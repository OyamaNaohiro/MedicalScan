#import <UIKit/UIKit.h>

// Pure ObjC wrapper around ScanEngineHostView (Swift).
// 既存の LiDARScannerNativeView と同じ iOS 26 安全パターン:
// NSInvocation はこの ObjC クラスを呼び、KVC で Swift 実体へ転送する。
@interface ScanEngineNativeView : UIView

@property (nonatomic) BOOL isScanning;
@property (nonatomic) NSInteger displayMode;

@end
