import { test } from 'node:test';
import assert from 'node:assert/strict';
import { chooseCandidate, currentLyric, emptyMedia, LyricsController, mediaPosition, parseLrc, trackKey, type LyricsCandidate, type RetryScheduler } from '../src/lyrics';

const candidate = (override: Partial<LyricsCandidate> = {}): LyricsCandidate => ({ id: 1, trackName: '测试歌曲', artistName: '歌手', albumName: '专辑', duration: 180, instrumental: false, syncedLyrics: '[00:01.20]第一句\n[00:05]第二句', plainLyrics: '第一句\n第二句', ...override });
const media = { ...emptyMedia(), available: true, sourceId: 'player', title: '测试歌曲', artist: '歌手', album: '专辑', duration: 180 };
test('长未闭合标签按线性路径解析，保留空标签和原有嵌套标签语义', () => {
  const unmatched = '['.repeat(100000);
  const start = performance.now();
  assert.deepEqual(parseLrc('[00:01.00]'+unmatched), [{at:1,text:unmatched}]);
  assert.ok(performance.now()-start < 1500, '100KB不应重现原先超过5秒的二次扫描');
  assert.deepEqual(parseLrc('[00:01]a[]b[x[y]c[open'), [{at:1,text:'a[]bc[open'}]);
  assert.equal(chooseCandidate([candidate({syncedLyrics:'[00:01]'+unmatched})],media)?.id,1);
});
test('解析预算拒绝超长歌词和过多时间戳，无关候选无需解析', () => {
  assert.throws(()=>parseLrc('x'.repeat(2*1024*1024+1)), /解析上限/);
  assert.throws(()=>parseLrc('[00:01]'.repeat(10001)+'text'), /解析上限/);
  assert.equal(chooseCandidate([candidate({trackName:'无关歌曲',syncedLyrics:'x'.repeat(2*1024*1024+1)}),candidate()],media)?.id,1);
});
test('多时间戳不能把小输入放大成巨量正文，超限候选不阻断合法候选', async () => {
  const expansion = '[00:01]'.repeat(10000) + 'x'.repeat(100000);
  assert.ok(expansion.length < 200000);
  assert.throws(()=>parseLrc(expansion), /展开正文超过解析上限/);
  const heavy=candidate({id:2,syncedLyrics:expansion});
  assert.equal(chooseCandidate([heavy,candidate()],media)?.id,1);
  assert.throws(()=>chooseCandidate([heavy],media), /展开正文/);
  const controller=new LyricsController(async()=>[heavy,candidate()]);
  let output='';await controller.load(media,value=>{output=value?.lines[0].text || '';});
  assert.equal(output,'第一句');
});
test('LRC 支持多时间戳、毫秒、偏移、元数据，按时间排序', () => {
  const lines = parseLrc('[ar:歌手]\n[offset:-200]\n[00:02.500][00:04]同一句\n[00:00.1]开头\n[00:99]无效');
  assert.deepEqual(lines, [{ at: 0, text: '开头' }, { at: 2.3, text: '同一句' }, { at: 3.8, text: '同一句' }]);
  assert.equal(currentLyric(lines, -1), -1); assert.equal(currentLyric(lines, 2.4), 1); assert.equal(currentLyric(lines, 99), 2);
});
test('歌词候选必须匹配曲名和非空歌手，并拒绝错误时长', () => {
  assert.equal(chooseCandidate([candidate({ trackName: '同名以外' })], media), null);
  assert.equal(chooseCandidate([candidate({ artistName: '另一个人' })], media), null);
  assert.equal(chooseCandidate([candidate({ artistName: '' })], media), null);
  assert.equal(chooseCandidate([candidate({ duration: 200 })], media), null);
  assert.equal(chooseCandidate([candidate({ id: 2, albumName: '其他', syncedLyrics: null }), candidate()], media)?.id, 1);
});
test('歌手只做完整名称匹配，排版空格可归一但不猜测多艺人集合', () => {
  assert.equal(chooseCandidate([candidate({ artistName: '歌手乐队' })], media), null);
  assert.equal(chooseCandidate([candidate()], { ...media, artist: '' }), null);
  assert.equal(chooseCandidate([candidate({ artistName: '甲/乙' })], { ...media, artist: ' 甲 / 乙 ' })?.id, 1);
  assert.equal(chooseCandidate([candidate({ artistName: '甲' })], { ...media, artist: '甲 / 乙' }), null);
  assert.equal(chooseCandidate([candidate({ artistName: '乙/甲' })], { ...media, artist: '甲/乙' }), null);
  assert.equal(chooseCandidate([candidate({ artistName: 'ACDC' })], { ...media, artist: 'AC/DC' }), null);
  assert.equal(chooseCandidate([candidate({ artistName: 'ＡＣ／ＤＣ' })], { ...media, artist: 'AC/DC' })?.id, 1);
  assert.equal(chooseCandidate([candidate({ trackName: '测试歌曲 (Live)' })], media), null);
  assert.equal(chooseCandidate([candidate({ trackName: '测试歌曲 (Remix)' })], media), null);
});
test('本地进度推进在暂停时停止、受时长限制，失联最多推进3秒', () => {
  const sample = { ...media, position: 178, sampledAt: 10000, playing: true };
  assert.equal(mediaPosition(sample, 11000), 179); assert.equal(mediaPosition(sample, 20000), 180);
  assert.equal(mediaPosition({ ...sample, duration: null }, 100000), 181);
  assert.equal(mediaPosition({ ...sample, playing: false }, 12000), 178);
  assert.equal(mediaPosition({ ...sample, position: null }, 12000), null);
});
test('本地进度按真实0.5倍和2倍速度推进，旧快照和无效速率采用1倍，暂停不推进', () => {
  const sample = { ...media, position: 10, sampledAt: 10000, playing: true };
  assert.equal(mediaPosition({ ...sample, playbackRate: 0.5 }, 12000), 11);
  assert.equal(mediaPosition({ ...sample, playbackRate: 2 }, 12000), 14);
  assert.equal(mediaPosition({ ...sample, playbackRate: 0 }, 12000), 10);
  for (const playbackRate of [undefined, null, NaN, Infinity, -1, 17]) {
    assert.equal(mediaPosition({ ...sample, playbackRate }, 12000), 12);
  }
  assert.equal(mediaPosition({ ...sample, playbackRate: 2, playing: false }, 12000), 10);
  assert.equal(mediaPosition({ ...sample, playbackRate: 2 }, 99999), 16);
});
test('过期请求不得覆盖新歌歌词，但仍可缓存供之后返回', async () => {
  let resolveFirst!: (items: LyricsCandidate[]) => void;
  const seen: string[] = [];
  const controller = new LyricsController(async input => input.title === '测试歌曲'
    ? new Promise(resolve => { resolveFirst = resolve; }) : [candidate({ trackName: '新歌', plainLyrics: '新歌词', syncedLyrics: null })]);
  const first = controller.load(media, value => seen.push(value!.plain));
  await controller.load({ ...media, title: '新歌' }, value => seen.push(value!.plain));
  resolveFirst([candidate()]); await first;
  assert.deepEqual(seen, ['新歌词']);
  await controller.load(media, value => seen.push(value!.plain));
  assert.deepEqual(seen, ['新歌词', '第一句\n第二句']);
});
test('歌词缓存命中、过期与取消后的请求不会更新界面', async () => {
  let calls = 0, now = 1000;
  const controller = new LyricsController(async () => { calls++; return [candidate()]; }, () => now);
  await controller.load(media, () => {}); await controller.load(media, () => {}); assert.equal(calls, 1);
  now += 86400001; await controller.load(media, () => {}); assert.equal(calls, 2);
  let resolve!: (value: LyricsCandidate[]) => void;
  const pending = new LyricsController(() => new Promise(r => { resolve = r; }));
  let applied = false; const result = pending.load(media, () => { applied = true; });
  pending.cancel(); resolve([candidate()]); await result; assert.equal(applied, false);
});
test('晚到的时长重新校验歌词；网络错误不会当成无歌词缓存', async () => {
  let calls = 0;
  const controller = new LyricsController(async () => { calls++; return [candidate({ duration: 200 })]; });
  const selected: boolean[] = [];
  await controller.load({ ...media, duration: null }, value => selected.push(!!value));
  await controller.load(media, value => selected.push(!!value));
  assert.deepEqual(selected, [true, false]); assert.equal(calls, 2);
  assert.notEqual(trackKey(media), trackKey({ ...media, duration: null }));
  let fail = true;
  const flaky = new LyricsController(async () => { if (fail) throw new Error('network'); return [candidate()]; }, Date.now, { retryDelaysMs: [0, 0] });
  await assert.rejects(flaky.load(media, () => {})); fail = false;
  let applied = false; await flaky.load(media, value => { applied = !!value; }); assert.equal(applied, true);
});

