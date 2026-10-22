export const widgetIds = ['media', 'calendar', 'notes', 'files'] as const;
export type WidgetId = typeof widgetIds[number];
export interface Preferences {
  appearance: 'dark' | 'light' | 'system'; language: 'auto' | 'zh' | 'en';
  panelWidth: number; panelHeight: number; islandWidth: number; islandHeight: number; lyricsIslandWidth: number; lyricsIslandHeight: number;
  enabledWidgets: WidgetId[]; showHistory: boolean; historyLimit: number;
  hoverExpand: boolean; scrollExpand: boolean; hoverExitDelayMs: number; idleCollapseMs: number;
  reduceMotion: boolean; jellyIntensity: 'off' | 'low' | 'medium' | 'high'; magnetic: boolean; hideCursor: boolean;
  showTicker: boolean; tickerSpeed: number; selectedGifId: string | null;
  reminderEnabled: boolean; reminderLeadMinutes: number; reminderSound: 'default' | 'asterisk' | 'exclamation';
  quietHoursEnabled: boolean; quietHoursStart: string; quietHoursEnd: string; autoRefreshCalendars: boolean;
  autoCheckUpdates: boolean; launchAtLogin: boolean; visibleOnAllDesktops: boolean;
}
export const defaultPreferences: Preferences = {
  appearance: 'dark', language: 'auto', panelWidth: 620, panelHeight: 590, islandWidth: 300, islandHeight: 52,
  lyricsIslandWidth: 360, lyricsIslandHeight: 72, enabledWidgets: [...widgetIds], showHistory: true, historyLimit: 3,
  hoverExpand: false, scrollExpand: true, hoverExitDelayMs: 200, idleCollapseMs: 1000,
  reduceMotion: false, jellyIntensity: 'medium', magnetic: true, hideCursor: false, showTicker: true, tickerSpeed: 25, selectedGifId: null,
  reminderEnabled: false, reminderLeadMinutes: 5, reminderSound: 'default', quietHoursEnabled: false, quietHoursStart: '22:00', quietHoursEnd: '07:00',
  autoRefreshCalendars: true, autoCheckUpdates: true, launchAtLogin: false, visibleOnAllDesktops: false,
};
const ranges: Partial<Record<keyof Preferences, [number, number, boolean?]>> = {
  panelWidth: [160, 1200], panelHeight: [160, 1000], islandWidth: [40, 600], islandHeight: [8, 120],
  lyricsIslandWidth: [60, 800], lyricsIslandHeight: [10, 160], historyLimit: [1, 20, true],
  hoverExitDelayMs: [0, 10000, true], idleCollapseMs: [0, 600000, true], tickerSpeed: [1, 200], reminderLeadMinutes: [0, 1440, true],
};
const enums: Partial<Record<keyof Preferences, string[]>> = { appearance: ['dark', 'light', 'system'], language: ['auto', 'zh', 'en'],
  jellyIntensity: ['off', 'low', 'medium', 'high'], reminderSound: ['default', 'asterisk', 'exclamation'] };
export function parsePreferences(source: Record<string, unknown>): Preferences {
  const result = structuredClone(defaultPreferences);
  for (const key of Object.keys(defaultPreferences) as (keyof Preferences)[]) {
    if (source[key] === undefined) continue;
    const value = source[key], range = ranges[key], options = enums[key];
    let valid = true;
    if (range) valid = typeof value === 'number' && Number.isFinite(value) && value >= range[0] && value <= range[1] && (!range[2] || Number.isInteger(value));
    else if (options) valid = typeof value === 'string' && options.includes(value);
    else if (key === 'enabledWidgets') valid = Array.isArray(value) && value.every(item => widgetIds.includes(item as WidgetId)) && new Set(value).size === value.length;
    else if (key === 'selectedGifId') valid = value === null || typeof value === 'string' && !!value.trim() && !value.includes('\0') && value.length <= 4096;
    else if (key === 'quietHoursStart' || key === 'quietHoursEnd') valid = typeof value === 'string' && /^(?:[01]\d|2[0-3]):[0-5]\d$/.test(value);
    else valid = typeof value === 'boolean';
    if (!valid) throw new Error(`设置 ${key} 无效，已阻止覆盖原件`);
    (result as unknown as Record<string, unknown>)[key] = structuredClone(value);
  }
  return result;
}
export function windowSize(settings: Preferences, expanded: boolean, ticker: boolean): { width: number; height: number } {
  return expanded ? { width: settings.panelWidth, height: settings.panelHeight }
    : ticker ? { width: settings.lyricsIslandWidth, height: settings.lyricsIslandHeight }
      : { width: settings.islandWidth, height: settings.islandHeight };
}
export function resolvedAppearance(mode: Preferences['appearance'], systemDark: boolean): 'dark' | 'light' {
  return mode === 'system' ? systemDark ? 'dark' : 'light' : mode;
}
/** 向内形变，不借用原生窗口外的绘制空间；强度仍有独立幅度。 */
export function jellyScale(intensity: Preferences['jellyIntensity']): number {
  return { off: 1, low: .985, medium: .96, high: .93 }[intensity];
}
export function magneticOffset(pointerFromCenter: number, frameWidth: number, islandWidth: number): number {
  if (![pointerFromCenter, frameWidth, islandWidth].every(Number.isFinite)) return 0;
  const available = Math.max(0, Math.min(6, (frameWidth - islandWidth) / 2));
  return Math.max(-available, Math.min(available, pointerFromCenter * .035));
}
export interface InteractionState { editing: boolean; composing: boolean; selection: boolean; menu: boolean; dragging: boolean; fileDrop: boolean }
export const protectsPanel = (state: InteractionState): boolean => Object.values(state).some(Boolean);
export class CollapsePolicy {
  private outsideSince: number | null = null;
  update(now: number, inside: boolean, expanded: boolean, protectedInteraction: boolean, delay: number): boolean {
    if (!expanded || inside || protectedInteraction || delay === 0) { this.outsideSince = null; return false; }
    if (this.outsideSince === null) this.outsideSince = now;
    return now - this.outsideSince >= delay;
  }
  reset(): void { this.outsideSince = null; }
}
