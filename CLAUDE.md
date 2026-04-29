# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## Role

Senior iOS Jailbreak Developer — Theos/Logos, arm64/arm64e, rootless jailbreak internals, AVFoundation/CoreMedia/IOSurface pipeline, private API hooking.

## Operational Rules

- No filler. No politeness. No self-reference.
- Output: dense, symbol-rich, technically precise.
- Code: exact Logos syntax — `%hook`, `%orig`, `%end`, `%ctor`, `%c()`, `%new`.
- Reasoning: step-based. Validate before concluding.
- Correctness over verbosity.

---

## Build Commands

```bash
# All three subprojects → packages/*.deb  (rootless by default)
make package

# Rootful .deb (overrides the exported THEOS_PACKAGE_SCHEME)
make package THEOS_PACKAGE_SCHEME=

# Both rootless and rootful on WSL Ubuntu
./build_all.sh

# Build + SSH deploy + launchd reload
make install

# Single subproject
make -C DiCoyDaemon
make -C DiCoyTweak
make -C DiCoyPrefs
```

Required env vars:

| Var | Purpose |
|---|---|
| `THEOS` | Theos installation root |
| `THEOS_DEVICE_IP` | Device IP for `make install` |
| `THEOS_DEVICE_PORT` | SSH port (default 22) |

Scheme: `THEOS_PACKAGE_SCHEME=rootless` (set in root `Makefile`). All rootless install paths are under `/var/jb/`.

Verify daemon post-install:
```bash
ssh root@<ip> launchctl list | grep dicoy
```

---

## Architecture

Three-binary design. No pixel data crosses process boundaries.

```
DiCoyDaemon  (root, launchd, /var/jb/usr/sbin/)
  └─ CARenderServerRenderDisplay() → IOSurface pool (SURFACE_POOL_SIZE=2, double-buffered)
  └─ Unix Domain Socket /var/jb/var/run/dicoy.sock
  └─ broadcastFrame: sends 4-byte IOSurfaceID only (DicoyMessage.surface_id)

DiCoyTweak   (MobileSubstrate dylib, injected into every AVFoundation process)
  └─ DiCoyClient: socket → IOSurfaceLookup(id) → CVPixelBufferCreateWithIOSurface
  └─ DiCoyTweakManager: owns latest surface + builds CMSampleBufferRef per-frame
  └─ Logos hooks: %hook AVCaptureSession, AVCaptureVideoDataOutput, AVCaptureAudioDataOutput
  └─ Proxy-delegate pattern: swaps app's real delegate for DiCoyVideoProxy/DiCoyAudioProxy

DiCoyPrefs   (PreferenceLoader bundle, /var/jb/Library/PreferenceBundles/)
  └─ PSListController subclass; Root.plist drives all UI
  └─ PostNotification: com.dicoy.modeChanged → CFNotificationCenter Darwin
  └─ Prefs domain: com.dicoy.prefs → /var/jb/var/mobile/Library/Preferences/com.dicoy.prefs.plist
  └─ Vendored AltList.framework (weak link) for future app-selection cells
```

### IPC Wire Protocol (`DiCoyProtocol.h`)

`DicoyMessage` — 12 bytes, packed, host byte order:

| Field | Type | Notes |
|---|---|---|
| `magic` | `uint16_t` | `0xD1C0` — validates framing |
| `type` | `uint8_t` | `DicoyMessageType` enum |
| `mode` | `uint8_t` | informational; daemon is authoritative |
| `surface_id` | `uint32_t` | IOSurface global ID; valid on `kDicoyMsgFrameReady` only |
| `width/height` | `uint16_t` | frame dimensions |
| `timestamp` | `uint32_t` | monotonic ms since daemon start |

Directions: Tweak→Daemon: `StartCapture`, `StopCapture`, `Ping`. Daemon→Tweak: `FrameReady`, `Pong`.

### Rootless / Rootful Path Macros

`DiCoyProtocol.h` defines `DICOY_JB_PREFIX` based on `-DDICOY_ROOTLESS=1`:

```c
#ifdef DICOY_ROOTLESS
#  define DICOY_JB_PREFIX "/var/jb"
#else
#  define DICOY_JB_PREFIX ""
#endif
#define DICOY_SOCKET_PATH DICOY_JB_PREFIX "/var/run/dicoy.sock"
#define DICOY_PREFS_PATH  DICOY_JB_PREFIX "/var/mobile/Library/Preferences/com.dicoy.prefs.plist"
```

`-DDICOY_ROOTLESS=1` is injected by `DiCoyDaemon/Makefile` and `DiCoyTweak/Makefile` when `THEOS_PACKAGE_SCHEME=rootless`. `Tweak.x` uses `@DICOY_PREFS_PATH` (Clang adjacent-string-literal concatenation).

### Zero-Copy Path

`CARenderServerRenderDisplay` → `gSurfacePool[slot]` (GPU write)
→ `broadcastFrame(IOSurfaceGetID(slot))` (4 bytes over socket)
→ `IOSurfaceLookup(msg.surface_id)` (maps same physical GPU pages, no memcpy)
→ `CVPixelBufferCreateWithIOSurface` (zero-copy wrapper)
→ `CMSampleBufferCreateForImageBuffer` → app delegate

### Daemon Threading Model

- **Main thread**: `captureLoop` — frame-rate gated with `clock_gettime_nsec_np`; polls `activeCount()==0` at 10 Hz when idle (battery gate).
- **Background thread**: `socketServer` — one `pthread` per accepted client; `handleClient` blocks on `recv(MSG_WAITALL)`.
- `gSurfaceMutex` guards `gWriteIdx`/surface pool slot selection.
- `gClientsMtx` guards `gClients[]` + `gActiveCount`.
- `broadcastFrame` uses `MSG_DONTWAIT` — drops frame to slow clients rather than blocking capture loop.

