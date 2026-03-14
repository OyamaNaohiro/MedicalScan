#import "ScanEventEmitter.h"

static ScanEventEmitter *sharedEmitter = nil;

@implementation ScanEventEmitter

RCT_EXPORT_MODULE()

+ (BOOL)requiresMainQueueSetup {
  return NO;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    sharedEmitter = self;
  }
  return self;
}

+ (void)emitEvent:(NSDictionary *)body {
  if (sharedEmitter && sharedEmitter.bridge) {
    [sharedEmitter sendEventWithName:@"scanEvent" body:body];
  }
}

- (NSArray<NSString *> *)supportedEvents {
  return @[@"scanEvent"];
}

- (void)startObserving {}
- (void)stopObserving {}

@end