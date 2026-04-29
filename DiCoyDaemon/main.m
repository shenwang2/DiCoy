// DiCoyDaemon/main.m
//
// Background daemon that captures the device screen at DICOY_TARGET_FPS and
// delivers the frame handle (an IOSurface ID integer) to connected tweak
// clients over a Unix Domain Socket. No pixel data ever crosses the socket;
// only the 4-byte IOSurfaceID is sent, so the client process can call
// IOSurfaceLookup() to map the same GPU memory without any memcpy.

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#import <CoreGraphics/CoreGraphics.h>
#import <UIKit/UIKit.h>
#import <IOKit/IOReturn.h>
#import <mach/mach.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <pthread.h>
#import <signal.h>
#import <unistd.h>
#import <os/log.h>

// bootstrap_look_up is not declared in the iOS SDK's mach/bootstrap.h
extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *service_name, mach_port_t *sp);

#import "DiCoyProtocol.h"

// =========================================================================
// Private API declarations
//
// CARenderServer is the private system compositor daemon. It holds the
// canonical, fully-composited pixel output for every display. By sending
// it a render request we get a pixel-perfect screenshot that includes all
// SpringBoard layers, system UI, and the frontmost app – exactly what the
// user sees – without going through AVFoundation or ReplayKit.
//
// These symbols are resolved at link time via the private CARenderServer
// framework (/System/Library/PrivateFrameworks/...). The declarations
// below allow the compiler to type-check call sites.
// =========================================================================

// Renders the current composited display into `surface`.
//   server  – Mach port obtained via bootstrap_look_up("com.apple.CARenderServer")
//   display – 0 for the main iPhone display
//   surface – destination IOSurface (must be pre-allocated with matching dimensions)
//   x, y    – pixel offset; pass 0.0, 0.0 to render from the top-left corner
//   flags   – 0 for synchronous, fully-composited render
extern kern_return_t CARenderServerRenderDisplay(
    mach_port_t  server,
    uint32_t     display,
    IOSurfaceRef surface,
    CGFloat      x,
    CGFloat      y,
    uint32_t     flags
);

// =========================================================================
// Constants / configuration
// =========================================================================

#define MAX_CLIENTS       8
#define SURFACE_POOL_SIZE 2  // double-buffered: daemon writes A while clients read B

// =========================================================================
// Globals
// =========================================================================

static os_log_t gLog;
static CGFloat  gDisplayW = 0, gDisplayH = 0;

// --- IOSurface double-buffer pool ---
// We pre-allocate SURFACE_POOL_SIZE surfaces and round-robin through them.
// The daemon renders into gSurfacePool[gWriteIdx]; on the next frame it
// advances gWriteIdx and renders into the other surface. Clients receive
// the surface ID for the most-recently completed render; they have until
// the NEXT frame to finish reading before the daemon reclaims that slot.
static IOSurfaceRef    gSurfacePool[SURFACE_POOL_SIZE];
static uint32_t        gSurfaceIDs[SURFACE_POOL_SIZE];
static int             gWriteIdx = 0;
static pthread_mutex_t gSurfaceMutex = PTHREAD_MUTEX_INITIALIZER;

// --- Client tracking ---
typedef struct {
    int  fd;      // Socket fd; -1 means this slot is unused
    BOOL active;  // Client has sent kDicoyMsgStartCapture
} DicoyClient;

static DicoyClient     gClients[MAX_CLIENTS];
static int             gActiveCount = 0;
static pthread_mutex_t gClientsMtx = PTHREAD_MUTEX_INITIALIZER;

// =========================================================================
// Forward declarations
// =========================================================================

static BOOL   setupSurfaces(void);
static void * captureLoop(void *arg);
static void * socketServer(void *arg);
static void * handleClient(void *arg);
static void   broadcastFrame(uint32_t surfID, uint16_t w, uint16_t h);
static void   removeClient(int fd);
static int    activeCount(void);

