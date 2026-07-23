// AmazonDarkSB.xm
// SpringBoard-side dark cover for the Amazon Shopping launch screen.
//
// Injected ONLY into com.apple.springboard (see AmazonDarkSB.plist). The system
// draws Amazon's white LaunchScreen storyboard/snapshot from the render server
// BEFORE Amazon's own process (and the main AmazonDark tweak) is alive, so that
// frame cannot be themed from inside Amazon. Here, in SpringBoard, we drop a
// dark view over Amazon's launching scene and pull it a few seconds later.
//
// SAFETY (this runs in SpringBoard, so a fault here = safe mode):
//   - every hook body is wrapped in @try/@catch, nothing escapes;
//   - the cover removes itself on a hard timer and an absolute cap, so it can
//     NEVER get stuck blacking out the screen;
//   - we only touch a scene whose bundle id is EXACTLY com.amazon.Amazon;
//   - a class/keypath log is written so we can confirm the hook landed.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString * const kAMZ      = @"com.amazon.Amazon";
static NSString * const kDefaults = @"com.colindavidr.amazondark";
static const NSTimeInterval kCoverHold    = 3.5;  // dark cover visible time
static const NSTimeInterval kCoverFade    = 0.45; // fade-out duration
static const NSTimeInterval kCoverHardCap = 7.0;  // absolute max on screen

@interface SBSceneView : UIView
@end

static const void *kCoverKey        = &kCoverKey;
static const void *kCoveredOnceKey  = &kCoveredOnceKey;

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

// Best-effort bundle id for whatever scene-view class SpringBoard hands us.
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

static void ADRemoveCover(UIView *host) {
    @try {
        UIView *cover = objc_getAssociatedObject(host, kCoverKey);
        if (!cover) return;
        objc_setAssociatedObject(host, kCoverKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [UIView animateWithDuration:kCoverFade animations:^{ cover.alpha = 0.0; }
                         completion:^(BOOL f){ @try { [cover removeFromSuperview]; } @catch (__unused NSException *e) {} }];
    } @catch (__unused NSException *e) {}
}

static void ADAddCover(UIView *host) {
    @try {
        if (!host || !host.window) return;
        if (objc_getAssociatedObject(host, kCoverKey)) return; // already covering
        CGRect b = CGRectIsEmpty(host.bounds) ? [UIScreen mainScreen].bounds : host.bounds;
        UIView *cover = [[UIView alloc] initWithFrame:b];
        cover.backgroundColor = [UIColor colorWithRed:0x18/255.0 green:0x1a/255.0 blue:0x1b/255.0 alpha:1.0];
        cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        cover.userInteractionEnabled = NO;
        [host addSubview:cover];
        objc_setAssociatedObject(host, kCoverKey, cover, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ADSBLog(@"COVER added");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kCoverHold * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ ADRemoveCover(host); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kCoverHardCap * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                UIView *c = objc_getAssociatedObject(host, kCoverKey);
                if (c) { objc_setAssociatedObject(host, kCoverKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                         [c removeFromSuperview]; ADSBLog(@"COVER hardcap-removed"); }
            } @catch (__unused NSException *e) {}
        });
    } @catch (__unused NSException *e) {}
}

%hook SBSceneView
- (void)didMoveToWindow {
    %orig;
    @try {
        if (!self.window) return;

        // Learn the real class + which keypath yields a bundle id, once per class.
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

        // Cover once per scene-view instance (a cold relaunch makes a new one,
        // so each launch is still covered; a background->resume is not).
        if (objc_getAssociatedObject(self, kCoveredOnceKey)) return;
        objc_setAssociatedObject(self, kCoveredOnceKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ADSBLog(@"AMAZON scene -> cover");
        ADAddCover(self);
    } @catch (__unused NSException *e) {}
}
%end

%ctor {
    @autoreleasepool {
        @try { %init; ADSBLog(@"AmazonDarkSB ctor"); }
        @catch (__unused NSException *e) {}
    }
}
