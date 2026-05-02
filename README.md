# DiCoy BETA / ONLY MEDIA INJECTION WORKING AND ONLY IN SOME APPS

A rootless / rootful iOS jailbreak tweak (iOS 15.0–17.0, arm64 / arm64e) that replaces the camera and microphone feeds in any AVFoundation-based app with either a **live mirror of the device screen** or a **local video/audio file**, using a zero-copy multi-process architecture.

## Features

- **Screen Mirroring** — Captures the fully-composited display (every layer, every app) at 30 or 60 FPS via the private `CARenderServerRenderDisplay` API and pipes it into the camera feed of any AVFoundation app.
- **Media Injection** — Replaces the camera with a local `.mp4` or `.mov` file; also replaces the microphone with the file's audio track. The file loops seamlessly at EOF.
- **Zero-copy IPC** — Only a 4-byte IOSurface ID crosses the process boundary; both processes map the same GPU memory pages, so no pixel data is ever copied.
- **Battery aware** — The capture daemon automatically pauses at 10 Hz when no app has the camera open and resumes at full frame rate when a session starts.
- **Live settings** — Mode changes in Preferences apply immediately via Darwin notifications without relaunching the target app or doing a respring.
- **Rootless & rootful** — Ships as both a rootless `.deb` (Dopamine, palera1n rootless) and a rootful `.deb` (checkra1n, unc0ver).

## How It Works

Because sandboxed apps cannot capture the global screen, DiCoy uses a privileged background daemon and inter-process communication.

```
┌─────────────────────────────────────────────────────────────────┐
│  DiCoyDaemon  (root, launchd)                                   │
│                                                                 │
│  CARenderServer ──► IOSurface pool ──► broadcast IOSurfaceID   │
│  (composited display)  (GPU memory)   (Unix Domain Socket)      │
└────────────────────────────────┬────────────────────────────────┘
                                 │  /var/jb/var/run/dicoy.sock
                                 │  sends: 4-byte IOSurfaceID only
┌────────────────────────────────▼────────────────────────────────┐
│  DiCoyTweak  (injected into target app via MobileSubstrate)     │
│                                                                 │
│  IOSurfaceLookup(id)                                            │
│       │  zero-copy — maps same GPU pages, no memcpy             │
│       ▼                                                         │
│  CVPixelBufferCreateWithIOSurface                               │
│       │                                                         │
│       ▼                                                         │
│  CMSampleBufferCreateForImageBuffer ──► app delegate callback   │
└─────────────────────────────────────────────────────────────────┘
```

The tweak hooks `AVCaptureVideoDataOutput` and `AVCaptureAudioDataOutput` using a proxy-delegate pattern. AVFoundation calls DiCoy's proxy, which substitutes the injected buffer before forwarding to the app's real delegate.

In **Media Inject** mode the daemon is bypassed entirely. `AVAssetReader` decodes video frames to 32BGRA (matching the IOSurface format) and audio to interleaved 16-bit LPCM at the session's sample rate, restamped to `CACurrentMediaTime()` for seamless delivery.

## Requirements

- Rootless jailbreak (Dopamine 2.x, palera1n rootless) **or** rootful jailbreak (checkra1n, unc0ver)
- iOS 15.0 – 17.0, arm64 / arm64e
- MobileSubstrate / ElleKit
- PreferenceLoader
- [Theos](https://theos.dev) (build environment only)

## Building

```bash
# Clone and enter the repo
git clone https://github.com/EolnMsuk/DiCoy.git
cd DiCoy

# Build all three subprojects and package (rootless by default)
make package

# Build and install directly to a connected device over SSH
make install

# Build both rootless and rootful on WSL Ubuntu
./build_all.sh
# → packages/rootless/  and  packages/rootful/
```

To build only one subproject:

```bash
make -C DiCoyDaemon
make -C DiCoyTweak
make -C DiCoyPrefs
```

To build the rootful variant explicitly:

```bash
make package THEOS_PACKAGE_SCHEME=
```

### Required environment variables

| Variable | Purpose |
|---|---|
| `THEOS` | Path to your Theos installation |
| `THEOS_DEVICE_IP` | Device IP for `make install` over SSH |
| `THEOS_DEVICE_PORT` | SSH port (default 22) |

### GitHub Actions

Push a `v*` tag to trigger an automated build and GitHub Release with both rootless and rootful `.deb` artifacts. See `.github/workflows/build.yml`.

## Installation

1. Run `./build_all.sh` or `make package` to produce `.deb` files in `packages/`.
2. Transfer the appropriate `.deb` to the device and install with your package manager, or use `make install` to do both at once.

After installation the daemon starts automatically via launchd. Confirm it is running:

```bash
ssh root@<device-ip> launchctl list | grep dicoy
```

## Usage

Open **Settings → DiCoy** on the device.

| Setting | Description |
|---|---|
| **Mode: Off** | DiCoy is inactive; all apps see the real camera and microphone. |
| **Mode: Screen Mirror** | The device display is injected as the camera feed. Microphone is passed through unchanged. |
| **Mode: Media Inject** | A local media file is injected as both camera and microphone. Enter the full path below. |
| **File Path** | Absolute path to a `.mp4` or `.mov` file on the device filesystem. |
| **Frame Rate** | 30 FPS (default) or 60 FPS. Restart the camera app to apply. |

Mode changes apply immediately. No respring is required.

## Technical Notes

**Why CARenderServer instead of ReplayKit or AVFoundation?**
ReplayKit and AVFoundation screen recording are sandboxed and require user-visible permission dialogs. `CARenderServerRenderDisplay` is a private compositor API that runs in the daemon's privileged context, delivering a fully composited frame with no prompts.

**Why IOSurface for IPC?**
Passing raw pixels over a socket at 30 FPS (1170×2532×4 bytes ≈ 14 MB/frame) would cost ~420 MB/s of memory bandwidth. IOSurface is a kernel-managed shared memory object; only its integer ID (4 bytes) crosses the socket, and `IOSurfaceLookup()` maps the same physical GPU pages into the receiving process with no copy.

**Proxy-delegate pattern**
Hooking a protocol method generically in Logos requires knowing the concrete class at compile time. Instead, DiCoy intercepts `setSampleBufferDelegate:queue:` and swaps the real delegate for a thin proxy. AVFoundation then calls the proxy for every frame, giving a single injection point that works with any delegate class the app uses.

**Audio injection format matching**
On the first microphone callback, `DiCoyAudioProxy` extracts the real session's `AudioStreamBasicDescription` (sample rate, channel count) from the `CMAudioFormatDescriptionRef` and passes it to `AVAssetReaderTrackOutput` as the output settings. This guarantees the injected LPCM audio is format-compatible with the session without any resampling.

**AltList.framework**
The vendored `AltList.framework` (in `vendor/`) provides app-selection preference cells for future per-app targeting. It is linked as a weak framework and must be installed separately on the device if those cells are used.

## Compatibility

See [compatibility.md](compatibility.md) for a full device/iOS/app compatibility matrix, known limitations, and potential conflicts with other tweaks.

## Project Structure

See [ProjectStructure.md](ProjectStructure.md) for an annotated file tree and data-flow diagram.

## Disclaimer

This project is intended for **educational and security research purposes only**. Use it only on devices you own or have explicit permission to test. The authors are not responsible for misuse. Jailbreaking may void your device warranty and reduce its security posture.