// =========================================================================
// Signal handler – remove the socket file so a fresh daemon start works
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
        gLog = os_log_create("com.dicoy.daemon", "main");
        os_log(gLog, "DiCoyDaemon starting (PID %d)", getpid());

        signal(SIGTERM, onSignal);
        signal(SIGINT,  onSignal);

        // Initialise client table (static globals are zero-init, but fd=0
        // is stdin, so we must explicitly set all fds to the sentinel -1).
        for (int i = 0; i < MAX_CLIENTS; i++) gClients[i].fd = -1;

        // Query native display resolution in physical pixels.
        CGRect nb = [UIScreen mainScreen].nativeBounds;
        gDisplayW = nb.size.width;
        gDisplayH = nb.size.height;
        if (gDisplayW == 0) {
            // Hard-coded fallback (iPhone 12 Pro physical resolution).
            gDisplayW = 1170; gDisplayH = 2532;
            os_log_error(gLog, "CGDisplay query failed, falling back to 1170x2532");
        }
        os_log(gLog, "Display: %.0f x %.0f", gDisplayW, gDisplayH);

        if (!setupSurfaces()) {
            os_log_fault(gLog, "IOSurface pool creation failed – aborting");
            return 1;
        }

        // Socket server runs on a background thread; capture loop on main thread.
        pthread_t serverThread;
        pthread_create(&serverThread, NULL, socketServer, NULL);
        pthread_detach(serverThread);

        captureLoop(NULL);
        return 0;
    }
}

// =========================================================================
// setupSurfaces
//
// Allocates SURFACE_POOL_SIZE IOSurfaces in GPU-shared memory.
//
// Key IOSurface properties:
//   kIOSurfaceIsGlobal  – allows any process to look up the surface by its
//                         integer ID via IOSurfaceLookup(), without needing
//                         a Mach port handoff. This is what makes the
//                         zero-copy cross-process sharing work.
//   kIOSurfacePixelFormat – 0x42475241 == 'BGRA' == kCVPixelFormatType_32BGRA.
//                           CARenderServer produces BGRA; CoreVideo and
//                           AVFoundation expect BGRA for camera-style buffers.
// =========================================================================

static BOOL setupSurfaces(void) {
    int w = (int)gDisplayW, h = (int)gDisplayH;

    NSDictionary *props = @{
        (id)kIOSurfaceWidth:           @(w),
        (id)kIOSurfaceHeight:          @(h),
        (id)kIOSurfaceBytesPerElement: @(4),        // 4 bytes per pixel (BGRA)
        (id)kIOSurfaceBytesPerRow:     @(w * 4),
        (id)kIOSurfaceAllocSize:       @(w * h * 4),
        (id)kIOSurfacePixelFormat:     @(0x42475241), // 'BGRA'
        // kIOSurfaceIsGlobal is the critical flag: it registers the surface in
        // a kernel-level table so that IOSurfaceLookup(id) works from any
        // process on the device, including sandboxed apps running our tweak.
        (id)kIOSurfaceIsGlobal:        @YES,
    };

    for (int i = 0; i < SURFACE_POOL_SIZE; i++) {
        gSurfacePool[i] = IOSurfaceCreate((__bridge CFDictionaryRef)props);
        if (!gSurfacePool[i]) {
            os_log_error(gLog, "IOSurfaceCreate failed for slot %d", i);
            return NO;
        }
        gSurfaceIDs[i] = IOSurfaceGetID(gSurfacePool[i]);
        os_log(gLog, "Surface[%d]: id=%u", i, gSurfaceIDs[i]);
    }
    return YES;
}

// =========================================================================
// captureLoop
//
// The main capture loop. Runs on the process's main thread.
//
// Algorithm:
//  1. Obtain a Mach send-right to CARenderServer via bootstrap.
//  2. Sleep when no clients are connected (battery conservation).
//  3. On each frame deadline, select the next write slot in the pool.
//  4. Lock the IOSurface for GPU write, call CARenderServerRenderDisplay,
//     then unlock.
//  5. Broadcast the surface ID to all active clients over the socket.
//
// Zero-copy explanation:
//  CARenderServerRenderDisplay writes directly into the IOSurface's GPU
//  memory. IOSurfaceLookup() in the tweak process maps the SAME physical
//  memory pages (via the IOSurface kernel object). No bytes are copied at
//  any point in the pipeline; the client just gets a new pointer alias.
// =========================================================================

