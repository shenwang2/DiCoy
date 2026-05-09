// DiCoyTweak/DiCoyServer.m
//
// Screen-capture server running inside SpringBoard via tweak injection.
//
// Capture pipeline (tried in order):
//   1. CARenderServerRenderDisplay(serverPort, "LCD", gSurface, 0)
//      Renders the live compositor output into a pre-allocated IOSurface.
//      Requires com.apple.private.coreanimation.render-server entitlement and the
//      real render server Mach port (not 0).
//
//   2. CARenderServerCaptureDisplay(serverPort, "LCD", 0)
//      Returns a new IOSurfaceRef snapshot each call. Used if (1) keeps failing.
//
//   3. CARenderServerCreateSnapshots(serverPort, [@"LCD"], 0)
//      Returns a CFArray of IOSurfaceRef snapshots. Last resort if (2) not found.
//
// The selected IOSurface is delivered to clients as an ObjC object over
// NSXPCConnection — serialized as a Mach send right. No IOSurfaceRootUserClient
// access needed on the receiving side.
//
// kIOSurfaceIsGlobal is required so CARenderServerRenderDisplay (render server
// process) can call IOSurfaceLookup(id) to map the surface for writing.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurfaceRef.h>
#import <pthread.h>
#import <unistd.h>
#import <stdarg.h>
#import <os/log.h>
#import <dlfcn.h>
#import "DiCoyProtocol.h"
#import "DiCoyXPCProtocol.h"
#import "MachXPCListener.h"

// =========================================================================
// Private CARenderServer function types
// =========================================================================

// Renders the named display into an existing IOSurface.
typedef kern_return_t (*CARSRenderDisplay_t)(mach_port_t  serverPort,
                                             CFStringRef  displayName,
                                             IOSurfaceRef surface,
                                             int          flags);

// Returns a new IOSurfaceRef snapshot (caller must CFRelease), or NULL on error.
typedef IOSurfaceRef  (*CARSCaptureDisplay_t)(mach_port_t serverPort,
                                              CFStringRef displayName,
                                              int         flags);

// Returns a CFArray of IOSurfaceRef snapshots (one per displayNames entry).
typedef CFArrayRef    (*CARSCreateSnapshots_t)(mach_port_t serverPort,
                                               CFArrayRef  displayNames, // CFArray<CFString>
                                               int         flags);

// Enumerates available display names.
typedef CFArrayRef    (*CARSCopyDisplayList_t)(void);

// Render server Mach port accessors.
typedef mach_port_t   (*CARSGetServerPort_t)(uint32_t displayID); // displayID 0 = primary
typedef mach_port_t   (*CARSGetPort_t)(void);

// =========================================================================
// NSXPCInterface helper — whitelists IOSurface for receiveFrame:width:height:
// Must match DiCoyClientInterface() in DiCoyClient.m exactly.
// =========================================================================

static NSXPCInterface *DiCoyClientInterface(void) {
    static NSXPCInterface *iface;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        iface = [NSXPCInterface interfaceWithProtocol:@protocol(DiCoyXPCClient)];
        NSSet *classes = [NSSet setWithObject:NSClassFromString(@"IOSurface")];
        [iface setClasses:classes
              forSelector:@selector(receiveFrame:width:height:)
           argumentIndex:0
                 ofReply:NO];
    });
    return iface;
}

// =========================================================================
// Globals
// =========================================================================

static os_log_t              sSrvLog;
static NSMutableSet         *sConnections; // all accepted NSXPCConnections
static NSMutableSet         *sActive;      // connections that sent startCapture
static pthread_mutex_t       sClientsMtx  = PTHREAD_MUTEX_INITIALIZER;

// Pre-allocated surface for CARenderServerRenderDisplay mode.
// NULL when using capture mode (CARenderServerCaptureDisplay / CreateSnapshots).
static IOSurfaceRef          gSurface  = NULL;
static uint16_t              gSurfaceW = 0;
static uint16_t              gSurfaceH = 0;

// =========================================================================
// Diagnostic writer
// =========================================================================

static void srvLog(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    char buf[512]; vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    FILE *f = fopen("/var/tmp/dicoy_server.txt", "a");
    if (f) { fprintf(f, "%s\n", buf); fclose(f); }
    os_log(sSrvLog, "%{public}s", buf);
}

