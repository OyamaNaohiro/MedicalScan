#import <React/RCTViewManager.h>
#import "ScanEngineNativeView.h"

// ScanEngine プレビューの RN コンポーネント（RN 名: "ScanEngineView"）。
// Pure ObjC 実装で iOS 26 の NSInvocation+Swift ブリッジクラッシュを回避する。
@interface ScanEngineViewManager : RCTViewManager
@end

@implementation ScanEngineViewManager

RCT_EXPORT_MODULE()

- (UIView *)view {
  return [[ScanEngineNativeView alloc] init];
}

+ (BOOL)requiresMainQueueSetup {
  return YES;
}

RCT_EXPORT_VIEW_PROPERTY(isScanning, BOOL)
RCT_EXPORT_VIEW_PROPERTY(displayMode, NSInteger)
RCT_EXPORT_VIEW_PROPERTY(scanMode, NSInteger)
RCT_EXPORT_VIEW_PROPERTY(confidenceEnabled, BOOL)
RCT_EXPORT_VIEW_PROPERTY(bilateralEnabled, BOOL)
RCT_EXPORT_VIEW_PROPERTY(temporalEnabled, BOOL)
RCT_EXPORT_VIEW_PROPERTY(tsdfDisplay, NSInteger)
RCT_EXPORT_VIEW_PROPERTY(tsdfAxis, NSInteger)
RCT_EXPORT_VIEW_PROPERTY(tsdfSlice, double)
RCT_EXPORT_VIEW_PROPERTY(meshView, BOOL)
RCT_EXPORT_VIEW_PROPERTY(sdfSmooth, BOOL)
RCT_EXPORT_VIEW_PROPERTY(icpEnabled, BOOL)
RCT_EXPORT_VIEW_PROPERTY(connectGate, BOOL)
RCT_EXPORT_VIEW_PROPERTY(sparseEnabled, BOOL)
RCT_EXPORT_VIEW_PROPERTY(exportFormat, NSInteger)
RCT_EXPORT_VIEW_PROPERTY(exportRequest, double)
RCT_EXPORT_VIEW_PROPERTY(decimateRatio, double)

@end
