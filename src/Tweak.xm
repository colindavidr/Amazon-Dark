/*
 * AmazonDark v4.0.0  —  "True Dark" rewrite
 * ============================================================================
 * Target: Amazon Shopping iOS app (com.amazon.Amazon), v27.x, NathanLR rootless,
 *         arm64 / arm64e. iOS 15+.
 *
 * WHY THIS IS A REWRITE (and not another v3.x inversion tweak)
 * ----------------------------------------------------------------------------
 * v3.x forced a `colorInvert` CAFilter onto the top-level UIWindow layer and then
 * tried to *counter-invert* every image layer back to normal. That fight is
 * inherently racy: the window inverts synchronously, but per-image counter-filters
 * only land on layout, so photos flash (and often stay) as negatives. That is the
 * root cause of "everything is dark but the images are inverted."
 *
 * A real dark mode never inverts a photo in the first place. That is what NOIR /
 * Dark Reader do on the web, and it is the behavior we want. So v4 stops inverting
 * and instead darkens each surface with a method appropriate to that surface:
 *
 *   1. WEB VIEWS  (Home gateway, Cart, PDP, Search, most "content"):  Dark Reader.
 *      We bundle the official Dark Reader engine (MIT, resources/darkreader.js) and
 *      call DarkReader.enable(theme). Dark Reader analyses each element's real
 *      colors and generates a genuine dark theme. It deliberately LEAVES <img>,
 *      <picture>, <video>, <canvas> and background images ALONE. This is the fix
 *      for inverted images, and it is the surface the user confirmed works perfectly
 *      via the NOIR Safari extension.
 *
 *   2. NATIVE CHROME  (tab bar, nav/search bar, SwiftUI/UIKit surfaces):  the app's
 *      OWN native dark theme. Confirmed in the 27.11.8 binary: a complete native
 *      dark theme (ANXDarkModeServiceImpl, dark ConfigurableChromeSkins, dark
 *      tab-bar tokens) gated behind ONE Weblab, NAVX_DARK_MODE_IOS_1283655
 *      (default-treatment "C" = off). We flip that gate on client-side + set the
 *      appearance preference to dark + make the trait-observer report dark, then
 *      fire ANXAppearanceModeDidChangeNotification. Amazon then renders its own
 *      designed dark chrome — correct icons, correct accent colors, no inversion.
 *
 *   3. NATIVE NON-WEB CONTENT that stays light because it is server-driven and the
 *      server withholds dark color tokens for accounts outside the dark cohort:
 *      an OPTIONAL, preference-gated, background-only darkening pass that recolors
 *      solid light backgrounds toward the configured dark background and NEVER
 *      touches image/glyph layers. Off by default (see AD_PREF_NATIVE_FALLBACK).
 *
 * Everything is controlled by a preference plist (see prefs/ subproject), so this
 * is a true dark mode with color settings, like CarBridge / OneSettings, not a
 * one-size invert.
 *
 * NATHANLR SAFETY (carried over verbatim from the CarBridgeReborn sessions)
 * ----------------------------------------------------------------------------
 *  - ZERO Obj-C in %ctor: no NSLog/os_log, no @"" literals at ctor scope. The ObjC
 *    runtime is not guaranteed ready when the dylib loads on NathanLR; touching it
 *    there SIGBUS/SIGABRTs. %ctor uses only raw write() syscalls + a process guard.
 *  - All Obj-C work is deferred onto the main queue / dispatch_after sweeps.
 *  - File logging to $TMPDIR (sandbox-writable; /var/mobile is NOT writable from a
 *    sandboxed app — that mistake cost a whole session last time).
 *  - Every hook body is wrapped in @try/@catch so an unexpected shape is absorbed.
 *  - No auto-killall in postinst (respring races with Ellekit/dpkg triggers).
 * ============================================================================
 */

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
#import <stdio.h>
#import <unistd.h>
#import <fcntl.h>
#import <dlfcn.h>
#import "ADColor.h"

extern char *__progname;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wunused-variable"
#pragma clang diagnostic ignored "-Wunused-function"
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
#pragma clang diagnostic ignored "-Wobjc-method-access"

// ─── the Weblab that gates Amazon's native dark theme (confirmed in binary) ─────────
#define AD_DARK_WEBLAB      "NAVX_DARK_MODE_IOS_1283655"
#define AD_DARK_TREATMENT   "T1"   // change to T2/T3 if a future build gates on another

// Preference domain (matches prefs subproject + postinst).
#define AD_PREF_DOMAIN      "com.colindavidr.amazondark"

// ════════════════════════════════════════════════════════════════════════════════
// Class forward-decls. We declare unknown Amazon classes as UIView/NSObject so the
// compiler resolves selectors; Logos/%hook only installs on classes that exist at
// runtime, so declaring one that is absent in some build is harmless.
// ════════════════════════════════════════════════════════════════════════════════
@interface ANXDarkModeServiceImpl : NSObject
- (BOOL)isDarkModeExperienceEnabled;
- (BOOL)isDarkModeExperienceActive;
- (BOOL)systemDarkModeActive;
@end

@interface AXUSplashScreenViewController : UIViewController @end
@interface TezBaseSplashScreenViewController : UIViewController @end

// ─────────────────────────────────────────────────────────────────────────────────
// Logging (file-based, sandbox-safe). Raw writes only from ctor; Obj-C-free.
// ─────────────────────────────────────────────────────────────────────────────────
static int gFD = -1;
static void ADOpenLog(void){
    const char *t = getenv("TMPDIR");
    char p[2048];
    if (t && *t) snprintf(p, sizeof(p), "%sAmazonDark.log", t);   // TMPDIR ends with '/'
    else         strncpy(p, "/tmp/AmazonDark.log", sizeof(p));
    gFD = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0644);
}
static void ADRaw(const char *s){ if (gFD >= 0){ write(gFD, s, strlen(s)); write(gFD, "\n", 1); } }

// Formatted logging. Safe after launch (Obj-C available); never called from %ctor.
static void ADLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void ADLog(NSString *fmt, ...){
    @try {
        va_list ap; va_start(ap, fmt);
        NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        ADRaw([[@"[AmazonDark] " stringByAppendingString:m] UTF8String]);
    } @catch(...) {}
}

