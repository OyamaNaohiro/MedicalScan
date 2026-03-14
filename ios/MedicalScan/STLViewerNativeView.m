#import "STLViewerNativeView.h"

// Access the Swift STLViewerView at runtime to avoid importing
// MedicalScan-Swift.h (a generated header unavailable during ScanDependencies).
// NSClassFromString finds the class in the app module; KVC sets @objc properties.

@interface STLViewerNativeView ()
@property (nonatomic, strong) UIView *impl;
@end

@implementation STLViewerNativeView

- (instancetype)init {
  self = [super init];
  if (self) {
    Class cls = NSClassFromString(@"MedicalScan.STLViewerView");
    if (!cls) cls = NSClassFromString(@"STLViewerView");
    _impl = [[cls alloc] init];
    _impl.frame = self.bounds;
    _impl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_impl];
  }
  return self;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  _impl.frame = self.bounds;
}

- (void)setStlFilePath:(NSString *)stlFilePath {
  _stlFilePath = [stlFilePath copy];
  [_impl setValue:(stlFilePath ?: @"") forKey:@"stlFilePath"];
}

@end