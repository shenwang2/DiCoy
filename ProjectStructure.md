# DiCoy – Project Structure

## Description

DiCoy is a rootless / rootful iOS jailbreak tweak (iOS 15–17, arm64/arm64e) that intercepts AVFoundation's camera and microphone pipelines and substitutes injected content. It supports two modes: **Screen Mirror** (live composited display captured via private CARenderServer APIs) and **Media Inject** (a local video/audio file decoded and looped). The architecture is a privileged background daemon that produces IOSurface frames, communicating with an in-process dylib via a 4-byte-per-frame Unix Domain Socket — no pixel data ever crosses the process boundary.

The project consists of three independently packaged binaries built from a single Theos workspace.

---

## File Tree

```
DiCoy/
│
├── Makefile                              Root Theos workspace. Builds all three subprojects,
│                                         exports THEOS_PACKAGE_SCHEME=rootless by default.
│
├── control                               Debian package metadata (name, version, dependencies).
│
├── build_all.sh                          Local build script for WSL Ubuntu. Produces both
│                                         rootless and rootful .deb variants.
│
├── changelog.md                          Human-readable release notes.
│
├── compatibility.md                      Device/iOS/jailbreak compatibility matrix and
│                                         known limitations / tweak conflict reference.
│
├── ProjectStructure.md                   This file.
│
├── README.md                             User-facing documentation.
│
├── CLAUDE.md                             Claude Code session instructions and architecture
│                                         reference for AI-assisted development.
│
│
├── .github/
│   └── workflows/
│       └── build.yml                     GitHub Actions CI/CD workflow. Matrix builds
│                                         rootless and rootful .deb artifacts on macos-14
│                                         using iPhoneOS16.5.sdk. Creates or updates a
│                                         GitHub Release on every push to main/master
│                                         (not PRs); version tag sourced from control file.
│
│
├── DiCoyDaemon/                          ── Privileged background daemon ──────────────────
│   │                                     Root process; launched by launchd at boot.
│   │                                     Captures the composited display and delivers
│   │                                     IOSurface IDs to connected tweak clients.
│   │
│   ├── main.m                            All daemon logic: display capture loop via
│   │                                     CARenderServerRenderDisplay, double-buffered
│   │                                     IOSurface pool, Unix Domain Socket server,
│   │                                     per-client pthread handlers, MSG_DONTWAIT
│   │                                     broadcast, battery-aware idle polling.
│   │
│   ├── DiCoyProtocol.h                   Shared IPC contract: DicoyMessage struct (12 B,
│   │                                     packed), DicoyMessageType enum, DicoyMode enum,
│   │                                     DICOY_MAGIC, DICOY_SOCKET_PATH, DICOY_PREFS_PATH,
│   │                                     DICOY_TARGET_FPS. Conditionally defines
│   │                                     DICOY_JB_PREFIX for rootless vs rootful paths.
│   │
│   ├── entitlements.plist                Codesign entitlements required by the daemon:
│   │                                     CARenderServer Mach service, IOSurfaceFamily,
│   │                                     private IOKit, private framebuffer,
│   │                                     no-container sandbox suppression,
│   │                                     platform-application.
│   │
│   ├── com.dicoy.daemon.plist.in         launchd job definition template. %%JB_PREFIX%%
│   │                                     is substituted at build time (before-package::
│   │                                     Makefile target) to produce the correct binary
│   │                                     path for rootless (/var/jb/usr/sbin/…) or
│   │                                     rootful (/usr/sbin/…). RunAtLoad + KeepAlive.
│   │
│   ├── com.dicoy.daemon.plist            Generated at build time from .in template.
│   │                                     Do not edit directly.
│   │
│   └── Makefile                          Builds DiCoyDaemon as a Theos TOOL_NAME.
│                                         Handles rootless/rootful install paths,
│                                         -DDICOY_ROOTLESS=1 CFLAGS, launchd plist
│                                         generation into layout/, and after-install::
│                                         launchctl reload target.
│
│
├── DiCoyTweak/                           ── MobileSubstrate dylib ─────────────────────────
│   │                                     Injected into every process that loads AVFoundation
│   │                                     (Camera, FaceTime, Snapchat, etc.) via the
│   │                                     DiCoyTweak.plist filter.
│   │
│   ├── Tweak.x                           All Logos hooks and injection logic:
│   │                                     • DiCoyTweakManager (singleton) — owns the daemon
│   │                                       connection, latest IOSurface, and AVAssetReader
│   │                                       instances for video + audio injection.
│   │                                     • DiCoyVideoProxy — intercepts video delegate
│   │                                       callbacks; injects IOSurface (screen mirror) or
│   │                                       AVAssetReader BGRA frames (media inject).
│   │                                     • DiCoyAudioProxy — intercepts audio delegate
│   │                                       callbacks; injects LPCM audio from media file,
│   │                                       ASBD-matched and PTS-restamped to session clock.
│   │                                     • %hook AVCaptureSession, AVCaptureVideoDataOutput,
│   │                                       AVCaptureAudioDataOutput.
│   │                                     • %ctor — registers Darwin notification observer
│   │                                       for live mode changes (no respring needed).
│   │
│   ├── DiCoyClient.h / DiCoyClient.m     Socket client that connects to DiCoyDaemon,
│   │                                     sends StartCapture/StopCapture commands, and
│   │                                     runs a blocking recv() loop on a private serial
│   │                                     queue. On FRAME_READY: calls IOSurfaceLookup(id)
│   │                                     (zero-copy) and invokes the registered callback.
│   │
│   ├── DiCoyProtocol.h                   Copy of the shared IPC protocol header
│   │                                     (identical to DiCoyDaemon/DiCoyProtocol.h).
│   │
│   ├── DiCoyTweak.plist                  MobileSubstrate injection filter.
│   │                                     Injects into all processes loading AVFoundation.
│   │                                     Narrow to specific bundle IDs here if needed.
│   │
│   └── Makefile                          Builds DiCoyTweak as a Theos TWEAK_NAME.
│                                         Links: AVFoundation, CoreMedia, CoreVideo,
│                                         IOSurface, QuartzCore, AudioToolbox.
│                                         Passes -DDICOY_ROOTLESS=1 for rootless builds.
│
│
├── DiCoyPrefs/                           ── Preference bundle ─────────────────────────────
│   │                                     Loaded by Preferences.app via PreferenceLoader.
│   │                                     Persists settings to com.dicoy.prefs domain;
│   │                                     posts com.dicoy.modeChanged Darwin notification
│   │                                     automatically via PSListController machinery.
│   │
│   ├── DiCoyPrefsListController.h / .m   Minimal PSListController subclass; loads
│   │                                     specifiers from Resources/Root.plist.
│   │
│   ├── entry.plist                       PreferenceLoader registration (PSLinkCell →
│   │                                     DiCoyPrefsListController).
│   │
│   ├── Makefile                          Builds DiCoyPrefs as a Theos BUNDLE_NAME.
│   │                                     Links AltList.framework (vendored, weak)
│   │                                     for optional app-selection preference cells.
│   │                                     Handles rootless/rootful install paths and
│   │                                     stages entry.plist into layout/.
│   │
│   └── Resources/
│       ├── Root.plist                    All preference specifiers: Mode segment control
│       │                                 (Off / Screen Mirror / Media Inject), File Path
│       │                                 text field, Frame Rate segment (30 / 60 FPS).
│       │                                 PostNotification keys drive live updates.
│       └── Info.plist                    Bundle metadata for the preference bundle.
│
│
└── vendor/
    └── AltList.framework/                Third-party preference framework by Pixel0mer.
                                          Provides app-selection preference cells
                                          (ATLApplicationListSelectionController, etc.)
                                          for future per-app targeting in DiCoyPrefs.
                                          Linked as a weak framework at build time;
                                          must be installed on device as a separate
                                          package if its cells are used at runtime.
```

