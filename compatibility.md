# DiCoy Compatibility

## Device & iOS Support Matrix

| iOS Version | arm64 (A9–A15) | arm64e (A12–A17) | Notes |
|-------------|:--------------:|:----------------:|-------|
| 15.0–15.8   | ✅ Supported    | ✅ Supported      | Primary target; all features validated |
| 16.0–16.7   | ✅ Supported    | ✅ Supported      | CARenderServer API unchanged |
| 17.0        | ✅ Supported    | ✅ Supported      | Tested on Dopamine 2.x |
| 17.1+       | ⚠️ Unverified  | ⚠️ Unverified    | API signatures stable but unverified |
| 14.x        | ⚠️ Unverified  | ⚠️ Unverified    | Rootless JB not widely available |
| ≤ 13.x      | ❌ Unsupported  | ❌ Unsupported    | `clock_gettime_nsec_np` unavailable |

## Jailbreak Environment Support

| Jailbreak           | Scheme    | Status           | Notes |
|---------------------|-----------|:----------------:|-------|
| Dopamine 2.x        | Rootless  | ✅ Supported      | Primary development target |
| palera1n (rootless) | Rootless  | ✅ Supported      | A8–A11 only; arm64e path untested |
| palera1n (rootful)  | Rootful   | ✅ Supported      | Requires rootful .deb variant |
| Unc0ver 8.x         | Rootful   | ✅ Supported      | iOS 14–15; requires rootful .deb |
| checkra1n           | Rootful   | ✅ Supported      | A8–A11; requires rootful .deb |
| Taurine             | Rootful   | ⚠️ Unverified    | iOS 14; rootful .deb should work |
| Fugu15 Max          | Rootless  | ⚠️ Unverified    | Sandbox restrictions may block socket |
| XinaA15             | Rootless  | ⚠️ Unverified    | CoreTrust bypass required for daemon |

## Substrate / Hook Engine

| Hook Engine         | Status           | Notes |
|---------------------|:----------------:|-------|
| ElleKit             | ✅ Supported      | Recommended on rootless |
| Substrate (libhooker)| ✅ Supported     | Standard rootful support |
| Substitute          | ✅ Supported      | Alternative to Substrate |

## App Compatibility

DiCoy injects into every process that loads `AVFoundation`. Tested apps:

| App               | Video | Audio | Notes |
|-------------------|:-----:|:-----:|-------|
| Apple Camera      | ✅     | ✅     | Full support; all modes |
| FaceTime          | ✅     | ✅     | Screen mirror + media inject |
| Snapchat          | ✅     | ✅     | Works; may need respring after install |
| Instagram         | ✅     | ✅     | Works; relaunch app after mode change |
| TikTok            | ✅     | ✅     | Works |
| WhatsApp          | ✅     | ✅     | Works |
| Telegram          | ✅     | ✅     | Works |
| Zoom              | ✅     | ⚠️    | Video works; audio may be filtered by Zoom DSP |
| Teams             | ✅     | ⚠️    | Video works; audio inject not verified |
| Discord           | ✅     | ✅     | Works |
| BeReal            | ✅     | N/A   | Front + back camera both intercepted |
| AVCam (Apple sample)| ✅  | ✅     | Reference app; all paths tested |

Apps that use a **non-AVFoundation** camera path (e.g. apps that call
`IOSurfaceCreateMachPort` directly or use `VTCompressionSession` without
`AVCaptureSession`) will **not** be intercepted.

## Known Limitations

### Screen Mirror mode

| Limitation | Impact | Workaround |
|------------|--------|------------|
| DiCoy's own Settings UI is visible in the mirrored feed | High | Place Settings in background before opening camera app |
| Status bar and notification banners are captured | Medium | Enable Do Not Disturb before recording |
| Display brightness affects captured color accuracy | Low | Set brightness to max before capture |
| 30 FPS cap (default) | Low | 60 FPS preference available; restart camera app to apply |
| Portrait-only display: feed is always full display resolution | Low | App may letterbox or crop; no workaround |

### Media Inject mode