// ════════════════════════════════════════════════════════════════════════════════
// PREFERENCES
// Read straight from the plist the settings bundle writes. We avoid a hard Cephei
// dependency (keeps the tweak self-contained); NSUserDefaults(suiteName:) reads the
// same file HBPreferences/Cephei write to under rootless.
// ════════════════════════════════════════════════════════════════════════════════
typedef struct {
    BOOL  enabled;            // master on/off
    BOOL  webDarkReader;      // use Dark Reader in web views
    BOOL  nativeTheme;        // force Amazon's native dark theme (weblab)
    BOOL  nativeRecolor;      // Dark Reader colour engine over native (non-web) content
    long  brightness;         // Dark Reader 0..100+ (default 100)
    long  contrast;           // Dark Reader 0..100+ (default 100)
    long  sepia;              // Dark Reader 0..100  (default 0)
    long  grayscale;          // Dark Reader 0..100  (default 0)
    char  bgHex[8];           // dark scheme background, "#RRGGBB"
    char  fgHex[8];           // dark scheme text,       "#RRGGBB"
} ADPrefs;

static ADPrefs gP;
static void ADSyncColorEngine(void);
static UIColor *ADColorFromHex(const char *hex);
static void ADRunProbe(void);

static long ADPrefLong(NSDictionary *d, NSString *k, long def){
    id v = d[k]; return (v && [v respondsToSelector:@selector(longValue)]) ? [v longValue] : def;
}
static BOOL ADPrefBool(NSDictionary *d, NSString *k, BOOL def){
    id v = d[k]; return (v && [v respondsToSelector:@selector(boolValue)]) ? [v boolValue] : def;
}
static void ADPrefHex(NSDictionary *d, NSString *k, const char *def, char *out){
    id v = d[k];
    NSString *s = ([v isKindOfClass:[NSString class]] && [v length] >= 4) ? v : @(def);
    strncpy(out, s.UTF8String, 7); out[7] = 0;
}

static void ADLoadPrefs(void){
    // Defaults: everything a "true dark mode" wants, image inversion OFF.
    gP.enabled = YES; gP.webDarkReader = YES; gP.nativeTheme = YES;
    gP.nativeRecolor = YES;
    gP.brightness = 100; gP.contrast = 100; gP.sepia = 0; gP.grayscale = 0;
    strcpy(gP.bgHex, "#181a1b"); strcpy(gP.fgHex, "#e8e6e3");
    @try {
        NSUserDefaults *u = [[NSUserDefaults alloc] initWithSuiteName:@(AD_PREF_DOMAIN)];
        NSDictionary *d = [u dictionaryRepresentation] ?: @{};
        // also merge the on-disk plist if present (rootless prefs path)
        NSString *pp = [NSString stringWithFormat:@"/var/jb/var/mobile/Library/Preferences/%s.plist", AD_PREF_DOMAIN];
        NSDictionary *fromFile = [NSDictionary dictionaryWithContentsOfFile:pp];
        if (fromFile.count){ NSMutableDictionary *m = [d mutableCopy]; [m addEntriesFromDictionary:fromFile]; d = m; }

        gP.enabled            = ADPrefBool(d, @"enabled",            gP.enabled);
        gP.webDarkReader      = ADPrefBool(d, @"webDarkReader",      gP.webDarkReader);
        gP.nativeTheme        = ADPrefBool(d, @"nativeTheme",        gP.nativeTheme);
        gP.nativeRecolor      = ADPrefBool(d, @"nativeRecolor",      gP.nativeRecolor);
        gP.brightness         = ADPrefLong(d, @"brightness",         gP.brightness);
        gP.contrast           = ADPrefLong(d, @"contrast",           gP.contrast);
        gP.sepia              = ADPrefLong(d, @"sepia",              gP.sepia);
        gP.grayscale          = ADPrefLong(d, @"grayscale",          gP.grayscale);
        ADPrefHex(d, @"bgHex", "#181a1b", gP.bgHex);
        ADPrefHex(d, @"fgHex", "#e8e6e3", gP.fgHex);
    } @catch(...) {}
    ADSyncColorEngine();
    ADLog(@"prefs: enabled=%d web=%d nativeTheme=%d nativeRecolor=%d bright=%ld contrast=%ld gray=%ld sepia=%ld bg=%s fg=%s",
          gP.enabled, gP.webDarkReader, gP.nativeTheme, gP.nativeRecolor,
          gP.brightness, gP.contrast, gP.grayscale, gP.sepia, gP.bgHex, gP.fgHex);
}

// ════════════════════════════════════════════════════════════════════════════════
// SURFACE 1 — WEB VIEWS via bundled Dark Reader
// ════════════════════════════════════════════════════════════════════════════════

// Locate our bundled darkreader.js next to the dylib (rootless-safe: use dladdr to
// find our own install dir, then read the sibling resource).
static NSString *ADBundledDarkReaderJS(void){
    static NSString *cached = nil;
    static BOOL tried = NO;
    if (tried) return cached;
    tried = YES;
    @try {
        Dl_info info; static int anchor;
        if (dladdr((const void *)&anchor, &info) && info.dli_fname){
            NSString *dylib = @(info.dli_fname);
            NSString *dir = [dylib stringByDeletingLastPathComponent];
            // Theos installs BUNDLE resources to .../AmazonDark.bundle next to the dylib.
            NSArray *cands = @[
                [dir stringByAppendingPathComponent:@"AmazonDark.bundle/darkreader.js"],
                [dir stringByAppendingPathComponent:@"darkreader.js"],
                @"/var/jb/Library/Application Support/AmazonDark/darkreader.js",
            ];
            for (NSString *c in cands){
                NSString *s = [NSString stringWithContentsOfFile:c encoding:NSUTF8StringEncoding error:nil];
                if (s.length){
                    cached = s;
                    ADLog(@"darkreader.js loaded (%lu bytes) from %@", (unsigned long)s.length, c);
                    break;
                }
                ADLog(@"darkreader.js NOT at %@", c);
            }
            if (!cached.length)
                ADLog(@"FATAL: darkreader.js missing — web surfaces will stay LIGHT. "
                       "Check the package installed it under Application Support/AmazonDark.");
        }
    } @catch(...) {}
    return cached;
}

