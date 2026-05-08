// DiCoyTweak/DiCoyServer.m
//
// Screen-capture server running inside SpringBoard via tweak injection.
//
// Socket: /var/tmp/dicoy.sock — sticky 1777 so mobile (SpringBoard) can bind
// and sandboxed apps can connect after libSandy applies the DiCoy profile.
//
// IOMobileFramebufferGetLayerDefaultSurface may return kIOReturnError during
// early SpringBoard startup (display not yet fully initialized). The capture
// loop never exits — it retries and logs every 30 failures so the log shows
// whether/when the surface becomes available.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <IOSurface/IOSurfaceRef.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <pthread.h>
#import <unistd.h>
#import <stdarg.h>
#import <os/log.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import "DiCoyProtocol.h"

// IOReturn / kIOReturnSuccess are in IOKit/IOReturn.h which is absent from the
// public iPhoneOS SDK. Define the minimum we need here.
#ifndef IOReturn
typedef int IOReturn;
#endif
#ifndef kIOReturnSuccess
#define kIOReturnSuccess 0
#endif

// =========================================================================
// IOMobileFramebuffer — private framework, loaded via dlopen
// =========================================================================

typedef struct __IOMobileFramebuffer *IOMobileFramebufferRef;

typedef IOReturn (*IOMFBOpen_t)(uint32_t               service,
                                task_port_t            task,
                                uint32_t               type,
                                IOMobileFramebufferRef *out);

typedef IOReturn (*IOMFBGetSurface_t)(IOMobileFramebufferRef fb,
                                      int                    layer,
                                      IOSurfaceRef          *outSurface);

// IOKit — forward-declare to avoid IOKitLib.h availability issues.
extern uint32_t              IOServiceGetMatchingService(uint32_t masterPort, CFDictionaryRef matching) __attribute__((weak));
extern CFMutableDictionaryRef IOServiceMatching(const char *name)                                       __attribute__((weak));
extern kern_return_t          IOObjectRelease(uint32_t object)                                          __attribute__((weak));
extern uint32_t               kIOMasterPortDefault                                                       __attribute__((weak));

// =========================================================================
// Constants
// =========================================================================

#define SRV_MAX_CLIENTS 8

// =========================================================================
// Module-private globals
// =========================================================================

static os_log_t        sSrvLog;
typedef struct { int fd; BOOL active; } SrvClient;
static SrvClient       sClients[SRV_MAX_CLIENTS];
static int             sActiveCount = 0;
static pthread_mutex_t sClientsMtx  = PTHREAD_MUTEX_INITIALIZER;

// =========================================================================
// Diagnostic file writer — /var/tmp/dicoy_server.txt
// =========================================================================

static void srvLog(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    char buf[512]; vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    FILE *f = fopen("/var/tmp/dicoy_server.txt", "a");
    if (f) { fprintf(f, "%s\n", buf); fclose(f); }
    os_log(sSrvLog, "%{public}s", buf);
}

// =========================================================================
// Forward declarations
// =========================================================================

static void * srvCaptureLoop(void *arg);
static void * srvSocketServer(void *arg);
static void * srvHandleClient(void *arg);
static void   srvBroadcast(uint32_t surfID, uint16_t w, uint16_t h);
static void   srvRemoveClient(int fd);
static int    srvActiveCount(void);

// =========================================================================
// Public entry point — called once from %ctor when in SpringBoard
// =========================================================================

void diCoyServerStart(void) {
    sSrvLog = os_log_create("com.dicoy.server", "springboard");
    for (int i = 0; i < SRV_MAX_CLIENTS; i++) sClients[i].fd = -1;

    FILE *f = fopen("/var/tmp/dicoy_server.txt", "w");
    if (f) { fprintf(f, "DiCoyServer start PID=%d\n", getpid()); fclose(f); }

    pthread_t t;
    pthread_create(&t, NULL, srvSocketServer, NULL);
    pthread_detach(t);
    pthread_create(&t, NULL, srvCaptureLoop, NULL);
    pthread_detach(t);
}

// =========================================================================
// Capture loop — IOMobileFramebuffer inside SpringBoard
//
// IOMobileFramebufferOpen requires the UI bootstrap session and
// com.apple.private.framebuffer — both true for SpringBoard.
//
// GetLayerDefaultSurface may return kIOReturnError early in boot before the
// display has rendered its first frame. We never exit on failure; instead we
// log every 30th consecutive failure and keep retrying.
// =========================================================================

