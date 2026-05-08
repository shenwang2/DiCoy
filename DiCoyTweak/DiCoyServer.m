// DiCoyTweak/DiCoyServer.m
//
// Screen-capture server that runs inside SpringBoard via tweak injection.
// SpringBoard has the entitlements (com.apple.CARenderServer, IOSurfaceFamily)
// and the UI-session bootstrap port needed to make this work — a standalone
// launchd daemon in the Background session cannot obtain these.
//
// Entry point: diCoyServerStart()
// Call once from %ctor when NSProcessInfo.processInfo.processName == "SpringBoard".

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <IOSurface/IOSurfaceRef.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <pthread.h>
#import <unistd.h>
#import <os/log.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import "DiCoyProtocol.h"

// bootstrap_look_up not declared in the iOS SDK's mach/bootstrap.h
extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *service_name, mach_port_t *sp);

typedef kern_return_t (*CARSRenderDisplay_t)(
    mach_port_t  server,
    uint32_t     display,
    IOSurfaceRef surface,
    CGFloat      x, CGFloat y,
    uint32_t     flags
);

// =========================================================================
// Constants
// =========================================================================

#define SRV_MAX_CLIENTS       8
#define SRV_SURFACE_POOL_SIZE 2

// =========================================================================
// Module-private globals (srv_ prefix avoids collisions with tweak globals)
// =========================================================================

static os_log_t         sSrvLog;
static IOSurfaceRef     sSurfPool[SRV_SURFACE_POOL_SIZE];
static uint32_t         sSurfIDs[SRV_SURFACE_POOL_SIZE];
static int              sWriteIdx   = 0;
static pthread_mutex_t  sSurfMtx    = PTHREAD_MUTEX_INITIALIZER;

typedef struct { int fd; BOOL active; } SrvClient;
static SrvClient        sClients[SRV_MAX_CLIENTS];
static int              sActiveCount = 0;
static pthread_mutex_t  sClientsMtx  = PTHREAD_MUTEX_INITIALIZER;

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
// Public entry point
// =========================================================================

void diCoyServerStart(void) {
    sSrvLog = os_log_create("com.dicoy.server", "springboard");
    for (int i = 0; i < SRV_MAX_CLIENTS; i++) sClients[i].fd = -1;
    mkdir(DICOY_JB_PREFIX "/var/run", 0755);

    os_log(sSrvLog, "DiCoyServer starting in SpringBoard");

    pthread_t t;
    pthread_create(&t, NULL, srvSocketServer, NULL);
    pthread_detach(t);
    pthread_create(&t, NULL, srvCaptureLoop, NULL);
    pthread_detach(t);
}

// =========================================================================
// Surface pool — runs inside SpringBoard, so kIOSurfaceIsGlobal is honored
// =========================================================================

static BOOL srvSetupSurfaces(int w, int h) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSDictionary *props = @{
        (id)kIOSurfaceWidth:           @(w),
        (id)kIOSurfaceHeight:          @(h),
        (id)kIOSurfaceBytesPerElement: @(4),
        (id)kIOSurfaceBytesPerRow:     @(w * 4),
        (id)kIOSurfaceAllocSize:       @(w * h * 4),
        (id)kIOSurfacePixelFormat:     @((uint32_t)0x42475241u), // 'BGRA'
        (id)kIOSurfaceIsGlobal:        @YES,
    };
#pragma clang diagnostic pop

    for (int i = 0; i < SRV_SURFACE_POOL_SIZE; i++) {
        sSurfPool[i] = IOSurfaceCreate((__bridge CFDictionaryRef)props);
        if (!sSurfPool[i]) {
            os_log_error(sSrvLog, "IOSurfaceCreate failed for slot %d", i);
            return NO;
        }
        sSurfIDs[i] = IOSurfaceGetID(sSurfPool[i]);
        os_log(sSrvLog, "Surface[%d] id=%u", i, sSurfIDs[i]);
    }
    return YES;
}

