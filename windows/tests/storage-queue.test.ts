import { test } from 'node:test';
import assert from 'node:assert/strict';
import { setImmediate as nextTurn } from 'node:timers/promises';
import { newNote } from '../src/domain';
import { parseStore, StoreController } from '../src/storage';

type Write = { content: string; resolve(): void; reject(error: Error): void };
function delayedDisk() {
  const writes: Write[] = [], waiting = new Map<number, (write: Write) => void>();
  let persisted = '';
  return {
    writes,
    get persisted() { return persisted; },
    read: async () => null,
    write: (content: string) => new Promise<void>((resolve, reject) => {
      const write = { content, resolve: () => { persisted = content; resolve(); }, reject };
      const index = writes.push(write) - 1;
      waiting.get(index)?.(write); waiting.delete(index);
    }),
    started: (index: number): Promise<Write> => writes[index] ? Promise.resolve(writes[index])
      : new Promise(resolve => { waiting.set(index, resolve); }),
  };
}

test('慢盘期间100次保存只写在途快照与最新快照，合并请求在最新落盘后完成', async () => {
  const disk = delayedDisk(), controller = new StoreController(disk);
  controller.store.notes.push(newNote('连续编辑', '内容0'));
  const completed: number[] = [];
  const saves = [controller.save().then(() => { completed.push(0); })];
  const firstWrite = await disk.started(0);
  for (let index = 1; index < 100; index++) {
    controller.store.notes[0].content = `内容${index}`;
    saves.push(controller.save().then(() => { completed.push(index); }));
  }
  assert.equal(disk.writes.length, 1); assert.deepEqual(completed, []);
  firstWrite.resolve(); await saves[0];
  const latestWrite = await disk.started(1);
  assert.equal(parseStore(latestWrite.content).notes[0].content, '内容99');
  assert.deepEqual(completed, [0]);
  assert.equal(controller.state.kind, 'saving');
  latestWrite.resolve(); await Promise.all(saves); await controller.flush();
  assert.equal(disk.writes.length, 2);
  assert.equal(completed.length, 100);
  assert.equal(parseStore(disk.persisted).notes[0].content, '内容99');
  assert.equal(controller.state.kind, 'saved');
});

test('flush等待期间追加的保存也必须落盘，不能在旧写入完成时提前返回', async () => {
  const disk = delayedDisk(), controller = new StoreController(disk);
  controller.store.notes.push(newNote('退出前编辑', '第一版'));
  const first = controller.save(), firstWrite = await disk.started(0);
  let flushed = false;
  const flushing = controller.flush().then(() => { flushed = true; });
  controller.store.notes[0].content = '第二版'; const second = controller.save();
  firstWrite.resolve(); const secondWrite = await disk.started(1);
  await nextTurn(); assert.equal(flushed, false);
  controller.store.notes[0].content = '最终版'; const final = controller.save();
  secondWrite.resolve(); const finalWrite = await disk.started(2);
  await nextTurn(); assert.equal(flushed, false);
  finalWrite.resolve(); await Promise.all([first, second, final, flushing]);
  assert.equal(parseStore(disk.persisted).notes[0].content, '最终版');
  assert.equal(flushed, true);
});

test('合并批次写失败时所有请求拒绝且草稿保留，新保存可恢复', async () => {
  const disk = delayedDisk(), controller = new StoreController(disk);
  controller.store.notes.push(newNote('继续编辑', '第一版'));
  const first = controller.save(), firstWrite = await disk.started(0);
  controller.store.notes[0].content = '第二版'; const second = controller.save();
  controller.store.notes[0].content = '第三版'; const third = controller.save();
  let failures = 0;
  const failed = Promise.all([second, third].map(save => assert.rejects(save, /disk full/).then(() => { failures++; })));
  firstWrite.resolve(); await first;
  const mergedWrite = await disk.started(1);
  assert.equal(parseStore(mergedWrite.content).notes[0].content, '第三版');
  assert.equal(failures, 0);
  mergedWrite.reject(new Error('disk full')); await failed;
  assert.equal(failures, 2); assert.equal(controller.state.kind, 'error');
  assert.equal(controller.store.notes[0].content, '第三版');
  assert.equal(parseStore(disk.persisted).notes[0].content, '第一版');
  await assert.rejects(controller.flush(), /disk full/);
  controller.store.notes[0].content = '恢复后最终版'; const retry = controller.save();
  const retryWrite = await disk.started(2); retryWrite.resolve();
  await retry; await controller.flush();
  assert.equal(parseStore(disk.persisted).notes[0].content, '恢复后最终版');
  assert.equal(controller.state.kind, 'saved');
});

test('旧写入失败不会将更新批次标为失败，最新成功状态不会回退', async () => {
  const disk = delayedDisk(), states: string[] = [];
  const controller = new StoreController(disk, state => { states.push(state.kind); });
  controller.store.notes.push(newNote('最新修改', '旧内容'));
  const first = assert.rejects(controller.save(), /old write failed/), firstWrite = await disk.started(0);
  controller.store.notes[0].content = '最新内容'; const latest = controller.save();
  firstWrite.reject(new Error('old write failed')); await first;
  const latestWrite = await disk.started(1);
  assert.equal(controller.state.kind, 'saving');
  latestWrite.resolve(); await latest; await controller.flush(); await nextTurn();
  assert.equal(controller.state.kind, 'saved'); assert.equal(states.includes('error'), false);
  assert.equal(parseStore(disk.persisted).notes[0].content, '最新内容');
});

test('旧在途与待写快照完成不能清除更新草稿的验证错误', async () => {
  const disk = delayedDisk(), controller = new StoreController(disk);
  controller.store.notes.push(newNote('保留验证失败草稿', '第一版'));
  const first = controller.save(), firstWrite = await disk.started(0);
  controller.store.notes[0].content = '有效第二版'; const second = controller.save();
  controller.store.notes[0].id = ''; controller.store.notes[0].content = '无效最新草稿';
  await assert.rejects(controller.save(), /已损坏/);
  const validationMessage = controller.state.message;
  firstWrite.resolve(); const secondWrite = await disk.started(1);
  assert.equal(controller.state.kind, 'error');
  secondWrite.resolve(); await Promise.all([first, second]);
  assert.equal(controller.state.message, validationMessage);
  await assert.rejects(controller.flush(), /已损坏/);
  assert.equal(controller.store.notes[0].content, '无效最新草稿');
  assert.equal(parseStore(disk.persisted).notes[0].content, '有效第二版');
  assert.equal(disk.writes.length, 2);
});

test('损坏读取锁定后save和flush均拒绝，不能启动磁盘写入', async () => {
  const disk = delayedDisk(), controller = new StoreController({ ...disk, read: async () => '{bad' });
  await controller.load();
  assert.equal(controller.blocked, true);
  controller.store.notes.push(newNote('仅在内存的草稿', '不能覆盖损坏原件'));
  await assert.rejects(controller.save(), /存储已锁定/);
  await assert.rejects(controller.flush(), /有效的 JSON/);
  assert.equal(controller.state.kind, 'blocked'); assert.equal(disk.writes.length, 0);
});
