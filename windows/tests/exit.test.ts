import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ExitGate } from '../src/exit';
import { StoreController, parseStore } from '../src/storage';
import { newNote } from '../src/domain';

test('退出在慢盘保存开始前锁定新编辑，确认退出时最后一份可编辑内容已保存', async () => {
  let release!: () => void;
  const slowDisk = new Promise<void>(resolve => { release = resolve; });
  let persisted = '', confirmed = false, locked = false;
  const controller = new StoreController({ read: async () => null, write: async content => { await slowDisk; persisted = content; } });
  await controller.load(); controller.store.notes.push(newNote('笔记', 'A'));
  const gate = new ExitGate(busy => { locked = busy; });
  const exiting = gate.request(() => controller.save(), async () => { confirmed = true; });
  assert.equal(locked, true);
  // UI 的修改入口与控件 disabled 共用这个门禁，等待期间的 B 不会被接受为草稿。
  if (!gate.pending) controller.store.notes[0].content = 'B';
  assert.equal(confirmed, false);
  release(); await exiting;
  assert.equal(parseStore(persisted).notes[0].content, controller.store.notes[0].content);
  assert.equal(parseStore(persisted).notes[0].content, 'A');
  assert.equal(confirmed, true); assert.equal(locked, true);
});
test('失败恢复编辑、保留草稿且不确认退出，随后可重试', async () => {
  let locked = false, confirms = 0;
  const gate = new ExitGate(busy => { locked = busy; });
  await assert.rejects(gate.request(async () => { throw new Error('磁盘已满'); }, async () => { confirms++; }));
  assert.equal(locked, false); assert.equal(gate.pending, false); assert.equal(confirms, 0);
  await gate.request(async () => {}, async () => { confirms++; });
  assert.equal(confirms, 1); assert.equal(gate.pending, true);
});
test('重复退出请求不会重复保存或提前确认', async () => {
  let release!: () => void, writes = 0, confirms = 0;
  const slow = new Promise<void>(resolve => { release = resolve; });
  const gate = new ExitGate(() => {});
  const first = gate.request(async () => { writes++; await slow; }, async () => { confirms++; });
  await gate.request(async () => { writes++; }, async () => { confirms++; });
  assert.equal(writes, 1); assert.equal(confirms, 0);
  release(); await first; assert.equal(confirms, 1);
});