// =========================================================================
// Capture loop
// =========================================================================

static void * srvCaptureLoop(void *arg) {
    // Load CARenderServer at runtime — same dlopen approach as the old daemon.
    void *lib = dlopen(
        "/System/Library/PrivateFrameworks/CARenderServer.framework/CARenderServer",
        RTLD_LAZY | RTLD_GLOBAL);
    CARSRenderDisplay_t renderFn = lib
        ? (CARSRenderDisplay_t)dlsym(lib, "CARenderServerRenderDisplay")
        : NULL;
    if (!renderFn) {
        os_log_fault(sSrvLog, "CARenderServerRenderDisplay not found: %s", dlerror());
        return NULL;
    }

    // CARenderServer is in the UI session bootstrap; SpringBoard's bootstrap_port
    // is already in the right session, so this lookup succeeds where a daemon's
    // Background-session bootstrap_port would not.
    mach_port_t renderPort = MACH_PORT_NULL;
    for (int i = 0; i < 30; i++) {
        kern_return_t kr = bootstrap_look_up(
            bootstrap_port, "com.apple.CARenderServer", &renderPort);
        if (kr == KERN_SUCCESS && renderPort != MACH_PORT_NULL) break;
        sleep(1);
    }
    if (renderPort == MACH_PORT_NULL) {
        os_log_fault(sSrvLog, "bootstrap_look_up(CARenderServer) failed");
        return NULL;
    }
    os_log(sSrvLog, "CARenderServer port=%u", renderPort);

    CGRect nb = [UIScreen mainScreen].nativeBounds;
    int w = (nb.size.width  > 0) ? (int)nb.size.width  : 1170;
    int h = (nb.size.height > 0) ? (int)nb.size.height : 2532;
    os_log(sSrvLog, "Display %d x %d", w, h);

    if (!srvSetupSurfaces(w, h)) {
        os_log_fault(sSrvLog, "Surface pool setup failed");
        return NULL;
    }

    const uint64_t frameIntervalNs = (uint64_t)(1e9 / DICOY_TARGET_FPS);
    uint64_t lastFrameNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);

    while (1) {
        if (srvActiveCount() == 0) { usleep(100000); continue; }

        uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        int64_t remaining = (int64_t)frameIntervalNs - (int64_t)(now - lastFrameNs);
        if (remaining > 0) { usleep((useconds_t)(remaining / 2000)); continue; }
        lastFrameNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);

        pthread_mutex_lock(&sSurfMtx);
        int slot = sWriteIdx;
        sWriteIdx = (sWriteIdx + 1) % SRV_SURFACE_POOL_SIZE;
        pthread_mutex_unlock(&sSurfMtx);

        IOSurfaceRef dst = sSurfPool[slot];
        IOSurfaceLock(dst, 0, NULL);
        kern_return_t kr = renderFn(renderPort, 0, dst, 0.0, 0.0, 0);
        IOSurfaceUnlock(dst, 0, NULL);

        if (kr == KERN_SUCCESS) {
            srvBroadcast(sSurfIDs[slot], (uint16_t)w, (uint16_t)h);
        } else {
            os_log_error(sSrvLog, "CARenderServerRenderDisplay: %d", kr);
        }
    }

    return NULL;
}

// =========================================================================
// Socket server
// =========================================================================

static void * srvSocketServer(void *arg) {
    unlink(DICOY_SOCKET_PATH); // remove stale socket from previous SpringBoard instance

    int srvFd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (srvFd < 0) return NULL;

    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, DICOY_SOCKET_PATH, sizeof(addr.sun_path));

    if (bind(srvFd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(srvFd); return NULL;
    }
    chmod(DICOY_SOCKET_PATH, 0777);
    listen(srvFd, SRV_MAX_CLIENTS);
    os_log(sSrvLog, "Listening on %s", DICOY_SOCKET_PATH);

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
                os_log(sSrvLog, "fd=%d START_CAPTURE active=%d", fd, sActiveCount);
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
