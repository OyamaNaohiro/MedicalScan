#import <React/RCTViewManager.h>
#import "MedicalScan-Swift.h"

// Pure ObjC implementation - avoids iOS 26 NSInvocation+Swift bridge crash
// in ObjCTurboModule::performVoidMethodInvocation.
@interface LiDARScannerViewManager : RCTViewManager
@end

@implementation LiDARScannerViewManager

RCT_EXPORT_MODULE()

- (UIView *)view {
  return [[LiDARScannerView alloc] init];
}

+ (BOOL)requiresMainQueueSetup {
  return YES;
}

RCT_EXPORT_VIEW_PROPERTY(showMeshOverlay, BOOL)
RCT_EXPORT_VIEW_PROPERTY(scannerMode, NSString)
RCT_EXPORT_VIEW_PROPERTY(isScanning, BOOL)
RCT_EXPORT_VIEW_PROPERTY(exportFilename, NSString)

@end