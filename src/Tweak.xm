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
// Keep in lockstep with layout/DEBIAN/control. The init log is the only way to
// confirm which build is live on device.
#define AD_VERSION "v5.121.0"

#import "ADColor.h"
#import "ADImageKey.h"

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
    BOOL  imageKeyBackground; // corner-key white studio backdrops in photos (opt-in)
    BOOL  imageBackdrop;      // dark panel behind images (helps transparent ones)
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
static const void *kADModImageKey = &kADModImageKey;
static inline BOOL ADIsModifiedImage(UIImage *im){ return im && objc_getAssociatedObject(im, kADModImageKey) != nil; }
static inline void ADMarkModifiedImage(UIImage *im){ if (im) objc_setAssociatedObject(im, kADModImageKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
static UIColor *ADColorFromHex(const char *hex);
static UIImage *ADGlyphify(UIImage *img);
static UIImage *ADGlyphifyForView(UIImage *img, UIView *v);
static BOOL ADIsChromeGlyphContext(UIView *v);
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

static void ADLoadPrefs(void);
static BOOL gPrefsLoadedOnce = NO;
static NSString *gADBootCache = nil;   // rebuilt only when prefs change; ALL access via ADBootQueue
static dispatch_queue_t ADBootQueue(void);
static inline void ADEnsurePrefs(void){
    if (gPrefsLoadedOnce) return;
    if ([NSThread isMainThread]){ ADLoadPrefs(); return; }
    dispatch_async(dispatch_get_main_queue(), ^{ if (!gPrefsLoadedOnce) ADLoadPrefs(); });
}
static void ADLoadPrefs(void){
    gPrefsLoadedOnce = YES;
    dispatch_async(ADBootQueue(), ^{ gADBootCache = nil; });   // serialized invalidation
    // Defaults: everything a "true dark mode" wants, image inversion OFF.
    gP.enabled = YES; gP.webDarkReader = YES; gP.nativeTheme = YES;
    gP.imageBackdrop = YES;
    gP.imageKeyBackground = NO;
    gP.nativeRecolor = YES;
    gP.brightness = 100; gP.contrast = 100; gP.sepia = 0; gP.grayscale = 0;
    strcpy(gP.bgHex, "#181a1b"); strcpy(gP.fgHex, "#e8e6e3");
    // Declared at function scope: the log below sits outside the @try, and in
    // v5.65.0 these lived inside it, which would not compile.
    const char *srcPath = "(defaults only)";
    unsigned long nKeys = 0;
    @try {
        NSUserDefaults *u = [[NSUserDefaults alloc] initWithSuiteName:@(AD_PREF_DOMAIN)];
        NSDictionary *d = [u dictionaryRepresentation] ?: @{};
        // WHY THE SETTINGS TOGGLE DID NOTHING. Settings writes this domain
        // through cfprefsd, which lands in the REAL /var/mobile/Library/
        // Preferences -- not the /var/jb mirror this used to read, and the
        // NSUserDefaults suite above can come back empty inside Amazon's
        // sandbox. So the switch was writing somewhere the tweak never looked.
        // Read every plausible location, last one found wins, and derive the
        // jailbreak root from our own loaded image so no path is hardcoded.
        NSMutableArray *paths = [NSMutableArray array];
        [paths addObject:[NSString stringWithFormat:@"/var/jb/var/mobile/Library/Preferences/%s.plist", AD_PREF_DOMAIN]];
        @try {
            Dl_info info;
            if (dladdr((const void *)&ADLoadPrefs, &info) && info.dli_fname){
                NSString *img = [NSString stringWithUTF8String:info.dli_fname];
                NSRange jb = [img rangeOfString:@"/jb/"];
                if (jb.location != NSNotFound){
                    NSString *root = [img substringToIndex:jb.location + jb.length - 1];
                    [paths addObject:[NSString stringWithFormat:@"%@/var/mobile/Library/Preferences/%s.plist", root, AD_PREF_DOMAIN]];
                }
            }
        } @catch(...) {}
        [paths addObject:[NSString stringWithFormat:@"/var/mobile/Library/Preferences/%s.plist", AD_PREF_DOMAIN]];
        for (NSString *pp in paths){
            NSDictionary *fromFile = [NSDictionary dictionaryWithContentsOfFile:pp];
            if (fromFile.count){
                NSMutableDictionary *m = [d mutableCopy];
                [m addEntriesFromDictionary:fromFile];
                d = m;
                srcPath = pp.UTF8String;
            }
        }

        gP.enabled            = ADPrefBool(d, @"enabled",            gP.enabled);
        gP.webDarkReader      = ADPrefBool(d, @"webDarkReader",      gP.webDarkReader);
        gP.nativeTheme        = ADPrefBool(d, @"nativeTheme",        gP.nativeTheme);
        gP.imageBackdrop      = ADPrefBool(d, @"imageBackdrop",      gP.imageBackdrop);
        gP.imageKeyBackground = ADPrefBool(d, @"imageKeyBackground", gP.imageKeyBackground);
        gP.nativeRecolor      = ADPrefBool(d, @"nativeRecolor",      gP.nativeRecolor);
        gP.brightness         = ADPrefLong(d, @"brightness",         gP.brightness);
        gP.contrast           = ADPrefLong(d, @"contrast",           gP.contrast);
        gP.sepia              = ADPrefLong(d, @"sepia",              gP.sepia);
        gP.grayscale          = ADPrefLong(d, @"grayscale",          gP.grayscale);
        ADPrefHex(d, @"bgHex", "#181a1b", gP.bgHex);
        ADPrefHex(d, @"fgHex", "#e8e6e3", gP.fgHex);
        nKeys = (unsigned long)d.count;
    } @catch(...) {}
    ADSyncColorEngine();
    ADLog(@"prefs: src=%s keys=%lu", srcPath, nKeys);
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
// THE HOME-TAB VEIL, root-caused by the DOM probe:
//   IMG{filter=none, op=1, blend=multiply, bg=rgba(0,0,0,0)}
// Amazon sets mix-blend-mode:multiply on product images. Multiply is a no-op against
// white (x * 1 = x), so on Amazon's stock light page the images look untouched — but
// multiply against a DARK backdrop multiplies every pixel by that dark colour, so the
// photo is literally blended into the background. That is the "semi-transparent black
// overlay" over the products, and it explains why filter and opacity resets did
// nothing: neither was ever involved. Forcing mix-blend-mode:normal restores the
// images exactly. isolation:auto stops a parent stacking context re-introducing it.
//
// Fixes object passed as enable()'s 2nd argument. ignoreImageAnalysis:['*'] stops
// Dark Reader hiding / inverting / solid-filling images — the home-tab product veil.
// This is the web-side half of the project's core promise: never touch imagery.
//
// The css field is injected by Dark Reader as an authoritative override sheet
// (overrideStyle.textContent in dynamic-theme/index.ts), so it wins the cascade.
// We use it to undo the OTHER way Dark Reader can veil a photo: it runs
// modifyGradientColor() on every CSS gradient stop (a path entirely separate from
// image analysis), so a white→transparent scrim gradient laid over a hero image
// gets its stops darkened into a grey/black film. The rules below force any element
// that layers a gradient ON TOP of a background image to drop the gradient, and
// neutralise standalone overlay layers, without touching gradients used as real
// button or chip fills.
static NSString *ADFixesLiteral(void){
    // The image backdrop is only meaningful where an image has TRANSPARENT pixels:
    // a dark panel behind an opaque JPEG is completely hidden by the photo. So this
    // helps transparent PNGs (icons, cut-out product shots) and is a harmless no-op
    // everywhere else. It cannot darken white that is baked into a JPEG's pixels -
    // that needs real pixel work, which is a separate decision.
    NSString *imgBackdrop = gP.imageBackdrop
        ? [NSString stringWithFormat:@"img{background-color:%s !important;}", gP.bgHex]
        : @"";
    return [NSString stringWithFormat:
            @"{css:'"
             "img,picture,video,canvas,svg{filter:none !important;opacity:1 !important;"
             "mix-blend-mode:normal !important;isolation:auto !important;}"
             "%@"
             "[style*=\\\"background-image\\\"]{filter:none !important;}"
             // THE FIX THAT ACTUALLY WORKED, brought back. v5.27.0 whitened the heart
             // with a documentStart CSS rule and it visibly worked; v5.28.0 removed it
             // because [class*=heart-position] dragged the 32px disc into the whitening
             // (the white blob). Every JS attempt since lost a timing race CSS cannot
             // DARK CIRCLE, CHROME RING, WHITE SYMBOL -- the specified target for
             // both buttons, stated after the invert experiment: "circles with
             // chrome borders and white symbols". The disc is styled on the BUTTON
             // element across both card layouts (aria-label catches the grid
             // compare variant whose class family differs); the wrapper span is
             // explicitly flattened so nested matches cannot double-ring. Glyphs go
             // white by silhouette; the loading placeholder is hidden outright
             // because whitening a solid square asset produces a white box.
             "[class*=lists-framework-action-button],"
             "[class*=copilot-compare][class*=on-image-button],"
             "[class*=copilot-compare] [class*=on-image-button],"
             "[class*=s-product-image] button[aria-label*=ompare],"
             "[class*=puisg-col] [role=button][aria-label*=ompare]"
             "{background-color:#181a1b !important;border-radius:50%% !important;"
             "border:1.5px solid rgba(255,255,255,0.65) !important;"
             "box-shadow:none !important;box-sizing:border-box !important;}"
             "[class*=puis-heart-position]"
             "{background-color:transparent !important;border:0 !important;"
             "box-shadow:none !important;}"
             "[class*=lists-framework-action-button] img,"
             "[class*=lists-framework-action-button] i,"
             "[class*=lists-framework-action-button] svg,"
             "[class*=lists-framework-unfill],[class*=lists-framework-fill],"
             "[class*=copilot-compare] [class*=on-image-button] img,"
             "[class*=copilot-compare] [class*=on-image-button] i,"
             "[class*=copilot-compare] [class*=on-image-button] svg,"
             "[class*=copilot-compare][class*=on-image-button] img,"
             "[class*=copilot-compare][class*=on-image-button] i,"
             "[class*=copilot-compare][class*=on-image-button] svg,"
             "[class*=s-product-image] button[aria-label*=ompare] img,"
             "[class*=s-product-image] button[aria-label*=ompare] i,"
             "[class*=s-product-image] button[aria-label*=ompare] svg,"
             "[class*=puisg-col] [role=button][aria-label*=ompare] img,"
             "[class*=puisg-col] [role=button][aria-label*=ompare] i,"
             "[class*=puisg-col] [role=button][aria-label*=ompare] svg"
             "{filter:brightness(0) invert(1) !important;"
             "background-color:transparent !important;}"
             "[class*=puis-heart-position] [class*=placehold],[class*=heart-placeholder]"
             "{display:none !important;}"
             "[class*=lists-framework-action-button],"
             "[class*=lists-framework-action-button] *,"
             "[class*=copilot-compare] [class*=on-image-button] *,"
             "[class*=copilot-compare][class*=on-image-button] *"
             "{color:#ffffff !important;fill:#ffffff !important;}"

             // Home shortcut strips (Haul / Prime Video / Grocery...): brand
             // artwork sits on LIGHT pills, where the dark image backdrop reads
             // as a black box. Brand imgs keep a clean slate.
             // Chrome glyphs: no backdrop, ever. Sized rules cannot be expressed
             // in CSS, so cover the search/nav containers by name here and let the
             // JS pass above catch the rest by measured size.
             "[class*=nav-search] img,[class*=searchbar] img,[class*=search-bar] img,"
             "[role=search] img,[class*=nav-] img[class*=icon],[class*=header] img[class*=icon]"
             "{background-color:transparent !important;}"
             "img[alt*=\\\"Whole Foods\\\"],img[alt*=Prime],img[alt*=prime],img[alt*=Fresh],"
             "img[alt*=Haul],img[alt*=haul],img[alt*=Grocer],img[alt*=Luxury],img[alt*=Pharmac]"
             "{background-color:transparent !important;filter:none !important;}"
             // ISSUE 2: the read-more fade on long reviews is a white gradient
             // overlay; on the dark theme it reads as a white smear. Remove the
             // paint wholesale -- the expander still works, the text just ends.
             // THE CONTENT REGRESSION, AND MY FAULT. v5.54 put display:none in a
             // rule whose selector list included [class*=gradient] -- so every
             // element with "gradient" anywhere in its class was HIDDEN, and on
             // the home and cart pages that is real content, not scrim. Two
             // separate rules now: real elements only ever lose their PAINT,
             // and display:none is confined to pseudo-elements, which draw
             // nothing but the fade itself.
             "[class*=expander] [class*=fade],[class*=fade-out],"
             "[data-hook*=review] [class*=fade],[class*=expander-fade],"
             "[class*=a-reactive-container],[class*=reactive-contain]"
             "{background:transparent !important;background-image:none !important;"
             "box-shadow:none !important;}"
             "[class*=a-expander-partial]::before,[class*=a-expander-partial]::after,"
             "[class*=expander-content]::before,[class*=expander-content]::after,"
             "[class*=a-expander-partial-collapse-container]::after,"
             "[class*=a-expander-partial-collapse-container]::before,"
             "[data-hook*=review] [class*=expander]::after,"
             "[data-hook*=review] [class*=expander]::before,"
             "[class*=cr-] [class*=expander]::after,[class*=cr-] [class*=expander]::before,"
             "[class*=review] [class*=expander]::after,[class*=review] [class*=expander]::before"
             "{background:none !important;background-image:none !important;"
             "content:none !important;display:none !important;}"

             // Card skeletons. The light= probe names div.a-section@76x64 shells
             // that stay light through every pass -- they flash white where the
             // heart will be while the card hydrates. Empty shells carry no
             // content, so darkening them at documentStart cannot cover anything.
             "[class*=puis] [class*=a-section]:empty,[class*=s-result] [class*=a-section]:empty,"
             "[class*=s-card] [class*=a-section]:empty"
             "{background-color:#181a1b !important;}"

             // Promo/hero card header: no dark box behind it, and its title text
             // stays the stock dark (it sits on a light hero image).
             "[class*=a-cardui-header]{background-color:transparent !important;}"
             "[class*=a-cardui-header] [class*=sub-header-title-font],"
             "[class*=sub-header-title-font]"
             "{color:#0f1111 !important;-webkit-text-fill-color:#0f1111 !important;}"
             // Darkening blends crush their content toward black on a dark theme; the
             // deal badges use them inline. Neutralise at documentStart so the text is
             // legible on first paint instead of after the repair catches up.
             "[style*=multiply],[style*=darken],[style*=color-burn],"
             "[class*=deal] [style*=blend],[class*=Deal] [style*=blend]"
             "{mix-blend-mode:normal !important;isolation:auto !important;}"
             "',invert:[],ignoreInlineStyle:['[class*=puis-heart-position]','[class*=puis-heart-position] *',"
             "'[class*=lists-framework-action-button]','[class*=lists-framework-action-button] *',"
             "'[class*=copilot-compare]','[class*=copilot-compare] *'],"
             "ignoreImageAnalysis:['*'],disableStyleSheetsProxy:false}",
            imgBackdrop];
}

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
static dispatch_queue_t ADBootQueue(void){
    static dispatch_queue_t q; static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.amazondark.boot", DISPATCH_QUEUE_SERIAL); });
    return q;
}
static NSString *ADDarkReaderBootstrapBuild(void){
    NSString *dr = ADBundledDarkReaderJS();
    if (!dr.length) return nil;
    return [NSString stringWithFormat:
        @"(function(){try{"
         "if(window.__AMZDARK_LOADED__)return;window.__AMZDARK_LOADED__=1;"
         "try{window.__AD_EARLY__='';"
           "var __adPinRe=/unfill|placehold/i;"
           "var __adPin=function(n){try{"
             "if(!n||n.nodeType!==1)return;"
             "var c=n.className;if(c&&c.baseVal!==undefined)c=c.baseVal;c=String(c||'');"
             "if(__adPinRe.test(c)){n.style.setProperty('background-color','transparent','important');}"
             "if(String(c).indexOf('a-section')>=0&&n.closest&&"
               "n.closest('[class*=puis],[class*=s-result],[class*=s-card]')){"
               "n.style.setProperty('background-color','#181a1b','important');}"
             "if(n.querySelectorAll){var q=n.querySelectorAll('[class*=unfill],[class*=placehold]');"
               "for(var i=0;i<q.length;i++)q[i].style.setProperty('background-color','transparent','important');"
               "var q2=n.querySelectorAll('[class*=a-section]');"
               "for(var k2=0;k2<q2.length&&k2<200;k2++){var e2=q2[k2];"
                 "if(e2.closest&&e2.closest('[class*=puis],[class*=s-result],[class*=s-card]')){"
                   "e2.style.setProperty('background-color','#181a1b','important');}}}"
           "}catch(e){}};"
           "new MutationObserver(function(ms){for(var i=0;i<ms.length;i++){var m=ms[i];"
             "if(m.type==='attributes'){__adPin(m.target);continue;}"
             "for(var j=0;j<m.addedNodes.length;j++)__adPin(m.addedNodes[j]);}})"
             ".observe(document.documentElement,{childList:true,subtree:true,attributes:true,attributeFilter:['class']});"
           "var __adSnap=function(t){try{"
             "var u=document.querySelector('[class*=lists-framework-unfill]');"
             "var pp=document.querySelector('[class*=heart-placeholder]');"
             "var d=function(x){if(!x)return '-';var cs=getComputedStyle(x);"
               "return (cs.backgroundColor||'').replace(/ /g,'')+'/'+(cs.backgroundImage==='none'?'-':'Y')+'/'+String(cs.filter).slice(0,24);};"
             "window.__AD_EARLY__+=' t'+t+'[u:'+d(u)+'|p:'+d(pp)+']';"
           "}catch(e){}};"
           "setTimeout(function(){__adSnap(120);},120);"
           "setTimeout(function(){__adSnap(400);},400);"
           "setTimeout(function(){__adSnap(900);},900);"
         "}catch(e){}"
         "%@\n" // DarkReader UMD
         "if(window.DarkReader&&DarkReader.enable){"
         "try{DarkReader.setFetchMethod(window.fetch);}catch(e){}"
         // WCAG contrast repair. Dark Reader recolours from the page's own palette,
         // which can leave text only marginally separated from its background - the
         // '% off' badges and the descriptions under product photos being the
         // reported cases. This measures the real computed contrast of every element
         // that owns visible text and lifts ONLY the ones that actually fail, so
         // brand colours that already read fine are untouched.
         "window.__AMZDARK_FIXCONTRAST__=function(){try{"
           "var FG='%@';"
           "function ch(v){v=v/255;return v<=0.03928?v/12.92:Math.pow((v+0.055)/1.055,2.4);}"
           "function lum(c){var m=/rgba?\\((\\d+),\\s*(\\d+),\\s*(\\d+)(?:,\\s*([\\d.]+))?\\)/.exec(c);"
             "if(!m)return null;var a=m[4]===undefined?1:parseFloat(m[4]);if(a<0.1)return null;"
             "return 0.2126*ch(+m[1])+0.7152*ch(+m[2])+0.0722*ch(+m[3]);}"
           "function bgOf(e){while(e){var l=lum(getComputedStyle(e).backgroundColor);"
             "if(l!==null)return l;e=e.parentElement;}return 0.02;}"
           // Darkening blend modes are destructive on a dark theme: multiply/darken/
           // color-burn all SUBTRACT light, so against a dark backdrop they crush the
           // element toward black. That is what veiled the home tiles (fixed in v5.8.0
           // via CSS on media elements) and it is back on the explore pane because
           // there the blend mode sits on a CONTAINER, not the <img> - resetting the
           // child cannot undo a parent's blending of the whole composited subtree.
           // Neutralising by COMPUTED value catches it wherever it lives: img, div,
           // background-image element or wrapper. Lighten/screen/overlay are left
           // alone - they add light, which is harmless here.
           "var BAD={'multiply':1,'darken':1,'color-burn':1};"
           "function collect(root,out,depth){try{"
             "var list=root.querySelectorAll('*');"
             "for(var a=0;a<list.length;a++){var e=list[a];out.push(e);"
               // Shadow roots are separate trees: querySelectorAll stops at the host,
               // so anything Amazon builds inside one is unreachable from the document.
               "if(e.shadowRoot&&depth<4&&out.length<6000)collect(e.shadowRoot,out,depth+1);}"
             "}catch(e){}return out;}"
           "var els=collect(document.body,[],0),n=0,bfix=0,lfix=0,gfix=0,bigfix=0;"           // Read the themed background off <html> rather than plumbing another
           // format argument through two call sites.
           "var BG='rgb(24,26,27)';try{var hb=getComputedStyle(document.documentElement).backgroundColor;"
             "var hl=lum(hb);if(hl!==null&&hl<0.25)BG=hb;}catch(e){}"
           "var SKIP=/star|prime|logo|flag|swatch|thumb|sponsor|pill-image|product-image|photo|heart|wish|lists-framework|avatar|profile|author|reviewer|byline|merchant|seller|brand|store|logo-|-logo|headshot|user-image|customer/i;"           // Classes the probe confirmed are monochrome UI glyphs. These get a
           // looser size cap, because the heart measures 33x33 against a 32 limit and
           // was failing by a single pixel, while sbs-pill-image at 34x34 is a product
           // thumbnail that must keep its colour.
           "var ICON=/heart|wish|favor|lists-framework|a-icon|icon-|-icon|^_[a-z0-9]{4,8}_/i;"           // collect() walks document.body's DESCENDANTS, so <html> and <body>
           // themselves are never in els. A page that paints its own light background
           // on body -- Amazon Pharmacy's pink -- is invisible to every per-element
           // rule, and its inline/high-specificity value also overrides Dark Reader's
           // sheet. Darken them explicitly. Both solid and gradient forms.
           "try{var roots=[document.documentElement,document.body];"
             "for(var ri=0;ri<roots.length;ri++){var be=roots[ri];if(!be)continue;"
               "var bcs=getComputedStyle(be),bbl=lum(bcs.backgroundColor);"
               "if(bbl!==null&&bbl>0.4){be.style.setProperty('background-color',BG,'important');lfix++;}"
               "var bbi=bcs.backgroundImage||'';"
               "if(bbi.indexOf('gradient')>=0){var bmx=0,bm,bre=/rgba?\\((\\d+),\\s*(\\d+),\\s*(\\d+)/g;"
                 "while((bm=bre.exec(bbi))){var bl2=0.2126*ch(+bm[1])+0.7152*ch(+bm[2])+0.0722*ch(+bm[3]);"
                   "if(bl2>bmx)bmx=bl2;}"
                 "if(bmx>0.4){be.style.setProperty('background-image','none','important');"
                   "be.style.setProperty('background-color',BG,'important');lfix++;}}}"
           "}catch(e){}"
           "for(var i=0;i<els.length;i++){var el=els[i];"
             "var cs=getComputedStyle(el);"
             // NO LIGHT PANELS. Anything still measuring light after Dark Reader has
             // run is a miss -- a gradient it could not parse, a shadow subtree, an
             // inline style it skipped. Correct by COMPUTED value so the mechanism
             // does not matter. els is in document order, so an ancestor is darkened
             // before its children are contrast-checked against it.
             "if(lfix<500){var pl=lum(cs.backgroundColor);"
               "if(pl!==null&&pl>0.55){el.style.setProperty('background-color',BG,'important');lfix++;}}"
             // LARGE light panels, uncapped. Section-sized light surfaces (the
             // pharmacy pink wrapper, the light-blue insurance strip) are never
             // content -- darken them even after the general cap is spent.
             "if(bigfix<120){var plb=lum(cs.backgroundColor);"
               "if(plb!==null&&plb>0.55){var rb=el.getBoundingClientRect();"
                 "if(rb.width>=200&&rb.height>=80){"
                   "el.style.setProperty('background-color',BG,'important');bigfix++;}}}"
             // LIGHT GRADIENTS. lfix read 0 on every line while a 430x627 light panel
             // sat on screen, because a gradient lives in background-IMAGE and is
             // invisible to a backgroundColor check. The probe named it:
             // div.wd-backdrop-gradient, the 'Researched by Alexa' card. Parse the
             // stops and only neutralise gradients that actually resolve light, so
             // decorative dark gradients are left alone.
             "if(lfix<500){var gbi=cs.backgroundImage||'';"
               "if(gbi.indexOf('gradient')>=0&&el.closest){"
                 "try{if(el.closest('[data-hook*=review],[class*=a-expander],[class*=expander-partial]')){"
                   "el.style.setProperty('background-image','none','important');"
                   "el.style.setProperty('background','none','important');}}catch(e){}}"
               "if(gbi.indexOf('gradient')>=0){var g2=el.getBoundingClientRect();"
                 "if(g2.width>120&&g2.height>28){var gmx=0,gm,gre=/rgba?\\((\\d+),\\s*(\\d+),\\s*(\\d+)/g;"
                   "while((gm=gre.exec(gbi))){var gl2=0.2126*ch(+gm[1])+0.7152*ch(+gm[2])+0.0722*ch(+gm[3]);"
                     "if(gl2>gmx)gmx=gl2;}"
                   "if(gmx>0.55){el.style.setProperty('background-image','none','important');"
                     "el.style.setProperty('background-color',BG,'important');lfix++;}}}}"
             // SPRITE AND <img> GLYPHS -- the heart and the filter control.
             // ignoreImageAnalysis:['*'] switches off Dark Reader's dark-image
             // inversion (added in v5.4.0 to protect product photos) and the injected
             // img{filter:none} rule blocks it a second time, so a monochrome icon
             // shipped as an <img> or CSS sprite has nothing acting on it at all.
             // Forcing it white is safe at glyph size and beats measuring pixels,
             // which cannot work here: these come from m.media-amazon.com and would
             // taint a canvas. Inline !important outranks stylesheet !important, so
             // this wins over our own img{filter:none}.
             "if(gfix<160&&!el.__adGlyph){try{var gr=el.getBoundingClientRect();"
               "var cn2=el.className;if(cn2&&cn2.baseVal!==undefined)cn2=cn2.baseVal;"
               "cn2=(cn2||'').toString();"
               // textContent was the wrong test. Amazon's standard icon markup nests a
               // visually-hidden label -- <span class=a-icon><span class=a-icon-alt>Add
               // to list</span></span> -- so textContent is non-empty and the guard
               // rejected precisely the markup being targeted. That is why the filter
               // control (no nested label) went white and the heart did not. Only the
               // element's OWN direct text nodes should disqualify it.
               "var ot=false;for(var z=0;z<el.childNodes.length;z++){var nz=el.childNodes[z];"
                 "if(nz.nodeType===3&&nz.nodeValue&&nz.nodeValue.trim()){ot=true;break;}}"
               "var lim=ICON.test(cn2)?40:36;"
               "var inContent=false;try{inContent=!!(el.closest&&el.closest("
                 "'[data-hook*=review],[class*=review],[class*=profile],[class*=avatar],"
                 "[class*=author],[class*=byline],[class*=merchant],[class*=seller],"
                 "[class*=brand],[class*=store],[id*=review]'));}catch(e){}"
               // A real <img> carrying alt text is almost always content (an
               // avatar's alt is the person's name, a logo's is the brand). Icon
               // markup uses a nested a-icon-alt span, not the img's own alt, so
               // this does not catch the glyphs we actually want.
               "var isI=el.tagName.toLowerCase()==='img';"
               "var hasAlt=isI&&el.getAttribute&&(el.getAttribute('alt')||'').trim().length>1;"
               "if(gr.width>5&&gr.width<=lim&&gr.height>5&&gr.height<=lim&&!SKIP.test(cn2)&&!ot&&bgOf(el)<=0.5&&!inContent&&!hasAlt){"
                 "var hasB=cs.backgroundImage&&cs.backgroundImage!=='none';"
                 "if(isI||hasB){el.style.setProperty('filter','brightness(0) invert(1)','important');"
                   "el.__adGlyph=1;gfix++;}}"
             "}catch(e){}}"
             "if(el.tagName&&el.tagName.toLowerCase()==='img'&&lfix<500){"
               "var pw2=el.getBoundingClientRect();"
               // Glyph-sized art never needs a backdrop; the dark panel behind a
               // small search-bar icon is the black box, not a feature.
               "if(pw2.width>0&&pw2.width<=48&&pw2.height>0&&pw2.height<=48){"
                 "el.style.setProperty('background-color','transparent','important');}"
               // Any image sitting on a LIGHT surface -- promo cards, banners,
               // hero lockups like the pharmacy wordmark -- must not carry the
               // dark backdrop. No width cap: a wide logo needs this too.
               "else if(bgOf(el.parentElement||el)>0.06){"
                 "el.style.setProperty('background-color','transparent','important');}}"
             "try{if(lfix<500&&el.tagName){var tn3=el.tagName.toLowerCase();"
               "if(tn3!=='img'&&tn3!=='svg'&&tn3!=='canvas'){"
                 "var ownbl=lum(cs.backgroundColor);"
                 "if(ownbl!==null&&ownbl<0.25){"
                   "var pbl=bgOf(el.parentElement||el);"
                   // Surface is a distinct colour (teal) or light, and clearly
                   // lighter than the element's own near-black fill: our box, not
                   // a real chip. Margin of 0.12 keeps genuine dark-on-dark chips.
                   "if(pbl>0.12&&pbl>ownbl+0.12){el.style.setProperty('background-color','transparent','important');}}}}"
             "}catch(e){}"
             "if(BAD[cs.mixBlendMode]&&bfix<800){"
               "el.style.setProperty('mix-blend-mode','normal','important');"
               "el.style.setProperty('isolation','auto','important');bfix++;}"
             // SVG icons. Dark Reader recolours CSS 'color'; it does not touch the
             // fill/stroke PRESENTATION ATTRIBUTES that line-art icons use, so an
             // <svg fill="#000"> stays black on a themed page. Measured on device:
             // the X and recent-search glyphs sit at rgb(12,13,14) - actually darker
             // than the rgb(24,26,27) background - while text on the same page themed
             // correctly. Only dark fills are redirected, so multi-colour artwork and
             // brand marks keep their palette.
             "if(el.namespaceURI==='http://www.w3.org/2000/svg'){"
               "if(el.tagName.toLowerCase()==='svg'&&gfix<160&&!el.__adGlyph){"
                 "try{var sr3=el.getBoundingClientRect();"
                   "var sc3=el.className;if(sc3&&sc3.baseVal!==undefined)sc3=sc3.baseVal;sc3=(sc3||'').toString();"
                   "var slim=ICON.test(sc3)?44:40;"
                   "var SK2=/star|prime|logo|flag|swatch|thumb|sponsor|pill-image|product-image|photo/i;"
                   "if(sr3.width>5&&sr3.width<=slim&&sr3.height>5&&sr3.height<=slim&&!SK2.test(sc3)){"
                     "el.style.setProperty('filter','brightness(0) invert(1)','important');el.__adGlyph=1;gfix++;}"
                 "}catch(e){}}"
               "var fl2=lum(cs.fill),sl=lum(cs.stroke);"
               "if(fl2!==null&&fl2<0.45){el.style.setProperty('fill',FG,'important');n++;}"
               "if(sl!==null&&sl<0.45){el.style.setProperty('stroke',FG,'important');n++;}"
             "}"
             // ICON FONTS / PSEUDO-ELEMENT GLYPHS. The text pass below requires a
             // literal child text node, and a ::before glyph has none - the character
             // lives in generated content. So an icon font renders in the element's
             // own dark `color` and nothing above ever looks at it. This is the single
             // most likely reason autocomplete reports 0/0 while its clock and X
             // glyphs sit there black.
             "function hasC(p){if(!p)return false;var c=p.content;"
               "if(!c||c==='none'||c==='normal')return false;return c.length>2;}"
             "try{var pb=getComputedStyle(el,'::before'),pa=getComputedStyle(el,'::after');"
               "if((hasC(pb)||hasC(pa))&&n<400){var pcl=lum(cs.color);"
                 "if(pcl!==null&&pcl<0.50){el.style.setProperty('color',FG,'important');n++;}}"
             "}catch(e){}"
             // MASK-IMAGE ICONS. The mask is the shape; the visible colour is the
             // element's background-color. Dark Reader treats that as a background and
             // darkens it, which paints the glyph in the page background colour - i.e.
             // makes it vanish rather than merely stay dark.
             "try{var mi=cs.webkitMaskImage||cs.maskImage;"
               "if(mi&&mi!=='none'&&n<400){var mbl=lum(cs.backgroundColor);"
                 "if(mbl!==null&&mbl<0.55){el.style.setProperty('background-color',FG,'important');n++;}}"
             "}catch(e){}"
             "try{if(n<400){var g3=el.getBoundingClientRect();"
               "if(g3.width>5&&g3.width<=40&&g3.height>5&&g3.height<=40){"
                 "var bw2=parseFloat(cs.borderTopWidth)||parseFloat(cs.borderLeftWidth)||0;"
                 "if(bw2>=1.5){var bcl=lum(cs.borderTopColor||cs.borderLeftColor);"
                   "if(bcl!==null&&bcl<0.35){var ot2=false;"
                     "for(var z2=0;z2<el.childNodes.length;z2++){var nz2=el.childNodes[z2];"
                       "if(nz2.nodeType===3&&nz2.nodeValue&&nz2.nodeValue.trim()){ot2=true;break;}}"
                     "if(!ot2){el.style.setProperty('border-color',FG,'important');n++;}}}}}"
             "}catch(e){}"
             "if(n>=400)continue;"
             "var t=false;"
             "for(var k=0;k<el.childNodes.length;k++){var nd=el.childNodes[k];"
               "if(nd.nodeType===3&&nd.nodeValue&&nd.nodeValue.trim()){t=true;break;}}"
             "if(!t)continue;"
             "var fl=lum(cs.color);if(fl===null)continue;"
             // Text overlaid on a promo/hero IMAGE keeps its own colour. Catches
             // both a CSS url() background and an <img>/<picture> that actually
             // OVERLAPS this text (product titles sit BELOW their image, so they
             // do not overlap and are still themed normally).
             "var overImg=false;"
             "try{var tr=el.getBoundingClientRect();var pe2=el,pd2=0;"
               "var ovl=function(ir){return ir.width>=100&&ir.height>=100"
                 "&&ir.left<tr.right&&ir.right>tr.left&&ir.top<tr.bottom&&ir.bottom>tr.top;};"
               "while(pe2&&pd2++<10){var pcs2=getComputedStyle(pe2);"
                 "if((pcs2.backgroundImage||'').indexOf('url(')>=0){overImg=true;break;}"
                 "var ims=pe2.querySelectorAll?pe2.querySelectorAll('img,picture,video'):[];"
                 "for(var qi=0;qi<ims.length;qi++){if(ovl(ims[qi].getBoundingClientRect())){overImg=true;break;}}"
                 "if(overImg)break;"
                 "var sib=pe2.previousElementSibling,sc=0;"
                 "while(sib&&sc++<4){if(/^(img|picture|video)$/i.test(sib.tagName)&&ovl(sib.getBoundingClientRect())){overImg=true;break;}"
                   "var si=sib.querySelectorAll?sib.querySelectorAll('img,picture,video'):[];"
                   "for(var sj=0;sj<si.length;sj++){if(ovl(si[sj].getBoundingClientRect())){overImg=true;break;}}"
                   "if(overImg)break;sib=sib.previousElementSibling;}"
                 "if(overImg||lum(pcs2.backgroundColor)!==null)break;"
                 "pe2=pe2.parentElement;}}catch(e){}"
             "if(overImg){"
               "try{if(!window.__AD_PROMO__&&el.getBoundingClientRect().width>70){"
                 "var pcn=el.className;if(pcn&&pcn.baseVal!==undefined)pcn=pcn.baseVal;"
                 "var par=el.parentElement,pp='';if(par){var pc=par.className;if(pc&&pc.baseVal!==undefined)pc=pc.baseVal;pp=String(pc||'').split(' ')[0];}"
                 "window.__AD_PROMO__=el.tagName.toLowerCase()+'.'+String(pcn||'').split(' ')[0].slice(0,34)"
                   "+'^'+pp.slice(0,28)+'/'+cs.color;}}catch(e){}"
               "if(lum(cs.color)!==null&&lum(cs.color)>0.5)"
                 "el.style.setProperty('color','#0f1111','important');continue;}"
             "var bl=bgOf(el);var hi=Math.max(fl,bl)+0.05,lo=Math.min(fl,bl)+0.05;"
             "if(hi/lo<3.0){el.style.setProperty('color',FG,'important');n++;}}"

           // Clear stray dark square wrappers around the buttons (the box that
           // can extend past the pill). Shapes/borders are persistent CSS above.
           "try{var AIC=document.querySelectorAll('[class*=a-icon]');"
             "for(var ai=0;ai<AIC.length&&ai<500;ai++){var ae=AIC[ai];"
               "var acn=ae.className;if(acn&&acn.baseVal!==undefined)acn=acn.baseVal;acn=String(acn||'');"
               "if(/star|prime|logo|flag|swatch|thumb|sponsor|product|photo|-alt|toggle|switch|checkbox|heart|wish|lists-framework|copilot-compare/i.test(acn))continue;"
               "var acs=getComputedStyle(ae),abf=getComputedStyle(ae,'::before'),aba=getComputedStyle(ae,'::after');"
               "var abi=acs.backgroundImage||acs.webkitMaskImage||acs.maskImage"
                 "||abf.backgroundImage||abf.webkitMaskImage||abf.maskImage"
                 "||aba.backgroundImage||aba.webkitMaskImage||aba.maskImage;"
               "if(!abi||abi==='none'||abi.indexOf('url(')<0)continue;"
               "if(ae.closest&&ae.closest('[class*=heart],[class*=wish],[class*=lists-framework],[class*=copilot-compare]'))continue;"
               "var ar=ae.getBoundingClientRect();"
               "if(ar.width>5&&ar.width<=60&&ar.height>5&&ar.height<=60){"
                 "ae.style.setProperty('filter','brightness(0) invert(1)','important');ae.__adGlyph=1;}}"
           "}catch(e){}"
           "try{var CDU=document.querySelectorAll('[class*=cardui],[class*=Cardui]');"
             "for(var di=0;di<CDU.length&&di<20;di++){var card=CDU[di];"
               "var cr=card.getBoundingClientRect();if(cr.width<120||cr.height<80)continue;"
               "if(bgOf(card)<0.4)continue;"
               "var kids=card.querySelectorAll('*');"
               "for(var ki=0;ki<kids.length&&ki<250;ki++){var kd=kids[ki];"
                 "var kbl=lum(getComputedStyle(kd).backgroundColor);"
                 "if(kbl===null||kbl>=0.25)continue;"
                 "var kr=kd.getBoundingClientRect();"
                 "if(kr.width>=cr.width*0.96&&kr.height>=cr.height*0.96)continue;"
                 "kd.style.setProperty('background-color','transparent','important');}}"
           "}catch(e){}"
           "try{var PRM=document.querySelectorAll('[class*=sub-header-title-font]');"
             "for(var pi=0;pi<PRM.length&&pi<40;pi++){var pt=PRM[pi];"
               "pt.style.setProperty('color','#0f1111','important');"
               "pt.style.setProperty('-webkit-text-fill-color','#0f1111','important');"
               // clear dark background boxes on the header ancestors
               "var pa=pt,pd=0;"
               "while(pa&&pd++<5){var pac=getComputedStyle(pa),pal=lum(pac.backgroundColor);"
                 "if(pal!==null&&pal<0.3)pa.style.setProperty('background-color','transparent','important');"
                 "pa=pa.parentElement;}}"
           "}catch(e){}"
           "try{var WG=function(root){if(!root||!root.querySelectorAll)return;"
               "var gl=root.querySelectorAll('*');"
               "for(var wi=0;wi<gl.length&&wi<90;wi++){var g=gl[wi];"
                 "var gr=g.getBoundingClientRect();"
                 "if(gr.width<4||gr.width>40||gr.height<4||gr.height>40)continue;"
                 "var gsty=getComputedStyle(g),gtg=(g.tagName||'').toLowerCase();"
                 "if(g.namespaceURI==='http://www.w3.org/2000/svg'){"
                   "g.style.setProperty('fill',FG,'important');"
                   "g.style.setProperty('stroke',FG,'important');continue;}"
                 "var gbi=gsty.backgroundImage,gmi=gsty.webkitMaskImage||gsty.maskImage;"
                 "var gbf=getComputedStyle(g,'::before'),gaf=getComputedStyle(g,'::after');"
                 "var sprite=(gbi&&gbi.indexOf('url(')>=0)"
                   "||(gbf.backgroundImage&&gbf.backgroundImage.indexOf('url(')>=0)"
                   "||(gaf.backgroundImage&&gaf.backgroundImage.indexOf('url(')>=0);"
                 "var mask=(gmi&&gmi!=='none')"
                   "||(gbf.webkitMaskImage&&gbf.webkitMaskImage!=='none')"
                   "||(gbf.maskImage&&gbf.maskImage!=='none');"
                 "if(gtg==='img'||sprite){g.style.setProperty('filter','brightness(0) invert(1)','important');continue;}"
                 "if(mask){g.style.setProperty('background-color',FG,'important');continue;}"
                 "var pc=(gbf.content&&gbf.content!=='none'&&gbf.content!=='normal')"
                   "||(gaf.content&&gaf.content!=='none'&&gaf.content!=='normal');"
                 "var wtx=false;for(var wz=0;wz<g.childNodes.length;wz++){var wn=g.childNodes[wz];"
                   "if(wn.nodeType===3&&wn.nodeValue&&wn.nodeValue.trim()){wtx=true;break;}}"
                 "if(pc){var pcl=lum(gsty.color);if(pcl!==null&&pcl<0.6)g.style.setProperty('color',FG,'important');continue;}"
                 "if(!g.children.length&&!wtx&&gr.width<=14&&gr.height<=14){"
                   "var dbl=lum(gsty.backgroundColor);"
                   "if(dbl!==null&&dbl<0.5){g.style.setProperty('background-color',FG,'important');continue;}}}"
             "};"
             "var WGT=document.querySelectorAll("
               "'[class*=sc-nested-actions]');"
             "for(var wti=0;wti<WGT.length&&wti<40;wti++)WG(WGT[wti]);"
           "}catch(e){}"

           // One-shot probe. Two builds have now been spent inferring what paints
           // these glyphs from what does NOT move. Cheaper to just ask the DOM: report
           // the first few icon-sized elements and which mechanism draws each, so the
           // next change targets a known selector instead of a guess.
           // The one-shot flag was the bug: __AMZDARK_APPLY__ calls this once at
           // bootstrap and DISCARDS the result, so the probe was always spent before
           // the first logged invocation. Compute once, cache, return every time.
           // Caching fixed the "consumed at bootstrap" bug but introduced its twin:
           // the bootstrap call runs against a near-empty DOM, found nothing, and
           // cached THAT. Hence probe=none while gfix was busy matching elements.
           // Only cache a result that actually found something; keep retrying until
           // one does.
           // NO CACHE. Cached-once has now been wrong twice: spent on the bootstrap
           // DOM, then locked to an early snapshot holding only the filter icon while
           // the product cards had not rendered. Recompute every call -- it is two
           // bounded scans behind a 400ms debounce -- so the log always describes the
           // DOM as it stands right now.
           "var pr='';try{{"
             "var seen={},acc=[];"
             "for(var q=0;q<els.length&&acc.length<14;q++){var pe=els[q];"
               "var rc=pe.getBoundingClientRect();"
               "if(rc.width<6||rc.width>40||rc.height<6||rc.height>40)continue;"
               "if(pe.children.length>2)continue;"
               "var pcs=getComputedStyle(pe),tg=pe.tagName.toLowerCase(),kind='';"
               "var pbi=pcs.backgroundImage,pmi=pcs.webkitMaskImage||pcs.maskImage;"
               "var ppb=getComputedStyle(pe,'::before');"
               "if(tg==='img')kind='img';"
               "else if(pmi&&pmi!=='none')kind='mask';"
               "else if(pbi&&pbi!=='none')kind='bgimg';"
               "else if(hasC(ppb))kind='pseudo';"
               "else if(pe.namespaceURI==='http://www.w3.org/2000/svg')kind='svg';"
               "else continue;"
               "var cn=pe.className;if(cn&&cn.baseVal!==undefined)cn=cn.baseVal;"
               "cn=(cn||'').toString().split(' ')[0].slice(0,22);"
               "var k=kind+'.'+cn;if(seen[k])continue;seen[k]=1;"
               "acc.push(k+'@'+Math.round(rc.width)+'x'+Math.round(rc.height)+'/'+pcs.color"
                 "+'/f:'+((pcs.filter&&pcs.filter!=='none')?'Y':'-'));}"
             // also name whatever is still LIGHT, which is what the Alexa card is
             "var lt=[];for(var w=0;w<els.length&&lt.length<3;w++){var le=els[w];"
               "var lcs=getComputedStyle(le),ll=lum(lcs.backgroundColor);"
               // lfix has read 0 on every line, so whatever is still light is not a
               // backgroundColor. A gradient is the obvious candidate and is invisible
               // to lum(), so report those too rather than keep guessing at the pane.
               "var lgi=lcs.backgroundImage||'';var lgr=lgi.indexOf('gradient')>=0;"
               "if(!lgr&&(ll===null||ll<=0.55))continue;var lr=le.getBoundingClientRect();"
               "if(lr.width<60||lr.height<20)continue;"
               "var lc=le.className;if(lc&&lc.baseVal!==undefined)lc=lc.baseVal;"
               "lt.push(le.tagName.toLowerCase()+'.'+(lc||'').toString().split(' ')[0].slice(0,18)"
                 "+'@'+Math.round(lr.width)+'x'+Math.round(lr.height));}"
             // Targeted: name the heart's markup directly instead of hoping it lands
             // in the first N icon-sized elements.
             "var ht=[];try{var hq=document.querySelectorAll("
               "'[class*=heart],[class*=wish],[class*=favor],[aria-label*=list],[aria-label*=List]');"
               "for(var y=0;y<hq.length&&ht.length<4;y++){var he=hq[y];"
                 "var hr=he.getBoundingClientRect();if(hr.width<4)continue;"
                 "var hcs=getComputedStyle(he),hk='plain';"
                 "var hbi=hcs.backgroundImage,hmi=hcs.webkitMaskImage||hcs.maskImage;"
                 "if(he.tagName.toLowerCase()==='img')hk='img';"
                 "else if(hmi&&hmi!=='none')hk='mask';"
                 "else if(hbi&&hbi!=='none')hk='bgimg';"
                 "else if(he.namespaceURI==='http://www.w3.org/2000/svg')hk='svg';"
                 "var hc=he.className;if(hc&&hc.baseVal!==undefined)hc=hc.baseVal;"
                 "ht.push(hk+'.'+(hc||'').toString().split(' ')[0].slice(0,20)"
                   "+'@'+Math.round(hr.width)+'x'+Math.round(hr.height)"
                   "+'/f:'+(hcs.fill||'-')+'/c:'+hcs.color);}}catch(e){}"
             // Full subtree of the first heart container, so we stop inferring which
             // node draws the glyph. Widened after the 10-node cap cut the walk off
             // exactly where the glyph should live (the children of the 32x32
             // lists-framework span were nodes 11+): 24 nodes, ::after as well as
             // ::before, pseudo paint sources, and the tail of any <img> src, which
             // names the artwork outright.
             "var htree='';try{var HB=document.querySelector('[class*=heart],[class*=wish],[class*=lists-framework]');"
               "if(HB){var top=HB,up=0;"
                 "while(top.parentElement&&up++<3){var pp2=top.parentElement;"
                   "var pr3=pp2.getBoundingClientRect();if(pr3.width>48||pr3.height>48)break;top=pp2;}"
                 "var stk=[top],hd=[],gd=0;"
                 "var pc2=function(p){return !!(p&&p.content&&p.content!=='none'&&p.content!=='normal');};"
                 "var pi2=function(p){return !!(p&&p.backgroundImage&&p.backgroundImage!=='none');};"
                 "var pm2=function(p){return !!(p&&((p.webkitMaskImage||p.maskImage||'none')!=='none'));};"
                 "while(stk.length&&hd.length<24&&gd++<300){var nd=stk.shift();"
                   "var ncs=getComputedStyle(nd),nrr=nd.getBoundingClientRect();"
                   "var nbb=getComputedStyle(nd,'::before'),naa=getComputedStyle(nd,'::after');"
                   "var cn3=nd.className;if(cn3&&cn3.baseVal!==undefined)cn3=cn3.baseVal;"
                   "var sr2='';if(nd.tagName.toLowerCase()==='img'){"
                     "sr2=(nd.currentSrc||nd.src||'').split('?')[0];sr2='|src='+(sr2?sr2.slice(-26):'-');}"
                   "hd.push(nd.tagName.toLowerCase()+'.'+String(cn3||'').split(' ')[0].slice(0,24)"
                     "+'@'+Math.round(nrr.width)+'x'+Math.round(nrr.height)"
                     "+'|top'+Math.round(nrr.top-bt)"
                     "+'|bg='+ncs.backgroundColor.replace(/ /g,'')"
                     "+'|bgi='+(ncs.backgroundImage==='none'?'-':'Y')"
                     "+'|mask='+(((ncs.webkitMaskImage||ncs.maskImage||'none')==='none')?'-':'Y')"
                     "+'|bef='+(pc2(nbb)?'Y':'-')+'|aft='+(pc2(naa)?'Y':'-')"
                     "+'|pbgi='+(((pi2(nbb)?'b':'')+(pi2(naa)?'a':''))||'-')"
                     "+'|pmsk='+(((pm2(nbb)?'b':'')+(pm2(naa)?'a':''))||'-')"
                     "+'|flt='+ncs.filter+sr2);"
                   "for(var ci2=0;ci2<nd.children.length;ci2++)stk.push(nd.children[ci2]);}"
                 "htree=' HEARTTREE='+hd.join(' ~ ');}"
             "}catch(e){}"
             "var fd=[];try{var FQ=document.querySelectorAll("
               "'[class*=a-expander] *,[data-hook*=review] *');"
               "for(var y2=0;y2<FQ.length&&y2<250&&fd.length<3;y2++){var fe2=FQ[y2];"
                 "var c2=getComputedStyle(fe2),b2=c2.backgroundImage||'';"
                 "var pa2=getComputedStyle(fe2,'::after'),pb2=getComputedStyle(fe2,'::before');"
                 "var pab=(pa2&&pa2.backgroundImage!=='none')?pa2.backgroundImage:"
                   "((pb2&&pb2.backgroundImage!=='none')?pb2.backgroundImage:'');"
                 "var src2=(b2.indexOf('gradient')>=0)?b2:((pab.indexOf('gradient')>=0)?('PSEUDO:'+pab):'');"
                 "if(!src2){var lb2=lum(c2.backgroundColor);"
                   "if(lb2!==null&&lb2>0.5)src2='LIGHTBG:'+c2.backgroundColor;}"
                 "if(!src2)continue;"
                 "var r2=fe2.getBoundingClientRect();"
                 "var cn4=fe2.className;if(cn4&&cn4.baseVal!==undefined)cn4=cn4.baseVal;"
                 "fd.push(fe2.tagName.toLowerCase()+'.'+String(cn4||'').split(' ')[0].slice(0,22)"
                   "+'@'+Math.round(r2.width)+'x'+Math.round(r2.height)+'|'+src2.slice(0,46));}"
             "}catch(e){}"
             "var btree='';try{"
               "var findBtn=function(sel){var q=document.querySelectorAll(sel);"
                 "for(var z=0;z<q.length;z++){var rr=q[z].getBoundingClientRect();"
                   "if(rr.width>20&&rr.height>20)return q[z];}return null;};"
               "var dumpBtn=function(el,tag){if(!el)return '';var top=el,up=0;"
                 "var bt=el.getBoundingClientRect().top;"
                 "if(/ompare/i.test(tag)){top=el.parentElement||el;}"
                 "else{while(top.parentElement&&up++<6)top=top.parentElement;}"
                 "var stk=[top],out=[],gd=0;"
                 "while(stk.length&&out.length<14&&gd++<120){var nd=stk.shift();"
                   "var cs=getComputedStyle(nd),rc=nd.getBoundingClientRect();"
                   "var cn=nd.className;if(cn&&cn.baseVal!==undefined)cn=cn.baseVal;"
                   "out.push(nd.tagName.toLowerCase()+'.'+String(cn||'').split(' ')[0].slice(0,30)"
                     "+'@'+Math.round(rc.width)+'x'+Math.round(rc.height)"
                     "+'|bg='+cs.backgroundColor.replace(/ /g,'')"
                     "+'|rad='+(parseFloat(cs.borderTopLeftRadius)||0)"
                     "+'|bgi='+(cs.backgroundImage==='none'?'-':'Y'));"
                   "for(var ci=0;ci<nd.children.length;ci++)stk.push(nd.children[ci]);}"
                 "return ' '+tag+'='+out.join(' ~ ');};"
               "btree=dumpBtn(findBtn('[aria-label*=ompare],[class*=compare],[data-csa-c-content-id*=ompare]'),'CMPTREE')"
                 "+dumpBtn(findBtn('[class*=heart],[class*=wish]'),'HRTBTN');"
             "}catch(e){}"
             "try{var desc=function(n){if(!n)return'';var nr=n.getBoundingClientRect();"
                 "var ncs=getComputedStyle(n),ntg=(n.tagName||'').toLowerCase(),nk='plain';"
                 "var nbi=ncs.backgroundImage,nmi=ncs.webkitMaskImage||ncs.maskImage,nbf=getComputedStyle(n,'::before');"
                 "if(ntg==='img')nk='img';else if(nmi&&nmi!=='none')nk='mask';"
                 "else if(nbi&&nbi!=='none')nk='bgimg';"
                 "else if(nbf.backgroundImage&&nbf.backgroundImage!=='none')nk='pre-bg';"
                 "else if(nbf.content&&nbf.content!=='none'&&nbf.content!=='normal')nk='pre-txt';"
                 "else if(n.namespaceURI==='http://www.w3.org/2000/svg')nk='svg';"
                 "var nc=n.className;if(nc&&nc.baseVal!==undefined)nc=nc.baseVal;"
                 "return ntg+'.'+String(nc||'').split(' ')[0].slice(0,16)+'|'+nk"
                   "+'@'+Math.round(nr.width)+'x'+Math.round(nr.height)"
                   "+'|f:'+((ncs.filter&&ncs.filter!=='none')?'Y':'-')"
                   "+'|fl:'+String(ncs.fill||'-').replace(/ /g,'').slice(0,10)"
                   "+'|c:'+ncs.color.replace(/ /g,'');};"
               "var KBQ=document.querySelectorAll("
               "'[aria-label*=More],[aria-label*=more],[aria-label*=ptions],[aria-label*=verflow],"
               "[class*=sc-nested-actions],[class*=overflow],[class*=kebab],[class*=ellipsis]');"
               "for(var kq=0;kq<KBQ.length;kq++){var ke=KBQ[kq];"
                 "var kr=ke.getBoundingClientRect();if(kr.width<10||kr.width>48||kr.height<10||kr.height>48)continue;"
                 "var kb=[desc(ke)],kk2=ke.querySelectorAll('*');"
                 "for(var ki2=0;ki2<kk2.length&&kb.length<7;ki2++)kb.push(desc(kk2[ki2]));"
                 "window.__AD_KEBAB__=kb.join(' > ');break;}"
               "var CBQ=document.querySelectorAll('[class*=copilot-compare]');"
               "var cb=[];for(var cq=0;cq<CBQ.length&&cb.length<6;cq++){var cbe=CBQ[cq];"
                 "var cbr=cbe.getBoundingClientRect();if(cbr.width<6||cbr.width>40||cbr.height<6||cbr.height>40)continue;"
                 "cb.push(desc(cbe));}"
               "if(cb.length)window.__AD_CMPBAR__=cb.join(' ~ ');"
             "}catch(e){}"
             "try{var CXB=document.querySelectorAll('[class*=on-image-button]');var cxt=null;"
               "for(var cx=0;cx<CXB.length;cx++){var cxe=CXB[cx];"
                 "var cxcl=cxe.className;if(cxcl&&cxcl.baseVal!==undefined)cxcl=cxcl.baseVal;cxcl=String(cxcl||'');"
                 "if(/compare/i.test(cxcl)||(cxe.closest&&cxe.closest('[class*=copilot-compare]'))){cxt=cxe;break;}}"
               "if(cxt){var cxa=[],node=cxt,cbr=cxt.getBoundingClientRect(),up=0;"
                 "while(node&&up++<5){var ncs=getComputedStyle(node),nr=node.getBoundingClientRect();"
                   "var ncl=node.className;if(ncl&&ncl.baseVal!==undefined)ncl=ncl.baseVal;"
                   "cxa.push(node.tagName.toLowerCase()+'.'+String(ncl||'').split(' ')[0].slice(0,20)"
                     "+'|top'+Math.round(nr.top-cbr.top)+'|h'+Math.round(nr.height)"
                     "+'|bg='+ncs.backgroundColor.replace(/ /g,'')"
                     "+'|bgi='+(ncs.backgroundImage==='none'?'-':'Y')"
                     "+'|sh='+(ncs.boxShadow==='none'?'-':ncs.boxShadow.replace(/ /g,'').slice(0,26)));"
                   "node=node.parentElement;}"
                 "window.__AD_CMPX__=cxa.join(' > ');}"
             "}catch(e){}"
             "pr=' url='+String(location.pathname||'').slice(0,28)"
               "+(window.__AD_CMPX__?(' CMPX='+window.__AD_CMPX__):'')"
               "+(window.__AD_KEBAB__?(' KEBAB='+window.__AD_KEBAB__):'')"
               "+(window.__AD_CMPBAR__?(' CMPBAR='+window.__AD_CMPBAR__):'')"
               "+(window.__AD_PROMO__?(' PROMO='+window.__AD_PROMO__):'')"
               "+btree"
               "+(fd.length?(' FADE='+fd.join(' ~ ')):' FADE=none')"
               "+(window.__AD_EARLY__?(' EARLY='+window.__AD_EARLY__):'')"
               "+(acc.length?(' probe='+acc.join(' ')):' probe=none')"
               "+(lt.length?(' light='+lt.join(' ')):'')"
               "+(ht.length?(' HEART='+ht.join(' ')):'')+htree;}"
           "}catch(e){pr=' probeERR';}"
           "return n+'/'+bfix+'/'+lfix+'/'+gfix+'/'+bigfix+pr;}catch(e){return -1;}};"
         "window.__AMZDARK_APPLY__=function(){try{"
           "if(!document.querySelector('style.darkreader'))DarkReader.enable(%@,%@);"
           "window.__AMZDARK_FIXCONTRAST__();"
         "}catch(e){}};"
         // Re-run the repair as the page fills in (carousels, lazy tiles), debounced
         // so a busy DOM cannot turn this into a hot loop.
         "try{var _t=null;new MutationObserver(function(){clearTimeout(_t);"
           "_t=setTimeout(function(){try{window.__AMZDARK_FIXCONTRAST__();}catch(e){}},150);})"
           ".observe(document.documentElement,{childList:true,subtree:true});}catch(e){}"
         "window.__AMZDARK_APPLY__();"
         // Fast early passes so promo text / buttons are corrected before the
         // eye registers Dark Reader's first-paint colours. One-shot, bounded.
         "try{[30,90,180,320,600].forEach(function(t){setTimeout(function(){"
           "try{window.__AMZDARK_FIXCONTRAST__();}catch(e){}},t);});}catch(e){}"
         // Re-apply when the page is restored from the back-forward cache (returning
         // to a tab). pageshow.persisted is true exactly in that case, and it is the
         // event that fires when no navigation happens — the cart's "went white on
         // return" path. Also re-assert on visibility regain.
         "try{window.addEventListener('pageshow',function(e){if(e.persisted)window.__AMZDARK_APPLY__();});}catch(e){}"
         "try{document.addEventListener('visibilitychange',function(){if(!document.hidden)window.__AMZDARK_APPLY__();});}catch(e){}"
         "}}catch(e){}})();",
        dr, [NSString stringWithUTF8String:gP.fgHex], ADThemeLiteral(), ADFixesLiteral()];
}
static NSString *ADDarkReaderBootstrap(void){
    __block NSString *out = nil;
    dispatch_sync(ADBootQueue(), ^{
        if (!gADBootCache) gADBootCache = ADDarkReaderBootstrapBuild();
        out = gADBootCache;
    });
    return out;
}

// LIGHT: re-apply the theme. MUST be a no-op when the page is already themed.
//
// This previously ran DarkReader.disable() whenever style.darkreader was missing,
// then re-enabled. That call strips Dark Reader's stylesheet, so the page snaps to
// stock white before going dark again — and because the burst fires it repeatedly
// (0/60/200/500ms on every viewDidAppear, plus each sweep), the home tab visibly
// flashed white/dark/white. It was added to fix the cart, but the cart's real cause
// was 'noflag' (the user script never ran in that document), which the self-heal
// below handles. So the disable() was solving a problem that did not exist while
// creating one that did. Removed.
//
// Now: if the stylesheet is present the page is themed and we touch nothing.
// LIGHT: re-apply. Skipping DarkReader.enable() when the page is already themed is
// what stopped the white flashing in v5.5.1 and must stay — but the REPAIR passes
// must not inherit that early return.
//
// They did, and it made three builds' worth of work inert. The SVG fill fix, the
// contrast lifting and the shadow-DOM traversal all live inside
// __AMZDARK_FIXCONTRAST__, and this function returned before reaching it whenever
// style.darkreader was present. On the search pane — which IS themed, its
// recent-search text being correctly light — the native burst therefore did nothing
// at all, which is exactly why those icons and labels never changed.
//
// So: enable() stays conditional, the repair runs every time. It is idempotent
// (it only rewrites values that currently fail) and cheap on a settled page.
static NSString *ADDarkReaderReapply(void){
    return [NSString stringWithFormat:
        @"(function(){try{"
         "if(!(window.DarkReader&&DarkReader.enable))return 'noDR';"
         "if(!document.querySelector('style.darkreader'))DarkReader.enable(%@,%@);"
         "if(window.__AMZDARK_FIXCONTRAST__)return ''+window.__AMZDARK_FIXCONTRAST__();"
         "return 'nofix';"
         "}catch(e){return 'err';}})();",
        ADThemeLiteral(), ADFixesLiteral()];
}

static void ADBootstrapDarkReaderIn(WKWebView *wv);
static const void *kADBootedKey = &kADBootedKey;
static const void *kADUSKey = &kADUSKey;
static int gLoadLog = 12;
// Add our documentStart engine user-script to a webview's config if it is not
// already there. Called from the load hooks so it lands BEFORE the navigation
// -- the only timing that reaches loadHTMLString/loadData content and child
// frames. Safe to call repeatedly (guarded per webview).
static void ADEnsureUserScript(WKWebView *wv){
    @try {
        if (!gP.enabled || !gP.webDarkReader || !wv) return;
        if (objc_getAssociatedObject(wv, kADUSKey)) return;
        NSString *js = ADDarkReaderBootstrap();
        Class WKUS = NSClassFromString(@"WKUserScript");
        WKUserContentController *ucc = wv.configuration.userContentController;
        if (js.length && WKUS && ucc){
            WKUserScript *us = [[WKUS alloc] initWithSource:js
                                              injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                           forMainFrameOnly:NO];
            [ucc addUserScript:us];
            objc_setAssociatedObject(wv, kADUSKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (gLoadLog > 0){ gLoadLog--;
                ADLog(@"loadhook: injected userscript into %s", object_getClassName(wv)); }
        }
    } @catch(...) {}
}
static void ADEnableDarkReaderIn(WKWebView *wv){
    if (!gP.enabled || !gP.webDarkReader || !wv) return;
    @try {
        // Lightweight re-apply; the heavy engine arrives via the documentStart userscript.
        NSString *js = ADDarkReaderReapply();
        if (js.length){
            [wv evaluateJavaScript:js completionHandler:^(id r, NSError *e){
                @try {
                    if (![r isKindOfClass:[NSString class]]) return;
                    NSString *res = (NSString *)r;
                    // 'n/bfix' = text colours lifted / blend modes neutralised.
                    // 'nofix'  = the repair function is not defined in this document.
                    // Deduped per URL+result so a settled page cannot spam the log.
                    static NSMutableSet *seenFix = nil;
                    if (!seenFix) seenFix = [NSMutableSet set];
                    NSString *u2 = wv.URL.absoluteString ?: @"(none)";
                    if (u2.length > 60) u2 = [u2 substringToIndex:60];
                    NSString *k = [NSString stringWithFormat:@"%@|%@", u2, res];
                    if (![seenFix containsObject:k]){
                        [seenFix addObject:k];
                        ADLog(@"repair %@ -> %@", u2, res);
                    }
                } @catch(...) {}
            }];
        }

        // Name the page once per URL. Tells us which surfaces are actually web —
        // a tab that never shows up here is native and needs a different fix.
        static NSMutableSet *seen = nil;
        if (!seen) seen = [NSMutableSet set];
        NSString *u = wv.URL.absoluteString ?: @"(no url)";
        if (u.length > 90) u = [u substringToIndex:90];
        if (![seen containsObject:u]){
            [seen addObject:u];
            ADLog(@"web themed: %@", u);
        }

        // Report the page's ACTUAL state back into the log. The cart keeps reverting
        // to light on tab-return and two rounds of native-side timing fixes have not
        // held, so stop inferring: ask the document directly whether the engine is
        // loaded, whether its stylesheet is still attached, and what readyState it is
        // in. Deduped per URL+state so it cannot spam.
        [wv evaluateJavaScript:
            @"(function(){try{return (window.DarkReader?'DR':'noDR')+'/'"
             "+(document.querySelector('style.darkreader')?'styled':'NOSTYLE')+'/'"
             "+(window.__AMZDARK_LOADED__?'flag':'noflag')+'/'+document.readyState;}"
             "catch(e){return 'err';}})()"
             completionHandler:^(id result, NSError *err){
            @try {
                NSString *st = [result isKindOfClass:[NSString class]] ? (NSString *)result
                                                                       : @"(nonstring)";
                // Log state TRANSITIONS: remember the last state per URL and log only
                // when it changes, so an oscillation shows as alternating lines instead
                // of collapsing to one. This is what will confirm the flip is fixed.
                static NSMutableDictionary *lastState = nil;
                if (!lastState) lastState = [NSMutableDictionary dictionary];
                NSString *prev = lastState[u];
                if (!prev || ![prev isEqualToString:st]){
                    lastState[u] = st;
                    ADLog(@"web state: %@ -> %@%@", u, st, err ? @" (evalError)" : @"");
                }

                // SELF-HEAL. 'noflag' means __AMZDARK_LOADED__ is absent, i.e. the
                // documentStart WKUserScript never ran in THIS document — so the page
                // has no engine to re-enable and every light-touch re-apply is a no-op.
                // That is the real cart failure: not a bfcache restore (which would
                // keep the flag and lose only the styles), but a fresh document our
                // script never reached, because the web view was created or navigated
                // outside the window in which we attach the script.
                //
                // Rather than chase every creation path, repair it here: inject the
                // full engine directly into the live document. evaluateJavaScript does
                // not care how the document came to exist, so this works regardless.
                // Overlay diagnostic: name the elements veiling product images. Amazon blocks
                // remote DOM inspection, so the page has to tell us itself. Runs once per URL.
                if ([st containsString:@"complete"]) {
                    static NSMutableSet *ovSeen = nil;
                    if (!ovSeen) ovSeen = [NSMutableSet set];
                    if (![ovSeen containsObject:u]){
                        NSString *probe =
                          @"(function(){try{"
                           "var imgs=[].slice.call(document.querySelectorAll('img'));"
                           "var big=imgs.filter(function(i){var r=i.getBoundingClientRect();"
                             "return r.width>=80&&r.height>=80;});"
                           "if(!big.length)return 'imgs='+imgs.length+' big=0';"
                           "var out=[];"
                           "for(var n=0;n<big.length&&out.length<3;n++){var im=big[n];"
                             "var cs=getComputedStyle(im);"
                             "var r=im.getBoundingClientRect();"
                             "var top=document.elementFromPoint(r.left+r.width/2,r.top+r.height/2);"
                             "var cover='self';"
                             "if(top&&top!==im){var tcs=getComputedStyle(top);"
                               "cover=(top.tagName||'?')+'.'+String(top.className||'').slice(0,24)"
                                 "+'{bg='+tcs.backgroundColor+',bgi='+tcs.backgroundImage.slice(0,24)"
                                 "+',op='+tcs.opacity+'}';}"
                             "out.push('IMG{filter='+cs.filter+',op='+cs.opacity"
                               "+',blend='+cs.mixBlendMode+',bg='+cs.backgroundColor"
                               "+'} cover='+cover);}"
                           "var bgEls=[].slice.call(document.querySelectorAll('div,span,a'))"
                             ".filter(function(e){var c=getComputedStyle(e);"
                               "if(c.backgroundImage.indexOf('url(')<0)return false;"
                               "var r=e.getBoundingClientRect();return r.width>=80&&r.height>=80;});"
                           "for(var m=0;m<bgEls.length&&m<2;m++){var be=bgEls[m];"
                             "var bc=getComputedStyle(be);"
                             "out.push('BGEL{filter='+bc.filter+',op='+bc.opacity"
                               "+',bg='+bc.backgroundColor+',bgi='+bc.backgroundImage.slice(0,50)+'}');}"
                           "var htmlF=getComputedStyle(document.documentElement).filter;"
                           "var bodyF=getComputedStyle(document.body).filter;"
                           "var png=0,jpg=0,other=0;"
                           "for(var q=0;q<big.length;q++){var u2=(big[q].currentSrc||big[q].src||'');"
                             "if(/\\.png(\\?|$)/i.test(u2))png++;"
                             "else if(/\\.jpe?g(\\?|$)/i.test(u2))jpg++;else other++;}"
                           "var fr=document.querySelectorAll('iframe').length;"
                           "return 'img='+big.length+' png='+png+' jpg='+jpg+' other='+other"
                             "+' bgEl='+bgEls.length+' iframes='+fr"
                             "+' htmlFilter='+htmlF+' bodyFilter='+bodyF"
                             "+' || '+out.join(' || ');"
                           "}catch(e){return 'err:'+e;}})()";
                        [wv evaluateJavaScript:probe completionHandler:^(id r3, NSError *e3){
                            @try {
                                if (![r3 isKindOfClass:[NSString class]]) return;
                                NSString *res = (NSString *)r3;
                                // Only remember a sample that actually found media. An
                                // empty result means we looked too early (or the content
                                // lives in a frame), so leave the URL un-cached and try
                                // again on the next pass rather than caching a blind spot.
                                BOOL useful = !([res containsString:@"img=0 bgEl=0"] ||
                                                [res hasPrefix:@"imgs=0"]);
                                if (useful) [ovSeen addObject:u];
                                ADLog(@"overlay@%@: %@%@", u, res, useful ? @"" : @" [retrying]");
                            } @catch(...) {}
                        }];
                    }
                }
                if ([st containsString:@"noflag"] || [st hasPrefix:@"noDR"]){
                    // ROOT-CAUSE HALF. noflag recurring on every navigation means our
                    // documentStart user script is not present on this web view's content
                    // controller any more. The binary exports removeAllUserScripts and an
                    // AMIPrewarmWebviewTask, so Amazon both prewarms web views (created
                    // before we could hook init) and clears user scripts on reuse. Healing
                    // the current document alone therefore fixes one page and leaves the
                    // NEXT navigation unthemed — which is precisely the observed cycle:
                    // noflag -> repair -> dark -> navigate -> noflag -> repair ...
                    //
                    // So re-attach the script here. Once it is back on the controller the
                    // next document is themed at documentStart, before first paint, and
                    // there is no white gap to repair.
                    @try {
                        WKUserContentController *ucc = wv.configuration.userContentController;
                        Class WKUS = NSClassFromString(@"WKUserScript");
                        NSString *boot = ADDarkReaderBootstrap();
                        if (ucc && WKUS && boot.length){
                            BOOL present = NO;
                            for (WKUserScript *existing in ucc.userScripts){
                                if ([existing.source containsString:@"__AMZDARK_LOADED__"]){
                                    present = YES;
                                    break;
                                }
                            }
                            if (!present){
                                WKUserScript *us =
                                    [[WKUS alloc] initWithSource:boot
                                                   injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                forMainFrameOnly:NO];
                                [ucc addUserScript:us];
                                ADLog(@"web: user script re-attached (was stripped) for %@", u);
                            }
                        }
                    } @catch(...) {}

                    // Re-heal EVERY time the document is unthemed, not once per URL.
                    // Guard on DOCUMENT identity: __AMZDARK_HEALED__ lives on window, so a
                    // fresh document at a reused URL heals again while a single document is
                    // never re-injected (no flash, no wasted 346KB parse).
                    NSString *heal =
                        @"(function(){try{"
                         "if(window.__AMZDARK_HEALED__)return 'already';"
                         "window.__AMZDARK_HEALED__=1;return 'heal';"
                         "}catch(e){return 'heal';}})()";
                    [wv evaluateJavaScript:heal completionHandler:^(id r2, NSError *e2){
                        @try {
                            if ([r2 isKindOfClass:[NSString class]] &&
                                [(NSString *)r2 isEqualToString:@"heal"]){
                                NSString *full = ADDarkReaderBootstrap();
                                if (full.length){
                                    ADLog(@"web repair: injecting full engine into %@", u);
                                    [wv evaluateJavaScript:full completionHandler:^(id r3, NSError *e3){
                                        if (e3) ADLog(@"web repair FAILED: %@", e3.localizedDescription);
                                    }];
                                }
                            }
                        } @catch(...) {}
                    }];
                }
            } @catch(...) {}
        }];
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
static void ADBootstrapDarkReaderIn(WKWebView *wv);
static void ADWalkWebViews(UIView *v){
    @try {
        if ([v isKindOfClass:[WKWebView class]]){
            gWebSeen++;
            WKWebView *wv = (WKWebView *)v;
            @try {
                static NSMutableSet *seenWV = nil;
                if (!seenWV) seenWV = [NSMutableSet set];
                NSString *u = wv.URL.absoluteString ?: @"(no url)";
                NSString *key = [NSString stringWithFormat:@"%s|%@", object_getClassName(wv),
                                 u.length > 70 ? [u substringToIndex:70] : u];
                if (![seenWV containsObject:key]){
                    [seenWV addObject:key];
                    ADLog(@"WEBVIEW cls=%s url=%@", object_getClassName(wv), u);
                    // Ping the document once per webview and surface the FAILURE, not
                    // just the success: an App-Bound block answers here as
                    // WKErrorDomain/14 with no result, which is indistinguishable from
                    // silence unless the error is printed. Also record whether the
                    // configuration carries the restriction at all.
                    BOOL lim = NO;
                    @try { lim = [[wv.configuration valueForKey:@"limitsNavigationsToAppBoundDomains"] boolValue]; } @catch(...) {}
                    NSString *uShort = u.length > 60 ? [u substringToIndex:60] : u;
                    [wv evaluateJavaScript:
                        @"(function(){try{return (location.href||'nohref').slice(0,60)"
                         "+' DR='+(window.DarkReader?1:0)"
                         "+' t='+String(document.title||'').slice(0,24);}catch(e){return 'jserr';}})()"
                         completionHandler:^(id pr, NSError *pe){
                        @try {
                            if (pe) ADLog(@"wvping %@ -> ERR %@/%ld appbound=%d",
                                          uShort, pe.domain, (long)pe.code, lim ? 1 : 0);
                            else    ADLog(@"wvping %@ -> %@ appbound=%d",
                                          uShort, pr, lim ? 1 : 0);
                        } @catch(...) {}
                    }];
                }
            } @catch(...) {}
            ADEnableDarkReaderIn(wv);
        }
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

// ════════════════════════════════════════════════════════════════════════════════
// WKWebViewConfiguration — App-Bound Domains would silently kill every injection
// path (user scripts AND evaluateJavaScript) on any origin not in the app's
// WKAppBoundDomains list. Pharmacy is the prime suspect for living on such an
// origin. Force the restriction off; log if Amazon actually tried to enable it,
// because that log line is the confirmation of the whole mechanism.
%hook WKWebViewConfiguration
- (void)setLimitsNavigationsToAppBoundDomains:(BOOL)flag {
    if (flag) ADLog(@"appbound: Amazon requested limitsNavigationsToAppBoundDomains=YES — forcing NO");
    %orig(NO);
}
- (BOOL)limitsNavigationsToAppBoundDomains {
    return NO;
}
%end

// ════════════════════════════════════════════════════════════════════════════════
// WKUserContentController — restore our script the moment Amazon strips it.
// ────────────────────────────────────────────────────────────────────────────────
// The binary exports removeAllUserScripts and AMIPrewarmWebviewTask: Amazon prewarms
// web views and clears their user scripts on reuse. That is why 'noflag' recurred on
// every navigation no matter how many times we healed the current document — the
// documentStart hook was being removed behind us, so each new page painted white
// before the repair could land. Re-adding immediately after the strip means the next
// document is themed at documentStart, before first paint, so there is no white gap
// at all rather than a gap we race to patch.
// ════════════════════════════════════════════════════════════════════════════════
%hook WKUserContentController
- (void)removeAllUserScripts {
    %orig;
    @try {
        ADEnsurePrefs();
        if (!gP.enabled || !gP.webDarkReader) return;
        NSString *boot = ADDarkReaderBootstrap();
        Class WKUS = NSClassFromString(@"WKUserScript");
        if (!boot.length || !WKUS) return;
        WKUserScript *us = [[WKUS alloc] initWithSource:boot
                                          injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                       forMainFrameOnly:NO];
        [self addUserScript:us];
        ADLog(@"web: user script restored after removeAllUserScripts");
    } @catch(...) {}
}
%end

static inline double ADUptime(void);
static int gWkLogLeft = 6;
// A one-line dark floor evaluated into whatever document currently exists --
// no Dark Reader needed. If the engine is already there this is a no-op; if
// the page is mid-load and unthemed, the background stops being white NOW.
static void ADPreDarken(WKWebView *wv){
    @try {
        if (![NSThread isMainThread]) return;
        [wv evaluateJavaScript:
            @"try{if(!document.getElementById('adpre')){var s=document.createElement('style');"
             "s.id='adpre';s.textContent='html,body{background:#181a1b !important}';"
             "(document.documentElement||document).appendChild(s);}}catch(e){}"
             completionHandler:nil];
    } @catch(...) {}
}

%hook WKWebView
- (WKNavigation *)loadHTMLString:(NSString *)string baseURL:(NSURL *)baseURL {
    @try { if (gLoadLog > 0){ gLoadLog--; ADLog(@"loadhook: loadHTMLString on %s len=%lu",
              object_getClassName(self), (unsigned long)string.length); } ADEnsureUserScript(self); } @catch(...) {}
    return %orig;
}
- (WKNavigation *)loadData:(NSData *)data MIMEType:(NSString *)MIMEType characterEncodingName:(NSString *)enc baseURL:(NSURL *)baseURL {
    @try { ADEnsureUserScript(self); } @catch(...) {}
    return %orig;
}
- (WKNavigation *)loadRequest:(NSURLRequest *)request {
    @try { ADEnsureUserScript(self); } @catch(...) {}
    return %orig;
}
- (id)initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)cfg {
    @try {
        ADEnsurePrefs();
        if (gWkLogLeft > 0){ gWkLogLeft--;
            ADLog(@"wkhook init en=%d dr=%d t=%.1f", gP.enabled?1:0, gP.webDarkReader?1:0, ADUptime()); }
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
        ADEnsurePrefs();
        if (!self.window || !gP.enabled || !gP.webDarkReader) return;
        ADPreDarken(self);   // instant dark floor for a page that is mid-load
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

        // Census + repair for LATE webviews. One-shot per instance: name it, ping
        // it (surfacing any injection error), and run the repair pass a few times
        // on a private schedule -- the global burst timer is long dead by the time
        // surfaces like Pharmacy are opened, which is exactly why they stayed
        // light and silent through every previous probe.
        static const void *kADAttachOnce = &kADAttachOnce;
        if (!objc_getAssociatedObject(self, kADAttachOnce)){
            objc_setAssociatedObject(self, kADAttachOnce, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            NSString *au = self.URL.absoluteString ?: @"(no url yet)";
            if (au.length > 70) au = [au substringToIndex:70];
            ADLog(@"wvattach cls=%s url=%@ t=%.1f", object_getClassName(self), au, ADUptime());
            __weak WKWebView *weakWv = self;
            for (NSNumber *delay in @[@0.8, @2.0, @4.5]){
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                               (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    @try {
                        WKWebView *wv2 = weakWv;
                        if (!wv2 || !wv2.window) return;
                        NSString *u3 = wv2.URL.absoluteString ?: @"(no url)";
                        if (u3.length > 60) u3 = [u3 substringToIndex:60];
                        [wv2 evaluateJavaScript:ADDarkReaderReapply()
                              completionHandler:^(id r4, NSError *e4){
                            @try {
                                if (e4) ADLog(@"wvrepair %@ -> ERR %@/%ld",
                                              u3, e4.domain, (long)e4.code);
                                else if ([r4 isKindOfClass:[NSString class]])
                                          ADLog(@"wvrepair %@ -> %@", u3, r4);
                            } @catch(...) {}
                        }];
                    } @catch(...) {}
                });
            }
        }
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

// ─── colours the tweak creates itself ─────────────────────────────────────────
// Anything we build from the theme is ALREADY the final on-screen value. Running it
// back through ADModifyUIColor is not idempotent: the foreground curve maps light to
// dark, so assigning our light foreground to a tint produced a DARK tint. That is
// what kept every icon dark while the sweep reported it had fixed them.
//
// ADIsModifiedUIColor could not catch this. It recognises values the transform has
// EMITTED; the theme's foreground pole (#e8e6e3) is an INPUT we supply, and the
// transform's actual output for dark text is a different value (~rgb(222,219,215)),
// so the pole never appeared in that set.
static const void *kADOwnColorKey = &kADOwnColorKey;
static inline BOOL ADIsOwnColor(UIColor *c){
    return c != nil && objc_getAssociatedObject(c, kADOwnColorKey) != nil;
}
static inline UIColor *ADMarkOwnColor(UIColor *c){
    if (c) objc_setAssociatedObject(c, kADOwnColorKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return c;
}

// A UIImage counts as template-rendered if UIKit will paint it with tintColor.
// renderingMode alone is not enough: an asset marked "Template Image" in the
// catalogue reports UIImageRenderingModeAutomatic and is resolved to template at
// draw time, so the AlwaysTemplate test walked straight past the app's own icons.
static const void *kADOrigImageKey = &kADOrigImageKey;
static UIColor *gAmazonBlue = nil;   // Amazon's own tab accent, captured live
static BOOL ADIsTabBarItemish(UIView *v);
// Walk UP. ADIsTabBarItemish names CONTAINER classes, so the image view that actually
// holds the cart glyph never matches on its own -- only an ancestor does. Declared
// here rather than next to the sweep because THREE separate paths repaint glyphs and
// all three need this gate: setImage:, setImage:forState:, and the didMoveToWindow
// catch-up. v5.21.0 gated the first two and the cart tab stayed white, because the
// third one was still repainting it.
static BOOL ADInTabBarChain(UIView *v){
    int d = 0;
    while (v && d++ < 12){ if (ADIsTabBarItemish(v)) return YES; v = v.superview; }
    return NO;
}

// Search fields and nav bars draw their own background; a dark panel behind a
// small glyph there reads as a black box rather than a backdrop.
// True only when the nearest ancestor that paints an opaque background is our
// dark theme (or unknown). A light or saturated surface returns NO, so the
// backdrop is skipped there.
static BOOL ADAncestorSurfaceIsDark(UIView *v){
    UIView *p = v; int d = 0;
    while (p && d++ < 10){
        UIColor *bg = p.backgroundColor;
        CGFloat r,g,b,a;
        if (bg && [bg getRed:&r green:&g blue:&b alpha:&a] && a > 0.5){
            CGFloat l = 0.2126*r + 0.7152*g + 0.0722*b;
            return l < 0.10;
        }
        p = p.superview;
    }
    return YES;   // unknown: keep prior behaviour
}
static BOOL ADIsChromeGlyphContext(UIView *v){
    UIView *p = v; int d = 0;
    while (p && d++ < 8){
        const char *c = object_getClassName(p);
        if (c && (strstr(c, "SearchBar")  || strstr(c, "SearchField") ||
                  strstr(c, "NavigationBar") || strstr(c, "TextField") ||
                  strstr(c, "SearchTextField")))
            return YES;
        p = p.superview;
    }
    return NO;
}
static inline BOOL ADImageIsTemplateish(UIImage *im){
    if (!im) return NO;
    if (im.renderingMode == UIImageRenderingModeAlwaysTemplate) return YES;
    if (im.renderingMode == UIImageRenderingModeAlwaysOriginal) return NO;
    CGImageRef cg = im.CGImage;
    if (cg && (CGImageIsMask(cg) || CGImageGetAlphaInfo(cg) == kCGImageAlphaOnly)) return YES;
    if (im.symbolConfiguration != nil) return YES;   // SF Symbols are always template
    return NO;
}

// ─── tab bar colouring ──────────────────────────────────────────────────────────
// The bar wants COLOUR, not our monochrome foreground: every tab in Amazon's accent
// blue, the selected one white. The generic setTintColor hook was lightening Amazon's
// blue to ~0.90 (near white), which is exactly why every tab went white. We capture
// Amazon's own accent so the shade matches, stop transforming bar tints, and colour
// each icon explicitly by selection state.
static UIColor *ADBarBlue(void){
    if (gAmazonBlue) return gAmazonBlue;
    return ADColorFromHex("#00A8E1");            // marked-own fallback
}
static UIColor *ADBarWhite(void){ return ADColorFromHex(gP.fgHex); }   // marked-own ~white
static const void *kADBarSelKey = &kADBarSelKey;
static const void *kADIndicatorKey = &kADIndicatorKey;
// React-Native glyph invert bookkeeping (used by the CALayer setFilters guard
// below and the ADInvertRNSVG helper further down).
static const void *kADRNInvertKey  = &kADRNInvertKey;
static const void *kADRNFiltersKey = &kADRNFiltersKey;
static const void *kADRNCheckKey   = &kADRNCheckKey;
static BOOL ADBackdropIsDark(UIView *v);
static void ADLaunchWhiteGuard(UIView *v);
static void ADInvertRNSVGApply(UIView *v);
static inline BOOL ADIsTaggedIndicator(UIView *v){
    return v && objc_getAssociatedObject(v, kADIndicatorKey) != nil;
}
static inline void ADTagIndicator(UIView *v){
    if (!v) return;
    objc_setAssociatedObject(v, kADIndicatorKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // The tag must ALSO live on the layer. UIView.backgroundColor forwards to
    // layer.backgroundColor as a raw CGColor, which cannot carry the own-colour
    // marker -- so the CALayer hook had no way to recognise the indicator and
    // re-darkened the white one call after the sweep set it (the tabline probe
    // read bg=0.10 at the start of every sweep for exactly this reason).
    @try { objc_setAssociatedObject(v.layer, kADIndicatorKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC); } @catch(...) {}
}
static void ADRememberBarSelection(UIView *root, BOOL selected){
    if (!root) return;
    @try {
        objc_setAssociatedObject(root, kADBarSelKey, @(selected), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        for (UIView *s in root.subviews) ADRememberBarSelection(s, selected);
    } @catch(...) {}
}
// Recorded state beats a live ancestor walk: during a tap the walk can observe the
// pre-tap value and repaint blue over the white we just set.
static BOOL ADBarSelectionKnown(UIView *v, BOOL *out){
    int d = 0;
    while (v && d++ < 12){
        NSNumber *n = objc_getAssociatedObject(v, kADBarSelKey);
        if (n){ *out = n.boolValue; return YES; }
        v = v.superview;
    }
    return NO;
}
static BOOL ADViewIsSelectedInBar(UIView *v){
    int d = 0;
    while (v && d++ < 12){
        if ([v isKindOfClass:[UIControl class]] && ((UIControl *)v).selected) return YES;
        v = v.superview;
    }
    return NO;
}
static void ADTintBarIcon(UIImageView *iv, BOOL selected){
    @try {
        UIImage *img = iv.image;
        if (!img) return;
        // Templatise so the tint takes. A bitmap icon ignores tintColor, which is why
        // the dark bitmaps stayed dark; a template renders entirely in its tint.
        if (!ADImageIsTemplateish(img)){
            UIImage *tpl = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            if (tpl){ ADMarkModifiedImage(tpl); iv.image = tpl; }
        }
        UIColor *want = selected ? ADBarWhite() : ADBarBlue();
        // Idempotent: only write when it would actually change something. Each write
        // provokes another setTintColor:, so unconditional writes keep the loop alive.
        UIColor *cur = ((UIView *)iv).tintColor;
        CGFloat cr,cg,cb,ca,wr,wg,wb,wa;
        BOOL same = cur &&
            [cur getRed:&cr green:&cg blue:&cb alpha:&ca] &&
            [want getRed:&wr green:&wg blue:&wb alpha:&wa] &&
            fabs(cr-wr) < 0.01 && fabs(cg-wg) < 0.01 && fabs(cb-wb) < 0.01;
        if (!same){
            // Snap, don't fade. This write lands inside whatever animation context
            // Amazon's tab transition has open, so UIKit eased the colour change
            // over the transition's duration -- the slow blue-to-white. Disabling
            // implicit actions for this one assignment makes it take on the next
            // frame instead.
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            [UIView performWithoutAnimation:^{ ((UIView *)iv).tintColor = want; }];
            [CATransaction commit];
        }
    } @catch(...) {}
}
static BOOL gADSettingImage = NO;   // re-entrancy guard for the setImage: hooks
static BOOL gBarFixPending = NO;
static BOOL gBarCorrecting  = NO;
static void ADApplyBarTint(UIView *container, BOOL selected);
static void ADCorrectBarTintsIn(UIView *v){
    if (!v) return;
    @try {
        if ([v isKindOfClass:[UIControl class]] && ADInTabBarChain(v))
            ADApplyBarTint(v, ((UIControl *)v).selected);
        for (UIView *sv in v.subviews) ADCorrectBarTintsIn(sv);
    } @catch(...) {}
}
static void ADScheduleBarCorrection(void){
    if (gBarFixPending || gBarCorrecting) return;
    gBarFixPending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        gBarFixPending = NO;
        gBarCorrecting = YES;
        @try {
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes){
                if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)sc).windows) ADCorrectBarTintsIn(w);
            }
        } @catch(...) {}
        gBarCorrecting = NO;
    });
}
static void ADApplyBarTint(UIView *container, BOOL selected){
    if (!container) return;
    @try {
        if ([container isKindOfClass:[UIImageView class]]) ADTintBarIcon((UIImageView *)container, selected);
        for (UIView *s in container.subviews) ADApplyBarTint(s, selected);
    } @catch(...) {}
}

// ─── UIView / UILabel / controls ──────────────────────────────────────────────────
static void ADInvertRNSVG(UIView *v);

%hook UIView
- (void)didMoveToWindow {
    %orig;
    @try { if (ADRecolorOn() && self.window) ADInvertRNSVG(self); } @catch(...) {}
}
- (void)setBackgroundColor:(UIColor *)color {
    if (!ADRecolorOn() || !color || ADIsOwnColor(color) || ADIsWebKitOwned(self)) {
        %orig;
        return;
    }
    @try {
        // Tab selection indicator: a short thin bar inside the tab bar. Only the
        // active tab draws one, so no selection test is needed -- and the earlier
        // test was what suppressed this, since the indicator is not inside the
        // selected control's subtree. Width separates it from the 430-wide hairline.
        // Tagged by the sweep, which runs after layout. Measuring here is unreliable:
        // setBackgroundColor: often precedes layout, so bounds read 0x0 and any size
        // test fails silently -- the reason the previous attempt never took effect.
        if (ADIsTaggedIndicator(self)){
            UIColor *ind = ADBarWhite();
            %orig(ind);
            return;
        }
    } @catch(...) {}
    @try {
        // Kill translucent dark veils. A ~50%-opaque dark fill spread over a large
        // view is a scrim sitting on top of content (the home-tab overlay the probe
        // named: UIView rgba(0.09,0.10,0.11,0.50)). On a light UI it dims things a
        // little; on our now-dark UI it just muddies the product cards underneath for
        // no benefit. If a dark, half-transparent colour lands on a sizeable view,
        // drop it to clear so the themed content shows through cleanly.
        CGFloat r,g,b,a;
        if ([color getRed:&r green:&g blue:&b alpha:&a]){
            CGFloat lum = 0.2126*r + 0.7152*g + 0.0722*b;
            if (a > 0.15 && a < 0.85 && lum < 0.25 &&
                self.bounds.size.width > 120 && self.bounds.size.height > 120){
                %orig([UIColor clearColor]);
                return;
            }
        }
        UIColor *m = ADModifyUIColor(color, ADColorRoleBackground);
        if (!m) m = color;
        %orig(m);
        return;
    } @catch(...) {}
    %orig;
}
- (void)setTintColor:(UIColor *)color {
    // Tab bar FIRST, before the generic guard below. The blue/white flash was a fight:
    // we set a tab icon blue, Amazon reset its tint (often to nil -> reverts to the
    // bar's inherited near-white), our next sweep re-blued it. Overriding every
    // assignment here -- real colour, nil, or our own -- means Amazon's value never
    // lands, so there is nothing to flash against. (The old !color guard sat ABOVE
    // this and swallowed the nil case, which is why it had to move below.)
    @try {
        if (ADRecolorOn() && !ADIsWebKitOwned(self) && ADInTabBarChain(self)){
            if (color && !ADIsOwnColor(color)){
                CGFloat r,g,b,a;
                if (!gAmazonBlue && [color getRed:&r green:&g blue:&b alpha:&a]){
                    CGFloat mx = MAX(r,MAX(g,b)), mn = MIN(r,MIN(g,b));
                    if ((mx-mn) > 0.15 && b >= r*0.9)
                        gAmazonBlue = ADMarkOwnColor([UIColor colorWithRed:r green:g blue:b alpha:1.0]);
                }
            }
            if (!ADIsOwnColor(color)){
                // Resolve to a local -- Logos's %orig tokenizer rejects a nested call
                // in its arguments, which is what broke the v5.28.0 CI lint.
                BOOL sel = NO;
                if (!ADBarSelectionKnown(self, &sel)) sel = ADViewIsSelectedInBar(self);
                UIColor *want = sel ? ADBarWhite() : ADBarBlue();
                CGFloat ir,ig,ib,ia,tr2,tg2,tb2,ta2;
                BOOL alreadyWanted = color &&
                    [color getRed:&ir green:&ig blue:&ib alpha:&ia] &&
                    [want getRed:&tr2 green:&tg2 blue:&tb2 alpha:&ta2] &&
                    fabs(ir-tr2) < 0.01 && fabs(ig-tg2) < 0.01 && fabs(ib-tb2) < 0.01;
                if (alreadyWanted){
                    %orig;
                    return;
                }
                ADScheduleBarCorrection();
                %orig(want);
                return;
            }
            %orig;
            return;
        }
    } @catch(...) {}
    if (!ADRecolorOn() || !color || ADIsOwnColor(color) || ADIsWebKitOwned(self)) {
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
    if (!ADRecolorOn() || !color || ADIsOwnColor(color)) {
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
    if (!ADRecolorOn() || !color || ADIsOwnColor(color)) {
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
    if (!ADRecolorOn() || !color || ADIsOwnColor(color)) {
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
    if (!ADRecolorOn() || !color || ADIsOwnColor(color)) {
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
        // Claimed tab-bar elements (selection indicator, top hairline). Their view
        // sets a marked-own white, but the marker cannot survive the UIColor ->
        // CGColor forwarding, so without this check the hook mapped the white
        // straight back to the dark background colour.
        if (objc_getAssociatedObject(self, kADIndicatorKey)) {
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
- (void)setFilters:(NSArray *)filters {
    @try {
        id d = self.delegate;
        if (d && [d isKindOfClass:[UIView class]] &&
            objc_getAssociatedObject(d, kADRNInvertKey)){
            NSArray *ours = objc_getAssociatedObject(d, kADRNFiltersKey);
            if (ours.count){
                BOOL has = NO;
                for (id f in (filters ?: @[])){ if ([ours containsObject:f]){ has = YES; break; } }
                if (!has){
                    NSMutableArray *m2 = [NSMutableArray arrayWithArray:(filters ?: @[])];
                    [m2 addObjectsFromArray:ours];
                    %orig(m2);
                    return;
                }
            }
        }
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

// ════════════════════════════════════════════════════════════════════════════════
// SURFACE 3e — react-native-linear-gradient (BVLinearGradientLayer)
// ────────────────────────────────────────────────────────────────────────────────
// This layer is why a region can render solid white while every hook and the probe
// swear nothing is white. It is a plain CALayer that paints its gradient in
// drawInContext: with raw CoreGraphics — so it is NOT a CAGradientLayer (the hook
// above never sees it), it has no backgroundColor (the probe prints NO-BG), and it
// never calls [UIColor setFill] (pure CGGradientRef). A white→light-grey RN
// <LinearGradient> backdrop is therefore invisible to the entire engine and renders
// as a white sheet. Its colors property is the single choke point: transform the
// stops with the background curve and the gradient darkens like any other surface,
// hue preserved for genuinely colourful brand gradients.
// ════════════════════════════════════════════════════════════════════════════════
%hook BVLinearGradientLayer
- (void)setColors:(NSArray *)colors {
    if (!ADRecolorOn() || colors.count == 0) {
        %orig;
        return;
    }
    @try {
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:colors.count];
        for (id c in colors){
            if ([c isKindOfClass:[UIColor class]]){
                UIColor *m = ADModifyUIColor((UIColor *)c, ADColorRoleBackground);
                [out addObject:(m ? m : c)];
            } else if (c && CFGetTypeID((__bridge CFTypeRef)c) == CGColorGetTypeID()){
                CGColorRef m = ADModifyCGColor((__bridge CGColorRef)c, ADColorRoleBackground);
                [out addObject:(m ? (__bridge id)m : c)];
            } else {
                [out addObject:c];
            }
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
- (void)didMoveToWindow {
    %orig;
    @try {
        // The light band behind the status bar and search field is a bar-background
        // blur whose backdrop paints its own light tint, so forcing the effect dark
        // in setEffect: is not always enough. Drop a dark fill behind the effect view
        // when it is bar-sized so the top matches the themed content below it.
        if (ADRecolorOn() && self.window && self.bounds.size.height < 160){
            ((UIView *)self).backgroundColor = ADColorFromHex(gP.bgHex);
        }
    } @catch(...) {}
}
%end

// _UIBarBackground is the nav/search bar's own backing view; force it dark so the
// top band matches the themed content below it.
%hook _UIBarBackground
- (void)layoutSubviews {
    %orig;
    @try {
        if (gP.enabled) ((UIView *)self).backgroundColor = ADColorFromHex(gP.bgHex);
    } @catch(...) {}
}
%end

static void ADSweepViewTree(UIView *v, int depth, BOOL inTabBar);
static const void *kADScrollPendKey = &kADScrollPendKey;
%hook UIScrollView
- (void)didMoveToWindow {
    %orig;
    @try { if (ADRecolorOn() && self.window) self.indicatorStyle = UIScrollViewIndicatorStyleWhite; } @catch(...) {}
}
- (void)setContentOffset:(CGPoint)offset {
    %orig;
    @try {
        if (!ADRecolorOn() || !self.window || ADIsWebKitOwned(self)) return;
        // Coalesce: schedule ONE scoped sweep ~300ms after scrolling settles.
        if (objc_getAssociatedObject(self, kADScrollPendKey)) return;
        objc_setAssociatedObject(self, kADScrollPendKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak UIScrollView *ws = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300*1000000LL),
            dispatch_get_main_queue(), ^{
                UIScrollView *ss = ws;
                if (!ss) return;
                objc_setAssociatedObject(ss, kADScrollPendKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                @try { if (ADRecolorOn() && ss.window) ADSweepViewTree(ss, 0, NO); } @catch(...) {}
            });
    } @catch(...) {}
}
%end

// ════════════════════════════════════════════════════════════════════════════════
// SURFACE 4 — bottom nav toolbar chrome (the tab bar strip).
// These Amazon container views sometimes assert an opaque light backdrop AFTER our
// generic hooks run, so a plain colour swap can be overwritten. Forcing the fill in
// layoutSubviews (which re-runs on every relayout) makes it stick. Image-safe: only
// the container's own backgroundColor is touched, never any glyph/icon subview.
// ════════════════════════════════════════════════════════════════════════════════
// The tab-bar strip. Force the container dark, but NEVER recurse into its item/icon
// subviews — those are template-tinted glyphs, and repainting their backgrounds (or
// the fill landing mid-transition) is what made tabs intermittently vanish. We set
// the fill only when it is not already our colour, so a fast relayout does not keep
// re-triggering it.
static void ADForceBarDark(UIView *bar){
    if (!gP.enabled || !bar) return;
    @try {
        UIColor *want = ADColorFromHex(gP.bgHex);
        UIColor *have = bar.backgroundColor;
        CGFloat r1,g1,b1,a1,r2,g2,b2,a2;
        BOOL same = have &&
            [have getRed:&r1 green:&g1 blue:&b1 alpha:&a1] &&
            [want getRed:&r2 green:&g2 blue:&b2 alpha:&a2] &&
            fabs(r1-r2)<0.01 && fabs(g1-g2)<0.01 && fabs(b1-b2)<0.01 && fabs(a1-a2)<0.01;
        if (!same) bar.backgroundColor = want;
    } @catch(...) {}
}
%hook CXIStoreModesBottomNavToolbar
- (void)layoutSubviews {
    %orig;
    ADForceBarDark((UIView *)self);
}
%end
%hook CXIStoreModesTabBarView
- (void)layoutSubviews {
    %orig;
    ADForceBarDark((UIView *)self);
}
%end
%hook ANPRetailTabBar
- (void)layoutSubviews {
    %orig;
    ADForceBarDark((UIView *)self);
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
// Dedupe by identity rather than capping the number of runs. The old hard cap of 6
// reports was consumed during launch, so by the time a problem tab was opened the
// probe had permanently stopped — which is exactly why the hamburger returned no
// diagnostics. Reporting each distinct offender once keeps it alive indefinitely
// without spamming.
static NSMutableSet *gProbeSeen = nil;
static BOOL ADProbeFirstTime(NSString *key){
    if (!gProbeSeen) gProbeSeen = [NSMutableSet set];
    if ([gProbeSeen containsObject:key]) return NO;
    [gProbeSeen addObject:key];
    return YES;
}

static void ADProbeTree(UIView *v, int depth, int *found){
    if (!v || depth > 40 || *found >= 40) return;
    @try {
        if (ADIsWebKitOwned(v)) {
            ADLog(@"  probe: WEBVIEW %s (Dark Reader territory)", object_getClassName(v));
            return;
        }
        // Small image-bearing views: the Alexa panel's native icons. Either
        // UIImageView artwork, or raw layer.contents -- React Native Fabric
        // paints images that way and bypasses every UIImageView hook, which
        // would explain glyphs no pass has ever touched.
        @try {
            CGFloat gw = v.bounds.size.width, gh = v.bounds.size.height;
            if (gw >= 4 && gw <= 48 && gh >= 4 && gh <= 48 && !v.hidden){
                BOOL isIv = [v isKindOfClass:[UIImageView class]];
                BOOL isLb = [v isKindOfClass:[UILabel class]];
                UIImage *gi = isIv ? ((UIImageView *)v).image : nil;
                BOOL layerImg = !isIv && v.layer.contents != nil;
                if (gi || layerImg || isLb){
                    NSString *gk = [NSString stringWithFormat:@"G%s%.0fx%.0f",
                                    object_getClassName(v), gw, gh];
                    if (ADProbeFirstTime(gk)){
                        UIColor *tc = v.tintColor; CGFloat tr,tg,tb,ta; double tl = -1;
                        if (tc && [tc getRed:&tr green:&tg blue:&tb alpha:&ta]) tl = 0.2126*tr+0.7152*tg+0.0722*tb;
                        if (isLb){
                            UILabel *pl = (UILabel *)v;
                            UIColor *ptc = pl.textColor; CGFloat pr,pg,pb,pa; double ptl = -1;
                            if (ptc && [ptc getRed:&pr green:&pg blue:&pb alpha:&pa]) ptl = 0.2126*pr+0.7152*pg+0.0722*pb;
                            NSString *pt = pl.text.length ? [pl.text substringToIndex:MIN((NSUInteger)6, pl.text.length)] : @"";
                            ADLog(@"  probe: GLYPH %s %.0fx%.0f LBL txt='%s' tl=%.2f cont=%d bkd=%d tint=%.2f",
                                  object_getClassName(v), gw, gh,
                                  pt.UTF8String ?: "", ptl, v.layer.contents?1:0,
                                  ADBackdropIsDark(v)?1:0, tl);
                        } else {
                            ADLog(@"  probe: GLYPH %s %.0fx%.0f img=%d dark=%d tmpl=%d layer=%d tint=%.2f",
                                  object_getClassName(v), gw, gh, gi?1:0,
                                  gi?ADIsDarkGlyph(gi):0, (gi && ADImageIsTemplateish(gi))?1:0,
                                  layerImg?1:0, tl);
                        }
                        (*found)++;
                    }
                }
            }
        } @catch(...) {}
        UIColor *bg = v.backgroundColor;
        if (bg){
            CGFloat r,g,b,a;
            if ([bg getRed:&r green:&g blue:&b alpha:&a] && a > 0.2){
                CGFloat lum = 0.2126*r + 0.7152*g + 0.0722*b;
                if (lum > 0.55){                     // still light => an offender
                    NSString *k = [NSString stringWithFormat:@"L%s%.0fx%.0f",
                                   object_getClassName(v), v.bounds.size.width, v.bounds.size.height];
                    if (ADProbeFirstTime(k)){
                        ADLog(@"  probe: LIGHT bg %s rgba(%.2f,%.2f,%.2f,%.2f) frame=%.0fx%.0f",
                              object_getClassName(v), r,g,b,a,
                              v.bounds.size.width, v.bounds.size.height);
                        (*found)++;
                    }
                } else if (a < 0.95 && lum < 0.35 && v.bounds.size.width > 100){
                    // Dark AND translucent over a large area = the veil on the home tab.
                    NSString *k = [NSString stringWithFormat:@"O%s%.0fx%.0f",
                                   object_getClassName(v), v.bounds.size.width, v.bounds.size.height];
                    if (ADProbeFirstTime(k)){
                        ADLog(@"  probe: DARK-OVERLAY %s rgba(%.2f,%.2f,%.2f,%.2f) frame=%.0fx%.0f",
                              object_getClassName(v), r,g,b,a,
                              v.bounds.size.width, v.bounds.size.height);
                        (*found)++;
                    }
                }
            }
        } else if (v.bounds.size.width > 150 && v.bounds.size.height > 60 && !v.hidden) {
            // No backgroundColor at all but big and visible => probably drawRect: or a
            // UIImageView. Naming it tells us which of the two to chase.
            BOOL isImg = [v isKindOfClass:[UIImageView class]];
            // If it draws itself, does the class override drawRect: ? That is the
            // signal for [UIColor set]/setFill painting our hooks should be catching.
            BOOL drawsSelf = [v methodForSelector:@selector(drawRect:)] !=
                             [UIView instanceMethodForSelector:@selector(drawRect:)];
            // For image views, is the image a tiny resizable slice (a background) or a
            // real picture? Tiny + tiled = a themeable chrome asset.
            const char *imgInfo = "";
            if (isImg){
                UIImage *im = ((UIImageView *)v).image;
                if (im && (im.size.width < 8 || im.size.height < 8)) imgInfo = " TINY-STRETCH-IMG";
            }
            NSString *k = [NSString stringWithFormat:@"N%s%.0fx%.0f",
                           object_getClassName(v), v.bounds.size.width, v.bounds.size.height];
            if (ADProbeFirstTime(k)){
                ADLog(@"  probe: NO-BG %s%s%s%s frame=%.0fx%.0f",
                      object_getClassName(v),
                      isImg ? " IMAGEVIEW" : "",
                      drawsSelf ? " DRAWS-SELF" : "",
                      imgInfo,
                      v.bounds.size.width, v.bounds.size.height);
                (*found)++;
            }
        }
        for (UIView *s in v.subviews) ADProbeTree(s, depth+1, found);
    } @catch(...) {}
}

static void ADRunProbe(void){
    if (!gProbeArmed) return;
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

// ════════════════════════════════════════════════════════════════════════════════
// SURFACE 5 — image backdrops (native half of the same idea as the web CSS above).
// ────────────────────────────────────────────────────────────────────────────────
// Setting a dark backgroundColor on an image view shows through wherever the image
// has TRANSPARENT pixels — cut-out product shots, icons, logos with alpha. It is
// completely hidden behind an opaque JPEG, so it is a no-op on ordinary photos
// rather than a risk to them.
//
// What this deliberately does NOT do: touch layer.contents or any pixel of the
// image. White baked into a JPEG stays exactly as photographed. That limitation is
// the whole reason images have survived this project intact, and it is not worth
// trading away for this.
// ════════════════════════════════════════════════════════════════════════════════
%hook UIImageView
- (void)didMoveToWindow {
    %orig;
    @try {
        if (!gP.enabled || !self.window || ADIsWebKitOwned(self)) return;
        // The tab bar owns its own colours. Both branches below repaint: the backdrop
        // drops a dark panel behind any transparent artwork, and the catch-up
        // glyphifies and re-tints. Between them that is the white cart icon and the
        // nav items that read as blank until tapped -- tapping installs the selected
        // artwork through a path that already ran before injection.
        // The dump settled the tab bar: unselected icons are dark BITMAPS (dark=1,
        // tmpl=0) rendering invisibly on the dark bar. Convert them like any glyph,
        // but skip the backdrop and the tint pin so the bar's own tint -- selected
        // blue, unselected grey -- still drives their colour.
        if (ADInTabBarChain(self)){
            ADTintBarIcon(self, ADViewIsSelectedInBar(self));
            return;                                      // bar icons are fully handled
        }

        // (1) Backdrop for TRANSPARENT images — cheap, always-on-when-enabled.
        // Never behind glyph-sized artwork, never inside search/nav chrome, and
        // never over a coloured/light surface (a teal or promo header), where a
        // near-black panel reads as a box instead of a backdrop.
        CGFloat bw = self.bounds.size.width, bh = self.bounds.size.height;
        BOOL surfDark = ADAncestorSurfaceIsDark(self);
        if (gP.imageBackdrop && (bw > 48 || bh > 48) && !ADIsChromeGlyphContext(self) && surfDark){
            UIImage *img = self.image;
            if (img && img.CGImage){
                CGImageAlphaInfo a = CGImageGetAlphaInfo(img.CGImage);
                BOOL hasAlpha = (a == kCGImageAlphaFirst || a == kCGImageAlphaLast ||
                                 a == kCGImageAlphaPremultipliedFirst ||
                                 a == kCGImageAlphaPremultipliedLast);
                if (hasAlpha && !self.backgroundColor)
                    ((UIView *)self).backgroundColor = ADColorFromHex(gP.bgHex);
            }
        }

        // (1b) Catch-up for glyphs assigned BEFORE our hooks were installed. New
        // assignments are handled earlier and more reliably by the setImage: hook.
        {
            UIImage *tpl = ADGlyphifyForView(self.image, self);
            if (tpl){
                ((UIView *)self).tintColor = ADColorFromHex(gP.fgHex);
                self.image = tpl;
            }
        }

        // (2) Corner-key white-studio backdrops in OPAQUE photos — pixel work, opt-in.
        // Off by default: it edits pixels, which everything else here avoids, and a
        // wrong key looks worse than a white card. Runs on a background queue and
        // caches per source image so each is processed at most once; if the key
        // declines (ambiguous / not white-studio) the original is kept untouched.
        if (gP.imageKeyBackground){
            UIImage *img = self.image;
            if (img && img.CGImage && !ADIsModifiedImage(img)){
                static const void *kKeyed = &kKeyed;
                if (!objc_getAssociatedObject(img, kKeyed)){
                    objc_setAssociatedObject(img, kKeyed, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    __weak UIImageView *weakSelf = self;
                    NSString *hexStr = [NSString stringWithUTF8String:gP.bgHex];
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                        @try {
                            UIImage *keyed = ADKeyWhiteBackground(img, hexStr.UTF8String);
                            if (!keyed) return;
                            ADMarkModifiedImage(keyed);
                            dispatch_async(dispatch_get_main_queue(), ^{
                                @try {
                                    UIImageView *sv = weakSelf;
                                    if (sv && sv.image == img) sv.image = keyed;   // still the same image
                                } @catch(...) {}
                            });
                        } @catch(...) {}
                    });
                }
            }
        }
    } @catch(...) {}
}
%end

// ════════════════════════════════════════════════════════════════════════════════
// SURFACE 3f — DIRECTLY-DRAWN TEXT (NSString / NSAttributedString draw APIs)
// ────────────────────────────────────────────────────────────────────────────────
// The gap left by making the drawRect: paint path one-way in v5.3.1. That change
// (light fills darken, dark fills untouched) was needed to stop an already-dark
// backdrop being flipped light — but it means dark text painted through
// [UIColor set] + drawInRect: is now left dark on a dark background, i.e. invisible.
//
// The fix is to intercept where the colour is UNAMBIGUOUSLY text rather than trying
// to guess intent from a bare fill colour. In these APIs the foreground attribute is
// text by definition, so pushing it through the foreground curve carries none of the
// risk that made the generic paint hook one-way: we can never lighten a background
// here, because a background is never drawn by drawInRect:withAttributes:.
// ════════════════════════════════════════════════════════════════════════════════

// Return a copy of `attrs` whose foreground colour has been run through the
// foreground curve. Text with no explicit colour defaults to black, which on a dark
// surface is the worst case, so that is lifted too.
static NSDictionary *ADRecolorTextAttrs(NSDictionary *attrs){
    if (!ADRecolorOn()) return attrs;
    @try {
        UIColor *fg = attrs[NSForegroundColorAttributeName];
        if (fg && ADIsModifiedUIColor(fg)) return attrs;          // already ours
        UIColor *src = [fg isKindOfClass:[UIColor class]] ? fg : [UIColor blackColor];
        UIColor *mod = ADModifyUIColor(src, ADColorRoleForeground);
        if (!mod) return attrs;
        NSMutableDictionary *m = attrs ? [attrs mutableCopy] : [NSMutableDictionary dictionary];
        m[NSForegroundColorAttributeName] = mod;
        return m;
    } @catch(...) {}
    return attrs;
}

%hook NSString
- (void)drawAtPoint:(CGPoint)point withAttributes:(NSDictionary *)attrs {
    @try {
        NSDictionary *a = ADRecolorTextAttrs(attrs);
        %orig(point, a);
        return;
    } @catch(...) {}
    %orig;
}
- (void)drawInRect:(CGRect)rect withAttributes:(NSDictionary *)attrs {
    @try {
        NSDictionary *a = ADRecolorTextAttrs(attrs);
        %orig(rect, a);
        return;
    } @catch(...) {}
    %orig;
}
- (void)drawWithRect:(CGRect)rect
             options:(NSStringDrawingOptions)options
          attributes:(NSDictionary *)attrs
             context:(NSStringDrawingContext *)context {
    @try {
        NSDictionary *a = ADRecolorTextAttrs(attrs);
        %orig(rect, options, a, context);
        return;
    } @catch(...) {}
    %orig;
}
%end

%hook NSAttributedString
- (void)drawAtPoint:(CGPoint)point {
    @try {
        NSAttributedString *r = ADRecolorAttributedString(self);
        if (r != self) {
            [r drawAtPoint:point];
            return;
        }
    } @catch(...) {}
    %orig;
}
- (void)drawInRect:(CGRect)rect {
    @try {
        NSAttributedString *r = ADRecolorAttributedString(self);
        if (r != self) {
            [r drawInRect:rect];
            return;
        }
    } @catch(...) {}
    %orig;
}
%end

// ════════════════════════════════════════════════════════════════════════════════
// SURFACE 5b — GLYPH CONVERSION AT ASSIGNMENT TIME
// ────────────────────────────────────────────────────────────────────────────────
// Converting glyphs only in didMoveToWindow was too late and too narrow. Any icon
// whose image is set AFTER the view is already on screen never got converted — the
// search magnifier once the search UI opens, the filters icon after a search, the
// recent-searches glyph, the heart on a product cell. It also caused the location
// pin to flash black: the original dark artwork was displayed first and only
// repainted when the view moved into the window.
//
// Intercepting setImage: fixes both at once. The conversion happens before the
// image is ever handed to the view, so a late assignment is caught and there is no
// intermediate frame showing the dark original.
//
// Results are cached per UIImage (checked-and-not-a-glyph is remembered too), so a
// given image is analysed at most once no matter how often it is re-assigned during
// scrolling.
static const void *kADGlyphChecked = &kADGlyphChecked;

// Only convert glyph-sized artwork. Category thumbnails and other content
// illustrations are larger than any real monochrome UI glyph; whitening them
// destroys their detail. Tab-bar icons are exempt -- they are tinted by
// selection state on their own path and must still convert.
static UIImage *ADGlyphifyForView(UIImage *img, UIView *v){
    @try {
        if (v && !ADInTabBarChain(v) && !ADIsChromeGlyphContext(v)){
            CGFloat w = v.bounds.size.width, h = v.bounds.size.height;
            if (w > 40 || h > 40) return nil;
        }
    } @catch(...) {}
    return ADGlyphify(img);
}
static UIImage *ADGlyphify(UIImage *img){
    if (!gP.enabled || !gP.imageBackdrop || !img) return nil;
    @try {
        if (ADIsModifiedImage(img)) return nil;                        // already ours
        if (objc_getAssociatedObject(img, kADGlyphChecked)) return nil; // known non-glyph
        if (ADImageIsTemplateish(img)) return nil;   // already tinted, not repainted
        if (!ADIsDarkGlyph(img)){
            objc_setAssociatedObject(img, kADGlyphChecked, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return nil;
        }
        UIImage *tpl = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        if (!tpl) return nil;
        ADMarkModifiedImage(tpl);
        // Keep the original. Every gate so far has been a promise not to convert;
        // this is the ability to UNDO one, which is what the tab bar actually needs.
        objc_setAssociatedObject(tpl, kADOrigImageKey, img, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return tpl;
    } @catch(...) {}
    return nil;
}

%hook UIImageView
- (void)setImage:(UIImage *)image {
    if (!image || ADIsWebKitOwned(self) || !ADRecolorOn() || gADSettingImage) {
        %orig;
        return;
    }
    // Detached: nothing to walk yet. Defer to didMoveToWindow, where ancestry -- and
    // therefore the tab-bar test -- is knowable.
    if (!self.superview && !self.window) {
        %orig;
        return;
    }
    @try {
        // THE tab-bar fix. The dump proved unselected tab icons are dark BITMAPS
        // going invisible on the dark bar, so we still convert them. What we must NOT
        // do is pin the tint: a converted template inherits the bar's tint, which is
        // what lets the selected state colour it blue. Pinning fg is what turned the
        // cart white -- that was the real defect behind four builds of gating, not the
        // conversion.
        if (ADInTabBarChain(self)) {
            %orig;                                       // install the artwork
            gADSettingImage = YES;                       // our own writes must not re-enter
            @try { ADTintBarIcon(self, ADViewIsSelectedInBar(self)); } @catch(...) {}
            gADSettingImage = NO;
            return;
        }
        UIImage *tpl = ADGlyphifyForView(image, self);
        if (tpl) {
            ((UIView *)self).tintColor = ADColorFromHex(gP.fgHex);
            %orig(tpl);
            return;
        }
    } @catch(...) {}
    %orig;
}
%end

// Many of these glyphs are button artwork rather than plain image views — the heart,
// the filters control, the recent-search rows.
%hook UIButton
- (void)setImage:(UIImage *)image forState:(UIControlState)state {
    if (!image || !ADRecolorOn() || gADSettingImage) {
        %orig;
        return;
    }
    if (!self.superview && !self.window) {
        %orig;
        return;
    }
    @try {
        if (ADInTabBarChain(self)) {
            %orig(image, state);
            ADApplyBarTint(self, ADViewIsSelectedInBar(self));
            return;
        }
        UIImage *tpl = ADGlyphifyForView(image, self);
        if (tpl) {
            ((UIView *)self).tintColor = ADColorFromHex(gP.fgHex);
            %orig(tpl, state);
            return;
        }
    } @catch(...) {}
    %orig;
}
%end

// Selection changes after the launch timer stops, so a tap must re-colour the tab
// itself. setSelected: is the exact event; ADApplyBarTint reads the NEW value.
%hook UIControl
- (void)setSelected:(BOOL)selected {
    %orig;
    @try {
        if (ADRecolorOn() && ADInTabBarChain(self)){
            // Record first so any tint assignment triggered by this change reads the
            // NEW value rather than re-deriving a stale one.
            ADRememberBarSelection(self, selected);
            ADApplyBarTint(self, selected);
            ADScheduleBarCorrection();
        }
    } @catch(...) {}
}
// The residual lag is upstream of us: Amazon flips `selected` only partway
// through its own transition, and no amount of snap-on-assignment can beat the
// moment the assignment happens. Finger-down is the earliest truthful signal --
// paint the tapped tab white immediately and let the deferred correction pass
// re-read real state afterwards, which also cleans up a cancelled touch.
- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    BOOL r = %orig;
    @try {
        if (ADRecolorOn() && ADInTabBarChain(self)){
            ADRememberBarSelection(self, YES);
            ADApplyBarTint(self, YES);
            ADScheduleBarCorrection();
        }
    } @catch(...) {}
    return r;
}
%end

// The residual seconds-long delay: the bottom bar is Packard/React-Native, so a
// tap can be consumed by an RN pressable -- no UIControl ever tracks or flips
// `selected`, and neither of the immediate paths above fires. The white then
// arrives only with the next incidental sweep. UIWindow sendEvent: sees every
// touch no matter who handles it; a touch in the bar region fires a short
// correction burst, and whichever pass first observes the settled selection
// paints it. Writes are idempotent, so the burst cannot ring.
static void ADSweep(void);
static int gBarTapLog = 4;
%hook UIWindow
- (void)sendEvent:(UIEvent *)event {
    %orig;
    @try {
        if (!ADRecolorOn()) return;
        for (UITouch *t in event.allTouches){
            if (t.phase != UITouchPhaseBegan && t.phase != UITouchPhaseEnded) continue;
            CGPoint pt = [t locationInView:nil];
            CGFloat H = self.bounds.size.height;
            if (H > 0 && pt.y > H - 130.0){
                if (gBarTapLog > 0){ gBarTapLog--; ADLog(@"bartap y=%.0f t=%.1f", pt.y, ADUptime()); }
                static const int64_t d_ms[] = {0, 250, 700};
                for (int i = 0; i < 3; i++){
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, d_ms[i]*1000000LL),
                        dispatch_get_main_queue(), ^{ @try { ADScheduleBarCorrection(); } @catch(...) {} });
                }
                break;
            }
        }
    } @catch(...) {}
}
%end

// ─── catch-up sweep ───────────────────────────────────────────────────────────────
// Views built before our hooks installed (the pre-warmed gateway, the splash stack)
// already hold light colours. Re-assigning a view's own colour runs it through the
// hook once; ADModifyUIColor recognises anything it previously emitted, so a view
// that is swept twice is not darkened twice.
static BOOL ADIsTabBarItemish(UIView *v){
    const char *n = object_getClassName(v);
    if (!n) return NO;
    return (strstr(n,"BottomNav") || strstr(n,"TabBarItem") ||
            strstr(n,"TabBar") || strstr(n,"NavToolbar"));
}
// ─── React Native SVG icons (the Alexa panel) ────────────────────────────────────
// The GLYPH probe named the Alexa panel's dark icons: RNSVGSvgView -- react-native-
// svg painting vector paths straight into layer contents. No UIImageView hook, no
// web pass, no tint can reach that artwork. A Core Animation colour filter can:
// colorInvert flips the dark strokes light, hueRotate(pi) restores hue for any
// coloured artwork caught in the net -- the same invert+hue-rotate recipe Dark
// Reader uses for images, applied at the layer. Private CAFilter is resolved at
// runtime and every call is guarded, so a missing class is a silent no-op.
@interface CAFilter : NSObject
+ (id)filterWithType:(NSString *)type;
@end
static int gRNLogLeft = 8;
static BOOL ADBackdropIsDark(UIView *v){
    UIView *p = v.superview; int d = 0;
    while (p && d++ < 12){
        UIColor *bg = p.backgroundColor;
        if (bg){
            CGFloat r,g,b,a;
            if ([bg getRed:&r green:&g blue:&b alpha:&a] && a > 0.5)
                return (0.2126*r + 0.7152*g + 0.0722*b) < 0.45;
        }
        p = p.superview;
    }
    return YES;   // themed app: unknown means dark
}
static void ADInvertRNSVG(UIView *v){
    @try {
        const char *cn = object_getClassName(v);
        if (!cn) return;
        CGFloat w = v.bounds.size.width, h = v.bounds.size.height;
        if (w < 3 || w > 48 || h < 3 || h > 48) return;   // icons, not illustrations
        BOOL take = (strcmp(cn, "RNSVGSvgView") == 0);    // root only; children ride along
        if (0 && !take && [v isKindOfClass:[UILabel class]]){   // DISABLED in v5.52.0 stability build
            // The kebab: an RN-hosted UILabel whose dots are baked into layer
            // contents. The colour-property gate could never match -- the sweep
            // recolours textColor, so the PROPERTY reads light while the PIXELS
            // stay dark (v5.41.0 logged zero cls=UILabel for exactly this
            // reason). So judge by pixels: render the label once and ask
            // ADIsDarkGlyph. A label whose text genuinely went light fails the
            // darkness test and is left alone; capped attempts keep the render
            // cost bounded while late-drawn contents still get a look.
            if (w >= 6 && h >= 6 && v.layer.contents != nil && ADBackdropIsDark(v)){
                NSNumber *att = objc_getAssociatedObject(v, kADRNCheckKey);
                if (att.intValue < 4 && !objc_getAssociatedObject(v, kADRNInvertKey)){
                    objc_setAssociatedObject(v, kADRNCheckKey, @(att.intValue + 1),
                                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    // NOT here: this code path runs inside layoutSubviews, and
                    // rendering a view mid-layout is reentrant UIKit. Decide on
                    // the next turn, where snapshotting is legal.
                    dispatch_async(dispatch_get_main_queue(), ^{ @try {
                        if (objc_getAssociatedObject(v, kADRNInvertKey)) return;
                        UIGraphicsBeginImageContextWithOptions(v.bounds.size, NO, 1);
                        [v drawViewHierarchyInRect:v.bounds afterScreenUpdates:NO];
                        UIImage *im = UIGraphicsGetImageFromCurrentImageContext();
                        UIGraphicsEndImageContext();
                        if (im && ADIsDarkGlyph(im)) ADInvertRNSVGApply(v);
                    } @catch(...) {} });
                }
            }
        }
        if (!take) return;
        // Heal, don't just flag: React clears layer.filters when it re-renders a
        // mounted view, which is why every icon reverted to black after visiting
        // the dots menu. If our filters are gone, put them back.
        if (objc_getAssociatedObject(v, kADRNInvertKey) && v.layer.filters.count) return;
        ADInvertRNSVGApply(v);
    } @catch(...) {}
}
static void ADInvertRNSVGApply(UIView *v){
    @try {
        Class F = NSClassFromString(@"CAFilter");
        if (!F) return;
        id inv = [F filterWithType:@"colorInvert"];
        if (!inv) return;
        id hue = [F filterWithType:@"hueRotate"];
        @try { [hue setValue:@(M_PI) forKey:@"inputAngle"]; } @catch(...) { hue = nil; }
        NSArray *ours = hue ? @[inv, hue] : @[inv];
        v.layer.filters = ours;
        objc_setAssociatedObject(v, kADRNFiltersKey, ours, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(v, kADRNInvertKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (gRNLogLeft > 0){ gRNLogLeft--;
            ADLog(@"rnsvg inverted cls=%s %.0fx%.0f", object_getClassName(v),
                  v.bounds.size.width, v.bounds.size.height); }
    } @catch(...) {}
}

// ─── status bar: beat subclass overrides ────────────────────────────────────
static NSMutableDictionary *gSBOrig = nil;      // class name -> original IMP (as uintptr)
static int gSBLogLeft = 8;
static UIStatusBarStyle ADSBStyleImp(id self, SEL _cmd){
    if (gP.enabled) return UIStatusBarStyleLightContent;
    @try {
        Class c = object_getClass(self);
        while (c){
            NSNumber *v = gSBOrig[NSStringFromClass(c)];
            if (v){
                IMP orig = (IMP)(uintptr_t)[v unsignedLongLongValue];
                UIStatusBarStyle (*fn)(id, SEL) = (UIStatusBarStyle (*)(id, SEL))orig;
                if (fn) return fn(self, _cmd);
            }
            c = class_getSuperclass(c);
        }
    } @catch(...) {}
    return UIStatusBarStyleDefault;
}
// Walk from this VC's class up to UIViewController; the first class that
// implements preferredStatusBarStyle directly is the one deciding, so that is
// the one to replace. Runs once per class, then never again.
static NSMutableSet *gSBSeen = nil;
static void ADClaimStatusBarFor(Class c){
    @try {
        SEL sel = @selector(preferredStatusBarStyle);
        Class base = [UIViewController class];
        if (!gSBOrig) gSBOrig = [NSMutableDictionary dictionary];
        if (!gSBSeen) gSBSeen = [NSMutableSet set];
        // Examined once per class: copying a method list on every appearance is
        // exactly the kind of per-screen cost that shows up as scroll lag.
        if (!c) return;
        NSString *seenKey = NSStringFromClass(c);
        if ([gSBSeen containsObject:seenKey]) return;
        [gSBSeen addObject:seenKey];
        while (c && c != base){
            unsigned int n = 0;
            Method *ms = class_copyMethodList(c, &n);
            BOOL here = NO;
            for (unsigned i = 0; i < n; i++){
                if (method_getName(ms[i]) != sel) continue;
                here = YES;
                NSString *key = NSStringFromClass(c);
                if (!gSBOrig[key]){
                    IMP orig = method_getImplementation(ms[i]);
                    gSBOrig[key] = @((unsigned long long)(uintptr_t)orig);
                    method_setImplementation(ms[i], (IMP)ADSBStyleImp);
                    if (gSBLogLeft > 0){ gSBLogLeft--;
                        ADLog(@"statusbar: claimed %s", class_getName(c)); }
                }
                break;
            }
            free(ms);
            if (here) break;
            c = class_getSuperclass(c);
        }
    } @catch(...) {}
}

static int gTabDumpLeft = 16;   // one-shot budget, refreshed on each app launch
static int gSwImgSeen = 0, gSwGlyphFixed = 0, gSwDarkLabels = 0, gSwViews = 0;
static int gSwLabelFixed = 0, gSwTemplateSeen = 0, gSwTintFixed = 0;
static char gSwSample[96] = {0};
static char gSwTintNow[64] = {0};
static void ADSweepViewTree(UIView *v, int depth, BOOL inTabBar){
    if (!v || depth > 60) return;
    @try {
        if (ADIsWebKitOwned(v)) return;                 // Dark Reader's territory
        ADInvertRNSVG(v);                               // Alexa panel vector icons
        ADLaunchWhiteGuard(v);                          // launch-window white killer
        // Was `return`, which skipped this view AND everything under it -- including
        // the background fill. That is where the grey boxes behind the nav tabs came
        // from: an unthemed light fill sitting exactly where we refused to look, and
        // appearing or not depending on whether that view happened to be installed
        // for the current tab state. Only the icon and label work needs holding back
        // here; the fill still has to be darkened like everything else.
        BOOL tabBarish = inTabBar || ADIsTabBarItemish(v);   // INHERITED, not re-derived
        if (tabBarish && gTabDumpLeft > 0 &&
            ([v isKindOfClass:[UIImageView class]] || [v isKindOfClass:[UIButton class]])){
            @try {
                UIImage *di = [v isKindOfClass:[UIImageView class]] ? ((UIImageView *)v).image
                                                                    : ((UIButton *)v).currentImage;
                UIColor *dt = v.tintColor; CGFloat r,g,b,a; double tl = -1;
                if (dt && [dt getRed:&r green:&g blue:&b alpha:&a]) tl = 0.2126*r+0.7152*g+0.0722*b;
                BOOL ownbg = (v.backgroundColor && ADIsOwnColor(v.backgroundColor));
                UIImage *orig = di ? objc_getAssociatedObject(di, kADOrigImageKey) : nil;
                ADLog(@"tabdump cls=%s img=%d dark=%d tmpl=%d tint=%.2f rgb=%.2f,%.2f,%.2f sel=%d bg=%d orig=%d",
                      object_getClassName(v), di?1:0,
                      di?ADIsDarkGlyph(di):0, (di && ADImageIsTemplateish(di))?1:0,
                      tl, (tl>=0?r:0),(tl>=0?g:0),(tl>=0?b:0),
                      ADViewIsSelectedInBar(v)?1:0, ownbg?1:0, orig?1:0);
                gTabDumpLeft--;
            } @catch(...) {}
        }
        // Thin non-icon bar views: candidates for the selection indicator the user
        // wants white. Report class/size/background so it can be targeted exactly.
        if (tabBarish && gTabDumpLeft > 0 &&
            ![v isKindOfClass:[UIImageView class]] && ![v isKindOfClass:[UIButton class]]){
            @try {
                CGFloat hh = v.bounds.size.height, ww = v.bounds.size.width;
                if (hh > 0 && hh < 8 && ww > 12){
                    UIColor *bc = v.backgroundColor; double bl = -1; CGFloat br,bgc,bb,ba;
                    if (bc && [bc getRed:&br green:&bgc blue:&bb alpha:&ba]) bl = 0.2126*br+0.7152*bgc+0.0722*bb;
                    ADLog(@"tabline cls=%s w=%.0f h=%.1f bg=%.2f tagged=%d inchain=%d",
                          object_getClassName(v), ww, hh, bl,
                          ADIsTaggedIndicator(v) ? 1 : 0, ADInTabBarChain(v) ? 1 : 0);
                    gTabDumpLeft--;
                }
            } @catch(...) {}
        }
        if (tabBarish){
            const char *scn = object_getClassName(v);
            if (scn && strstr(scn, "BarBackgroundShadow")){
                ADTagIndicator(v);   // claim it, or the CALayer hook re-darkens the white
                ((UIView *)v).backgroundColor = ADBarWhite();   // whiten the top hairline
            }
            // Selection indicator: the short bar above the active symbol. It was being
            // logged but never recoloured, so it stayed the app's dark grey. Width is
            // what separates it from the full-width hairline -- the indicator spans one
            // tab, the separator spans the bar -- and it is only lit for the selected
            // tab so the others do not all light up.
            @try {
                CGFloat ih = v.bounds.size.height, iw = v.bounds.size.width;
                if (ih > 0 && ih < 8 && iw > 12 && iw < 160 &&
                    ![v isKindOfClass:[UIImageView class]] && ![v isKindOfClass:[UIButton class]]){
                    ADTagIndicator(v);                    // so reassignments stay white
                    ((UIView *)v).backgroundColor = ADBarWhite();
                }
            } @catch(...) {}
        }
        // Do not re-darken the tab indicator we just lit.
        BOOL isTabIndicator = NO;
        @try {
            CGFloat th = v.bounds.size.height, tw = v.bounds.size.width;
            isTabIndicator = (tabBarish && th > 0 && th < 8 && tw > 12 && tw < 160 &&
                              ![v isKindOfClass:[UIImageView class]] &&
                              ![v isKindOfClass:[UIButton class]]);
        } @catch(...) {}
        UIColor *bg = v.backgroundColor;
        if (!isTabIndicator && bg && !ADIsOwnColor(bg) && !ADIsModifiedUIColor(bg)) {
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

        // GLYPH RESCUE. Our setImage: hooks only fire when the app calls that setter.
        // An icon supplied through UIButtonConfiguration (iOS 15+), set during init,
        // or assigned before injection never triggers them and stays black. Reading
        // the CURRENT image here catches it regardless of how it got there — measured
        // on device, the search-pane X and history glyphs were still near-black under
        // v5.14.0, which means no setter path reached them. ADGlyphify caches both
        // outcomes, so a view swept repeatedly costs a dictionary lookup.
        gSwViews++;
        if ([v isKindOfClass:[UIImageView class]]){
            @try {
                UIImageView *iv = (UIImageView *)v;
                if (iv.image) gSwImgSeen++;
                if (tabBarish){
                    ADTintBarIcon(iv, ADViewIsSelectedInBar(iv));
                } else {
                if (iv.image && ADImageIsTemplateish(iv.image)){
                    gSwTemplateSeen++;
                    UIColor *tint = iv.tintColor;
                    CGFloat tr,tg,tb,ta;
                    if (tint && [tint getRed:&tr green:&tg blue:&tb alpha:&ta] &&
                        (0.2126*tr + 0.7152*tg + 0.0722*tb) < 0.45 && !tabBarish){
                        ((UIView *)iv).tintColor = ADColorFromHex(gP.fgHex);
                        gSwTintFixed++;
                    }
                    // Read back what a real template icon's tint RESOLVES to, whether
                    // or not we just changed it. Recording only on the fix path would
                    // go silent in exactly the steady state we need to inspect.
                    if (!gSwTintNow[0]){
                        @try {
                            CGFloat nr,ng,nb,na;
                            if ([((UIView *)iv).tintColor getRed:&nr green:&ng blue:&nb alpha:&na])
                                snprintf(gSwTintNow, sizeof(gSwTintNow), "%.2f,%.2f,%.2f", nr,ng,nb);
                        } @catch(...) {}
                    }
                }
                UIImage *tpl = ADGlyphifyForView(((UIImageView *)v).image, v);
                if (tpl) gSwGlyphFixed++;
                if (tpl){
                    ((UIView *)v).tintColor = ADColorFromHex(gP.fgHex);
                    ((UIImageView *)v).image = tpl;
                }
                }
            } @catch(...) {}
        } else if ([v isKindOfClass:[UIButton class]]){
            @try {
                UIButton *b = (UIButton *)v;
                if (tabBarish){ ADApplyBarTint(b, ADViewIsSelectedInBar(b)); }
                else {
                UIImage *cur = b.currentImage;
                if (cur && ADImageIsTemplateish(cur)){
                    gSwTemplateSeen++;
                    UIColor *tint = b.tintColor;
                    CGFloat tr,tg,tb,ta;
                    if (tint && [tint getRed:&tr green:&tg blue:&tb alpha:&ta] &&
                        (0.2126*tr + 0.7152*tg + 0.0722*tb) < 0.45 && !tabBarish){
                        ((UIView *)b).tintColor = ADColorFromHex(gP.fgHex);
                        gSwTintFixed++;
                    }
                }
                UIImage *tpl = ADGlyphifyForView(cur, b);
                if (tpl){
                    ((UIView *)b).tintColor = ADColorFromHex(gP.fgHex);
                    [b setImage:tpl forState:UIControlStateNormal];
                }
                }
            } @catch(...) {}
        }

        if (!tabBarish && [v isKindOfClass:[UILabel class]]){
            UILabel *l = (UILabel *)v;
            UIColor *tc = l.textColor;
            @try {
                CGFloat rr,gg,bb,aa;
                if (tc && [tc getRed:&rr green:&gg blue:&bb alpha:&aa] &&
                    (0.2126*rr+0.7152*gg+0.0722*bb) < 0.30) gSwDarkLabels++;
            } @catch(...) {}
            if (tc && !ADIsModifiedUIColor(tc)) {
                UIColor *mt = ADModifyUIColor(tc, ADColorRoleForeground);
                if (mt) { l.textColor = mt; gSwLabelFixed++; }
                else if (!gSwSample[0]) {
                    // Record ONE declined label so we can see what it actually is.
                    @try {
                        CGFloat r2,g2,b2,a2;
                        BOOL ok = [tc getRed:&r2 green:&g2 blue:&b2 alpha:&a2];
                        snprintf(gSwSample, sizeof(gSwSample), "%s rgba=%s%.2f,%.2f,%.2f,%.2f",
                                 object_getClassName(l), ok ? "" : "UNREADABLE ",
                                 ok?r2:0, ok?g2:0, ok?b2:0, ok?a2:0);
                    } @catch(...) {}
                }
            }
        } else if ([v respondsToSelector:@selector(textColor)] &&
                   [v respondsToSelector:@selector(setTextColor:)]) {
            // Any other view exposing textColor — UITextView/UITextField and Amazon's
            // own label subclasses. Needed because our setter hooks only fire when the
            // app ASSIGNS a colour: a label that never sets one and inherits the
            // default black is never intercepted, so the sweep is its only chance.
            // Measured on device: 'Search with photo' was sitting at pure rgb(0,0,0).
            @try {
                UIColor *tc = [(id)v textColor];
                if (tc && !ADIsModifiedUIColor(tc)){
                    UIColor *mt = ADModifyUIColor(tc, ADColorRoleForeground);
                    if (mt) [(id)v setTextColor:mt];
                }
            } @catch(...) {}
        }
        if (!tabBarish && [v isKindOfClass:[UIButton class]]){
            // Button titles follow the same rule, and a button whose title colour was
            // never explicitly set is exactly the case the setTitleColor: hook cannot see.
            @try {
                UIButton *b = (UIButton *)v;
                UIColor *tc = b.titleLabel.textColor;
                if (tc && !ADIsModifiedUIColor(tc)){
                    UIColor *mt = ADModifyUIColor(tc, ADColorRoleForeground);
                    if (mt) [b setTitleColor:mt forState:UIControlStateNormal];
                }
            } @catch(...) {}
        }
        for (UIView *s in v.subviews) ADSweepViewTree(s, depth + 1, tabBarish);
    } @catch(...) {}
}
// ─── sweep a cell as it comes into view ───────────────────────────────────────────
// The launch timer stops after ~40s by design, so content built later is only
// corrected when some unrelated event happens to fire a sweep. That is the "dark at
// first, correct once you have been scrolling a while" lag on the home feed: the
// transform is right, it is just arriving late.
//
// didMoveToWindow is the wrong moment -- a REUSED cell never leaves the window, so
// it would fire on first appearance and never again, which is exactly the scrolling
// case we need. layoutSubviews fires after the cell is reconfigured, so the colours
// we are about to read are the final ones. Guarded by a per-reuse flag cleared in
// prepareForReuse, so each cell is swept once per reuse cycle rather than on every
// layout pass.
static const void *kADCellSwept = &kADCellSwept;

%hook UICollectionViewCell
- (void)prepareForReuse {
    %orig;
    objc_setAssociatedObject(self, kADCellSwept, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (void)layoutSubviews {
    %orig;
    @try {
        if (!ADRecolorOn() || !self.window) return;
        if (objc_getAssociatedObject(self, kADCellSwept)) return;
        objc_setAssociatedObject(self, kADCellSwept, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Seed from real ancestry. Passing NO restarted the walk mid-tree with the
        // inherited flag cleared, so a tab bar built out of collection view cells had
        // its whole subtree treated as ordinary content -- undoing the v5.19.1 fix
        // for exactly the views it was meant to protect.
        ADSweepViewTree(self, 0, ADInTabBarChain(self));
    } @catch(...) {}
}
%end

%hook UITableViewCell
- (void)prepareForReuse {
    %orig;
    objc_setAssociatedObject(self, kADCellSwept, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (void)layoutSubviews {
    %orig;
    @try {
        if (!ADRecolorOn() || !self.window) return;
        if (objc_getAssociatedObject(self, kADCellSwept)) return;
        objc_setAssociatedObject(self, kADCellSwept, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ADSweepViewTree(self, 0, ADInTabBarChain(self));
    } @catch(...) {}
}
%end

static void ADSweepAllWindows(void){
    if (!ADRecolorOn()) return;
    @try {
        int nwin = 0;
        gSwViews = gSwImgSeen = gSwGlyphFixed = gSwDarkLabels = gSwLabelFixed = 0;
        gSwTemplateSeen = gSwTintFixed = 0;
        gSwSample[0] = 0;
        gSwTintNow[0] = 0;
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes){
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows){ nwin++; ADSweepViewTree(w, 0, NO); }
        }
        static NSString *last = nil;
        NSString *now = [NSString stringWithFormat:
                         @"win=%d views=%d img=%d tmpl=%d tintFixed=%d glyphFixed=%d darkLabels=%d labelFixed=%d%s%s%s%s",
                         nwin, gSwViews, gSwImgSeen, gSwTemplateSeen, gSwTintFixed,
                         gSwGlyphFixed, gSwDarkLabels, gSwLabelFixed,
                         gSwSample[0]  ? " declined=" : "", gSwSample[0]  ? gSwSample  : "",
                         gSwTintNow[0] ? " tintNow="  : "", gSwTintNow[0] ? gSwTintNow : ""];
        if (!last || ![last isEqualToString:now]){ last = now; ADLog(@"sweep %@", now); }
    } @catch(...) {}
}

// ════════════════════════════════════════════════════════════════════════════════
// Splash: while Dark Reader / native theme spin up, keep the launch screen dark so
// there is no white flash. Set the splash VC's own view backgroundColor (no invert).
// ════════════════════════════════════════════════════════════════════════════════
static UIColor *ADColorFromHex(const char *hex){
    unsigned int r=24,g=26,b=27;
    if (hex && hex[0]=='#') sscanf(hex+1, "%02x%02x%02x", &r,&g,&b);
    // Marked as ours: this is a finished theme colour, not an app colour awaiting
    // transformation. Without the mark, handing it to tintColor ran it through the
    // foreground curve and came back dark.
    return ADMarkOwnColor([UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1.0]);
}
// ─── launch-window white killer ─────────────────────────────────────────────────
// Setting the splash VC's backgroundColor was correct but insufficient: the 4+
// second white screen is an OPAQUE surface drawn over it -- most likely a
// fullscreen UIImageView whose bitmap bakes the logo into a white field, which
// no backgroundColor can darken. For the first 12 seconds of the process, any
// screen-covering view is inspected: a light background is repainted, and a
// mostly-light IMAGE gets the same colorInvert+hueRotate the RNSVG icons use --
// white field goes dark, dark logo goes light, coloured artwork keeps its hue.
// splashdump lines name every large surface seen, so if the white lives in a
// class this net misses, the next log says exactly which.
static double gADT0 = 0;
static inline double ADUptime(void){
    double now = CFAbsoluteTimeGetCurrent();
    if (gADT0 == 0) gADT0 = now;
    return now - gADT0;
}
static BOOL ADImageMostlyLight(UIImage *img){
    @try {
        CGImageRef src = img.CGImage;
        if (!src) return NO;
        enum { W = 12, H = 12 };
        uint8_t buf[W*H*4];
        memset(buf, 0, sizeof(buf));
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(buf, W, H, 8, W*4, cs,
                            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(cs);
        if (!ctx) return NO;
        CGContextDrawImage(ctx, CGRectMake(0,0,W,H), src);
        CGContextRelease(ctx);
        long n = 0; double sum = 0;
        for (int i = 0; i < W*H; i++){
            uint8_t *px = buf + i*4;
            if (px[3] < 100) continue;
            n++; sum += (0.2126*px[0] + 0.7152*px[1] + 0.0722*px[2]) / 255.0;
        }
        if (n < (long)(W*H*0.4)) return NO;   // mostly transparent: not a white field
        return (sum / n) > 0.60;
    } @catch(...) {}
    return NO;
}
static int gSplashDumpLeft = 10;
static int gSplashFixLeft  = 6;
static int gSplashPillLeft = 4;
static void ADLaunchWhiteGuard(UIView *v){
    @try {
        if (!gP.enabled || ADUptime() > 12.0) return;
        CGRect sb = [UIScreen mainScreen].bounds;
        CGFloat w = v.bounds.size.width, h = v.bounds.size.height;
        // The launch storyboard's decorative search-bar outline: a short, wide,
        // rounded/bordered pill near the top. On the dark launch frame it reads as
        // a stray border (reported as a "dynamic island border"). Hide it -- it is
        // decoration on a screen that exists for under a second.
        if (h >= 36 && h <= 96 && w >= sb.size.width*0.55 && w < sb.size.width*0.98 &&
            (v.layer.cornerRadius >= 12.0 || v.layer.borderWidth > 0.4)){
            if (gSplashPillLeft > 0){
                gSplashPillLeft--;
                ADLog(@"splashpill hid cls=%s %.0fx%.0f r=%.0f bw=%.1f",
                      object_getClassName(v), w, h,
                      (double)v.layer.cornerRadius, (double)v.layer.borderWidth);
            }
            v.layer.borderWidth = 0;
            v.hidden = YES;
            return;
        }
        if (w < sb.size.width*0.6 || h < sb.size.height*0.5) return;
        BOOL isIv = [v isKindOfClass:[UIImageView class]];
        UIImage *im = isIv ? ((UIImageView *)v).image : nil;
        UIColor *bg = v.backgroundColor; double bl = -1; CGFloat r,g,b,a;
        if (bg && [bg getRed:&r green:&g blue:&b alpha:&a] && a > 0.5)
            bl = 0.2126*r + 0.7152*g + 0.0722*b;
        if (gSplashDumpLeft > 0 && (im || bl >= 0)){
            gSplashDumpLeft--;
            ADLog(@"splashdump cls=%s %.0fx%.0f bg=%.2f img=%d light=%d t=%.1f",
                  object_getClassName(v), w, h, bl, im?1:0,
                  im?ADImageMostlyLight(im):0, ADUptime());
        }
        if (bl > 0.55 && !ADIsOwnColor(bg)) v.backgroundColor = ADColorFromHex(gP.bgHex);
        if (im && gSplashFixLeft > 0 && !objc_getAssociatedObject(v, kADRNInvertKey) &&
            ADImageMostlyLight(im)){
            Class F = NSClassFromString(@"CAFilter");
            if (F){
                id inv = [F filterWithType:@"colorInvert"];
                id hue = [F filterWithType:@"hueRotate"];
                @try { [hue setValue:@(M_PI) forKey:@"inputAngle"]; } @catch(...) { hue = nil; }
                if (inv){
                    NSArray *ours = hue ? @[inv, hue] : @[inv];
                    v.layer.filters = ours;
                    objc_setAssociatedObject(v, kADRNFiltersKey, ours, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    objc_setAssociatedObject(v, kADRNInvertKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    gSplashFixLeft--;
                    ADLog(@"splash inverted cls=%s %.0fx%.0f", object_getClassName(v), w, h);
                }
            }
        }
    } @catch(...) {}
}
static void ADDarkenSplashTree(UIView *v, int d){
    if (!v || d > 8) return;
    @try { ADLaunchWhiteGuard(v); for (UIView *sv in v.subviews) ADDarkenSplashTree(sv, d+1); } @catch(...) {}
}
static void ADDarkenSplash(UIViewController *vc){
    if (!gP.enabled) return;
    @try {
        UIView *v = vc.view;
        if (v){ v.backgroundColor = ADColorFromHex(gP.bgHex); ADDarkenSplashTree(v, 0); }
    } @catch(...) {}
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
            NSString *vcKey = [NSString stringWithUTF8String:object_getClassName(self)];
            static NSMutableSet *vcSeen = nil;
            if (!vcSeen) vcSeen = [NSMutableSet set];
            if (![vcSeen containsObject:vcKey]){
                [vcSeen addObject:vcKey];
                ADLog(@"screen: %@", vcKey);
            }
            gProbeArmed = YES;
            @try {
                if (gP.enabled){
                    ADClaimStatusBarFor(object_getClass(self));
                    // Children decide as often as containers do on RN screens.
                    for (UIViewController *ch in self.childViewControllers)
                        ADClaimStatusBarFor(object_getClass(ch));
                    if (gSBLogLeft > 0){ gSBLogLeft--;
                        ADLog(@"statusbar: vc=%s appStyle=%ld",
                              object_getClassName(self),
                              (long)[UIApplication sharedApplication].statusBarStyle); }
                }
            } @catch(...) {}
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

// React Native's StatusBar module sets the style through the legacy
// UIApplication API, which never consults any view controller. Force it light.
%hook UIApplication
- (void)setStatusBarStyle:(UIStatusBarStyle)style {
    if (gP.enabled && style != UIStatusBarStyleLightContent){
        %orig(UIStatusBarStyleLightContent);
        return;
    }
    %orig;
}
- (void)setStatusBarStyle:(UIStatusBarStyle)style animated:(BOOL)animated {
    if (gP.enabled && style != UIStatusBarStyleLightContent){
        %orig(UIStatusBarStyleLightContent, animated);
        return;
    }
    %orig;
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
    ADRaw("[AmazonDark] " AD_VERSION " init (DarkReader web + native colour engine)");
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
