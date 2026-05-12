// DiCoyTweak/Tweak.x

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurfaceRef.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CoreImage.h>
#import <AudioToolbox/AudioToolbox.h>
#import <os/lock.h>
#import <objc/runtime.h>
#import "DiCoyClient.h"
#import "DiCoyProtocol.h"

extern void diCoyServerStart(void); // DiCoyServer.m — activated in SpringBoard only
#import <substrate.h>
#import <libSandy.h>

static const void *kDiCoyDisplayLayerKey = &kDiCoyDisplayLayerKey;
static const void *kDiCoyDisplayLinkKey  = &kDiCoyDisplayLinkKey;

// =========================================================================
// DiCoyTweakManager
// =========================================================================

typedef NS_ENUM(NSInteger, DicoyRotation) {
    kDicoyRotateDefault = 0,  // no rotation
    kDicoyRotateCCW     = 1,  // 90° counter-clockwise
    kDicoyRotateCW      = 2,  // 90° clockwise
    kDicoyRotate180     = 3,  // 180° (upside-down)
};

@interface DiCoyTweakManager : NSObject
+ (instancetype)sharedManager;
- (void)startMirroring;
- (void)stopMirroring;
- (CMSampleBufferRef)buildSampleBufferMatchingBuffer:(CMSampleBufferRef)origin CF_RETURNS_RETAINED;
- (CMSampleBufferRef)nextAudioSampleBufferMatchingASBD:(const AudioStreamBasicDescription *)asbd CF_RETURNS_RETAINED;
- (BOOL)fillAudioIntoBufferList:(AudioBufferList *)ioData numFrames:(UInt32)numFrames asbd:(const AudioStreamBasicDescription *)asbd;
@property (nonatomic, strong)  DiCoyClient *client;
@property (nonatomic, assign)  IOSurfaceRef latestSurface;
@property (nonatomic, assign)  uint16_t surfaceWidth;
@property (nonatomic, assign)  uint16_t surfaceHeight;
@property (nonatomic, assign)  BOOL active;
@property (nonatomic, assign)  DicoyMode currentMode;
@property (nonatomic, copy)    NSString *currentMediaPath;
@property (nonatomic, strong)  NSURL         *recordingOutputURL;
@property (nonatomic, assign)  CFAbsoluteTime  recordingStartTime;
@property (nonatomic, assign)  DicoyRotation   videoRotation;
@end

@implementation DiCoyTweakManager {
    os_unfair_lock _surfaceLock;
    os_unfair_lock _videoReaderLock;
    os_unfair_lock _audioReaderLock;
    os_unfair_lock _previewFrameLock;
    AVAssetReader            *_videoReader;
    AVAssetReaderTrackOutput *_videoOutput;
    OSType                    _videoFormat;
    AVAssetReader            *_audioReader;
    AVAssetReaderTrackOutput *_audioOutput;
    CMSampleBufferRef         _lastInjectedFrame;    // latest video frame; display link reads this
    CMTime                    _audioNextPTS;          // running PTS for injected audio
    BOOL                      _audioPTSValid;
    NSMutableData            *_audioStagingBuffer;   // decoded int16 LPCM for AU render path
    NSUInteger                _audioStagingOffset;
    double                    _audioStagingSampleRate;
    UInt32                    _audioStagingChannels;
    // Wall-clock anchor for real-time playback. Video and audio both map their
    // positions off this, so playback runs at 1× regardless of how fast or slow
    // the host app's capture callback fires, and the two streams stay in sync.
    CFTimeInterval            _playbackAnchor;
    double                    _mediaDurationSec;
    UInt64                    _audioSamplesDrained;
}

+ (instancetype)sharedManager {
    static DiCoyTweakManager *s;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [DiCoyTweakManager new]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _surfaceLock      = OS_UNFAIR_LOCK_INIT;
        _videoReaderLock  = OS_UNFAIR_LOCK_INIT;
        _audioReaderLock  = OS_UNFAIR_LOCK_INIT;
        _previewFrameLock = OS_UNFAIR_LOCK_INIT;
        _client = [DiCoyClient new];
        __weak typeof(self) weak = self;
        _client.frameCallback = ^(IOSurfaceRef surface, uint16_t w, uint16_t h) {
            DiCoyTweakManager *strong = weak;
            if (!strong) return;
            CFRetain(surface);
            os_unfair_lock_lock(&strong->_surfaceLock);
            IOSurfaceRef old = strong.latestSurface;
            strong.latestSurface = surface;
            strong.surfaceWidth  = w;
            strong.surfaceHeight = h;
            os_unfair_lock_unlock(&strong->_surfaceLock);
            if (old) CFRelease(old);
        };
    }
    return self;
}

- (void)startMirroring {
    if (self.active) return;
    NSDictionary *prefs =
        [NSDictionary dictionaryWithContentsOfFile:@DICOY_PREFS_PATH] ?: @{};
    NSString *mode = prefs[@"mode"] ?: @"off";
    [[NSString stringWithFormat:@"%@:%@", NSProcessInfo.processInfo.processName, mode]
     writeToFile:@"/var/tmp/dicoy_mode.txt" atomically:YES
        encoding:NSUTF8StringEncoding error:nil];
    if ([mode isEqualToString:@"off"]) return;
    self.active = YES;
    if ([mode isEqualToString:@"mediaInject"]) {
        self.currentMode      = kDicoyModeMediaInject;
        self.currentMediaPath = prefs[@"mediaFilePath"] ?: @"";
        NSString *rotStr = prefs[@"videoRotation"] ?: @"default";
        if ([rotStr isEqualToString:@"ccw"])
            self.videoRotation = kDicoyRotateCCW;
        else if ([rotStr isEqualToString:@"cw"])
            self.videoRotation = kDicoyRotateCW;
        else if ([rotStr isEqualToString:@"upsideDown"])
            self.videoRotation = kDicoyRotate180;
        else
            self.videoRotation = kDicoyRotateDefault;
        // Cache media duration once so the reader knows where to loop.
        if (self.currentMediaPath.length) {
            AVURLAsset *probe = [AVURLAsset URLAssetWithURL:
                [NSURL fileURLWithPath:self.currentMediaPath] options:nil];
            double sec = CMTimeGetSeconds(probe.duration);
            _mediaDurationSec = (sec > 0.05) ? sec : 0;
        } else {
            _mediaDurationSec = 0;
        }
        _playbackAnchor      = CACurrentMediaTime();
        _audioSamplesDrained = 0;
        [self _setupVideoReaderForPath:self.currentMediaPath
                           pixelFormat:kCVPixelFormatType_32BGRA];
    } else {
        self.currentMode = kDicoyModeScreenMirror;
        if ([self.client connect]) {
            [self.client startCapture];
        } else {
            // Daemon not yet running; reconnectIfNeeded will retry each frame callback.
            [@"connect_failed_on_start" writeToFile:@"/var/tmp/dicoy_debug.txt"
                atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }
}

- (void)stopMirroring {
    if (!self.active) return;
    self.active      = NO;
    self.currentMode = kDicoyModeOff;
    [self.client stopCapture];
    [self.client disconnect];
    os_unfair_lock_lock(&_surfaceLock);
    IOSurfaceRef oldSurface = self.latestSurface;
    self.latestSurface  = NULL;
    self.surfaceWidth   = 0;
    self.surfaceHeight  = 0;
    os_unfair_lock_unlock(&_surfaceLock);
    if (oldSurface) CFRelease(oldSurface);
    os_unfair_lock_lock(&_videoReaderLock);
    [_videoReader cancelReading];
    _videoReader  = nil;
    _videoOutput  = nil;
    _videoFormat  = 0;
    os_unfair_lock_unlock(&_videoReaderLock);
    os_unfair_lock_lock(&_audioReaderLock);
    [_audioReader cancelReading];
    _audioReader = nil;
    _audioOutput = nil;
    os_unfair_lock_unlock(&_audioReaderLock);
    os_unfair_lock_lock(&_previewFrameLock);
    CMSampleBufferRef oldFrame = _lastInjectedFrame;
    _lastInjectedFrame = nil;
    os_unfair_lock_unlock(&_previewFrameLock);
    if (oldFrame) CFRelease(oldFrame);
    _audioPTSValid = NO;
    _audioStagingBuffer = nil;
    _audioStagingOffset = 0;
    _audioStagingSampleRate = 0;
    _audioStagingChannels = 0;
    _playbackAnchor = 0;
    _mediaDurationSec = 0;
    _audioSamplesDrained = 0;
}

// One reader, one track output. Raw decoded pixels — no auto-rotation.
// User-selected rotation is applied per-frame in _nextVideoFrameForOrigin:.
- (void)_setupVideoReaderForPath:(NSString *)path pixelFormat:(OSType)fmt {
    if (!path.length) return;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!track) return;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
    if (!reader) return;
    AVAssetReaderTrackOutput *out = [AVAssetReaderTrackOutput
        assetReaderTrackOutputWithTrack:track
        outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(fmt)}];
    out.alwaysCopiesSampleData = NO;
    [reader addOutput:out];
    if (![reader startReading]) return;
    os_unfair_lock_lock(&_videoReaderLock);
    [_videoReader cancelReading];
    _videoReader = reader;
    _videoOutput = out;
    _videoFormat = fmt;
    os_unfair_lock_unlock(&_videoReaderLock);
}

