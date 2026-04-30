// DiCoyTweak/Tweak.x

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurfaceRef.h>
#import <QuartzCore/QuartzCore.h>
#import <AudioToolbox/AudioToolbox.h>
#import <os/lock.h>
#import <objc/runtime.h>
#import "DiCoyClient.h"
#import "DiCoyProtocol.h"

static const void *kDiCoyDisplayLayerKey = &kDiCoyDisplayLayerKey;

// =========================================================================
// DiCoyTweakManager
// =========================================================================

@interface DiCoyTweakManager : NSObject
+ (instancetype)sharedManager;
- (void)startMirroring;
- (void)stopMirroring;
- (CMSampleBufferRef)buildSampleBufferMatchingBuffer:(CMSampleBufferRef)origin CF_RETURNS_RETAINED;
- (CMSampleBufferRef)nextAudioSampleBufferMatchingASBD:(const AudioStreamBasicDescription *)asbd CF_RETURNS_RETAINED;
@property (nonatomic, strong)  DiCoyClient *client;
@property (nonatomic, assign)  IOSurfaceRef latestSurface;
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
    AVAssetReaderTrackOutput *_videoOut_BGRA;
    AVAssetReaderTrackOutput *_videoOut_YUVvr;  // kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    AVAssetReaderTrackOutput *_videoOut_YUVfr;  // kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
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
    // Step 3a: prove startMirroring is entered — fixed string, no nil dependency.
    [@"startMirroring entered" writeToFile:@"/var/tmp/dicoy_start.txt"
     atomically:YES encoding:NSUTF8StringEncoding error:nil];
    // Step 3b: read prefs and report success or sandbox error.
    NSError *_prefsErr = nil;
    NSString *_rawPrefs = [NSString stringWithContentsOfFile:@DICOY_PREFS_PATH
                                                   encoding:NSUTF8StringEncoding error:&_prefsErr];
    [(_rawPrefs ?: [NSString stringWithFormat:@"READ FAILED: %@", _prefsErr])
     writeToFile:@"/var/tmp/dicoy_prefs.txt"
     atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if (self.active) return;
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@DICOY_PREFS_PATH] ?: @{};
    NSString *mode = prefs[@"mode"] ?: @"off";
    if ([mode isEqualToString:@"off"]) return;
    self.active = YES;
    if ([mode isEqualToString:@"mediaInject"]) {
        self.currentMode      = kDicoyModeMediaInject;
        self.currentMediaPath = prefs[@"mediaFilePath"] ?: @"";
        [self _setupVideoReaderForPath:self.currentMediaPath];
    } else {
        self.currentMode = kDicoyModeScreenMirror;
        if ([self.client connect]) [self.client startCapture];
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
    _videoReader    = nil;
    _videoOut_BGRA  = nil;
    _videoOut_YUVvr = nil;
    _videoOut_YUVfr = nil;
    os_unfair_lock_unlock(&_videoReaderLock);
    os_unfair_lock_lock(&_audioReaderLock);
    [_audioReader cancelReading];
    _audioReader = nil;
    _audioOutput = nil;
    os_unfair_lock_unlock(&_audioReaderLock);
}

- (void)_setupVideoReaderForPath:(NSString *)path {
    if (!path.length) return;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!track) return;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
    if (!reader) return;

    // Three outputs — one per pixel format so we can match whatever the app expects.
    AVAssetReaderTrackOutput *outBGRA = [AVAssetReaderTrackOutput
        assetReaderTrackOutputWithTrack:track
        outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:
                         @(kCVPixelFormatType_32BGRA)}];
    outBGRA.alwaysCopiesSampleData = NO;

    AVAssetReaderTrackOutput *outYUVvr = [AVAssetReaderTrackOutput
        assetReaderTrackOutputWithTrack:track
        outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:
                         @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)}];
    outYUVvr.alwaysCopiesSampleData = NO;

    AVAssetReaderTrackOutput *outYUVfr = [AVAssetReaderTrackOutput
        assetReaderTrackOutputWithTrack:track
        outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:
                         @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)}];
    outYUVfr.alwaysCopiesSampleData = NO;

    [reader addOutput:outBGRA];
    [reader addOutput:outYUVvr];
    [reader addOutput:outYUVfr];
    if (![reader startReading]) return;

    os_unfair_lock_lock(&_videoReaderLock);
    [_videoReader cancelReading];
    _videoReader    = reader;
    _videoOut_BGRA  = outBGRA;
    _videoOut_YUVvr = outYUVvr;
    _videoOut_YUVfr = outYUVfr;
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