test('同曲网络失败自动有限重试，成功只应用一次，真实空结果不重试', async () => {
  let calls = 0, applied = 0;
  const controller = new LyricsController(async () => { if (++calls < 3) throw new Error('network timeout'); return [candidate()]; }, Date.now, { retryDelaysMs: [0, 0] });
  await controller.load(media, () => { applied++; }); assert.equal(calls, 3); assert.equal(applied, 1);
  let emptyCalls = 0;
  const empty = new LyricsController(async () => { emptyCalls++; return []; }, Date.now, { retryDelaysMs: [0, 0] });
  await empty.load(media, value => assert.equal(value, null)); await empty.load(media, () => {}); assert.equal(emptyCalls, 1);
  let errors = 0;
  const broken = new LyricsController(async () => { errors++; throw new Error('network'); }, Date.now, { retryDelaysMs: [0, 0] });
  await assert.rejects(broken.load(media, () => {})); assert.equal(errors, 3); broken.cancel();
});
test('取消退避后立即结束，不再请求；旧请求失败不重试到新歌曲', async () => {
  let calls = 0, applies = 0;
  const waiting = new LyricsController(async () => { calls++; throw new Error('network'); }, Date.now, { retryDelaysMs: [30000, 30000] });
  const pending = waiting.load(media, () => { applies++; }); await Promise.resolve(); waiting.cancel(); await pending;
  assert.equal(calls, 1); assert.equal(applies, 0);
  let rejectOld!: (error: Error) => void;
  const switched = new LyricsController(async input => input.title === media.title ? new Promise((_resolve, reject) => { rejectOld = reject; }) : [candidate({ trackName: '新歌' })], Date.now, { retryDelaysMs: [0, 0] });
  const old = switched.load(media, () => { throw new Error('old must not apply'); }); await switched.load({ ...media, title: '新歌' }, () => {});
  rejectOld(new Error('network')); await old;
});
test('解码/参数错误不进行网络重试', async () => {
  let calls = 0; const controller = new LyricsController(async () => { calls++; throw new Error('歌词服务返回了无法识别的数据'); }, Date.now, { retryDelaysMs: [0, 0] });
  await assert.rejects(controller.load(media, () => {})); assert.equal(calls, 1);
});

