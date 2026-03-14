#import <React/RCTEventEmitter.h>

// Pure ObjC RCTEventEmitter - avoids RCTBubblingEventBlock (block-type prop)
// which crashes on iOS 26 when NSInvocation tries to encode block arguments.
@interface ScanEventEmitter : RCTEventEmitter

+ (void)emitEvent:(NSDictionary *)body;

@end