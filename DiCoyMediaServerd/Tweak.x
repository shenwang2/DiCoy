#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <substrate.h>
#import <os/log.h>

static os_log_t gMediaLog;

// This is the private CoreMedia function mediaserverd uses to send frames 
// to app processes (Safari, Camera App, etc.)
void (*orig_FigCaptureRemoteQueueEnqueue)(void *queue, CMSampleBufferRef sampleBuffer);

void hook_FigCaptureRemoteQueueEnqueue(void *queue, CMSampleBufferRef sampleBuffer) {
    if (!sampleBuffer) {
        orig_FigCaptureRemoteQueueEnqueue(queue, sampleBuffer);
        return;
    }

    // 1. Check if DiCoy is active via your preference file
    // 2. If active, pull the next frame from your AVAssetReader (or Ring Buffer for audio)
    // 3. Restamp the PTS of your injected frame to match the original sampleBuffer
    // 4. Send the INJECTED buffer down the queue instead of the real one:
    
    /* CMSampleBufferRef injectedBuffer = [DiCoyManager getNextInjectedFrameMatching:sampleBuffer];
    if (injectedBuffer) {
        orig_FigCaptureRemoteQueueEnqueue(queue, injectedBuffer);
        CFRelease(injectedBuffer);
        return;
    }
    */

    // Fallback to real camera
    orig_FigCaptureRemoteQueueEnqueue(queue, sampleBuffer);
}

%ctor {
    gMediaLog = os_log_create("com.dicoy.mediaserverd", "tweak");
    os_log(gMediaLog, "DiCoy loaded into mediaserverd!");

    // Dynamically resolve the private FigCapture symbol
    void *figCaptureLib = dlopen("/System/Library/PrivateFrameworks/CMCapture.framework/CMCapture", RTLD_NOW);
    if (figCaptureLib) {
        void *symbol = dlsym(figCaptureLib, "FigCaptureRemoteQueueEnqueue");
        if (symbol) {
            MSHookFunction(symbol, (void *)hook_FigCaptureRemoteQueueEnqueue, (void **)&orig_FigCaptureRemoteQueueEnqueue);
            os_log(gMediaLog, "Successfully hooked FigCaptureRemoteQueueEnqueue");
        }
    }
}