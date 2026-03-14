#import "LiDARScannerNativeView.h"
#import "MedicalScan-Swift.h"

@interface LiDARScannerNativeView ()
@property (nonatomic, strong) LiDARScannerView *impl;
@end

@implementation LiDARScannerNativeView

- (instancetype)init {
  self = [super init];
  if (self) {
    _impl = [[LiDARScannerView alloc] init];
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
  _impl.showMeshOverlay = showMeshOverlay;
}

- (void)setScannerMode:(NSString *)scannerMode {
  _scannerMode = [scannerMode copy];
  _impl.scannerMode = scannerMode ?: @"lidar";
}

- (void)setIsScanning:(BOOL)isScanning {
  _isScanning = isScanning;
  _impl.isScanning = isScanning;
}

- (void)setExportFilename:(NSString *)exportFilename {
  _exportFilename = [exportFilename copy];
  _impl.exportFilename = exportFilename ?: @"";
}

@end