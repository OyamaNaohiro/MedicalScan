#import <React/RCTViewManager.h>
#import "LiDARScannerNativeView.h"

// Pure ObjC implementation - avoids iOS 26 NSInvocation+Swift bridge crash.
// NSInvocation calls pure ObjC setters on LiDARScannerNativeView,
// which forwards to Swift via direct ObjC messaging (safe on iOS 26).
@interface LiDARScannerViewManager : RCTViewManager
@end

@implementation LiDARScannerViewManager

RCT_EXPORT_MODULE()

- (UIView *)view {
  return [[LiDARScannerNativeView alloc] init];
}

+ (BOOL)requiresMainQueueSetup {
  return YES;
}

RCT_EXPORT_VIEW_PROPERTY(showMeshOverlay, BOOL)
RCT_EXPORT_VIEW_PROPERTY(scannerMode, NSString)
RCT_EXPORT_VIEW_PROPERTY(isScanning, BOOL)
RCT_EXPORT_VIEW_PROPERTY(exportFilename, NSString)

@end