import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isQuietHours, planReminders, reminderKey, RefreshScheduler } from '../src/calendar-services';
import type { CalendarEvent } from '../src/calendar';
import { expandCalendars, validateCalendar } from '../src/calendar';

const settings = { reminderEnabled: true, reminderLeadMinutes: 5, quietHoursEnabled: false, quietHoursStart: '22:00', quietHoursEnd: '07:00' };
const now = new Date(2026, 9, 17, 12, 0, 0);
const event = (id: string, minutes: number, allDay = false): CalendarEvent => ({ id, sourceId: 'source', title: id,
  start: new Date(+now + minutes * 60000).toISOString(), end: new Date(+now + (minutes + 60) * 60000).toISOString(), allDay, location: '', description: '' });
const ics = 'BEGIN:VCALENDAR\nVERSION:2.0\nEND:VCALENDAR';
const source = { id: 'source', path: 'C:\\calendar.ics', name: 'calendar.ics', content: ics, importedAt: now.toISOString() };

test('提醒跳过全天/过去事件，一次返回全部到期项，保存键后重启不重复', () => {
  const events = [event('later', 4), event('past', -1), event('all-day', 0, true), event('first', 2)];
  const first = planReminders(events, settings, [], now); assert.deepEqual(first.due.map(e => e.id), ['first', 'later']);
  assert.deepEqual(planReminders(events, settings, first.remindedEvents, now).due, []);
  assert.equal(planReminders(events, { ...settings, reminderEnabled: false }, [], now).due.length, 0);
  const rescheduled = { ...events[3], start: new Date(+now + 60000).toISOString() };
  assert.equal(planReminders([rescheduled], settings, first.remindedEvents, now).due.length, 1);
});
test('跨午夜勿扰含起点不含终点，相同时间为空区间且不消费提醒', () => {
  const quiet = { ...settings, quietHoursEnabled: true };
  for (const hour of [22, 23, 0, 6]) assert.ok(isQuietHours(quiet, new Date(2026, 9, 17, hour, 0)));
  for (const hour of [7, 12, 21]) assert.equal(isQuietHours(quiet, new Date(2026, 9, 17, hour, 0)), false);
  assert.equal(isQuietHours({ ...quiet, quietHoursStart: '07:00' }, now), false);
  const suppressed = planReminders([event('a', 1)], { ...quiet, quietHoursStart: '11:00', quietHoursEnd: '13:00' }, [], now);
  assert.deepEqual(suppressed.newKeys, []);
});
test('零提前量允许轮询延迟，剪除过期键且总量受限', () => {
  assert.equal(planReminders([event('a', -0.2)], { ...settings, reminderLeadMinutes: 0 }, [], now).due.length, 1);
  assert.equal(planReminders([event('a', -1)], { ...settings, reminderLeadMinutes: 0 }, [], now).due.length, 0);
  const keys = Array.from({ length: 5100 }, (_, i) => `id${i}@${+now + 60000}`);
  const result = planReminders([], settings, ['bad', reminderKey(event('old', -61)), ...keys], now);
  assert.equal(result.remindedEvents.length, 5000); assert.ok(!result.remindedEvents.includes('bad'));
});
test('自动刷新只返回验证成功的新数据；错误不清空旧日历并按重试间隔再次读取', async () => {
  let calls = 0, fail = true;
  const scheduler = new RefreshScheduler({ read: async path => { calls++; if (fail) throw new Error('offline'); return { path, name: 'new.ics', content: ics }; }, validate: sources => { for (const source of sources) validateCalendar(source.content); } });
  const first = await scheduler.refresh([source], true, 1000); assert.equal(first.errors.length, 1); assert.deepEqual(first.updates, []); assert.equal(source.content, ics);
  await scheduler.refresh([source], true, 2000); assert.equal(calls, 1);
  fail = false; const next = await scheduler.refresh([source], true, 31000); assert.equal(calls, 2); assert.equal(next.updates[0].previousContent, ics);
  await scheduler.refresh([source], true, 32000); assert.equal(calls, 2);
});
test('畸形内容/错来源被拒绝，取消后的在途结果不覆盖新来源', async () => {
  for (const result of [{ path: source.path, name: 'bad', content: 'broken' }, { path: 'C:\\other.ics', name: source.name, content: ics }]) {
    const scheduler = new RefreshScheduler({ read: async () => result, validate: sources => { for (const source of sources) validateCalendar(source.content); } });
    const refreshed = await scheduler.refresh([source], true); assert.equal(refreshed.errors.length, 1); assert.deepEqual(refreshed.updates, []);
  }
  let finish!: (value: typeof source) => void;
  const scheduler = new RefreshScheduler({ read: () => new Promise(resolve => { finish = resolve; }), validate: sources => { for (const source of sources) validateCalendar(source.content); } });
  const pending = scheduler.refresh([source], true); assert.deepEqual(await scheduler.refresh([source], true), { updates: [], errors: [] });
  scheduler.cancel(); finish({ ...source, name: 'late.ics' }); assert.deepEqual(await pending, { updates: [], errors: [] });
});

