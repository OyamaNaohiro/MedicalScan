#import <React/RCTViewManager.h>

@interface RCT_EXTERN_MODULE(LiDARScannerViewManager, RCTViewManager)

RCT_EXPORT_VIEW_PROPERTY(showMeshOverlay, BOOL)
RCT_EXPORT_VIEW_PROPERTY(scannerMode, NSString)
RCT_EXPORT_VIEW_PROPERTY(isScanning, BOOL)
RCT_EXPORT_VIEW_PROPERTY(exportFilename, NSString)
RCT_EXPORT_VIEW_PROPERTY(onScanEvent, RCTBubblingEventBlock)

@end