- (void)_setupAudioReaderForPath:(NSString *)path
                    matchingASBD:(const AudioStreamBasicDescription *)asbd {
    if (!path.length) return;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    if (!track) return;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
    if (!reader) return;
    Float64 sr = (asbd && asbd->mSampleRate > 0)       ? asbd->mSampleRate       : 44100.0;
    UInt32  ch = (asbd && asbd->mChannelsPerFrame > 0) ? asbd->mChannelsPerFrame : 1;
    NSDictionary *settings = @{
        AVFormatIDKey:               @(kAudioFormatLinearPCM),
        AVSampleRateKey:             @(sr),
        AVNumberOfChannelsKey:       @(ch),
        AVLinearPCMBitDepthKey:      @(16),
        AVLinearPCMIsNonInterleaved: @NO,
        AVLinearPCMIsFloatKey:       @NO,
        AVLinearPCMIsBigEndianKey:   @NO,
    };
    AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput
        assetReaderTrackOutputWithTrack:track outputSettings:settings];
    output.alwaysCopiesSampleData = NO;
    [reader addOutput:output];
    if (![reader startReading]) return;
    os_unfair_lock_lock(&_audioReaderLock);
    [_audioReader cancelReading];
    _audioReader = reader;
    _audioOutput = output;
    os_unfair_lock_unlock(&_audioReaderLock);
}

// origin: real incoming sample buffer whose pixel format we match. Pass nil for the
// AVSampleBufferDisplayLayer path (defaults to BGRA, which the display layer accepts).
- (CMSampleBufferRef)buildSampleBufferMatchingBuffer:(CMSampleBufferRef)origin {
    if (!self.active) return NULL;

    if (self.currentMode == kDicoyModeMediaInject) {
        if (origin == nil) {
            // Display-link preview: return the last frame the camera hook produced
            // without advancing the reader, eliminating reader contention.
            os_unfair_lock_lock(&_previewFrameLock);
            CMSampleBufferRef cached = _lastInjectedFrame
                ? (CMSampleBufferRef)CFRetain(_lastInjectedFrame) : NULL;
            os_unfair_lock_unlock(&_previewFrameLock);
            // Fall through to reader if no camera hook has produced a frame yet
            // (preview-layer-only apps with no AVCaptureVideoDataOutput).
            if (cached) return cached;
        }
        return [self _nextVideoFrameForOrigin:origin];
    }

    // Screen mirror — zero-copy wrap of the daemon's latest IOSurface.
    os_unfair_lock_lock(&_surfaceLock);
    IOSurfaceRef surface = self.latestSurface;
    uint16_t w = self.surfaceWidth, h = self.surfaceHeight;
    if (surface) CFRetain(surface);
    os_unfair_lock_unlock(&_surfaceLock);
    if (!surface) {
        // No frame yet — daemon may have started after the app. Retry the connection
        // every 3 s without blocking the camera callback queue.
        [self.client reconnectIfNeeded];
        return NULL;
    }

    // Infer target pixel format and dimensions from the real camera frame.
    // The daemon surface is always BGRA; many camera pipelines expect 420v/420f.
    OSType targetFmt = kCVPixelFormatType_32BGRA;
    uint32_t targetW = w, targetH = h;
    if (origin) {
        CVImageBufferRef originPix = CMSampleBufferGetImageBuffer(origin);
        if (originPix) {
            targetW = (uint32_t)CVPixelBufferGetWidth(originPix);
            targetH = (uint32_t)CVPixelBufferGetHeight(originPix);
        }
        CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(origin);
        if (fd) targetFmt = CMFormatDescriptionGetMediaSubType(fd);
    }

    // Read the actual pixel format from the IOSurface rather than assuming BGRA.
    // The display framebuffer is typically BGRA on iOS but may differ on HDR displays.
    OSType surfaceFmt = IOSurfaceGetPixelFormat(surface);
    if (!surfaceFmt) surfaceFmt = kCVPixelFormatType_32BGRA;

    NSDictionary *pbAttrs = @{
        (id)kCVPixelBufferWidthKey:               @(w),
        (id)kCVPixelBufferHeightKey:              @(h),
        (id)kCVPixelBufferPixelFormatTypeKey:     @(surfaceFmt),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferRef surfacePix = NULL;
    CVReturn cvr = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface,
                                                     (__bridge CFDictionaryRef)pbAttrs, &surfacePix);
    CFRelease(surface);
    if (cvr != kCVReturnSuccess || !surfacePix) return NULL;

    // Scale and/or convert pixel format to match what the camera app expects.
    // CIContext uses GPU when available; it is created once and reused.
    static CIContext        *sCICtx;
    static dispatch_once_t   sCICtxOnce;
    dispatch_once(&sCICtxOnce, ^{ sCICtx = [CIContext contextWithOptions:nil]; });

    CVPixelBufferRef pix = surfacePix;
    BOOL needsConvert = (targetW != w || targetH != h || targetFmt != surfaceFmt);
    if (needsConvert) {
        CIImage *ciImg = [CIImage imageWithCVPixelBuffer:surfacePix];
        if (targetW != w || targetH != h) {
            CGFloat sx = (CGFloat)targetW / w, sy = (CGFloat)targetH / h;
            ciImg = [ciImg imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];
        }
        CVPixelBufferRef converted = NULL;
        NSDictionary *cvAttrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
        if (CVPixelBufferCreate(kCFAllocatorDefault, targetW, targetH, targetFmt,
                                (__bridge CFDictionaryRef)cvAttrs,
                                &converted) == kCVReturnSuccess && converted) {
            [sCICtx render:ciImg toCVPixelBuffer:converted];
            CVPixelBufferRelease(surfacePix);
            pix = converted;
        }
        // If conversion fails, fall through with original BGRA surface pix.
    }

    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pix, &fmt) != noErr) {
        CVPixelBufferRelease(pix); return NULL;
    }

    // Match timing from the real camera frame so the app's pipeline accepts the buffer.
    CMSampleTimingInfo timing;
    if (origin) {
        timing = (CMSampleTimingInfo){
            .duration              = CMSampleBufferGetDuration(origin),
            .presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(origin),
            .decodeTimeStamp       = CMSampleBufferGetDecodeTimeStamp(origin),
        };
    } else {
        timing = (CMSampleTimingInfo){
            .duration              = CMTimeMake(1, DICOY_TARGET_FPS),
            .presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000),
            .decodeTimeStamp       = kCMTimeInvalid,
        };
    }

    CMSampleBufferRef sb = NULL;
    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pix, true,
                                       NULL, NULL, fmt, &timing, &sb);
    CFRelease(fmt);
    CVPixelBufferRelease(pix);
    return sb;
}

