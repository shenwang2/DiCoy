  # DiCoy changelog

  ---

  ## v1.0.1

  ### Bug Fixes — Compilation (iPhoneOS SDK compatibility)

  [FIX] IOSurface import — main.m, Tweak.x, DiCoyClient.h
  - Was: `#import <IOSurface/IOSurface.h>` (macOS ObjC umbrella — not present in iPhoneOS SDK)
  - Fix: Changed to `#import <IOSurface/IOSurfaceRef.h>` (cross-platform C API header, exists in all iPhoneOS SDKs)

  [FIX] CGDisplayMode* APIs removed — DiCoyDaemon/main.m
  - Was: `CGDisplayCopyDisplayMode` / `CGDisplayModeGetWidth` / `CGDisplayModeGetHeight` / `CGDisplayModeRelease` (macOS-only CoreGraphics display management; not declared in iPhoneOS SDK)
  - Fix: Replaced with `[UIScreen mainScreen].nativeBounds` for physical pixel dimensions. Added `#import <UIKit/UIKit.h>` and `UIKit` to `DiCoyDaemon_FRAMEWORKS`.

  [FIX] bootstrap_look_up undeclared — DiCoyDaemon/main.m
  - Was: `#import <mach/bootstrap.h>` (present on iOS but empty; does not declare `bootstrap_look_up`)
  - Fix: Removed the import; added explicit forward declaration: `extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *service_name, mach_port_t *sp);`

  [FIX] IOReturn / kIOReturnSuccess undeclared — DiCoyDaemon/main.m
  - Fix: Added `#import <IOKit/IOReturn.h>`

  [FIX] kIOSurfaceIsGlobal deprecated-as-error — DiCoyDaemon/Makefile
  - Was: `-Werror` caused the iOS 11.0 deprecation warning on `kIOSurfaceIsGlobal` to abort the build
  - Fix: Added `-Wno-deprecated-declarations` to `DiCoyDaemon_CFLAGS`. The flag is architecturally required for cross-process IOSurface sharing in a jailbreak daemon; the deprecation is a sandboxed-app security warning that does not apply here.

  [FIX] os_unfair_lock / OS_UNFAIR_LOCK_INIT visibility — DiCoyTweak/Tweak.x
  - Was: Logos preprocessor obscured Clang module visibility; `os_unfair_lock` and `OS_UNFAIR_LOCK_INIT` resolved as "must be imported from module 'Darwin.os.lock'"
  - Fix: Added `#import <os/lock.h>` explicitly to Tweak.x

  [FIX] ARC weak-pointer dereference UB — DiCoyTweak/Tweak.x frameCallback block
  - Was: `&weak->_surfaceLock` / `weak.latestSurface` — ARC forbids taking a member address or accessing ivars through a `__weak` pointer directly (undefined behavior)
  - Fix: Added `DiCoyTweakManager *strong = weak; if (!strong) return;` at the top of the block; replaced all `weak->` / `weak.` with `strong->` / `strong.`

  ### Bug Fixes — CI/CD

  [FIX] .deb not produced despite successful build
  - Was: `make package` without `FINALPACKAGE=1` does not finalize and write the `.deb` to `packages/`
  - Fix: Added `FINALPACKAGE=1` to the `make package` invocation in build.yml

  [FIX] Artifact staging glob missed Theos subdirectory layout
  - Was: `packages/*.deb` bare glob failed when Theos wrote the deb into a subdirectory
  - Fix: Changed to `find packages -name "*.deb" -type f` in the Stage debs step

  [FIX] control Architecture convention
  - Was: `Architecture: iphoneos-arm64` — incorrect; caused the deb to be written to an unexpected path
  - Fix: Changed to `Architecture: iphoneos-arm` (correct Theos convention; Theos promotes to `iphoneos-arm64` automatically for rootless builds)

  ### Improvements — CI/CD

  Auto-release on every push (no manual tags required)
  - Was: Release job only fired on `v*` tag pushes
  - Now: Fires on every push to main/master (not PRs); version tag derived from `Version:` in the `control` file. Pushing the same version updates the existing release in place.

  Release body includes installation compatibility table
  - Table maps each `.deb` variant to the target iOS range and supported jailbreaks
  - `draft: false` — releases are published immediately

  ### Modified Files

  - DiCoyDaemon/main.m — IOSurfaceRef.h import, UIKit nativeBounds, IOReturn, bootstrap_look_up forward decl
  - DiCoyDaemon/Makefile — added UIKit framework, -Wno-deprecated-declarations
  - DiCoyTweak/Tweak.x — IOSurfaceRef.h import, os/lock.h import, weak→strong ARC fix
  - DiCoyTweak/DiCoyClient.h — IOSurfaceRef.h import
  - control — Architecture iphoneos-arm64 → iphoneos-arm; Version 1.0.0 → 1.0.1
  - .github/workflows/build.yml — FINALPACKAGE=1, find-based deb staging, auto-release on push, version from control, compatibility table

  ---

  ## v1.0.0

  Audit Results & Changes
  Bug Fixes
  [CRITICAL] handleClient UB + heap leak — main.m
  - Was: static void handleClient(int fd) with (void *(*)(void *)) cast in pthread_create. On arm64, the pointer fdp
  would be misread as an int; fdp was never freed.
  - Fix: Signature changed to static void *handleClient(void *arg). First two lines extract fd = *(int *)arg;
  free(arg);. Added return NULL; at end.

  [BUG] buildSampleBuffer IOSurface CFRetain leak — Tweak.x
  - Was: CFRetain(surface) before the !self.active guard → retained surface leaked on that path.
  - Fix: !self.active early-return moved to the top of the method, before any retain.

  ---
  Feature Implementation

  DiCoyAudioProxy — full media inject pipeline
  - AVAssetReader + AVAssetReaderTrackOutput with interleaved signed 16-bit LPCM output.
  - Lazily initialised on the first mic callback: inspects the real sampleBuffer's CMAudioFormatDescriptionRef →
  AudioStreamBasicDescription to match the session's sample rate and channel count exactly.
  - Loops on EOF by recreating the reader against the same path.
  - All PTS restamped with CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000) so AVFoundation sees a live monotonic
  clock.
  - Guarded by _audioReaderLock (os_unfair_lock); never blocks the audio callback queue past one copyNextSampleBuffer
  call.

  buildSampleBuffer — media inject video path
  - kDicoyModeMediaInject now delegates to nextVideoSampleBuffer (AVAssetReader → BGRA CVPixelBuffer → restamped
  CMSampleBufferRef), looping the file on EOF.
  - Screen mirror path unchanged; daemon connection skipped entirely in media inject mode.

  startMirroring / stopMirroring — mode-aware
  - startMirroring: branches on mediaInject vs screenMirror; only connects to daemon in screen mirror mode.
  - stopMirroring: cancels both video and audio readers; disconnects daemon client.

  modeChangedCallback — live mode switching
  - Now handles screenMirror ↔ mediaInject transitions while a session is active by calling stopMirroring +
  startMirroring inline, so the new source takes effect on the next camera frame without requiring a camera app restart.

  DiCoyTweak/Makefile — AudioToolbox added to _FRAMEWORKS for kAudioFormatLinearPCM and AudioStreamBasicDescription link
   resolution.
   