test('关闭刷新立即使在途读取失效；重新启用的新结果不被旧请求打断', async () => {
  const pendingReads: ((value: { path: string; name: string; content: string }) => void)[] = [];
  const scheduler = new RefreshScheduler({ read: () => new Promise(resolve => pendingReads.push(resolve)), validate: sources => { for (const source of sources) validateCalendar(source.content); } });
  const first = scheduler.refresh([source], true, 1000);
  assert.deepEqual(await scheduler.refresh([source], false, 2000), { updates: [], errors: [] });
  const restarted = scheduler.refresh([source], true, 3000);
  assert.equal(pendingReads.length, 2);
  pendingReads[0]({ ...source, name: 'stale.ics' }); assert.deepEqual(await first, { updates: [], errors: [] });
  assert.deepEqual(await scheduler.refresh([source], true, 4000), { updates: [], errors: [] });
  pendingReads[1]({ ...source, name: 'current.ics' });
  assert.equal((await restarted).updates[0].name, 'current.ics');
});

test('刷新逐个保留来源，成功项和失败项可独立提交，强制刷新跳过间隔', async () => {
  let calls = 0;
  const scheduler = new RefreshScheduler({ read: async path => {
    calls++; if (path.endsWith('bad.ics')) throw new Error('文件无法读取');
    return { path, name: 'updated.ics', content: ics };
  }, validate: sources => { for (const source of sources) validateCalendar(source.content); } });
  const other = { ...source, id: 'other', path: 'C:\\bad.ics' };
  const result = await scheduler.refresh([source, other], true, 1000);
  assert.deepEqual(result.updates.map(value => value.id), ['source']);
  assert.deepEqual(result.errors.map(value => value.id), ['other']);
  await scheduler.refresh([source, other], true, 2000, true); assert.equal(calls, 4);
  assert.equal(source.name, 'calendar.ics'); assert.equal(other.content, ics);
});

test('提醒窗口的边界、无效设置与勿扰结束后的计划保持确定', () => {
  const zero = { ...settings, reminderLeadMinutes: 0 };
  assert.equal(planReminders([event('now', 0)], zero, [], now).due.length, 1);
  assert.equal(planReminders([event('future', 0.01)], zero, [], now).due.length, 0);
  assert.equal(planReminders([event('old-boundary', -1)], zero, [], now).due.length, 0);
  for (const lead of [-1, NaN, Infinity, 0.5, 1441]) {
    assert.deepEqual(planReminders([event('a', 1)], { ...settings, reminderLeadMinutes: lead }, [], now).due, []);
  }
  const duringQuiet = { ...settings, quietHoursEnabled: true, quietHoursStart: '11:00', quietHoursEnd: '12:01' };
  const suppressed = planReminders([event('a', 2)], duringQuiet, [], now);
  assert.deepEqual(suppressed.remindedEvents, []);
  assert.equal(planReminders([event('a', 2)], duringQuiet, suppressed.remindedEvents, new Date(+now + 60000)).due.length, 1);
});

