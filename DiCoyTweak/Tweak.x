// DiCoyTweak/Tweak.x
//
// Logos hooks that intercept AVFoundation's camera and microphone pipelines
// and substitute injected content sourced from DiCoyDaemon (screen mirror)
// or a local media file (media injection mode).
//
// Injection architecture overview:
//
//   App code calls:
//     [videoOutput setSampleBufferDelegate:realDelegate queue:q]
//
//   We intercept this and substitute our proxy:
//     [videoOutput setSampleBufferDelegate:DiCoyVideoProxy queue:q]
//
//   When the real camera fires a frame, AVFoundation calls:
//     [DiCoyVideoProxy captureOutput:output didOutputSampleBuffer:realBuf ...]
//
//   We build an injected CMSampleBufferRef from the latest IOSurface (screen
//   mirror) or from an AVAssetReader (media inject) and call the app's real
//   delegate with the injected buffer instead.
//
//   Audio injection (media inject mode): DiCoyAudioProxy reads audio samples
//   from the media file via AVAssetReader, converts to the session's LPCM
//   format (derived from the first real mic buffer), restamps to current
//   time, and delivers in place of the real microphone buffer.

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurfaceRef.h>
#import <QuartzCore/QuartzCore.h>
#import <AudioToolbox/AudioToolbox.h>
#import <os/lock.h>
#import <notify.h>
#import "DiCoyClient.h"
#import "DiCoyProtocol.h"

// =========================================================================
// DiCoyTweakManager (singleton)
//
// Owns the daemon connection, the most-recently received IOSurface (screen
// mirror path), and AVAssetReader instances (media inject path).
// All public entry points are thread-safe.
// =========================================================================

@interface DiCoyTweakManager : NSObject
+ (instancetype)sharedManager;
- (void)startMirroring;
- (void)stopMirroring;
// Builds a video CMSampleBufferRef. Screen mirror: IOSurface → CVPixelBuffer.
// Media inject: AVAssetReader → restamped copy. Caller must CFRelease.
- (CMSampleBufferRef)buildSampleBuffer CF_RETURNS_RETAINED;
// Reads the next audio chunk from the inject file, converting to match asbd.
// Lazily initialises the audio AVAssetReader on the first call.
// Returns NULL in screen mirror mode or if no file/track exists. Caller must CFRelease.
- (CMSampleBufferRef)nextAudioSampleBufferMatchingASBD:(const AudioStreamBasicDescription *)asbd CF_RETURNS_RETAINED;
// Initialises (or re-initialises) the audio AVAssetReader. Called from
// DiCoyAudioProxy on the first real mic callback once the ASBD is known.
- (void)setupAudioReaderForPath:(NSString *)path matchingASBD:(const AudioStreamBasicDescription *)asbd;

@property (nonatomic, strong)  DiCoyClient *client;
@property (nonatomic, assign)  IOSurfaceRef latestSurface; // protected by _surfaceLock
@property (nonatomic, assign)  uint16_t surfaceWidth;
@property (nonatomic, assign)  uint16_t surfaceHeight;
@property (nonatomic, assign)  BOOL active;
@property (nonatomic, assign)  DicoyMode currentMode;
@property (nonatomic, copy)    NSString *currentMediaPath;
@end

@implementation DiCoyTweakManager {
    os_unfair_lock _surfaceLock;
    os_unfair_lock _videoReaderLock;
    os_unfair_lock _audioReaderLock;
    AVAssetReader            *_videoReader;
    AVAssetReaderTrackOutput *_videoOutput;
    AVAssetReader            *_audioReader;
    AVAssetReaderTrackOutput *_audioOutput;
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
        _surfaceLock     = OS_UNFAIR_LOCK_INIT;
        _videoReaderLock = OS_UNFAIR_LOCK_INIT;
        _audioReaderLock = OS_UNFAIR_LOCK_INIT;
        _client = [DiCoyClient new];
        __weak typeof(self) weak = self;

        // Called on client's private read queue for each FRAME_READY from daemon.
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

    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:
        @DICOY_PREFS_PATH];
    NSString *mode = prefs[@"mode"] ?: @"off";
    if ([mode isEqualToString:@"off"]) return;

    self.active = YES;

    if ([mode isEqualToString:@"mediaInject"]) {
        self.currentMode      = kDicoyModeMediaInject;
        self.currentMediaPath = prefs[@"mediaFilePath"] ?: @"";
        [self setupVideoReaderForPath:self.currentMediaPath];
        // Audio reader is lazily initialised on the first mic callback once
        // the session's AudioStreamBasicDescription is known.
    } else {
        self.currentMode = kDicoyModeScreenMirror;
        if ([self.client connect]) {
            [self.client startCapture];
        }
    }
}