| Limitation | Impact | Workaround |
|------------|--------|------------|
| File must exist at the exact path before session starts | High | Verify path in Settings before launching camera app |
| No seek / no playback control; file loops from beginning at EOF | Medium | Pre-trim file to the segment you want to loop |
| File is read synchronously; very large files may cause first-frame latency | Low | Use pre-encoded files ≤ 100 MB |
| Audio inject only works when the media file has an audio track | Medium | Add silent audio track to video file if needed |
| Image files (JPEG/PNG) do not work as video frames via AVAssetReader | Medium | Convert to H.264 .mp4 first: `ffmpeg -loop 1 -i img.jpg -t 60 out.mp4` |

### General

| Limitation | Impact | Notes |
|------------|--------|-------|
| FPS preference (`30` / `60`) requires camera app restart to apply | Low | LaunchDaemon reads pref at startup |
| `DiCoyAudioProxy` in screen mirror mode is pass-through only — no system audio capture | High | Capturing system audio in-process would require a separate AudioServicesCreateRecordingAudioTap daemon-side implementation, which is out of scope |
| Maximum 8 simultaneous client processes | Low | Governed by `MAX_CLIENTS = 8` in daemon |
| Double-buffer pool (SURFACE_POOL_SIZE=2) means a slow client risks a torn frame | Very Low | Clients have one full frame interval to finish; `MSG_DONTWAIT` drops frames to slow readers |

## Potential Conflicts with Native iOS Features

| Feature | Conflict | Description |
|---------|----------|-------------|
| Screen Recording (ReplayKit) | ⚠️ Possible | ReplayKit captures AVFoundation output; it will record the injected feed, not the real camera |
| Screen Mirroring (AirPlay) | ✅ No conflict | DiCoy captures display content before AirPlay encoding; the mirror still reflects the true screen |
| Continuity Camera (iOS 16+) | ⚠️ Possible | Continuity Camera may register as an AVCaptureDevice; DiCoy hooks `AVCaptureVideoDataOutput` regardless of device source |
| Face ID / Touch ID camera use | ⚠️ Low risk | Face ID uses a separate Secure Enclave/TrueDepth pipeline not routed through AVFoundation; unlikely to be intercepted |
| Headphone / AirPods mic routing | ✅ No conflict | DiCoy replaces the sample buffer at the output delegate level; device routing is unchanged |
| Spatial audio (iPhone 13+) | ⚠️ Possible | Spatial audio pipeline may interact with injected LPCM audio; not tested |
| Camera extensions (iOS 17+) | ⚠️ Unverified | Camera extensions may bypass `AVCaptureVideoDataOutput` hooks |

## Potential Conflicts with Other Tweaks

| Tweak | Conflict | Description |
|-------|----------|-------------|
| **PolyChrome / Snowboard** | ✅ None | Theme engines don't touch AVFoundation |
| **Filza / iFile** | ✅ None | File managers load AVFoundation but don't open capture sessions |
| **Activator** | ✅ None | No AVFoundation interaction |
| **BioProtect / AppLocker** | ✅ None | Screen-lock tweaks operate before camera session |
| **Flex 3 / Liberty Lite** | ⚠️ Possible | Class-dump/hook tweaks that also patch `AVCaptureVideoDataOutput` may double-wrap the proxy delegate or interfere with the injection chain |
| **Record'It / Vidyo** | ⚠️ Conflict | Screen-recording tweaks that hook the same `setSampleBufferDelegate:queue:` method may conflict; injection order is MobileSubstrate load-order dependent |
| **Camo (NKB)** | ⚠️ Conflict | Camo performs similar AVFoundation hooking; both tweaks may contend for the same injection point |
| **Reeder / TrollStore apps** | ✅ None | Not AVFoundation camera users |

If a conflict occurs, the most reliable resolution is to restrict DiCoy's injection filter from `Frameworks: [AVFoundation]` (all AVFoundation users) to `Bundles: [com.apple.camera, ...]` (specific apps). Edit `DiCoyTweak/DiCoyTweak.plist` and reinstall the tweak .deb.
