// DiCoyPrefs/DiCoyPrefsListController.m

#import "DiCoyPrefsListController.h"

// cfprefsd on iOS 14+ does not reliably flush preference domains to disk when
// the domain doesn't belong to the current app. The tweak reads the file
// directly, so we force-write it here bypassing cfprefsd entirely.
static NSString *const kPrefsPlistPath = @"/var/tmp/com.dicoy.prefs.plist";

@implementation DiCoyPrefsListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    [self _flushToDisk];
}

// PSEditTextCell may not call setPreferenceValue:specifier: if the user types
// without triggering a change event. Flush on disappear to catch those cases.
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self _flushToDisk];
}

- (void)_flushToDisk {
    NSMutableDictionary *prefs =
        [NSMutableDictionary dictionaryWithContentsOfFile:kPrefsPlistPath]
        ?: [NSMutableDictionary dictionary];
    // Read every specifier with a key and overwrite with its current live value.
    for (PSSpecifier *s in self.specifiers) {
        NSString *key = s.properties[@"key"];
        if (!key) continue;
        id value = [self readPreferenceValue:s];
        if (value) prefs[key] = value;
    }
    [prefs writeToFile:kPrefsPlistPath atomically:YES];
}

@end
