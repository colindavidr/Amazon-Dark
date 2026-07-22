/*
 * AmazonDark — Settings pane, mirroring CarBridgeReborn's proven structure.
 *
 * History that shaped this file: three earlier designs took Settings down.
 * v5.53/54 died inside -[PSListController loadSpecifiersFromPlistName:] (per
 * crash report), v5.55 died inside a hand-rolled specifier builder (per
 * AD_prefs_live.txt, which stopped after "specifiers called"), and v5.56's
 * executable-free bundle could not load at all ("executable couldn't be
 * located"). CBR runs fine on this exact device, so this follows it closely:
 * no private-framework linkage, runtime class lookups, %subclass registered
 * in %ctor, plist load with a manual fallback, and the Respring action on a
 * navigation bar button rather than a PSButtonCell action.
 *
 * Every step logs. If this still faults, the last line in the log names the
 * exact call that did it.
 */
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>

static void ADPLog(const char *m){
    int fd = open("/var/mobile/AD_prefs_live.txt", O_WRONLY|O_CREAT|O_APPEND, 0644);
    if (fd >= 0){ write(fd, m, strlen(m)); write(fd, "\n", 1); close(fd); }
}

#define AD_DOMAIN    @"com.colindavidr.amazondark"
#define AD_JB_PLIST  @"/var/jb/var/mobile/Library/Preferences/com.colindavidr.amazondark.plist"
#define BUNDLE_PATH  @"/var/jb/Library/PreferenceBundles/ADPrefs.bundle"

// THE CRASH, at last. %subclass builds ADRootListController at RUNTIME, so the
// class belongs to no Mach-O image -- and PSListController's default -bundle
// resolves through +bundleForClass:, which cannot find an image for a runtime
// class. loadSpecifiersFromPlistName: then runs against a nil/garbage bundle
// and faults, which is exactly where every log stops. A hardcoded /var/jb path
// was not enough either: this jailbreak mounts at /private/preboot/<UUID>/jb
// and /var/jb may not resolve. dladdr gives the real on-disk path of the very
// binary this code is executing from, so the bundle is found whatever the
// layout.
static NSBundle *ADOwnBundle(void){
    static NSBundle *cached = nil;
    if (cached) return cached;
    @try {
        Dl_info info;
        if (dladdr((const void *)&ADOwnBundle, &info) && info.dli_fname){
            NSString *exe = [NSString stringWithUTF8String:info.dli_fname];
            NSString *dir = [exe stringByDeletingLastPathComponent];
            cached = [NSBundle bundleWithPath:dir];
            char b[512];
            snprintf(b, sizeof(b), "[prefs] image=%s bundle=%s",
                     info.dli_fname, cached ? "OK" : "nil");
            ADPLog(b);
        }
    } @catch (NSException *e) {}
    if (!cached) cached = [NSBundle bundleWithPath:BUNDLE_PATH];
    ADPLog(cached ? "[prefs] own bundle resolved" : "[prefs] own bundle NIL");
    return cached;
}
#define AD_SWITCHCELL 6

@interface PSSpecifier : NSObject
+ (id)groupSpecifierWithName:(NSString *)name;
+ (id)preferenceSpecifierNamed:(NSString *)name target:(id)target set:(SEL)set get:(SEL)get detail:(Class)detail cell:(NSInteger)cell edit:(Class)edit;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
@end

@interface PSListController : UIViewController
- (id)specifiers;
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)plistName target:(id)target;
@end

@interface SBSRelaunchAction : NSObject
+ (instancetype)actionWithReason:(NSString *)reason options:(NSUInteger)options targetURL:(NSURL *)url;
@end
@interface FBSSystemService : NSObject
+ (instancetype)sharedService;
- (void)sendActions:(NSSet *)actions withResult:(id)result;
@end

static void ADWriteBoth(NSString *key, id value){
    @try {
        CFPreferencesSetAppValue((__bridge CFStringRef)key,
                                 (__bridge CFPropertyListRef)value,
                                 (__bridge CFStringRef)AD_DOMAIN);
        CFPreferencesAppSynchronize((__bridge CFStringRef)AD_DOMAIN);
    } @catch (NSException *e) {}
    @try {
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:AD_JB_PLIST]
                                 ?: [NSMutableDictionary dictionary];
        d[key] = value;
        [d writeToFile:AD_JB_PLIST atomically:YES];
    } @catch (NSException *e) {}
    @try {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFSTR("com.colindavidr.amazondark/prefs-changed"), NULL, NULL, YES);
    } @catch (NSException *e) {}
}

%subclass ADRootListController : PSListController

- (id)navigationTitle { return @"AmazonDark"; }

