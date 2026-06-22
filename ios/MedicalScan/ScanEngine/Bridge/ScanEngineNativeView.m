#import "ScanEngineNativeView.h"

// Swift の ScanEngineHostView を実行時に解決し、props を KVC で転送する。
// MedicalScan-Swift.h を import せずに済むため ScanDependencies 段でも安全。

@interface ScanEngineNativeView ()
@property (nonatomic, strong) UIView *impl;
@end

@implementation ScanEngineNativeView

- (instancetype)init {
  self = [super init];
  if (self) {
    Class cls = NSClassFromString(@"ScanEngineHostView");
    if (!cls) cls = NSClassFromString(@"MedicalScan.ScanEngineHostView");
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

- (void)setIsScanning:(BOOL)isScanning {
  _isScanning = isScanning;
  [_impl setValue:@(isScanning) forKey:@"isScanning"];
}

- (void)setDisplayMode:(NSInteger)displayMode {
  _displayMode = displayMode;
  [_impl setValue:@(displayMode) forKey:@"displayMode"];
}

- (void)setConfidenceEnabled:(BOOL)confidenceEnabled {
  _confidenceEnabled = confidenceEnabled;
  [_impl setValue:@(confidenceEnabled) forKey:@"confidenceEnabled"];
}

- (void)setBilateralEnabled:(BOOL)bilateralEnabled {
  _bilateralEnabled = bilateralEnabled;
  [_impl setValue:@(bilateralEnabled) forKey:@"bilateralEnabled"];
}

- (void)setTemporalEnabled:(BOOL)temporalEnabled {
  _temporalEnabled = temporalEnabled;
  [_impl setValue:@(temporalEnabled) forKey:@"temporalEnabled"];
}

@end