// The theme literal, built from live prefs (shared by both the heavy bootstrap and
// the lightweight re-enable call).
static NSString *ADThemeLiteral(void){
    // mode:1 = dark. styleSystemControls themes form controls/scrollbars.
    // The fixed/sticky headers Amazon uses respond better with these on.
    return [NSString stringWithFormat:
        @"{mode:1,brightness:%ld,contrast:%ld,sepia:%ld,grayscale:%ld,"
         "darkSchemeBackgroundColor:'%s',darkSchemeTextColor:'%s',"
         "styleSystemControls:true}",
        gP.brightness, gP.contrast, gP.sepia, gP.grayscale, gP.bgHex, gP.fgHex];
}

// HEAVY: full Dark Reader UMD + first enable(). Injected ONCE per document at
// documentStart via a WKUserScript. The 346KB engine is parsed a single time per page.
static NSString *ADDarkReaderBootstrap(void){
    NSString *dr = ADBundledDarkReaderJS();
    if (!dr.length) return nil;
    return [NSString stringWithFormat:
        @"(function(){try{"
         "if(window.__AMZDARK_LOADED__)return;window.__AMZDARK_LOADED__=1;%@\n" // DarkReader UMD
         "if(window.DarkReader&&DarkReader.enable){"
         "try{DarkReader.setFetchMethod(window.fetch);}catch(e){}"
         "window.__AMZDARK_APPLY__=function(){try{DarkReader.enable(%@);}catch(e){}};"
         "window.__AMZDARK_APPLY__();"
         "}}catch(e){}})();",
        dr, ADThemeLiteral()];
}

// LIGHT: re-apply the theme without re-parsing the engine. Safe to call on every
// navigation / timer tick; no-ops until the heavy bootstrap has run for this document.
static NSString *ADDarkReaderReapply(void){
    return [NSString stringWithFormat:
        @"(function(){try{"
         "if(window.__AMZDARK_APPLY__){window.__AMZDARK_APPLY__();}"
         "else if(window.DarkReader&&DarkReader.enable){DarkReader.enable(%@);}"
         "}catch(e){}})();",
        ADThemeLiteral()];
}

static void ADEnableDarkReaderIn(WKWebView *wv){
    if (!gP.enabled || !gP.webDarkReader || !wv) return;
    @try {
        // Lightweight re-apply; the heavy engine arrives via the documentStart userscript.
        NSString *js = ADDarkReaderReapply();
        if (js.length) [wv evaluateJavaScript:js completionHandler:nil];
    } @catch(...) {}
}

// Inject the FULL engine into whatever is already rendered (used once for web views
// that existed before our hook — e.g. the warmed gateway — where the documentStart
// userscript won't fire until the next load). Idempotent: the bootstrap self-guards
// on window.__AMZDARK_LOADED__, so calling it repeatedly is safe.
static void ADBootstrapDarkReaderIn(WKWebView *wv){
    if (!gP.enabled || !gP.webDarkReader || !wv) return;
    @try {
        NSString *js = ADDarkReaderBootstrap();
        if (js.length) [wv evaluateJavaScript:js completionHandler:nil];
    } @catch(...) {}
}

static int gWebSeen = 0;
static void ADWalkWebViews(UIView *v){
    @try {
        if ([v isKindOfClass:[WKWebView class]]){ gWebSeen++; ADEnableDarkReaderIn((WKWebView *)v); }
        for (UIView *s in v.subviews) ADWalkWebViews(s);
    } @catch(...) {}
}
static void ADInjectAllWebViews(void){
    @try {
        gWebSeen = 0;
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes){
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) ADWalkWebViews(w);
        }
        static int lastReported = -1;
        if (gWebSeen != lastReported){ ADLog(@"web views themed: %d", gWebSeen); lastReported = gWebSeen; }
    } @catch(...) {}
}

%hook WKWebView
- (id)initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)cfg {
    @try {
        if (gP.enabled && gP.webDarkReader && cfg && cfg.userContentController){
            NSString *js = ADDarkReaderBootstrap();
            Class WKUS = NSClassFromString(@"WKUserScript");
            if (js.length && WKUS){
                WKUserScript *us = [[WKUS alloc] initWithSource:js
                                                  injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                               forMainFrameOnly:NO];
                [cfg.userContentController addUserScript:us];
            }
        }
    } @catch(...) {}
    return %orig;
}
- (void)didMoveToWindow {
    %orig;
    @try {
        if (!self.window || !gP.enabled || !gP.webDarkReader) return;
        // Paint the web view's own backdrop dark up front so the white page has
        // nothing to flash before Dark Reader paints the DOM. Cheap and idempotent.
        self.opaque = NO;
        self.backgroundColor = ADColorFromHex(gP.bgHex);
        @try { [self setValue:ADColorFromHex(gP.bgHex) forKey:@"underPageBackgroundColor"]; } @catch(...) {}
        // Attach a documentStart user-script even to pre-initialised web views (e.g. the
        // warmed gateway) so a pull-to-refresh re-applies Dark Reader on the next load.
        static const void *kUS = &kUS;
        if (!objc_getAssociatedObject(self, kUS)){
            NSString *js = ADDarkReaderBootstrap();
            Class WKUS = NSClassFromString(@"WKUserScript");
            WKUserContentController *ucc = self.configuration.userContentController;
            if (js.length && WKUS && ucc){
                WKUserScript *us = [[WKUS alloc] initWithSource:js
                                                  injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                               forMainFrameOnly:NO];
                [ucc addUserScript:us];
            }
            objc_setAssociatedObject(self, kUS, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        ADBootstrapDarkReaderIn(self); // engine into the already-rendered document (idempotent)
    } @catch(...) {}
}
- (void)webView:(WKWebView *)wv didFinishNavigation:(id)nav {
    %orig;
    ADEnableDarkReaderIn(self);
}
%end

// ════════════════════════════════════════════════════════════════════════════════
// SURFACE 2 — NATIVE CHROME via Amazon's own dark theme (flip the Weblab gate)
// ════════════════════════════════════════════════════════════════════════════════

// Force the two computed booleans the whole native theme keys off of.
%hook ANXDarkModeServiceImpl
- (BOOL)isDarkModeExperienceEnabled { if (gP.enabled && gP.nativeTheme) return YES; return %orig;
}
- (BOOL)isDarkModeExperienceActive  { if (gP.enabled && gP.nativeTheme) return YES; return %orig;
}
- (BOOL)systemDarkModeActive        { if (gP.enabled && gP.nativeTheme) return YES; return %orig;
}
%end

// Lock the Weblab treatment for the dark experiment so every downstream consumer
// (skins, tab-bar tokens, RN appearance module) sees the app as dark-enabled.
// AMIRedstoneWeblabBridgeService is the confirmed bridge; lockWeblab:toTreatment:
// returns BOOL. We call it once the service exists; guarded and idempotent.
static void ADLockDarkWeblab(void){
    if (!gP.enabled || !gP.nativeTheme) return;
    @try {
        Class Bridge = NSClassFromString(@"AMIRedstoneWeblabBridgeService");
        if (!Bridge) return;
        SEL shared = NSSelectorFromString(@"sharedWeblabService");
        id svc = nil;
        if ([Bridge respondsToSelector:shared]) svc = ((id(*)(id,SEL))objc_msgSend)(Bridge, shared);
        if (!svc) return;
        SEL lock = NSSelectorFromString(@"lockWeblab:toTreatment:");
        if ([svc respondsToSelector:lock]){
            ((void(*)(id,SEL,id,id))objc_msgSend)(svc, lock, @AD_DARK_WEBLAB, @AD_DARK_TREATMENT);
            ADRaw("[AmazonDark] locked NAVX_DARK_MODE_IOS_1283655 -> " AD_DARK_TREATMENT);
        }
    } @catch(...) {}
}

// Push the appearance preference to dark and broadcast the change so already-rendered
// chrome re-skins. The preference persists as an NSInteger tri-state
// (0 system / 1 light / 2 dark, mirroring UIUserInterfaceStyle); we set 2 and also
// call applyPreference: if present.
static void ADForceAppearanceDark(void){
    if (!gP.enabled || !gP.nativeTheme) return;
    @try {
        Class PM = NSClassFromString(@"ANXAppearancePreferenceManager");
        if (PM){
            SEL save  = NSSelectorFromString(@"savePreference:");
            SEL apply = NSSelectorFromString(@"applyPreference:");
            if ([PM respondsToSelector:save])  ((void(*)(id,SEL,long))objc_msgSend)(PM, save, 2);
            if ([PM respondsToSelector:apply]) ((void(*)(id,SEL,long))objc_msgSend)(PM, apply, 2);
        }
        // Fire the documented notification so listeners re-render.
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"ANXAppearanceModeDidChangeNotification"
                          object:nil
                        userInfo:@{ @"darkMode": @YES }];
    } @catch(...) {}
}

// Make the trait-observer report dark so systemDarkModeActive is naturally YES even
// if the boolean hook above is bypassed by a code path that re-reads the trait.
static void ADForceWindowsDarkTrait(void){
    if (!gP.enabled || !gP.nativeTheme) return;
    if (@available(iOS 13.0, *)) {
        @try {
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes){
                if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)sc).windows)
                    w.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
            }
        } @catch(...) {}
    }
}

