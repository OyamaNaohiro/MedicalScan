#import "LiDARScannerNativeView.h"

// Access the Swift LiDARScannerView at runtime to avoid importing
// MedicalScan-Swift.h (a generated header unavailable during ScanDependencies).
// NSClassFromString finds the class in the app module; KVC sets @objc properties.

@interface LiDARScannerNativeView ()
@property (nonatomic, strong) UIView *impl;
@end

@implementation LiDARScannerNativeView

- (instancetype)init {
  self = [super init];
  if (self) {
    Class cls = NSClassFromString(@"MedicalScan.LiDARScannerView");
    if (!cls) cls = NSClassFromString(@"LiDARScannerView");
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

- (void)setShowMeshOverlay:(BOOL)showMeshOverlay {
  _showMeshOverlay = showMeshOverlay;
  [_impl setValue:@(showMeshOverlay) forKey:@"showMeshOverlay"];
}

- (void)setScannerMode:(NSString *)scannerMode {
  _scannerMode = [scannerMode copy];
  [_impl setValue:(scannerMode ?: @"lidar") forKey:@"scannerMode"];
}

- (void)setIsScanning:(BOOL)isScanning {
  _isScanning = isScanning;
  [_impl setValue:@(isScanning) forKey:@"isScanning"];
}

- (void)setExportFilename:(NSString *)exportFilename {
  _exportFilename = [exportFilename copy];
  [_impl setValue:(exportFilename ?: @"") forKey:@"exportFilename"];
}

@end