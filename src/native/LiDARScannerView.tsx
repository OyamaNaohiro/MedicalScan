import React from 'react';
import {requireNativeComponent, ViewStyle, Platform, View} from 'react-native';

export type ScannerMode = 'lidar' | 'trueDepthObject' | 'structureSensor';

interface LiDARScannerViewProps {
  style?: ViewStyle;
  showMeshOverlay?: boolean;
  boundingBoxEnabled?: boolean;
  boxWidth?: number;
  boxHeight?: number;
  boxDepth?: number;
  scannerMode?: ScannerMode;
  isScanning?: boolean;
  exportFilename?: string;
  shareFilePath?: string;
}

const NativeLiDARView =
  Platform.OS === 'ios'
    ? requireNativeComponent<LiDARScannerViewProps>('LiDARScannerView')
    : null;

const LiDARScannerView: React.FC<LiDARScannerViewProps> = ({
  style,
  showMeshOverlay = true,
  boundingBoxEnabled = false,
  boxWidth = 0.6,
  boxHeight = 1.2,
  boxDepth = 0.6,
  scannerMode = 'lidar',
  isScanning = false,
  exportFilename = '',
  shareFilePath = '',
}) => {
  if (!NativeLiDARView) {
    return <View style={style} />;
  }
  return (
    <NativeLiDARView
      style={style}
      showMeshOverlay={showMeshOverlay}
      boundingBoxEnabled={boundingBoxEnabled}
      boxWidth={boxWidth}
      boxHeight={boxHeight}
      boxDepth={boxDepth}
      scannerMode={scannerMode}
      isScanning={isScanning}
      exportFilename={exportFilename}
      shareFilePath={shareFilePath}
    />
  );
};

export {LiDARScannerView};
export default LiDARScannerView;