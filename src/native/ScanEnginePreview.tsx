import React from 'react';
import {requireNativeComponent, ViewStyle, Platform, View} from 'react-native';

// プレビューの可視化モード（ネイティブ DepthDisplayMode と一致）。
export enum DepthDisplayMode {
  RawDepth = 0,
  ValidMask = 1,
  Filtered = 2,
  Difference = 3,
}

interface ScanEnginePreviewProps {
  style?: ViewStyle;
  isScanning?: boolean;
  displayMode?: DepthDisplayMode;
  confidenceEnabled?: boolean;
  bilateralEnabled?: boolean;
  temporalEnabled?: boolean;
  tsdfDisplay?: number; // 0:off 1:distance 2:weight 3:occupancy
  tsdfAxis?: number; // 0:XY 1:XZ 2:YZ
  tsdfSlice?: number; // 0..1
  meshView?: boolean; // 3Dメッシュ表示
}

const NativeScanEngineView =
  Platform.OS === 'ios'
    ? requireNativeComponent<ScanEnginePreviewProps>('ScanEngineView')
    : null;

/**
 * 描画専用のネイティブプレビュー。スキャン処理は Swift 側 ScanEngine が担当し、
 * RN は isScanning / displayMode を渡すだけ（UI のみ）。
 */
const ScanEnginePreview: React.FC<ScanEnginePreviewProps> = ({
  style,
  isScanning = false,
  displayMode = DepthDisplayMode.Filtered,
  confidenceEnabled = true,
  bilateralEnabled = true,
  temporalEnabled = true,
  tsdfDisplay = 0,
  tsdfAxis = 0,
  tsdfSlice = 0.5,
  meshView = false,
}) => {
  if (!NativeScanEngineView) {
    return <View style={style} />;
  }
  return (
    <NativeScanEngineView
      style={style}
      isScanning={isScanning}
      displayMode={displayMode}
      confidenceEnabled={confidenceEnabled}
      bilateralEnabled={bilateralEnabled}
      temporalEnabled={temporalEnabled}
      tsdfDisplay={tsdfDisplay}
      tsdfAxis={tsdfAxis}
      tsdfSlice={tsdfSlice}
      meshView={meshView}
    />
  );
};

export {ScanEnginePreview};
export default ScanEnginePreview;
