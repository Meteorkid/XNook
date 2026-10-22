import { emptyStore, validMediaSourceId, type Store } from './domain';
import { parsePreferences } from './preferences';

const record = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);
const text = (v: unknown): v is string => typeof v === 'string';
const id = (v: unknown): boolean => text(v) && !!v.trim();
const date = (v: unknown): boolean => text(v) && /^\d{4}-\d{2}-\d{2}T/.test(v) && Number.isFinite(Date.parse(v));
const nullableDate = (v: unknown): boolean => v === null || date(v);
const bounded = (v: unknown, max: number): v is unknown[] => Array.isArray(v) && v.length <= max;
const file = (v: unknown): boolean => record(v) && id(v.id) && text(v.path) && !!v.path.trim() && text(v.name) && typeof v.isDirectory === 'boolean' && date(v.addedAt);
const note = (v: unknown): boolean => record(v) && id(v.id) && text(v.title) && text(v.content) && date(v.createdAt) && date(v.updatedAt);
const linkedNote = (v: unknown): boolean => v === null || (record(v) && id(v.id) && text(v.title) && text(v.content));
const uniqueIds = (items: unknown[]): boolean => new Set(items.map(item => (item as { id: string }).id)).size === items.length;
const session = (v: unknown, ended: boolean): boolean => record(v) && id(v.id) && text(v.title) && date(v.startedAt)
  && (ended ? date(v.endedAt) : v.endedAt === null) && nullableDate(v.scheduledEndAt)
  && (v.eventId === null || id(v.eventId)) && linkedNote(v.linkedNote) && bounded(v.linkedFiles, 10000) && v.linkedFiles.every(file) && uniqueIds(v.linkedFiles);
const STORE_LIMIT_BYTES = 16 * 1024 * 1024;
const byteLength = (content: string): number => new TextEncoder().encode(content).length;
export function parseStore(content: string | null): Store { return parseStoreContent(content); }
function parseStoreContent(content: string | null, allowOversize = false): Store {
  if (content === null) return emptyStore();
  if (!allowOversize && byteLength(content) > STORE_LIMIT_BYTES) throw new Error('数据文件超过 16 MiB，已阻止覆盖；请删除不再需要的任务历史或缩减笔记后重试');
  let v: unknown;
  try { v = JSON.parse(content); } catch { throw new Error('数据文件不是有效的 JSON，已阻止覆盖原件'); }
  if (!record(v) || v.version !== 1 || !bounded(v.notes, 10000) || !v.notes.every(note)
    || !bounded(v.files, 10000) || !v.files.every(file) || !bounded(v.history, 10000) || !v.history.every(s => session(s, true))
    || !(v.activeSession === null || session(v.activeSession, false)) || !bounded(v.calendars, 100)
    || !v.calendars.every(c => record(c) && id(c.id) && text(c.path) && text(c.name) && text(c.content) && date(c.importedAt))
    || !record(v.settings) || !['followPointer', 'hideInFullscreen', 'lyricsEnabled'].every(k => typeof (v.settings as Record<string, unknown>)[k] === 'boolean')) {
    throw new Error('数据格式不兼容或已损坏，已阻止覆盖原件');
  }
  for (const list of [v.notes, v.files, v.history, v.calendars]) {
    const ids = list.map(item => (item as { id: string }).id);
    if (new Set(ids).size !== ids.length) throw new Error('数据包含重复标识，已阻止覆盖原件');
  }
  const preferred = (v.settings as Record<string, unknown>).preferredMediaSourceId;
  if (preferred !== undefined && preferred !== null && !validMediaSourceId(preferred)) throw new Error('播放器选择设置已损坏，已阻止覆盖原件');
  (v.settings as Record<string, unknown>).preferredMediaSourceId = preferred ?? null;
  v.settings = { ...(v.settings as Record<string, unknown>), ...parsePreferences(v.settings as Record<string, unknown>) };
  if (v.remindedEvents === undefined) v.remindedEvents = [];
  if (!bounded(v.remindedEvents, 5000) || !v.remindedEvents.every(item => text(item) && !!item && item.length <= 8192)) throw new Error('提醒记录已损坏，已阻止覆盖原件');
  return v as unknown as Store;
}
export type SaveState = { kind: 'saved' | 'saving' | 'error' | 'blocked'; message: string };
type SaveBatch = { snapshot: string; revision: number; promise: Promise<void>; resolve(): void; reject(error: unknown): void };

/** 写入严格串行，只保留在途与最新待写快照；失败后保留内存草稿。 */
export class StoreController {
  store: Store = emptyStore();
  blocked = false;
  state: SaveState = { kind: 'saved', message: '已保存到本机' };
  private inFlight: Promise<void> | null = null;
  private pending: SaveBatch | null = null;
  private revision = 0;
  constructor(private io: { read(): Promise<string | null>; write(content: string): Promise<void> },
    private onState: (state: SaveState) => void = () => {}) {}
  async load(): Promise<void> {
    try { this.store = parseStore(await this.io.read()); this.blocked = false; this.setState('saved', '已保存到本机'); }
    catch (error) { this.blocked = true; this.setState('blocked', String(error)); }
  }
  private setState(kind: SaveState['kind'], message: string): void { this.state = { kind, message }; this.onState(this.state); }
  /** 离散操作先验证完整候选；编辑器草稿仍可在保存失败后保留。 */
  mutate<T>(change: (candidate: Store) => T, allowReduction = false): T {
    if (this.blocked) throw new Error('存储已锁定，请先恢复数据文件并重新打开应用');
    const candidate = structuredClone(this.store), result = change(candidate);
    const snapshot = JSON.stringify(candidate), size = byteLength(snapshot);
    // 已超限草稿允许分步清理；只能减少数据，结构检查仍然执行。
    const reducing = allowReduction && size < byteLength(JSON.stringify(this.store));
    parseStoreContent(snapshot, reducing);
    this.store = candidate;
    return result;
  }
  save(): Promise<void> {
    if (this.blocked) return Promise.reject(new Error('存储已锁定，请先恢复数据文件并重新打开应用'));
    const revision = ++this.revision;
    const snapshot = JSON.stringify(this.store);
    try { parseStore(snapshot); }
    catch (error) {
      this.setState('error', `保存失败，草稿仍保留：${String(error)}`);
      return Promise.reject(error);
    }
    this.setState('saving', '正在保存…');
    if (this.pending) {
      this.pending.snapshot = snapshot; this.pending.revision = revision;
      return this.pending.promise;
    }
    let resolve!: () => void, reject!: (error: unknown) => void;
    const promise = new Promise<void>((accept, decline) => { resolve = accept; reject = decline; });
    this.pending = { snapshot, revision, promise, resolve, reject };
    this.writeNext();
    return promise;
  }
  private writeNext(): void {
    if (this.inFlight || !this.pending) return;
    const batch = this.pending; this.pending = null;
    this.inFlight = Promise.resolve().then(() => this.io.write(batch.snapshot)).then(() => {
      if (batch.revision === this.revision) this.setState('saved', '已保存到本机');
      batch.resolve();
    }, error => {
      if (batch.revision === this.revision) this.setState('error', `保存失败，草稿仍保留：${String(error)}`);
      batch.reject(error);
    }).finally(() => { this.inFlight = null; this.writeNext(); });
  }
  async flush(): Promise<void> {
    while (this.inFlight) await this.inFlight;
    if (this.state.kind === 'error' || this.blocked) throw new Error(this.state.message);
  }
}
