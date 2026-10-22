import { invoke, isTauri } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { getCurrentWebviewWindow } from '@tauri-apps/api/webviewWindow';
import type { FileInfo, Settings } from './domain';
import { emptyMedia, type LyricsCandidate, type MediaSnapshot } from './lyrics';
import { previewFileStatuses, type FileStatus } from './file-status';
export interface PeerStatus { installed: boolean; running: boolean; compatible: boolean; detail: string }
export interface CalendarFile { path: string; name: string; content: string }
export interface GifInfo { id: string; name: string }
export interface UpdateStatus { currentVersion: string; latestVersion: string | null; updateAvailable: boolean; url: string | null; checkedAt: string; message: string }
export interface IslandPreferences { swipeEnabled: boolean; sensitivity: 'low' | 'medium' | 'high'; startupDisplay: 'lastUsed' | 'xnook' | 'xisland' }
export type TrayAction = 'settings' | 'checkUpdates';
export const native = isTauri();
const PREVIEW_KEY = 'xnook:browser-development-preview:v1';
const requireNative = (): never => { throw new Error('此操作需要 Windows 客户端；当前为浏览器开发预览'); };
export const bridge = {
  read: (): Promise<string | null> => native ? invoke('read_store') : Promise.resolve(localStorage.getItem(PREVIEW_KEY)),
  write: (content: string): Promise<void> => native ? invoke('write_store', { content }) : Promise.resolve().then(() => localStorage.setItem(PREVIEW_KEY, content)),
  resize: (expanded: boolean, width = expanded ? 620 : 300, height = expanded ? 590 : 52): Promise<unknown> => native ? invoke('resize_island', { width, height, expanded }) : Promise.resolve(),
  focus: (): Promise<void> => native ? invoke('focus_input') : Promise.resolve(),
  configure: (followPointer: boolean, hideInFullscreen: boolean): Promise<void> => native ? invoke('configure_window', { followPointer, hideInFullscreen }) : Promise.resolve(),
  drag: (phase: 'begin' | 'update' | 'end'): Promise<unknown> => native ? invoke('drag_island', { phase }) : Promise.resolve(),
  files: (): Promise<FileInfo[] | null> => native ? invoke('pick_files') : Promise.reject(new Error('文件架需要 Windows 客户端，浏览器无法保存真实文件路径')),
  inspect: (paths: string[]): Promise<FileInfo[]> => native ? invoke('inspect_files', { paths }) : Promise.reject(new Error('浏览器无法验证本地路径')),
  fileStatuses: async (paths: string[]): Promise<FileStatus[]> => {
    if (!native) return previewFileStatuses(paths);
    const result: FileStatus[] = [];
    for (let offset = 0; offset < paths.length; offset += 128) {
      result.push(...await invoke<FileStatus[]>('file_statuses', { paths: paths.slice(offset, offset + 128) }));
    }
    return result;
  },
  open: (path: string): Promise<void> => native ? invoke('open_file', { path }) : Promise.reject(new Error('浏览器开发预览无法打开本机路径')),
  reveal: (path: string): Promise<void> => native ? invoke('reveal_file', { path }) : Promise.reject(new Error('浏览器开发预览无法定位本机路径')),
  export: async (title: string, content: string, format: 'md' | 'txt'): Promise<boolean> => {
    if (native) return invoke('export_note', { title, content, format });
    const url = URL.createObjectURL(new Blob([content], { type: 'text/plain;charset=utf-8' }));
    const a = document.createElement('a'); a.href = url; a.download = `${title.replace(/[<>:"/\\|?*]/g, '_')}.${format}`;
    a.click(); setTimeout(() => URL.revokeObjectURL(url), 1000); return true;
  },
  calendar: (): Promise<CalendarFile | null> => native ? invoke('pick_calendar') : Promise.resolve(requireNative()),
  refreshCalendar: (path: string): Promise<CalendarFile> => native ? invoke('read_calendar', { path }) : Promise.resolve(requireNative()),
  media: (preferredSourceId: string | null): Promise<MediaSnapshot> => native ? invoke('media_snapshot', { preferredSourceId }) : Promise.resolve({ ...emptyMedia(), sourceId: preferredSourceId || '', error: '浏览器预览不连接系统播放器' }),
  control: (sourceId: string, sessionToken: string, action: 'toggle' | 'next' | 'previous' | 'seek', position?: number): Promise<void> => native ? invoke('media_control', { sourceId, sessionToken, action, position }) : Promise.resolve(requireNative()),
  lyrics: (m: MediaSnapshot): Promise<LyricsCandidate[]> => native ? invoke('lookup_lyrics', { title: m.title, artist: m.artist, album: m.album, duration: m.duration }) : Promise.resolve([]),
  peer: (): Promise<PeerStatus> => native ? invoke('island_peer_status') : Promise.resolve({ installed: false, running: false, compatible: false, detail: '开发预览不连接 XIsland' }),
  switch: (): Promise<void> => native ? invoke('switch_island') : Promise.resolve(requireNative()),
  beginExit: (): Promise<void> => native ? invoke('begin_exit') : Promise.resolve(),
  cancelExit: (): Promise<void> => native ? invoke('cancel_exit') : Promise.resolve(),
  confirmExit: (): Promise<void> => native ? invoke('confirm_exit') : Promise.resolve(),
  preferences: (settings: Settings): Promise<void> => native ? invoke('apply_preferences', { settings }) : Promise.resolve(),
  getLogin: (): Promise<boolean> => native ? invoke('get_launch_at_login') : Promise.resolve(false),
  setLogin: (enabled: boolean): Promise<boolean> => native ? invoke('set_launch_at_login', { enabled }) : Promise.resolve(requireNative()),
  copyFiles: (paths: string[]): Promise<void> => native ? invoke('copy_files', { paths }) : Promise.resolve(requireNative()),
  dragFiles: (paths: string[]): Promise<void> => native ? invoke('start_file_drag', { paths }) : Promise.resolve(requireNative()),
  openPlayer: (sourceId: string, sessionToken: string): Promise<void> => native ? invoke('open_media_player', { sourceId, sessionToken }) : Promise.resolve(requireNative()),
  recover: async (content: string): Promise<{ backupPath: string }> => {
    if (native) return invoke('recover_store', { content });
    const backupPath = `${PREVIEW_KEY}:backup:${Date.now()}`;
    const original = localStorage.getItem(PREVIEW_KEY); if (original !== null) localStorage.setItem(backupPath, original);
    localStorage.setItem(PREVIEW_KEY, content); return { backupPath };
  },
  gifs: (): Promise<GifInfo[]> => native ? invoke('list_gifs') : Promise.resolve([]),
  importGif: (): Promise<GifInfo | null> => native ? invoke('import_gif') : Promise.resolve(requireNative()),
  readGif: (id: string): Promise<string> => native ? invoke('read_gif', { id }) : Promise.resolve(requireNative()),
  deleteGif: (id: string): Promise<void> => native ? invoke('delete_gif', { id }) : Promise.resolve(requireNative()),
  openCalendar: (path?: string): Promise<void> => native ? invoke('open_calendar', { path }) : Promise.resolve(requireNative()),
  reminder: (sound: Settings['reminderSound']): Promise<void> => native ? invoke('play_reminder_sound', { sound }) : Promise.resolve(requireNative()),
  updates: (force: boolean): Promise<UpdateStatus> => native ? invoke('check_updates', { force }) : Promise.resolve(requireNative()),
  openUpdate: (): Promise<void> => native ? invoke('open_update_page') : Promise.resolve(requireNative()),
  getIslandPreferences: (): Promise<IslandPreferences> => native ? invoke('island_get_preferences') : Promise.resolve({ swipeEnabled: true, sensitivity: 'medium', startupDisplay: 'lastUsed' }),
  setIslandPreferences: (preferences: IslandPreferences): Promise<IslandPreferences> => native ? invoke('island_set_preferences', { preferences }) : Promise.resolve(preferences),
  subscribe: async (onFiles: (paths: string[]) => void, onError: (message: string) => void, onExit: () => void, onDragging: (dragging: boolean) => void = () => {}, onCalendarTick: () => void = () => {}, onTrayAction: (action: TrayAction) => void | Promise<void> = () => {}): Promise<() => void> => {
    if (!native) return () => {};
    const unlistenDrop = await getCurrentWebviewWindow().onDragDropEvent(event => {
      onDragging(event.payload.type === 'enter' || event.payload.type === 'over');
      if (event.payload.type === 'drop') onFiles(event.payload.paths);
    });
    const unlistenError = await listen<string>('island-link-error', event => onError(event.payload));
    const unlistenNativeError = await listen<string>('native-error', event => onError(event.payload));
    const unlistenExit = await listen('request-exit', onExit);
    const unlistenCalendar = await listen('calendar-tick', onCalendarTick);
    let disposed = false, draining = false, drainAgain = false;
    const drainTrayActions = async (): Promise<void> => {
      if (disposed) return;
      if (draining) { drainAgain = true; return; }
      draining = true;
      try {
        do {
          drainAgain = false;
          const actions = await invoke<TrayAction[]>('take_tray_actions');
          for (const action of actions) if (!disposed && (action === 'settings' || action === 'checkUpdates')) await onTrayAction(action);
        } while (drainAgain && !disposed);
      } catch (error) { if (!disposed) onError(String(error)); }
      finally { draining = false; }
    };
    const unlistenTray = await listen('tray-actions-pending', () => { void drainTrayActions(); });
    await drainTrayActions();
    return () => { disposed = true; unlistenDrop(); unlistenError(); unlistenNativeError(); unlistenExit(); unlistenCalendar(); unlistenTray(); };
  },
};
