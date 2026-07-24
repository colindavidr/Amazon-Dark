// AmazonDarkSB.xm
// SpringBoard-side dark cover for the Amazon Shopping launch screen.
//
// Injected ONLY into com.apple.springboard (AmazonDarkSB.plist). Amazon's white
// LaunchScreen is drawn by the render server before Amazon's process is alive,
// so it can't be themed from inside Amazon. Here we float a dark WINDOW over the
// launching Amazon scene and lift it a few seconds later.
//
// Why a separate window and not a subview of the scene: an opaque view placed
// INSIDE SBSceneView makes FrontBoard treat Amazon's scene as fully occluded, so
// it suspends rendering and the app never draws (permanent black). A separate
// SpringBoard window floats on top without changing the app scene's occlusion,
// so Amazon renders normally underneath and is there the instant we lift it.
//
// SAFETY (runs in SpringBoard => a fault here is safe mode):
//   - every entry point is @try/@catch guarded;
//   - the cover window lifts on a timer AND an absolute hard cap, so it can
//     never get stuck blacking out the screen;
//   - only ever triggered by a scene whose bundle id is exactly Amazon.

#import <UIKit/UIKit.h>
#import <notify.h>
#import <objc/runtime.h>

static NSString * const kAMZ      = @"com.amazon.Amazon";
static NSString * const kDefaults = @"com.colindavidr.amazondark";
static const NSTimeInterval kCoverHold    = 3.0;  // dark cover visible time
static const NSTimeInterval kCoverFade    = 0.30; // lift animation
static const NSTimeInterval kCoverHardCap = 6.0;  // absolute max on screen
static const NSTimeInterval kReCoverGap   = 8.0;  // ignore re-triggers within

@interface SBSceneView : UIView
@end

@interface UIImage (AD)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bid format:(int)fmt scale:(CGFloat)scale;
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bid format:(int)fmt;
@end

static UIWindow *gCoverWin;
static double gPresentAt;
static NSTimeInterval gLastPresent;

static void ADSBLog(NSString *msg) {
    @try {
        static NSFileHandle *fh; static dispatch_once_t once;
        dispatch_once(&once, ^{
            NSString *p = @"/var/mobile/AmazonDarkSB.log";
            [[NSFileManager defaultManager] createFileAtPath:p contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:p];
        });
        NSString *line = [NSString stringWithFormat:@"%f %@\n", CFAbsoluteTimeGetCurrent(), msg];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    } @catch (__unused NSException *e) {}
}

static BOOL ADSBEnabled(void) {
    @try {
        CFPreferencesAppSynchronize((__bridge CFStringRef)kDefaults);
        Boolean valid = NO;
        Boolean on = CFPreferencesGetAppBooleanValue(CFSTR("enabled"),
                        (__bridge CFStringRef)kDefaults, &valid);
        return valid ? (on ? YES : NO) : YES;   // default on
    } @catch (__unused NSException *e) { return YES; }
}

