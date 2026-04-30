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

// Socket path – placed in the globally-accessible rootless prefix so that
// sandboxed app processes can connect without special entitlements.
#define DICOY_SOCKET_PATH DICOY_JB_PREFIX "/var/run/dicoy.sock"

// Preferences plist path – used by DiCoyTweak to read the current mode.
// Stored in /var/tmp/ (world-readable/writable, sticky) so Camera.app's sandbox
// can read it. /var/mobile/Library/Preferences/ is blocked by Camera's sandbox
// profile (EPERM) even on jailbroken devices.
#define DICOY_PREFS_PATH  "/var/tmp/com.dicoy.prefs.plist"

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
