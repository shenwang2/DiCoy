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
#import <libSandy.h>

static const void *kDiCoyDisplayLayerKey = &kDiCoyDisplayLayerKey;
static const void *kDiCoyDisplayLinkKey  = &kDiCoyDisplayLinkKey;

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
    AVAssetReaderTrackOutput *_videoOutput;
    OSType                    _videoFormat;
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
    if (self.active) return;
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@DICOY_PREFS_PATH] ?: @{};
    NSString *mode = prefs[@"mode"] ?: @"off";
    if ([mode isEqualToString:@"off"]) return;
    self.active = YES;
    if ([mode isEqualToString:@"mediaInject"]) {
        self.currentMode      = kDicoyModeMediaInject;
        self.currentMediaPath = prefs[@"mediaFilePath"] ?: @"";
        [self _setupVideoReaderForPath:self.currentMediaPath
                           pixelFormat:kCVPixelFormatType_32BGRA];
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
    _videoReader  = nil;
    _videoOutput  = nil;
    _videoFormat  = 0;
    os_unfair_lock_unlock(&_videoReaderLock);
    os_unfair_lock_lock(&_audioReaderLock);
    [_audioReader cancelReading];
    _audioReader = nil;
    _audioOutput = nil;
    os_unfair_lock_unlock(&_audioReaderLock);
}

// One reader, one output, one pixel format. AVAssetReader forbids multiple
// outputs for the same track. Format is detected from the first real incoming
// frame and the reader is recreated if it changes (e.g. between sessions).
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
    // Derive pixel format from the real incoming buffer (nil → BGRA for display layer).
    OSType sub = kCVPixelFormatType_32BGRA;
    if (origin) {
        CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(origin);
        if (fd) sub = CMFormatDescriptionGetMediaSubType(fd);
    }

    // Fast path: reader exists, format matches, not at EOF.
    os_unfair_lock_lock(&_videoReaderLock);
    BOOL ok = _videoReader
           && (_videoReader.status == AVAssetReaderStatusReading)
           && (_videoFormat == sub);
    CMSampleBufferRef fileBuf = ok ? [_videoOutput copyNextSampleBuffer] : nil;
    os_unfair_lock_unlock(&_videoReaderLock);

    if (!fileBuf) {
        // EOF, wrong format, or not yet initialised — recreate with the correct format.
        NSString *path = self.currentMediaPath;
        if (!path.length) return NULL;
        [self _setupVideoReaderForPath:path pixelFormat:sub];
        os_unfair_lock_lock(&_videoReaderLock);
        ok = _videoReader && (_videoReader.status == AVAssetReaderStatusReading);
        fileBuf = ok ? [_videoOutput copyNextSampleBuffer] : nil;
        os_unfair_lock_unlock(&_videoReaderLock);
        if (!fileBuf) return NULL;
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
    CMVideoFormatDescriptionRef fmt = NULL;
    CMSampleBufferRef result = NULL;
    if (pix && CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pix, &fmt) == noErr) {
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pix, true, NULL, NULL,
                                           fmt, &timing, &result);
        CFRelease(fmt);
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
    // Consume libSandy sandbox extensions before hooks register so that prefs
    // file access, socket connect, and IOSurfaceLookup are all unlocked by the
    // time any hook-initiated code runs.
    libSandy_applyProfile("DiCoy");

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