- (CMSampleBufferRef)_nextVideoFrameForOrigin:(CMSampleBufferRef)origin {
    // Derive pixel format from the real incoming buffer (nil → BGRA for display layer).
    OSType sub = kCVPixelFormatType_32BGRA;
    if (origin) {
        CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(origin);
        if (fd) sub = CMFormatDescriptionGetMediaSubType(fd);
    }

    // Wall-clock target: how far into the (looped) media are we right now?
    // We drive playback off the system clock instead of advancing one frame per
    // callback — this decouples playback speed from the host app's capture rate.
    CFTimeInterval now      = CACurrentMediaTime();
    CFTimeInterval elapsed  = (_playbackAnchor > 0) ? (now - _playbackAnchor) : 0;
    double         loopSec  = _mediaDurationSec;
    double         targetSec = (loopSec > 0) ? fmod(elapsed, loopSec) : elapsed;

    // Pull the frame whose PTS is the greatest ≤ targetSec. When the reader's
    // current frame is still in the future (callback came faster than video fps),
    // we reuse the cached frame instead of advancing. When the reader is behind
    // (callback is slower than video fps, e.g. QQ throttles to 15fps on a 30fps
    // video), we drop frames to catch up.
    os_unfair_lock_lock(&_videoReaderLock);
    BOOL ok = _videoReader
           && (_videoReader.status == AVAssetReaderStatusReading)
           && (_videoFormat == sub);
    if (!ok) {
        os_unfair_lock_unlock(&_videoReaderLock);
        NSString *path = self.currentMediaPath;
        if (!path.length) return NULL;
        [self _setupVideoReaderForPath:path pixelFormat:sub];
        os_unfair_lock_lock(&_videoReaderLock);
        ok = _videoReader && (_videoReader.status == AVAssetReaderStatusReading);
        if (!ok) { os_unfair_lock_unlock(&_videoReaderLock); return NULL; }
    }

    CMSampleBufferRef fileBuf = nil;
    // Track reader's current decode position. When it overshoots the loop
    // duration, restart. When targetSec jumps backwards across the loop boundary,
    // restart. Otherwise pull frames until reader PTS catches up to targetSec.
    static double sReaderLastPTS = 0;     // PTS of the last frame we returned
    // (static is fine here: at most one reader exists at a time; startMirroring
    //  resets state via _setupVideoReaderForPath:. _videoReaderLock gates access.)
    BOOL needReset = NO;
    if (targetSec + 0.001 < sReaderLastPTS) needReset = YES;  // looped past zero
    if (needReset) {
        os_unfair_lock_unlock(&_videoReaderLock);
        [self _setupVideoReaderForPath:self.currentMediaPath pixelFormat:sub];
        os_unfair_lock_lock(&_videoReaderLock);
        sReaderLastPTS = 0;
        ok = _videoReader && (_videoReader.status == AVAssetReaderStatusReading);
        if (!ok) { os_unfair_lock_unlock(&_videoReaderLock); return NULL; }
    }

    // Only advance the reader when we are BEHIND wall-clock target. If the host
    // app calls us faster than the video's fps (e.g. 60Hz callbacks on a 30fps
    // video), we return the cached last frame without consuming a new one —
    // otherwise playback speeds up by the callback/video ratio.
    BOOL needAdvance = (sReaderLastPTS < targetSec - 0.0005);
    if (needAdvance) {
        // Drop-to-target: advance reader while next-frame PTS < targetSec.
        CMSampleBufferRef nextBuf = [_videoOutput copyNextSampleBuffer];
        while (nextBuf) {
            CMTime pts = CMSampleBufferGetOutputPresentationTimeStamp(nextBuf);
            if (!CMTIME_IS_VALID(pts)) pts = CMSampleBufferGetPresentationTimeStamp(nextBuf);
            double ptsSec = CMTIME_IS_VALID(pts) ? CMTimeGetSeconds(pts) : sReaderLastPTS;
            if (fileBuf) CFRelease(fileBuf);
            fileBuf = nextBuf;
            sReaderLastPTS = ptsSec;
            if (ptsSec >= targetSec) { nextBuf = nil; break; }
            nextBuf = [_videoOutput copyNextSampleBuffer];
        }
    }

    // Reader drained — EOF during catch-up. Restart and grab the first frame.
    if (needAdvance && !fileBuf) {
        os_unfair_lock_unlock(&_videoReaderLock);
        [self _setupVideoReaderForPath:self.currentMediaPath pixelFormat:sub];
        os_unfair_lock_lock(&_videoReaderLock);
        sReaderLastPTS = 0;
        ok = _videoReader && (_videoReader.status == AVAssetReaderStatusReading);
        fileBuf = ok ? [_videoOutput copyNextSampleBuffer] : nil;
        if (fileBuf) {
            CMTime pts = CMSampleBufferGetOutputPresentationTimeStamp(fileBuf);
            if (!CMTIME_IS_VALID(pts)) pts = CMSampleBufferGetPresentationTimeStamp(fileBuf);
            sReaderLastPTS = CMTIME_IS_VALID(pts) ? CMTimeGetSeconds(pts) : 0;
        }
    }
    os_unfair_lock_unlock(&_videoReaderLock);

    if (!fileBuf) {
        // Either we chose not to advance (ahead of target, reuse cached) or
        // reader is still initialising. Return the cached last frame so the
        // host gets a continuous stream of valid buffers.
        os_unfair_lock_lock(&_previewFrameLock);
        CMSampleBufferRef cached = _lastInjectedFrame
            ? (CMSampleBufferRef)CFRetain(_lastInjectedFrame) : NULL;
        os_unfair_lock_unlock(&_previewFrameLock);
        return cached;
    }

    // Mirror timing from the real buffer so the app's pipeline accepts the frame.
    CMSampleTimingInfo timing;
    if (origin) {
        timing = (CMSampleTimingInfo){
            .duration              = CMSampleBufferGetDuration(origin),
            .presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(origin),
            .decodeTimeStamp       = CMSampleBufferGetDecodeTimeStamp(origin),
        };
    } else {
        CMTime dur = CMSampleBufferGetDuration(fileBuf);
        if (!CMTIME_IS_VALID(dur) || CMTIME_IS_INDEFINITE(dur)) dur = CMTimeMake(1, DICOY_TARGET_FPS);
        timing = (CMSampleTimingInfo){
            .duration              = dur,
            .presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000),
            .decodeTimeStamp       = kCMTimeInvalid,
        };
    }

    CVImageBufferRef pix = CMSampleBufferGetImageBuffer(fileBuf);

    // Apply user-selected rotation via CIContext (GPU-accelerated).
    // The CIContext is created once and reused; rotation is applied after decoding
    // so it works with any pixel format the reader produces.
    CVPixelBufferRef rotatedPix = NULL;
    if (pix && self.videoRotation != kDicoyRotateDefault) {
        static CIContext        *sRotCtx;
        static dispatch_once_t   sRotCtxOnce;
        dispatch_once(&sRotCtxOnce, ^{ sRotCtx = [CIContext contextWithOptions:nil]; });

        size_t srcW   = CVPixelBufferGetWidth(pix);
        size_t srcH   = CVPixelBufferGetHeight(pix);
        OSType srcFmt = CVPixelBufferGetPixelFormatType(pix);

        CGAffineTransform rotTx;
        size_t dstW, dstH;
        if (self.videoRotation == kDicoyRotateCCW) {
            rotTx = CGAffineTransformMakeRotation(M_PI_2);   // 90° CCW
            dstW = srcH; dstH = srcW;
        } else if (self.videoRotation == kDicoyRotateCW) {
            rotTx = CGAffineTransformMakeRotation(-M_PI_2);  // 90° CW
            dstW = srcH; dstH = srcW;
        } else {                                              // 180°
            rotTx = CGAffineTransformMakeRotation(M_PI);
            dstW = srcW; dstH = srcH;
        }

        CIImage *ciImg   = [CIImage imageWithCVPixelBuffer:pix];
        CIImage *rotated = [ciImg imageByApplyingTransform:rotTx];
        // Normalize: rotation may shift origin to negative coordinates.
        CGRect ext = rotated.extent;
        rotated = [rotated imageByApplyingTransform:
            CGAffineTransformMakeTranslation(-ext.origin.x, -ext.origin.y)];

        NSDictionary *rotAttrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
        if (CVPixelBufferCreate(kCFAllocatorDefault, dstW, dstH, srcFmt,
                                (__bridge CFDictionaryRef)rotAttrs,
                                &rotatedPix) == kCVReturnSuccess && rotatedPix) {
            [sRotCtx render:rotated toCVPixelBuffer:rotatedPix];
        }
    }

    CVImageBufferRef effectivePix = rotatedPix ?: pix;
    CMVideoFormatDescriptionRef fmt = NULL;
    CMSampleBufferRef result = NULL;
    if (effectivePix &&
        CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, effectivePix, &fmt) == noErr) {
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, effectivePix, true, NULL, NULL,
                                           fmt, &timing, &result);
        CFRelease(fmt);
        if (result && origin) {
            CFDictionaryRef exif = CMGetAttachment(origin, CFSTR("{Exif}"), NULL);
            CFDictionaryRef tiff = CMGetAttachment(origin, CFSTR("{TIFF}"), NULL);
            if (exif) CMSetAttachment(result, CFSTR("{Exif}"), exif, kCMAttachmentMode_ShouldPropagate);
            if (tiff) CMSetAttachment(result, CFSTR("{TIFF}"), tiff, kCMAttachmentMode_ShouldPropagate);
        }
    }
    if (rotatedPix) CVPixelBufferRelease(rotatedPix);
    CFRelease(fileBuf);
    if (result) {
        os_unfair_lock_lock(&_previewFrameLock);
        CMSampleBufferRef old = _lastInjectedFrame;
        _lastInjectedFrame = (CMSampleBufferRef)CFRetain(result);
        os_unfair_lock_unlock(&_previewFrameLock);
        if (old) CFRelease(old);
    }
    return result;
}

