// DiCoyTweak/DiCoyServer.m
//
// Screen-capture server running inside SpringBoard via tweak injection.
//
// CARenderServerRenderDisplay renders the primary display into a local IOSurface
// each frame. The surface is delivered to clients as an ObjC object over
// NSXPCConnection — serialized as a Mach send right, reconstructed on the
// client via IOSurfaceLookupFromMachPort. No IOSurfaceRootUserClient access
// needed on the receiving side.
//
// MachXPCListener registers "com.dicoy.server" via bootstrap_check_in.
// Sandboxed clients are granted bootstrap_look_up access by the Sandy profile's
// mach-lookup extension (com.apple.security.exception.mach-lookup.global-name).

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
// CARenderServerRenderDisplay — merged into QuartzCore on iOS 15+
// =========================================================================

// Second argument is a CFStringRef display name.
// Passing NULL returns KERN_SUCCESS but renders blank.
// Call CARenderServerCopyDisplayList() to discover valid names at runtime.
typedef kern_return_t (*CARSRenderDisplay_t)(mach_port_t  port,
                                             CFStringRef  displayName,
                                             IOSurfaceRef surface,
                                             int          flags);

// Returns a CFArray of CFString display names (iOS 13+).
typedef CFArrayRef (*CARSCopyDisplayList_t)(void);

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
// XPC listener delegate — implements NSXPCListenerDelegate + DiCoyXPCServer
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

// DiCoyXPCServer — called from the client over XPC

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
// CADisplayLink target — runs on the main thread
// =========================================================================

@interface DiCoyCaptureTarget : NSObject
@property (nonatomic, assign) CARSRenderDisplay_t renderFn;
@property (nonatomic, assign) int                 failCount;
@property (nonatomic, strong) NSString           *displayName; // nil → pass NULL to renderFn
@end

@implementation DiCoyCaptureTarget