- (NSBundle *)bundle {
    NSBundle *b = ADOwnBundle();
    if (b) return b;
    return %orig;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    @try {
        NSString *key = [specifier propertyForKey:@"key"];
        if (!key.length) return @YES;
        NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:AD_JB_PLIST];
        id v = file[key];
        if (v) return v;
        CFPropertyListRef cv = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                         (__bridge CFStringRef)AD_DOMAIN);
        if (cv) return (__bridge_transfer id)cv;
        id def = [specifier propertyForKey:@"default"];
        return def ?: @YES;
    } @catch (NSException *e) { return @YES; }
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    @try {
        NSString *key = [specifier propertyForKey:@"key"];
        if (key.length) ADWriteBoth(key, value);
    } @catch (NSException *e) {}
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    // Respring lives on a nav-bar button (CBR's approach) instead of a
    // PSButtonCell action -- one less specifier mechanism in the crash path.
    @try {
        UIViewController *vc = (UIViewController *)self;
        if (!vc.navigationItem.rightBarButtonItem){
            vc.navigationItem.rightBarButtonItem =
                [[UIBarButtonItem alloc] initWithTitle:@"Respring"
                                                 style:UIBarButtonItemStyleDone
                                                target:self
                                                action:@selector(adRespringTapped)];
        }
    } @catch (NSException *e) {}
}

%new
- (void)adRespringTapped {
    ADPLog("[prefs] respring tapped");
    @try {
        SBSRelaunchAction *a = [%c(SBSRelaunchAction) actionWithReason:@"AmazonDark"
                                                               options:(1 << 2) targetURL:nil];
        [[%c(FBSSystemService) sharedService] sendActions:[NSSet setWithObject:a] withResult:nil];
    } @catch (NSException *e) {}
}

- (id)specifiers {
    ADPLog("[prefs] specifiers: enter");
    NSArray *specs = nil;
    @try {
        NSBundle *ob = ADOwnBundle();
        NSString *rp = [ob pathForResource:@"Root" ofType:@"plist"];
        ADPLog(rp.length ? "[prefs] Root.plist found in bundle"
                         : "[prefs] Root.plist NOT found in bundle");
    } @catch (NSException *e) { ADPLog("[prefs] bundle probe EXCEPTION"); }
    @try {
        specs = [(PSListController *)self loadSpecifiersFromPlistName:@"Root" target:self];
        ADPLog(specs.count ? "[prefs] specifiers: plist load OK" : "[prefs] specifiers: plist load EMPTY");
    } @catch (NSException *e) {
        ADPLog("[prefs] specifiers: plist load EXCEPTION");
        specs = nil;
    }
    if (!specs.count){
        @try {
            ADPLog("[prefs] specifiers: manual group");
            NSMutableArray *out = [NSMutableArray array];
            [out addObject:[%c(PSSpecifier) groupSpecifierWithName:@"AmazonDark"]];
            ADPLog("[prefs] specifiers: manual switch");
            PSSpecifier *sw = [%c(PSSpecifier) preferenceSpecifierNamed:@"Enabled"
                                  target:self
                                     set:@selector(setPreferenceValue:specifier:)
                                     get:@selector(readPreferenceValue:)
                                  detail:nil cell:AD_SWITCHCELL edit:nil];
            [sw setProperty:@"enabled" forKey:@"key"];
            [sw setProperty:AD_DOMAIN  forKey:@"defaults"];
            [sw setProperty:@YES       forKey:@"default"];
            [out addObject:sw];
            specs = out;
            ADPLog("[prefs] specifiers: manual built");
        } @catch (NSException *e) {
            ADPLog("[prefs] specifiers: manual EXCEPTION");
            specs = @[];
        }
    }
    @try {
        // Associate FIRST: object_setIvar does not retain under ARC, so writing
        // an autoreleased array into _specifiers leaves a dangling pointer once
        // the pool drains. The association owns it for the controller's life.
        objc_setAssociatedObject(self, "adSpecs", specs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        Ivar iv = class_getInstanceVariable(%c(PSListController), "_specifiers");
        ADPLog(iv ? "[prefs] specifiers: ivar found" : "[prefs] specifiers: ivar MISSING");
        if (iv) object_setIvar(self, iv, specs);
    } @catch (NSException *e) { ADPLog("[prefs] specifiers: ivar EXCEPTION"); }
    ADPLog("[prefs] specifiers: returning");
    return specs;
}

%end

%ctor {
    ADPLog("[prefs] ctor entered");
    if (!objc_getClass("PSListController"))
        dlopen("/System/Library/PrivateFrameworks/Preferences.framework/Preferences", RTLD_LAZY);
    ADPLog(objc_getClass("PSListController") ? "[prefs] PSListController FOUND"
                                            : "[prefs] PSListController MISSING");
    %init;
    ADPLog(objc_getClass("ADRootListController") ? "[prefs] subclass OK" : "[prefs] subclass MISSING");
}
