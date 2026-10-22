export interface FileInfo { path: string; name: string; isDirectory: boolean }
export interface ShelfFile extends FileInfo { id: string; addedAt: string }
export interface Note { id: string; title: string; content: string; createdAt: string; updatedAt: string }
export interface CalendarSource { id: string; path: string; name: string; content: string; importedAt: string }
export interface FlowSession {
  id: string; title: string; startedAt: string; endedAt: string | null;
  eventId: string | null; scheduledEndAt: string | null;
  linkedNote: { id: string; title: string; content: string } | null;
  linkedFiles: ShelfFile[];
}
export interface Settings extends Preferences { followPointer: boolean; hideInFullscreen: boolean; lyricsEnabled: boolean; preferredMediaSourceId: string | null }
export const validMediaSourceId = (value: unknown): value is string => typeof value === 'string' && !!value.trim() && !value.includes('\0') && value.length <= 4096;
export interface Store {
  version: 1; notes: Note[]; files: ShelfFile[]; calendars: CalendarSource[];
  activeSession: FlowSession | null; history: FlowSession[]; settings: Settings; remindedEvents: string[];
}
export const emptyStore = (): Store => ({
  version: 1, notes: [], files: [], calendars: [], activeSession: null, history: [], remindedEvents: [],
  settings: { ...structuredClone(defaultPreferences), followPointer: true, hideInFullscreen: true, lyricsEnabled: true, preferredMediaSourceId: null },
});
export function newNote(title = '', content = '', now = new Date().toISOString()): Note {
  return { id: crypto.randomUUID(), title, content, createdAt: now, updatedAt: now };
}
export const noteTitle = (note: Pick<Note, 'title' | 'content'>): string =>
  note.title.trim() || note.content.trim().split('\n')[0]?.replace(/^#+\s*/, '').slice(0, 48) || '未命名笔记';
export function searchNotes(notes: Note[], query: string): Note[] {
  const words = query.toLocaleLowerCase().trim().split(/\s+/).filter(Boolean);
  return notes.filter(n => words.every(w => `${n.title}\n${n.content}`.toLocaleLowerCase().includes(w)))
    .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
}
export function addFiles(store: Store, files: FileInfo[], now = new Date().toISOString()): void {
  const existing = new Set(store.files.map(f => f.path.toLocaleLowerCase()));
  for (const file of files) {
    const key = file.path.toLocaleLowerCase();
    if (!existing.has(key)) { store.files.push({ ...file, id: crypto.randomUUID(), addedAt: now }); existing.add(key); }
  }
}
export function startSession(store: Store, title: string, eventId: string | null = null,
  scheduledEndAt: string | null = null, now = new Date().toISOString()): FlowSession {
  if (store.activeSession) throw new Error('请先结束当前任务');
  const session: FlowSession = { id: crypto.randomUUID(), title: title.trim() || '未命名任务',
    startedAt: now, endedAt: null, eventId, scheduledEndAt, linkedNote: null, linkedFiles: [] };
  store.activeSession = session;
  return session;
}
export function endSession(store: Store, now = new Date().toISOString()): void {
  if (!store.activeSession) throw new Error('当前没有进行中的任务');
  store.history.unshift({ ...structuredClone(store.activeSession), endedAt: now });
  store.activeSession = null;
}
export function resumeSession(store: Store, id: string, now = new Date().toISOString()): void {
  const old = store.history.find(s => s.id === id);
  if (!old) throw new Error('任务记录不存在');
  const current = startSession(store, old.title, old.eventId, null, now);
  current.linkedNote = structuredClone(old.linkedNote);
  current.linkedFiles = structuredClone(old.linkedFiles);
}
export function linkFiles(store: Store): void {
  const active = store.activeSession;
  if (!active) throw new Error('请先开始一个任务');
  const paths = new Set(active.linkedFiles.map(f => f.path.toLocaleLowerCase()));
  active.linkedFiles.push(...structuredClone(store.files.filter(f => !paths.has(f.path.toLocaleLowerCase()))));
}
export function linkNote(store: Store, note: Note): void {
  if (!store.activeSession) throw new Error('请先开始一个任务');
  store.activeSession.linkedNote = { id: note.id, title: noteTitle(note), content: note.content };
}
export function refreshLinkedNote(store: Store, note: Note): void {
  if (store.activeSession?.linkedNote?.id === note.id) linkNote(store, note);
}
export function openLinkedNote(store: Store, sessionId: string, now = new Date().toISOString()): Note {
  const session = store.activeSession?.id === sessionId ? store.activeSession : store.history.find(item => item.id === sessionId);
  if (!session) throw new Error('任务记录不存在');
  const snapshot = session.linkedNote;
  if (!snapshot) throw new Error('任务没有关联笔记');
  const existing = store.notes.find(note => note.id === snapshot.id);
  if (existing) return existing;
  const restored = newNote(noteTitle(snapshot), snapshot.content, now);
  store.notes.push(restored);
  // 重绑后再次打开会复用同一笔记，历史正文仍保持结束时的快照。
  session.linkedNote = { ...snapshot, id: restored.id };
  return restored;
}
export function historyPage(history: readonly FlowSession[], page = 0, pageSize = 20): {
  items: FlowSession[]; page: number; pageSize: number; pageCount: number; total: number;
} {
  const size = Number.isFinite(pageSize) ? Math.max(1, Math.min(100, Math.floor(pageSize))) : 20;
  const pageCount = Math.max(1, Math.ceil(history.length / size));
  const index = Number.isFinite(page) ? Math.max(0, Math.min(pageCount - 1, Math.floor(page))) : 0;
  const endedTime = (session: FlowSession): number => {
    const value = Date.parse(session.endedAt || '');
    return Number.isFinite(value) ? value : -Infinity;
  };
  const sorted = [...history].sort((a, b) => endedTime(b) - endedTime(a));
  return { items: sorted.slice(index * size, (index + 1) * size), page: index, pageSize: size, pageCount, total: history.length };
}
export function deleteNote(store: Store, id: string): Note | null {
  const note = store.notes.find(n => n.id === id);
  if (!note) return null;
  store.notes = store.notes.filter(n => n.id !== id);
  return structuredClone(note);
}
export function undoDeleteNote(store: Store, note: Note): void {
  if (!store.notes.some(n => n.id === note.id)) store.notes.push(structuredClone(note));
}
import { defaultPreferences, type Preferences } from './preferences';