test('空歌词和损坏同步歌词不能盖过有效纯文本候选', () => {
  const unavailable = candidate({ syncedLyrics: null, plainLyrics: null });
  assert.equal(chooseCandidate([unavailable], media), null);
  const plain = candidate({ id: 2, albumName: '其他版本专辑', syncedLyrics: null, plainLyrics: '有效原文' });
  assert.equal(chooseCandidate([unavailable, plain], media)?.id, 2);
  assert.equal(chooseCandidate([candidate({ syncedLyrics: '[00:99]坏时间', plainLyrics: null })], media), null);
});

test('曲名保留加号等符号，兼容全角排版，LRC拒绝非有限时间', () => {
  const symbolic = { ...media, title: 'A+B' };
  assert.equal(chooseCandidate([candidate({ trackName: 'AB' })], symbolic), null);
  assert.equal(chooseCandidate([candidate({ trackName: 'Ａ＋Ｂ' })], symbolic)?.id, 1);
  for (const stamp of ['00:1', '00:01.1234', '00:01e0', '00:60', '00:01.', `${'9'.repeat(400)}:01`]) {
    assert.deepEqual(parseLrc(`[${stamp}]词`), [], stamp);
  }
  assert.deepEqual(parseLrc(`[offset:${'9'.repeat(400)}]\n[00:01]词`), [{ at: 1, text: '词' }]);
  assert.equal(chooseCandidate([candidate({ syncedLyrics: null, plainLyrics: '\uFEFF\u2028 \t' })], media), null);
  assert.equal(chooseCandidate([candidate({ syncedLyrics: null, plainLyrics: '\u0085' })], media)?.id, 1);
});

