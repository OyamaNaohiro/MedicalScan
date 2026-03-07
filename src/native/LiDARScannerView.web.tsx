import React from 'react';
import {View, Text, StyleSheet, ViewStyle} from 'react-native';

interface LiDARScannerViewProps {
  style?: ViewStyle;
  showMeshOverlay?: boolean;
}

export function LiDARScannerView({style}: LiDARScannerViewProps) {
  return (
    <View style={[styles.container, style]}>
      <View style={styles.mockCamera}>
        <Text style={styles.title}>LiDAR Scanner</Text>
        <Text style={styles.subtitle}>Web Preview Mode</Text>
        <Text style={styles.description}>
          実機では、ここにARカメラビューとメッシュオーバーレイが表示されます
        </Text>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  mockCamera: {
    flex: 1,
    backgroundColor: '#1a1a2e',
    alignItems: 'center',
    justifyContent: 'center',
    padding: 32,
  },
  title: {
    fontSize: 24,
    fontWeight: '700',
    color: '#e0e0e0',
    marginBottom: 8,
  },
  subtitle: {
    fontSize: 16,
    fontWeight: '600',
    color: '#007aff',
    marginBottom: 16,
  },
  description: {
    fontSize: 14,
    color: '#888',
    textAlign: 'center',
    lineHeight: 22,
  },
});