static NSString *ADSceneBundleId(UIView *v, NSString **hitPathOut) {
    NSArray *paths = @[ @"sceneHandle.application.bundleIdentifier",
                        @"sceneHandle.sceneIdentity.bundleIdentifier",
                        @"application.bundleIdentifier",
                        @"sceneHandle.sceneIdentity.bundleIdentifierOverride",
                        @"_sceneHandle.application.bundleIdentifier" ];
    for (NSString *kp in paths) {
        @try {
            id val = [v valueForKeyPath:kp];
            if ([val isKindOfClass:[NSString class]] && [(NSString *)val length]) {
                if (hitPathOut) *hitPathOut = kp;
                return (NSString *)val;
            }
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

static UIWindowScene *ADForegroundWindowScene(void) {
    @try {
        NSArray *scenes = [[UIApplication sharedApplication].connectedScenes allObjects];
        for (UIScene *s in scenes)
            if ([s isKindOfClass:[UIWindowScene class]] &&
                s.activationState == UISceneActivationStateForegroundActive)
                return (UIWindowScene *)s;
        for (UIScene *s in scenes)
            if ([s isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)s;
    } @catch (__unused NSException *e) {}
    return nil;
}

static void ADDismissCover(void) {
    @try {
        if (!gCoverWin) return;
        UIWindow *w = gCoverWin; gCoverWin = nil;
        [UIView animateWithDuration:kCoverFade animations:^{ w.alpha = 0.0; }
                         completion:^(BOOL f){ @try { w.hidden = YES; } @catch (__unused NSException *e) {} }];
        ADSBLog(@"COVER dismissed");
    } @catch (__unused NSException *e) {}
}

static void ADPresentCover(void) {
    @try {
        NSTimeInterval now = CFAbsoluteTimeGetCurrent();
        if (gCoverWin) return;
        if (now - gLastPresent < kReCoverGap) return;
        gLastPresent = now;

        UIWindow *w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        UIWindowScene *sc = ADForegroundWindowScene();
        if (sc) w.windowScene = sc;
        UIColor *dark = [UIColor colorWithRed:0x18/255.0 green:0x1a/255.0 blue:0x1b/255.0 alpha:1.0];
        UIViewController *vc = [UIViewController new];
        vc.view.backgroundColor = dark;
        w.rootViewController = vc;
        w.backgroundColor = dark;

        // Inverted splash logo, generated from the app's own launch screen: dark
        // ground, light wordmark, the orange smile kept orange. Falls back to the
        // rounded app icon only if the packaged asset is missing.
        BOOL usedSplash = NO;
        @try {
            UIImage *splash = nil;
            NSArray *cand = @[@"/var/jb/Library/Application Support/AmazonDark/splash-logo.png",
                              @"/Library/Application Support/AmazonDark/splash-logo.png"];
            for (NSString *cp in cand) {
                splash = [UIImage imageWithContentsOfFile:cp];
                if (splash) break;
            }
            if (splash) {
                UIImageView *logo = [[UIImageView alloc] initWithImage:splash];
                logo.contentMode = UIViewContentModeScaleAspectFit;   // wordmark: no
                logo.translatesAutoresizingMaskIntoConstraints = NO;  // corner mask
                logo.tag = 7741;
                [vc.view addSubview:logo];
                CGFloat lw = [UIScreen mainScreen].bounds.size.width * 0.62;
                CGFloat lh = lw * (splash.size.height / MAX(splash.size.width, 1.0));
                [NSLayoutConstraint activateConstraints:@[
                    [logo.centerXAnchor constraintEqualToAnchor:vc.view.centerXAnchor],
                    [logo.centerYAnchor constraintEqualToAnchor:vc.view.centerYAnchor],
                    [logo.widthAnchor constraintEqualToConstant:lw],
                    [logo.heightAnchor constraintEqualToConstant:lh],
                ]];
                usedSplash = YES;
                ADSBLog([NSString stringWithFormat:@"COVER splash logo (%.0fx%.0f)", splash.size.width, splash.size.height]);
            }
        } @catch (__unused NSException *e) {}
        @try {
            if (usedSplash) goto coverAssembled;
            UIImage *icon = nil;
            if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)])
                icon = [UIImage _applicationIconImageForBundleIdentifier:kAMZ format:2 scale:[UIScreen mainScreen].scale];
            if (!icon && [UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:)])
                icon = [UIImage _applicationIconImageForBundleIdentifier:kAMZ format:2];
            if (icon) {
                UIImageView *logo = [[UIImageView alloc] initWithImage:icon];
                logo.contentMode = UIViewContentModeScaleAspectFit;
                logo.translatesAutoresizingMaskIntoConstraints = NO;
                logo.tag = 7741;
                logo.layer.cornerRadius = 22.0;
                logo.layer.masksToBounds = YES;
                [vc.view addSubview:logo];
                [NSLayoutConstraint activateConstraints:@[
                    [logo.centerXAnchor constraintEqualToAnchor:vc.view.centerXAnchor],
                    [logo.centerYAnchor constraintEqualToAnchor:vc.view.centerYAnchor],
                    [logo.widthAnchor constraintEqualToConstant:132.0],
                    [logo.heightAnchor constraintEqualToConstant:132.0],
                ]];
                ADSBLog(@"COVER logo added");
            } else { ADSBLog(@"COVER logo unavailable"); }
        } @catch (__unused NSException *e) {}
        coverAssembled:;
        w.windowLevel = UIWindowLevelAlert + 1.0;
        w.userInteractionEnabled = NO;

        // INSTANT COVERAGE, SETTLE INSIDE. A grow-from-small cover exposes the
        // system's light launch frame (and the storyboard pill) around it while
        // it scales -- exactly the regression reported. So the surface is
        // full-screen from its first frame with only a fast opacity ramp to
        // avoid a hard cut, and the stock-launch feel comes from the LOGO
        // settling (0.92 -> 1.0 spring + fade) inside the already-opaque cover.
        UIView *cv = w.rootViewController.view;
        UIView *lg = [cv viewWithTag:7741];
        BOOL adReduce = UIAccessibilityIsReduceMotionEnabled();
        w.alpha = 0.25;                    // substantial coverage on frame one
        if (lg && !adReduce){
            lg.alpha = 0.0;
            lg.transform = CGAffineTransformMakeScale(0.92, 0.92);
        }
        w.hidden = NO;   // show without becoming key (don't steal input focus)
        [UIView animateWithDuration:0.14 animations:^{ w.alpha = 1.0; }];
        if (lg && !adReduce){
            [UIView animateWithDuration:0.45 delay:0.05
                 usingSpringWithDamping:0.85 initialSpringVelocity:0.3
                                options:UIViewAnimationOptionCurveEaseOut
                             animations:^{
                                 lg.alpha = 1.0;
                                 lg.transform = CGAffineTransformIdentity;
                             } completion:nil];
        } else if (lg){
            lg.alpha = 0.0;
            [UIView animateWithDuration:0.20 animations:^{ lg.alpha = 1.0; }];
        }
                gCoverWin = w;
        gPresentAt = CFAbsoluteTimeGetCurrent();
        ADSBLog(@"COVER presented (settle)");

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kCoverHold * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ ADDismissCover(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kCoverHardCap * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try { if (gCoverWin) { UIWindow *x = gCoverWin; gCoverWin = nil; x.hidden = YES; ADSBLog(@"COVER hardcap"); } }
            @catch (__unused NSException *e) {}
        });
    } @catch (__unused NSException *e) {}
}

