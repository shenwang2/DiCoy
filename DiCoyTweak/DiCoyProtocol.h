#ifndef DICOY_PROTOCOL_H
#define DICOY_PROTOCOL_H

#include <stdint.h>

// Magic bytes in every message header to detect corrupt/misaligned reads.
#define DICOY_MAGIC ((uint16_t)0xD1C0)

// Runtime path prefix: /var/jb for rootless jailbreaks, empty for rootful.
// Set by passing -DDICOY_ROOTLESS=1 in the Makefile for rootless builds.
#ifdef DICOY_ROOTLESS
#  define DICOY_JB_PREFIX "/var/jb"
#else
#  define DICOY_JB_PREFIX ""
#endif

// Socket path – /var/tmp is 1777 (sticky, world-writable), so SpringBoard
// (running as mobile) can bind here, and sandboxed apps can connect after
// libSandy applies the DiCoy sandbox-extension profile.
#define DICOY_SOCKET_PATH "/var/tmp/dicoy.sock"

// Preferences plist path – user preferences always live at the real mobile home
// regardless of jailbreak type; the JB prefix is for JB binaries/libraries only.
// libSandy grants the injected process read-write access via the DiCoy profile.
#define DICOY_PREFS_PATH  "/var/mobile/Library/Preferences/com.dicoy.prefs.plist"

// Darwin notification key posted by DiCoyPrefs when the user changes modes.
// The tweak subscribes to this to reconfigure itself without a respring.
#define DICOY_NOTIFY_MODE_CHANGED "com.dicoy.modeChanged"

// Target capture rate. Change here propagates to both daemon and tweak.
#define DICOY_TARGET_FPS 30

// -----------------------------------------------------------------------
// Wire protocol
// All messages are fixed-size. Multi-byte fields are host byte order
// (sender and receiver are always the same physical device).
// -----------------------------------------------------------------------

typedef enum : uint8_t {
    kDicoyMsgStartCapture = 0x01, // Tweak  -> Daemon: begin pushing frames
    kDicoyMsgStopCapture  = 0x02, // Tweak  -> Daemon: pause frame delivery
    kDicoyMsgFrameReady   = 0x03, // Daemon -> Tweak:  new IOSurface available
    kDicoyMsgPing         = 0x04, // Tweak  -> Daemon: keepalive probe
    kDicoyMsgPong         = 0x05, // Daemon -> Tweak:  keepalive response
} DicoyMessageType;

// Operating mode, kept in sync with DiCoyPrefs "mode" key.
typedef enum : uint8_t {
    kDicoyModeOff          = 0,
    kDicoyModeScreenMirror = 1,
    kDicoyModeMediaInject  = 2,
} DicoyMode;

typedef struct __attribute__((packed)) {
    uint16_t magic;      // Always DICOY_MAGIC
    uint8_t  type;       // DicoyMessageType
    uint8_t  mode;       // DicoyMode (informational; daemon is authoritative)
    uint32_t surface_id; // IOSurface ID (valid only for kDicoyMsgFrameReady)
    uint16_t width;      // Frame width  in pixels
    uint16_t height;     // Frame height in pixels
    uint32_t timestamp;  // Monotonic ms since daemon start (frame ordering)
} DicoyMessage;

#endif // DICOY_PROTOCOL_H
