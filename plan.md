# DiCoy — Active Fix Plan

## Device
iPhone 13 mini · iOS 16.1.1 · Dopamine 2 (rootless) · ElleKit

---

## Confirmed State

| Step | Status | Evidence |
|---|---|---|
| Tweak loads into Camera.app | ✅ | dicoy_load.txt: "Camera loaded" |
| AVCaptureSession -startRunning fires | ✅ | dicoy_session.txt |
| AVCaptureVideoPreviewLayer -addSublayer: fires | ✅ | dicoy_previewlayer.txt |
| startMirroring is entered | ✅ | dicoy_start.txt |
| Prefs plist exists on disk | ❌ FIXED | dicoy_prefs.txt: "READ FAILED: No such file" |
| Frame injection visible | ❌ untested | needs prefs fix deployed first |

## Root Cause (confirmed)
cfprefsd on iOS 16 does not flush arbitrary preference domains to disk.
`com.dicoy.prefs.plist` never existed at `/var/mobile/Library/Preferences/`.
Tweak read nil → mode defaulted to "off" → startMirroring returned early → nothing happened.

## Fix Applied
`DiCoyPrefsListController.m` now overrides `setPreferenceValue:specifier:` to
force-write the plist directly to disk on every preference change, bypassing cfprefsd.

---

## Next Test
Build + install. Open Settings → DiCoy, set mode to **Media Inject**, enter a valid
video path, back out. Then open Camera.app. The viewfinder should show the injected video.

Check after:
```bash
cat /var/mobile/Library/Preferences/com.dicoy.prefs.plist  # must now exist with mode != off
cat /var/tmp/dicoy_build.txt  # "buildSampleBuffer called" — proves injection pipeline runs
```

---

## If dicoy_build.txt still missing after prefs fix
`active` is still false. Possible reasons:
- `startMirroring` runs but `_setupVideoReaderForPath:` fails (bad path, wrong format)
- `modeChangedCallback` not firing after prefs change (need to reopen Camera)

Force-restart Camera.app after changing prefs — `modeChangedCallback` only works if
Camera is already open when prefs change; if Camera opened before prefs were written, it reads stale "off".

---

## If dicoy_build.txt exists but viewfinder unchanged
The pipeline is running. Issue is the AVSampleBufferDisplayLayer overlay not
rendering over the preview layer. Next step:
- Confirm `addSublayer:` hook fires and display layer is set up (it does — confirmed)
- Check `dLayer.frame` matches preview layer bounds
- Check if `readyForMoreMediaData` is ever true
- Consider switching to `-setSession:` hook instead of `-addSublayer:`

---

## Fix Queue (if frame injection runs but viewfinder is unaffected)

### If AVSampleBufferDisplayLayer overlay doesn't win
Switch hook point from `-addSublayer:` to `-setSession:`:
```objc
%hook AVCaptureVideoPreviewLayer
- (void)setSession:(AVCaptureSession *)session {
    %orig;
    if (!session) return;
    // set up AVSampleBufferDisplayLayer here
}
%end
```

### If MSHookMessageEx on delegate class fails silently
Hook CMSampleBufferGetImageBuffer at C level — bypasses all ObjC dispatch:
```objc
static CVImageBufferRef (*orig_GetImageBuffer)(CMSampleBufferRef) = NULL;
static CVImageBufferRef hook_GetImageBuffer(CMSampleBufferRef sbuf) {
    CVImageBufferRef injected = [[DiCoyTweakManager sharedManager] currentPixelBuffer];
    return injected ?: orig_GetImageBuffer(sbuf);
}
// in %ctor after %init:
MSHookFunction((void*)CMSampleBufferGetImageBuffer,
               (void*)hook_GetImageBuffer, (void**)&orig_GetImageBuffer);
```

---

## Architecture Notes
- Media inject is the MVP — no daemon needed. Prove this before touching screen mirror.
- Screen mirror requires DiCoyDaemon running (launchd) + IOSurface + socket.
- VCAM reference uses `com.apple.UIKit` global injection + `/var/mobile/Library/Caches/temp.mov`.

## Future Ideas
<!-- Add new findings here -->
- Photo capture injection: `AVCapturePhotoOutput -capturePhotoWithSettings:delegate:` + `MSHookMessageEx` on `captureOutput:didFinishProcessingPhoto:error:`
- `MSHookFunction` on `CVPixelBufferGetBaseAddress` as alternative hook point
