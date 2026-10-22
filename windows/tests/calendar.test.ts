import { test } from 'node:test';
import assert from 'node:assert/strict';
import { expandCalendar, expandCalendars, validateCalendar } from '../src/calendar';
import type { CalendarSource } from '../src/domain';
const wrap = (events: string): string => `BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//XNook Test//EN\r\n${events}\r\nEND:VCALENDAR`;
const event = (properties: string): string => `BEGIN:VEVENT\r\n${properties}\r\nEND:VEVENT`;
const source = (content: string): CalendarSource => ({ id:'calendar', name:'calendar.ics', path:'C:\\calendar.ics', importedAt:'2026-10-17T00:00:00.000Z', content });
const expand = (content: string, from = '2026-10-01T00:00:00Z', to = '2026-11-01T00:00:00Z') => expandCalendar(source(content), new Date(from), new Date(to));
test('UTC 日程与中文折行、转义文本正确解析', () => {
  const result = expand(wrap(event('UID:1\r\nDTSTART:20261017T010000Z\r\nDTEND:20261017T020000Z\r\nSUMMARY:项目\r\n 会议\r\nDESCRIPTION:第一行\\n第二行\\,补充\r\nLOCATION:线上')));
  assert.equal(result.events.length, 1);
  assert.equal(result.events[0].start, '2026-10-17T01:00:00.000Z');
  assert.equal(result.events[0].title, '项目会议');
  assert.equal(result.events[0].description, '第一行\n第二行,补充');
});
test('全天多日使用本地日期，DTEND 排他且跨范围重叠保留', () => {
  const result = expand(wrap(event('UID:day\r\nDTSTART;VALUE=DATE:20261015\r\nDTEND;VALUE=DATE:20261018\r\nSUMMARY:多日活动')), '2026-10-17T00:00:00Z', '2026-10-19T00:00:00Z');
  assert.equal(result.events[0].allDay, true);
  assert.equal(new Date(result.events[0].start).getDate(), 15);
  assert.equal(new Date(result.events[0].end).getDate(), 18);
});
test('缺少 VTIMEZONE 时通过 Intl 正确处理上海时区', () => {
  const result = expand(wrap(event('UID:china\r\nDTSTART;TZID=Asia/Shanghai:20261017T090000\r\nDTEND;TZID=Asia/Shanghai:20261017T100000\r\nSUMMARY:上海时间')));
  assert.equal(result.events[0].start, '2026-10-17T01:00:00.000Z');
});
test('纽约重复日程跨夏令时仍保持当地上午9点', () => {
  const result = expand(wrap(event('UID:dst\r\nDTSTART;TZID=America/New_York:20261031T090000\r\nDTEND;TZID=America/New_York:20261031T100000\r\nRRULE:FREQ=DAILY;COUNT=3\r\nSUMMARY:早会')), '2026-10-30T00:00:00Z', '2026-11-04T00:00:00Z');
  assert.deepEqual(result.events.map(e => e.start), ['2026-10-31T13:00:00.000Z', '2026-11-01T14:00:00.000Z', '2026-11-02T14:00:00.000Z']);
});
const customZone = (offset: string): string => `BEGIN:VTIMEZONE\r\nTZID:Custom/Office\r\nBEGIN:STANDARD\r\nDTSTART:19700101T000000\r\nTZOFFSETFROM:${offset}\r\nTZOFFSETTO:${offset}\r\nEND:STANDARD\r\nEND:VTIMEZONE`;
test('文件内 VTIMEZONE 生效，两个日历同 TZID 的定义相互隔离', () => {
  const entry = event('UID:custom\r\nDTSTART;TZID=Custom/Office:20261017T090000\r\nDTEND;TZID=Custom/Office:20261017T100000\r\nSUMMARY:自定义时区');
  assert.equal(expand(wrap(customZone('+0900') + '\r\n' + entry)).events[0].start, '2026-10-17T00:00:00.000Z');
  assert.equal(expand(wrap(customZone('+0200') + '\r\n' + entry)).events[0].start, '2026-10-17T07:00:00.000Z');
  assert.equal(expand(wrap(customZone('+0900') + '\r\n' + entry)).events[0].start, '2026-10-17T00:00:00.000Z');
});
test('RRULE、EXDATE、RECURRENCE-ID 移动与取消共同生效', () => {
  const master = event('UID:series\r\nDTSTART:20261017T090000Z\r\nDTEND:20261017T100000Z\r\nRRULE:FREQ=DAILY;COUNT=5\r\nEXDATE:20261018T090000Z\r\nSUMMARY:原会议');
  const moved = event('UID:series\r\nRECURRENCE-ID:20261019T090000Z\r\nDTSTART:20261019T140000Z\r\nDTEND:20261019T150000Z\r\nSUMMARY:改期会议');
  const cancelled = event('UID:series\r\nRECURRENCE-ID:20261020T090000Z\r\nSTATUS:CANCELLED');
  const result = expand(wrap([master, moved, cancelled].join('\r\n')));
  assert.deepEqual(result.events.map(e => e.start), ['2026-10-17T09:00:00.000Z', '2026-10-19T14:00:00.000Z', '2026-10-21T09:00:00.000Z']);
  assert.equal(result.events[1].title, '改期会议');
});
test('原发生时间在范围外的例外移动到范围内时仍显示', () => {
  const master = event('UID:moved\r\nDTSTART:20261017T090000Z\r\nDTEND:20261017T100000Z\r\nRRULE:FREQ=DAILY;COUNT=5\r\nSUMMARY:会议');
  const moved = event('UID:moved\r\nRECURRENCE-ID:20261021T090000Z\r\nDTSTART:20261018T140000Z\r\nDTEND:20261018T150000Z\r\nSUMMARY:提前');
  const result = expand(wrap(master + '\r\n' + moved), '2026-10-18T12:00:00Z', '2026-10-19T00:00:00Z');
  assert.deepEqual(result.events.map(e => e.title), ['提前']);
});
test('UTC 取消标识与上海主事件对应同一实例，全天例外按日期取消', () => {
  const master = event('UID:timezone-cancel\r\nDTSTART;TZID=Asia/Shanghai:20261017T090000\r\nDTEND;TZID=Asia/Shanghai:20261017T100000\r\nRRULE:FREQ=DAILY;COUNT=3\r\nSUMMARY:上海会议');
  const cancelled = event('UID:timezone-cancel\r\nRECURRENCE-ID:20261018T010000Z\r\nSTATUS:CANCELLED');
  assert.deepEqual(expand(wrap(master + '\r\n' + cancelled)).events.map(e => e.start), ['2026-10-17T01:00:00.000Z', '2026-10-19T01:00:00.000Z']);
  const dayMaster = event('UID:day-cancel\r\nDTSTART;VALUE=DATE:20261017\r\nDTEND;VALUE=DATE:20261018\r\nRRULE:FREQ=DAILY;COUNT=3\r\nSUMMARY:全天');
  const dayCancelled = event('UID:day-cancel\r\nRECURRENCE-ID;VALUE=DATE:20261018\r\nSTATUS:CANCELLED');
  assert.deepEqual(expand(wrap(dayMaster + '\r\n' + dayCancelled)).events.map(e => new Date(e.start).getDate()), [17, 19]);
});
test('UTC 改期标识不会把同一上海重复实例插入两次', () => {
  const master = event('UID:timezone-move\r\nDTSTART;TZID=Asia/Shanghai:20261017T090000\r\nDTEND;TZID=Asia/Shanghai:20261017T100000\r\nRRULE:FREQ=DAILY;COUNT=3\r\nSUMMARY:上海会议');
  const moved = event('UID:timezone-move\r\nRECURRENCE-ID:20261018T010000Z\r\nDTSTART:20261018T050000Z\r\nDTEND:20261018T060000Z\r\nSUMMARY:改到下午');
  assert.deepEqual(expand(wrap(master + '\r\n' + moved)).events.map(e => e.start), ['2026-10-17T01:00:00.000Z', '2026-10-18T05:00:00.000Z', '2026-10-19T01:00:00.000Z']);
});
test('未知时区和缺少必需字段拒绝导入，取消整组不会显示', () => {
  assert.throws(() => validateCalendar(wrap(event('UID:bad\r\nDTSTART;TZID=Unknown/Zone:20261017T090000'))), /无法识别时区/);
  assert.throws(() => validateCalendar(wrap(event('DTSTART:20261017T090000Z'))), /UID/);
  assert.throws(() => validateCalendar('this is not a calendar'));
  assert.equal(expand(wrap(event('UID:cancelled\r\nSTATUS:CANCELLED'))).events.length, 0);
});
test('提醒和待办不被悄悄当成已支持', () => {
  const alarm = event('UID:alarm\r\nDTSTART:20261017T090000Z\r\nBEGIN:VALARM\r\nTRIGGER:-PT15M\r\nACTION:DISPLAY\r\nDESCRIPTION:提醒\r\nEND:VALARM');
  const result = expand(wrap(alarm + '\r\nBEGIN:VTODO\r\nUID:todo\r\nSUMMARY:任务\r\nEND:VTODO'));
  assert.equal(result.warnings.length, 2);
});
test('语法正确但时间倒置的日程和范围外例外都拒绝导入', () => {
  for (const properties of [
    'UID:bad\r\nDTSTART:20261017T090000Z\r\nDTEND:20261017T080000Z',
    'UID:bad\r\nRECURRENCE-ID:20300101T090000Z\r\nDTSTART:20300101T090000Z\r\nDTEND:20300101T080000Z',
  ]) assert.throws(() => validateCalendar(wrap(event(properties))), /时间范围/);
});
test('大量普通事件在解析前受到组件上限限制，重复主事件UID被拒绝', () => {
  const bulk = wrap(Array.from({ length: 16000 }, (_, i) => event(`UID:${i}\r\nDTSTART:20261017T090000Z`)).join('\r\n'));
  assert.throws(() => expand(bulk), /安全上限/);
  const master = event('UID:duplicate\r\nDTSTART:20261017T090000Z\r\nRRULE:FREQ=DAILY;COUNT=3');
  assert.throws(() => expand(wrap(master + '\r\n' + master)), /重复.*UID/);
});
test('多个系列共用输出预算，不能分别绕过安全上限', () => {
  const series = Array.from({ length: 3 }, (_, i) => event(`UID:series-${i}\r\nDTSTART:20260101T000000Z\r\nRRULE:FREQ=HOURLY;COUNT=5000`));
  assert.throws(() => expand(wrap(series.join('\r\n')), '2026-01-01T00:00:00Z', '2027-01-01T00:00:00Z'), /安全上限/);
});

