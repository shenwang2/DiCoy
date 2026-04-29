#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#import "DiCoyProtocol.h"

// Called on a private serial queue each time the daemon delivers a new frame.
// The IOSurfaceRef is valid for the duration of the callback; retain it if
// you need it beyond that scope.
typedef void (^DiCoyFrameCallback)(IOSurfaceRef surface, uint16_t width, uint16_t height);

// DiCoyClient manages the Unix Domain Socket connection to DiCoyDaemon and
// dispatches incoming FRAME_READY messages to the registered callback.
@interface DiCoyClient : NSObject

// Register a block to receive frame notifications. Set before calling -connect.
@property (nonatomic, copy)     DiCoyFrameCallback frameCallback;
@property (nonatomic, readonly, getter=isConnected) BOOL connected;

// Returns YES when the socket was successfully opened.
- (BOOL)connect;
- (void)disconnect;

// Sends START/STOP to the daemon (controls whether it burns CPU capturing).
- (void)startCapture;
- (void)stopCapture;

@end