- (void)stopMirroring {
    if (!self.active) return;
    self.active      = NO;
    self.currentMode = kDicoyModeOff;

    [self.client stopCapture];
    [self.client disconnect];

    os_unfair_lock_lock(&_videoReaderLock);
    [_videoReader cancelReading];
    _videoReader = nil;
    _videoOutput = nil;
    os_unfair_lock_unlock(&_videoReaderLock);

    os_unfair_lock_lock(&_audioReaderLock);
    [_audioReader cancelReading];
    _audioReader = nil;
    _audioOutput = nil;
    os_unfair_lock_unlock(&_audioReaderLock);
}

// =========================================================================
// setupVideoReaderForPath:
//
// Creates an AVAssetReader that decodes video frames to 32BGRA, matching
// the IOSurface pixel format used in screen mirror mode so downstream
// AVFoundation processing sees the same format regardless of mode.
// =========================================================================

- (void)setupVideoReaderForPath:(NSString *)path {
    if (!path.length) return;
    NSURL *url            = [NSURL fileURLWithPath:path];
    AVURLAsset *asset     = [AVURLAsset URLAssetWithURL:url options:nil];
    AVAssetTrack *track   = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!track) return;

    NSError *err          = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
    if (!reader) return;

    NSDictionary *settings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
    };
    AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput
        assetReaderTrackOutputWithTrack:track outputSettings:settings];
    output.alwaysCopiesSampleData = NO;
    [reader addOutput:output];
    if (![reader startReading]) return;

    os_unfair_lock_lock(&_videoReaderLock);
    [_videoReader cancelReading];
    _videoReader = reader;
    _videoOutput = output;
    os_unfair_lock_unlock(&_videoReaderLock);
}

// =========================================================================
// setupAudioReaderForPath:matchingASBD:
//
// Creates an AVAssetReader that decodes audio to interleaved signed-integer
// LPCM at the sample rate and channel count of the real microphone buffer.
// Called lazily on the first mic callback so the session ASBD is known.
// =========================================================================

- (void)setupAudioReaderForPath:(NSString *)path
                   matchingASBD:(const AudioStreamBasicDescription *)asbd {
    if (!path.length) return;
    NSURL *url            = [NSURL fileURLWithPath:path];
    AVURLAsset *asset     = [AVURLAsset URLAssetWithURL:url options:nil];
    AVAssetTrack *track   = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    if (!track) return;

    NSError *err          = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
    if (!reader) return;

    Float64 sampleRate    = (asbd && asbd->mSampleRate > 0)     ? asbd->mSampleRate     : 44100.0;
    UInt32 channels       = (asbd && asbd->mChannelsPerFrame > 0) ? asbd->mChannelsPerFrame : 1;

    NSDictionary *settings = @{
        AVFormatIDKey:               @(kAudioFormatLinearPCM),
        AVSampleRateKey:             @(sampleRate),
        AVNumberOfChannelsKey:       @(channels),
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

// =========================================================================
// nextVideoSampleBuffer
//
// Copies the next decoded BGRA video frame from the AVAssetReader, loops
// the file on EOF, and restamps the PTS to CACurrentMediaTime() so
// AVFoundation sees a monotonically-advancing live timestamp.
// =========================================================================

- (CMSampleBufferRef)nextVideoSampleBuffer {
    os_unfair_lock_lock(&_videoReaderLock);
    CMSampleBufferRef buf = nil;
    if (_videoReader && _videoReader.status == AVAssetReaderStatusReading) {
        buf = [_videoOutput copyNextSampleBuffer];
    }
    os_unfair_lock_unlock(&_videoReaderLock);

    if (!buf) {
        // EOF, error, or reader not yet created — loop/reset.
        NSString *path = self.currentMediaPath;
        if (!path.length) return NULL;
        [self setupVideoReaderForPath:path];
        os_unfair_lock_lock(&_videoReaderLock);
        if (_videoReader && _videoReader.status == AVAssetReaderStatusReading) {
            buf = [_videoOutput copyNextSampleBuffer];
        }
        os_unfair_lock_unlock(&_videoReaderLock);
        if (!buf) return NULL;
    }

    CMTime duration = CMSampleBufferGetDuration(buf);
    if (!CMTIME_IS_VALID(duration) || CMTIME_IS_INDEFINITE(duration)) {
        duration = CMTimeMake(1, 30); // fallback: 30 FPS
    }
    CMSampleTimingInfo timing = {
        .duration              = duration,
        .presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000),
        .decodeTimeStamp       = kCMTimeInvalid,
    };
    CMSampleBufferRef restamped = NULL;
    CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, buf, 1, &timing, &restamped);
    CFRelease(buf);
    return restamped; // NULL on copy failure; caller CFRelease otherwise
}