test('同一整数秒内的时长变化仍重新校验8秒匹配边界', async () => {
  let calls = 0;
  const controller = new LyricsController(async () => { calls++; return [candidate()]; });
  const selected: boolean[] = [];
  await controller.load({ ...media, duration: 187.6 }, lyrics => selected.push(!!lyrics));
  await controller.load({ ...media, duration: 188.4 }, lyrics => selected.push(!!lyrics));
  assert.deepEqual(selected, [true, false]); assert.equal(calls, 2);
});

test('同曲不足一秒的时长波动同步复用已匹配歌词，不重新请求或短暂清空', async () => {
  let calls = 0, current: unknown, synchronous = false;
  const controller = new LyricsController(async () => { calls++; return [candidate()]; });
  await controller.load(media, lyrics => { current = lyrics; });
  const original = current;
  const load = controller.load({ ...media, duration: 180.4 }, lyrics => { current = lyrics; synchronous = true; });
  assert.equal(calls, 1); assert.equal(synchronous, true); assert.equal(current, original);
  await load;
  assert.notEqual(trackKey(media), trackKey({ ...media, duration: 180.4 }));
  await controller.load({ ...media, duration: 180.4 }, lyrics => assert.equal(lyrics, original));
  assert.equal(calls, 1);
});

test('时长复用不跨来源、艺人、专辑或歌曲版本，也不跨未知时长与一秒边界', async () => {
  for (const changed of [{ sourceId: 'another-player' }, { artist: '另一位歌手' }, { album: '另一张专辑' },
    { title: '测试歌曲 (Live)' }, { duration: null }, { duration: 181 }]) {
    let calls = 0;
    const controller = new LyricsController(async () => { calls++; return [candidate()]; });
    await controller.load(media, () => {});
    await controller.load({ ...media, duration: 180.4, ...changed }, () => {});
    assert.equal(calls, 2, JSON.stringify(changed));
  }
});

test('真实空结果清除可复用候选，未命中的新精确时长仍重新查询', async () => {
  let calls = 0;
  const controller = new LyricsController(async () => ++calls === 1 ? [candidate()] : []);
  await controller.load(media, lyrics => assert.ok(lyrics));
  await controller.load({ ...media, duration: 181 }, lyrics => assert.equal(lyrics, null));
  await controller.load({ ...media, duration: 180.5 }, lyrics => assert.equal(lyrics, null));
  assert.equal(calls, 3);
});

test('取消后迟到的旧候选不会覆盖当前曲目的可复用歌词', async () => {
  let resolveOld!: (candidates: LyricsCandidate[]) => void, calls = 0;
  const controller = new LyricsController(async input => {
    calls++;
    return input.sourceId === media.sourceId ? new Promise(resolve => { resolveOld = resolve; })
      : [candidate({ id: 2, plainLyrics: '当前播放器歌词' })];
  });
  const old = controller.load(media, () => assert.fail('旧请求不得更新界面'));
  controller.cancel();
  const selected = { ...media, sourceId: 'new-player' };
  await controller.load(selected, lyrics => assert.equal(lyrics?.plain, '当前播放器歌词'));
  resolveOld([candidate({ plainLyrics: '迟到歌词' })]); await old;
  await controller.load({ ...selected, duration: 180.4 }, lyrics => assert.equal(lyrics?.plain, '当前播放器歌词'));
  assert.equal(calls, 2);
});

test('精确缓存命中可恢复当前复用候选，浮动时长不能延长原始缓存有效期', async () => {
  let calls = 0, now = 1000;
  const controller = new LyricsController(async input => { calls++; return [candidate({ trackName: input.title })]; }, () => now);
  await controller.load(media, () => {});
  await controller.load({ ...media, title: '另一首歌' }, () => {});
  await controller.load(media, () => {});
  now += 100;
  await controller.load({ ...media, duration: 180.4 }, () => {});
  assert.equal(calls, 2);
  now = 1000 + 86400001;
  await controller.load({ ...media, duration: 180.5 }, () => {});
  assert.equal(calls, 3);
});

function manualRetries(): { schedule: RetryScheduler; delays: () => number[]; fire: () => void } {
  let next = 0;
  const pending = new Map<number, { callback: () => void; delay: number }>();
  return {
    schedule: (callback, delay) => { const id = next++; pending.set(id, { callback, delay }); return () => { pending.delete(id); }; },
    delays: () => [...pending.values()].map(task => task.delay),
    fire: () => { const [id, task] = pending.entries().next().value!; pending.delete(id); task.callback(); },
  };
}
async function settle(): Promise<void> { for (let index = 0; index < 10; index++) await Promise.resolve(); }

