#import <UIKit/UIKit.h>

// Pure ObjC wrapper around STLViewerView (Swift).
// NSInvocation calls this ObjC class (safe on iOS 26).
@interface STLViewerNativeView : UIView

@property (nonatomic, copy) NSString *stlFilePath;

@end