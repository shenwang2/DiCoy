// DiCoyTweak/DiCoyServer.m
//
// Screen-capture server running inside SpringBoard via tweak injection.
//
// CARenderServer.framework does not exist on disk on iOS 15+ and is not in the
// dyld shared cache — dlopen fails.  IOMobileFramebuffer is the correct path:
// the framework exists, the symbols resolve, and IOMobileFramebufferOpen
// succeeds because SpringBoard is in the UI session (kIOReturnNotPermitted was
// only seen from the Background-session standalone daemon).
//
// The display's own IOSurface is in the global IOSurface table by system
// necessity, so IOSurfaceLookup() in camera-app processes works without
// kIOSurfaceIsGlobal.

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

// =========================================================================
// IOMobileFramebuffer — private framework, loaded via dlopen
// =========================================================================

typedef struct __IOMobileFramebuffer *IOMobileFramebufferRef;

typedef IOReturn (*IOMFBOpen_t)(uint32_t              service,
                                 task_port_t           task,
                                 uint32_t              type,
                                 IOMobileFramebufferRef *out);

typedef IOReturn (*IOMFBGetSurface_t)(IOMobileFramebufferRef fb,
                                       int                    layer,
                                       IOSurfaceRef          *outSurface);

// IOKit — forward-declare to avoid IOKitLib.h availability issues.
extern uint32_t IOServiceGetMatchingService(uint32_t masterPort, CFDictionaryRef matching) __attribute__((weak));
extern CFMutableDictionaryRef IOServiceMatching(const char *name) __attribute__((weak));
extern kern_return_t IOObjectRelease(uint32_t object) __attribute__((weak));
extern uint32_t kIOMasterPortDefault __attribute__((weak));

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
    mkdir(DICOY_JB_PREFIX "/var/run", 0755);

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
// IOMobileFramebufferOpen requires being in the UI bootstrap session and
// having com.apple.private.framebuffer — both are true for SpringBoard.
// The standalone daemon in the Background session got kIOReturnNotPermitted;
// SpringBoard does not.
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

    IOMFBOpen_t     fbOpen       = (IOMFBOpen_t)dlsym(lib, "IOMobileFramebufferOpen");
    IOMFBGetSurface_t fbGetSurface = (IOMFBGetSurface_t)dlsym(lib,
                                         "IOMobileFramebufferGetLayerDefaultSurface");
    if (!fbOpen || !fbGetSurface) {
        srvLog("FAIL: IOMobileFramebuffer symbols missing: %s", dlerror());
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
    srvLog("IOMobileFramebuffer opened");

    // Probe the initial surface to log dimensions and confirm it's accessible.
    {
        IOSurfaceRef s = NULL;
        IOReturn r = fbGetSurface(fb, 0, &s);
        if (r == kIOReturnSuccess && s) {
            srvLog("Display surface: %zux%zu fmt=0x%08x id=%u",
                   IOSurfaceGetWidth(s), IOSurfaceGetHeight(s),
                   IOSurfaceGetPixelFormat(s), IOSurfaceGetID(s));
        } else {
            srvLog("FAIL: initial GetLayerDefaultSurface: 0x%x", (unsigned)r);
            return NULL;
        }
    }

    const uint64_t frameIntervalNs = (uint64_t)(1e9 / DICOY_TARGET_FPS);
    uint64_t lastFrameNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    BOOL firstFrame = YES;

    while (1) {
        if (srvActiveCount() == 0) { usleep(100000); continue; }

        uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        int64_t remaining = (int64_t)frameIntervalNs - (int64_t)(now - lastFrameNs);
        if (remaining > 0) { usleep((useconds_t)(remaining / 2000)); continue; }
        lastFrameNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);

        IOSurfaceRef surface = NULL;
        if (fbGetSurface(fb, 0, &surface) != kIOReturnSuccess || !surface) continue;

        uint32_t sid = IOSurfaceGetID(surface);
        uint16_t w   = (uint16_t)IOSurfaceGetWidth(surface);
        uint16_t h   = (uint16_t)IOSurfaceGetHeight(surface);
        // surface is owned by the display hardware — do NOT CFRelease

        if (firstFrame) {
            firstFrame = NO;
            srvLog("First frame: id=%u %dx%d", sid, w, h);
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
