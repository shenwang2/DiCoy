#ifndef DICOY_XPC_PROTOCOL_H
#define DICOY_XPC_PROTOCOL_H

// Mach service name registered by SpringBoard via bootstrap_check_in.
// Camera-app processes reach it via bootstrap_look_up; the Sandy profile
// grants com.apple.security.exception.mach-lookup.global-name for this name.
#define DICOY_XPC_SERVICE_NAME "com.dicoy.server"

// Server → Client: per-frame delivery.
// 'surface' is an IOSurface ObjC object (toll-free bridged with IOSurfaceRef).
// NSXPCConnection serialises it as a Mach send right — no IOSurfaceRootUserClient
// access required on the receiving side.
// oneway = fire-and-forget; server does not wait for client acknowledgement.
@protocol DiCoyXPCClient <NSObject>
- (oneway void)receiveFrame:(id)surface width:(uint32_t)w height:(uint32_t)h;
@end

// Client → Server: capture control.
@protocol DiCoyXPCServer <NSObject>
- (oneway void)startCapture;
- (oneway void)stopCapture;
@end

#endif // DICOY_XPC_PROTOCOL_H