static int srvActiveCount(void) {
    pthread_mutex_lock(&sClientsMtx);
    int n = (int)sActive.count;
    pthread_mutex_unlock(&sClientsMtx);
    return n;
}

// =========================================================================
// XPC listener delegate
// =========================================================================

@interface DiCoyXPCListenerDelegate : NSObject <NSXPCListenerDelegate, DiCoyXPCServer>
@end

@implementation DiCoyXPCListenerDelegate

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)conn {
    conn.exportedInterface     = [NSXPCInterface interfaceWithProtocol:@protocol(DiCoyXPCServer)];
    conn.exportedObject        = self;
    conn.remoteObjectInterface = DiCoyClientInterface();

    NSXPCConnection * __weak weakConn = conn;
    conn.invalidationHandler = ^{
        NSXPCConnection *c = weakConn;
        if (!c) return;
        pthread_mutex_lock(&sClientsMtx);
        [sConnections removeObject:c];
        [sActive      removeObject:c];
        pthread_mutex_unlock(&sClientsMtx);
        srvLog("XPC client disconnected — active=%d", srvActiveCount());
    };

    [conn resume];

    pthread_mutex_lock(&sClientsMtx);
    [sConnections addObject:conn];
    pthread_mutex_unlock(&sClientsMtx);

    srvLog("XPC client connected");
    return YES;
}

- (oneway void)startCapture {
    NSXPCConnection *conn = [NSXPCConnection currentConnection];
    pthread_mutex_lock(&sClientsMtx);
    [sActive addObject:conn];
    int n = (int)sActive.count;
    pthread_mutex_unlock(&sClientsMtx);
    srvLog("startCapture — active=%d", n);
}

- (oneway void)stopCapture {
    NSXPCConnection *conn = [NSXPCConnection currentConnection];
    pthread_mutex_lock(&sClientsMtx);
    [sActive removeObject:conn];
    int n = (int)sActive.count;
    pthread_mutex_unlock(&sClientsMtx);
    srvLog("stopCapture — active=%d", n);
}

@end

// =========================================================================
// Capture mode selector
// =========================================================================

typedef NS_ENUM(NSInteger, DiCoyCaptureMode) {
    DiCoyCaptureModeRender,          // CARenderServerRenderDisplay → gSurface
    DiCoyCaptureModeCapture,         // CARenderServerCaptureDisplay → new IOSurfaceRef/tick
    DiCoyCaptureModeSnapshots,       // CARenderServerCreateSnapshots → new IOSurfaceRef/tick
};

// =========================================================================
// CADisplayLink target — runs on the main thread
// =========================================================================

@interface DiCoyCaptureTarget : NSObject
@property (nonatomic, assign) DiCoyCaptureMode    mode;
@property (nonatomic, assign) CARSRenderDisplay_t  renderFn;
@property (nonatomic, assign) CARSCaptureDisplay_t captureFn;
@property (nonatomic, assign) CARSCreateSnapshots_t snapshotsFn;
@property (nonatomic, assign) mach_port_t          serverPort;
@property (nonatomic, assign) int                  failCount;
@property (nonatomic, strong) NSString            *displayName;
@end

@implementation DiCoyCaptureTarget