- (CMSampleBufferRef)nextAudioSampleBufferMatchingASBD:(const AudioStreamBasicDescription *)asbd {
    // Loop-aware audio delivery: advance reader to the position matching the
    // same wall-clock target the video uses, so the two streams stay in sync.
    double targetSec = 0;
    if (_playbackAnchor > 0 && _mediaDurationSec > 0) {
        double elapsed = CACurrentMediaTime() - _playbackAnchor;
        targetSec = fmod(elapsed, _mediaDurationSec);
    }

    static double sAudioReaderLastPTS = 0;

    os_unfair_lock_lock(&_audioReaderLock);
    BOOL needsSetup = (_audioReader == nil);
    BOOL needsRestart = (!needsSetup &&
                        targetSec + 0.01 < sAudioReaderLastPTS);  // looped
    os_unfair_lock_unlock(&_audioReaderLock);

    if (needsSetup || needsRestart) {
        NSString *path = self.currentMediaPath;
        if (!path.length) return NULL;
        [self _setupAudioReaderForPath:path matchingASBD:asbd];
        sAudioReaderLastPTS = 0;
    }

    CMSampleBufferRef buf = nil;
    os_unfair_lock_lock(&_audioReaderLock);
    // Drop-to-target: pull audio buffers until reader PTS ≥ targetSec.
    CMSampleBufferRef next = (_audioReader && _audioReader.status == AVAssetReaderStatusReading)
        ? [_audioOutput copyNextSampleBuffer] : nil;
    while (next) {
        CMTime pts = CMSampleBufferGetOutputPresentationTimeStamp(next);
        if (!CMTIME_IS_VALID(pts)) pts = CMSampleBufferGetPresentationTimeStamp(next);
        double ptsSec = CMTIME_IS_VALID(pts) ? CMTimeGetSeconds(pts) : sAudioReaderLastPTS;
        if (buf) CFRelease(buf);
        buf = next;
        sAudioReaderLastPTS = ptsSec;
        if (ptsSec >= targetSec) { next = nil; break; }
        next = [_audioOutput copyNextSampleBuffer];
    }
    os_unfair_lock_unlock(&_audioReaderLock);

    // Reader drained — loop.
    if (!buf) {
        NSString *path = self.currentMediaPath;
        if (!path.length) return NULL;
        [self _setupAudioReaderForPath:path matchingASBD:asbd];
        sAudioReaderLastPTS = 0;
        os_unfair_lock_lock(&_audioReaderLock);
        if (_audioReader && _audioReader.status == AVAssetReaderStatusReading) {
            buf = [_audioOutput copyNextSampleBuffer];
        }
        os_unfair_lock_unlock(&_audioReaderLock);
        if (!buf) return NULL;
    }

    CMTime dur = CMSampleBufferGetDuration(buf);
    if (!CMTIME_IS_VALID(dur) || CMTIME_IS_INDEFINITE(dur))
        dur = CMTimeMake(1024, 44100); // fallback: 1024 samples @ 44.1 kHz

    // Anchor PTS on first buffer; increment by exact duration each call so the
    // pipeline sees a gapless, jitter-free audio stream.
    if (!_audioPTSValid) {
        _audioNextPTS  = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
        _audioPTSValid = YES;
    }
    CMTime pts    = _audioNextPTS;
    _audioNextPTS = CMTimeAdd(pts, dur);

    CMSampleTimingInfo timing = {
        .duration              = dur,
        .presentationTimeStamp = pts,
        .decodeTimeStamp       = kCMTimeInvalid,
    };
    CMSampleBufferRef restamped = NULL;
    CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, buf, 1, &timing, &restamped);
    CFRelease(buf);
    return restamped;
}

