import React from 'react';
import {requireNativeComponent, ViewStyle, Platform, View} from 'react-native';
import {ScannerMode} from './LiDARScanner';

interface LiDARScannerViewProps {
  style?: ViewStyle;
  showMeshOverlay?: boolean;
  scannerMode?: ScannerMode;
}

const NativeLiDARView =
  Platform.OS === 'ios'
    ? requireNativeComponent<LiDARScannerViewProps>('LiDARScannerView')
    : null;

const LiDARScannerView: React.FC<LiDARScannerViewProps> = ({
  style,
  showMeshOverlay = true,
  scannerMode = 'lidar',
}) => {
  if (!NativeLiDARView) {
    return <View style={style} />;
  }

  return (
    <NativeLiDARView
      style={style}
      showMeshOverlay={showMeshOverlay}
      scannerMode={scannerMode}
    />
  );
};

export {LiDARScannerView};
export default LiDARScannerView;
