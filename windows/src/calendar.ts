import ICAL from 'ical.js';
import type { CalendarSource } from './domain';

export interface CalendarEvent { id: string; sourceId: string; title: string; start: string; end: string; allDay: boolean; location: string; description: string }
export interface CalendarResult { events: CalendarEvent[]; warnings: string[] }
export interface CalendarBatchResult extends CalendarResult { errors: string[] }
export const calendarLimits = { sources: 100, fileBytes: 5 * 1024 * 1024, inputBytes: 10 * 1024 * 1024,
  components: 10000, properties: 40000, dateValues: 4000, iterations: 25000, events: 5000,
  outputBytes: 8 * 1024 * 1024, processingMs: 500 } as const;
export interface CalendarBudget { inputBytes: number; components: number; properties: number; dateValues: number;
  iterations: number; events: number; outputBytes: number; deadline: number }
export const createCalendarBudget = (): CalendarBudget => ({ inputBytes: 0, components: 0, properties: 0, dateValues: 0,
  iterations: 0, events: 0, outputBytes: 0, deadline: performance.now() + calendarLimits.processingMs });
class CalendarLimitError extends Error {}
const checkBudget = (budget: CalendarBudget): void => {
  if (performance.now() > budget.deadline) throw new CalendarLimitError('日历处理时间超过安全上限，请导出较短日期范围');
};
const recurrenceKey = (time: ICAL.Time): string => time.isDate ? `date:${time.toString()}` : `instant:${time.toUnixTime()}`;

/** 先限制树深度与属性数量，避免第三方解析器在构建组件树时耗尽资源。 */
function inspectStructure(content: string, budget: CalendarBudget): void {
  let depth = 0, components = 0, logical = '';
  const inspect = (): void => {
    const colon = logical.indexOf(':'), name = logical.slice(0, colon).split(';', 1)[0].toUpperCase();
    if (name === 'BEGIN') {
      if (++depth > 8 || ++components + budget.components > calendarLimits.components) throw new CalendarLimitError('日历组件总量或嵌套层级超过安全上限');
    } else if (name === 'END') depth--;
    else if (logical && ++budget.properties > calendarLimits.properties) throw new CalendarLimitError('日历属性总量超过安全上限');
    if (name === 'RDATE' || name === 'EXDATE') {
      budget.dateValues += logical.slice(colon + 1).split(',').length;
      if (budget.dateValues > calendarLimits.dateValues) throw new CalendarLimitError('日历例外日期总量超过安全上限');
    }
    checkBudget(budget);
  };
  for (const line of content.split(/\r\n|\n|\r/)) {
    if (/^[ \t]/.test(line)) logical += line.slice(1);
    else { if (logical) inspect(); logical = line; }
  }
  if (logical) inspect();
}

function validateTimeRange(item: ICAL.Event): void {
  const start = item.startDate?.toJSDate(), end = item.endDate?.toJSDate();
  if (!start || !end || !Number.isFinite(+start) || !Number.isFinite(+end) || end < start) throw new Error('日程时间范围无效');
}

