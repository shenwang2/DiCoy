// DiCoyPrefs/DiCoyPrefsListController.m

#import "DiCoyPrefsListController.h"
#import "DiCoyProtocol.h"
#import <spawn.h>

// The tweak reads the plist file directly (libSandy-unlocked), bypassing cfprefsd.
// We write to this path on Save so the tweak picks up new values on the next
// AVCaptureSession -startRunning after respring.
static NSString *const kPrefsPlistPath = @DICOY_PREFS_PATH;

@interface DiCoyPrefsListController () {
    BOOL _dirty;
}
@end

@implementation DiCoyPrefsListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _dirty = NO;
    [self _updateSaveButton];
}

// Called by PSListController whenever a specifier value changes.
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    _dirty = YES;
    [self _updateSaveButton];
}

- (void)_updateSaveButton {
    if (_dirty) {
        UIBarButtonItem *btn = [[UIBarButtonItem alloc]
            initWithTitle:@"Save"
                    style:UIBarButtonItemStyleDone
                   target:self
                   action:@selector(_saveButtonTapped)];
        self.navigationItem.rightBarButtonItem = btn;
    } else {
        self.navigationItem.rightBarButtonItem = nil;
    }
}

- (void)_saveButtonTapped {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Apply Changes"
                         message:@"DiCoy requires a respring to apply these settings."
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction
        actionWithTitle:@"Respring"
                  style:UIAlertActionStyleDestructive
                handler:^(UIAlertAction *a) {
        [self _flushToDisk];
        [self _respring];
    }]];

    [alert addAction:[UIAlertAction
        actionWithTitle:@"Cancel"
                  style:UIAlertActionStyleCancel
                handler:nil]];

    [self presentViewController:alert animated:YES completion:nil];
}

// Writes all current specifier values to the plist file the tweak reads directly.
- (void)_flushToDisk {
    NSMutableDictionary *prefs =
        [NSMutableDictionary dictionaryWithContentsOfFile:kPrefsPlistPath]
        ?: [NSMutableDictionary dictionary];
    for (PSSpecifier *s in self.specifiers) {
        NSString *key = s.properties[@"key"];
        if (!key) continue;
        id value = [self readPreferenceValue:s];
        if (value) prefs[key] = value;
    }
    [prefs writeToFile:kPrefsPlistPath atomically:YES];
    _dirty = NO;
    [self _updateSaveButton];
}

- (void)_respring {
    // Try rootless sbreload first, fall back to rootful path.
    extern char **environ;
    const char *rootless = "/var/jb/usr/bin/sbreload";
    const char *rootful  = "/usr/bin/sbreload";
    pid_t pid = 0;
    if (posix_spawn(&pid, rootless, NULL, NULL,
                    (char *const[]){(char *)rootless, NULL}, environ) != 0) {
        posix_spawn(&pid, rootful, NULL, NULL,
                    (char *const[]){(char *)rootful, NULL}, environ);
    }
}

@end
