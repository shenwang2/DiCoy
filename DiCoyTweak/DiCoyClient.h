#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#import "DiCoyProtocol.h"
#import "DiCoyXPCProtocol.h"

// Called on the XPC reply queue each time the server delivers a new frame.
// The IOSurfaceRef is valid for the duration of the callback; CFRetain it
// if you need it beyond that scope.
typedef void (^DiCoyFrameCallback)(IOSurfaceRef surface, uint16_t width, uint16_t height);

// DiCoyClient manages the NSXPCConnection to the SpringBoard-hosted server
// and dispatches incoming receiveFrame: messages to the registered callback.
@interface DiCoyClient : NSObject <DiCoyXPCClient>

// Register a block to receive frame notifications. Set before calling -connect.
@property (nonatomic, copy)     DiCoyFrameCallback frameCallback;
@property (nonatomic, readonly, getter=isConnected) BOOL connected;

// Returns YES when the socket was successfully opened.
- (BOOL)connect;
- (void)disconnect;

// Sends START/STOP to the daemon (controls whether it burns CPU capturing).
- (void)startCapture;
- (void)stopCapture;

// Attempt to reconnect if currently disconnected. Rate-limited to once per 3 s;
// the actual connect runs on the internal read queue so callers never block.
- (void)reconnectIfNeeded;

@end