// AudioUnit render path (WebRTC / Voice Processing I/O). Reads int16 LPCM from the
// AVAssetReader staging buffer and converts to whatever format the AU expects.
// Playback position is driven off the wall-clock anchor _playbackAnchor so the
// effective rate stays 1× even if the host AU render callback is slow, and audio
// stays in lockstep with the video stream (which uses the same anchor).
- (BOOL)fillAudioIntoBufferList:(AudioBufferList *)ioData
                      numFrames:(UInt32)numFrames
                           asbd:(const AudioStreamBasicDescription *)asbd {
    if (!self.active || !ioData || numFrames == 0 || !self.currentMediaPath.length) return NO;

    double targetSR  = (asbd && asbd->mSampleRate > 0)       ? asbd->mSampleRate       : 48000.0;
    UInt32 targetCh  = (asbd && asbd->mChannelsPerFrame > 0) ? asbd->mChannelsPerFrame : 1;
    BOOL   isFloat   = asbd ? !!(asbd->mFormatFlags & kAudioFormatFlagIsFloat)          : YES;
    BOOL   isNonInter= asbd ? !!(asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) : YES;

    NSUInteger frameStride = targetCh * sizeof(int16_t);
    NSUInteger bytesNeeded = numFrames * frameStride;

    // Recreate reader if format changed or not initialized.
    BOOL formatChanged = (_audioStagingSampleRate != targetSR || _audioStagingChannels != targetCh);
    os_unfair_lock_lock(&_audioReaderLock);
    BOOL readerOk = _audioReader && (_audioReader.status == AVAssetReaderStatusReading);
    os_unfair_lock_unlock(&_audioReaderLock);

    if (formatChanged || !readerOk || !_audioStagingBuffer) {
        AudioStreamBasicDescription rd = { .mSampleRate = targetSR, .mChannelsPerFrame = targetCh };
        [self _setupAudioReaderForPath:self.currentMediaPath matchingASBD:&rd];
        _audioStagingBuffer     = _audioStagingBuffer ?: [NSMutableData dataWithCapacity:65536];
        _audioStagingBuffer.length = 0;
        _audioStagingOffset     = 0;
        _audioStagingSampleRate = targetSR;
        _audioStagingChannels   = targetCh;
        _audioSamplesDrained    = 0;
    }

    // How many samples SHOULD we have delivered by now, looping-aware?
    UInt64 targetTotalSamples = 0;
    if (_playbackAnchor > 0) {
        double elapsed = CACurrentMediaTime() - _playbackAnchor;
        if (elapsed < 0) elapsed = 0;
        targetTotalSamples = (UInt64)(elapsed * targetSR);
    } else {
        targetTotalSamples = _audioSamplesDrained + numFrames;
    }
    UInt64 wantDrainedAfterThisCall = targetTotalSamples;
    if (wantDrainedAfterThisCall < _audioSamplesDrained + numFrames)
        wantDrainedAfterThisCall = _audioSamplesDrained + numFrames;
    UInt64 totalFramesToProduce = wantDrainedAfterThisCall - _audioSamplesDrained;
    UInt64 dropBeforeOutput = (totalFramesToProduce > numFrames)
        ? (totalFramesToProduce - numFrames) : 0;
    // Deadband: only apply drift correction when the accumulated lag is large
    // enough to matter. Below ~300 ms, the drops manifest as audible clicks
    // without measurably improving A/V sync. When real drift exceeds the
    // threshold, we catch up in one bigger step (one rare click instead of
    // continuous crackle).
    UInt64 minDropFrames = (UInt64)(targetSR * 0.300);     // 300ms
    if (dropBeforeOutput < minDropFrames) {
        dropBeforeOutput = 0;
        wantDrainedAfterThisCall = _audioSamplesDrained + numFrames;
    }
    // If capture is SLOWER than real time, drop samples so we stay in wall-clock
    // sync (prevents the audio from lagging further and further behind the video).
    NSUInteger dropBytes   = (NSUInteger)(dropBeforeOutput * frameStride);
    NSUInteger needAllBytes = bytesNeeded + dropBytes;

    // Drain file into staging until we have enough int16 frames, looping on EOF.
    while ((_audioStagingBuffer.length - _audioStagingOffset) < needAllBytes) {
        os_unfair_lock_lock(&_audioReaderLock);
        CMSampleBufferRef fb = (_audioReader && _audioReader.status == AVAssetReaderStatusReading)
            ? [_audioOutput copyNextSampleBuffer] : nil;
        os_unfair_lock_unlock(&_audioReaderLock);

        if (!fb) {
            // EOF — compact and loop.
            NSUInteger rem = _audioStagingBuffer.length - _audioStagingOffset;
            if (rem) memmove(_audioStagingBuffer.mutableBytes,
                             (uint8_t *)_audioStagingBuffer.bytes + _audioStagingOffset, rem);
            _audioStagingBuffer.length = rem;
            _audioStagingOffset = 0;
            AudioStreamBasicDescription rd = { .mSampleRate = targetSR, .mChannelsPerFrame = targetCh };
            [self _setupAudioReaderForPath:self.currentMediaPath matchingASBD:&rd];
            os_unfair_lock_lock(&_audioReaderLock);
            fb = (_audioReader && _audioReader.status == AVAssetReaderStatusReading)
                ? [_audioOutput copyNextSampleBuffer] : nil;
            os_unfair_lock_unlock(&_audioReaderLock);
            if (!fb) return NO;
        }

        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(fb);
        if (block) {
            size_t len = 0; char *ptr = NULL;
            CMBlockBufferGetDataPointer(block, 0, NULL, &len, &ptr);
            [_audioStagingBuffer appendBytes:ptr length:len];
        }
        CFRelease(fb);
    }

    // Discard the "drop" frames so that the next bytesNeeded window lines up
    // with wall clock.
    if (dropBytes > 0) {
        _audioStagingOffset += dropBytes;
    }

    // Compact periodically to avoid unbounded growth.
    if (_audioStagingOffset > 32768) {
        NSUInteger rem = _audioStagingBuffer.length - _audioStagingOffset;
        memmove(_audioStagingBuffer.mutableBytes,
                (uint8_t *)_audioStagingBuffer.bytes + _audioStagingOffset, rem);
        _audioStagingBuffer.length = rem;
        _audioStagingOffset = 0;
    }

    int16_t *src = (int16_t *)((uint8_t *)_audioStagingBuffer.bytes + _audioStagingOffset);
    _audioStagingOffset += bytesNeeded;
    _audioSamplesDrained = wantDrainedAfterThisCall;

    // Convert int16 interleaved → target format and fill ioData.
    if (isFloat && isNonInter) {
        for (UInt32 ch = 0; ch < MIN(targetCh, ioData->mNumberBuffers); ch++) {
            float *dst = (float *)ioData->mBuffers[ch].mData;
            for (UInt32 f = 0; f < numFrames; f++)
                dst[f] = src[f * targetCh + ch] * (1.0f / 32768.0f);
        }
    } else if (isFloat) {
        float *dst = (float *)ioData->mBuffers[0].mData;
        for (UInt32 i = 0; i < numFrames * targetCh; i++)
            dst[i] = src[i] * (1.0f / 32768.0f);
    } else {
        // Int16 or other — direct copy.
        memcpy(ioData->mBuffers[0].mData, src,
               MIN(bytesNeeded, ioData->mBuffers[0].mDataByteSize));
    }
    return YES;
}

