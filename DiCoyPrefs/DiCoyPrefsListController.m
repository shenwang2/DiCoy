// DiCoyPrefs/DiCoyPrefsListController.m
//
// Standard PreferenceLoader list controller. Most persistence and Darwin
// notification delivery is handled automatically by the PSListController
// machinery via the "PostNotification" and "defaults" keys in Root.plist.
// We subclass only to provide the specifier list.

#import "DiCoyPrefsListController.h"

@implementation DiCoyPrefsListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        // Loads Resources/Root.plist, which defines all preference cells.
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

@end
