const demoFiles = [
  {
    name: 'scan_2026-02-14T10-30-00.stl',
    path: '/documents/scan_2026-02-14T10-30-00.stl',
    size: 2457600,
    mtime: new Date('2026-02-14T10:30:00'),
    isFile: () => true,
    isDirectory: () => false,
  },
  {
    name: 'scan_2026-02-13T15-45-00.stl',
    path: '/documents/scan_2026-02-13T15-45-00.stl',
    size: 1843200,
    mtime: new Date('2026-02-13T15:45:00'),
    isFile: () => true,
    isDirectory: () => false,
  },
  {
    name: 'scan_2026-02-12T09-00-00.stl',
    path: '/documents/scan_2026-02-12T09-00-00.stl',
    size: 3145728,
    mtime: new Date('2026-02-12T09:00:00'),
    isFile: () => true,
    isDirectory: () => false,
  },
];

export default {
  DocumentDirectoryPath: '/documents',
  readDir: async () => demoFiles,
  unlink: async (path) => {
    console.log('[Web Mock] unlink:', path);
  },
};
