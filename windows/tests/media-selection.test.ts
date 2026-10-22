import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MediaSelection } from '../src/media-selection';
import { emptyMedia, LyricsController, type MediaSnapshot, type LyricsCandidate } from '../src/lyrics';

const sourceList = [
  { sourceId: 'cloudmusic.exe', name: '网易云音乐', kind: 'netease' as const, playing: true, isSystemCurrent: true },
  { sourceId: 'QQMusic.exe', name: 'QQ 音乐', kind: 'qqmusic' as const, playing: false, isSystemCurrent: false },
];
const snapshot = (sourceId: string, title = sourceId): MediaSnapshot => ({ ...emptyMedia(), available: true, sourceId, sessionToken: `token-${sourceId}`,
  playerName: sourceList.find(source => source.sourceId === sourceId)?.name || sourceId,
  sources: sourceList, title, artist: '歌手', canPlayPause: true, canNext: true, canSeek: true, duration: 200, position: 10 });
function deferred<T>() {
  let resolve!: (value: T) => void, reject!: (reason: Error) => void;
  const promise = new Promise<T>((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
}
test('恢复的固定来源传给首次查询，不先查询自动来源', async () => {
  const queries: (string | null)[] = [];
  const selection = new MediaSelection({ snapshot: async preferred => { queries.push(preferred); return snapshot(preferred!); }, control: async () => {} });
  selection.select('QQMusic.exe'); await selection.poll();
  assert.deepEqual(queries, ['QQMusic.exe']); assert.equal(selection.snapshot.playerName, 'QQ 音乐');
});
test('选择新来源立即清空旧曲目和控制；新查询不被旧挂起查询阻挡', async () => {
  const old = deferred<MediaSnapshot>();
  const selection = new MediaSelection({ snapshot: async preferred => preferred ? snapshot(preferred) : old.promise, control: async () => {} });
  const pending = selection.poll();
  selection.select('QQMusic.exe');
  assert.equal(selection.snapshot.available, false); assert.equal(selection.snapshot.title, ''); assert.equal(selection.snapshot.canPlayPause, false);
  const fresh = await selection.poll(); assert.equal(fresh?.sourceId, 'QQMusic.exe');
  old.resolve(snapshot('cloudmusic.exe')); assert.equal(await pending, null);
  assert.equal(selection.snapshot.sourceId, 'QQMusic.exe');
});
test('旧来源的查询错误不得覆盖新来源，重复当前轮询合并', async () => {
  const old = deferred<MediaSnapshot>(); let calls = 0;
  const selection = new MediaSelection({ snapshot: async preferred => { calls++; return preferred ? snapshot(preferred) : old.promise; }, control: async () => {} });
  const pending = selection.poll(); assert.equal(await selection.poll(), null); assert.equal(calls, 1);
  selection.select('QQMusic.exe'); await selection.poll(); old.reject(new Error('旧来源超时'));
  assert.equal(await pending, null); assert.equal(selection.snapshot.available, true); assert.equal(selection.snapshot.error, undefined);
});
test('手选来源离线时保留来源且禁用控制，不使用其他仍在线的播放器', async () => {
  const controls: string[] = [];
  const selection = new MediaSelection({ snapshot: async preferred => ({ ...emptyMedia(), sourceId: preferred!, sources: sourceList.slice(0, 1), playerName: 'QQ 音乐', error: '所选播放器离线' }),
    control: async id => { controls.push(id); } });
  selection.select('QQMusic.exe'); await selection.poll();
  assert.equal(selection.preferredSourceId, 'QQMusic.exe'); assert.equal(selection.snapshot.sourceId, 'QQMusic.exe');
  await assert.rejects(selection.control('cloudmusic.exe', 'token-cloudmusic.exe', 'toggle'));
  await assert.rejects(selection.control('QQMusic.exe', 'token-QQMusic.exe', 'toggle')); assert.deepEqual(controls, []);
});
test('原生错误回传其他可用来源时前端拒绝显示为固定来源', async () => {
  const selection = new MediaSelection({ snapshot: async () => snapshot('cloudmusic.exe'), control: async () => {} });
  selection.select('QQMusic.exe'); await selection.poll();
  assert.equal(selection.snapshot.available, false); assert.equal(selection.snapshot.sourceId, 'QQMusic.exe');
  assert.match(selection.snapshot.error!, /来源已经变化/);
});
test('控制绑定点击时的来源，自动来源改变后不将旧按钮发给新播放器', async () => {
  let next = snapshot('cloudmusic.exe');
  const controls: { id: string; action: string; position?: number }[] = [];
  const selection = new MediaSelection({ snapshot: async () => next,
    control: async (id, _sessionToken, action, position) => { controls.push({ id, action, position }); } });
  await selection.poll(); await selection.control('cloudmusic.exe', 'token-cloudmusic.exe', 'seek', 44);
  next = snapshot('QQMusic.exe'); await selection.poll();
  await assert.rejects(selection.control('cloudmusic.exe', 'token-cloudmusic.exe', 'toggle'));
  await selection.control('QQMusic.exe', 'token-QQMusic.exe', 'toggle');
  assert.deepEqual(controls, [{ id: 'cloudmusic.exe', action: 'seek', position: 44 }, { id: 'QQMusic.exe', action: 'toggle', position: undefined }]);
});
test('旧控制完成或失败不得触发新来源重绘', async () => {
  for (const fails of [false, true]) {
    const pendingControl = deferred<void>();
    const selection = new MediaSelection({ snapshot: async preferred => snapshot(preferred || 'cloudmusic.exe'), control: async () => pendingControl.promise });
    await selection.poll(); const control = selection.control('cloudmusic.exe', 'token-cloudmusic.exe', 'toggle');
    selection.select('QQMusic.exe'); await selection.poll();
    if (fails) pendingControl.reject(new Error('旧控制失败')); else pendingControl.resolve();
    assert.equal(await control, false); assert.equal(selection.snapshot.sourceId, 'QQMusic.exe');
  }
});
test('同一播放器切到新曲目后，旧曲目的控制完成也不越代刷新', async () => {
  const pending = deferred<void>(); let next = snapshot('QQMusic.exe', '旧歌曲');
  const selection = new MediaSelection({ snapshot: async () => next, control: async () => pending.promise });
  await selection.poll(); const control = selection.control('QQMusic.exe', 'token-QQMusic.exe', 'seek', 30);
  next = snapshot('QQMusic.exe', '新歌曲'); await selection.poll(); pending.resolve();
  assert.equal(await control, false); assert.equal(selection.snapshot.title, '新歌曲');
});
test('同来源同曲目更换会话token后，旧DOM控制被拒绝且不能借用新token', async () => {
  let next = { ...snapshot('QQMusic.exe', '同一歌曲'), sessionToken: 'session-A' };
  const received: string[] = [];
  const selection = new MediaSelection({ snapshot: async () => next, control: async (_id, token) => { received.push(token); } });
  await selection.poll();
  const renderedToken = selection.snapshot.sessionToken!;
  const generation = selection.generation;
  next = { ...next, sessionToken: 'session-B' }; await selection.poll();
  assert.ok(selection.generation > generation);
  await assert.rejects(selection.control('QQMusic.exe', renderedToken, 'toggle'), /会话已变化/);
  assert.deepEqual(received, []);
  await selection.control('QQMusic.exe', 'session-B', 'toggle');
  assert.deepEqual(received, ['session-B']);
});
test('原生绑定B但新快照尚未回到界面时，控制仍携带旧DOM的A而非B', async () => {
  const delayedSnapshot = deferred<MediaSnapshot>();
  let nativeToken = 'session-A', delay = false;
  const received: string[] = [], accepted: string[] = [];
  const selection = new MediaSelection({
    snapshot: async () => delay ? delayedSnapshot.promise : { ...snapshot('QQMusic.exe', '同一歌曲'), sessionToken: nativeToken },
    control: async (_id, token) => {
      received.push(token);
      if (token !== nativeToken) throw new Error('原生会话已变化');
      accepted.push(token);
    },
  });
  await selection.poll(); const renderedToken = selection.snapshot.sessionToken!;
  nativeToken = 'session-B'; delay = true; const pending = selection.poll();
  await assert.rejects(selection.control('QQMusic.exe', renderedToken, 'toggle'), /原生会话已变化/);
  assert.deepEqual(received, ['session-A']); assert.deepEqual(accepted, []);
  delayedSnapshot.resolve({ ...snapshot('QQMusic.exe', '同一歌曲'), sessionToken: 'session-B' }); await pending;
  await selection.control('QQMusic.exe', 'session-B', 'toggle'); assert.deepEqual(accepted, ['session-B']);
});
test('同来源同曲目token变更后，旧控制完成和错误都不能越代刷新', async () => {
  for (const fails of [false, true]) {
    const delayedControl = deferred<void>();
    let next = { ...snapshot('QQMusic.exe', '同一歌曲'), sessionToken: 'session-A' };
    const selection = new MediaSelection({ snapshot: async () => next, control: async () => delayedControl.promise });
    await selection.poll(); const pending = selection.control('QQMusic.exe', 'session-A', 'seek', 10);
    next = { ...next, sessionToken: 'session-B' }; await selection.poll();
    if (fails) delayedControl.reject(new Error('旧会话错误')); else delayedControl.resolve();
    assert.equal(await pending, false); assert.equal(selection.snapshot.sessionToken, 'session-B');
  }
});
test('缺失会话token时不发送媒体控制', async () => {
  let calls = 0;
  const selection = new MediaSelection({ snapshot: async () => ({ ...snapshot('QQMusic.exe'), sessionToken: null }), control: async () => { calls++; } });
  await selection.poll();
  await assert.rejects(selection.control('QQMusic.exe', '', 'toggle'));
  assert.equal(calls, 0);
});
test('旧歌词即使曲名相同，也不能越过手动来源切换', async () => {
  const pending = deferred<LyricsCandidate[]>();
  const controller = new LyricsController(async () => pending.promise);
  let applied = false;
  const old = controller.load(snapshot('cloudmusic.exe', '同名曲'), () => { applied = true; });
  controller.cancel();
  pending.resolve([{ id: 1, trackName: '同名曲', artistName: '歌手', albumName: '', duration: 200, instrumental: false, syncedLyrics: '[00:01]旧歌词', plainLyrics: '旧歌词' }]);
  await old; assert.equal(applied, false);
});
test('来源选择限制无效标识，回到自动模式传入null', async () => {
  const queries: (string | null)[] = [];
  const selection = new MediaSelection({ snapshot: async id => { queries.push(id); return snapshot(id || 'cloudmusic.exe'); }, control: async () => {} });
  for (const value of ['', ' ', 'a\0b', 'x'.repeat(4097)]) assert.throws(() => selection.select(value));
  selection.select('QQMusic.exe'); await selection.poll(); selection.select(null); await selection.poll();
  assert.deepEqual(queries, ['QQMusic.exe', null]);
});