test('刷新必须等待整批异步展开成功，失败保留所有旧内容', async () => {
  let finish!: () => void;
  const scheduler = new RefreshScheduler({ read: async path => ({ path, name: 'new.ics', content: ics }),
    validate: async sources => { assert.equal(sources[0].name, 'new.ics'); await new Promise<void>(resolve => { finish = resolve; }); throw new Error('日历处理超时'); } });
  let completed = false;
  const pending = scheduler.refresh([source], true, 1000).then(result => { completed = true; return result; });
  await new Promise(resolve => setImmediate(resolve)); assert.equal(completed, false);
  finish(); const result = await pending;
  assert.deepEqual(result.updates, []); assert.match(result.errors[0].message, /超时/); assert.equal(source.name, 'calendar.ics');
});

test('取消刷新同时中止异步展开，迟到结果不发布', async () => {
  let finish!: () => void, signal!: AbortSignal;
  const scheduler = new RefreshScheduler({ read: async path => ({ path, name: 'new.ics', content: ics }),
    validate: async (_, current) => { signal = current; await new Promise<void>(resolve => { finish = resolve; }); } });
  const pending = scheduler.refresh([source], true);
  await new Promise(resolve => setImmediate(resolve)); scheduler.cancel();
  assert.equal(signal.aborted, true); finish(); assert.deepEqual(await pending, { updates: [], errors: [] });
});

test('同时开始的零提前量提醒跨过30秒仍批量返回，失败和勿扰都不消费', () => {
  const events = [event('a', 0), event('b', 0)], zero = { ...settings, reminderLeadMinutes: 0 };
  const delayed = new Date(+now + 31000);
  const first = planReminders(events, zero, [], delayed);
  assert.deepEqual(first.due.map(item => item.id), ['a', 'b']);
  assert.equal(first.newKeys.length, 2);
  // 声音失败时调用方不提交 newKeys，下一轮仍可重试全部事项。
  assert.deepEqual(planReminders(events, zero, [], new Date(+now + 40000)).due, events);
  assert.deepEqual(planReminders(events, zero, first.remindedEvents, new Date(+now + 40000)).due, []);
  const quiet = { ...zero, quietHoursEnabled: true, quietHoursStart: '11:00', quietHoursEnd: '13:00' };
  assert.deepEqual(planReminders(events, quiet, [], delayed).newKeys, []);
});

test('超过1000项的同批提醒保留全部去重键，输出上限5000项下一轮不重响', () => {
  const events = Array.from({ length: 5000 }, (_, index) => event(`same-time-${index}`, 0));
  const zero = { ...settings, reminderLeadMinutes: 0 };
  const first = planReminders(events, zero, [], new Date(+now + 1000));
  assert.equal(first.due.length, 5000); assert.equal(first.newKeys.length, 5000); assert.equal(first.remindedEvents.length, 5000);
  assert.deepEqual(planReminders(events, zero, first.remindedEvents, new Date(+now + 31000)).due, []);
});

test('语法合法但倒置的时间以及展开超额均保留刷新前内容', async () => {
  const invalid = 'BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VEVENT\nUID:bad\nDTSTART:20261017T120000Z\nDTEND:20261017T110000Z\nEND:VEVENT\nEND:VCALENDAR';
  const oversized = 'BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VEVENT\nUID:big\nDTSTART:20261001T000000Z\nRRULE:FREQ=MINUTELY;COUNT=6000\nEND:VEVENT\nEND:VCALENDAR';
  for (const content of [invalid, oversized]) {
    const scheduler = new RefreshScheduler({ read: async path => ({ path, name: 'changed.ics', content }), validate: candidates => {
      const result = expandCalendars(candidates, new Date('2026-10-01T00:00:00Z'), new Date('2026-11-01T00:00:00Z'));
      if (result.errors.length) throw new Error(result.errors.join('\n'));
    } });
    const result = await scheduler.refresh([source], true);
    assert.deepEqual(result.updates, []); assert.equal(result.errors.length, 1);
    assert.equal(source.content, ics); assert.equal(source.name, 'calendar.ics');
  }
});
