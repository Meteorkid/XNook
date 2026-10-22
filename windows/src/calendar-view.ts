import type { CalendarEvent } from './calendar';

export type EventStatus = 'future' | 'ongoing' | 'ended';

export function localDateKey(date: Date): string {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}

export function localDayRange(date: Date): { start: Date; end: Date } {
  const start = new Date(date); start.setHours(0, 0, 0, 0);
  const end = new Date(start); end.setDate(end.getDate() + 1);
  return { start, end };
}

/** 按本地日期推进，夏令时切换日不能用固定的 24 小时相加。 */
export function visibleDates(month: Date, weekStartsOn = 1): Date[] {
  if (!Number.isFinite(+month)) return [];
  const first = new Date(month.getFullYear(), month.getMonth(), 1);
  const weekday = Number.isInteger(weekStartsOn) && weekStartsOn >= 0 && weekStartsOn <= 6 ? weekStartsOn : 1;
  first.setDate(first.getDate() - (first.getDay() - weekday + 7) % 7);
  return Array.from({ length: 42 }, (_, index) => {
    const date = new Date(first); date.setDate(first.getDate() + index); return date;
  });
}

export function eventsForDay(events: readonly CalendarEvent[], selectedDate: Date): CalendarEvent[] {
  const { start, end } = localDayRange(selectedDate);
  if (!Number.isFinite(+start)) return [];
  return events.filter(event => {
    const eventStart = Date.parse(event.start), eventEnd = Date.parse(event.end);
    return Number.isFinite(eventStart) && Number.isFinite(eventEnd) && eventEnd >= eventStart
      && eventStart < +end && (eventEnd > +start || (eventStart === eventEnd && eventStart >= +start));
  }).sort((left, right) => Date.parse(left.start) - Date.parse(right.start)
    || Date.parse(left.end) - Date.parse(right.end) || left.title.localeCompare(right.title) || left.id.localeCompare(right.id));
}

export function eventStatus(event: CalendarEvent, now = new Date()): EventStatus {
  const start = Date.parse(event.start), end = Date.parse(event.end);
  if (!Number.isFinite(start) || !Number.isFinite(end) || end < start) return 'ended';
  if (start > +now || (start === end && start === +now)) return 'future';
  return end > +now ? 'ongoing' : 'ended';
}

export function overviewEvents(events: readonly CalendarEvent[], selectedDate: Date, now = new Date(), limit = 2): CalendarEvent[] {
  const dayEvents = eventsForDay(events, selectedDate);
  const remaining = localDateKey(selectedDate) === localDateKey(now)
    ? dayEvents.filter(event => eventStatus(event, now) !== 'ended') : dayEvents;
  return remaining.slice(0, Math.max(0, Math.min(2, Number.isFinite(limit) ? Math.floor(limit) : 2)));
}

const SOURCE_COLORS = ['#68a9ff', '#ba8cff', '#48cda9', '#edaa58', '#ef7c9f', '#65bfd7'] as const;
export function calendarSourceColor(sourceId: string): string {
  let hash = 2166136261;
  for (const character of sourceId) { hash ^= character.codePointAt(0)!; hash = Math.imul(hash, 16777619); }
  return SOURCE_COLORS[(hash >>> 0) % SOURCE_COLORS.length];
}
