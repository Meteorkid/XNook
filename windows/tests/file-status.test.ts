import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fileStatusMap, formatFileSize, previewFileStatuses } from '../src/file-status';

test('浏览器不能将文件引用冒充可读取文件，仍逐项保留路径', () => {
  const paths = ['C:\\中文\\存在.txt', 'D:\\disconnected.txt'];
  const statuses = previewFileStatuses(paths);
  assert.deepEqual(statuses.map(item => item.path), paths);
  assert.ok(statuses.every(item => !item.available && item.error && item.sizeBytes === null && item.isDirectory === null));
  assert.equal(fileStatusMap(statuses).get(paths[0].toLocaleLowerCase()), statuses[0]);
});

test('文件大小显示字节及二进制单位，文件夹或未知大小不造数', () => {
  assert.equal(formatFileSize(null), '');
  assert.equal(formatFileSize(NaN), '');
  assert.equal(formatFileSize(-1), '');
  assert.equal(formatFileSize(0), '0 B');
  assert.equal(formatFileSize(6), '6 B');
  assert.equal(formatFileSize(1024), '1.0 KiB');
  assert.equal(formatFileSize(1536), '1.5 KiB');
  assert.equal(formatFileSize(11 * 1024 ** 2), '11 MiB');
});
