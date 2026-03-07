import {ScannerMode} from './LiDARScanner';

const LiDARScanner = {
  async isLiDARAvailable(): Promise<boolean> {
    return false;
  },
  async isTrueDepthAvailable(): Promise<boolean> {
    return false;
  },
  async startScan(_mode: ScannerMode): Promise<void> {
    console.log('[Web Mock] startScan called');
  },
  async stopScan(): Promise<void> {
    console.log('[Web Mock] stopScan called');
  },
  async exportToSTL(_filename: string): Promise<string> {
    console.log('[Web Mock] exportToSTL called');
    return '/mock/path/scan_demo.stl';
  },
};

export default LiDARScanner;