// ════════════════════════════════════════════════════════════════════════════════
// SURFACE 3 — NATIVE CONTENT via the Dark Reader colour engine (ADColor.m)
// ────────────────────────────────────────────────────────────────────────────────
// This is the part that makes it a *dark mode* rather than an *inversion*.
//
// We intercept each colour at the moment the app assigns it and re-map it in HSL
// space: backgrounds fall toward the dark pole, text and tints rise toward the
// light pole, borders compress toward the middle. Hue and saturation survive, so
// Amazon orange stays orange and the blue links stay blue — they just sit at a
// lightness that works on a dark surface.
//
// The critical property: a colour is a *declaration*, never a pixel. We never
// touch layer.contents, never install a CAFilter, never see a CGImage. Photos,
// product shots, customer images and app icons are therefore untouched — not
// because we detect and exempt them, but because they are not on this code path
// at all. That is the structural fix for the inverted-images bug, and it is why
// no allowlist of image classes needs maintaining ever again.
// ════════════════════════════════════════════════════════════════════════════════

// Push the current prefs into the colour engine (also clears its memo cache).
static void ADSyncColorEngine(void){
    ADThemeConfig cfg;
    cfg.brightness = (double)gP.brightness;
    cfg.contrast   = (double)gP.contrast;
    cfg.grayscale  = (double)gP.grayscale;
    cfg.sepia      = (double)gP.sepia;
    cfg.bgR = 24;  cfg.bgG = 26;  cfg.bgB = 27;
    cfg.fgR = 232; cfg.fgG = 230; cfg.fgB = 227;
    ADParseHexInto(gP.bgHex, &cfg.bgR, &cfg.bgG, &cfg.bgB);
    ADParseHexInto(gP.fgHex, &cfg.fgR, &cfg.fgG, &cfg.fgB);
    ADColorSetTheme(cfg);
}

// WebKit renders its own hierarchy and Dark Reader already owns everything inside
// it. Recolouring WK's internal views would fight the web engine and can blank the
// compositing layers, so we leave that whole subtree alone.
static inline BOOL ADIsWebKitOwned(id obj){
    if (!obj) return NO;
    const char *n = object_getClassName(obj);
    if (!n) return NO;
    if (n[0]=='W' && n[1]=='K') return YES;                 // WKWebView, WKContentView, …
    if (strncmp(n, "Web", 3) == 0) return YES;              // WebSimpleLayer, WebLayer, …
    return NO;
}
// A CALayer inside WebKit often has no delegate at all, so test the layer itself too.
static inline BOOL ADLayerIsWebKitOwned(CALayer *l){
    if (!l) return NO;
    if (ADIsWebKitOwned(l)) return YES;
    return ADIsWebKitOwned(l.delegate);
}

static inline BOOL ADRecolorOn(void){ return gP.enabled && gP.nativeRecolor; }

// ─── UIView / UILabel / controls ──────────────────────────────────────────────────
%hook UIView
- (void)setBackgroundColor:(UIColor *)color {
    if (!ADRecolorOn() || !color || ADIsWebKitOwned(self)) {
        %orig;
        return;
    }
    @try {
        UIColor *m = ADModifyUIColor(color, ADColorRoleBackground);
        if (!m) m = color;
        %orig(m);
        return;
    } @catch(...) {}
    %orig;
}
- (void)setTintColor:(UIColor *)color {
    // Template images (tab-bar glyphs, chevrons, the cart icon) are tinted, not
    // drawn. Treating tint as foreground is what keeps those icons visible once
    // the bar behind them goes dark — the failure mode that broke v3.2.1.
    if (!ADRecolorOn() || !color || ADIsWebKitOwned(self)) {
        %orig;
        return;
    }
    @try {
        UIColor *m = ADModifyUIColor(color, ADColorRoleForeground);
        if (!m) m = color;
        %orig(m);
        return;
    } @catch(...) {}
    %orig;
}
%end

