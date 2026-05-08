// DiCoyDaemon/main.m
//
// Captures the live display framebuffer via IOMobileFramebuffer and delivers
// each frame's IOSurfaceID to connected tweak clients over a Unix Domain Socket.
// No pixel data crosses the socket; IOSurfaceLookup() in the tweak maps the same
// GPU pages. The framebuffer's IOSurface is in the global IOSurface table by
// system necessity, so cross-process lookup works without kIOSurfaceIsGlobal.

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#import <IOKit/IOReturn.h>
#import <mach/mach.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <pthread.h>
#import <signal.h>
#import <unistd.h>
#import <os/log.h>
#import <dlfcn.h>

#import "DiCoyProtocol.h"

// =========================================================================
// IOMobileFramebuffer — private framework, loaded via dlopen at runtime.
// =========================================================================

typedef struct __IOMobileFramebuffer *IOMobileFramebufferRef;

typedef IOReturn (*IOMFBOpen_t)(uint32_t              service,
                                 task_port_t           task,
                                 uint32_t              type,
                                 IOMobileFramebufferRef *out);

typedef IOReturn (*IOMFBGetSurface_t)(IOMobileFramebufferRef fb,
                                       int                    layer,
                                       IOSurfaceRef          *outSurface);

// IOKit service lookup — forward-declare to avoid header dependency issues.
extern uint32_t IOServiceGetMatchingService(uint32_t masterPort, CFDictionaryRef matching) __attribute__((weak));
extern CFMutableDictionaryRef IOServiceMatching(const char *name) __attribute__((weak));
extern kern_return_t IOObjectRelease(uint32_t object) __attribute__((weak));
extern uint32_t kIOMasterPortDefault __attribute__((weak));

// =========================================================================
// Constants
// =========================================================================

#define MAX_CLIENTS 8

// =========================================================================
// Globals
// =========================================================================

static os_log_t gLog;

typedef struct {
    int  fd;
    BOOL active;
} DicoyClient;

static DicoyClient     gClients[MAX_CLIENTS];
static int             gActiveCount = 0;
static pthread_mutex_t gClientsMtx  = PTHREAD_MUTEX_INITIALIZER;

// =========================================================================
// Forward declarations
// =========================================================================

static void * captureLoop(void *arg);
static void * socketServer(void *arg);
static void * handleClient(void *arg);
static void   broadcastFrame(uint32_t surfID, uint16_t w, uint16_t h);
static void   removeClient(int fd);
static int    activeCount(void);

// =========================================================================
// Signal handler
// =========================================================================

static void onSignal(int sig) {
    os_log(gLog, "DiCoyDaemon: signal %d – shutting down", sig);
    unlink(DICOY_SOCKET_PATH);
    exit(0);
}

// =========================================================================
// main()
// =========================================================================

int main(int argc, char *argv[]) {
    @autoreleasepool {
        mkdir(DICOY_JB_PREFIX "/var/log", 0755);
        mkdir(DICOY_JB_PREFIX "/var/run", 0755);

        gLog = os_log_create("com.dicoy.daemon", "main");
        os_log(gLog, "DiCoyDaemon starting (PID %d)", getpid());
        fprintf(stderr, "DiCoyDaemon starting PID=%d\n", getpid());

        signal(SIGTERM, onSignal);
        signal(SIGINT,  onSignal);

        for (int i = 0; i < MAX_CLIENTS; i++) gClients[i].fd = -1;

        // Socket server runs on a background thread; capture loop on main thread.
        pthread_t serverThread;
        pthread_create(&serverThread, NULL, socketServer, NULL);
        pthread_detach(serverThread);

        captureLoop(NULL);
        return 0;
    }
}

// =========================================================================
// captureLoop
//
// Opens IOMobileFramebuffer to get the display's composited front-buffer.
// On each frame deadline, reads the current surface ID and broadcasts it.
// The surface is owned by the display hardware; we never lock or release it.
// =========================================================================

