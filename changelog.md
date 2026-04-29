  # DiCoy changelog

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