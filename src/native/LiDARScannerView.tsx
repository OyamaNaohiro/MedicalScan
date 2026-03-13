import React from 'react';
import {requireNativeComponent, ViewStyle, Platform, View} from 'react-native';

export type ScannerMode = 'lidar' | 'trueDepth';

export type ScanEventPayload =
  | {type: 'scanStarted'}
  | {type: 'scanStopped'}
  | {type: 'exported'; path: string}
  | {type: 'error'; message: string};

interface LiDARScannerViewProps {
  style?: ViewStyle;
  showMeshOverlay?: boolean;
  scannerMode?: ScannerMode;
  isScanning?: boolean;
  exportFilename?: string;
  onScanEvent?: (event: {nativeEvent: ScanEventPayload}) => void;
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
  onScanEvent,
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
      onScanEvent={onScanEvent}
    />
  );
};

export {LiDARScannerView};
export default LiDARScannerView;