%hook SBSceneView
- (void)didMoveToWindow {
    %orig;
    @try {
        if (!self.window) return;

        static NSMutableSet *seen; static dispatch_once_t once;
        dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
        NSString *cls = NSStringFromClass([self class]);

        if (!ADSBEnabled()) return;
        NSString *hitPath = nil;
        NSString *bid = ADSceneBundleId(self, &hitPath);
        if (![seen containsObject:cls]) {
            [seen addObject:cls];
            ADSBLog([NSString stringWithFormat:@"SCENE class=%@ bid=%@ via=%@", cls, bid ?: @"-", hitPath ?: @"-"]);
        }
        if (![bid isEqualToString:kAMZ]) return;

        ADSBLog(@"AMAZON scene -> present cover");
        ADPresentCover();
    } @catch (__unused NSException *e) {}
}
%end

%ctor {
    // Event-driven dismissal, matching the system: the launch screen leaves at
    // the app's first frame, not on a timer. The app posts this once its UI is
    // up; the kCoverHold timer stays only as a fallback for a launch where the
    // signal never arrives.
    @try {
        static int adReadyToken = 0;
        notify_register_dispatch("com.colindavidr.amazondark.ready", &adReadyToken,
                                 dispatch_get_main_queue(), ^(int t){
            @try {
                if (!gCoverWin) return;
                double shown = CFAbsoluteTimeGetCurrent() - gPresentAt;
                double wait  = shown < 0.50 ? (0.50 - shown) : 0.0;  // no strobe
                ADSBLog([NSString stringWithFormat:@"COVER ready (shown %.2fs, wait %.2fs)", shown, wait]);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ ADDismissCover(); });
            } @catch (__unused NSException *e) {}
        });
    } @catch (__unused NSException *e) {}
    @autoreleasepool {
        @try { %init; ADSBLog(@"AmazonDarkSB ctor"); }
        @catch (__unused NSException *e) {}
    }
}