- (void)tick:(CADisplayLink *)link {
    if (srvActiveCount() == 0) return;

    IOSurfaceRef frame = NULL;
    BOOL ownsFrame = NO; // YES when we must CFRelease after delivery

    switch (self.mode) {
        case DiCoyCaptureModeRender: {
            if (!gSurface) return;
            kern_return_t kr = self.renderFn(self.serverPort,
                                              (__bridge CFStringRef)self.displayName,
                                              gSurface, 0);
            if (kr != 0) {
                self.failCount++;
                if (self.failCount % 30 == 1)
                    srvLog("RenderDisplay fail #%d: 0x%x", self.failCount, (unsigned)kr);
                return;
            }
            frame = gSurface;
            break;
        }
        case DiCoyCaptureModeCapture: {
            frame = self.captureFn(self.serverPort,
                                    (__bridge CFStringRef)self.displayName, 0);
            if (!frame) {
                self.failCount++;
                if (self.failCount % 30 == 1)
                    srvLog("CaptureDisplay fail #%d (nil surface)", self.failCount);
                return;
            }
            ownsFrame = YES;
            break;
        }
        case DiCoyCaptureModeSnapshots: {
            CFArrayRef snaps = self.snapshotsFn(self.serverPort,
                                                 (__bridge CFArrayRef)@[self.displayName], 0);
            if (!snaps || CFArrayGetCount(snaps) == 0) {
                self.failCount++;
                if (self.failCount % 30 == 1)
                    srvLog("CreateSnapshots fail #%d", self.failCount);
                if (snaps) CFRelease(snaps);
                return;
            }
            frame = (IOSurfaceRef)CFRetain(CFArrayGetValueAtIndex(snaps, 0));
            CFRelease(snaps);
            ownsFrame = YES;
            break;
        }
    }

    if (self.failCount > 0) {
        srvLog("Capture recovered after %d failures", self.failCount);
        self.failCount = 0;
    }

    static BOOL sFirstFrame = YES;
    if (sFirstFrame) {
        sFirstFrame = NO;
        // Grid-sample to avoid false "IS BLACK" from dark corners.
        IOSurfaceLock(frame, kIOSurfaceLockReadOnly, NULL);
        uint8_t *px  = (uint8_t *)IOSurfaceGetBaseAddress(frame);
        size_t   bpr = IOSurfaceGetBytesPerRow(frame);
        size_t   fw  = IOSurfaceGetWidth(frame);
        size_t   fh  = IOSurfaceGetHeight(frame);
        BOOL hasContent = NO;
        if (px) {
            for (size_t row = 0; row < fh && !hasContent; row += 50) {
                for (size_t col = 0; col < fw && !hasContent; col += 50) {
                    uint8_t *p = px + row * bpr + col * 4;
                    hasContent = p[0] || p[1] || p[2];
                }
            }
        }
        IOSurfaceUnlock(frame, kIOSurfaceLockReadOnly, NULL);
        const char *modeStr[] = { "render", "capture", "snapshots" };
        srvLog("First frame: %zux%zu mode=%s port=0x%x displayName=%s bpr=%zu surface=%s",
               fw, fh,
               modeStr[self.mode],
               self.serverPort,
               self.displayName.UTF8String ?: "NULL",
               bpr,
               hasContent ? "HAS CONTENT" : "IS BLACK");
    }

    // Deliver to active clients.
    uint32_t fw = (uint32_t)IOSurfaceGetWidth(frame);
    uint32_t fh = (uint32_t)IOSurfaceGetHeight(frame);

    pthread_mutex_lock(&sClientsMtx);
    NSArray *activeSnapshot = [sActive allObjects];
    pthread_mutex_unlock(&sClientsMtx);

    id surfObj = (__bridge id)frame;
    for (NSXPCConnection *conn in activeSnapshot) {
        [[conn remoteObjectProxyWithErrorHandler:^(NSError *err) {
            srvLog("XPC send error: %s", err.localizedDescription.UTF8String);
        }] receiveFrame:surfObj width:fw height:fh];
    }

    // XPC copies the Mach send right before this returns, so it is safe to
    // release the local IOSurfaceRef now — the kernel keeps the surface alive
    // until the client's send right is consumed.
    if (ownsFrame) CFRelease(frame);
}

@end

// =========================================================================
// Public entry point
// =========================================================================

static DiCoyXPCListenerDelegate *sListenerDelegate;
static MachXPCListener          *sXPCListener;
static DiCoyCaptureTarget       *sCaptureTarget;
static CADisplayLink            *sDisplayLink;