// Must be called while holding _videoReaderLock.
- (AVAssetReaderTrackOutput *)_outputForSubtype:(OSType)sub {
    switch (sub) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return _videoOut_YUVvr;
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:  return _videoOut_YUVfr;
        default:                                               return _videoOut_BGRA;
    }
}

// Drain one frame from every output except `keep` so the AVAssetReader doesn't stall.
// Must be called while holding _videoReaderLock.
- (void)_drainOthersExcept:(AVAssetReaderTrackOutput *)keep {
    for (AVAssetReaderTrackOutput *o in @[_videoOut_BGRA, _videoOut_YUVvr, _videoOut_YUVfr]) {
        if (o && o != keep) {
            CMSampleBufferRef b = [o copyNextSampleBuffer];
            if (b) CFRelease(b);
        }
    }
}

// origin: real incoming sample buffer whose pixel format we match. Pass nil for the
// AVSampleBufferDisplayLayer path (defaults to BGRA, which the display layer accepts).
- (CMSampleBufferRef)buildSampleBufferMatchingBuffer:(CMSampleBufferRef)origin {
    // Step 5: prove this method is reached.
    [@"buildSampleBuffer called" writeToFile:@"/var/tmp/dicoy_build.txt"
     atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if (!self.active) return NULL;

    if (self.currentMode == kDicoyModeMediaInject) {
        return [self _nextVideoFrameForOrigin:origin];
    }

    // Screen mirror — wrap the latest IOSurface from the daemon.
    os_unfair_lock_lock(&_surfaceLock);
    IOSurfaceRef surface = self.latestSurface;
    uint16_t w = self.surfaceWidth, h = self.surfaceHeight;
    if (surface) CFRetain(surface);
    os_unfair_lock_unlock(&_surfaceLock);
    if (!surface) return NULL;

    NSDictionary *pbAttrs = @{
        (id)kCVPixelBufferWidthKey:               @(w),
        (id)kCVPixelBufferHeightKey:              @(h),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferRef pix = NULL;
    CVReturn cvr = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface,
                                                     (__bridge CFDictionaryRef)pbAttrs, &pix);
    CFRelease(surface);
    if (cvr != kCVReturnSuccess || !pix) return NULL;

    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pix, &fmt) != noErr) {
        CVPixelBufferRelease(pix); return NULL;
    }
    CMSampleTimingInfo timing = {
        .duration              = CMTimeMake(1, DICOY_TARGET_FPS),
        .presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000),
        .decodeTimeStamp       = kCMTimeInvalid,
    };
    CMSampleBufferRef sb = NULL;
    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pix, true, NULL, NULL, fmt, &timing, &sb);
    CFRelease(fmt);
    CVPixelBufferRelease(pix);
    return sb;
}

- (CMSampleBufferRef)_nextVideoFrameForOrigin:(CMSampleBufferRef)origin {
    // Derive pixel format from the incoming buffer (nil → BGRA for display layer).
    OSType sub = kCVPixelFormatType_32BGRA;
    if (origin) {
        CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(origin);
        if (fd) sub = CMFormatDescriptionGetMediaSubType(fd);
    }

    os_unfair_lock_lock(&_videoReaderLock);
    BOOL ok = _videoReader && _videoReader.status == AVAssetReaderStatusReading;
    AVAssetReaderTrackOutput *sel = ok ? [self _outputForSubtype:sub] : nil;
    CMSampleBufferRef fileBuf = sel ? [sel copyNextSampleBuffer] : nil;
    if (ok && fileBuf) [self _drainOthersExcept:sel];
    os_unfair_lock_unlock(&_videoReaderLock);

    if (!fileBuf) {
        // EOF or reader not yet initialised — restart the reader and retry once.
        NSString *path = self.currentMediaPath;
        if (!path.length) return NULL;
        [self _setupVideoReaderForPath:path];
        os_unfair_lock_lock(&_videoReaderLock);
        ok = _videoReader && _videoReader.status == AVAssetReaderStatusReading;
        sel = ok ? [self _outputForSubtype:sub] : nil;
        fileBuf = sel ? [sel copyNextSampleBuffer] : nil;
        if (ok && fileBuf) [self _drainOthersExcept:sel];
        os_unfair_lock_unlock(&_videoReaderLock);
        if (!fileBuf) return NULL;
    }

    // Build timing: mirror the origin buffer's PTS so apps don't reject the frame.
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
    CMVideoFormatDescriptionRef fmt = NULL;
    CMSampleBufferRef result = NULL;
    if (pix && CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pix, &fmt) == noErr) {
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pix, true, NULL, NULL,
                                           fmt, &timing, &result);
        CFRelease(fmt);
        // Propagate EXIF/TIFF so still-photo captures look authentic.
        if (result && origin) {
            CFDictionaryRef exif = CMGetAttachment(origin, CFSTR("{Exif}"), NULL);
            CFDictionaryRef tiff = CMGetAttachment(origin, CFSTR("{TIFF}"), NULL);
            if (exif) CMSetAttachment(result, CFSTR("{Exif}"), exif, kCMAttachmentMode_ShouldPropagate);
            if (tiff) CMSetAttachment(result, CFSTR("{TIFF}"), tiff, kCMAttachmentMode_ShouldPropagate);
        }
    }
    CFRelease(fileBuf);
    return result;
}

