// DiCoyTweak/DiCoyServer.m
//
// Screen-capture server running inside SpringBoard via tweak injection.
//
// IOMobileFramebufferGetLayerDefaultSurface returns kIOReturnError on A13+ DCP
// devices (the display compositor runs on a separate co-processor and this
// legacy API is a no-op stub). We use CARenderServerRenderDisplay instead.
//
// CARenderServer.framework no longer exists as a file on iOS 15+, but its
// symbols were merged into QuartzCore.framework (which is always loaded in
// every process). dlsym(RTLD_DEFAULT, ...) finds the symbol without dlopen.
//
// The destination IOSurface is created with IOSurfaceIsGlobal so camera-app
// processes can call IOSurfaceLookup(id) after libSandy grants
// IOSurfaceRootUserClient access.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurfaceRef.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <pthread.h>
#import <unistd.h>
#import <stdarg.h>
#import <os/log.h>
#import <dlfcn.h>
#import <sys/stat.h>
#import "DiCoyProtocol.h"

// =========================================================================
// CARenderServerRenderDisplay — in QuartzCore on iOS 15+
//
// Signature from reverse engineering of QuartzCore on iOS 13–15:
//   port    : mach_port_t — pass 0 (use the default render-server port)
//   display : CFStringRef — pass NULL (primary display)
//   surface : IOSurfaceRef — destination; must be pre-allocated
//   flags   : int         — pass 0
// Returns 0 (KERN_SUCCESS) on success.
// =========================================================================

typedef kern_return_t (*CARSRenderDisplay_t)(mach_port_t    port,
                                             CFStringRef    display,
                                             IOSurfaceRef   surface,
                                             int            flags);

// =========================================================================
// Constants / globals
// =========================================================================

#define SRV_MAX_CLIENTS 8

static os_log_t         sSrvLog;
typedef struct { int fd; BOOL active; } SrvClient;
static SrvClient        sClients[SRV_MAX_CLIENTS];
static int              sActiveCount = 0;
static pthread_mutex_t  sClientsMtx  = PTHREAD_MUTEX_INITIALIZER;

// The one surface we render the screen into each frame (created on main thread
// at startup; read-only from socket-server/broadcast thereafter).
static IOSurfaceRef     gSurface    = NULL;
static uint32_t         gSurfaceID  = 0;
static uint16_t         gSurfaceW   = 0;
static uint16_t         gSurfaceH   = 0;

// =========================================================================
// Diagnostic writer — /var/tmp/dicoy_server.txt
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
// Helpers
// =========================================================================

static void   srvBroadcast(uint32_t surfID, uint16_t w, uint16_t h);
static void   srvRemoveClient(int fd);
static int    srvActiveCount(void);

static void * srvSocketServer(void *arg);
static void * srvHandleClient(void *arg);

// =========================================================================
// CADisplayLink target — lives on the main thread
// =========================================================================

@interface DiCoyCaptureTarget : NSObject
@property (nonatomic, assign) CARSRenderDisplay_t renderFn;
@property (nonatomic, assign) int                 failCount;
@end

@implementation DiCoyCaptureTarget

- (void)tick:(CADisplayLink *)link {
    if (srvActiveCount() == 0) return;
    if (!gSurface)             return;

    kern_return_t kr = self.renderFn(0, NULL, gSurface, 0);
    if (kr != 0) {
        self.failCount++;
        if (self.failCount % 30 == 1)
            srvLog("CARenderServerRenderDisplay fail #%d: 0x%x", self.failCount, (unsigned)kr);
        return;
    }

    if (self.failCount > 0) {
        srvLog("CARenderServerRenderDisplay recovered after %d failures", self.failCount);
        self.failCount = 0;
    }

    static BOOL sFirstFrame = YES;
    if (sFirstFrame) {
        sFirstFrame = NO;
        srvLog("First frame rendered: id=%u %ux%u", gSurfaceID, gSurfaceW, gSurfaceH);
    }

    srvBroadcast(gSurfaceID, gSurfaceW, gSurfaceH);
}

@end

// =========================================================================
// Public entry point
// =========================================================================

// Retained on main thread for the display link lifetime.
static DiCoyCaptureTarget *sCaptureTarget;
static CADisplayLink      *sDisplayLink;