### Tweak Threading Model

- `DiCoyClient._readQueue` — serial `dispatch_queue`, blocks on `recv(MSG_WAITALL)`.
- `DiCoyTweakManager._surfaceLock` — `os_unfair_lock` guards `latestSurface`, `surfaceWidth`, `surfaceHeight`.
- `DiCoyTweakManager._videoReaderLock` — `os_unfair_lock` guards `_videoReader`/`_videoOutput` swap and `copyNextSampleBuffer`.
- `DiCoyTweakManager._audioReaderLock` — `os_unfair_lock` guards `_audioReader`/`_audioOutput` swap and `copyNextSampleBuffer`.
- Frame delivery: read queue → `frameCallback` → unfair lock swap → camera callback queue reads via `buildSampleBuffer`.

### Proxy-Delegate Pattern

`%hook AVCaptureVideoDataOutput -setSampleBufferDelegate:queue:` intercepts delegate registration. Wraps non-`DiCoyVideoProxy` delegates in proxy; guards against double-wrap with `isKindOfClass:%c(DiCoyVideoProxy)`. `forwardingTargetForSelector:` + `respondsToSelector:` delegation ensures transparent KVO/protocol conformance.

### Mode Signaling

`DiCoyPrefs` → `notify_post("com.dicoy.modeChanged")` (via `PostNotification` in Root.plist)
→ `CFNotificationCenterGetDarwinNotifyCenter` observer in `%ctor`
→ reads `DICOY_PREFS_PATH` inline
→ `stopMirroring` + `startMirroring` if session is live; `stopMirroring` only if mode → off

`startMirroring` fires naturally on the next `AVCaptureSession -startRunning` if no session is active.

### Media Inject Pipeline

`startMirroring` (mode=mediaInject) → `setupVideoReaderForPath:` (`AVAssetReader`, BGRA output, `alwaysCopiesSampleData=NO`)
→ `nextVideoSampleBuffer` per-frame: `copyNextSampleBuffer` → EOF detected → `setupVideoReaderForPath:` (reset) → retry → `CMSampleBufferCreateCopyWithNewTiming(CACurrentMediaTime())`

Audio: lazy init on first mic callback → `setupAudioReaderForPath:matchingASBD:` extracts real session ASBD (sample rate, channels) from `CMAudioFormatDescriptionGetStreamBasicDescription`, configures `AVAssetReaderTrackOutput` with matching interleaved LPCM16 output settings → `nextAudioSampleBufferMatchingASBD:` per callback, EOF loop, PTS restamped.

### Key Platform Notes

- IOSurface format: `0x42475241` = `'BGRA'` = `kCVPixelFormatType_32BGRA`. CARenderServer output matches AVFoundation camera expectations.
- `kIOSurfaceIsGlobal: YES` — mandatory. Without it, `IOSurfaceLookup()` fails from sandboxed processes.
- Socket chmod `0777` — required for sandboxed app UIDs to connect on rootless.
- Daemon install path: `/var/jb/usr/sbin/DiCoyDaemon`; launchd plist generated from `com.dicoy.daemon.plist.in` into `layout/` by `before-package::` Makefile target.
- Tweak filter (`DiCoyTweak.plist`): injects into all processes loading `AVFoundation`. Narrow to `Bundles` array for targeted injection.
- Entitlements (`entitlements.plist`): `com.apple.CARenderServer`, `com.apple.iokit.IOSurfaceFamily`, `com.apple.private.IOKit`, `com.apple.private.framebuffer`, `com.apple.private.security.no-container`, `platform-application`.

### AltList.framework (vendor/)

Vendored copy of Pixel0mer's AltList preference framework. Provides `ATLApplicationListSelectionController` and related classes for app-selection UI in DiCoyPrefs. Linked with `-weak_framework AltList` in `DiCoyPrefs/Makefile`; the prefs bundle loads on devices without AltList installed. To activate: add `ATLApplicationListSelectionController`-based specifiers to `Root.plist`, import headers in `DiCoyPrefsListController.m`, and list `com.pixelomer.altlist` as a device-side dependency in `control`.

### launchd Plist Generation

`DiCoyDaemon/com.dicoy.daemon.plist.in` is the source of truth. The `before-package::` target in `DiCoyDaemon/Makefile` runs `sed` to substitute `%%JB_PREFIX%%` with `/var/jb` (rootless) or `` (rootful) and writes to `layout/[var/jb/]Library/LaunchDaemons/com.dicoy.daemon.plist` for inclusion in the `.deb`. Do not edit the generated `com.dicoy.daemon.plist` directly.

### CI/CD

`.github/workflows/build.yml` — matrix build (rootless + rootful) on `ubuntu-latest`. Caches the Theos tree. Creates a GitHub Release with both `.deb` artifacts on `v*` tag push.

`build_all.sh` — local WSL Ubuntu equivalent. Validates `$THEOS`, builds both schemes, outputs to `packages/rootless/` and `packages/rootful/`.

### Known Limitations

- `DiCoyAudioProxy` in **screen mirror** mode is pass-through — system audio capture in-process requires a separate `AudioServicesCreateRecordingAudioTap` daemon-side implementation.
- FPS preference (`30` / `60`) is stored in `com.dicoy.prefs` but the daemon uses `DICOY_TARGET_FPS` (compile-time constant). Dynamic FPS requires a protocol extension or daemon-side pref read at startup.
- `AVAssetReader` does not support image files (JPEG/PNG). Convert to H.264 `.mp4` first.