%hook UILabel
- (void)setTextColor:(UIColor *)color {
    if (!ADRecolorOn() || !color) {
        %orig;
        return;
    }
    @try {
        UIColor *m = ADModifyUIColor(color, ADColorRoleForeground);
        if (!m) m = color;
        %orig(m);
        return;
    } @catch(...) {}
    %orig;
}
%end

%hook UITextView
- (void)setTextColor:(UIColor *)color {
    if (!ADRecolorOn() || !color) {
        %orig;
        return;
    }
    @try {
        UIColor *m = ADModifyUIColor(color, ADColorRoleForeground);
        if (!m) m = color;
        %orig(m);
        return;
    } @catch(...) {}
    %orig;
}
%end

%hook UITextField
- (void)setTextColor:(UIColor *)color {
    if (!ADRecolorOn() || !color) {
        %orig;
        return;
    }
    @try {
        UIColor *m = ADModifyUIColor(color, ADColorRoleForeground);
        if (!m) m = color;
        %orig(m);
        return;
    } @catch(...) {}
    %orig;
}
%end

%hook UIButton
- (void)setTitleColor:(UIColor *)color forState:(UIControlState)state {
    if (!ADRecolorOn() || !color) {
        %orig;
        return;
    }
    @try {
        UIColor *m = ADModifyUIColor(color, ADColorRoleForeground);
        if (!m) m = color;
        %orig(m, state);
        return;
    } @catch(...) {}
    %orig;
}
%end

// ════════════════════════════════════════════════════════════════════════════════
// SURFACE 3b — REACT NATIVE TEXT (the "text is almost as dark as the background")
// ────────────────────────────────────────────────────────────────────────────────
// This is the piece v5.0.3 was missing. React Native does NOT put text in a UILabel
// with a settable textColor. RCTParagraphComponentView / RCTTextView hold an
// NSAttributedString and draw it themselves in drawRect: via
//   -drawAttributedString:paragraphAttributes:frame:drawHighlightPath:
// The colour is baked into NSForegroundColorAttributeName runs inside that string,
// so our UILabel/UITextView textColor hooks never see it. The RN background went
// dark (UIView/CALayer hooks caught it) while the dark text stayed dark — hence
// near-invisible labels on the account, cart and Alexa tabs.
//
// Fix: intercept the attributed string on its way in, walk every foreground-colour
// run, and push each through the SAME foreground curve as everything else. Text
// runs with no explicit colour default to black in RN, so a nil-colour run is
// treated as black and lifted to the light pole too.
// ════════════════════════════════════════════════════════════════════════════════

static NSAttributedString *ADRecolorAttributedString(NSAttributedString *in){
    if (!ADRecolorOn() || in.length == 0) return in;
    @try {
        NSMutableAttributedString *m = [in mutableCopy];
        NSRange full = NSMakeRange(0, m.length);
        [m enumerateAttribute:NSForegroundColorAttributeName inRange:full
                      options:0
                   usingBlock:^(id value, NSRange range, BOOL *stop){
            @try {
                UIColor *orig = [value isKindOfClass:[UIColor class]]
                                ? (UIColor *)value
                                : [UIColor blackColor];   // RN default text colour
                UIColor *mod = ADModifyUIColor(orig, ADColorRoleForeground);
                if (mod) [m addAttribute:NSForegroundColorAttributeName value:mod range:range];
            } @catch(...) {}
        }];
        return m;
    } @catch(...) { return in; }
}

// Fabric text (new architecture). Setter lives on RCTParagraphComponentView.
%hook RCTParagraphComponentView
- (void)setAttributedText:(NSAttributedString *)attributedText {
    @try {
        NSAttributedString *r = ADRecolorAttributedString(attributedText);
        %orig(r);
        return;
    } @catch(...) {}
    %orig;
}
- (void)_setAttributedString:(NSAttributedString *)attributedString {
    @try {
        NSAttributedString *r = ADRecolorAttributedString(attributedString);
        %orig(r);
        return;
    } @catch(...) {}
    %orig;
}
%end

// Paper text (old architecture) — still present in this binary.
%hook RCTTextView
- (void)setTextStorage:(NSTextStorage *)textStorage {
    @try {
        if (ADRecolorOn() && textStorage.length){
            NSRange full = NSMakeRange(0, textStorage.length);
            [textStorage enumerateAttribute:NSForegroundColorAttributeName inRange:full
                                    options:0
                                 usingBlock:^(id value, NSRange range, BOOL *stop){
                @try {
                    UIColor *orig = [value isKindOfClass:[UIColor class]]
                                    ? (UIColor *)value : [UIColor blackColor];
                    UIColor *mod = ADModifyUIColor(orig, ADColorRoleForeground);
                    if (mod) [textStorage addAttribute:NSForegroundColorAttributeName
                                                 value:mod range:range];
                } @catch(...) {}
            }];
        }
    } @catch(...) {}
    %orig;
}
%end

// Some Amazon custom labels vend an attributed string through UILabel directly.
%hook UILabel
- (void)setAttributedText:(NSAttributedString *)attributedText {
    if (!ADRecolorOn() || !attributedText.length) {
        %orig;
        return;
    }
    @try {
        NSAttributedString *r = ADRecolorAttributedString(attributedText);
        %orig(r);
        return;
    } @catch(...) {}
    %orig;
}
%end

// ─── CALayer: catches React Native (Fabric sets layer colours directly) ───────────
%hook CALayer
- (void)setBackgroundColor:(CGColorRef)color {
    if (!ADRecolorOn() || !color) {
        %orig;
        return;
    }
    @try {
        if (ADLayerIsWebKitOwned(self)) {
            %orig;
            return;
        }
        CGColorRef m = ADModifyCGColor(color, ADColorRoleBackground);
        if (!m) m = color;
        %orig(m);
        return;
    } @catch(...) {}
    %orig;
}
- (void)setBorderColor:(CGColorRef)color {
    if (!ADRecolorOn() || !color) {
        %orig;
        return;
    }
    @try {
        if (ADLayerIsWebKitOwned(self)) {
            %orig;
            return;
        }
        CGColorRef m = ADModifyCGColor(color, ADColorRoleBorder);
        if (!m) m = color;
        %orig(m);
        return;
    } @catch(...) {}
    %orig;
}
%end