test('整份日历的组件和重复迭代总量受限，不能按主事件重置预算', () => {
  const many = Array.from({ length: 10001 }, (_, i) => event(`UID:${i}\r\nDTSTART:20261017T090000Z`)).join('\r\n');
  assert.throws(() => expand(wrap(many)), /组件.*上限/);
  const series = ['a', 'b'].map(uid => event(`UID:${uid}\r\nDTSTART:20000101T090000Z\r\nRRULE:FREQ=DAILY;COUNT=14000`)).join('\r\n');
  assert.throws(() => expand(wrap(series), '2040-01-01T00:00:00Z', '2040-02-01T00:00:00Z'), /重复.*上限/);
});


test('多个来源共用组件、重复迭代与输出总预算', () => {
  const simple = (count: number) => wrap(Array.from({ length: count }, (_, i) => event(`UID:${i}\r\nDTSTART:20261017T090000Z`)).join('\r\n'));
  const batch = (content: string) => [source(content), { ...source(content), id: 'other' }];
  const range = [new Date('2026-10-01T00:00:00Z'), new Date('2026-11-01T00:00:00Z')] as const;
  assert.throws(() => expandCalendars(batch(simple(3000)), ...range), /输出总量.*上限/);
  assert.throws(() => expandCalendars(batch(wrap(event('UID:old\r\nDTSTART:20000101T090000Z\r\nRRULE:FREQ=DAILY;COUNT=14000'))), new Date('2040-01-01T00:00:00Z'), new Date('2040-02-01T00:00:00Z')), /重复.*上限/);
  const cancelled = wrap(Array.from({ length: 6000 }, (_, i) => event(`UID:${i}\r\nSTATUS:CANCELLED`)).join('\r\n'));
  assert.throws(() => expandCalendars(batch(cancelled), ...range), /组件.*上限/);
});