static void * srvCaptureLoop(void *arg) {
    void *lib = dlopen(
        "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer",
        RTLD_LAZY | RTLD_GLOBAL);
    if (!lib) {
        srvLog("FAIL: dlopen IOMobileFramebuffer: %s", dlerror());
        return NULL;
    }
    srvLog("IOMobileFramebuffer.framework loaded");

    IOMFBOpen_t       fbOpen       = (IOMFBOpen_t)dlsym(lib, "IOMobileFramebufferOpen");
    IOMFBGetSurface_t fbGetSurface = (IOMFBGetSurface_t)dlsym(lib,
                                         "IOMobileFramebufferGetLayerDefaultSurface");
    if (!fbOpen || !fbGetSurface) {
        srvLog("FAIL: IOMobileFramebuffer symbols missing: open=%p surf=%p err=%s",
               (void *)fbOpen, (void *)fbGetSurface, dlerror());
        return NULL;
    }
    srvLog("IOMobileFramebuffer symbols resolved");

    uint32_t svc = IOServiceGetMatchingService
        ? IOServiceGetMatchingService(kIOMasterPortDefault,
                                      IOServiceMatching("IOMobileFramebuffer"))
        : 0;
    if (!svc) {
        srvLog("FAIL: IOMobileFramebuffer IOService not found");
        return NULL;
    }
    srvLog("IOService=0x%x", svc);

    IOMobileFramebufferRef fb = NULL;
    IOReturn openRet = fbOpen(svc, mach_task_self(), 0, &fb);
    if (IOObjectRelease) IOObjectRelease(svc);

    if (openRet != kIOReturnSuccess || !fb) {
        srvLog("FAIL: IOMobileFramebufferOpen: 0x%x", (unsigned)openRet);
        return NULL;
    }
    srvLog("IOMobileFramebuffer opened (type=0)");

    // -----------------------------------------------------------------------
    // Main capture loop.
    //
    // GetLayerDefaultSurface is retried every iteration without early exit:
    // it fails during SpringBoard init and (hopefully) succeeds once the
    // display pipeline is fully up. We log every 30th consecutive failure so
    // the log file shows progress without flooding.
    //
    // Layer probing: try 0, then 1, then 2 in sequence if 0 keeps failing.
    // -----------------------------------------------------------------------
    const uint64_t frameIntervalNs = (uint64_t)(1e9 / DICOY_TARGET_FPS);
    uint64_t lastFrameNs   = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    BOOL     firstFrame    = YES;
    int      surfFailCount = 0;
    int      probeLayer    = 0;   // escalate to 1, 2 after many failures on 0

    while (1) {
        if (srvActiveCount() == 0) { usleep(100000); continue; }

        uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        int64_t remaining = (int64_t)frameIntervalNs - (int64_t)(now - lastFrameNs);
        if (remaining > 0) { usleep((useconds_t)(remaining / 2000)); continue; }
        lastFrameNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);

        IOSurfaceRef surface = NULL;
        IOReturn r = fbGetSurface(fb, probeLayer, &surface);

        if (r != kIOReturnSuccess || !surface) {
            surfFailCount++;
            // After 150 failures on layer 0 (~5 s), escalate to layer 1
            if (surfFailCount == 150 && probeLayer == 0) {
                probeLayer = 1;
                srvLog("GetLayerDefaultSurface layer=0 failed %d times (0x%x), trying layer=1",
                       surfFailCount, (unsigned)r);
            }
            // After another 150 failures on layer 1, try layer 2
            if (surfFailCount == 300 && probeLayer == 1) {
                probeLayer = 2;
                srvLog("GetLayerDefaultSurface layer=1 still failing, trying layer=2");
            }
            // Log every 30th failure regardless
            if (surfFailCount % 30 == 1) {
                srvLog("GetLayerDefaultSurface layer=%d fail #%d: 0x%x",
                       probeLayer, surfFailCount, (unsigned)r);
            }
            continue;
        }

        // Surface obtained — reset failure counter and layer probe
        if (surfFailCount > 0) {
            srvLog("GetLayerDefaultSurface recovered after %d failures (layer=%d)",
                   surfFailCount, probeLayer);
            surfFailCount = 0;
        }

        uint32_t sid = IOSurfaceGetID(surface);
        uint16_t w   = (uint16_t)IOSurfaceGetWidth(surface);
        uint16_t h   = (uint16_t)IOSurfaceGetHeight(surface);
        // surface is owned by the display hardware — do NOT CFRelease

        if (firstFrame) {
            firstFrame = NO;
            srvLog("First frame: id=%u %ux%u fmt=0x%08x layer=%d",
                   sid, w, h, IOSurfaceGetPixelFormat(surface), probeLayer);
        }
        srvBroadcast(sid, w, h);
    }

    return NULL;
}

