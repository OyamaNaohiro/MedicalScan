import React, {useState, useCallback} from 'react';
import {
  View,
  Text,
  TouchableOpacity,
  StyleSheet,
  Alert,
  ActivityIndicator,
} from 'react-native';
import {SafeAreaView} from 'react-native-safe-area-context';
import {useFocusEffect} from '@react-navigation/native';
import {LiDARScannerView} from '../native/LiDARScannerView';
import LiDARScanner, {ScannerMode} from '../native/LiDARScanner';

// Phase 'select': show mode selection UI, no camera
// Phase 'active': camera is rendered, user controls scan
type ScanPhase = 'select' | 'active';
type ScanState = 'idle' | 'scanning' | 'exporting';

export default function ScanScreen() {
  const [phase, setPhase] = useState<ScanPhase>('select');
  const [scanState, setScanState] = useState<ScanState>('idle');
  const [showMesh, setShowMesh] = useState(true);
  const [scannerMode, setScannerMode] = useState<ScannerMode>('lidar');

  // Reset to selection screen every time this tab is focused
  useFocusEffect(
    useCallback(() => {
      return () => {
        // Tab lost focus — stop any ongoing scan
        LiDARScanner.stopScan().catch(() => {});
        setScanState('idle');
        setPhase('select');
      };
    }, []),
  );

  // When leaving active phase, stop any ongoing scan
  const handleBackToSelect = useCallback(async () => {
    if (scanState === 'scanning') {
      try {
        await LiDARScanner.stopScan();
      } catch {}
    }
    setScanState('idle');
    setPhase('select');
  }, [scanState]);

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

  // ─── Phase: select ─────────────────────────────────────────────
  if (phase === 'select') {
    return (
      <SafeAreaView style={styles.selectContainer} edges={['top', 'bottom']}>
        <Text style={styles.selectTitle}>スキャンモードを選択</Text>
        <Text style={styles.selectSubtitle}>
          使用するカメラを選んでください
        </Text>

        <View style={styles.modeCards}>
          <TouchableOpacity
            style={[
              styles.modeCard,
              scannerMode === 'lidar' && styles.modeCardActive,
            ]}
            onPress={() => setScannerMode('lidar')}>
            <Text style={styles.modeCardIcon}>{'📡'}</Text>
            <Text
              style={[
                styles.modeCardTitle,
                scannerMode === 'lidar' && styles.modeCardTitleActive,
              ]}>
              LiDAR
            </Text>
            <Text style={styles.modeCardDesc}>
              環境・物体の高精度3Dスキャン{'\n'}iPhone 12 Pro以降
            </Text>
            {scannerMode === 'lidar' && (
              <View style={styles.modeCardCheck}>
                <Text style={styles.modeCardCheckText}>{'✓'}</Text>
              </View>
            )}
          </TouchableOpacity>

          <TouchableOpacity
            style={[
              styles.modeCard,
              scannerMode === 'trueDepth' && styles.modeCardActive,
            ]}
            onPress={() => setScannerMode('trueDepth')}>
              <Text style={styles.modeCardIcon}>{'👤'}</Text>
              <Text
                style={[
                  styles.modeCardTitle,
                  scannerMode === 'trueDepth' && styles.modeCardTitleActive,
                ]}>
                TrueDepth
              </Text>
              <Text style={styles.modeCardDesc}>
                顔・近距離オブジェクトのスキャン{'\n'}Face ID搭載機種
              </Text>
              {scannerMode === 'trueDepth' && (
                <View style={styles.modeCardCheck}>
                  <Text style={styles.modeCardCheckText}>{'✓'}</Text>
                </View>
              )}
          </TouchableOpacity>
        </View>

        <TouchableOpacity
          style={styles.proceedButton}
          onPress={() => setPhase('active')}>
          <Text style={styles.proceedButtonText}>
            {scannerMode === 'lidar' ? 'LiDAR' : 'TrueDepth'}でスキャン開始
          </Text>
        </TouchableOpacity>
      </SafeAreaView>
    );
  }

  // ─── Phase: active ─────────────────────────────────────────────
  return (
    <SafeAreaView style={styles.container} edges={['bottom']}>
      <LiDARScannerView
        style={styles.scanner}
        showMeshOverlay={showMesh}
        scannerMode={scannerMode}
      />

      {/* Back button */}
      <TouchableOpacity
        style={styles.backButton}
        onPress={handleBackToSelect}
        disabled={scanState === 'exporting'}>
        <Text style={styles.backButtonText}>{'‹ モード選択'}</Text>
      </TouchableOpacity>

      {/* Status badge */}
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

      {/* Controls */}
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
            <Text style={styles.scanButtonText}>開始</Text>
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
  // ─── Shared ───────────────────────────────────────────────────
  container: {
    flex: 1,
    backgroundColor: '#000',
  },
  centerContainer: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    padding: 32,
    backgroundColor: '#1a1a2e',
  },
  // ─── Select phase ─────────────────────────────────────────────
  selectContainer: {
    flex: 1,
    backgroundColor: '#1a1a2e',
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 24,
  },
  selectTitle: {
    fontSize: 26,
    fontWeight: '800',
    color: '#fff',
    marginBottom: 8,
  },
  selectSubtitle: {
    fontSize: 14,
    color: '#888',
    marginBottom: 36,
  },
  modeCards: {
    width: '100%',
    gap: 14,
    marginBottom: 40,
  },
  modeCard: {
    backgroundColor: '#252540',
    borderRadius: 16,
    padding: 20,
    borderWidth: 2,
    borderColor: '#333',
    position: 'relative',
  },
  modeCardActive: {
    borderColor: '#007aff',
    backgroundColor: 'rgba(0,122,255,0.12)',
  },
  modeCardIcon: {
    fontSize: 32,
    marginBottom: 8,
  },
  modeCardTitle: {
    fontSize: 18,
    fontWeight: '700',
    color: '#aaa',
    marginBottom: 4,
  },
  modeCardTitleActive: {
    color: '#007aff',
  },
  modeCardDesc: {
    fontSize: 13,
    color: '#666',
    lineHeight: 18,
  },
  modeCardCheck: {
    position: 'absolute',
    top: 16,
    right: 16,
    width: 28,
    height: 28,
    borderRadius: 14,
    backgroundColor: '#007aff',
    alignItems: 'center',
    justifyContent: 'center',
  },
  modeCardCheckText: {
    color: '#fff',
    fontSize: 14,
    fontWeight: '700',
  },
  proceedButton: {
    backgroundColor: '#007aff',
    paddingHorizontal: 40,
    paddingVertical: 16,
    borderRadius: 16,
    shadowColor: '#007aff',
    shadowOffset: {width: 0, height: 4},
    shadowOpacity: 0.4,
    shadowRadius: 10,
    elevation: 6,
  },
  proceedButtonText: {
    color: '#fff',
    fontSize: 16,
    fontWeight: '700',
  },
  // ─── Active phase ──────────────────────────────────────────────
  scanner: {
    flex: 1,
  },
  backButton: {
    position: 'absolute',
    top: 16,
    left: 16,
    backgroundColor: 'rgba(0,0,0,0.55)',
    paddingHorizontal: 14,
    paddingVertical: 8,
    borderRadius: 20,
  },
  backButtonText: {
    color: '#fff',
    fontSize: 14,
    fontWeight: '600',
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
  // ─── Unavailable ───────────────────────────────────────────────
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
