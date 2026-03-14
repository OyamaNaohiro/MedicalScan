import React from 'react';
import {requireNativeComponent, ViewStyle, Platform, View} from 'react-native';

export type ScannerMode = 'lidar' | 'trueDepthObject';

interface LiDARScannerViewProps {
  style?: ViewStyle;
  showMeshOverlay?: boolean;
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
      scannerMode={scannerMode}
      isScanning={isScanning}
      exportFilename={exportFilename}
      shareFilePath={shareFilePath}
    />
  );
};

export {LiDARScannerView};
export default LiDARScannerView;