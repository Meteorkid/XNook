import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { CalendarEvent } from '../src/calendar';
import { calendarSourceColor, eventsForDay, eventStatus, localDateKey, localDayRange, overviewEvents, visibleDates } from '../src/calendar-view';

const at = (day: number, hour = 0, minute = 0): Date => new Date(2026, 9, day, hour, minute);
const event = (id: string, start: Date, end: Date, allDay = false): CalendarEvent => ({
  id, sourceId: 'calendar', title: id, start: start.toISOString(), end: end.toISOString(), allDay, location: '', description: '',
});

test('日历详情保留当天已结束项，概览只在今天隐藏并最多展示两项', () => {
  const now = at(17, 12);
  const events = [event('next-late', at(17, 16), at(17, 17)), event('ended', at(17, 9), at(17, 10)),
    event('ongoing', at(17, 11), at(17, 13)), event('next', at(17, 14), at(17, 15))];
  assert.deepEqual(eventsForDay(events, now).map(e => e.id), ['ended', 'ongoing', 'next', 'next-late']);
  assert.deepEqual(overviewEvents(events, now, now).map(e => e.id), ['ongoing', 'next']);
  assert.deepEqual(overviewEvents(events, now, at(18, 12)).map(e => e.id), ['ended', 'ongoing']);
  assert.equal(overviewEvents(events, now, at(16), 999).length, 2);
  assert.equal(overviewEvents(events, now, now, 0).length, 0);
  assert.equal(eventStatus(events[1], now), 'ended');
  assert.equal(eventStatus(events[2], now), 'ongoing');
  assert.equal(eventStatus(events[3], now), 'future');
});

test('跨日事件可用于每一天的标记，午夜结束排他，下一日开始不占前一天', () => {
  const events = [event('spanning', at(16, 23), at(18, 1)), event('previous', at(16, 20), at(17)),
    event('next', at(18), at(18, 1)), event('all-day', at(17), at(19), true)];
  assert.deepEqual(eventsForDay(events, at(17)).map(e => e.id), ['spanning', 'all-day']);
  assert.deepEqual(eventsForDay(events, at(18)).map(e => e.id), ['spanning', 'all-day', 'next']);
  assert.equal(eventsForDay(events, at(19)).length, 0);
  assert.equal(events.length, 4);
});

test('零时长事件属于开始日，到达瞬间可见，之后从今日概览消失', () => {
  const instant = event('instant', at(17, 12), at(17, 12));
  const midnight = event('midnight', at(17), at(17));
  assert.deepEqual(eventsForDay([instant, midnight], at(17)).map(e => e.id), ['midnight', 'instant']);
  assert.equal(eventsForDay([midnight], at(16)).length, 0);
  assert.equal(overviewEvents([instant], at(17), at(17, 12)).length, 1);
  assert.equal(eventStatus(instant, at(17, 12)), 'future');
  assert.equal(overviewEvents([instant], at(17), new Date(+at(17, 12) + 1)).length, 0);
  assert.equal(eventStatus(instant, new Date(+at(17, 12) + 1)), 'ended');
});

test('月历生成周一开始的42个本地日期，并保留跨月日期', () => {
  const dates = visibleDates(at(17));
  assert.equal(dates.length, 42); assert.equal(dates[0].getDay(), 1);
  assert.equal(localDateKey(dates[0]), '2026-09-28');
  assert.equal(localDateKey(dates.at(-1)!), '2026-11-08');
  assert.equal(new Set(dates.map(localDateKey)).size, 42);
  assert.equal(visibleDates(at(17), 0)[0].getDay(), 0);
  assert.equal(visibleDates(at(17), 99)[0].getDay(), 1);
  assert.deepEqual(visibleDates(new Date(NaN)), []);
});

test('日历日期和跨日事件在夏令时跃迁后仍按本地午夜计算', () => {
  const previous = process.env.TZ;
  process.env.TZ = 'America/Los_Angeles';
  try {
    const spring = localDayRange(new Date(2026, 2, 8, 12));
    const autumn = localDayRange(new Date(2026, 10, 1, 12));
    assert.equal(+spring.end - +spring.start, 23 * 3600000);
    assert.equal(+autumn.end - +autumn.start, 25 * 3600000);
    const dates = visibleDates(new Date(2026, 2, 9, 12));
    assert.ok(dates.every(date => date.getHours() === 0));
    assert.equal(new Set(dates.map(localDateKey)).size, 42);
    const spanning = event('dst', new Date(2026, 2, 7, 23), new Date(2026, 2, 9));
    assert.equal(eventsForDay([spanning], new Date(2026, 2, 8, 12)).length, 1);
    assert.equal(eventsForDay([spanning], new Date(2026, 2, 9)).length, 0);
  } finally { if (previous === undefined) delete process.env.TZ; else process.env.TZ = previous; }
});

test('来源颜色由来源标识决定，不随其他日历的导入或顺序改变', () => {
  const work = calendarSourceColor('work-calendar');
  assert.match(work, /^#[0-9a-f]{6}$/);
  calendarSourceColor('another-calendar');
  assert.equal(calendarSourceColor('work-calendar'), work);
  assert.equal(calendarSourceColor(''), calendarSourceColor(''));
});

test('损坏的外部事件不进入日期列表', () => {
  const valid = event('valid', at(17), at(18));
  assert.deepEqual(eventsForDay([{ ...valid, start: 'broken' }, { ...valid, end: at(16).toISOString() }], at(17)), []);
  assert.deepEqual(eventsForDay([valid], new Date(NaN)), []);
});
