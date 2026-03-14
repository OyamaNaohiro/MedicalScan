#import <React/RCTViewManager.h>
#import "STLViewerNativeView.h"

// Pure ObjC implementation - avoids iOS 26 NSInvocation+Swift bridge crash.
// NSInvocation calls pure ObjC setters on STLViewerNativeView,
// which forwards to Swift via direct ObjC messaging (safe on iOS 26).
@interface STLViewerViewManager : RCTViewManager
@end

@implementation STLViewerViewManager

RCT_EXPORT_MODULE()

- (UIView *)view {
  return [[STLViewerNativeView alloc] init];
}

+ (BOOL)requiresMainQueueSetup {
  return YES;
}

RCT_EXPORT_VIEW_PROPERTY(stlFilePath, NSString)

@end