// Build a looping composition of the injected video that fills `duration` seconds,
// delete Camera.app's raw output, export ours to the same URL, then call completion.
// Used to replace AVCaptureMovieFileOutput recordings after they finish.
- (void)_replaceVideoAtURL:(NSURL *)outputURL
                  duration:(NSTimeInterval)duration
                completion:(dispatch_block_t)completion {
    if (!self.currentMediaPath.length || duration <= 0) {
        if (completion) completion(); return;
    }
    AVURLAsset *src = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:self.currentMediaPath]
                                          options:nil];
    double srcSec = CMTimeGetSeconds(src.duration);
    if (srcSec <= 0) { if (completion) completion(); return; }

    AVMutableComposition *comp = [AVMutableComposition composition];
    AVAssetTrack *srcV = [[src tracksWithMediaType:AVMediaTypeVideo] firstObject];
    AVAssetTrack *srcA = [[src tracksWithMediaType:AVMediaTypeAudio] firstObject];
    AVMutableCompositionTrack *compV = srcV
        ? [comp addMutableTrackWithMediaType:AVMediaTypeVideo
                             preferredTrackID:kCMPersistentTrackID_Invalid] : nil;
    AVMutableCompositionTrack *compA = srcA
        ? [comp addMutableTrackWithMediaType:AVMediaTypeAudio
                             preferredTrackID:kCMPersistentTrackID_Invalid] : nil;

    CMTime cursor = kCMTimeZero;
    double filled = 0.0;
    while (filled < duration) {
        double seg = MIN(duration - filled, srcSec);
        CMTimeRange r = CMTimeRangeMake(kCMTimeZero, CMTimeMakeWithSeconds(seg, 600));
        if (compV && srcV) [compV insertTimeRange:r ofTrack:srcV atTime:cursor error:nil];
        if (compA && srcA) [compA insertTimeRange:r ofTrack:srcA atTime:cursor error:nil];
        cursor = CMTimeAdd(cursor, CMTimeMakeWithSeconds(seg, 600));
        filled += seg;
    }

    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
    AVAssetExportSession *exp = [AVAssetExportSession exportSessionWithAsset:comp
                                                                  presetName:AVAssetExportPresetHighestQuality];
    exp.outputURL      = outputURL;
    exp.outputFileType = AVFileTypeQuickTimeMovie;
    [exp exportAsynchronouslyWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(); });
    }];
}

@end


// =========================================================================
// AudioUnit render hook — covers WebRTC (Discord, FaceTime, etc.) and any app
// that uses Voice Processing I/O or Remote I/O directly instead of
// AVCaptureAudioDataOutput.  Bus 1 is the microphone input on all I/O units.
// =========================================================================

// Format cache: inferred from the filled AudioBufferList after origRender returns,
// so we never call AudioUnitGetProperty from inside the render callback.
static AudioUnit              gCachedAU      = NULL;
static UInt32                 gCachedBus     = UINT32_MAX;
static AudioStreamBasicDescription gCachedASBD = {};
static os_unfair_lock         gCachedAULock  = OS_UNFAIR_LOCK_INIT;

static AudioStreamBasicDescription dicoyInferAUFormat(AudioUnit unit, UInt32 bus,
                                                       UInt32 numFrames,
                                                       const AudioBufferList *ioData) {
    os_unfair_lock_lock(&gCachedAULock);
    if (gCachedAU == unit && gCachedBus == bus && gCachedASBD.mSampleRate > 0) {
        AudioStreamBasicDescription a = gCachedASBD;
        os_unfair_lock_unlock(&gCachedAULock);
        return a;
    }
    os_unfair_lock_unlock(&gCachedAULock);

    if (!ioData || ioData->mNumberBuffers == 0 || numFrames == 0)
        return (AudioStreamBasicDescription){};

    BOOL isNonInter      = (ioData->mNumberBuffers > 1);
    UInt32 bytesPerFrame = ioData->mBuffers[0].mDataByteSize / numFrames;
    BOOL isFloat         = (bytesPerFrame == sizeof(float));
    UInt32 channels      = isNonInter ? ioData->mNumberBuffers : 1;

    AudioStreamBasicDescription asbd = {
        .mSampleRate       = 48000.0,   // Voice Processing I/O default on modern iOS
        .mFormatID         = kAudioFormatLinearPCM,
        .mFormatFlags      = kAudioFormatFlagIsPacked
                           | (isFloat    ? kAudioFormatFlagIsFloat          : 0)
                           | (isNonInter ? kAudioFormatFlagIsNonInterleaved : 0),
        .mChannelsPerFrame = channels,
        .mBitsPerChannel   = bytesPerFrame * 8,
        .mFramesPerPacket  = 1,
        .mBytesPerFrame    = bytesPerFrame,
        .mBytesPerPacket   = bytesPerFrame,
    };

    os_unfair_lock_lock(&gCachedAULock);
    gCachedAU   = unit;
    gCachedBus  = bus;
    gCachedASBD = asbd;
    os_unfair_lock_unlock(&gCachedAULock);
    return asbd;
}

static OSStatus (*origAudioUnitRender)(AudioUnit, AudioUnitRenderActionFlags *,
                                        const AudioTimeStamp *, UInt32, UInt32,
                                        AudioBufferList *) = NULL;

static OSStatus dicoyAudioUnitRender(AudioUnit inUnit,
                                      AudioUnitRenderActionFlags *ioActionFlags,
                                      const AudioTimeStamp *inTimeStamp,
                                      UInt32 inOutputBusNumber,
                                      UInt32 inNumberFrames,
                                      AudioBufferList *ioData) {
    OSStatus result = origAudioUnitRender(inUnit, ioActionFlags, inTimeStamp,
                                           inOutputBusNumber, inNumberFrames, ioData);
    // Bus 1 = microphone input on all I/O audio units.
    if (result != noErr || inOutputBusNumber != 1 || !ioData || inNumberFrames == 0)
        return result;
    DiCoyTweakManager *mgr = [DiCoyTweakManager sharedManager];
    if (!mgr.active || mgr.currentMode != kDicoyModeMediaInject) return result;
    AudioStreamBasicDescription asbd = dicoyInferAUFormat(inUnit, inOutputBusNumber,
                                                           inNumberFrames, ioData);
    if (asbd.mSampleRate == 0) return result;
    [mgr fillAudioIntoBufferList:ioData numFrames:inNumberFrames asbd:&asbd];
    return result;
}


// =========================================================================
// Unified delegate hook
//
// MSHookMessageEx patches the method table. If two separate hooks both call
// it on the same class+selector (e.g., when the same delegate class handles
// both AVCaptureVideoDataOutput and AVCaptureAudioDataOutput), the second
// call chains onto the first: audio_hook → video_hook → original. A VIDEO
// buffer reaching the audio_hook produces a NULL ASBD; an audio buffer is
// fetched and delivered as video — corruption/crash. Fix: one class registry,
// one IMP per class that dispatches on the output type.
// =========================================================================

static NSMutableSet   *gHookedDelegateClasses;
static dispatch_once_t gHookedDelegateOnce;

static void dicoyHookDelegate(Class cls) {
    if (!cls) return;
    dispatch_once(&gHookedDelegateOnce, ^{ gHookedDelegateClasses = [NSMutableSet new]; });
    NSString *name = NSStringFromClass(cls);
    @synchronized(gHookedDelegateClasses) {
        if ([gHookedDelegateClasses containsObject:name]) return;
        [gHookedDelegateClasses addObject:name];
    }
    __block void (*origIMP)(id, SEL, AVCaptureOutput *,
                            CMSampleBufferRef,
                            AVCaptureConnection *) = nil;
    MSHookMessageEx(
        cls,
        @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
        imp_implementationWithBlock(
            ^(id blockSelf,
              AVCaptureOutput *output,
              CMSampleBufferRef sampleBuffer,
              AVCaptureConnection *connection) {
                DiCoyTweakManager *mgr = [DiCoyTweakManager sharedManager];
                CMSampleBufferRef injected = nil;
                if (mgr.active) {
                    if (mgr.currentMode == kDicoyModeMediaInject) {
                        if ([output isKindOfClass:[AVCaptureVideoDataOutput class]]) {
                            injected = [mgr buildSampleBufferMatchingBuffer:sampleBuffer];
                        } else if ([output isKindOfClass:[AVCaptureAudioDataOutput class]]) {
                            CMFormatDescriptionRef fd =
                                CMSampleBufferGetFormatDescription(sampleBuffer);
                            const AudioStreamBasicDescription *asbd =
                                CMAudioFormatDescriptionGetStreamBasicDescription(
                                    (CMAudioFormatDescriptionRef)fd);
                            injected = [mgr nextAudioSampleBufferMatchingASBD:asbd];
                        }
                    } else if (mgr.currentMode == kDicoyModeScreenMirror) {
                        if ([output isKindOfClass:[AVCaptureVideoDataOutput class]]) {
                            injected = [mgr buildSampleBufferMatchingBuffer:sampleBuffer];
                        }
                        // Screen mirror: audio passes through unchanged
                    }
                }
                origIMP(blockSelf,
                        @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
                        output, injected ?: sampleBuffer, connection);
                if (injected) CFRelease(injected);
            }),
        (IMP *)&origIMP
    );
}