---

## Data Flow Summary

```
DiCoyDaemon (root)
  CARenderServerRenderDisplay()
       │ writes composited pixels into
       ▼
  gSurfacePool[slot] (IOSurface, kIOSurfaceIsGlobal=YES, BGRA)
       │ only the 4-byte IOSurfaceID crosses the socket
       ▼ DicoyMessage { magic, type=FRAME_READY, surface_id, w, h, ts }
  Unix Domain Socket /var/jb/var/run/dicoy.sock  (chmod 0777)
       │
       ▼
DiCoyTweak (injected into app process)
  DiCoyClient._readQueue
  IOSurfaceLookup(surface_id)          ← zero-copy: maps same GPU pages
       │
       ▼
  DiCoyTweakManager.latestSurface      ← guarded by os_unfair_lock
       │
       ▼ on camera callback queue
  CVPixelBufferCreateWithIOSurface()   ← zero-copy CVPixelBuffer wrapper
  CMSampleBufferCreateForImageBuffer() ← restamped to CACurrentMediaTime()
       │
       ▼
  App's real AVCaptureVideoDataOutputSampleBufferDelegate
```

For **Media Inject** mode the daemon is bypassed entirely; the video path goes through `AVAssetReader → AVAssetReaderTrackOutput(BGRA) → nextVideoSampleBuffer()` and the audio path through `AVAssetReader → AVAssetReaderTrackOutput(LPCM) → nextAudioSampleBufferMatchingASBD:()`.
