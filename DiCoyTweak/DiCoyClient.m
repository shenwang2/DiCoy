// DiCoyTweak/DiCoyClient.m
//
// Manages the persistent connection to DiCoyDaemon. Runs a blocking read
// loop on a private queue so it never blocks an app's main thread or camera
// callback queue. When a FRAME_READY message arrives, it looks up the
// IOSurface by ID (zero-copy) and invokes the registered frameCallback.

#import "DiCoyClient.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <os/log.h>

static os_log_t gClientLog;

@implementation DiCoyClient {
    int              _fd;
    BOOL             _connected;
    BOOL             _capturing;
    dispatch_queue_t _readQueue;
}

+ (void)initialize {
    if (self == [DiCoyClient class]) {
        gClientLog = os_log_create("com.dicoy.tweak", "client");
    }
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _fd = -1;
        _readQueue = dispatch_queue_create("com.dicoy.tweak.readloop", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)connect {
    if (_connected) return YES;

    _fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (_fd < 0) {
        os_log_error(gClientLog, "socket(): %s", strerror(errno));
        return NO;
    }

    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, DICOY_SOCKET_PATH, sizeof(addr.sun_path));

    if (connect(_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        os_log_error(gClientLog, "connect(%s): %s", DICOY_SOCKET_PATH, strerror(errno));
        close(_fd);
        _fd = -1;
        return NO;
    }

    _connected = YES;
    os_log(gClientLog, "Connected to daemon");
    [self startReadLoop];
    return YES;
}

- (void)disconnect {
    if (!_connected) return;
    _connected = NO;
    _capturing = NO;
    close(_fd);
    _fd = -1;
}

- (void)sendType:(DicoyMessageType)type {
    if (_fd < 0) return;
    DicoyMessage msg = { .magic = DICOY_MAGIC, .type = (uint8_t)type };
    send(_fd, &msg, sizeof(msg), 0);
}

- (void)startCapture {
    if (_capturing) return;
    _capturing = YES;
    [self sendType:kDicoyMsgStartCapture];
}

- (void)stopCapture {
    if (!_capturing) return;
    _capturing = NO;
    [self sendType:kDicoyMsgStopCapture];
}

// Spawns the blocking read loop on _readQueue.
// The loop terminates when the socket closes or returns an error.
- (void)startReadLoop {
    int fd = _fd;
    __weak typeof(self) weak = self;

    dispatch_async(_readQueue, ^{
        DicoyMessage msg;

        while (weak.isConnected) {
            // MSG_WAITALL: block until all sizeof(msg) bytes arrive.
            ssize_t n = recv(fd, &msg, sizeof(msg), MSG_WAITALL);
            if (n != (ssize_t)sizeof(msg)) break;
            if (msg.magic != DICOY_MAGIC) continue;

            if ((DicoyMessageType)msg.type == kDicoyMsgFrameReady) {
                // -------------------------------------------------------
                // Zero-copy surface lookup.
                //
                // The daemon sent only a 4-byte IOSurfaceID. We call
                // IOSurfaceLookup() which resolves the ID to a local
                // IOSurfaceRef backed by the SAME physical GPU pages the
                // daemon rendered into. No pixel data is copied across
                // the socket or between processes at any point.
                //
                // The returned surface has a +1 retain count; we balance
                // it with CFRelease after the callback returns.
                // -------------------------------------------------------
                IOSurfaceRef surface = IOSurfaceLookup(msg.surface_id);
                if (surface) {
                    DiCoyFrameCallback cb = weak.frameCallback;
                    if (cb) cb(surface, msg.width, msg.height);
                    CFRelease(surface);
                } else {
                    os_log_error(gClientLog, "IOSurfaceLookup(%u) returned nil", msg.surface_id);
                }
            }
        }

        os_log(gClientLog, "Read loop ended");
        [weak disconnect];
    });
}

- (BOOL)isConnected { return _connected; }

- (void)dealloc {
    [self disconnect];
}

@end
