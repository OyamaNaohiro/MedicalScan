#import "STLViewerNativeView.h"
#import "MedicalScan-Swift.h"

@interface STLViewerNativeView ()
@property (nonatomic, strong) STLViewerView *impl;
@end

@implementation STLViewerNativeView

- (instancetype)init {
  self = [super init];
  if (self) {
    _impl = [[STLViewerView alloc] init];
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
  _impl.stlFilePath = stlFilePath ?: @"";
}

@end