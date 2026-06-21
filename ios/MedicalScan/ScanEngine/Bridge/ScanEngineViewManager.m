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

@end
