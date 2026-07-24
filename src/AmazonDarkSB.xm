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
#import <objc/runtime.h>

static NSString * const kAMZ      = @"com.amazon.Amazon";
static NSString * const kDefaults = @"com.colindavidr.amazondark";
static const NSTimeInterval kCoverHold    = 3.0;  // dark cover visible time
static const NSTimeInterval kCoverFade    = 0.40; // lift animation
static const NSTimeInterval kCoverHardCap = 6.0;  // absolute max on screen
static const NSTimeInterval kReCoverGap   = 8.0;  // ignore re-triggers within

@interface SBSceneView : UIView
@end

@interface UIImage (AD)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bid format:(int)fmt scale:(CGFloat)scale;
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bid format:(int)fmt;
@end

static UIWindow *gCoverWin;
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

        // Centered Amazon app icon -> the dark loading screen reads as a proper
        // splash instead of a black void.
        @try {
            UIImage *icon = nil;
            if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)])
                icon = [UIImage _applicationIconImageForBundleIdentifier:kAMZ format:2 scale:[UIScreen mainScreen].scale];
            if (!icon && [UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:)])
                icon = [UIImage _applicationIconImageForBundleIdentifier:kAMZ format:2];
            if (icon) {
                UIImageView *logo = [[UIImageView alloc] initWithImage:icon];
                logo.contentMode = UIViewContentModeScaleAspectFit;
                logo.translatesAutoresizingMaskIntoConstraints = NO;
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
        w.windowLevel = UIWindowLevelAlert + 1.0;
        w.userInteractionEnabled = NO;
        w.hidden = NO;   // show without becoming key (don't steal input focus)
        gCoverWin = w;
        ADSBLog(@"COVER presented");

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
    @autoreleasepool {
        @try { %init; ADSBLog(@"AmazonDarkSB ctor"); }
        @catch (__unused NSException *e) {}
    }
}
