import { test } from 'node:test';
import assert from 'node:assert/strict';
import { addFiles, deleteNote, emptyStore, endSession, historyPage, linkFiles, linkNote, newNote, noteTitle, openLinkedNote, refreshLinkedNote, resumeSession, searchNotes, startSession, undoDeleteNote } from '../src/domain';
import { parseStore, StoreController } from '../src/storage';

test('初次启动为空，不注入虚假笔记、任务、日历和文件', () => {
  const store = parseStore(null);
  assert.deepEqual([store.notes.length, store.files.length, store.calendars.length, store.history.length], [0, 0, 0, 0]);
  assert.equal(store.activeSession, null);
  assert.deepEqual(parseStore(JSON.stringify(store)), store);
});
test('关联大笔记超限原子拒绝，任务与持久化原件保持不变', async () => {
  const controller = new StoreController({ read: async () => null, write: async () => {} });
  const note = newNote('大笔记', 'a'.repeat(6 * 1024 * 1024)); controller.store.notes.push(note);
  startSession(controller.store, '已有快照'); linkNote(controller.store, note); endSession(controller.store);
  startSession(controller.store, '当前任务');
  const before = JSON.stringify(controller.store);
  assert.throws(() => controller.mutate(candidate => linkNote(candidate, note)), /16 MiB/);
  assert.equal(JSON.stringify(controller.store), before);
  await controller.save();
});
test('快照恢复、重复任务、添加和导入超限均不提交半成品', () => {
  const controller = new StoreController({ read: async () => null, write: async () => {} });
  const note = newNote('大笔记', 'a'.repeat(6 * 1024 * 1024)); controller.store.notes.push(note);
  startSession(controller.store, '历史任务'); linkNote(controller.store, note); endSession(controller.store);
  const id = controller.store.history[0].id;
  for (const change of [
    (candidate: ReturnType<typeof emptyStore>) => resumeSession(candidate, id),
    (candidate: ReturnType<typeof emptyStore>) => candidate.notes.push(newNote('新增', note.content)),
    (candidate: ReturnType<typeof emptyStore>) => candidate.calendars.push({id:'calendar',name:'大日历',path:'C:\\large.ics',content:note.content,importedAt:new Date().toISOString()}),
  ]) { const before = JSON.stringify(controller.store); assert.throws(() => controller.mutate(change), /16 MiB/); assert.equal(JSON.stringify(controller.store), before); }
  controller.store.history[0].linkedNote!.id = 'missing';
  const before = JSON.stringify(controller.store);
  assert.throws(() => controller.mutate(candidate => openLinkedNote(candidate, id)), /16 MiB/);
  assert.equal(JSON.stringify(controller.store), before);
});
test('超限编辑草稿不能结束任务，但删除历史可恢复保存且保留源笔记和文件', async () => {
  let saved = '';
  const controller = new StoreController({ read: async () => null, write: async value => { saved = value; } });
  const note = newNote('保留草稿', 'a'.repeat(6 * 1024 * 1024)); controller.store.notes.push(note);
  addFiles(controller.store, [{path:'C:\\source.txt',name:'source.txt',isDirectory:false}]);
  for (let index = 0; index < 3; index++) { startSession(controller.store, `历史${index}`); linkNote(controller.store, note); endSession(controller.store); }
  startSession(controller.store, '不能丢失的当前任务');
  const before = JSON.stringify(controller.store);
  assert.throws(() => controller.mutate(candidate => endSession(candidate)), /16 MiB/);
  assert.equal(JSON.stringify(controller.store), before);
  await assert.rejects(controller.save(), /16 MiB/);
  controller.mutate(candidate => { candidate.history.splice(0,1); }, true);
  assert.equal(controller.store.history.length, 2);
  await assert.rejects(controller.save(), /16 MiB/);
  controller.mutate(candidate => { candidate.history.splice(0,1); }, true);
  await controller.save();
  const restored = parseStore(saved);
  assert.equal(restored.activeSession?.title, '不能丢失的当前任务');
  assert.equal(restored.notes[0].content, note.content); assert.equal(restored.files[0].path, 'C:\\source.txt');
  assert.equal(restored.history.length, 1);
});
test('提醒去重记录覆盖5000项全局事件预算，旧1000项数据仍兼容', () => {
  const store = emptyStore(); store.remindedEvents = Array.from({length:5000}, (_, index) => `event-${index}@1792288800000`);
  assert.equal(parseStore(JSON.stringify(store)).remindedEvents.length, 5000);
  store.remindedEvents.push('overflow@1792288800000');
  assert.throws(() => parseStore(JSON.stringify(store)), /提醒记录已损坏/);
  store.remindedEvents = store.remindedEvents.slice(0,1000);
  assert.equal(parseStore(JSON.stringify(store)).remindedEvents.length, 1000);
});
test('未知版本、结构缺失、非法日期和重复标识阻止覆盖', () => {
  assert.throws(() => parseStore('{bad'));
  assert.throws(() => parseStore('{}'));
  assert.throws(() => parseStore(JSON.stringify({ ...emptyStore(), version: 2 })));
  const store = emptyStore(), note = newNote('笔记');
  store.notes.push(note, { ...note });
  assert.throws(() => parseStore(JSON.stringify(store)), /重复标识/);
  store.notes = [{ ...note, id: '' }]; assert.throws(() => parseStore(JSON.stringify(store)));
  store.notes = [{ ...note, updatedAt: 'not-a-date' }]; assert.throws(() => parseStore(JSON.stringify(store)));
});
test('v1旧设置缺少播放器偏好时迁移为自动，新字段可往返保存', () => {
  const legacy = emptyStore() as unknown as { settings: Record<string, unknown> };
  delete legacy.settings.preferredMediaSourceId;
  assert.equal(parseStore(JSON.stringify(legacy)).settings.preferredMediaSourceId, null);
  const store = emptyStore(); store.settings.preferredMediaSourceId = 'QQMusic.exe';
  assert.equal(parseStore(JSON.stringify(store)).settings.preferredMediaSourceId, 'QQMusic.exe');
});
test('播放器偏好类型、空值、NUL及UTF-16超长数据阻止写入', () => {
  for (const preferred of [false, 1, {}, '', '   ', 'QQ\0Music', 'x'.repeat(4097), '😀'.repeat(2049)]) {
    const store = emptyStore() as unknown as { settings: Record<string, unknown> };
    store.settings.preferredMediaSourceId = preferred;
    assert.throws(() => parseStore(JSON.stringify(store)), /播放器选择设置已损坏/);
  }
  const store = emptyStore(); store.settings.preferredMediaSourceId = '😀'.repeat(2048);
  assert.equal(parseStore(JSON.stringify(store)).settings.preferredMediaSourceId?.length, 4096);
});
test('读取损坏或权限失败后不向原件写入', async () => {
  let writes = 0;
  const controller = new StoreController({ read: async () => '{"version":1}', write: async () => { writes++; } });
  await controller.load();
  assert.equal(controller.blocked, true);
  await assert.rejects(controller.save()); assert.equal(writes, 0);
  const denied = new StoreController({ read: async () => { throw new Error('Access denied'); }, write: async () => { writes++; } });
  await denied.load(); await assert.rejects(denied.save()); assert.equal(writes, 0);
});
test('写入严格串行，旧快照不会在新快照之后完成', async () => {
  let release!: () => void;
  const gate = new Promise<void>(r => { release = r; });
  const written: string[] = [];
  const controller = new StoreController({ read: async () => null, write: async value => {
    if (!written.length) { written.push('started'); await gate; }
    written.push(JSON.parse(value).notes[0]?.content || '');
  } });
  await controller.load(); controller.store.notes.push(newNote('title', 'first'));
  const first = controller.save();
  await Promise.resolve();
  controller.store.notes[0].content = 'second'; const second = controller.save();
  assert.deepEqual(written, ['started']);
  release(); await Promise.all([first, second]);
  assert.deepEqual(written, ['started', 'first', 'second']);
  assert.equal(controller.state.kind, 'saved');
});
test('保存错误保留完整草稿，flush拒绝退出，重试可以保存最新修改', async () => {
  let fail = true, content = '';
  const controller = new StoreController({ read: async () => null, write: async value => { if (fail) throw new Error('disk full'); content = value; } });
  await controller.load(); controller.store.notes.push(newNote('中文标题', '尚未保存的草稿'));
  await assert.rejects(controller.save(), /disk full/);
  assert.equal(controller.store.notes[0].content, '尚未保存的草稿');
  await assert.rejects(controller.flush(), /disk full/);
  controller.store.notes[0].content += '，继续编辑'; fail = false;
  await controller.save(); await controller.flush();
  assert.equal(parseStore(content).notes[0].content, '尚未保存的草稿，继续编辑');
});
test('保存前的验证错误也显示为失败并阻止退出', async () => {
  let writes = 0;
  const controller = new StoreController({ read: async () => null, write: async () => { writes++; } });
  await controller.load();
  controller.store.notes.push({ ...newNote('未保存草稿'), id: '' });
  await assert.rejects(controller.save());
  assert.equal(controller.state.kind, 'error');
  await assert.rejects(controller.flush());
  assert.equal(writes, 0);
  assert.equal(controller.store.notes[0].title, '未保存草稿');
});
test('笔记支持标题回退、按多个关键词搜索、删除和撤销', () => {
  const store = emptyStore();
  const first = newNote('', '# Windows 方案\n这里是 ICS 日历', '2026-10-17T00:00:00.000Z');
  const second = newNote('项目', '音乐同步', '2026-10-16T00:00:00.000Z');
  store.notes.push(first, second);
  assert.equal(noteTitle(first), 'Windows 方案');
  assert.deepEqual(searchNotes(store.notes, 'windows 日历').map(n => n.id), [first.id]);
  assert.deepEqual(searchNotes(store.notes, '').map(n => n.id), [first.id, second.id]);
  const deleted = deleteNote(store, first.id)!; assert.equal(store.notes.length, 1);
  undoDeleteNote(store, deleted); undoDeleteNote(store, deleted); assert.equal(store.notes.length, 2);
  assert.equal(store.notes.find(n => n.id === first.id)?.content, first.content);
});
test('NookFlow 保留文件和笔记独立快照，结束后移除源数据仍能恢复', () => {
  const store = emptyStore();
  startSession(store, '写论文', null, null, '2026-10-17T01:00:00.000Z');
  addFiles(store, [{ path: 'C:\\Research\\paper.pdf', name: 'paper.pdf', isDirectory: false }]);
  addFiles(store, [{ path: 'c:\\research\\PAPER.pdf', name: 'PAPER.pdf', isDirectory: false }]);
  assert.equal(store.files.length, 1);
  linkFiles(store); linkFiles(store); assert.equal(store.activeSession!.linkedFiles.length, 1);
  const note = newNote('研究笔记', '第一次记录'); store.notes.push(note); linkNote(store, note);
  note.content = '完整记录'; refreshLinkedNote(store, note);
  endSession(store, '2026-10-17T01:30:00.000Z');
  const old = store.history[0]; store.files = []; store.notes = [];
  assert.equal(old.linkedFiles[0].path, 'C:\\Research\\paper.pdf');
  assert.equal(old.linkedNote!.content, '完整记录');
  resumeSession(store, old.id, '2026-10-17T02:00:00.000Z');
  assert.notEqual(store.activeSession!.id, old.id);
  assert.equal(store.activeSession!.endedAt, null);
  store.activeSession!.linkedNote!.content = '第二轮';
  assert.equal(old.linkedNote!.content, '完整记录');
  assert.throws(() => startSession(store, '并发任务'), /先结束/);
  assert.deepEqual(parseStore(JSON.stringify(store)), store);
});
test('没有活跃任务时不得结束或关联文件', () => {
  const store = emptyStore(); assert.throws(() => endSession(store)); assert.throws(() => linkFiles(store));
  assert.throws(() => resumeSession(store, 'missing'));
});
test('打开已关联原笔记不会覆盖用户后续修改或历史快照', () => {
  const store = emptyStore(), note = newNote('任务记录', '结束时正文');
  store.notes.push(note);
  const session = startSession(store, '任务'); linkNote(store, note); endSession(store);
  note.title = '后续改名'; note.content = '后续正文';
  const snapshot = structuredClone(store.history[0].linkedNote);
  assert.equal(openLinkedNote(store, session.id), note);
  assert.equal(store.notes.length, 1);
  assert.equal(note.content, '后续正文');
  assert.deepEqual(store.history[0].linkedNote, snapshot);
});
test('任务笔记缺失时只恢复一次并重绑，活跃任务后续编辑仍同步快照', () => {
  const store = emptyStore(), note = newNote('任务笔记', '原始正文');
  store.notes.push(note);
  const session = startSession(store, '任务'); linkNote(store, note); deleteNote(store, note.id);
  const restoredAt = '2026-10-17T03:00:00.000Z';
  const restored = openLinkedNote(store, session.id, restoredAt);
  assert.notEqual(restored.id, note.id);
  assert.equal(restored.createdAt, restoredAt);
  assert.equal(restored.updatedAt, restoredAt);
  assert.equal(store.activeSession!.linkedNote!.id, restored.id);
  assert.equal(openLinkedNote(store, session.id), restored);
  assert.equal(store.notes.length, 1);
  restored.title = '恢复后改名'; restored.content = '恢复后追加正文'; refreshLinkedNote(store, restored);
  assert.deepEqual(store.activeSession!.linkedNote, { id: restored.id, title: restored.title, content: restored.content });
  assert.deepEqual(parseStore(JSON.stringify(store)), store);
});
test('历史恢复只重绑标识，编辑恢复笔记不改写历史标题或正文', () => {
  const store = emptyStore(), note = newNote('结束时标题', '结束时正文');
  store.notes.push(note);
  const session = startSession(store, '历史任务'); linkNote(store, note); endSession(store); deleteNote(store, note.id);
  const restored = openLinkedNote(store, session.id);
  assert.equal(openLinkedNote(store, session.id), restored);
  restored.title = '新的标题'; restored.content = '新的正文'; refreshLinkedNote(store, restored);
  assert.deepEqual(store.history[0].linkedNote, { id: restored.id, title: '结束时标题', content: '结束时正文' });
  resumeSession(store, session.id); linkNote(store, restored);
  restored.content = '继续任务追加'; refreshLinkedNote(store, restored);
  assert.equal(store.activeSession!.linkedNote!.content, '继续任务追加');
  assert.equal(store.history[0].linkedNote!.content, '结束时正文');
  assert.equal(store.notes.length, 1);
});
test('恢复后的笔记再次删除仍能用原快照恢复，空白标题使用默认值', () => {
  const store = emptyStore();
  const session = startSession(store, ' \n\t ');
  assert.equal(session.title, '未命名任务');
  session.linkedNote = { id: 'missing-note', title: '  ', content: ' \n ' };
  const first = openLinkedNote(store, session.id);
  assert.equal(first.title, '未命名笔记');
  first.content = '未同步的临时修改'; deleteNote(store, first.id);
  const second = openLinkedNote(store, session.id);
  assert.notEqual(second.id, first.id);
  assert.equal(second.content, ' \n ');
  assert.equal(store.notes.length, 1);
  assert.equal(openLinkedNote(store, session.id), second);
});
test('任务不存在或未关联笔记时恢复失败且不创建数据', () => {
  const store = emptyStore();
  assert.throws(() => openLinkedNote(store, 'missing'), /任务记录不存在/);
  const session = startSession(store, '没有笔记');
  const before = structuredClone(store);
  assert.throws(() => openLinkedNote(store, session.id), /没有关联笔记/);
  assert.deepEqual(store, before);
});
test('全部历史按实际结束时间倒序分页，同时间稳定且不修改原数组', () => {
  const store = emptyStore();
  for (let index = 0; index < 43; index++) {
    startSession(store, `任务 ${index}`, null, null, '2026-10-17T00:00:00.000Z');
    endSession(store, new Date(Date.parse('2026-10-17T01:00:00.000Z') + index * 60000).toISOString());
  }
  store.history.reverse();
  const original = structuredClone(store.history), allIds: string[] = [];
  for (let page = 0; page < 3; page++) {
    const selection = historyPage(store.history, page);
    assert.equal(selection.pageCount, 3); assert.equal(selection.total, 43);
    allIds.push(...selection.items.map(session => session.id));
  }
  assert.deepEqual(allIds, [...store.history].reverse().map(session => session.id));
  assert.deepEqual(store.history, original);
  const tied = store.history.slice(0, 3).map(session => ({ ...session, endedAt: '2026-10-17T02:00:00.000Z' }));
  tied[1].endedAt = '2026-10-17T10:00:00.000+08:00';
  assert.deepEqual(historyPage(tied).items.map(session => session.id), tied.map(session => session.id));
});
test('历史分页钳制空列表、页码和页大小边界，不因超范围访问丢失最后一页', () => {
  assert.deepEqual(historyPage([]), { items: [], page: 0, pageSize: 20, pageCount: 1, total: 0 });
  const store = emptyStore();
  for (let index = 0; index < 102; index++) { startSession(store, `${index}`); endSession(store); }
  assert.equal(historyPage(store.history, -1).page, 0);
  assert.equal(historyPage(store.history, NaN, NaN).pageSize, 20);
  assert.equal(historyPage(store.history, Infinity).page, 0);
  assert.equal(historyPage(store.history, 0, -5).pageSize, 1);
  assert.equal(historyPage(store.history, 0, 3.9).pageSize, 3);
  const last = historyPage(store.history, 100000, 100000);
  assert.equal(last.pageSize, 100); assert.equal(last.page, 1); assert.equal(last.items.length, 2);
  assert.equal(last.items.at(-1)?.id, store.history.at(-1)?.id);
});
