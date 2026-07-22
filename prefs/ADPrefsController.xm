/*
 * AmazonDark — Settings pane, rebuilt on the CarBridgeReborn pattern.
 *
 * The previous pane linked Preferences.framework at compile time
 * (ADPrefs_PRIVATE_FRAMEWORKS = Preferences) and subclassed PSListController
 * statically. On this jailbreak that made the bundle unloadable inside
 * Settings — dyld failed resolving the private framework and Settings died
 * the moment the pane was opened. CarBridgeReborn's pane works because it
 * links NOTHING private: interfaces declared locally, every class resolved
 * at runtime with %c(), controller created as a Logos %subclass registered
 * in %ctor when Settings loads the bundle.
 *
 * Scope deliberately minimal per request: an Enabled switch and a Respring
 * button. Values are written BOTH to CFPreferences (the suite the tweak
 * merges) and to the /var/jb plist the tweak reads directly, then the
 * Darwin notification nudges a running Amazon.
 */
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>

// Plain syscall logging (CBR pattern): safe at ctor time, and it tells us
// whether the bundle loads at all when the pane still misbehaves.
static void ADPLog(const char *m){
    int fd = open("/var/mobile/AD_prefs_live.txt", O_WRONLY|O_CREAT|O_APPEND, 0644);
    if (fd >= 0){ write(fd, m, strlen(m)); write(fd, "\n", 1); close(fd); }
}

#define AD_DOMAIN   @"com.colindavidr.amazondark"
#define AD_JB_PLIST @"/var/jb/var/mobile/Library/Preferences/com.colindavidr.amazondark.plist"
#define AD_BUNDLE   @"/var/jb/Library/PreferenceBundles/ADPrefs.bundle"

@interface PSSpecifier : NSObject
+ (id)groupSpecifierWithName:(NSString *)name;
+ (id)preferenceSpecifierNamed:(NSString *)name target:(id)target set:(SEL)set get:(SEL)get detail:(Class)detail cell:(NSInteger)cell edit:(Class)edit;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
- (void)setButtonAction:(SEL)action;
@end

@interface PSListController : UIViewController
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)plistName target:(id)target;
- (NSBundle *)bundle;
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
        NSMutableDictionary *d =
            [NSMutableDictionary dictionaryWithContentsOfFile:AD_JB_PLIST]
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
    NSBundle *b = [NSBundle bundleWithPath:AD_BUNDLE];
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

- (id)specifiers {
    ADPLog("[prefs] specifiers called");
    @try {
        NSArray *specs = [(PSListController *)self loadSpecifiersFromPlistName:@"Root" target:self];
        if (specs.count){
            Ivar iv = class_getInstanceVariable(%c(PSListController), "_specifiers");
            if (iv) object_setIvar(self, iv, specs);
            objc_setAssociatedObject(self, "adSpecs", specs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return specs;
        }
    } @catch (NSException *e) {}
    // Fallback: build the two rows by hand so a plist problem can never take
    // Settings down with it.
    @try {
        NSMutableArray *out = [NSMutableArray array];
        [out addObject:[%c(PSSpecifier) groupSpecifierWithName:@"AmazonDark"]];
        PSSpecifier *sw = [%c(PSSpecifier) preferenceSpecifierNamed:@"Enabled" target:self
                              set:@selector(setPreferenceValue:specifier:)
                              get:@selector(readPreferenceValue:)
                           detail:nil cell:6 edit:nil];          // 6 = PSSwitchCell
        [sw setProperty:@"enabled" forKey:@"key"];
        [sw setProperty:AD_DOMAIN  forKey:@"defaults"];
        [sw setProperty:@YES       forKey:@"default"];
        [out addObject:sw];
        PSSpecifier *bt = [%c(PSSpecifier) preferenceSpecifierNamed:@"Respring" target:self
                              set:NULL get:NULL detail:nil cell:13 edit:nil];   // 13 = PSButtonCell
        @try { [bt setButtonAction:@selector(adRespring)]; } @catch (NSException *e) {}
        [out addObject:bt];
        Ivar iv = class_getInstanceVariable(%c(PSListController), "_specifiers");
        if (iv) object_setIvar(self, iv, out);
        objc_setAssociatedObject(self, "adSpecs", out, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return out;
    } @catch (NSException *e) { return @[]; }
}

%new
- (void)adRespring {
    @try {
        NSUInteger opts = (1 << 2);   // fade-to-black respring
        SBSRelaunchAction *a = [%c(SBSRelaunchAction) actionWithReason:@"AmazonDark"
                                                               options:opts targetURL:nil];
        [[%c(FBSSystemService) sharedService] sendActions:[NSSet setWithObject:a] withResult:nil];
    } @catch (NSException *e) {}
}

%end

%ctor {
    ADPLog("[prefs] ctor entered");
    // THE CRASH: %subclass needs PSListController to EXIST when %init runs.
    // PreferenceLoader can load this bundle before Preferences.framework is in
    // memory -- then the subclass is never created, NSPrincipalClass resolves
    // to nil, and Settings dies the moment the pane is opened. Force the
    // framework in first. Both rootless and rootful paths tried.
    if (!objc_getClass("PSListController")){
        dlopen("/System/Library/PrivateFrameworks/Preferences.framework/Preferences", RTLD_LAZY);
        ADPLog("[prefs] dlopen Preferences attempted");
    }
    ADPLog(objc_getClass("PSListController") ? "[prefs] PSListController FOUND"
                                            : "[prefs] PSListController MISSING");
    %init;
    ADPLog(objc_getClass("ADRootListController") ? "[prefs] subclass registered OK"
                                                 : "[prefs] subclass MISSING after init");
}