- (CMSampleBufferRef)nextAudioSampleBufferMatchingASBD:(const AudioStreamBasicDescription *)asbd {
    os_unfair_lock_lock(&_audioReaderLock);
    BOOL needsSetup = (_audioReader == nil);
    CMSampleBufferRef buf = nil;
    if (!needsSetup && _audioReader.status == AVAssetReaderStatusReading) {
        buf = [_audioOutput copyNextSampleBuffer];
    }
    os_unfair_lock_unlock(&_audioReaderLock);

    if (needsSetup || !buf) {
        NSString *path = self.currentMediaPath;
        if (!path.length) return NULL;
        [self _setupAudioReaderForPath:path matchingASBD:asbd];
        os_unfair_lock_lock(&_audioReaderLock);
        if (_audioReader && _audioReader.status == AVAssetReaderStatusReading) {
            buf = [_audioOutput copyNextSampleBuffer];
        }
        os_unfair_lock_unlock(&_audioReaderLock);
        if (!buf) return NULL;
    }

    CMTime dur = CMSampleBufferGetDuration(buf);
    if (!CMTIME_IS_VALID(dur) || CMTIME_IS_INDEFINITE(dur)) dur = kCMTimeZero;
    CMSampleTimingInfo timing = {
        .duration              = dur,
        .presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000),
        .decodeTimeStamp       = kCMTimeInvalid,
    };
    CMSampleBufferRef restamped = NULL;
    CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, buf, 1, &timing, &restamped);
    CFRelease(buf);
    return restamped;
}

@end


// =========================================================================
// Logos hooks
// =========================================================================

%hook AVCaptureSession

- (void)startRunning {
    // Step 2: prove AVCaptureSession -startRunning hook fires.
    [@"startRunning fired" writeToFile:@"/var/tmp/dicoy_session.txt"
     atomically:YES encoding:NSUTF8StringEncoding error:nil];
    %orig;
    [[DiCoyTweakManager sharedManager] startMirroring];
}

- (void)stopRunning {
    [[DiCoyTweakManager sharedManager] stopMirroring];
    %orig;
}

%end


// Hook the VIDEO delegate's sample buffer method directly via MSHookMessageEx,
// matching what VCAM does. Avoids the proxy-object approach and its edge cases.
%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    if (delegate && queue) {
        static NSMutableSet *hookedClasses;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ hookedClasses = [NSMutableSet new]; });

        NSString *clsName = NSStringFromClass([delegate class]);
        @synchronized(hookedClasses) {
            if (![hookedClasses containsObject:clsName]) {
                [hookedClasses addObject:clsName];
                __block void (*origIMP)(id, SEL, AVCaptureOutput *,
                                        CMSampleBufferRef,
                                        AVCaptureConnection *) = nil;
                MSHookMessageEx(
                    [delegate class],
                    @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
                    imp_implementationWithBlock(
                        ^(id self,
                          AVCaptureOutput *output,
                          CMSampleBufferRef sampleBuffer,
                          AVCaptureConnection *connection) {
                            CMSampleBufferRef injected =
                                [[DiCoyTweakManager sharedManager]
                                 buildSampleBufferMatchingBuffer:sampleBuffer];
                            origIMP(self,
                                    @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
                                    output,
                                    injected ?: sampleBuffer,
                                    connection);
                            if (injected) CFRelease(injected);
                        }),
                    (IMP *)&origIMP
                );
            }
        }
    }
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
                        static NSData       *sJpegData = nil;
                        static CVPixelBufferRef sInjPix = nil;

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
                                // Build JPEG for file-data path.
                                CIImage  *ci = [CIImage imageWithCVImageBuffer:injPix];
                                UIImage  *ui = [UIImage imageWithCIImage:ci scale:1.0
                                                            orientation:UIImageOrientationUp];
                                sJpegData = UIImageJPEGRepresentation(ui, 0.95);
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