test('重复日程长描述受总输出大小限制，避免小输入放大内存', () => {
  const content = wrap(event(`UID:big\r\nDTSTART:20261001T090000Z\r\nRRULE:FREQ=DAILY;COUNT=10\r\nDESCRIPTION:${'x'.repeat(1024 * 1024)}`));
  assert.throws(() => expand(content), /输出内容.*上限/);
});

test('重复例外拒绝歧义，孤立例外和合法月度年度规则保持可用', () => {
  const exception = event('UID:orphan\r\nRECURRENCE-ID:20261017T090000Z\r\nDTSTART:20261018T090000Z');
  assert.equal(expand(wrap(exception)).events[0].start, '2026-10-18T09:00:00.000Z');
  assert.throws(() => validateCalendar(wrap(exception + '\r\n' + exception)), /重复.*RECURRENCE-ID/);
  const monthly = event('UID:monthly\r\nDTSTART:20261005T090000Z\r\nRRULE:FREQ=MONTHLY;BYDAY=1MO;COUNT=3');
  assert.deepEqual(expand(wrap(monthly), '2026-10-01T00:00:00Z', '2027-01-01T00:00:00Z').events.map(item => item.start),
    ['2026-10-05T09:00:00.000Z', '2026-11-02T09:00:00.000Z', '2026-12-07T09:00:00.000Z']);
  const leap = event('UID:leap\r\nDTSTART:20240229T090000Z\r\nRRULE:FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=29;COUNT=2');
  assert.deepEqual(expand(wrap(leap), '2024-01-01T00:00:00Z', '2029-01-01T00:00:00Z').events.map(item => item.start),
    ['2024-02-29T09:00:00.000Z', '2028-02-29T09:00:00.000Z']);
});