static void * captureLoop(void *arg) {
    // Look up CARenderServer. This Mach service owns the display compositor.
    mach_port_t renderPort = MACH_PORT_NULL;
    kern_return_t kr = bootstrap_look_up(
        bootstrap_port, "com.apple.CARenderServer", &renderPort
    );
    if (kr != KERN_SUCCESS || renderPort == MACH_PORT_NULL) {
        os_log_fault(gLog, "bootstrap_look_up(CARenderServer) failed: %d", kr);
        return NULL;
    }
    os_log(gLog, "CARenderServer port: %u", renderPort);

    // Nanoseconds per frame for DICOY_TARGET_FPS.
    const uint64_t frameIntervalNs = (uint64_t)(1e9 / DICOY_TARGET_FPS);
    uint64_t lastFrameNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);

    while (1) {
        // --- Battery gate ---
        // When the camera is not open in any app, no client sends
        // kDicoyMsgStartCapture, so activeCount() stays 0. We poll at
        // 10 Hz instead of 30/60 Hz so the daemon is nearly idle.
        if (activeCount() == 0) {
            usleep(100000); // 100 ms
            continue;
        }

        // --- Frame-rate limiter ---
        uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        int64_t remaining = (int64_t)frameIntervalNs - (int64_t)(now - lastFrameNs);
        if (remaining > 0) {
            // Sleep for half the remaining time to avoid overshooting due to
            // usleep's minimum resolution (typically ~50 µs on iOS).
            usleep((useconds_t)(remaining / 2000));
            continue;
        }
        lastFrameNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);

        // --- Select write slot (round-robin) ---
        pthread_mutex_lock(&gSurfaceMutex);
        int slot = gWriteIdx;
        gWriteIdx = (gWriteIdx + 1) % SURFACE_POOL_SIZE;
        pthread_mutex_unlock(&gSurfaceMutex);

        IOSurfaceRef dst = gSurfacePool[slot];

        // --- Lock the surface for write ---
        // IOSurfaceLock with options=0 means "wait until any GPU reader is
        // done before granting write access". This prevents tearing when a
        // client CVPixelBuffer is mid-read on the GPU.
        IOReturn lockRet = IOSurfaceLock(dst, 0, NULL);
        if (lockRet != kIOReturnSuccess) {
            os_log_error(gLog, "IOSurfaceLock failed: 0x%x", lockRet);
            continue;
        }

        // --- Capture the display ---
        // CARenderServerRenderDisplay composites all display layers (app,
        // SpringBoard, status bar, notification overlays, etc.) into `dst`.
        // x=0, y=0 means no pixel offset; flags=0 is synchronous composite.
        kr = CARenderServerRenderDisplay(renderPort, 0, dst, 0.0, 0.0, 0);

        IOSurfaceUnlock(dst, 0, NULL);

        if (kr != KERN_SUCCESS) {
            os_log_error(gLog, "CARenderServerRenderDisplay failed: %d", kr);
            continue;
        }

        // --- Deliver the frame ID to all clients ---
        broadcastFrame(gSurfaceIDs[slot], (uint16_t)gDisplayW, (uint16_t)gDisplayH);
    }

    return NULL;
}

// =========================================================================
// socketServer
//
// Listens on DICOY_SOCKET_PATH and hands each connection to a dedicated
// thread. The thread blocks in recv() waiting for client commands.
// =========================================================================