- (void)tick:(CADisplayLink *)link {
    if (srvActiveCount() == 0) return;
    if (!gSurface)             return;

    CFStringRef dname = (__bridge CFStringRef)self.displayName;
    kern_return_t kr = self.renderFn(0, dname, gSurface, 0);
    if (kr != 0) {
        self.failCount++;
        if (self.failCount % 30 == 1)
            srvLog("CARenderServerRenderDisplay fail #%d: 0x%x (displayName=%s)",
                   self.failCount, (unsigned)kr,
                   self.displayName.UTF8String ?: "NULL");
        return;
    }

    if (self.failCount > 0) {
        srvLog("CARenderServerRenderDisplay recovered after %d failures", self.failCount);
        self.failCount = 0;
    }

    static BOOL sFirstFrame = YES;
    if (sFirstFrame) {
        sFirstFrame = NO;
        // Sample a grid of pixels to avoid false negative from black screen corners.
        IOSurfaceLock(gSurface, kIOSurfaceLockReadOnly, NULL);
        uint8_t *px  = (uint8_t *)IOSurfaceGetBaseAddress(gSurface);
        size_t   bpr = IOSurfaceGetBytesPerRow(gSurface);
        BOOL hasContent = NO;
        if (px) {
            for (int row = 0; row < (int)gSurfaceH && !hasContent; row += 50) {
                for (int col = 0; col < (int)gSurfaceW && !hasContent; col += 50) {
                    uint8_t *p = px + row * bpr + col * 4;
                    hasContent = p[0] || p[1] || p[2];
                }
            }
        }
        IOSurfaceUnlock(gSurface, kIOSurfaceLockReadOnly, NULL);
        srvLog("First frame: %ux%u displayName=%s bpr=%zu surface=%s",
               gSurfaceW, gSurfaceH,
               self.displayName.UTF8String ?: "NULL",
               bpr,
               hasContent ? "HAS CONTENT" : "IS BLACK");
    }

    // Snapshot sActive under lock, then iterate outside.
    pthread_mutex_lock(&sClientsMtx);
    NSArray *activeSnapshot = [sActive allObjects];
    pthread_mutex_unlock(&sClientsMtx);

    id surfObj = (__bridge id)gSurface;
    for (NSXPCConnection *conn in activeSnapshot) {
        [[conn remoteObjectProxyWithErrorHandler:^(NSError *err) {
            srvLog("XPC send error: %s", err.localizedDescription.UTF8String);
        }] receiveFrame:surfObj width:gSurfaceW height:gSurfaceH];
    }
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

    // Register the Mach service name via bootstrap_check_in.
    // Dopamine 2's patched launchd allows arbitrary check-in from SpringBoard.
    // Sandy mach-lookup extension grants sandboxed clients bootstrap_look_up access.
    sListenerDelegate = [DiCoyXPCListenerDelegate new];
    sXPCListener = [[MachXPCListener alloc] initWithObject:sListenerDelegate
                                                identifier:@DICOY_XPC_SERVICE_NAME];
    if (sXPCListener) {
        [sXPCListener resume];
        srvLog("MachXPCListener registered: %s", DICOY_XPC_SERVICE_NAME);
    } else {
        srvLog("MachXPCListener bootstrap_check_in FAILED — screen mirror unavailable");
    }

    // Display capture setup must run on the main thread.
    dispatch_async(dispatch_get_main_queue(), ^{

        // 1. Locate CARenderServerRenderDisplay (merged into QuartzCore on iOS 15+).
        CARSRenderDisplay_t renderFn =
            (CARSRenderDisplay_t)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
        srvLog("CARenderServerRenderDisplay = %s", renderFn ? "FOUND" : "NOT FOUND");

        if (!renderFn) {
            srvLog("ABORT: CARenderServerRenderDisplay absent");
            return;
        }

        // 2. Create the destination IOSurface (local; delivered to clients via XPC).
        CGRect native = [UIScreen mainScreen].nativeBounds;
        uint16_t w = (uint16_t)native.size.width;
        uint16_t h = (uint16_t)native.size.height;
        srvLog("Display native: %ux%u", w, h);

        CFMutableDictionaryRef props = CFDictionaryCreateMutable(
            kCFAllocatorDefault, 0,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(props, kIOSurfaceWidth,           (__bridge CFNumberRef)@(w));
        CFDictionarySetValue(props, kIOSurfaceHeight,          (__bridge CFNumberRef)@(h));
        CFDictionarySetValue(props, kIOSurfacePixelFormat,     (__bridge CFNumberRef)@(0x42475241)); // 'BGRA'
        CFDictionarySetValue(props, kIOSurfaceBytesPerElement, (__bridge CFNumberRef)@(4));

        gSurface = IOSurfaceCreate(props);
        CFRelease(props);

        if (!gSurface) {
            srvLog("ABORT: IOSurfaceCreate failed");
            return;
        }

        gSurfaceW = w;
        gSurfaceH = h;
        srvLog("IOSurface created: %p %ux%u bpr=%zu",
               (void *)gSurface, w, h, IOSurfaceGetBytesPerRow(gSurface));

        // 3. Discover the display name for CARenderServerRenderDisplay.
        //    CARenderServerCopyDisplayList returns a CFArray of valid CFString names.
        //    If absent, probe known candidate strings and log all results.
        NSString *displayName = nil;
        {
            CARSCopyDisplayList_t copyFn =
                (CARSCopyDisplayList_t)dlsym(RTLD_DEFAULT, "CARenderServerCopyDisplayList");
            if (copyFn) {
                CFArrayRef list = copyFn();
                if (list) {
                    CFIndex count = CFArrayGetCount(list);
                    srvLog("CARenderServerCopyDisplayList: %ld entries", (long)count);
                    for (CFIndex i = 0; i < count; i++) {
                        CFStringRef s = (CFStringRef)CFArrayGetValueAtIndex(list, i);
                        char buf[128] = {0};
                        CFStringGetCString(s, buf, sizeof(buf), kCFStringEncodingUTF8);
                        srvLog("  display[%ld] = '%s'", (long)i, buf);
                    }
                    if (count > 0) {
                        displayName = (__bridge_transfer NSString *)CFRetain(
                            CFArrayGetValueAtIndex(list, 0));
                    }
                    CFRelease(list);
                } else {
                    srvLog("CARenderServerCopyDisplayList: returned nil");
                }
            } else {
                srvLog("CARenderServerCopyDisplayList: symbol not found — probing candidates");
            }

            // If display list didn't give us a name, probe known candidates.
            // Log every result so we know exactly which names the OS accepts.
            if (!displayName) {
                NSArray<NSString*> *candidates = @[
                    @"LCD", @"lcd", @"CLCD", @"clcd",
                    @"IDP0", @"ColorLCD", @"", @"built-in"
                ];
                for (NSString *name in candidates) {
                    CFStringRef cfName = (__bridge CFStringRef)name;
                    kern_return_t kr = renderFn(0, cfName, gSurface, 0);
                    srvLog("Probe '%s': 0x%x %s",
                           name.UTF8String, (unsigned)kr,
                           kr == KERN_SUCCESS ? "(KERN_SUCCESS)" : "(KERN_FAILURE)");
                    if (kr == KERN_SUCCESS && !displayName) {
                        displayName = name;
                    }
                }
                // Always probe NULL to see its return code too.
                kern_return_t krNull = renderFn(0, NULL, gSurface, 0);
                srvLog("Probe NULL: 0x%x %s",
                       (unsigned)krNull,
                       krNull == KERN_SUCCESS ? "(KERN_SUCCESS)" : "(KERN_FAILURE)");
            }

            srvLog("Selected displayName: %s",
                   displayName.UTF8String ?: "NULL (may render blank)");
        }

        // 4. Drive frame capture via CADisplayLink.
        sCaptureTarget             = [DiCoyCaptureTarget new];
        sCaptureTarget.renderFn    = renderFn;
        sCaptureTarget.failCount   = 0;
        sCaptureTarget.displayName = displayName;

        sDisplayLink = [CADisplayLink displayLinkWithTarget:sCaptureTarget
                                                   selector:@selector(tick:)];
        sDisplayLink.preferredFramesPerSecond = DICOY_TARGET_FPS;
        [sDisplayLink addToRunLoop:[NSRunLoop mainRunLoop]
                           forMode:NSRunLoopCommonModes];

        srvLog("CADisplayLink started at %d fps", DICOY_TARGET_FPS);
    });
}