test('共同验证器限制属性、例外日期和嵌套深度，保留5MiB文件边界', () => {
  assert.throws(() => validateCalendar(wrap(event('UID:props\r\nDTSTART:20261017T090000Z\r\n' + 'X-EXTRA:1\r\n'.repeat(40001)))), /属性.*上限/);
  assert.throws(() => validateCalendar(wrap(event('UID:dates\r\nDTSTART:20261017T090000Z\r\nEXDATE:' + Array(4001).fill('20261017T090000Z').join(',')))), /例外日期.*上限/);
  assert.throws(() => validateCalendar('BEGIN:VCALENDAR\r\n'.repeat(9) + 'END:VCALENDAR\r\n'.repeat(9)), /嵌套.*上限/);
  assert.throws(() => validateCalendar('x'.repeat(5 * 1024 * 1024 + 1)), /5 MiB/);
});

test('所有事件UID均限制1024字符，避免提醒键超过持久化边界', () => {
  const valid = `UID:${'u'.repeat(1024)}\r\nDTSTART:20261017T090000Z`;
  assert.equal(expand(wrap(event(valid))).events.length, 1);
  for (const rest of ['DTSTART:20261017T090000Z', 'STATUS:CANCELLED',
    'RECURRENCE-ID:20261017T090000Z\r\nDTSTART:20261018T090000Z', 'RECURRENCE-ID:20261017T090000Z\r\nSTATUS:CANCELLED']) {
    assert.throws(() => validateCalendar(wrap(event(`UID:${'u'.repeat(1025)}\r\n${rest}`))), /UID.*1024/);
  }
});
