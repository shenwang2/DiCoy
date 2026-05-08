// DiCoyTweak/DiCoyClient.m
//
// NSXPCConnection client to the SpringBoard-hosted DiCoy server.
// Connects via MachXPC (bootstrap_look_up), sends startCapture/stopCapture,
// and receives IOSurface frames via receiveFrame:width:height:.
//
// IOSurface is transferred as an ObjC object over XPC — internally
// serialized as a Mach send right. No IOSurfaceRootUserClient access needed.

#import "DiCoyClient.h"
#import "MachXPCConnection.h"
#import <os/log.h>
#import <QuartzCore/QuartzCore.h>

static os_log_t gClientLog;

// Returns a once-initialized NSXPCInterface for DiCoyXPCClient that whitelists
// IOSurface as a serializable argument to receiveFrame:width:height:.
// Must be set on BOTH ends of the connection (server's remoteObjectInterface
// and client's exportedInterface) for NSXPCConnection to accept the class.
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

@implementation DiCoyClient {
    NSXPCConnection *_conn;
    BOOL             _connected;
    BOOL             _capturing;
}

+ (void)initialize {
    if (self == [DiCoyClient class]) {
        gClientLog = os_log_create("com.dicoy.tweak", "client");
    }
}

// Attempts to connect via MachXPC with a 5-second Mach-message timeout.
// Safe to call from any queue; blocks the calling thread during handshake.
- (BOOL)connect {
    if (_connected) return YES;

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block BOOL success = NO;

    [MachXPCConnection connectionFromMachXPCListener:@DICOY_XPC_SERVICE_NAME
                                   qualityOfService:QOS_CLASS_USER_INTERACTIVE
                       shouldCallHandlerInMainQueue:NO
                                  connectionHandler:^(NSXPCConnection *conn) {
        if (!conn) {
            os_log_error(gClientLog, "MachXPCConnection: bootstrap_look_up failed or timeout");
            dispatch_semaphore_signal(sema);
            return;
        }

        conn.exportedInterface = DiCoyClientInterface();
        conn.exportedObject    = self;
        conn.remoteObjectInterface =
            [NSXPCInterface interfaceWithProtocol:@protocol(DiCoyXPCServer)];

        conn.invalidationHandler = ^{
            os_log(gClientLog, "XPC connection invalidated");
            self->_connected = NO;
            self->_capturing = NO;
            self->_conn      = nil;
        };
        conn.interruptionHandler = ^{
            os_log(gClientLog, "XPC connection interrupted");
        };

        [conn resume];

        self->_conn      = conn;
        self->_connected = YES;
        success          = YES;
        dispatch_semaphore_signal(sema);
    }];

    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC);
    dispatch_semaphore_wait(sema, deadline);

    if (success) {
        os_log(gClientLog, "Connected to %s", DICOY_XPC_SERVICE_NAME);
    }
    return success;
}

- (void)disconnect {
    if (!_connected) return;
    [_conn invalidate];
    _conn      = nil;
    _connected = NO;
    _capturing = NO;
}

- (void)startCapture {
    if (_capturing || !_conn) return;
    _capturing = YES;
    [[_conn remoteObjectProxy] startCapture];
    os_log(gClientLog, "startCapture sent");
}

- (void)stopCapture {
    if (!_capturing || !_conn) return;
    _capturing = NO;
    [[_conn remoteObjectProxy] stopCapture];
}

// DiCoyXPCClient — called on the XPC queue each time the server sends a frame.
- (oneway void)receiveFrame:(id)surface width:(uint32_t)w height:(uint32_t)h {
    IOSurfaceRef surf = (__bridge IOSurfaceRef)surface;
    if (!surf) return;

    static BOOL sLogged = NO;
    if (!sLogged) {
        sLogged = YES;
        [[NSString stringWithFormat:@"ok:xpc w=%u h=%u", w, h]
         writeToFile:@"/var/tmp/dicoy_surf.txt"
         atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }

    DiCoyFrameCallback cb = self.frameCallback;
    if (cb) cb(surf, (uint16_t)w, (uint16_t)h);
}

- (BOOL)isConnected { return _connected; }

// Rate-limited reconnect — dispatched to a background queue so camera callback
// queues are never blocked by the 5-second Mach handshake timeout.
- (void)reconnectIfNeeded {
    if (_connected) return;
    static CFTimeInterval sLastAttempt = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - sLastAttempt < 3.0) return;
    sLastAttempt = now;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (self->_connected) return;
        if ([self connect]) {
            self->_capturing = NO;
            [self startCapture];
        }
    });
}

- (void)dealloc {
    [self disconnect];
}

@end