static void * captureLoop(void *arg) {
    void *lib = dlopen(
        "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer",
        RTLD_LAZY | RTLD_GLOBAL);
    if (lib) {
        fprintf(stderr, "DiCoyDaemon: IOMobileFramebuffer.framework loaded\n");
    } else {
        fprintf(stderr, "DiCoyDaemon: dlopen IOMobileFramebuffer: %s — trying RTLD_DEFAULT\n",
                dlerror());
    }

    void *search = lib ?: RTLD_DEFAULT;
    IOMFBOpen_t     fbOpen       = (IOMFBOpen_t)dlsym(search, "IOMobileFramebufferOpen");
    IOMFBGetSurface_t fbGetSurface = (IOMFBGetSurface_t)dlsym(search,
                                        "IOMobileFramebufferGetLayerDefaultSurface");

    if (!fbOpen || !fbGetSurface) {
        fprintf(stderr, "DiCoyDaemon: IOMobileFramebuffer symbols missing: %s\n", dlerror());
        return NULL;
    }
    fprintf(stderr, "DiCoyDaemon: IOMobileFramebuffer symbols resolved\n");

    uint32_t svc = IOServiceGetMatchingService
        ? IOServiceGetMatchingService(kIOMasterPortDefault,
                                      IOServiceMatching("IOMobileFramebuffer"))
        : 0;
    if (!svc) {
        fprintf(stderr, "DiCoyDaemon: IOMobileFramebuffer IOService not found\n");
        return NULL;
    }
    fprintf(stderr, "DiCoyDaemon: IOService=0x%x\n", svc);

    IOMobileFramebufferRef fb = NULL;
    IOReturn openRet = fbOpen(svc, mach_task_self(), 0, &fb);
    if (IOObjectRelease) IOObjectRelease(svc);

    if (openRet != kIOReturnSuccess || !fb) {
        fprintf(stderr, "DiCoyDaemon: IOMobileFramebufferOpen failed: 0x%x\n", openRet);
        return NULL;
    }
    fprintf(stderr, "DiCoyDaemon: IOMobileFramebuffer opened\n");

    // Log initial surface dimensions/format so the log file is useful.
    {
        IOSurfaceRef s = NULL;
        if (fbGetSurface(fb, 0, &s) == kIOReturnSuccess && s) {
            fprintf(stderr, "DiCoyDaemon: surface %zu×%zu fmt=0x%08x id=%u\n",
                    IOSurfaceGetWidth(s), IOSurfaceGetHeight(s),
                    IOSurfaceGetPixelFormat(s), IOSurfaceGetID(s));
        } else {
            fprintf(stderr, "DiCoyDaemon: initial GetLayerDefaultSurface failed\n");
        }
    }

    const uint64_t frameIntervalNs = (uint64_t)(1e9 / DICOY_TARGET_FPS);
    uint64_t lastFrameNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);

    while (1) {
        if (activeCount() == 0) {
            usleep(100000); // 10 Hz idle poll
            continue;
        }

        uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        int64_t remaining = (int64_t)frameIntervalNs - (int64_t)(now - lastFrameNs);
        if (remaining > 0) {
            usleep((useconds_t)(remaining / 2000));
            continue;
        }
        lastFrameNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);

        IOSurfaceRef surface = NULL;
        if (fbGetSurface(fb, 0, &surface) != kIOReturnSuccess || !surface) continue;

        uint32_t sid = IOSurfaceGetID(surface);
        uint16_t w   = (uint16_t)IOSurfaceGetWidth(surface);
        uint16_t h   = (uint16_t)IOSurfaceGetHeight(surface);
        broadcastFrame(sid, w, h);
        // surface is owned by display hardware — do NOT CFRelease
    }

    return NULL;
}

// =========================================================================
// socketServer
// =========================================================================

