#import <UIKit/UIKit.h>

// Pure ObjC wrapper around LiDARScannerView (Swift).
// NSInvocation calls this ObjC class (safe on iOS 26).
// This class then forwards props to the Swift implementation
// via direct ObjC messaging (also safe on iOS 26).
@interface LiDARScannerNativeView : UIView

@property (nonatomic) BOOL showMeshOverlay;
@property (nonatomic, copy) NSString *scannerMode;
@property (nonatomic) BOOL isScanning;
@property (nonatomic, copy) NSString *exportFilename;

@end