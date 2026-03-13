#import <React/RCTViewManager.h>
#import "MedicalScan-Swift.h"

// Pure ObjC implementation - avoids iOS 26 NSInvocation+Swift bridge crash
// in ObjCTurboModule::performVoidMethodInvocation.
@interface STLViewerViewManager : RCTViewManager
@end

@implementation STLViewerViewManager

RCT_EXPORT_MODULE()

- (UIView *)view {
  return [[STLViewerView alloc] init];
}

+ (BOOL)requiresMainQueueSetup {
  return YES;
}

RCT_EXPORT_VIEW_PROPERTY(stlFilePath, NSString)

@end