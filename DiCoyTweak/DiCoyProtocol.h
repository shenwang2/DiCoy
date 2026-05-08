#ifndef DICOY_PROTOCOL_H
#define DICOY_PROTOCOL_H

#include <stdint.h>

// Runtime path prefix: /var/jb for rootless jailbreaks, empty for rootful.
// Set by passing -DDICOY_ROOTLESS=1 in the Makefile for rootless builds.
#ifdef DICOY_ROOTLESS
#  define DICOY_JB_PREFIX "/var/jb"
#else
#  define DICOY_JB_PREFIX ""
#endif

// Preferences plist path – user preferences always live at the real mobile home
// regardless of jailbreak type; the JB prefix is for JB binaries/libraries only.
// libSandy grants the injected process read-write access via the DiCoy profile.
#define DICOY_PREFS_PATH  "/var/mobile/Library/Preferences/com.dicoy.prefs.plist"

// Darwin notification key posted by DiCoyPrefs when the user changes modes.
// The tweak subscribes to this to reconfigure itself without a respring.
#define DICOY_NOTIFY_MODE_CHANGED "com.dicoy.modeChanged"

// Target capture rate. Change here propagates to both daemon and tweak.
#define DICOY_TARGET_FPS 30

// Operating mode, kept in sync with DiCoyPrefs "mode" key.
typedef enum : uint8_t {
    kDicoyModeOff          = 0,
    kDicoyModeScreenMirror = 1,
    kDicoyModeMediaInject  = 2,
} DicoyMode;

#endif // DICOY_PROTOCOL_H
