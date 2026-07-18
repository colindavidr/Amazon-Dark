#import "ADRootListController.h"

@implementation ADRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    // Nudge the running Amazon app to reload prefs on next foreground.
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.colindavidr.amazondark/prefs-changed"), NULL, NULL, YES);
}

- (void)openGitHub {
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://github.com/colindavidr/Amazon-Dark"]
                                       options:@{} completionHandler:nil];
}

@end
