// DiCoyPrefs/DiCoyPrefsListController.m

#import "DiCoyPrefsListController.h"
#import "DiCoyProtocol.h"
#import <spawn.h>
#import <sys/stat.h>

// The tweak reads the plist file directly (libSandy-unlocked), bypassing cfprefsd.
// We write to this path on Save so the tweak picks up new values on the next
// AVCaptureSession -startRunning after respring.
static NSString *const kPrefsPlistPath = @DICOY_PREFS_PATH;

static NSDictionary *defaultPrefs(void) {
    return @{
        @"mode":          @"off",
        @"mediaFilePath": @"/var/mobile/Documents/VIDEO.MP4",
        @"videoRotation": @"default",
        @"fps":           @"30",
    };
}

// Detect jailbreak environment at runtime.
// Rootless: /var/jb is a real directory (Dopamine, palera1n rootless).
// RootHide: /var/jb is a symlink redirected to a different root.
// Rootful:  /var/jb does not exist.
static NSString *jbEnvironmentString(void) {
    struct stat st;
    if (lstat("/var/jb", &st) != 0) return @"rootful";
    if (S_ISLNK(st.st_mode)) return @"roothide";
    return @"rootless";
}

// ---------------------------------------------------------------------------
// Custom cell: red, centered "Reset to Defaults" button
// ---------------------------------------------------------------------------
@interface DiCoyResetCell : PSTableCell
@end

@implementation DiCoyResetCell
- (void)layoutSubviews {
    [super layoutSubviews];
    self.textLabel.textColor     = [UIColor systemRedColor];
    self.textLabel.textAlignment = NSTextAlignmentCenter;
}
@end

// ---------------------------------------------------------------------------
// List controller
// ---------------------------------------------------------------------------
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
    [self _updateVersionFooter];
}

- (void)_updateVersionFooter {
    NSBundle *bundle  = [NSBundle bundleForClass:[self class]];
    NSString *version = bundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?";
    NSString *ios     = UIDevice.currentDevice.systemVersion;
    NSString *env     = jbEnvironmentString();
    NSString *text    = [NSString stringWithFormat:@"DiCoy v%@ (iOS %@ %@)", version, ios, env];

    for (PSSpecifier *s in [self specifiers]) {
        if ([[s propertyForKey:@"id"] isEqualToString:@"versionFooterGroup"]) {
            [s setProperty:text forKey:@"footerText"];
            break;
        }
    }
    // Reload only the table footer without rebuilding specifiers.
    [self.tableView reloadData];
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

// ---------------------------------------------------------------------------
// Reset to Defaults
// ---------------------------------------------------------------------------

- (void)_resetButtonTapped {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Reset to Defaults"
                         message:@"All DiCoy settings will be reset. A userspace reboot is required to apply."
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction
        actionWithTitle:@"Reset & Reboot Userspace"
                  style:UIAlertActionStyleDestructive
                handler:^(UIAlertAction *a) {
        [self _resetDefaults];
        [self _userspaceReboot];
    }]];

    [alert addAction:[UIAlertAction
        actionWithTitle:@"Cancel"
                  style:UIAlertActionStyleCancel
                handler:nil]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)_resetDefaults {
    NSDictionary *d = defaultPrefs();

    // Write to cfprefsd so the UI reflects the correct values immediately.
    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:@"com.dicoy.prefs"];
    for (NSString *key in d) [ud setObject:d[key] forKey:key];
    [ud synchronize];

    // Also write to the direct plist file that the tweak reads.
    [d writeToFile:kPrefsPlistPath atomically:YES];

    _dirty = NO;
    [self _updateSaveButton];
    [self reloadSpecifiers];
    [self _updateVersionFooter];
}

- (void)_userspaceReboot {
    extern char **environ;
    // launchctl reboot userspace restarts all userspace processes (iOS 14+).
    const char *rootless = "/var/jb/usr/bin/launchctl";
    const char *rootful  = "/usr/bin/launchctl";
    pid_t pid = 0;
    if (posix_spawn(&pid, rootless, NULL, NULL,
                    (char *const[]){(char *)rootless, "reboot", "userspace", NULL}, environ) != 0) {
        posix_spawn(&pid, rootful, NULL, NULL,
                    (char *const[]){(char *)rootful, "reboot", "userspace", NULL}, environ);
    }
}

@end