// =========================================================================
// Logos hooks
// =========================================================================

%hook AVCaptureSession

- (void)startRunning {
    %orig;
    [[DiCoyTweakManager sharedManager] startMirroring];
}

- (void)stopRunning {
    %orig; // stop the session first so all in-flight callbacks drain before teardown
    [[DiCoyTweakManager sharedManager] stopMirroring];
}

%end


%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    if (delegate && queue) dicoyHookDelegate([delegate class]);
    %orig;
}

%end


// =========================================================================
// Photo output hook — still captures via AVCapturePhotoOutput bypass the
// AVCaptureVideoDataOutput delegate entirely.  We MSHookMessageEx the photo
// delegate's -captureOutput:didFinishProcessingPhoto:error: and, the first
// time it fires, also hook the concrete AVCapturePhoto class methods that
// Camera.app calls to retrieve pixel/file data before saving.
// =========================================================================

%hook AVCapturePhotoOutput

- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings
                        delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    if (!settings || !delegate) return %orig;
    static NSMutableSet *hookedClasses;
    static dispatch_once_t photoOnce;
    dispatch_once(&photoOnce, ^{ hookedClasses = [NSMutableSet new]; });
    NSString *clsName = NSStringFromClass([delegate class]);
    @synchronized(hookedClasses) {
        if (![hookedClasses containsObject:clsName]) {
            [hookedClasses addObject:clsName];
            __block void (*origPhoto)(id, SEL, AVCapturePhotoOutput *,
                                      AVCapturePhoto *, NSError *) = nil;
            MSHookMessageEx(
                [delegate class],
                @selector(captureOutput:didFinishProcessingPhoto:error:),
                imp_implementationWithBlock(^(id blockSelf,
                                              AVCapturePhotoOutput *captureOutput,
                                              AVCapturePhoto *photo,
                                              NSError *error) {
                    DiCoyTweakManager *mgr = [DiCoyTweakManager sharedManager];
                    if (mgr.active) {
                        // Static slots updated on every capture; read by the
                        // AVCapturePhoto method hooks below.
                        static NSData          *sJpegData = nil;
                        static CVPixelBufferRef sInjPix   = nil;
                        static UIImage         *sUIImage  = nil;

                        // Build a synthetic origin buffer matching the photo's
                        // pixel format so _nextVideoFrameForOrigin: picks the
                        // right AVAssetReaderTrackOutput.
                        CVPixelBufferRef photoPixel = photo.pixelBuffer;
                        CMSampleBufferRef synthetic  = nil;
                        if (photoPixel) {
                            CMVideoFormatDescriptionRef fd = nil;
                            if (CMVideoFormatDescriptionCreateForImageBuffer(
                                    kCFAllocatorDefault, photoPixel, &fd) == noErr) {
                                CMSampleTimingInfo t = {kCMTimeInvalid, kCMTimeZero,
                                                        kCMTimeInvalid};
                                CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault,
                                    photoPixel, true, nil, nil, fd, &t, &synthetic);
                                CFRelease(fd);
                            }
                        }
                        CMSampleBufferRef injected = [mgr buildSampleBufferMatchingBuffer:synthetic];
                        if (synthetic) CFRelease(synthetic);

                        if (injected) {
                            CVImageBufferRef injPix = CMSampleBufferGetImageBuffer(injected);
                            if (injPix) {
                                // Swap static pixel buffer slot (CF-managed).
                                CVPixelBufferRef old = sInjPix;
                                sInjPix = (CVPixelBufferRef)CFRetain(injPix);
                                if (old) CFRelease(old);
                                // Build UIImage once; JPEG for fileDataRepresentation path,
                                // CGImage for CGImageRepresentation path (Camera.app).
                                CIImage  *ci = [CIImage imageWithCVImageBuffer:injPix];
                                UIImage  *ui = [UIImage imageWithCIImage:ci scale:1.0
                                                            orientation:UIImageOrientationUp];
                                sJpegData = UIImageJPEGRepresentation(ui, 0.95);
                                sUIImage  = ui;
                            }
                            CFRelease(injected);

                            // Hook AVCapturePhoto methods on the concrete class once.
                            static BOOL photoClassHooked = NO;
                            if (!photoClassHooked && sInjPix) {
                                photoClassHooked = YES;

                                __block NSData *(*origFDR)(id, SEL) = nil;
                                MSHookMessageEx([photo class],
                                    @selector(fileDataRepresentation),
                                    imp_implementationWithBlock(^NSData *(id s) {
                                        DiCoyTweakManager *m = [DiCoyTweakManager sharedManager];
                                        if (m.active && sJpegData) return sJpegData;
                                        return origFDR(s, @selector(fileDataRepresentation));
                                    }), (IMP *)&origFDR);

                                __block NSData *(*origFDRCust)(id, SEL, id) = nil;
                                MSHookMessageEx([photo class],
                                    @selector(fileDataRepresentationWithCustomizer:),
                                    imp_implementationWithBlock(^NSData *(id s, id c) {
                                        DiCoyTweakManager *m = [DiCoyTweakManager sharedManager];
                                        if (m.active && sJpegData) return sJpegData;
                                        return origFDRCust(s,
                                            @selector(fileDataRepresentationWithCustomizer:), c);
                                    }), (IMP *)&origFDRCust);

                                __block CVPixelBufferRef (*origPB)(id, SEL) = nil;
                                MSHookMessageEx([photo class],
                                    @selector(pixelBuffer),
                                    imp_implementationWithBlock(^CVPixelBufferRef(id s) {
                                        DiCoyTweakManager *m = [DiCoyTweakManager sharedManager];
                                        if (m.active && sInjPix) return sInjPix;
                                        return origPB(s, @selector(pixelBuffer));
                                    }), (IMP *)&origPB);

                                // Camera.app calls CGImageRepresentation rather than
                                // fileDataRepresentation when building its photo preview
                                // and for some photo-library save paths.
                                __block CGImageRef (*origCGImg)(id, SEL) = nil;
                                MSHookMessageEx([photo class],
                                    @selector(CGImageRepresentation),
                                    imp_implementationWithBlock(^CGImageRef(id s) {
                                        DiCoyTweakManager *m = [DiCoyTweakManager sharedManager];
                                        if (m.active && sUIImage) return [sUIImage CGImage];
                                        return origCGImg(s, @selector(CGImageRepresentation));
                                    }), (IMP *)&origCGImg);
                            }
                        }
                    }
                    origPhoto(blockSelf,
                              @selector(captureOutput:didFinishProcessingPhoto:error:),
                              captureOutput, photo, error);
                }),
                (IMP *)&origPhoto);
        }
    }
    %orig;
}