static void * socketServer(void *arg) {
    char sockDir[256];
    strlcpy(sockDir, DICOY_SOCKET_PATH, sizeof(sockDir));
    char *slash = strrchr(sockDir, '/');
    if (slash && slash != sockDir) { *slash = '\0'; mkdir(sockDir, 0755); }

    unlink(DICOY_SOCKET_PATH);

    int srvFd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (srvFd < 0) {
        fprintf(stderr, "DiCoyDaemon: socket(): %s\n", strerror(errno));
        return NULL;
    }

    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, DICOY_SOCKET_PATH, sizeof(addr.sun_path));

    if (bind(srvFd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "DiCoyDaemon: bind(%s): %s\n", DICOY_SOCKET_PATH, strerror(errno));
        close(srvFd);
        return NULL;
    }

    chmod(DICOY_SOCKET_PATH, 0777);
    listen(srvFd, MAX_CLIENTS);
    fprintf(stderr, "DiCoyDaemon: listening on %s\n", DICOY_SOCKET_PATH);

    while (1) {
        int cfd = accept(srvFd, NULL, NULL);
        if (cfd < 0) continue;

        pthread_mutex_lock(&gClientsMtx);
        BOOL registered = NO;
        for (int i = 0; i < MAX_CLIENTS; i++) {
            if (gClients[i].fd < 0) {
                gClients[i].fd     = cfd;
                gClients[i].active = NO;
                registered         = YES;
                break;
            }
        }
        pthread_mutex_unlock(&gClientsMtx);

        if (!registered) { close(cfd); continue; }

        fprintf(stderr, "DiCoyDaemon: client connected fd=%d\n", cfd);
        int *fdp = malloc(sizeof(int));
        *fdp = cfd;
        pthread_t t;
        pthread_create(&t, NULL, handleClient, fdp);
        pthread_detach(t);
    }
    return NULL;
}

// =========================================================================
// handleClient
// =========================================================================

static void *handleClient(void *arg) {
    int fd = *(int *)arg;
    free(arg);
    DicoyMessage msg;

    while (1) {
        ssize_t n = recv(fd, &msg, sizeof(msg), MSG_WAITALL);
        if (n != (ssize_t)sizeof(msg)) break;
        if (msg.magic != DICOY_MAGIC) break;

        switch ((DicoyMessageType)msg.type) {
            case kDicoyMsgStartCapture:
                pthread_mutex_lock(&gClientsMtx);
                for (int i = 0; i < MAX_CLIENTS; i++) {
                    if (gClients[i].fd == fd && !gClients[i].active) {
                        gClients[i].active = YES;
                        gActiveCount++;
                        break;
                    }
                }
                pthread_mutex_unlock(&gClientsMtx);
                fprintf(stderr, "DiCoyDaemon: fd=%d START_CAPTURE active=%d\n", fd, gActiveCount);
                break;

            case kDicoyMsgStopCapture:
                pthread_mutex_lock(&gClientsMtx);
                for (int i = 0; i < MAX_CLIENTS; i++) {
                    if (gClients[i].fd == fd && gClients[i].active) {
                        gClients[i].active = NO;
                        gActiveCount--;
                        break;
                    }
                }
                pthread_mutex_unlock(&gClientsMtx);
                break;

            case kDicoyMsgPing: {
                DicoyMessage pong = { .magic = DICOY_MAGIC, .type = kDicoyMsgPong };
                send(fd, &pong, sizeof(pong), 0);
                break;
            }

            default: break;
        }
    }

    fprintf(stderr, "DiCoyDaemon: client disconnected fd=%d\n", fd);
    removeClient(fd);
    close(fd);
    return NULL;
}

// =========================================================================
// broadcastFrame / removeClient / activeCount
// =========================================================================

static void broadcastFrame(uint32_t surfID, uint16_t w, uint16_t h) {
    DicoyMessage msg = {
        .magic      = DICOY_MAGIC,
        .type       = kDicoyMsgFrameReady,
        .surface_id = surfID,
        .width      = w,
        .height     = h,
        .timestamp  = (uint32_t)(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1000000ULL),
    };
    pthread_mutex_lock(&gClientsMtx);
    for (int i = 0; i < MAX_CLIENTS; i++) {
        if (gClients[i].fd >= 0 && gClients[i].active)
            send(gClients[i].fd, &msg, sizeof(msg), MSG_DONTWAIT);
    }
    pthread_mutex_unlock(&gClientsMtx);
}

static void removeClient(int fd) {
    pthread_mutex_lock(&gClientsMtx);
    for (int i = 0; i < MAX_CLIENTS; i++) {
        if (gClients[i].fd == fd) {
            if (gClients[i].active) gActiveCount--;
            gClients[i].fd     = -1;
            gClients[i].active = NO;
            break;
        }
    }
    pthread_mutex_unlock(&gClientsMtx);
}

static int activeCount(void) {
    pthread_mutex_lock(&gClientsMtx);
    int n = gActiveCount;
    pthread_mutex_unlock(&gClientsMtx);
    return n;
}
