import {NativeEventEmitter, NativeModules, Platform} from 'react-native';

export type ScanEventPayload =
  | {type: 'scanStarted'}
  | {type: 'scanStopped'}
  | {type: 'exported'; path: string}
  | {type: 'error'; message: string}
  // ScanEngine (TSDF pipeline) events
  | {
      type: 'metrics';
      renderFPS: number;
      depthFPS: number;
      gpuMs: number;
      cpuMs: number;
      validRatio: number;
      tracking: string;
      displayMode: number;
      filterTimes: {[name: string]: number};
      tsdfGpuMs: number;
      tsdfUpdated: number;
      tsdfActive: number;
      tsdfOccupancy: number;
      tsdfMB: number;
      meshTriangles: number;
      mcGpuMs: number;
      icpRmsMm: number;
      icpCorr: number;
      icpApplied: boolean;
      centerDepthM: number;
      depthRangeMin: number;
      depthRangeMax: number;
    }
  | {type: 'engineState'; state: string; tracking?: string}
  | {type: 'engineError'; message: string}
  | {type: 'engineLog'; kind: string; message: string};

const {ScanEventEmitter: NativeScanEventEmitter} = NativeModules;

const emitter =
  Platform.OS === 'ios' && NativeScanEventEmitter
    ? new NativeEventEmitter(NativeScanEventEmitter)
    : null;

export function addScanEventListener(
  callback: (event: ScanEventPayload) => void,
) {
  if (!emitter) {
    return {remove: () => {}};
  }
  return emitter.addListener('scanEvent', callback);
}