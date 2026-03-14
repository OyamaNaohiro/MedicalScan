import React, {useState, useCallback, useEffect} from 'react';
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
import {LiDARScannerView, ScannerMode} from '../native/LiDARScannerView';
import {addScanEventListener} from '../native/ScanEventEmitter';

type ScanPhase = 'select' | 'active';
type ScanState = 'idle' | 'scanning' | 'exporting';

export default function ScanScreen() {
  const [phase, setPhase] = useState<ScanPhase>('select');
  const [scanState, setScanState] = useState<ScanState>('idle');
  const [showMesh, setShowMesh] = useState(true);
  const [scannerMode, setScannerMode] = useState<ScannerMode>('lidar');
  const [exportFilename, setExportFilename] = useState('');

  // Reset to selection screen on tab blur
  useFocusEffect(
    useCallback(() => {
      return () => {
        setScanState('idle');
        setPhase('select');
        setExportFilename('');
      };
    }, []),
  );

  useEffect(() => {
    const subscription = addScanEventListener(event => {
      if (event.type === 'exported') {
        setScanState('idle');
        Alert.alert('保存完了', `STLファイルを保存しました:\n${event.path}`);
        setExportFilename('');
      } else if (event.type === 'error') {
        setScanState('idle');
        Alert.alert('エラー', event.message);
        setExportFilename('');
      }
    });
    return () => subscription.remove();
  }, []);

  const handleBackToSelect = useCallback(() => {
    setScanState('idle');
    setPhase('select');
    setExportFilename('');
  }, []);

  const handleStartScan = useCallback(() => {
    setScanState('scanning');
  }, []);

  const handleStopScan = useCallback(() => {
    setScanState('idle');
  }, []);

  const handleExport = useCallback(() => {
    setScanState('exporting');
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
    setExportFilename(`scan_${timestamp}`);
  }, []);

  // ─── Phase: select ─────────────────────────────────────────────
  if (phase === 'select') {
    return (
      <SafeAreaView style={styles.selectContainer} edges={['top', 'bottom']}>
        <Text style={styles.selectTitle}>スキャンモードを選択</Text>
        <Text style={styles.selectSubtitle}>使用するカメラを選んでください</Text>

        <View style={styles.modeCards}>
          <TouchableOpacity
            style={[styles.modeCard, scannerMode === 'lidar' && styles.modeCardActive]}
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
            style={[styles.modeCard, scannerMode === 'trueDepth' && styles.modeCardActive]}
            onPress={() => setScannerMode('trueDepth')}>
            <Text style={styles.modeCardIcon}>{'👤'}</Text>
            <Text
              style={[
                styles.modeCardTitle,
                scannerMode === 'trueDepth' && styles.modeCardTitleActive,
              ]}>
              TrueDepth（顔）
            </Text>
            <Text style={styles.modeCardDesc}>
              顔の3Dスキャン{'\n'}Face ID搭載機種
            </Text>
            {scannerMode === 'trueDepth' && (
              <View style={styles.modeCardCheck}>
                <Text style={styles.modeCardCheckText}>{'✓'}</Text>
              </View>
            )}
          </TouchableOpacity>

          <TouchableOpacity
            style={[
              styles.modeCard,
              scannerMode === 'trueDepthObject' && styles.modeCardActive,
            ]}
            onPress={() => setScannerMode('trueDepthObject')}>
            <Text style={styles.modeCardIcon}>{'🫁'}</Text>
            <Text
              style={[
                styles.modeCardTitle,
                scannerMode === 'trueDepthObject' && styles.modeCardTitleActive,
              ]}>
              TrueDepth（物体）
            </Text>
            <Text style={styles.modeCardDesc}>
              顔以外のオブジェクトの深度スキャン{'\n'}距離15〜120cm推奨
            </Text>
            {scannerMode === 'trueDepthObject' && (
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
            {scannerMode === 'lidar'
              ? 'LiDAR'
              : scannerMode === 'trueDepthObject'
              ? 'TrueDepth（物体）'
              : 'TrueDepth（顔）'}
            でスキャン開始
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
        isScanning={scanState === 'scanning'}
        exportFilename={exportFilename}
      />

      <TouchableOpacity
        style={styles.backButton}
        onPress={handleBackToSelect}
        disabled={scanState === 'exporting'}>
        <Text style={styles.backButtonText}>{'‹ モード選択'}</Text>
      </TouchableOpacity>

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

      <View style={styles.controls}>
        <TouchableOpacity
          style={styles.toggleButton}
          onPress={() => setShowMesh(prev => !prev)}>
          <Text style={styles.toggleText}>メッシュ {showMesh ? 'OFF' : 'ON'}</Text>
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
          style={[styles.exportButton, scanState === 'exporting' && styles.disabledButton]}
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
});