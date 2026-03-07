import React, {useState, useEffect, useCallback} from 'react';
import {
  View,
  Text,
  TouchableOpacity,
  StyleSheet,
  Alert,
  ActivityIndicator,
} from 'react-native';
import {SafeAreaView} from 'react-native-safe-area-context';
import {LiDARScannerView} from '../native/LiDARScannerView';
import LiDARScanner, {ScannerMode} from '../native/LiDARScanner';

type ScanState = 'idle' | 'scanning' | 'exporting';

export default function ScanScreen() {
  const [scanState, setScanState] = useState<ScanState>('idle');
  const [showMesh, setShowMesh] = useState(true);
  const [lidarAvailable, setLidarAvailable] = useState<boolean | null>(null);
  const [trueDepthAvailable, setTrueDepthAvailable] = useState<boolean>(false);
  const [scannerMode, setScannerMode] = useState<ScannerMode>('lidar');

  useEffect(() => {
    Promise.all([
      LiDARScanner.isLiDARAvailable(),
      LiDARScanner.isTrueDepthAvailable(),
    ]).then(([lidar, trueDepth]) => {
      setLidarAvailable(lidar);
      setTrueDepthAvailable(trueDepth);
    });
  }, []);

  const handleSelectMode = useCallback(
    (mode: ScannerMode) => {
      if (scanState !== 'idle') {
        return;
      }
      setScannerMode(mode);
    },
    [scanState],
  );

  const handleStartScan = useCallback(async () => {
    try {
      setScanState('scanning');
      await LiDARScanner.startScan(scannerMode);
    } catch (error: any) {
      setScanState('idle');
      Alert.alert('エラー', error.message || 'スキャンを開始できませんでした');
    }
  }, [scannerMode]);

  const handleStopScan = useCallback(async () => {
    try {
      await LiDARScanner.stopScan();
      setScanState('idle');
    } catch (error: any) {
      Alert.alert('エラー', error.message || 'スキャンを停止できませんでした');
    }
  }, []);

  const handleExport = useCallback(async () => {
    if (scanState === 'scanning') {
      await LiDARScanner.stopScan();
    }
    setScanState('exporting');
    try {
      const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
      const filename = `scan_${timestamp}`;
      const filePath = await LiDARScanner.exportToSTL(filename);
      setScanState('idle');
      Alert.alert('保存完了', `STLファイルを保存しました:\n${filePath}`);
    } catch (error: any) {
      setScanState('idle');
      Alert.alert('エラー', error.message || 'STLのエクスポートに失敗しました');
    }
  }, [scanState]);

  // Loading state
  if (lidarAvailable === null) {
    return (
      <SafeAreaView style={styles.container} edges={['bottom']}>
        <View style={styles.unavailableContainer}>
          <ActivityIndicator size="large" color="#007aff" />
        </View>
      </SafeAreaView>
    );
  }

  // Neither sensor available
  if (!lidarAvailable && !trueDepthAvailable) {
    return (
      <SafeAreaView style={styles.container} edges={['bottom']}>
        <View style={styles.unavailableContainer}>
          <Text style={styles.unavailableIcon}>{'📱'}</Text>
          <Text style={styles.unavailableTitle}>スキャン非対応デバイス</Text>
          <Text style={styles.unavailableText}>
            このデバイスはLiDARまたはTrueDepthカメラを搭載していません。
          </Text>
          <Text style={styles.unavailableHint}>
            ファイル画面と設定画面は引き続き使用できます
          </Text>
        </View>
      </SafeAreaView>
    );
  }

  const activeMode: ScannerMode =
    scannerMode === 'lidar' && !lidarAvailable ? 'trueDepth' : scannerMode;

  return (
    <SafeAreaView style={styles.container} edges={['bottom']}>
      <LiDARScannerView
        style={styles.scanner}
        showMeshOverlay={showMesh}
        scannerMode={activeMode}
      />

      <View style={styles.overlay}>
        {scanState === 'scanning' && (
          <View style={styles.statusBadge}>
            <View style={styles.recordingDot} />
            <Text style={styles.statusText}>スキャン中...</Text>
          </View>
        )}
        {scanState === 'exporting' && (
          <View style={styles.statusBadge}>
            <ActivityIndicator size="small" color="#fff" />
            <Text style={styles.statusText}>エクスポート中...</Text>
          </View>
        )}
      </View>

      {/* Mode selector */}
      <View style={styles.modeSelector}>
        {lidarAvailable && (
          <TouchableOpacity
            style={[
              styles.modeButton,
              activeMode === 'lidar' && styles.modeButtonActive,
            ]}
            onPress={() => handleSelectMode('lidar')}
            disabled={scanState !== 'idle'}>
            <Text
              style={[
                styles.modeButtonText,
                activeMode === 'lidar' && styles.modeButtonTextActive,
              ]}>
              LiDAR
            </Text>
            <Text
              style={[
                styles.modeSubText,
                activeMode === 'lidar' && styles.modeButtonTextActive,
              ]}>
              環境スキャン
            </Text>
          </TouchableOpacity>
        )}
        {trueDepthAvailable && (
          <TouchableOpacity
            style={[
              styles.modeButton,
              activeMode === 'trueDepth' && styles.modeButtonActive,
            ]}
            onPress={() => handleSelectMode('trueDepth')}
            disabled={scanState !== 'idle'}>
            <Text
              style={[
                styles.modeButtonText,
                activeMode === 'trueDepth' && styles.modeButtonTextActive,
              ]}>
              TrueDepth
            </Text>
            <Text
              style={[
                styles.modeSubText,
                activeMode === 'trueDepth' && styles.modeButtonTextActive,
              ]}>
              顔スキャン
            </Text>
          </TouchableOpacity>
        )}
      </View>

      <View style={styles.controls}>
        <TouchableOpacity
          style={styles.toggleButton}
          onPress={() => setShowMesh(prev => !prev)}>
          <Text style={styles.toggleText}>
            メッシュ {showMesh ? 'OFF' : 'ON'}
          </Text>
        </TouchableOpacity>

        {scanState === 'idle' ? (
          <TouchableOpacity style={styles.scanButton} onPress={handleStartScan}>
            <Text style={styles.scanButtonText}>スキャン開始</Text>
          </TouchableOpacity>
        ) : scanState === 'scanning' ? (
          <TouchableOpacity
            style={[styles.scanButton, styles.stopButton]}
            onPress={handleStopScan}>
            <Text style={styles.scanButtonText}>停止</Text>
          </TouchableOpacity>
        ) : (
          <View style={[styles.scanButton, styles.disabledButton]}>
            <ActivityIndicator color="#fff" />
          </View>
        )}

        <TouchableOpacity
          style={[
            styles.exportButton,
            scanState === 'exporting' && styles.disabledButton,
          ]}
          onPress={handleExport}
          disabled={scanState === 'exporting'}>
          <Text style={styles.exportText}>STL保存</Text>
        </TouchableOpacity>
      </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#000',
  },
  scanner: {
    flex: 1,
  },
  overlay: {
    position: 'absolute',
    top: 60,
    alignSelf: 'center',
  },
  statusBadge: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: 'rgba(0,0,0,0.6)',
    paddingHorizontal: 16,
    paddingVertical: 8,
    borderRadius: 20,
    gap: 8,
  },
  recordingDot: {
    width: 10,
    height: 10,
    borderRadius: 5,
    backgroundColor: '#ff3b30',
  },
  statusText: {
    color: '#fff',
    fontSize: 14,
    fontWeight: '600',
  },
  modeSelector: {
    flexDirection: 'row',
    justifyContent: 'center',
    gap: 12,
    paddingHorizontal: 16,
    paddingVertical: 10,
    backgroundColor: 'rgba(0,0,0,0.8)',
  },
  modeButton: {
    flex: 1,
    alignItems: 'center',
    paddingVertical: 8,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: '#555',
    backgroundColor: '#222',
  },
  modeButtonActive: {
    borderColor: '#007aff',
    backgroundColor: 'rgba(0,122,255,0.2)',
  },
  modeButtonText: {
    color: '#aaa',
    fontSize: 14,
    fontWeight: '700',
  },
  modeButtonTextActive: {
    color: '#007aff',
  },
  modeSubText: {
    color: '#666',
    fontSize: 11,
    marginTop: 2,
  },
  controls: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-around',
    paddingVertical: 20,
    paddingHorizontal: 16,
    backgroundColor: 'rgba(0,0,0,0.8)',
  },
  toggleButton: {
    paddingHorizontal: 16,
    paddingVertical: 12,
    borderRadius: 10,
    backgroundColor: '#333',
  },
  toggleText: {
    color: '#fff',
    fontSize: 13,
    fontWeight: '600',
  },
  scanButton: {
    width: 80,
    height: 80,
    borderRadius: 40,
    backgroundColor: '#007aff',
    alignItems: 'center',
    justifyContent: 'center',
  },
  stopButton: {
    backgroundColor: '#ff3b30',
  },
  disabledButton: {
    opacity: 0.5,
  },
  scanButtonText: {
    color: '#fff',
    fontSize: 14,
    fontWeight: '700',
  },
  exportButton: {
    paddingHorizontal: 16,
    paddingVertical: 12,
    borderRadius: 10,
    backgroundColor: '#34c759',
  },
  exportText: {
    color: '#fff',
    fontSize: 13,
    fontWeight: '600',
  },
  unavailableContainer: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    padding: 32,
    backgroundColor: '#1a1a2e',
  },
  unavailableIcon: {
    fontSize: 48,
    marginBottom: 16,
  },
  unavailableTitle: {
    fontSize: 22,
    fontWeight: '700',
    color: '#fff',
    marginBottom: 12,
  },
  unavailableText: {
    fontSize: 15,
    color: '#aaa',
    textAlign: 'center',
    lineHeight: 22,
    marginBottom: 4,
  },
  unavailableHint: {
    fontSize: 13,
    color: '#666',
    textAlign: 'center',
    marginTop: 16,
  },
});