/** 缺少 VTIMEZONE 的 IANA 标识使用操作系统时区数据，不能降级为本地时间。 */
function registerIanaZone(tzid: string): void {
  const formatter = new Intl.DateTimeFormat('en-US', { timeZone: tzid, year: 'numeric', month: '2-digit',
    day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' });
  const offsetAt = (stamp: number): number => {
    const parts = Object.fromEntries(formatter.formatToParts(new Date(stamp)).map(p => [p.type, p.value]));
    return (Date.UTC(+parts.year, +parts.month - 1, +parts.day, +parts.hour, +parts.minute, +parts.second) - stamp) / 1000;
  };
  const zone = new ICAL.Timezone({ tzid });
  zone.utcOffset = (time: ICAL.Time): number => {
    const wall = Date.UTC(time.year, time.month - 1, time.day, time.hour, time.minute, time.second);
    // 转换前后两个偏移覆盖 DST 重叠；取第一次出现。不存在的本地时间使用跃迁前偏移。
    const offsets = [...new Set([offsetAt(wall - 86400000), offsetAt(wall), offsetAt(wall + 86400000)])];
    const matches = offsets.filter(offset => offsetAt(wall - offset * 1000) === offset);
    return matches.length ? Math.max(...matches) : offsetAt(wall - 86400000);
  };
  ICAL.TimezoneService.register(zone, tzid);
}
function prepareCalendar(content: string, budget: CalendarBudget): ICAL.Component {
  checkBudget(budget);
  const size = new TextEncoder().encode(content).length;
  budget.inputBytes += size;
  if (budget.inputBytes > calendarLimits.inputBytes) throw new CalendarLimitError('日历来源总大小超过 10 MiB 上限');
  if (size > calendarLimits.fileBytes) throw new Error('日历文件超过 5 MiB');
  inspectStructure(content, budget);
  const root = new ICAL.Component(ICAL.parse(content));
  checkBudget(budget);
  if (root.name !== 'vcalendar') throw new Error('文件不是有效的 iCalendar 日历');
  const pending = [root];
  while (pending.length) {
    const component = pending.pop()!;
    if (++budget.components > calendarLimits.components) throw new CalendarLimitError('日历组件总量超过安全上限，请减少导入的日程');
    pending.push(...component.getAllSubcomponents());
  }
  const known = new Set(root.getAllSubcomponents('vtimezone').map(c => String(c.getFirstPropertyValue('tzid'))));
  const masterIds = new Set<string>(), exceptionIds = new Set<string>();
  for (const event of root.getAllSubcomponents('vevent')) {
    checkBudget(budget);
    for (const property of event.getAllProperties()) {
      const tzid = property.getParameter('tzid');
      if (typeof tzid === 'string' && !known.has(tzid)) {
        try { registerIanaZone(tzid); known.add(tzid); }
        catch { throw new Error(`无法识别时区「${tzid}」。请导出包含 VTIMEZONE 的 .ics 文件`); }
      }
    }
    if (!event.hasProperty('uid')) throw new Error('日程缺少 UID，无法可靠处理重复事件');
    if (!event.hasProperty('dtstart') && event.getFirstPropertyValue('status') !== 'CANCELLED') throw new Error('日程缺少 DTSTART');
    for (const name of ['uid', 'dtstart', 'dtend', 'duration', 'recurrence-id']) {
      if (event.getAllProperties(name).length > 1) throw new Error(`日程包含重复的 ${name.toUpperCase()} 属性`);
    }
    if (event.hasProperty('dtend') && event.hasProperty('duration')) throw new Error('日程不能同时指定 DTEND 和 DURATION');
    const uid = String(event.getFirstPropertyValue('uid'));
    if (!uid.trim()) throw new Error('日程缺少 UID，无法可靠处理重复事件');
    if (uid.length > 1024) throw new Error('日程 UID 超过 1024 字符上限');
    if (event.hasProperty('recurrence-id')) {
      const recurrence = event.getFirstPropertyValue('recurrence-id') as ICAL.Time;
      if (!Number.isFinite(+recurrence.toJSDate())) throw new Error('日程例外时间范围无效');
      const key = JSON.stringify([uid, recurrenceKey(recurrence)]);
      if (exceptionIds.has(key)) throw new Error('日程包含重复的 UID 与 RECURRENCE-ID');
      exceptionIds.add(key);
    } else {
      if (masterIds.has(uid)) throw new Error('日程包含重复的主事件 UID');
      masterIds.add(uid);
    }
    // 包括查询窗口之外和已取消但仍含时间的事件，避免刷新覆盖可用的旧文件。
    if (event.hasProperty('dtstart')) validateTimeRange(new ICAL.Event(event, { exceptions: [] }));
  }
  checkBudget(budget);
  return root;
}
export function validateCalendar(content: string): void { prepareCalendar(content, createCalendarBudget()); }

export function expandCalendar(source: CalendarSource, rangeStart: Date, rangeEnd: Date, budget = createCalendarBudget()): CalendarResult {
  if (!Number.isFinite(+rangeStart) || !Number.isFinite(+rangeEnd) || rangeEnd <= rangeStart) throw new Error('日历查询时间范围无效');
  const root = prepareCalendar(source.content, budget);
  const components = root.getAllSubcomponents('vevent');
  const masters: ICAL.Component[] = [], exceptionsByUid = new Map<string, ICAL.Component[]>();
  for (const component of components) {
    if (!component.hasProperty('recurrence-id')) { masters.push(component); continue; }
    const uid = String(component.getFirstPropertyValue('uid'));
    const exceptions = exceptionsByUid.get(uid) ?? [];
    exceptions.push(component); exceptionsByUid.set(uid, exceptions);
  }
  const warnings: string[] = [];
  if (root.getAllSubcomponents('vtodo').length) warnings.push('此文件中的 VTODO 待办暂不导入。');
  if (components.some(c => c.getAllSubcomponents('valarm').length)) warnings.push('ICS 提醒已保留在原始文件中；首版不触发系统通知。');
  const events: CalendarEvent[] = [];
  const seen = new Set<string>();
  const push = (item: ICAL.Event, start: ICAL.Time, end: ICAL.Time, recurrence: string): void => {
    checkBudget(budget);
    if (item.component.getFirstPropertyValue('status') === 'CANCELLED') return;
    const startDate = start.toJSDate(), endDate = end.toJSDate();
    if (!Number.isFinite(+startDate) || !Number.isFinite(+endDate) || endDate < startDate) throw new Error('日程时间范围无效');
    if (startDate >= rangeEnd || (endDate <= rangeStart && startDate < rangeStart)) return;
    const id = `${source.id}:${item.uid}:${recurrence}`;
    if (seen.has(id)) return;
    if (++budget.events > calendarLimits.events) throw new CalendarLimitError('日程输出总量超过安全上限，请导出较短日期范围');
    budget.outputBytes += 2 * (id.length + source.id.length + (item.summary || '').length + (item.location || '').length + (item.description || '').length) + 128;
    if (budget.outputBytes > calendarLimits.outputBytes) throw new CalendarLimitError('日程输出内容超过安全上限，请缩短日程描述');
    seen.add(id);
    events.push({ id, sourceId: source.id, title: item.summary || '未命名日程', start: startDate.toISOString(),
      end: endDate.toISOString(), allDay: start.isDate, location: item.location || '', description: item.description || '' });
  };
  for (const component of masters) {
    checkBudget(budget);
    if (component.getFirstPropertyValue('status') === 'CANCELLED') continue;
    const event = new ICAL.Event(component, { exceptions: [] });
    const exceptions = exceptionsByUid.get(event.uid) ?? [];
    const cancelled = new Set(exceptions.filter(c => c.getFirstPropertyValue('status') === 'CANCELLED')
      .map(c => recurrenceKey(c.getFirstPropertyValue('recurrence-id') as ICAL.Time)));
    for (const exception of exceptions) {
      if (exception.getFirstPropertyValue('status') !== 'CANCELLED') event.relateException(new ICAL.Event(exception));
    }
    if (!event.isRecurring()) { push(event, event.startDate, event.endDate, recurrenceKey(event.startDate)); continue; }
    const iterator = event.iterator();
    let occurrence: ICAL.Time | null;
    while ((occurrence = iterator.next())) {
      checkBudget(budget);
      if (++budget.iterations > calendarLimits.iterations) throw new CalendarLimitError('重复日程展开总量超过安全上限，请导出较短日期范围');
      if (occurrence.toJSDate() >= rangeEnd) break;
      if (cancelled.has(recurrenceKey(occurrence))) continue;
      const detail = event.getOccurrenceDetails(occurrence);
      push(detail.item, detail.startDate, detail.endDate, recurrenceKey(occurrence));
    }
    // 被改到查询区间内的例外，原发生时间可能位于查询区间之后。
    for (const exception of exceptions) {
      if (exception.getFirstPropertyValue('status') === 'CANCELLED') continue;
      const item = new ICAL.Event(exception);
      push(item, item.startDate, item.endDate, recurrenceKey(item.recurrenceId));
    }
  }
  const masterIds = new Set(masters.map(c => String(c.getFirstPropertyValue('uid'))));
  for (const [uid, exceptions] of exceptionsByUid) {
    if (masterIds.has(uid)) continue;
    for (const component of exceptions) {
    if (component.getFirstPropertyValue('status') !== 'CANCELLED') {
      const item = new ICAL.Event(component);
      push(item, item.startDate, item.endDate, recurrenceKey(item.recurrenceId));
    }
  }
  }
  return { events: events.sort((a, b) => a.start.localeCompare(b.start)), warnings };
}

/** 一次显示/导入/刷新共用预算；生产调用必须位于可终止的 Worker 内。 */
export function expandCalendars(sources: readonly CalendarSource[], rangeStart: Date, rangeEnd: Date): CalendarBatchResult {
  if (sources.length > calendarLimits.sources) throw new CalendarLimitError('日历来源数量超过安全上限');
  const budget = createCalendarBudget(), events: CalendarEvent[] = [], warnings: string[] = [], errors: string[] = [];
  for (const source of sources) {
    try {
      const result = expandCalendar(source, rangeStart, rangeEnd, budget);
      events.push(...result.events); warnings.push(...result.warnings);
    } catch (error) {
      if (error instanceof CalendarLimitError) throw error;
      errors.push(`${source.name}：${error instanceof Error ? error.message : String(error)}`);
    }
  }
  return { events: events.sort((a, b) => a.start.localeCompare(b.start)), warnings: [...new Set(warnings)], errors };
}