// =========================================================================
// Socket server
// =========================================================================

static void * srvSocketServer(void *arg) {
    unlink(DICOY_SOCKET_PATH);

    int srvFd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (srvFd < 0) { srvLog("FAIL: socket(): %s", strerror(errno)); return NULL; }

    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, DICOY_SOCKET_PATH, sizeof(addr.sun_path));

    if (bind(srvFd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        srvLog("FAIL: bind(%s): %s", DICOY_SOCKET_PATH, strerror(errno));
        close(srvFd); return NULL;
    }
    chmod(DICOY_SOCKET_PATH, 0777);
    listen(srvFd, SRV_MAX_CLIENTS);
    srvLog("Socket listening on %s", DICOY_SOCKET_PATH);

    while (1) {
        int cfd = accept(srvFd, NULL, NULL);
        if (cfd < 0) continue;

        pthread_mutex_lock(&sClientsMtx);
        BOOL ok = NO;
        for (int i = 0; i < SRV_MAX_CLIENTS; i++) {
            if (sClients[i].fd < 0) {
                sClients[i].fd = cfd; sClients[i].active = NO; ok = YES; break;
            }
        }
        pthread_mutex_unlock(&sClientsMtx);
        if (!ok) { close(cfd); continue; }

        srvLog("Client connected fd=%d", cfd);
        int *fdp = malloc(sizeof(int)); *fdp = cfd;
        pthread_t t; pthread_create(&t, NULL, srvHandleClient, fdp); pthread_detach(t);
    }
    return NULL;
}

static void * srvHandleClient(void *arg) {
    int fd = *(int *)arg; free(arg);
    DicoyMessage msg;
    while (1) {
        if (recv(fd, &msg, sizeof(msg), MSG_WAITALL) != (ssize_t)sizeof(msg)) break;
        if (msg.magic != DICOY_MAGIC) break;
        switch ((DicoyMessageType)msg.type) {
            case kDicoyMsgStartCapture:
                pthread_mutex_lock(&sClientsMtx);
                for (int i = 0; i < SRV_MAX_CLIENTS; i++) {
                    if (sClients[i].fd == fd && !sClients[i].active) {
                        sClients[i].active = YES; sActiveCount++; break;
                    }
                }
                pthread_mutex_unlock(&sClientsMtx);
                srvLog("fd=%d START_CAPTURE active=%d", fd, sActiveCount);
                break;
            case kDicoyMsgStopCapture:
                pthread_mutex_lock(&sClientsMtx);
                for (int i = 0; i < SRV_MAX_CLIENTS; i++) {
                    if (sClients[i].fd == fd && sClients[i].active) {
                        sClients[i].active = NO; sActiveCount--; break;
                    }
                }
                pthread_mutex_unlock(&sClientsMtx);
                break;
            case kDicoyMsgPing: {
                DicoyMessage pong = { .magic = DICOY_MAGIC, .type = kDicoyMsgPong };
                send(fd, &pong, sizeof(pong), 0);
                break;
            }
            default: break;
        }
    }
    srvLog("Client disconnected fd=%d", fd);
    srvRemoveClient(fd);
    close(fd);
    return NULL;
}

static void srvBroadcast(uint32_t surfID, uint16_t w, uint16_t h) {
    DicoyMessage msg = {
        .magic = DICOY_MAGIC, .type = kDicoyMsgFrameReady,
        .surface_id = surfID, .width = w, .height = h,
        .timestamp = (uint32_t)(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1000000ULL),
    };
    pthread_mutex_lock(&sClientsMtx);
    for (int i = 0; i < SRV_MAX_CLIENTS; i++)
        if (sClients[i].fd >= 0 && sClients[i].active)
            send(sClients[i].fd, &msg, sizeof(msg), MSG_DONTWAIT);
    pthread_mutex_unlock(&sClientsMtx);
}

static void srvRemoveClient(int fd) {
    pthread_mutex_lock(&sClientsMtx);
    for (int i = 0; i < SRV_MAX_CLIENTS; i++) {
        if (sClients[i].fd == fd) {
            if (sClients[i].active) sActiveCount--;
            sClients[i].fd = -1; sClients[i].active = NO; break;
        }
    }
    pthread_mutex_unlock(&sClientsMtx);
}

static int srvActiveCount(void) {
    pthread_mutex_lock(&sClientsMtx);
    int n = sActiveCount;
    pthread_mutex_unlock(&sClientsMtx);
    return n;
}