// =========================================================================
// nextAudioSampleBufferMatchingASBD:
//
// Reads the next LPCM chunk from the inject file. Lazily initialises the
// reader on the first call (needs ASBD to configure output format). Loops
// on EOF. Restamps PTS to match the camera clock.
// =========================================================================

- (CMSampleBufferRef)nextAudioSampleBufferMatchingASBD:(const AudioStreamBasicDescription *)asbd {
    os_unfair_lock_lock(&_audioReaderLock);
    BOOL needsSetup = (_audioReader == nil);
    CMSampleBufferRef buf = nil;
    if (!needsSetup && _audioReader.status == AVAssetReaderStatusReading) {
        buf = [_audioOutput copyNextSampleBuffer];
    }
    os_unfair_lock_unlock(&_audioReaderLock);

    if (needsSetup || !buf) {
        // Lazy init or EOF — set up / reset the reader.
        NSString *path = self.currentMediaPath;
        if (!path.length) return NULL;
        [self setupAudioReaderForPath:path matchingASBD:asbd];
        os_unfair_lock_lock(&_audioReaderLock);
        if (_audioReader && _audioReader.status == AVAssetReaderStatusReading) {
            buf = [_audioOutput copyNextSampleBuffer];
        }
        os_unfair_lock_unlock(&_audioReaderLock);
        if (!buf) return NULL;
    }

    CMTime duration = CMSampleBufferGetDuration(buf);
    if (!CMTIME_IS_VALID(duration) || CMTIME_IS_INDEFINITE(duration)) {
        duration = kCMTimeZero;
    }
    CMSampleTimingInfo timing = {
        .duration              = duration,
        .presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000),
        .decodeTimeStamp       = kCMTimeInvalid,
    };
    CMSampleBufferRef restamped = NULL;
    CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, buf, 1, &timing, &restamped);
    CFRelease(buf);
    return restamped;
}

// =========================================================================
// buildSampleBuffer
//
// Screen mirror: IOSurface → CVPixelBuffer → CMSampleBuffer (zero-copy IPC).
// Media inject: delegates to nextVideoSampleBuffer (AVAssetReader, looping).
// =========================================================================

- (CMSampleBufferRef)buildSampleBuffer {
    if (!self.active) return NULL;

    if (self.currentMode == kDicoyModeMediaInject) {
        return [self nextVideoSampleBuffer];
    }

    // --- Screen mirror path ---
    os_unfair_lock_lock(&_surfaceLock);
    IOSurfaceRef surface = self.latestSurface;
    uint16_t w = self.surfaceWidth;
    uint16_t h = self.surfaceHeight;
    if (surface) CFRetain(surface);
    os_unfair_lock_unlock(&_surfaceLock);

    if (!surface) return NULL;

    NSDictionary *pbAttrs = @{
        (id)kCVPixelBufferWidthKey:               @(w),
        (id)kCVPixelBufferHeightKey:              @(h),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferRef pixBuf = NULL;
    CVReturn cvRet = CVPixelBufferCreateWithIOSurface(
        kCFAllocatorDefault, surface,
        (__bridge CFDictionaryRef)pbAttrs, &pixBuf
    );
    CFRelease(surface);
    if (cvRet != kCVReturnSuccess || !pixBuf) return NULL;

    CMVideoFormatDescriptionRef fmtDesc = NULL;
    OSStatus fmtErr = CMVideoFormatDescriptionCreateForImageBuffer(
        kCFAllocatorDefault, pixBuf, &fmtDesc
    );
    if (fmtErr != noErr || !fmtDesc) {
        CVPixelBufferRelease(pixBuf);
        return NULL;
    }

    CMSampleTimingInfo timing = {
        .duration              = CMTimeMake(1, DICOY_TARGET_FPS),
        .presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000),
        .decodeTimeStamp       = kCMTimeInvalid,
    };

    CMSampleBufferRef sampleBuf = NULL;
    CMSampleBufferCreateForImageBuffer(
        kCFAllocatorDefault, pixBuf, true, NULL, NULL,
        fmtDesc, &timing, &sampleBuf
    );

    CFRelease(fmtDesc);
    CVPixelBufferRelease(pixBuf);
    return sampleBuf;
}

@end

// =========================================================================
// DiCoyVideoProxy
//
// Drop-in replacement for the app's AVCaptureVideoDataOutputSampleBufferDelegate.
// Injects our synthesised buffer; falls through to the real camera buffer
// when DiCoy is inactive or no frame has arrived yet.
// =========================================================================

@interface DiCoyVideoProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> realDelegate;
@end

@implementation DiCoyVideoProxy

