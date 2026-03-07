import {NativeModules, Platform} from 'react-native';

const {LiDARScannerModule} = NativeModules;

export type ScannerMode = 'lidar' | 'trueDepth';

interface ILiDARScanner {
  isLiDARAvailable(): Promise<boolean>;
  isTrueDepthAvailable(): Promise<boolean>;
  startScan(mode: ScannerMode): Promise<void>;
  stopScan(): Promise<void>;
  exportToSTL(filename: string): Promise<string>;
}

const LiDARScanner: ILiDARScanner = {
  isLiDARAvailable(): Promise<boolean> {
    if (Platform.OS !== 'ios') {
      return Promise.resolve(false);
    }
    return LiDARScannerModule.isLiDARAvailable();
  },

  isTrueDepthAvailable(): Promise<boolean> {
    if (Platform.OS !== 'ios') {
      return Promise.resolve(false);
    }
    return LiDARScannerModule.isTrueDepthAvailable();
  },

  startScan(mode: ScannerMode): Promise<void> {
    if (Platform.OS !== 'ios') {
      return Promise.reject(new Error('Scanning is only available on iOS'));
    }
    return LiDARScannerModule.startScan(mode);
  },

  stopScan(): Promise<void> {
    if (Platform.OS !== 'ios') {
      return Promise.reject(new Error('Scanning is only available on iOS'));
    }
    return LiDARScannerModule.stopScan();
  },

  exportToSTL(filename: string): Promise<string> {
    if (Platform.OS !== 'ios') {
      return Promise.reject(new Error('Scanning is only available on iOS'));
    }
    return LiDARScannerModule.exportToSTL(filename);
  },
};

export default LiDARScanner;
