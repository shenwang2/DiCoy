// DiCoyPrefs/DiCoyPrefsListController.m

#import "DiCoyPrefsListController.h"

// cfprefsd on iOS 14+ does not reliably flush preference domains to disk when
// the domain doesn't belong to the current app. PSListController calls through
// to CFPreferences, which stores the value in-memory but may never write the
// .plist file. The tweak reads the file directly, so we force-write it here
// on every preference change.
static NSString *const kPrefsPlistPath =
    @"/var/mobile/Library/Preferences/com.dicoy.prefs.plist";

@implementation DiCoyPrefsListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    NSString *key = specifier.properties[@"key"];
    if (!key) return;
    NSMutableDictionary *prefs =
        [NSMutableDictionary dictionaryWithContentsOfFile:kPrefsPlistPath]
        ?: [NSMutableDictionary dictionary];
    if (value) prefs[key] = value;
    else [prefs removeObjectForKey:key];
    [prefs writeToFile:kPrefsPlistPath atomically:YES];
}

@end