---   

  New files created:

  - .github/workflows/build.yml — matrix CI: rootless + rootful builds on every push/PR; creates GitHub Release with both .deb artifacts on v* tags
  - build_all.sh — WSL Ubuntu local build script; validates $THEOS, builds both schemes into packages/rootless/ and packages/rootful/
  - compatibility.md — full device/iOS/jailbreak/app compatibility matrix; known limitations for both modes; tweak conflict reference
  - ProjectStructure.md — project description, annotated file tree, data-flow diagram
  - DiCoyDaemon/com.dicoy.daemon.plist.in — launchd plist template with %%JB_PREFIX%% placeholder

  Modified files:

  - DiCoyDaemon/Makefile — before-package:: generates daemon plist from template into layout/ (so it's included in the .deb); rootless/rootful install path switching; passes
  -DDICOY_ROOTLESS=1
  - DiCoyTweak/Makefile — passes -DDICOY_ROOTLESS=1 for rootless builds
  - DiCoyPrefs/Makefile — links AltList.framework as -weak_framework; rootless/rootful install path switching; stages entry.plist into layout/
  - DiCoyDaemon/DiCoyProtocol.h — replaced hardcoded socket path with DICOY_JB_PREFIX macro; added DICOY_PREFS_PATH
  - DiCoyTweak/DiCoyProtocol.h — same as above (the two copies are now identical)
  - DiCoyTweak/Tweak.x — both prefs path strings replaced with @DICOY_PREFS_PATH
  - README.md — updated: audio injection feature, rootful deb, build_all.sh, links to new docs
  - CLAUDE.md — updated: rootless/rootful macro system, media inject pipeline, AltList, launchd plist generation, CI/CD, removed stale "Known Incomplete" entry
   
   ---