%hook CAGradientLayer
- (void)setColors:(NSArray *)colors {
    if (!ADRecolorOn() || colors.count == 0) {
        %orig;
        return;
    }
    @try {
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:colors.count];
        for (id c in colors){
            CGColorRef cg = (__bridge CGColorRef)c;
            CGColorRef m  = ADModifyCGColor(cg, ADColorRoleBackground);
            [out addObject:(__bridge id)(m ? m : cg)];
        }
        %orig(out);
        return;
    } @catch(...) {}
    %orig;
}
%end

// ─── system chrome that has its own switches rather than colours ───────────────────
%hook UIVisualEffectView
- (void)setEffect:(UIVisualEffect *)effect {
    if (!ADRecolorOn()) {
        %orig;
        return;
    }
    @try {
        if ([effect isKindOfClass:[UIBlurEffect class]]){
            %orig([UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]);
            return;
        }
    } @catch(...) {}
    %orig;
}
%end

%hook UIScrollView
- (void)didMoveToWindow {
    %orig;
    @try { if (ADRecolorOn() && self.window) self.indicatorStyle = UIScrollViewIndicatorStyleWhite; } @catch(...) {}
}
%end

// ════════════════════════════════════════════════════════════════════════════════
// SURFACE 4 — bottom nav toolbar chrome (the tab bar strip).
// These Amazon container views sometimes assert an opaque light backdrop AFTER our
// generic hooks run, so a plain colour swap can be overwritten. Forcing the fill in
// layoutSubviews (which re-runs on every relayout) makes it stick. Image-safe: only
// the container's own backgroundColor is touched, never any glyph/icon subview.
// ════════════════════════════════════════════════════════════════════════════════
%hook CXIStoreModesBottomNavToolbar
- (void)layoutSubviews {
    %orig;
    @try { if (gP.enabled) ((UIView *)self).backgroundColor = ADColorFromHex(gP.bgHex); } @catch(...) {}
}
%end
%hook CXIStoreModesTabBarView
- (void)layoutSubviews {
    %orig;
    @try { if (gP.enabled) ((UIView *)self).backgroundColor = ADColorFromHex(gP.bgHex); } @catch(...) {}
}
%end
%hook ANPRetailTabBar
- (void)layoutSubviews {
    %orig;
    @try { if (gP.enabled) ((UIView *)self).backgroundColor = ADColorFromHex(gP.bgHex); } @catch(...) {}
}
%end

// ════════════════════════════════════════════════════════════════════════════════
// SURFACE 3c — drawRect: painting (the gap that left whole panels white)
// ────────────────────────────────────────────────────────────────────────────────
// A view that paints itself in drawRect: never assigns a backgroundColor. It calls
// [someColor setFill] / [someColor set] and fills a rect. Nothing in the UIView or
// CALayer hooks can see that, so those panels stayed exactly as Amazon drew them —
// which is what the white "lattice" on the hamburger tab and the white boxes on the
// account tab are. Routing the paint colours through the same curve fixes the whole
// class of them at once, without naming a single Amazon class.
//
// Images are unaffected: this intercepts *fill/stroke colours*, never image drawing.
// ════════════════════════════════════════════════════════════════════════════════
%hook UIColor
- (void)set {
    if (!ADRecolorOn()) {
        %orig;
        return;
    }
    @try {
        UIColor *m = ADModifyUIColor(self, ADColorRoleAuto);
        if (m) {
            [m set];
            return;
        }
    } @catch(...) {}
    %orig;
}
- (void)setFill {
    if (!ADRecolorOn()) {
        %orig;
        return;
    }
    @try {
        UIColor *m = ADModifyUIColor(self, ADColorRoleAuto);
        if (m) {
            [m setFill];
            return;
        }
    } @catch(...) {}
    %orig;
}
- (void)setStroke {
    if (!ADRecolorOn()) {
        %orig;
        return;
    }
    @try {
        UIColor *m = ADModifyUIColor(self, ADColorRoleBorder);
        if (m) {
            [m setStroke];
            return;
        }
    } @catch(...) {}
    %orig;
}
%end

// ════════════════════════════════════════════════════════════════════════════════
// DIAGNOSTIC PROBE — make the tweak tell us what is still light.
// ────────────────────────────────────────────────────────────────────────────────
// Three rounds of inferring from screenshots has not converged, because a white
// panel can be a UIView background, a drawRect: fill, a UIImage, or a web surface,
// and they look identical in a photo but need completely different fixes. This walks
// the live hierarchy and logs the CLASS of anything still rendering light, plus how
// it is coloured. One line per offender tells us which mechanism to target.
//
// Throttled hard: at most one report per screen appearance and capped entries, so it
// cannot spam the log or cost anything meaningful on the main thread.
static BOOL  gProbeArmed  = NO;
static int   gProbeReports = 0;

static void ADProbeTree(UIView *v, int depth, int *found){
    if (!v || depth > 40 || *found >= 25) return;
    @try {
        if (ADIsWebKitOwned(v)) {
            ADLog(@"  probe: WEBVIEW %s (Dark Reader territory)", object_getClassName(v));
            return;
        }
        UIColor *bg = v.backgroundColor;
        if (bg){
            CGFloat r,g,b,a;
            if ([bg getRed:&r green:&g blue:&b alpha:&a] && a > 0.2){
                CGFloat lum = 0.2126*r + 0.7152*g + 0.0722*b;
                if (lum > 0.55){                     // still light => an offender
                    ADLog(@"  probe: LIGHT bg %s rgba(%.2f,%.2f,%.2f,%.2f) frame=%.0fx%.0f",
                          object_getClassName(v), r,g,b,a,
                          v.bounds.size.width, v.bounds.size.height);
                    (*found)++;
                }
            }
        } else if (v.bounds.size.width > 150 && v.bounds.size.height > 60 && !v.hidden) {
            // No backgroundColor at all but big and visible => probably drawRect: or a
            // UIImageView. Naming it tells us which of the two to chase.
            BOOL isImg = [v isKindOfClass:[UIImageView class]];
            ADLog(@"  probe: NO-BG %s%s frame=%.0fx%.0f",
                  object_getClassName(v), isImg ? " (UIImageView)" : " (drawRect?)",
                  v.bounds.size.width, v.bounds.size.height);
            (*found)++;
        }
        for (UIView *s in v.subviews) ADProbeTree(s, depth+1, found);
    } @catch(...) {}
}