test('短重试失败后仍以15/30/60/120秒恢复同曲歌词，成功后终止重试', async () => {
  const timers = manualRetries(); let calls = 0, applied = 0; const errors: unknown[] = [];
  const controller = new LyricsController(async () => {
    if (++calls <= 7) throw new Error('network timeout');
    return [candidate()];
  }, Date.now, { scheduleRetry: timers.schedule });
  const initial = assert.rejects(controller.load(media, value => { assert.ok(value); applied++; }, error => errors.push(error)), /network/);
  await settle(); assert.deepEqual(timers.delays(), [1000]);
  timers.fire(); await settle(); assert.deepEqual(timers.delays(), [3000]);
  timers.fire(); await initial; assert.equal(calls, 3);
  for (const delay of [15000, 30000, 60000, 120000, 120000]) {
    assert.deepEqual(timers.delays(), [delay]); timers.fire(); await settle();
  }
  assert.equal(calls, 8); assert.equal(applied, 1); assert.equal(errors.length, 4);
  assert.deepEqual(timers.delays(), []);
});

test('后台重试等待期间可取消，关闭歌词后不会再发请求', async () => {
  const timers = manualRetries(); let calls = 0;
  const controller = new LyricsController(async () => { calls++; throw new Error('network'); }, Date.now,
    { retryDelaysMs: [], scheduleRetry: timers.schedule });
  await assert.rejects(controller.load(media, () => assert.fail('must not apply')));
  assert.deepEqual(timers.delays(), [15000]); controller.cancel();
  assert.deepEqual(timers.delays(), []); assert.equal(calls, 1);
});

test('重试定时器触发后立即关闭歌词，微任务不能再次发出已取消的请求', async () => {
  const timers = manualRetries(); let calls = 0;
  const controller = new LyricsController(async () => { calls++; throw new Error('network'); }, Date.now,
    { retryDelaysMs: [], scheduleRetry: timers.schedule });
  await assert.rejects(controller.load(media, () => assert.fail('must not apply')));
  timers.fire(); controller.cancel(); await settle();
  assert.equal(calls, 1); assert.deepEqual(timers.delays(), []);
});

test('后台请求未完成时不排新请求，换曲后迟到的失败也不能恢复旧曲重试', async () => {
  const timers = manualRetries(); let calls = 0, rejectOld!: (error: Error) => void;
  const seen: string[] = [], errors: unknown[] = [];
  const controller = new LyricsController(async input => {
    calls++;
    if (input.title !== media.title) return [candidate({ trackName: '新歌' })];
    if (calls === 1) throw new Error('network');
    return new Promise((_resolve, reject) => { rejectOld = reject; });
  }, Date.now, { retryDelaysMs: [], scheduleRetry: timers.schedule });
  await assert.rejects(controller.load(media, () => seen.push('old'), error => errors.push(error)));
  timers.fire(); await settle(); assert.equal(calls, 2); assert.deepEqual(timers.delays(), []);
  await controller.load({ ...media, title: '新歌' }, () => seen.push('new'));
  rejectOld(new Error('network')); await settle();
  assert.deepEqual(seen, ['new']); assert.deepEqual(errors, []); assert.deepEqual(timers.delays(), []);
});

test('后台真实空结果停止网络重试，非网络错误和错误回调不会产生未处理拒绝', async () => {
  for (const result of ['empty', 'invalid'] as const) {
    const timers = manualRetries(); let calls = 0, errors = 0, applied = 0;
    const controller = new LyricsController(async () => {
      if (++calls === 1) throw new Error('network');
      if (result === 'invalid') throw new Error('歌词服务返回了无法识别的数据');
      return [];
    }, Date.now, { retryDelaysMs: [], scheduleRetry: timers.schedule });
    await assert.rejects(controller.load(media, value => { assert.equal(value, null); applied++; }, () => { errors++; throw new Error('UI failed'); }));
    timers.fire(); await settle();
    assert.equal(calls, 2); assert.equal(applied, result === 'empty' ? 1 : 0); assert.equal(errors, result === 'invalid' ? 1 : 0);
    assert.deepEqual(timers.delays(), []);
  }
});