void diCoyServerStart(void) {
    sSrvLog = os_log_create("com.dicoy.server", "springboard");

    FILE *f = fopen("/var/tmp/dicoy_server.txt", "w");
    if (f) { fprintf(f, "DiCoyServer start PID=%d\n", getpid()); fclose(f); }

    pthread_mutex_init(&sClientsMtx, NULL);
    sConnections = [NSMutableSet set];
    sActive      = [NSMutableSet set];

    sListenerDelegate = [DiCoyXPCListenerDelegate new];
    sXPCListener = [[MachXPCListener alloc] initWithObject:sListenerDelegate
                                                identifier:@DICOY_XPC_SERVICE_NAME];
    if (sXPCListener) {
        [sXPCListener resume];
        srvLog("MachXPCListener registered: %s", DICOY_XPC_SERVICE_NAME);
    } else {
        srvLog("MachXPCListener bootstrap_check_in FAILED");
    }

    dispatch_async(dispatch_get_main_queue(), ^{

        // ── 1. Locate render/capture symbols ──────────────────────────────

        CARSRenderDisplay_t renderFn =
            (CARSRenderDisplay_t)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
        CARSCaptureDisplay_t captureFn =
            (CARSCaptureDisplay_t)dlsym(RTLD_DEFAULT, "CARenderServerCaptureDisplay");
        CARSCreateSnapshots_t snapshotsFn =
            (CARSCreateSnapshots_t)dlsym(RTLD_DEFAULT, "CARenderServerCreateSnapshots");

        srvLog("CARenderServerRenderDisplay   = %s", renderFn    ? "FOUND" : "absent");
        srvLog("CARenderServerCaptureDisplay  = %s", captureFn   ? "FOUND" : "absent");
        srvLog("CARenderServerCreateSnapshots = %s", snapshotsFn ? "FOUND" : "absent");

        if (!renderFn && !captureFn && !snapshotsFn) {
            srvLog("ABORT: no CARenderServer capture symbol found");
            return;
        }

        // ── 2. Obtain the render server Mach port ─────────────────────────
        //    Passing 0 results in KERN_FAILURE for live displays. The correct
        //    port is required so the render server can accept our request.

        mach_port_t serverPort = 0;
        {
            CARSGetServerPort_t getServerPortFn =
                (CARSGetServerPort_t)dlsym(RTLD_DEFAULT, "CARenderServerGetServerPort");
            CARSGetPort_t getPortFn =
                (CARSGetPort_t)dlsym(RTLD_DEFAULT, "CARenderServerGetPort");

            if (getServerPortFn) {
                serverPort = getServerPortFn(0); // 0 = primary display
                srvLog("CARenderServerGetServerPort(0) = 0x%x", serverPort);
            } else if (getPortFn) {
                serverPort = getPortFn();
                srvLog("CARenderServerGetPort() = 0x%x", serverPort);
            } else {
                srvLog("No render server port function found — port = 0 (likely KERN_FAILURE)");
            }
        }

        // ── 3. Enumerate available display names ──────────────────────────

        CARSCopyDisplayList_t copyListFn =
            (CARSCopyDisplayList_t)dlsym(RTLD_DEFAULT, "CARenderServerCopyDisplayList");
        if (copyListFn) {
            CFArrayRef list = copyListFn();
            if (list) {
                CFIndex n = CFArrayGetCount(list);
                srvLog("CARenderServerCopyDisplayList: %ld entries", (long)n);
                for (CFIndex i = 0; i < n; i++) {
                    char buf[128] = {0};
                    CFStringGetCString((CFStringRef)CFArrayGetValueAtIndex(list, i),
                                      buf, sizeof(buf), kCFStringEncodingUTF8);
                    srvLog("  display[%ld] = '%s'", (long)i, buf);
                }
                CFRelease(list);
            }
        } else {
            srvLog("CARenderServerCopyDisplayList: not found");
        }

        // ── 4. Create IOSurface for RenderDisplay mode ────────────────────
        //    kIOSurfaceIsGlobal lets the render server process call
        //    IOSurfaceLookup(id) to map the surface for writing.

        CGRect native = [UIScreen mainScreen].nativeBounds;
        uint16_t w = (uint16_t)native.size.width;
        uint16_t h = (uint16_t)native.size.height;
        srvLog("Display native: %ux%u", w, h);

        if (renderFn) {
            CFMutableDictionaryRef props = CFDictionaryCreateMutable(
                kCFAllocatorDefault, 0,
                &kCFTypeDictionaryKeyCallBacks,
                &kCFTypeDictionaryValueCallBacks);
            CFDictionarySetValue(props, kIOSurfaceWidth,           (__bridge CFNumberRef)@(w));
            CFDictionarySetValue(props, kIOSurfaceHeight,          (__bridge CFNumberRef)@(h));
            CFDictionarySetValue(props, kIOSurfacePixelFormat,     (__bridge CFNumberRef)@(0x42475241)); // 'BGRA'
            CFDictionarySetValue(props, kIOSurfaceBytesPerElement, (__bridge CFNumberRef)@(4));
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            CFDictionarySetValue(props, kIOSurfaceIsGlobal, kCFBooleanTrue);
#pragma clang diagnostic pop

            gSurface = IOSurfaceCreate(props);
            CFRelease(props);

            if (gSurface) {
                gSurfaceW = w; gSurfaceH = h;
                srvLog("IOSurface created: %p id=%u %ux%u bpr=%zu",
                       (void *)gSurface, IOSurfaceGetID(gSurface), w, h,
                       IOSurfaceGetBytesPerRow(gSurface));
            } else {
                srvLog("IOSurfaceCreate failed — RenderDisplay mode disabled");
            }
        }

        // ── 5. Probe display names and select best capture mode ───────────
        //    Priority: RenderDisplay("LCD") > CaptureDisplay("LCD") >
        //              CreateSnapshots("LCD") > same with "CLCD" fallback.

        NSString *displayName = nil;
        DiCoyCaptureMode captureMode = DiCoyCaptureModeRender;

        NSArray<NSString*> *candidates = @[@"LCD", @"CLCD", @"lcd"];

        for (NSString *name in candidates) {
            CFStringRef cfName = (__bridge CFStringRef)name;

            // Try RenderDisplay first (renders into pre-allocated gSurface).
            if (renderFn && gSurface) {
                kern_return_t kr = renderFn(serverPort, cfName, gSurface, 0);
                srvLog("RenderDisplay probe '%s' port=0x%x: 0x%x (%s)",
                       name.UTF8String, serverPort, (unsigned)kr,
                       kr == KERN_SUCCESS ? "OK" : "FAIL");
                if (kr == KERN_SUCCESS) {
                    displayName   = name;
                    captureMode   = DiCoyCaptureModeRender;
                    break;
                }
            }

            // Try CaptureDisplay (returns new IOSurfaceRef each call).
            if (captureFn) {
                IOSurfaceRef s = captureFn(serverPort, cfName, 0);
                srvLog("CaptureDisplay probe '%s' port=0x%x: %s",
                       name.UTF8String, serverPort, s ? "got surface" : "nil");
                if (s) {
                    CFRelease(s);
                    displayName = name;
                    captureMode = DiCoyCaptureModeCapture;
                    break;
                }
            }

            // Try CreateSnapshots (returns CFArray of IOSurfaceRef).
            if (snapshotsFn) {
                CFArrayRef snaps = snapshotsFn(serverPort,
                                               (__bridge CFArrayRef)@[name], 0);
                BOOL got = snaps && CFArrayGetCount(snaps) > 0;
                srvLog("CreateSnapshots probe '%s' port=0x%x: %s",
                       name.UTF8String, serverPort, got ? "got snapshot" : "nil/empty");
                if (snaps) CFRelease(snaps);
                if (got) {
                    displayName = name;
                    captureMode = DiCoyCaptureModeSnapshots;
                    break;
                }
            }
        }

        const char *modeStr[] = { "render", "capture", "snapshots" };
        srvLog("Selected: mode=%s displayName=%s",
               displayName ? modeStr[captureMode] : "NONE",
               displayName.UTF8String ?: "(all probes failed — expect black)");

        // ── 6. Drive frame capture via CADisplayLink ──────────────────────

        sCaptureTarget              = [DiCoyCaptureTarget new];
        sCaptureTarget.mode         = captureMode;
        sCaptureTarget.renderFn     = renderFn;
        sCaptureTarget.captureFn    = captureFn;
        sCaptureTarget.snapshotsFn  = snapshotsFn;
        sCaptureTarget.serverPort   = serverPort;
        sCaptureTarget.failCount    = 0;
        sCaptureTarget.displayName  = displayName; // nil → first tick will log fails

        sDisplayLink = [CADisplayLink displayLinkWithTarget:sCaptureTarget
                                                   selector:@selector(tick:)];
        sDisplayLink.preferredFramesPerSecond = DICOY_TARGET_FPS;
        [sDisplayLink addToRunLoop:[NSRunLoop mainRunLoop]
                           forMode:NSRunLoopCommonModes];

        srvLog("CADisplayLink started at %d fps", DICOY_TARGET_FPS);
    });
}