static void ADRunProbe(void){
    if (!gProbeArmed || gProbeReports >= 6) return;
    gProbeArmed = NO;
    gProbeReports++;
    @try {
        int found = 0;
        ADLog(@"── probe #%d: scanning for surfaces still light ──", gProbeReports);
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes){
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) ADProbeTree(w, 0, &found);
        }
        ADLog(@"── probe #%d complete: %d offender(s) ──", gProbeReports, found);
    } @catch(...) {}
}

// ════════════════════════════════════════════════════════════════════════════════
// SURFACE 3d — REACT NATIVE VIEW BACKGROUNDS
// ────────────────────────────────────────────────────────────────────────────────
// The probe proved these were unreachable: RCTScrollView and the account-menu tiles
// held pure opaque white through every sweep. Two reasons, both structural.
//
//  1. Obj-C dispatch. RCTView overrides setBackgroundColor:, so a %hook on UIView
//     is simply never consulted for it — the subclass implementation wins.
//  2. RN's override early-returns when the incoming colour isEqual: the stored one.
//
// Hooking the RN classes themselves fixes (1); the sweep now passing a transformed
// colour fixes (2). Both are needed — the hook catches live updates, the sweep
// catches anything built before we attached.
//
// Still image-safe: these set a view's own background fill, never layer.contents.
// ════════════════════════════════════════════════════════════════════════════════
%hook RCTView
- (void)setBackgroundColor:(UIColor *)backgroundColor {
    if (!ADRecolorOn() || !backgroundColor) {
        %orig;
        return;
    }
    @try {
        UIColor *m = ADModifyUIColor(backgroundColor, ADColorRoleBackground);
        if (!m) m = backgroundColor;
        %orig(m);
        return;
    } @catch(...) {}
    %orig;
}
%end

%hook RCTScrollView
- (void)setBackgroundColor:(UIColor *)backgroundColor {
    if (!ADRecolorOn() || !backgroundColor) {
        %orig;
        return;
    }
    @try {
        UIColor *m = ADModifyUIColor(backgroundColor, ADColorRoleBackground);
        if (!m) m = backgroundColor;
        %orig(m);
        return;
    } @catch(...) {}
    %orig;
}
%end

%hook RCTViewComponentView
- (void)setBackgroundColor:(UIColor *)backgroundColor {
    if (!ADRecolorOn() || !backgroundColor) {
        %orig;
        return;
    }
    @try {
        UIColor *m = ADModifyUIColor(backgroundColor, ADColorRoleBackground);
        if (!m) m = backgroundColor;
        %orig(m);
        return;
    } @catch(...) {}
    %orig;
}
%end

// RN text colour also arrives as a discrete attribute object on the Paper path.
%hook RCTTextAttributes
- (void)setForegroundColor:(UIColor *)foregroundColor {
    if (!ADRecolorOn() || !foregroundColor) {
        %orig;
        return;
    }
    @try {
        UIColor *m = ADModifyUIColor(foregroundColor, ADColorRoleForeground);
        if (!m) m = foregroundColor;
        %orig(m);
        return;
    } @catch(...) {}
    %orig;
}
%end

// ─── catch-up sweep ───────────────────────────────────────────────────────────────
// Views built before our hooks installed (the pre-warmed gateway, the splash stack)
// already hold light colours. Re-assigning a view's own colour runs it through the
// hook once; ADModifyUIColor recognises anything it previously emitted, so a view
// that is swept twice is not darkened twice.
static void ADSweepViewTree(UIView *v, int depth){
    if (!v || depth > 60) return;
    @try {
        if (ADIsWebKitOwned(v)) return;                 // Dark Reader's territory
        UIColor *bg = v.backgroundColor;
        if (bg && !ADIsModifiedUIColor(bg)) {
            // Assign the TRANSFORMED colour, never the same object back.
            //
            // The old code did `v.backgroundColor = bg` and relied on our UIView hook
            // to convert it in flight. That fails twice over on React Native views:
            // RCTView overrides setBackgroundColor: (so the UIView hook never runs for
            // it), and its override early-returns when the new value isEqual: the one
            // it already holds — so handing back the identical object was a guaranteed
            // no-op. That is why RCTScrollView and the four 94x39 account-menu tiles
            // stayed pure white through every sweep.
            //
            // Passing a genuinely different colour object satisfies the equality check
            // and works regardless of whether a subclass overrides the setter.
            UIColor *m = ADModifyUIColor(bg, ADColorRoleBackground);
            if (m) v.backgroundColor = m;
        }
        if ([v isKindOfClass:[UILabel class]]){
            UILabel *l = (UILabel *)v;
            UIColor *tc = l.textColor;
            if (tc && !ADIsModifiedUIColor(tc)) {
                UIColor *mt = ADModifyUIColor(tc, ADColorRoleForeground);
                if (mt) l.textColor = mt;
            }
        }
        for (UIView *s in v.subviews) ADSweepViewTree(s, depth + 1);
    } @catch(...) {}
}
static void ADSweepAllWindows(void){
    if (!ADRecolorOn()) return;
    @try {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes){
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) ADSweepViewTree(w, 0);
        }
    } @catch(...) {}
}

// ════════════════════════════════════════════════════════════════════════════════
// Splash: while Dark Reader / native theme spin up, keep the launch screen dark so
// there is no white flash. Set the splash VC's own view backgroundColor (no invert).
// ════════════════════════════════════════════════════════════════════════════════
static UIColor *ADColorFromHex(const char *hex){
    unsigned int r=24,g=26,b=27;
    if (hex && hex[0]=='#') sscanf(hex+1, "%02x%02x%02x", &r,&g,&b);
    return [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1.0];
}
static void ADDarkenSplash(UIViewController *vc){
    if (!gP.enabled) return;
    @try { UIView *v = vc.view; if (v) v.backgroundColor = ADColorFromHex(gP.bgHex); } @catch(...) {}
}
%hook AXUSplashScreenViewController
- (void)viewDidLayoutSubviews {
    %orig;
    ADDarkenSplash(self);
}
- (void)viewDidAppear:(BOOL)a {
    %orig;
    ADDarkenSplash(self);
}
%end
%hook TezBaseSplashScreenViewController
- (void)viewDidLayoutSubviews {
    %orig;
    ADDarkenSplash(self);
}
- (void)viewDidAppear:(BOOL)a {
    %orig;
    ADDarkenSplash(self);
}
%end