// Same pattern for the AUDIO delegate.
%hook AVCaptureAudioDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureAudioDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    if (delegate && queue) {
        static NSMutableSet *hookedClasses;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ hookedClasses = [NSMutableSet new]; });

        NSString *clsName = NSStringFromClass([delegate class]);
        @synchronized(hookedClasses) {
            if (![hookedClasses containsObject:clsName]) {
                [hookedClasses addObject:clsName];
                __block void (*origIMP)(id, SEL, AVCaptureOutput *,
                                        CMSampleBufferRef,
                                        AVCaptureConnection *) = nil;
                MSHookMessageEx(
                    [delegate class],
                    @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
                    imp_implementationWithBlock(
                        ^(id self,
                          AVCaptureOutput *output,
                          CMSampleBufferRef sampleBuffer,
                          AVCaptureConnection *connection) {
                            DiCoyTweakManager *mgr = [DiCoyTweakManager sharedManager];
                            if (mgr.active && mgr.currentMode == kDicoyModeMediaInject) {
                                CMFormatDescriptionRef fd =
                                    CMSampleBufferGetFormatDescription(sampleBuffer);
                                const AudioStreamBasicDescription *asbd =
                                    CMAudioFormatDescriptionGetStreamBasicDescription(
                                        (CMAudioFormatDescriptionRef)fd);
                                CMSampleBufferRef injected =
                                    [mgr nextAudioSampleBufferMatchingASBD:asbd];
                                if (injected) {
                                    origIMP(self,
                                            @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
                                            output, injected, connection);
                                    CFRelease(injected);
                                    return;
                                }
                            }
                            origIMP(self,
                                    @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
                                    output, sampleBuffer, connection);
                        }),
                    (IMP *)&origIMP
                );
            }
        }
    }
    %orig;
}

%end


// AVCaptureVideoPreviewLayer hook — covers the native Camera app viewfinder and any
// other app that uses a preview layer rather than AVCaptureVideoDataOutput.
// Injects an AVSampleBufferDisplayLayer overlay driven by a CADisplayLink.
%hook AVCaptureVideoPreviewLayer

- (void)addSublayer:(CALayer *)layer {
    // Step 4: prove AVCaptureVideoPreviewLayer -addSublayer: fires.
    [@"addSublayer fired" writeToFile:@"/var/tmp/dicoy_previewlayer.txt"
     atomically:YES encoding:NSUTF8StringEncoding error:nil];
    %orig;
    // Only set up once per preview layer instance.
    if (objc_getAssociatedObject(self, kDiCoyDisplayLayerKey)) return;

    AVSampleBufferDisplayLayer *displayLayer = [AVSampleBufferDisplayLayer new];
    // Start invisible — opacity is raised to 1.0 only when a real frame is
    // successfully enqueued. No mask layer: without content the display layer
    // is fully transparent, so the real camera preview shows through unobstructed.
    displayLayer.opacity = 0.0f;
    [self insertSublayer:displayLayer above:layer];

    objc_setAssociatedObject(self, kDiCoyDisplayLayerKey, displayLayer,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    dispatch_async(dispatch_get_main_queue(), ^{
        displayLayer.frame = self.bounds;
    });

    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:self
                                                      selector:@selector(dicoyStep:)];
    [link addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
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
    CFTimeInterval now = CACurrentMediaTime();
    if (now - lastRefresh < 1.0 / DICOY_TARGET_FPS) return;
    if (!dLayer.readyForMoreMediaData) return;
    lastRefresh = now;

    CMSampleBufferRef frame = [mgr buildSampleBufferMatchingBuffer:nil];
    if (frame) {
        dLayer.opacity = 1.0f;
        [dLayer flush];
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
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@DICOY_PREFS_PATH] ?: @{};
    NSString *mode = prefs[@"mode"] ?: @"off";
    // Always stop first so startMirroring can re-read the new prefs cleanly.
    if (mgr.active) [mgr stopMirroring];
    if (![mode isEqualToString:@"off"]) [mgr startMirroring];
}

%ctor {
    // Step 1: prove the dylib loads and which process it's in.
    // /var/tmp is world-writable and accessible from sandboxed processes on jailbroken devices.
    [[NSString stringWithFormat:@"%@ loaded", [NSProcessInfo processInfo].processName]
     writeToFile:@"/var/tmp/dicoy_load.txt"
     atomically:YES encoding:NSUTF8StringEncoding error:nil];
    %init;
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        modeChangedCallback,
        CFSTR(DICOY_NOTIFY_MODE_CHANGED),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
}