static void * socketServer(void *arg) {
    unlink(DICOY_SOCKET_PATH); // Remove stale socket from a previous run

    int srvFd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (srvFd < 0) {
        os_log_fault(gLog, "socket(): %s", strerror(errno));
        return NULL;
    }

    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, DICOY_SOCKET_PATH, sizeof(addr.sun_path));

    if (bind(srvFd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        os_log_fault(gLog, "bind(%s): %s", DICOY_SOCKET_PATH, strerror(errno));
        close(srvFd);
        return NULL;
    }

    // 0777 so that sandboxed app processes (different UID/GID from root)
    // can connect. On a rootless jailbreak the path is in /var/jb which is
    // already world-traversable.
    chmod(DICOY_SOCKET_PATH, 0777);

    listen(srvFd, MAX_CLIENTS);
    os_log(gLog, "Listening on %s", DICOY_SOCKET_PATH);

    while (1) {
        int cfd = accept(srvFd, NULL, NULL);
        if (cfd < 0) { continue; }

        // Register in the client table.
        pthread_mutex_lock(&gClientsMtx);
        BOOL registered = NO;
        for (int i = 0; i < MAX_CLIENTS; i++) {
            if (gClients[i].fd < 0) {
                gClients[i].fd = cfd;
                gClients[i].active = NO;
                registered = YES;
                break;
            }
        }
        pthread_mutex_unlock(&gClientsMtx);

        if (!registered) {
            os_log_error(gLog, "Too many clients, rejecting fd=%d", cfd);
            close(cfd);
            continue;
        }

        os_log(gLog, "Client connected (fd=%d)", cfd);

        // Spawn a per-client thread. The fd is heap-allocated so the thread
        // can safely free it after the connection closes.
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
//
// Blocks reading fixed-size DicoyMessage packets from one client. Mutates
// gClients and gActiveCount when the client starts or stops capture, then
// cleans up when the connection drops.
// =========================================================================

static void *handleClient(void *arg) {
    int fd = *(int *)arg;
    free(arg);
    DicoyMessage msg;

    while (1) {
        ssize_t n = recv(fd, &msg, sizeof(msg), MSG_WAITALL);
        if (n != (ssize_t)sizeof(msg)) break; // EOF or error

        if (msg.magic != DICOY_MAGIC) {
            os_log_error(gLog, "fd=%d: bad magic 0x%04x", fd, msg.magic);
            break;
        }

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
                os_log(gLog, "fd=%d: START_CAPTURE (active=%d)", fd, gActiveCount);
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
                os_log(gLog, "fd=%d: STOP_CAPTURE (active=%d)", fd, gActiveCount);
                break;

            case kDicoyMsgPing: {
                DicoyMessage pong = { .magic = DICOY_MAGIC, .type = kDicoyMsgPong };
                send(fd, &pong, sizeof(pong), 0);
                break;
            }

            default:
                os_log_error(gLog, "fd=%d: unknown type 0x%02x", fd, msg.type);
                break;
        }
    }

    os_log(gLog, "Client disconnected (fd=%d)", fd);
    removeClient(fd);
    close(fd);
    return NULL;
}

// =========================================================================
// broadcastFrame
//
// Sends a FRAME_READY message to every active client.
// MSG_DONTWAIT: if a client's socket buffer is full, we skip it (frame
// drop) rather than blocking the capture loop for a slow reader.
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
        if (gClients[i].fd >= 0 && gClients[i].active) {
            send(gClients[i].fd, &msg, sizeof(msg), MSG_DONTWAIT);
        }
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

// =========================================================================
// IOMobileFramebuffer alternative (reference, not used above)
//
// CARenderServerRenderDisplay (used above) composites ALL layers into the
// destination surface. If you only need the raw display hardware buffer
// (without compositor overlays), use IOMobileFramebuffer instead:
//
//   #import <IOKit/IOKitLib.h>
//   typedef struct __IOMobileFramebuffer *IOMobileFramebufferRef;
//   extern IOReturn IOMobileFramebufferOpen(
//       io_service_t service, task_port_t task,
//       uint32_t type, IOMobileFramebufferRef *fb);
//   extern IOReturn IOMobileFramebufferGetLayerDefaultSurface(
//       IOMobileFramebufferRef fb, int layer, IOSurfaceRef *outSurface);
//
//   io_service_t svc = IOServiceGetMatchingService(
//       kIOMasterPortDefault, IOServiceMatching("IOMobileFramebuffer"));
//   IOMobileFramebufferRef fb;
//   IOMobileFramebufferOpen(svc, mach_task_self(), 0, &fb);
//   IOSurfaceRef rawSurface;
//   IOMobileFramebufferGetLayerDefaultSurface(fb, 0, &rawSurface);
//   // rawSurface IS the live framebuffer. Broadcast its ID directly –
//   // no CARenderServerRenderDisplay call needed. Note: this surface
//   // is owned by the display hardware; never call IOSurfaceLock on it
//   // for an extended period or the display will freeze.
//   uint32_t sid = IOSurfaceGetID(rawSurface);
//   broadcastFrame(sid, w, h);
// =========================================================================