void diCoyServerStart(void) {
    sSrvLog = os_log_create("com.dicoy.server", "springboard");
    for (int i = 0; i < SRV_MAX_CLIENTS; i++) sClients[i].fd = -1;

    FILE *f = fopen("/var/tmp/dicoy_server.txt", "w");
    if (f) { fprintf(f, "DiCoyServer start PID=%d\n", getpid()); fclose(f); }

    // Socket server runs on a background thread.
    pthread_t t;
    pthread_create(&t, NULL, srvSocketServer, NULL);
    pthread_detach(t);

    // Display capture must be set up on the main thread (display-server APIs,
    // UIScreen, and CADisplayLink all require it).
    dispatch_async(dispatch_get_main_queue(), ^{

        // ---------------------------------------------------------------
        // 1. Locate CARenderServerRenderDisplay in the loaded QuartzCore.
        // ---------------------------------------------------------------
        CARSRenderDisplay_t renderFn =
            (CARSRenderDisplay_t)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
        srvLog("CARenderServerRenderDisplay = %s",
               renderFn ? "FOUND in QuartzCore" : "NOT FOUND");

        if (!renderFn) {
            srvLog("ABORT: CARenderServerRenderDisplay absent — screen mirror unavailable");
            return;
        }

        // ---------------------------------------------------------------
        // 2. Create the global destination IOSurface.
        //    SpringBoard is an Apple-signed privileged process in the UI
        //    session, so IOSurfaceIsGlobal is honored here (it fails in
        //    Background-session daemons).
        // ---------------------------------------------------------------
        CGRect native = [UIScreen mainScreen].nativeBounds;
        uint16_t w = (uint16_t)native.size.width;
        uint16_t h = (uint16_t)native.size.height;
        srvLog("Display native bounds: %ux%u", w, h);

        // Use string literal for IOSurfaceIsGlobal to avoid the deprecated
        // kIOSurfaceIsGlobal symbol (same string value, no warning).
        CFMutableDictionaryRef props = CFDictionaryCreateMutable(
            kCFAllocatorDefault, 0,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(props, kIOSurfaceWidth,           (__bridge CFNumberRef)@(w));
        CFDictionarySetValue(props, kIOSurfaceHeight,          (__bridge CFNumberRef)@(h));
        CFDictionarySetValue(props, kIOSurfacePixelFormat,     (__bridge CFNumberRef)@(0x42475241)); // 'BGRA'
        CFDictionarySetValue(props, kIOSurfaceBytesPerElement, (__bridge CFNumberRef)@(4));
        CFDictionarySetValue(props, CFSTR("IOSurfaceIsGlobal"), kCFBooleanTrue);

        gSurface = IOSurfaceCreate(props);
        CFRelease(props);

        srvLog("IOSurfaceCreate(global) %ux%u = %p id=%u",
               w, h, (void *)gSurface,
               gSurface ? IOSurfaceGetID(gSurface) : 0);

        if (!gSurface) {
            srvLog("ABORT: IOSurfaceCreate failed — SpringBoard may lack entitlement");
            return;
        }

        gSurfaceID = IOSurfaceGetID(gSurface);
        gSurfaceW  = w;
        gSurfaceH  = h;

        // ---------------------------------------------------------------
        // 3. Start a CADisplayLink to drive frame capture at DICOY_TARGET_FPS.
        // ---------------------------------------------------------------
        sCaptureTarget           = [DiCoyCaptureTarget new];
        sCaptureTarget.renderFn  = renderFn;
        sCaptureTarget.failCount = 0;

        sDisplayLink = [CADisplayLink
            displayLinkWithTarget:sCaptureTarget
                         selector:@selector(tick:)];
        sDisplayLink.preferredFramesPerSecond = DICOY_TARGET_FPS;
        [sDisplayLink addToRunLoop:[NSRunLoop mainRunLoop]
                           forMode:NSRunLoopCommonModes];

        srvLog("CADisplayLink started at %d fps, surface id=%u",
               DICOY_TARGET_FPS, gSurfaceID);
    });
}

// =========================================================================
// Socket server
// =========================================================================

static void * srvSocketServer(void *arg) {
    int srvFd = socket(AF_INET, SOCK_STREAM, 0);
    if (srvFd < 0) { srvLog("FAIL: socket(): %s", strerror(errno)); return NULL; }

    int yes = 1;
    setsockopt(srvFd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr = {0};
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port        = htons(DICOY_SERVER_PORT);

    if (bind(srvFd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        srvLog("FAIL: bind(127.0.0.1:%d): %s", DICOY_SERVER_PORT, strerror(errno));
        close(srvFd); return NULL;
    }
    listen(srvFd, SRV_MAX_CLIENTS);
    srvLog("TCP server listening on 127.0.0.1:%d", DICOY_SERVER_PORT);

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
        pthread_t t;
        pthread_create(&t, NULL, srvHandleClient, fdp);
        pthread_detach(t);
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
        .magic      = DICOY_MAGIC,
        .type       = kDicoyMsgFrameReady,
        .surface_id = surfID,
        .width      = w,
        .height     = h,
        .timestamp  = (uint32_t)(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1000000ULL),
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
