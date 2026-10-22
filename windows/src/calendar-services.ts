import type { CalendarEvent } from './calendar';
import type { CalendarSource } from './domain';

export interface ReminderSettings {
  reminderEnabled: boolean; reminderLeadMinutes: number;
  quietHoursEnabled: boolean; quietHoursStart: string; quietHoursEnd: string;
}
export interface ReminderPlan { due: CalendarEvent[]; newKeys: string[]; remindedEvents: string[] }
const minuteOfDay = (value: string): number | null => /^([01]\d|2[0-3]):[0-5]\d$/.test(value)
  ? Number(value.slice(0, 2)) * 60 + Number(value.slice(3)) : null;
export function isQuietHours(settings: Pick<ReminderSettings, 'quietHoursEnabled' | 'quietHoursStart' | 'quietHoursEnd'>, now = new Date()): boolean {
  if (!settings.quietHoursEnabled) return false;
  const start = minuteOfDay(settings.quietHoursStart), end = minuteOfDay(settings.quietHoursEnd);
  if (start === null || end === null) return false;
  const minute = now.getHours() * 60 + now.getMinutes();
  return start <= end ? minute >= start && minute < end : minute >= start || minute < end;
}
export const reminderKey = (event: Pick<CalendarEvent, 'id' | 'start'>): string => `${event.id}@${Date.parse(event.start)}`;

/** 返回本轮全部到期事项；调用方播放成功后才保存 newKeys，勿扰不消费标记。 */
export function planReminders(events: readonly CalendarEvent[], settings: ReminderSettings, remindedEvents: readonly string[], now = new Date()): ReminderPlan {
  const stamp = now.getTime();
  const previous = [...new Set(remindedEvents)].filter(key => {
    const time = Number(key.slice(key.lastIndexOf('@') + 1));
    return key.includes('@') && Number.isFinite(time) && time >= stamp - 3600000;
  }).slice(-5000);
  if (!Number.isFinite(stamp) || !settings.reminderEnabled || isQuietHours(settings, now)
    || !Number.isInteger(settings.reminderLeadMinutes) || settings.reminderLeadMinutes < 0 || settings.reminderLeadMinutes > 1440) return { due: [], newKeys: [], remindedEvents: previous };
  const lead = settings.reminderLeadMinutes * 60000;
  const previousKeys = new Set(previous), plannedKeys = new Set<string>();
  const due = events.filter(event => {
    const start = Date.parse(event.start);
    // 30 秒轮询允许额外一轮延迟，同时发生的事件必须在同一轮全部返回。
    const inWindow = lead === 0 ? start > stamp - 60000 && start <= stamp : start >= stamp && start <= stamp + lead;
    const key = reminderKey(event);
    if (event.allDay || !Number.isFinite(start) || !inWindow || previousKeys.has(key) || plannedKeys.has(key)) return false;
    plannedKeys.add(key); return true;
  }).sort((left, right) => Date.parse(left.start) - Date.parse(right.start) || left.id.localeCompare(right.id));
  const newKeys = due.map(reminderKey);
  return { due, newKeys, remindedEvents: [...previous, ...newKeys].slice(-5000) };
}

export interface CalendarUpdate { id: string; path: string; name: string; content: string; previousContent: string }
export interface RefreshResult { updates: CalendarUpdate[]; errors: { id: string; path: string; message: string }[] }
export class RefreshScheduler {
  private generation = 0;
  private running: number | null = null;
  private controller: AbortController | null = null;
  private nextAt = new Map<string, number>();
  constructor(private io: {
    read(path: string): Promise<{ path: string; name: string; content: string }>;
    validate(sources: readonly CalendarSource[], signal: AbortSignal): void | Promise<void>;
  }, private intervalMs = 60000, private retryMs = 30000) {
    if (!Number.isFinite(intervalMs) || intervalMs < 1000 || !Number.isFinite(retryMs) || retryMs < 1000) throw new Error('日历刷新间隔无效');
  }
  cancel(): void { this.generation++; this.running = null; this.controller?.abort(); this.controller = null; }
  async refresh(sources: readonly CalendarSource[], enabled: boolean, now = Date.now(), force = false): Promise<RefreshResult> {
    const empty = (): RefreshResult => ({ updates: [], errors: [] });
    if (!enabled) { this.cancel(); return empty(); }
    const generation = this.generation;
    if (this.running === generation) return empty();
    this.running = generation;
    const controller = new AbortController(); this.controller = controller;
    const result = empty();
    const inputs = sources.map(source => ({ ...source }));
    const present = new Set(inputs.map(source => `${source.id}\0${source.path}`));
    for (const key of this.nextAt.keys()) if (!present.has(key)) this.nextAt.delete(key);
    try {
      for (const source of inputs) {
        const key = `${source.id}\0${source.path}`;
        if (!force && (this.nextAt.get(key) ?? 0) > now) continue;
        try {
          const latest = await this.io.read(source.path);
          if (generation !== this.generation) return empty();
          if (latest.path !== source.path) throw new Error('日历读取返回了不同来源，已保留原数据');
          this.nextAt.set(key, now + this.intervalMs);
          if (latest.content !== source.content || latest.name !== source.name) result.updates.push({ id: source.id, ...latest, previousContent: source.content });
        } catch (error) {
          if (generation !== this.generation) return empty();
          this.nextAt.set(key, now + this.retryMs);
          result.errors.push({ id: source.id, path: source.path, message: error instanceof Error ? error.message : String(error) });
        }
      }
      if (result.updates.length) {
        const candidates = inputs.map(source => {
          const update = result.updates.find(item => item.id === source.id);
          return update ? { ...source, content: update.content, name: update.name } : source;
        });
        try {
          await this.io.validate(candidates, controller.signal);
          if (generation !== this.generation) return empty();
        } catch (error) {
          if (generation !== this.generation) return empty();
          for (const update of result.updates) {
            this.nextAt.set(`${update.id}\0${update.path}`, now + this.retryMs);
            result.errors.push({ id: update.id, path: update.path, message: error instanceof Error ? error.message : String(error) });
          }
          result.updates = [];
        }
      }
      return generation === this.generation ? result : empty();
    } finally { if (this.running === generation) { this.running = null; this.controller = null; } }
  }
}