// ════════════════════════════════════════════════════════════════════════════════
// Periodic re-apply. Web tabs re-render their DOM on back-navigation / pull-to-refresh
// and can drop Dark Reader; re-enabling is idempotent. Native theme re-broadcast is
// cheap. Timer self-reschedules with a gentle cadence.
// ════════════════════════════════════════════════════════════════════════════════
static void ADSweep(void){
    ADForceWindowsDarkTrait();
    ADInjectAllWebViews();
    ADSweepAllWindows();
}

// ─── decaying launch timer (bounded) ──────────────────────────────────────────────
// Catches views built before injection. It stops after the launch window, but that
// no longer leaves later tabs white: new web views re-theme themselves on mount
// (WKWebView didMoveToWindow) and on the RN tab-switch hook below, and native views
// are themed at assignment. So this timer is purely a launch-time backstop.
static int gSweepTicks = 0;
static void ADStartTimer(void){
    if (gSweepTicks++ > 20) {           // ~40s, then done — events take over
        ADRaw("[AmazonDark] launch sweeps complete; event-driven from here");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2.0*NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{ ADSweep(); ADStartTimer(); });
}

// ─── event-driven re-theme on tab / screen change (kills the white flash) ──────────
// The flashing you saw is a NEW web view being mounted for the tab you switch to:
// for a few frames it shows its own white page before Dark Reader paints the DOM,
// and if the launch timer had already stopped, nothing re-applied. Rather than run
// a forever-timer, we re-theme exactly when the view hierarchy changes. A short
// coalesced burst (0 / 60 / 200 / 500 ms) covers the mount-to-first-paint window
// without a standing cost.
static void ADReapplyBurst(void){
    static const int64_t delays_ms[] = {0, 60, 200, 500};
    for (int i = 0; i < 4; i++){
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delays_ms[i]*1000000LL),
            dispatch_get_main_queue(), ^{ @try {
                ADForceWindowsDarkTrait();
                ADInjectAllWebViews();
                ADSweepAllWindows();
            } @catch(...) {} });
    }
}

// UIViewController appearance is the most reliable, arch-agnostic signal for a tab
// switch or push. Gate to controllers that actually host content so we do not fire
// the burst for every cell-sized child VC.
%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    @try {
        if (!ADRecolorOn()) return;
        if (self.view.window && self.view.bounds.size.width > 200){
            gProbeArmed = YES;
            ADReapplyBurst();
            // Probe after the burst has settled, so we only report genuine hold-outs.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 900*1000000LL),
                dispatch_get_main_queue(), ^{ ADRunProbe(); });
        }
    } @catch(...) {}
}
- (UIStatusBarStyle)preferredStatusBarStyle {
    if (gP.enabled) return UIStatusBarStyleLightContent;
    return %orig;
}
%end

// ─── live settings reload ─────────────────────────────────────────────────────────
// ADRootListController posts this Darwin notification on every toggle. Without an
// observer the setting sat in the plist and did nothing until the app was killed,
// which made the whole Settings pane look broken.
//
// Caveat worth knowing: web surfaces re-theme exactly, because DarkReader.enable()
// recomputes from the untouched DOM. Native views cannot — the original colour is
// gone once replaced, so re-running the transform over already-themed views drifts
// slightly (it converges, it does not blow up). A relaunch gives an exact result.
static void ADPrefsChanged(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object,
                           CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            ADLoadPrefs();              // also re-syncs + clears the colour cache
            ADRaw("[AmazonDark] prefs reloaded (Darwin notification)");
            ADForceWindowsDarkTrait();
            ADInjectAllWebViews();      // exact re-theme on web
            ADSweepAllWindows();        // best-effort re-theme on native
        } @catch(...) {}
    });
}

// Foreground: a backgrounded app can be re-laid-out by the system, and web tabs may
// have been reclaimed. One sweep on return is far cheaper than a forever-timer.
static void ADAppForegrounded(CFNotificationCenterRef center, void *observer,
                              CFStringRef name, const void *object,
                              CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{ @try { ADSweep(); } @catch(...) {} });
}

// ─── %ctor : Obj-C-free. Process guard + open log + %init + schedule real work. ────
%ctor {
    if (strcmp(__progname, "Amazon") != 0) return;   // belt (plist filter is the braces)
    ADOpenLog();
    ADRaw("[AmazonDark] v5.3.0 init (DarkReader web + native colour engine)");
    %init;
    ADRaw("[AmazonDark] hooks registered");
    {
        const char *names[] = {"RCTParagraphComponentView","RCTTextView","RCTViewComponentView",
                               "RCTScrollView","RCTTextAttributes",
                               "CXIStoreModesBottomNavToolbar","CXIStoreModesTabBarView",
                               "ANPRetailTabBar","ANXDarkModeServiceImpl"};
        for (unsigned i = 0; i < sizeof(names)/sizeof(names[0]); i++){
            char buf[160];
            snprintf(buf, sizeof(buf), "[AmazonDark] class %s: %s",
                     names[i], objc_getClass(names[i]) ? "FOUND" : "MISSING (hook inert)");
            ADRaw(buf);
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        ADLoadPrefs();
        ADLockDarkWeblab();
        ADForceAppearanceDark();
        ADForceWindowsDarkTrait();
        ADInjectAllWebViews();
        ADSweepAllWindows();
    });
    // Escalating sweeps to catch late-initialised services/web views (0.2s..~10s).
    for (double d = 0.2; d <= 10.0; d *= 1.6){
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(d*NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                ADLockDarkWeblab();
                ADForceAppearanceDark();
                ADSweep();
            });
    }
    // Live settings reload + foreground re-apply.
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, ADPrefsChanged,
        CFSTR("com.colindavidr.amazondark/prefs-changed"),
        NULL, CFNotificationSuspensionBehaviorCoalesce);
    CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(),
        NULL, ADAppForegrounded,
        (__bridge CFStringRef)UIApplicationWillEnterForegroundNotification,
        NULL, CFNotificationSuspensionBehaviorCoalesce);

    ADStartTimer();
}

#pragma clang diagnostic pop