%end


%hook AVCaptureAudioDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureAudioDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    if (delegate && queue) dicoyHookDelegate([delegate class]);
    %orig;
}

%end


// =========================================================================
// AVCaptureMovieFileOutput hook — Camera.app records video through this output,
// which writes directly to a file via hardware encoders with no sample-buffer
// delegate.  We hook the recording-delegate completion and replace the raw
// .mov with a looped/trimmed version of the injected video before Camera.app
// hands the file to PHPhotoLibrary.
// =========================================================================

%hook AVCaptureMovieFileOutput

- (void)startRecordingToOutputFileURL:(NSURL *)outputFileURL
                    recordingDelegate:(id<AVCaptureFileOutputRecordingDelegate>)delegate {
    DiCoyTweakManager *mgr = [DiCoyTweakManager sharedManager];
    if (mgr.active && mgr.currentMode == kDicoyModeMediaInject && delegate) {
        mgr.recordingOutputURL  = outputFileURL;
        mgr.recordingStartTime  = CFAbsoluteTimeGetCurrent();

        static NSMutableSet   *hookedRecClasses;
        static dispatch_once_t recOnce;
        dispatch_once(&recOnce, ^{ hookedRecClasses = [NSMutableSet new]; });
        NSString *cls = NSStringFromClass([delegate class]);
        @synchronized(hookedRecClasses) {
            if (![hookedRecClasses containsObject:cls]) {
                [hookedRecClasses addObject:cls];
                __block void (*origRec)(id, SEL,
                                        AVCaptureFileOutput *,
                                        NSURL *,
                                        NSArray *,
                                        NSError *) = nil;
                MSHookMessageEx(
                    [delegate class],
                    @selector(fileOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:),
                    imp_implementationWithBlock(
                        ^(id bSelf,
                          AVCaptureFileOutput *output,
                          NSURL *url,
                          NSArray *connections,
                          NSError *error) {
                            DiCoyTweakManager *m = [DiCoyTweakManager sharedManager];
                            if (m.active && m.currentMode == kDicoyModeMediaInject && !error) {
                                NSTimeInterval dur = CFAbsoluteTimeGetCurrent() - m.recordingStartTime;
                                [m _replaceVideoAtURL:url duration:dur completion:^{
                                    origRec(bSelf,
                                            @selector(fileOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:),
                                            output, url, connections, nil);
                                }];
                            } else {
                                origRec(bSelf,
                                        @selector(fileOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:),
                                        output, url, connections, error);
                            }
                        }),
                    (IMP *)&origRec
                );
            }
        }
    }
    %orig;
}

%end


// Forward-declare the %new method so blocks that call [self _dicoyInstall]
// compile without -Wundeclared-selector errors.
@interface AVCaptureVideoPreviewLayer (DiCoyInstall)
- (void)_dicoyInstall;
@end

// AVCaptureVideoPreviewLayer hook — covers the native Camera app viewfinder and any
// other app that uses a preview layer rather than AVCaptureVideoDataOutput.
// Hooks initWithSession: and setSession: so the display layer is installed as soon
// as the preview layer is wired to a capture session, before startRunning fires.
%hook AVCaptureVideoPreviewLayer

%new
- (void)_dicoyInstall {
    if (objc_getAssociatedObject(self, kDiCoyDisplayLayerKey)) return;

    AVSampleBufferDisplayLayer *dl = [AVSampleBufferDisplayLayer new];
    dl.frame   = self.bounds;
    dl.opacity = 0.0f;
    [self addSublayer:dl];
    objc_setAssociatedObject(self, kDiCoyDisplayLayerKey, dl,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:self
                                                      selector:@selector(dicoyStep:)];
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    objc_setAssociatedObject(self, kDiCoyDisplayLinkKey, link,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (instancetype)initWithSession:(AVCaptureSession *)session {
    self = %orig;
    if (self) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self _dicoyInstall]; });
    }
    return self;
}

- (void)setSession:(AVCaptureSession *)session {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ [self _dicoyInstall]; });
}

- (void)setSessionWithNoConnection:(AVCaptureSession *)session {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ [self _dicoyInstall]; });
}

// layoutSublayers fires on the main thread every time the layer lays out —
// guaranteed to fire once the preview layer is in the view hierarchy, regardless
// of which session-attachment API the app used.
- (void)layoutSublayers {
    %orig;
    [self _dicoyInstall];
}

%new
- (void)dicoyStep:(CADisplayLink *)sender {
    DiCoyTweakManager *mgr = [DiCoyTweakManager sharedManager];
    AVSampleBufferDisplayLayer *dLayer =
        objc_getAssociatedObject(self, kDiCoyDisplayLayerKey);
    if (!dLayer) return;

    if (!mgr.active) {
        dLayer.opacity = 0.0f;
        return;
    }

    dLayer.frame = self.bounds;

    static CFTimeInterval lastRefresh = 0;
    CFTimeInterval now = sender.timestamp;
    if (now - lastRefresh < 1.0 / DICOY_TARGET_FPS) return;
    if (!dLayer.readyForMoreMediaData) return;
    lastRefresh = now;

    CMSampleBufferRef frame = [mgr buildSampleBufferMatchingBuffer:nil];
    if (frame) {
        dLayer.opacity = 1.0f;
        // Only flush when the layer has entered a failed state; otherwise
        // unconditional flush before every enqueue causes a blank frame on
        // each display-link tick and wastes a render cycle.
        if (dLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
            [dLayer flush];
        }
        [dLayer enqueueSampleBuffer:frame];
        CFRelease(frame);
    }
}

%end


// =========================================================================
// Mode-change notification + constructor
// =========================================================================

static void modeChangedCallback(CFNotificationCenterRef  center,
                                 void                    *observer,
                                 CFStringRef              name,
                                 const void              *object,
                                 CFDictionaryRef          userInfo) {
    DiCoyTweakManager *mgr = [DiCoyTweakManager sharedManager];
    NSDictionary *prefs =
        [NSDictionary dictionaryWithContentsOfFile:@DICOY_PREFS_PATH] ?: @{};
    NSString *mode = prefs[@"mode"] ?: @"off";
    // Always stop first so startMirroring can re-read the new prefs cleanly.
    if (mgr.active) [mgr stopMirroring];
    if (![mode isEqualToString:@"off"]) [mgr startMirroring];
}

%ctor {
    // One-shot: tells us which process loaded the tweak. Check via: cat /var/tmp/dicoy_proc.txt
    [[NSString stringWithFormat:@"%@", NSProcessInfo.processInfo.processName]
     writeToFile:@"/var/tmp/dicoy_proc.txt"
     atomically:YES encoding:NSUTF8StringEncoding error:nil];
    // Consume libSandy sandbox extensions before hooks register so that prefs
    // file access, socket connect, and IOSurfaceLookup are all unlocked by the
    // time any hook-initiated code runs.
    libSandy_applyProfile("DiCoy");

    %init;
    // Hook AudioUnitRender to intercept Voice Processing I/O mic input (WebRTC apps).
    MSHookFunction((void *)AudioUnitRender, (void *)dicoyAudioUnitRender,
                   (void **)&origAudioUnitRender);
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        modeChangedCallback,
        CFSTR(DICOY_NOTIFY_MODE_CHANGED),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
    // SpringBoard has the UI-session bootstrap port and Apple-signed entitlements
    // (com.apple.CARenderServer, IOSurfaceFamily) that the Background daemon lacked.
    if ([NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) {
        diCoyServerStart();
    }
}
