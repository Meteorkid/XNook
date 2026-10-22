export interface FileStatus {
  path: string;
  available: boolean;
  error: string | null;
  sizeBytes: number | null;
  isDirectory: boolean | null;
}

export const previewFileStatuses = (paths: readonly string[]): FileStatus[] => paths.map(path => ({
  path, available: false, error: '浏览器开发预览无法验证本地文件', sizeBytes: null, isDirectory: null,
}));

export function fileStatusMap(statuses: readonly FileStatus[]): Map<string, FileStatus> {
  return new Map(statuses.map(status => [status.path.toLocaleLowerCase(), status]));
}

export function formatFileSize(bytes: number | null): string {
  if (bytes === null || !Number.isFinite(bytes) || bytes < 0) return '';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  const index = bytes === 0 ? 0 : Math.max(0, Math.min(units.length - 1, Math.floor(Math.log(bytes) / Math.log(1024))));
  const amount = bytes / 1024 ** index;
  return `${index === 0 || amount >= 10 ? amount.toFixed(0) : amount.toFixed(1)} ${units[index]}`;
}