- (void)captureOutput:(AVCaptureOutput *)output
  didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
         fromConnection:(AVCaptureConnection *)connection {

    CMSampleBufferRef injected = [[DiCoyTweakManager sharedManager] buildSampleBuffer];
    if (injected) {
        [self.realDelegate captureOutput:output
                   didOutputSampleBuffer:injected
                          fromConnection:connection];
        CFRelease(injected);
    } else {
        [self.realDelegate captureOutput:output
                   didOutputSampleBuffer:sampleBuffer
                          fromConnection:connection];
    }
}

- (void)captureOutput:(AVCaptureOutput *)output
  didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    if ([self.realDelegate respondsToSelector:_cmd]) {
        [self.realDelegate captureOutput:output
                     didDropSampleBuffer:sampleBuffer
                          fromConnection:connection];
    }
}

- (BOOL)respondsToSelector:(SEL)sel {
    return [self.realDelegate respondsToSelector:sel] || [super respondsToSelector:sel];
}
- (id)forwardingTargetForSelector:(SEL)sel {
    return self.realDelegate;
}

@end

// =========================================================================
// DiCoyAudioProxy
//
// Screen mirror mode: pass-through. System audio capture would require a
// separate AudioServicesCreateRecordingAudioTap daemon-side implementation.
//
// Media inject mode: reads audio from the inject file via AVAssetReader,
// converts to interleaved 16-bit LPCM at the session's sample rate and
// channel count (derived from the first real mic buffer), restamps to
// current time, and delivers instead of the mic buffer.
// =========================================================================

@interface DiCoyAudioProxy : NSObject <AVCaptureAudioDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id<AVCaptureAudioDataOutputSampleBufferDelegate> realDelegate;
@end

@implementation DiCoyAudioProxy

- (void)captureOutput:(AVCaptureOutput *)output
  didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
         fromConnection:(AVCaptureConnection *)connection {

    DiCoyTweakManager *mgr = [DiCoyTweakManager sharedManager];
    if (mgr.active && mgr.currentMode == kDicoyModeMediaInject) {
        CMAudioFormatDescriptionRef fmtDesc =
            (CMAudioFormatDescriptionRef)CMSampleBufferGetFormatDescription(sampleBuffer);
        const AudioStreamBasicDescription *asbd =
            CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc);

        CMSampleBufferRef injected = [mgr nextAudioSampleBufferMatchingASBD:asbd];
        if (injected) {
            [self.realDelegate captureOutput:output
                       didOutputSampleBuffer:injected
                              fromConnection:connection];
            CFRelease(injected);
            return;
        }
    }

    // Screen mirror mode or no injected audio available — pass through mic.
    [self.realDelegate captureOutput:output
               didOutputSampleBuffer:sampleBuffer
                      fromConnection:connection];
}

- (BOOL)respondsToSelector:(SEL)sel {
    return [self.realDelegate respondsToSelector:sel] || [super respondsToSelector:sel];
}
- (id)forwardingTargetForSelector:(SEL)sel { return self.realDelegate; }

@end

// =========================================================================
// Logos hooks
// =========================================================================

%hook AVCaptureSession

- (void)startRunning {
    %orig;
    [[DiCoyTweakManager sharedManager] startMirroring];
}

- (void)stopRunning {
    [[DiCoyTweakManager sharedManager] stopMirroring];
    %orig;
}

%end

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    if (delegate && ![delegate isKindOfClass:%c(DiCoyVideoProxy)]) {
        DiCoyVideoProxy *proxy = [DiCoyVideoProxy new];
        proxy.realDelegate = delegate;
        %orig(proxy, queue);
    } else {
        %orig;
    }
}

%end

%hook AVCaptureAudioDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureAudioDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    if (delegate && ![delegate isKindOfClass:%c(DiCoyAudioProxy)]) {
        DiCoyAudioProxy *proxy = [DiCoyAudioProxy new];
        proxy.realDelegate = delegate;
        %orig(proxy, queue);
    } else {
        %orig;
    }
}

%end

// =========================================================================
// %ctor
// =========================================================================

static void modeChangedCallback(CFNotificationCenterRef center, void *observer,
                                 CFStringRef name, const void *object,
                                 CFDictionaryRef userInfo) {
    DiCoyTweakManager *mgr = [DiCoyTweakManager sharedManager];
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:
        @DICOY_PREFS_PATH];
    NSString *mode = prefs[@"mode"] ?: @"off";

    if ([mode isEqualToString:@"off"]) {
        if (mgr.active) [mgr stopMirroring];
    } else if (mgr.active) {
        // Mode switched between screenMirror and mediaInject while a session
        // is live — restart so the new source takes effect immediately.
        [mgr stopMirroring];
        [mgr startMirroring];
    }
    // If no session is running (mgr.active == NO), startMirroring fires
    // naturally on the next AVCaptureSession -startRunning.
}

%ctor {
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        modeChangedCallback,
        CFSTR(DICOY_NOTIFY_MODE_CHANGED),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
}
