import './styles.css';
import { bridge, native, type CalendarFile, type PeerStatus, type GifInfo, type IslandPreferences, type UpdateStatus } from './bridge';
import { addFiles, deleteNote, emptyStore, endSession, historyPage, linkFiles, linkNote, newNote, noteTitle, openLinkedNote, refreshLinkedNote, resumeSession, searchNotes, startSession, undoDeleteNote, type Note, type FlowSession, type Settings, type CalendarSource } from './domain';
import { StoreController } from './storage';
import type { CalendarEvent } from './calendar';
import { CalendarClient } from './calendar-client';
import { LyricsController, currentLyric, emptyMedia, mediaPosition, trackKey, type Lyrics } from './lyrics';
import { panelShortcut } from './keyboard';
import { ExitGate } from './exit';
import { MediaSelection, type MediaAction } from './media-selection';
import { CollapsePolicy, jellyScale, magneticOffset, parsePreferences, protectsPanel, resolvedAppearance, widgetIds, windowSize, type WidgetId } from './preferences';
import { html, language, locale, setLanguage, t } from './i18n';
import { settingsView } from './settings-view';
import { planReminders, RefreshScheduler } from './calendar-services';
import { calendarSourceColor, eventsForDay, eventStatus, overviewEvents, visibleDates } from './calendar-view';
import { fileStatusMap, formatFileSize, type FileStatus } from './file-status';
import { PillGesture } from './pill-gesture';

type View = 'overview' | 'media' | 'calendar' | 'notes' | 'files' | 'flow' | 'settings';
const labels: Record<View, string> = { overview: '概览', media: '音乐', calendar: '日历', notes: '笔记', files: '文件架', flow: 'NookFlow', settings: '设置' };
const shapes: Record<string, string> = {
  overview: '<rect x="3" y="3" width="7" height="7" rx="2"/><rect x="14" y="3" width="7" height="7" rx="2"/><rect x="3" y="14" width="7" height="7" rx="2"/><rect x="14" y="14" width="7" height="7" rx="2"/>',
  media: '<path d="M9 18V5l12-2v13M9 8l12-2"/><ellipse cx="6" cy="18" rx="3" ry="3"/><ellipse cx="18" cy="16" rx="3" ry="3"/>',
  calendar: '<rect x="3" y="5" width="18" height="16" rx="3"/><path d="M7 3v4m10-4v4M3 11h18m-13 4h2m4 0h2m-8 3h2"/>',
  notes: '<path d="M15 3H6a3 3 0 0 0-3 3v12a3 3 0 0 0 3 3h12a3 3 0 0 0 3-3V9zM15 3v6h6M7 13h10m-10 4h7"/>',
  files: '<path d="M3 7h6l2-3h7a3 3 0 0 1 3 3v11a3 3 0 0 1-3 3H6a3 3 0 0 1-3-3z"/>',
  flow: '<path d="M12 3v4m0 10v4M3 12h4m10 0h4"/><circle cx="12" cy="12" r="5"/>',
  settings: '<path d="m9 3-1 3-3 1 1 3-2 2 2 2-1 3 3 1 1 3h6l1-3 3-1-1-3 2-2-2-2 1-3-3-1-1-3z"/><circle cx="12" cy="12" r="3"/>',
  close: '<path d="m6 6 12 12M6 18 18 6"/>', plus: '<path d="M12 5v14M5 12h14"/>',
  link: '<path d="M9 8H6a4 4 0 0 0 0 8h3m6-8h3a4 4 0 0 1 0 8h-3M8 12h8"/>',
  play: '<path d="m8 5 11 7-11 7z"/>', pause: '<path d="M8 5v14M16 5v14"/>',
  next: '<path d="m5 5 10 7-10 7zM19 5v14"/>', previous: '<path d="m19 5-10 7 10 7zM5 5v14"/>',
  arrow: '<path d="m9 6 6 6-6 6"/>', check: '<path d="m5 12 4 4L19 6"/>',
};
const icon = (name: string): string => html`<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${shapes[name] || shapes.files}</svg>`;
const escape = (value: unknown): string => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);
const formatTime = (seconds: number | null): string => seconds === null ? '—:—' : `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, '0')}`;
const dayKey = (date: Date): string => `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
const dateTime = (iso: string): string => new Date(iso).toLocaleString(locale(), { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' });
const root = document.querySelector<HTMLDivElement>('#app')!;
let exitControls: { element: HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement | HTMLButtonElement; disabled: boolean }[] = [];
const exitGate = new ExitGate(busy => {
  root.inert = busy; root.setAttribute('aria-busy', String(busy));
  if (busy) {
    exitControls = [...root.querySelectorAll<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement | HTMLButtonElement>('input, textarea, select, button')]
      .map(element => ({ element, disabled: element.disabled }));
    for (const { element } of exitControls) element.disabled = true;
    toast(t('正在保存并退出…'));
  } else {
    for (const { element, disabled } of exitControls) element.disabled = disabled;
    exitControls = [];
  }
});
function ensureEditing(): void { if (exitGate.pending) throw new Error(t('正在保存并退出，请稍候')); }
let expanded = false, view: View = 'overview', selectedNote: string | null = null, search = '', selectedDay = dayKey(new Date());
let flowDraft = '';
let allHistory = false, historyPageIndex = 0, selectedHistory: string | null = null;
let month = new Date(new Date().getFullYear(), new Date().getMonth(), 1);
let lastToday = dayKey(new Date());
let events: CalendarEvent[] = [], calendarWarnings: string[] = [], calendarErrors: string[] = [];
let deleted: Note | null = null, toastTimer: ReturnType<typeof setTimeout>;
let peer: PeerStatus = { installed: false, running: false, compatible: false, detail: t('正在检查 XIsland…') }, switching = false;
let media = emptyMedia(), lyrics: Lyrics | null = null, lyricStatus = '', mediaKey = '';
let mediaContentDirty = false, mediaSelectorDirty = false, seeking = false;
let saveTimer: ReturnType<typeof setTimeout> | undefined, composing = false, mounted = false;
let gifs: GifInfo[] = [], gifData = '', gifStill = '', gifGeneration = 0;
let sharedPreferences: IslandPreferences = { swipeEnabled: true, sensitivity: 'medium', startupDisplay: 'lastUsed' }, sharedReady = false;
let updateStatus: UpdateStatus | null = null;
let nextAutomaticUpdate = 0, automaticUpdateBusy = false;
let lastBackupPath: string | null = null;
let pointerInside = false, expandedByHover = false, hoverEnteredAt = 0, dropActive = false, fileDragging = false, nativeDialog = false;
let panelActionAt = Date.now(), calendarServiceBusy = false, calendarServiceRequested = false;
let preferenceQueue = Promise.resolve(), sharedPreferenceQueue = Promise.resolve(), sharedPending = 0, sharedRevision = 0;
let confirmationAction: (() => Promise<void>) | null = null;
let fileStatuses = new Map<string,FileStatus>(), fileStatusBusy = false, fileStatusError = '', fileStatusRevision = 0, fileStatusRefreshRequested = false;
let contextMenuOpen = false, expandedHeight = 590, resizeFrame = 0;
let discardOnExit = false;
const pillGesture = new PillGesture();
const collapsePolicy = new CollapsePolicy();
const darkMedia = matchMedia('(prefers-color-scheme: dark)'), reducedMedia = matchMedia('(prefers-reduced-motion: reduce)');
const calendarClient = new CalendarClient();
let calendarGeneration = 0, calendarImportGeneration = 0;
let calendarController: AbortController | null = null, calendarImportController: AbortController | null = null;
const refreshScheduler = new RefreshScheduler({ read: bridge.refreshCalendar, validate: async (sources, signal) => {
  const { from, to } = calendarRange();
  const result = await calendarClient.expand(sources, from, to, signal);
  if (result.errors.length) throw new Error(result.errors.join('\n'));
} });
const storage = new StoreController(bridge, () => updateSaveStatus());
const lyricController = new LyricsController(bridge.lyrics);
const mediaSelection = new MediaSelection({ snapshot: bridge.media, control: bridge.control });
const store = () => storage.store;
const editDisabled = (): string => storage.blocked ? ' disabled' : '';
const reduceMotion = (): boolean => store().settings.reduceMotion || reducedMedia.matches;
const tickerVisible = (): boolean => media.available && media.playing && (store().settings.showTicker || store().settings.lyricsEnabled);
const visibleWidgets = (): View[] => ['overview', ...store().settings.enabledWidgets, 'flow'];
function activeTicker(): string {
  if (store().settings.lyricsEnabled) {
    const position = mediaPosition(media);
    const line = position === null ? -1 : currentLyric(lyrics?.lines || [], position);
    if (line >= 0 && lyrics?.lines[line]?.text) return lyrics.lines[line].text;
    if (lyrics?.plain.trim()) return lyrics.plain.trim().split('\n').find(Boolean) || '';
  }
  return store().settings.showTicker ? [media.title, media.artist].filter(Boolean).join(' — ') : '';
}
async function resizeWindow(): Promise<void> {
  const dimensions = windowSize(store().settings, expanded, tickerVisible());
  if (expanded) dimensions.height = measureExpandedHeight();
  else if (contextMenuOpen) { dimensions.height += 100; dimensions.width=Math.max(220,dimensions.width); }
  expandedHeight = dimensions.height;
  applyVisualPreferences();
  await bridge.resize(expanded, dimensions.width, dimensions.height);
}
function measureExpandedHeight(): number {
  const content = document.querySelector<HTMLElement>('#content'), inner = document.querySelector<HTMLElement>('#content-inner');
  const panel = document.querySelector<HTMLElement>('.panel');
  if (!content || !inner || !panel) return store().settings.panelHeight;
  const style = getComputedStyle(content);
  const other = [...panel.children].filter(node=>node!==content).reduce((sum,node)=>sum+(node as HTMLElement).offsetHeight,0);
  return Math.min(store().settings.panelHeight,Math.max(200,Math.ceil(inner.getBoundingClientRect().height+Number.parseFloat(style.paddingTop)+Number.parseFloat(style.paddingBottom)+other+10)));
}
function schedulePanelSize(): void {
  if (!expanded || resizeFrame) return;
  resizeFrame = requestAnimationFrame(()=>{ resizeFrame=0; const height=measureExpandedHeight(); if (expanded && Math.abs(height-expandedHeight)>1) void perform(resizeWindow); });
}
const contentObserver = new ResizeObserver(schedulePanelSize);
function applyVisualPreferences(): void {
  const settings = store().settings;
  setLanguage(settings.language); document.documentElement.lang = locale();
  document.documentElement.dataset.appearance = resolvedAppearance(settings.appearance, darkMedia.matches);
  document.documentElement.style.colorScheme = document.documentElement.dataset.appearance;
  root.dataset.reduceMotion = String(reduceMotion()); root.dataset.hideCursor = String(settings.hideCursor);
  root.dataset.ticker = String(tickerVisible());
  const dimensions = windowSize(settings, expanded, tickerVisible());
  root.dataset.squashed=String(!expanded && dimensions.height<28);
  root.style.setProperty('--island-width', `${dimensions.width - 12}px`);
  root.style.setProperty('--island-height', `${dimensions.height - 4}px`);
  root.style.setProperty('--panel-width', `${settings.panelWidth - 12}px`); root.style.setProperty('--panel-height', `${Math.min(settings.panelHeight,expandedHeight) - 9}px`);
  root.dataset.playing = String(media.available && media.playing);
  root.style.setProperty('--jelly-scale', String(jellyScale(settings.jellyIntensity)));
  if (reduceMotion() || expanded) { root.classList.remove('jelly'); root.style.setProperty('--magnetic-x','0px'); }
}
function protectedInteraction(): boolean {
  const active = document.activeElement as HTMLElement | null;
  return exitGate.pending || protectsPanel({ editing: !!active?.matches('input,textarea,[contenteditable]'), composing,
    selection: !!window.getSelection()?.toString(), menu: contextMenuOpen || !!active?.matches('select') || !!document.querySelector('dialog[open]') || nativeDialog,
    dragging: dragging || pillGesture.active || fileDragging || seeking, fileDrop: dropActive });
}
async function transitionPanel(open: boolean, byHover = false): Promise<void> {
  if (!open && protectedInteraction()) return;
  expanded = open; expandedByHover = open && byHover; panelActionAt = Date.now(); collapsePolicy.reset(); render(); await resizeWindow();
  if (open && !byHover) await bridge.focus();
}

function toast(message: string): void {
  const target = document.querySelector<HTMLElement>('#toast');
  if (target) { target.textContent = t(message); target.hidden = false; clearTimeout(toastTimer); toastTimer = setTimeout(() => { target.hidden = true; }, 5500); }
}
async function perform(action: () => Promise<unknown> | unknown): Promise<void> {
  try { await action(); } catch (error) { toast(error instanceof Error ? error.message : String(error)); }
}
async function nativePicker<T>(choose: () => Promise<T>): Promise<T> { nativeDialog = true; try { return await choose(); } finally { nativeDialog = false; } }
async function persist(): Promise<void> { clearTimeout(saveTimer); saveTimer = undefined; await storage.save(); }
function scheduleSave(): void {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => { void persist().catch(() => {}); }, 350);
  const target = document.querySelector('#save-status'); if (target) target.textContent = t('有未保存修改');
}
function updateSaveStatus(): void {
  const status = document.querySelector<HTMLElement>('#save-status');
  if (status) {
    status.textContent = t(saveTimer && storage.state.kind !== 'error' && storage.state.kind !== 'blocked' ? t('有未保存修改') : storage.state.message);
    status.dataset.kind = storage.state.kind;
  }
  const retry = document.querySelector<HTMLButtonElement>('#retry-save');
  if (retry) retry.hidden = storage.state.kind !== 'error';
}
function empty(title: string, detail: string, action = ''): string {
  return html`<div class="empty"><div class="empty-orbit">${icon(view)}</div><strong>${t(title)}</strong><p>${t(detail)}</p>${action}</div>`;
}
function button(action: string, label: string, symbol = '', className = '', attrs = '', userLabel = false): string {
  return html`<button type="button" data-action="${action}" class="${className}" ${attrs}>${symbol ? icon(symbol) : ''}${userLabel ? label : t(label)}</button>`;
}
function render(): void {
  closeContextMenu(false);
  const oldScroll = root.dataset.view === view ? document.querySelector('#content')?.scrollTop || 0 : 0;
  mounted = true;
  applyVisualPreferences(); root.dataset.view = view;
  root.className = expanded ? 'expanded' : 'collapsed';
  root.innerHTML = html`<section class="island" aria-label="XNook 工具面板">
    <div class="pill" ${expanded ? 'hidden' : ''}>
      ${media.available && media.artwork ? html`<button class="pill-art" data-action="media-open" data-source-id="${escape(media.sourceId)}" data-session-token="${escape(media.sessionToken || '')}" aria-label="打开播放器"><img src="${escape(media.artwork)}" alt="专辑封面"></button>` : ''}
      <button class="pill-open" data-action="expand" aria-label="展开 XNook"><span class="brand-mark">${icon('overview')}</span><span class="pill-copy"><b>XNook</b><span id="pill-detail">${escape(store().activeSession?.title || (media.available ? media.title : t('留一点空间给自己')))}</span></span><span class="activity-dots"><i></i><i></i><i></i></span></button>
      ${(reduceMotion() ? '' : media.playing ? gifData : gifStill) ? html`<img class="pill-gif" src="${escape(media.playing ? gifData : gifStill)}" alt="自定义 GIF">` : ''}
      ${button('switch', '', 'link', 'icon-button pill-switch', html`aria-label="切换到 XIsland" title="${escape(peer.detail)}" ${switching ? 'disabled' : ''}`)}
    </div>
    <div class="pill-ticker" ${!expanded && tickerVisible() ? '' : 'hidden'}><span id="pill-ticker-text">${escape(activeTicker())}</span></div>
    <div class="panel" ${expanded ? '' : 'hidden'}>
      <header><div class="brand"><span class="brand-mark">${icon('overview')}</span><b>XNook</b><span class="platform-label">WINDOWS</span></div><span class="header-spacer" id="drag-handle" title="拖动窗口"></span>
      ${button('switch', switching ? t('切换中…') : 'XIsland', 'link', 'peer-button', `title="${escape(peer.detail)}" ${switching ? 'disabled' : ''}`)}
      ${button('view:settings', '', 'settings', 'icon-button', html`aria-label="打开设置"`)}${button('collapse', '', 'close', 'icon-button', html`aria-label="收起面板"`)}</header>
      ${!native ? html`<div class="preview-banner">浏览器开发预览 · 数据仅保存在此浏览器 · 系统功能需 Windows 客户端</div>` : ''}
      ${storage.blocked ? html`<div class="storage-block" role="alert">${escape(storage.state.message)}<p>原件受到保护，当前不可编辑。</p>${button('store-reload',t('重新读取'))}${button('store-recover',t('备份并恢复为空数据'))}</div>` : ''}
      <nav aria-label="工具导航"><select id="compact-nav" aria-label="${t('选择工具','Choose tool')}">${[...new Set([...visibleWidgets(),view])].map(item=>html`<option value="${item}" ${view===item?'selected':''}>${t(labels[item])}</option>`).join('')}</select>${[...new Set([...visibleWidgets(), ...(view !== 'settings' ? [view] : [])])].map(v => button(`view:${v}`, t(labels[v]), v, view === v ? 'nav-button active' : 'nav-button', `aria-current="${view === v ? 'page' : 'false'}"`)).join('')}</nav>
      <main id="content" tabindex="-1"><div id="content-inner">${renderView()}</div></main>
      <footer><span class="save-dot" aria-hidden="true"></span><span id="save-status" role="status"></span>${button('retry-save', t('重试保存'), '', 'text-button', 'id="retry-save" hidden')}<span class="footer-spacer"></span><span>横向轻扫 · 切换工作岛</span></footer>
    </div><div id="toast" class="toast" role="status" hidden></div></section>`;
  updateSaveStatus(); updateSharedControls();
  contentObserver.disconnect(); const inner = document.querySelector('#content-inner'); if (inner) contentObserver.observe(inner); schedulePanelSize();
  const content = document.querySelector('#content'); if (content) content.scrollTop = oldScroll;
  const peerText = document.querySelector('#peer-detail'); if (peerText) peerText.textContent = peer.detail;
  updateClock();
}
function renderView(): string {
  if (view === 'overview') return renderOverview();
  if (view === 'media') return html`<div id="media-panel">${renderMedia()}</div>`;
  if (view === 'calendar') return renderCalendar();
  if (view === 'notes') return renderNotes();
  if (view === 'files') return renderFiles();
  if (view === 'flow') return renderFlow();
  return renderSettings();
}
function renderOverview(): string {
  const selected = new Date(`${selectedDay}T12:00:00`), agenda = overviewEvents(events, selected);
  const recentNotes = searchNotes(store().notes, '').slice(0,4);
  const dates = Array.from({length:7},(_,i) => { const date = new Date(selected); date.setDate(date.getDate()+i-3); return date; });
  return html`<div class="section-heading"><div><span class="eyebrow">YOUR LITTLE CORNER</span><h1>把此刻，放在眼前。</h1></div><span class="today">${new Date().toLocaleDateString(locale(), { month:'long',day:'numeric',weekday:'short' })}</span></div>
    <section class="overview-flow" aria-label="NookFlow"><div class="overview-heading"><span class="eyebrow">NOOKFLOW</span>${button('view:flow',t('任务详情','Task details'),'arrow','text-button')}</div>${store().activeSession ? renderSession(store().activeSession!,true) : renderStartForm(true)}</section>
    <div class="overview-grid">
    ${store().settings.enabledWidgets.includes('media') ? html`<section class="overview-card overview-tool"><div class="overview-heading"><span class="card-label">正在播放</span>${button('view:media',t('查看全部','View all'),'arrow','text-button')}</div><strong id="overview-track">${escape(media.available ? media.title : t('等待音乐响起'))}</strong><small id="overview-artist">${escape(media.available ? media.artist : t('连接 Windows 系统媒体会话'))}</small><div id="overview-media-controls">${renderOverviewMediaControls()}</div></section>` : ''}
    ${store().settings.enabledWidgets.includes('calendar') ? html`<section class="overview-card overview-tool overview-calendar"><div class="overview-heading"><span class="card-label">${t('所选日日程','Selected day')}</span>${button('view:calendar',t('查看全部','View all'),'arrow','text-button')}</div><div class="overview-dates" aria-label="${t('选择日程日期','Choose agenda date')}">${dates.map(date=>button(`overview-day:${dayKey(date)}`,String(date.getDate()),'',`day ${dayKey(date)===selectedDay ? 'selected' : ''}`,`aria-label="${dayKey(date)}" aria-pressed="${dayKey(date)===selectedDay}"`)).join('')}</div><small>${selected.toLocaleDateString(locale(),{month:'long',day:'numeric',weekday:'short'})}</small><div class="overview-agenda">${agenda.length ? agenda.map(event=>renderEvent(event,true)).join('') : html`<p class="hint">${t(dayKey(new Date())===selectedDay && eventsForDay(events,selected).length ? '今天的日程已结束' : '这一天还没有日程',dayKey(new Date())===selectedDay && eventsForDay(events,selected).length ? 'Today’s events have ended' : 'No events on this day')}</p>`}</div>${selectedDay!==dayKey(new Date()) ? button('calendar-today',t('回到今天'),'','text-button') : ''}</section>` : ''}
    ${store().settings.enabledWidgets.includes('notes') ? html`<section class="overview-card overview-tool"><div class="overview-heading"><span class="card-label">随手记</span>${button('view:notes',t('查看全部','View all'),'arrow','text-button')}</div>${button('note-new',t('新建笔记'),'plus','subtle',editDisabled())}<div class="overview-list">${recentNotes.length ? recentNotes.map(note=>button('overview-note',escape(displayNoteTitle(note)),'notes','overview-item',`data-id="${escape(note.id)}"`,true)).join('') : html`<small>${t('你的笔记会出现在这里')}</small>`}</div></section>` : ''}
    ${store().settings.enabledWidgets.includes('files') ? html`<section class="overview-card overview-tool"><div class="overview-heading"><span class="card-label">文件架</span>${button('view:files',t('查看全部','View all'),'arrow','text-button')}</div>${button('files-add',t('添加文件'),'plus','subtle',editDisabled())}<div class="overview-list">${store().files.slice(0,4).map(file=>button('file-open',escape(file.name),'files','overview-item',`data-id="${escape(file.id)}" title="${escape(file.path)}"`,true)).join('') || html`<small>${t('文件架还是空的。','Your file shelf is empty.')}</small>`}</div></section>` : ''}
    </div>${renderRecentHistory()}`;
}
function renderOverviewMediaControls(): string {
  const attributes = `data-source-id="${escape(media.sourceId)}" data-session-token="${escape(media.sessionToken || '')}"`;
  return html`<div class="overview-transport">${button('media:previous','','previous','icon-button',`${attributes} aria-label="${t('上一首')}" ${media.available && media.sessionToken && media.canPrevious ? '' : 'disabled'}`)}${button('media:toggle','',media.playing ? 'pause' : 'play','play-button',`${attributes} aria-label="${t(media.playing ? '暂停' : '播放')}" ${media.available && media.sessionToken && media.canPlayPause ? '' : 'disabled'}`)}${button('media:next','','next','icon-button',`${attributes} aria-label="${t('下一首')}" ${media.available && media.sessionToken && media.canNext ? '' : 'disabled'}`)}<span class="mini-wave" aria-hidden="true"><i></i><i></i><i></i><i></i><i></i></span></div>`;
}
function renderEvent(event: CalendarEvent, compact = false): string {
  const status = eventStatus(event), statusLabel = status==='ongoing' ? t('进行中','Ongoing') : status==='ended' ? t('已结束','Ended') : '';
  const source = store().calendars.find(source=>source.id===event.sourceId);
  return html`<article class="event ${compact ? 'compact-event' : ''}" data-event-status="${status}" style="--source-color:${calendarSourceColor(event.sourceId)}"><span class="event-time">${event.allDay ? t('全天') : new Date(event.start).toLocaleTimeString(locale(),{hour:'2-digit',minute:'2-digit'})}</span><div><strong>${escape(event.title)}</strong>${statusLabel ? html`<span class="event-status">${statusLabel}</span>` : ''}${source ? html`<small class="event-source">${escape(source.name)}</small>` : ''}${!compact && event.location ? html`<small>${escape(event.location)}</small>` : ''}${!compact ? html`<small>${t('至 ','Until ')}${event.allDay ? new Date(+new Date(event.end)-1).toLocaleDateString(locale()) : dateTime(event.end)}</small>${event.description ? html`<p class="event-description">${escape(event.description)}</p>` : ''}` : ''}${button('event-flow',t('开始专注'),'flow','text-button',`data-id="${escape(event.id)}"${editDisabled()}`)}</div></article>`;
}
function renderMedia(): string {
  return html`<div class="media-source-picker"><label for="media-source-select">播放器</label><select id="media-source-select" aria-label="播放器"${editDisabled()}>${renderSourceOptions()}</select><p id="media-source-status">${escape(sourceStatus())}</p></div><div id="media-content">${renderMediaContent()}</div>`;
}
function renderSourceOptions(): string {
  const preferred = mediaSelection.preferredSourceId;
  const options = [html`<option value=""${preferred === null ? ' selected' : ''}>自动选择</option>`];
  for (const source of media.sources) options.push(html`<option value="${escape(source.sourceId)}"${preferred === source.sourceId ? ' selected' : ''}>${escape(source.name || source.sourceId)}${source.playing ? ' · ' + t('正在播放') : ''}${source.isSystemCurrent ? ' · ' + t('系统当前') : ''}</option>`);
  if (preferred && !media.sources.some(source => source.sourceId === preferred)) options.push(html`<option value="${escape(preferred)}" selected>${escape(media.playerName || preferred)} · 离线</option>`);
  return options.join('');
}
function sourceStatus(): string {
  if (!native) return t('浏览器开发预览不连接系统播放器。');
  if (mediaSelection.preferredSourceId) return media.available ? `${t('已固定 ')}${media.playerName || t('所选播放器')}` : t('所选播放器暂不可用，将保留选择，不控制其他播放器。');
  return media.available ? `${t('自动选择')} · ${media.playerName || media.sourceId}` : t('自动优先正在播放的网易云音乐和 QQ 音乐。');
}
function renderMediaContent(): string {
  if (!media.available) {
    const fixed = mediaSelection.preferredSourceId !== null;
    return empty(fixed ? t('所选播放器暂未连接') : t('音乐，随你而来'), escape(media.error || t(fixed
      ? t('打开所选播放器并开始播放。连接恢复后会继续读取这个播放器，不会自动换到其他软件。')
      : t('打开网易云音乐、QQ 音乐或其他支持 Windows 系统媒体控制的播放器并开始播放。未公开媒体会话的客户端暂时无法检测。'))),
    fixed ? button('media-auto', t('回到自动选择'), '', 'subtle', editDisabled()) : '');
  }
  const artwork = media.artwork && /^(data:image\/(png|jpeg|webp|gif);base64,)/.test(media.artwork) ? html`<img src="${escape(media.artwork)}" alt="专辑封面">` : icon('media');
  return html`<div class="media-hero"><button class="album-art" data-action="media-open" data-source-id="${escape(media.sourceId)}" data-session-token="${escape(media.sessionToken || '')}" aria-label="打开播放器" ${media.sessionToken ? '' : 'disabled'}>${artwork}</button><div class="grow"><span class="eyebrow">NOW PLAYING</span><h1>${escape(media.title || t('未知曲目'))}</h1><p>${escape(media.artist || t('未知艺术家'))}</p><small>${escape(media.album || media.sourceId)}</small></div></div>
    <div class="progress"><input id="media-seek" data-source-id="${escape(media.sourceId)}" data-session-token="${escape(media.sessionToken || '')}" aria-label="播放进度" type="range" min="0" max="${media.duration || 1}" value="${mediaPosition(media) || 0}" step="0.1" ${media.sessionToken && media.canSeek && media.duration && media.position !== null ? '' : 'disabled'}><div><span id="media-position"></span><span>${formatTime(media.duration)}</span></div></div>
    <div class="transport">${button('media:previous', '', 'previous', 'icon-button', html`data-source-id="${escape(media.sourceId)}" data-session-token="${escape(media.sessionToken || '')}" aria-label="上一首" ${media.sessionToken && media.canPrevious ? '' : 'disabled'}`)}${button('media:toggle', '', media.playing ? 'pause' : 'play', 'play-button', `data-source-id="${escape(media.sourceId)}" data-session-token="${escape(media.sessionToken || '')}" aria-label="${media.playing ? t('暂停') : t('播放')}" ${media.sessionToken && media.canPlayPause ? '' : 'disabled'}`)}${button('media:next', '', 'next', 'icon-button', html`data-source-id="${escape(media.sourceId)}" data-session-token="${escape(media.sessionToken || '')}" aria-label="下一首" ${media.sessionToken && media.canNext ? '' : 'disabled'}`)}</div>
    ${media.error ? html`<p class="hint">${escape(media.error)}</p>` : ''}
    <div class="lyrics" id="lyrics" aria-label="歌词">${renderLyrics()}</div>`;
}
function renderLyrics(): string {
  if (!store().settings.lyricsEnabled) return html`<p class="muted">歌词已关闭，可在设置中开启。</p>`;
  if (!lyrics) return html`<p class="muted">${escape(lyricStatus || t('没有找到匹配歌词'))}</p>`;
  if (lyrics.instrumental) return html`<p class="muted">纯音乐 · 让旋律自己说话</p>`;
  if (!lyrics.lines.length) return html`<p class="plain-lyrics">${escape(lyrics.plain || t('暂无歌词'))}</p>`;
  return lyrics.lines.map((line, i) => html`<p data-lyric="${i}">${escape(line.text || '♪')}</p>`).join('');
}
function renderCalendar(): string {
  const days = visibleDates(month), items = eventsForDay(events,new Date(`${selectedDay}T12:00:00`));
  return html`<div class="section-heading"><div><span class="eyebrow">CALENDAR</span><h1>为今天留出时间</h1></div>${button('calendar-default',t('打开日历'),'','text-button')}${button('calendar-import',t('导入 .ics'),'plus','subtle',editDisabled())}<input id="ics-input" type="file" accept=".ics,text/calendar" hidden></div>
    <div class="calendar-layout"><div class="month-panel"><div class="month-heading">${button('month:-1','‹','','icon-button',html`aria-label="上个月"`)}<b>${month.toLocaleDateString(locale(),{year:'numeric',month:'long'})}</b>${button('month:1','›','','icon-button',html`aria-label="下个月"`)}</div><div class="calendar-grid">${(language()==='zh' ? ['一','二','三','四','五','六','日'] : ['M','T','W','T','F','S','S']).map(day=>html`<small>${day}</small>`).join('')}${days.map(date=>html`<button data-action="day:${dayKey(date)}" aria-label="${dayKey(date)}" aria-pressed="${dayKey(date)===selectedDay}" class="day ${date.getMonth()!==month.getMonth() ? 'outside' : ''} ${dayKey(date)===selectedDay ? 'selected' : ''} ${dayKey(date)===dayKey(new Date()) ? 'today-day' : ''}">${date.getDate()}${eventsForDay(events,date).length ? '<i></i>' : ''}</button>`).join('')}</div>${button('calendar-today',t('回到今天'),'','text-button')}</div>
    <div class="agenda"><span class="eyebrow">${selectedDay}</span>${items.length ? items.map(event=>renderEvent(event)).join('') : html`<div class="agenda-empty">这一天还没有日程<br><span>给自己一点自由的时间。</span></div>`}</div></div>
    ${calendarErrors.map(error=>html`<p class="inline-error">${escape(error)}</p>`).join('')}${calendarWarnings.map(warning=>html`<p class="hint">${escape(warning)}</p>`).join('')}
    <div class="source-list">${store().calendars.map(source=>html`<div><span>${icon('calendar')}${escape(source.name)}<small>${dateTime(source.importedAt)} 导入</small></span>${button('calendar-refresh',t('刷新'),'','text-button',`data-id="${escape(source.id)}"${editDisabled()}`)}${button('calendar-open',t('打开'),'','text-button',`data-id="${escape(source.id)}"`)}${button('calendar-remove',t('移除'),'','text-button danger',`data-id="${escape(source.id)}"${editDisabled()}`)}</div>`).join('')}</div>${!store().calendars.length ? html`<p class="hint">只读取你选择的本地 .ics 文件；重新导入同一路径会更新日程。</p>` : ''}`;
}
function renderNotes(): string {
  const filtered = searchNotes(store().notes, search), note = store().notes.find(n => n.id === selectedNote);
  return html`<div class="section-heading"><div><span class="eyebrow">QUICK NOTES</span><h1>接住一闪而过的想法</h1></div>${button('note-new', t('新建笔记'), 'plus', 'subtle', editDisabled())}</div>
    <div class="notes-layout"><aside class="note-sidebar"><input type="search" id="note-search" placeholder="搜索笔记…" aria-label="搜索笔记" value="${escape(search)}"><div id="note-list">${renderNoteList(filtered)}</div></aside><div class="note-editor">${note ? html`<input id="note-title" value="${escape(note.title)}" placeholder="未命名笔记" aria-label="笔记标题" maxlength="200"${editDisabled()}><textarea id="note-content" placeholder="从这里开始写…" aria-label="笔记内容" spellcheck="false"${editDisabled()}>${escape(note.content)}</textarea><div class="editor-toolbar"><span id="note-length">${note.content.length}${t(' 字', ' characters')}</span>${button('note-export-md', t('导出 Markdown'), '', 'text-button')}${button('note-export-txt', 'TXT', '', 'text-button')}${store().activeSession ? button('note-link', t('关联任务'), 'link', 'text-button', editDisabled()) : ''}${button('note-delete', t('删除'), '', 'text-button danger', editDisabled())}</div>` : empty(t('留下一个想法'), store().notes.length ? t('选择一篇笔记，继续上次的思路。') : t('笔记自动保存到本机，支持 Markdown 原文导出。'), button('note-new', t('写第一篇笔记'), 'plus', 'primary', editDisabled()))}</div></div>
    ${deleted ? html`<div class="undo-bar">已删除「${escape(displayNoteTitle(deleted))}」${button('note-undo', t('撤销删除'), '', 'text-button', editDisabled())}</div>` : ''}`;
}
function renderNoteList(notes: Note[]): string {
  return notes.length ? notes.map(n => html`<button class="note-item ${n.id === selectedNote ? 'selected' : ''}" data-action="note-select" data-id="${escape(n.id)}"><strong>${escape(displayNoteTitle(n))}</strong><span>${escape(n.content.replace(/\n/g, ' ').slice(0, 65) || t('还没有内容'))}</span><small>${dateTime(n.updatedAt)}</small></button>`).join('') : html`<p class="hint">${t(search ? t('没有匹配的笔记') : t('你的笔记会出现在这里'))}</p>`;
}
function renderFiles(): string {
  return html`<div class="section-heading"><div><span class="eyebrow">FILE SHELF</span><h1>常用文件，触手可及</h1></div>${button('files-refresh',t('刷新文件状态','Refresh files'),'','text-button',fileStatusBusy ? 'disabled' : '')}${button('files-add', t('添加文件'), 'plus', 'subtle', editDisabled())}</div>
    <div class="drop-zone"><span>${icon('files')}</span><b>把文件拖到岛上</b><small>保留原位置，随时打开或定位文件</small></div>
    ${fileStatusError ? html`<p class="inline-error">${escape(fileStatusError)}</p>` : ''}<div class="file-list">${store().files.map(f => { const status=fileStatuses.get(f.path.toLocaleLowerCase()); return html`<article class="file-row" data-file-id="${escape(f.id)}" data-available="${status?.available ?? 'unknown'}"><div class="file-symbol">${icon(f.isDirectory ? 'files' : 'notes')}</div><div class="grow"><strong title="${escape(f.path)}">${escape(f.name)}</strong><small>${escape(f.path)}</small><small class="file-status">${status ? status.available ? (status.isDirectory ? t('文件夹','Folder') : formatFileSize(status.sizeBytes)) : escape(status.error || t('文件暂不可用','File unavailable')) : t(native ? '正在检查文件…' : '浏览器无法验证本地路径',native ? 'Checking file…' : 'Local paths cannot be checked in the preview')}</small></div>${button('file-open', t('打开'), '', 'subtle', `data-id="${escape(f.id)}"`)}${button('file-copy', t('复制文件'), '', 'text-button', `data-id="${escape(f.id)}"`)}${button('file-drag', t('拖出文件'), '', 'text-button', `data-drag-file="${escape(f.id)}"`)}${button('file-reveal', t('定位'), '', 'text-button', `data-id="${escape(f.id)}"`)}${button('file-remove', '', 'close', 'icon-button', html`aria-label="移除 ${escape(f.name)}" data-id="${escape(f.id)}"${editDisabled()}`)}</article>`; }).join('')}</div><p class="hint">${t(store().files.length ? t('移除文件引用不会删除磁盘原文件。任务历史保留独立文件快照。') : t('文件架还是空的。添加文件后，这里就是你的临时工作台。'))}</p>`;
}
async function refreshFileStatuses(): Promise<void> {
  if (!native) return;
  if (fileStatusBusy) { fileStatusRefreshRequested=true; return; }
  fileStatusRefreshRequested=false;
  fileStatusBusy=true; const revision=++fileStatusRevision;
  try {
    const statuses=await bridge.fileStatuses(store().files.map(file=>file.path));
    if (revision!==fileStatusRevision) return;
    fileStatuses=fileStatusMap(statuses); fileStatusError='';
  } catch (error) { if (revision===fileStatusRevision) fileStatusError=String(error); }
  finally {
    fileStatusBusy=false;
    if (view==='files' && !fileDragging && !composing && !exitGate.pending) render();
    if (fileStatusRefreshRequested) void refreshFileStatuses();
  }
}
function renderSession(session: FlowSession, active: boolean, detail = false): string {
  return html`<article class="session-card ${active ? 'session-active' : ''}"><div class="session-heading"><span class="card-icon green">${icon('flow')}</span><div class="grow"><h2>${escape(session.title)}</h2><small>${active ? html`<span data-elapsed></span> · 进行中` : `${dateTime(session.startedAt)} · ${Math.max(1, Math.round((+new Date(session.endedAt!) - +new Date(session.startedAt)) / 60000))}${t(' 分钟', ' min')}`}</small></div>${active ? button('flow-end', t('结束任务'), 'check', 'subtle', editDisabled()) : button('flow-resume', t('再次开始'), '', 'text-button', `data-id="${escape(session.id)}"${editDisabled()}`)}</div>
    ${!active ? html`<div class="session-times"><small>${t('开始：','Started: ')}${new Date(session.startedAt).toLocaleString(locale())}</small><small>${t('结束：','Ended: ')}${new Date(session.endedAt!).toLocaleString(locale())}</small></div>${detail ? '' : button('flow-history-detail',t('查看详情','View details'),'arrow','text-button',`data-id="${escape(session.id)}"`)}${button('flow-history-delete',t('删除任务记录','Delete task record'),'','text-button danger',`data-id="${escape(session.id)}"${editDisabled()}`)}` : ''}
    ${session.scheduledEndAt ? html`<p class="hint">计划结束 ${dateTime(session.scheduledEndAt)}</p>` : ''}
    <div class="session-links">${session.linkedNote ? button('flow-note-open', escape(session.linkedNote.title), 'notes', 'attachment', `data-id="${escape(session.id)}"`, true) : ''}${session.linkedFiles.map((f, i) => button('flow-file-open', escape(f.name), 'files', 'attachment', `data-session="${escape(session.id)}" data-index="${i}"`, true)).join('')}</div>
    ${active ? html`<div class="session-actions">${button('flow-note', session.linkedNote ? t('打开任务笔记') : t('创建任务笔记'), 'notes', 'text-button', editDisabled())}${button('flow-files', t('关联文件架'), 'link', 'text-button', editDisabled())}</div>` : ''}</article>`;
}
function renderStartForm(compact = false): string {
  return html`<form id="flow-start-form" class="start-flow ${compact ? 'compact-start' : ''}">${compact ? '' : html`<span class="focus-symbol">${icon('flow')}</span>`}<label for="flow-title">现在，想专注什么？</label><div><input id="flow-title" placeholder="例如：完成项目方案" value="${escape(flowDraft)}" maxlength="200"${editDisabled()}><button type="submit" class="primary"${editDisabled()}>开始专注</button></div>${compact ? '' : html`<p>从日历启动，或在这里开始一个新任务。</p>`}</form>`;
}
function renderRecentHistory(): string {
  if (!store().settings.showHistory) return '';
  const items = historyPage(store().history,0,store().settings.historyLimit).items;
  return html`<div class="overview-heading history-label"><h3>${t('最近任务','Recent tasks')}</h3>${button('flow-history',t('全部历史','All history'),'arrow','text-button')}</div>${items.length ? items.map(session=>renderSession(session,false)).join('') : html`<p class="hint">完成的任务会留在这里，笔记和文件关联也会一起保存。</p>`}`;
}
function renderFlow(): string {
  const title = html`<div class="section-heading"><div><span class="eyebrow">NOOKFLOW</span><h1>${selectedHistory ? t('任务详情','Task details') : allHistory ? t('全部历史','All history') : t('让思路停留在任务里')}</h1></div><span class="count-label">${store().history.length}${t(' 次完成',' completed')}</span></div>`;
  if (selectedHistory) {
    const session = store().history.find(item=>item.id===selectedHistory);
    return title + button('flow-history-back',t('返回任务列表','Back to tasks'),'','text-button') + (session ? renderSession(session,false,true) : html`<p class="hint">${t('任务记录不存在')}</p>`);
  }
  if (allHistory) {
    const page = historyPage(store().history,historyPageIndex,20); historyPageIndex = page.page;
    return title + button('flow-history-close',t('返回当前任务','Back to current task'),'','text-button') + html`<div class="history-pages">${button('history-page:-1',t('上一页','Previous page'),'','subtle',page.page===0 ? 'disabled' : '')}<span>${page.page+1} / ${page.pageCount}</span>${button('history-page:1',t('下一页','Next page'),'','subtle',page.page+1>=page.pageCount ? 'disabled' : '')}</div>${page.items.length ? page.items.map(session=>renderSession(session,false)).join('') : html`<p class="hint">${t('还没有完成的任务','No completed tasks yet')}</p>`}`;
  }
  return title + (store().activeSession ? renderSession(store().activeSession!,true) : renderStartForm()) + (store().settings.showHistory ? renderRecentHistory() : button('flow-history',t('全部历史','All history'),'arrow','text-button'));
}
function renderSettings(): string {
  return settingsView(store().settings, sharedPreferences, gifs, updateStatus, storage.blocked, sharedReady, lastBackupPath);
}

function calendarRange(): { from: Date; to: Date } {
  const grid=visibleDates(month), selected=new Date(`${selectedDay}T00:00:00`), selectedEnd=new Date(selected);
  selectedEnd.setDate(selectedEnd.getDate()+1);
  const gridEnd=new Date(grid[grid.length-1]); gridEnd.setDate(gridEnd.getDate()+1);
  return { from: new Date(Math.min(+grid[0], +selected, Date.now() - 86400000)),
    to: new Date(Math.max(+gridEnd, +selectedEnd, Date.now() + 90 * 86400000)) };
}
const calendarSnapshot = (): CalendarSource[] => store().calendars.map(source => ({ ...source }));
function calendarSourcesCurrent(snapshot: readonly CalendarSource[]): boolean {
  return snapshot.length === store().calendars.length && snapshot.every((source, index) => {
    const current = store().calendars[index];
    return current.id === source.id && current.path === source.path && current.content === source.content
      && current.name === source.name && current.importedAt === source.importedAt;
  });
}
async function refreshEvents(): Promise<boolean> {
  const generation = ++calendarGeneration, currentStore = store(), sources = calendarSnapshot();
  calendarController?.abort(); calendarController = new AbortController();
  const controller = calendarController, { from, to } = calendarRange();
  events = []; calendarWarnings = []; calendarErrors = [];
  const current = (): boolean => generation === calendarGeneration && store() === currentStore && calendarSourcesCurrent(sources);
  if (!sources.length) return true;
  try {
    const result = await calendarClient.expand(sources, from, to, controller.signal);
    if (!current()) return false;
    events = result.events; calendarWarnings = result.warnings; calendarErrors = result.errors;
  } catch (error) {
    if (!current() || controller.signal.aborted) return false;
    calendarErrors = [error instanceof Error ? error.message : String(error)];
  } finally { if (calendarController === controller) calendarController = null; }
  return true;
}
async function importCalendar(file: CalendarFile): Promise<void> {
  ensureEditing();
  const generation = ++calendarImportGeneration, currentStore = store(), before = calendarSnapshot();
  calendarImportController?.abort(); calendarImportController = new AbortController();
  const controller = calendarImportController;
  const existing = before.find(c => c.path.toLocaleLowerCase() === file.path.toLocaleLowerCase());
  const source = { ...file, id: existing?.id || crypto.randomUUID(), importedAt: new Date().toISOString() };
  const candidates = existing ? before.map(item => item.id === existing.id ? source : item) : [...before, source];
  try {
    const { from, to } = calendarRange();
    const result = await calendarClient.expand(candidates, from, to, controller.signal);
    if (generation !== calendarImportGeneration || store() !== currentStore || !calendarSourcesCurrent(before)) return;
    ensureEditing();
    if (storage.blocked) throw new Error(t('存储受保护'));
    if (result.errors.length) throw new Error(result.errors.join('\n'));
    storage.mutate(candidate => { candidate.calendars = candidates; });
    refreshScheduler.cancel();
    void refreshCalendarView();
    if (view === 'calendar' || view === 'overview') render();
    await persist(); toast(t('日历已导入'));
  } catch (error) { if (!controller.signal.aborted) throw error; }
  finally { if (calendarImportController === controller) calendarImportController = null; }
}
async function selectView(next: View): Promise<void> {
  view = next; expanded = true; expandedByHover = false; panelActionAt = Date.now();
  if (view === 'notes' && !selectedNote) selectedNote = searchNotes(store().notes, '')[0]?.id || null;
  if (view === 'calendar') void refreshCalendarView();
  render(); await resizeWindow(); await bridge.focus();
  if (view === 'settings') { void refreshGifs(); void refreshSharedPreferences(); }
  if (view === 'files') void refreshFileStatuses();
}
async function switchIsland(): Promise<void> {
  if (switching) return;
  switching = true;
  for (const b of document.querySelectorAll<HTMLButtonElement>('[data-action="switch"]')) b.disabled = true;
  try { if (!storage.blocked) { if (saveTimer) await persist(); await storage.flush(); } await bridge.switch(); }
  finally { switching = false; for (const b of document.querySelectorAll<HTMLButtonElement>('[data-action="switch"]')) b.disabled = false; await refreshPeer(); }
}
async function refreshPeer(): Promise<void> {
  try { peer = await bridge.peer(); } catch (error) { peer = { installed: false, running: false, compatible: false, detail: String(error) }; }
  for (const b of document.querySelectorAll<HTMLElement>('[data-action="switch"]')) b.title = peer.detail;
  const target = document.querySelector('#peer-detail'); if (target) target.textContent = peer.detail;
}
const displayNoteTitle = (note: Pick<Note, 'title' | 'content'>): string => note.title.trim() || note.content.trim() ? noteTitle(note) : t('未命名笔记');
const currentNote = (): Note | undefined => store().notes.find(n => n.id === selectedNote);
function sessionById(id?: string): FlowSession | undefined { return store().activeSession?.id === id ? store().activeSession! : store().history.find(s => s.id === id); }
async function openSessionNote(session: FlowSession): Promise<void> {
  if (!session.linkedNote) return;
  const existing = store().notes.some(note=>note.id===session.linkedNote!.id);
  if (!existing && storage.blocked) throw new Error(t('存储受保护，暂时无法恢复笔记快照'));
  selectedNote = existing ? openLinkedNote(store(), session.id).id : storage.mutate(candidate => openLinkedNote(candidate,session.id)).id;
  if (!existing) { await persist(); toast(t('已从任务快照恢复一份笔记')); }
  await selectView('notes');
}
async function action(name: string, element: HTMLElement): Promise<void> {
  ensureEditing();
  panelActionAt = Date.now();
  if (name === 'confirm-action') { const confirmed = confirmationAction; closeConfirmation(); if (confirmed) await confirmed(); return; }
  if (name === 'cancel-action') { closeConfirmation(); return; }
  if (name === 'safe-exit') { await beginExit(); return; }
  if (name === 'files-refresh') { await refreshFileStatuses(); return; }
  if (name === 'flow-history') { allHistory=true; historyPageIndex=0; selectedHistory=null; await selectView('flow'); return; }
  if (name === 'flow-history-close') { allHistory=false; selectedHistory=null; render(); return; }
  if (name === 'flow-history-back') { selectedHistory=null; render(); return; }
  if (name === 'flow-history-detail') { selectedHistory=element.dataset.id || null; await selectView('flow'); return; }
  if (name.startsWith('history-page:')) { historyPageIndex+=Number(name.slice(13)); render(); document.querySelector('#content')?.scrollTo(0,0); return; }
  if (name === 'overview-note') { selectedNote=element.dataset.id || null; search=''; await selectView('notes'); return; }
  if (name.startsWith('overview-day:')) { selectedDay=name.slice(13); const date=new Date(`${selectedDay}T12:00:00`); month=new Date(date.getFullYear(),date.getMonth(),1); void refreshCalendarView(); render(); return; }
  if (name === 'store-reload') {
    if (!storage.blocked && saveTimer) await persist();
    if (!storage.blocked && storage.state.kind === 'error') throw new Error(t('请先保存当前草稿，再重新读取','Save the current draft before reloading'));
    await preferenceQueue; await storage.flush().catch(error => { if (!storage.blocked) throw error; });
    await storage.load(); selectedNote = null; refreshScheduler.cancel(); fileStatuses.clear(); fileStatusRevision++;
    mediaSelection.select(store().settings.preferredMediaSourceId); media = mediaSelection.snapshot;
    lyricController.cancel(); mediaKey = ''; lyrics = null;
    void refreshCalendarView(); render(); await applyAllPreferences(); await pollMedia(); return;
  }
  if (name === 'store-backup') {
    if (!lastBackupPath) return;
    if (native) await bridge.reveal(lastBackupPath);
    else toast(`${t('备份保存在此浏览器的隔离存储中：','The backup is in this browser’s isolated local storage: ')}${lastBackupPath}`);
    return;
  }
  if (name === 'store-recover') {
    await confirmAction(t('确认备份并恢复为空数据？'), t('将先备份原始数据，再创建空数据。原文件不会被直接覆盖。'), async () => {
      await preferenceQueue;
      if (!storage.blocked) { await persist(); await storage.flush(); }
      const result = await bridge.recover(JSON.stringify(emptyStore()));
      lastBackupPath = result.backupPath;
      clearTimeout(saveTimer); saveTimer = undefined; await storage.load(); selectedNote = null; deleted = null; flowDraft = ''; fileStatuses.clear(); fileStatusRevision++;
      refreshScheduler.cancel(); mediaSelection.select(store().settings.preferredMediaSourceId); media = mediaSelection.snapshot;
      lyricController.cancel(); mediaKey = ''; lyrics = null;
      void refreshCalendarView(); render(); await applyAllPreferences(); toast(`${t('原件备份位置：','Original backup: ')}${result.backupPath}`);
    }); return;
  }
  if (name === 'updates-check') { updateStatus = await bridge.updates(true); if (view === 'settings') render(); return; }
  if (name === 'updates-open') { await bridge.openUpdate(); return; }
  if (name === 'calendar-default') { await bridge.openCalendar(); return; }
  if (name === 'calendar-open') { const source = store().calendars.find(c => c.id === element.dataset.id); if (source) await bridge.openCalendar(source.path); return; }
  if (name === 'reminder-test') { await bridge.reminder(store().settings.reminderSound); return; }
  if (name === 'media-open') {
    if (!media.available || element.dataset.sourceId !== media.sourceId || element.dataset.sessionToken !== media.sessionToken || !media.sessionToken) throw new Error(t('播放器会话已变化，请重试','The player session changed. Try again.'));
    await bridge.openPlayer(element.dataset.sourceId!, element.dataset.sessionToken!); return;
  }
  if (name === 'file-copy') { const file = store().files.find(f => f.id === element.dataset.id); if (file) { await bridge.copyFiles([file.path]); toast(t('文件已复制到剪贴板','File copied to clipboard')); } return; }
  if (name === 'file-drag') return;
  if (name === 'exit-continue') { await cancelExit(); return; }
  if (name === 'exit-retry') { await bridge.cancelExit(); await beginExit(); return; }
  if (name === 'exit-discard-confirm') { await bridge.cancelExit(); await beginExit(true); return; }
  if (name === 'exit-discard') {
    const dialog = document.querySelector<HTMLDialogElement>('#exit-dialog');
    if (dialog) dialog.innerHTML = html`<h2>确认放弃未保存的修改？</h2><p>这次未能保存的内容会丢失，磁盘中已保存的原件不会被删除。</p><div>${button('exit-continue', t('继续编辑'), '', 'subtle')}${button('exit-discard-confirm', t('确认不保存并退出'), '', 'subtle danger')}</div>`;
    return;
  }
  if (name.startsWith('view:')) { await selectView(name.slice(5) as View); return; }
  if (name === 'expand' || name === 'collapse') { await transitionPanel(name === 'expand'); return; }
  if (name === 'switch') { await switchIsland(); return; }
  if (name === 'retry-save') { await persist(); return; }
  if (name === 'media-auto') { await selectMediaSource(null); return; }
  if (name.startsWith('media:')) { if (await mediaSelection.control(element.dataset.sourceId || '', element.dataset.sessionToken || '', name.slice(6) as MediaAction)) await pollMedia(); return; }
  if (name.startsWith('month:')) { month.setMonth(month.getMonth() + Number(name.slice(6))); void refreshCalendarView(); render(); return; }
  if (name.startsWith('day:')) { selectedDay = name.slice(4); render(); return; }
  if (name === 'calendar-today') { month = new Date(new Date().getFullYear(), new Date().getMonth(), 1); selectedDay = dayKey(new Date()); void refreshCalendarView(); render(); return; }
  if (name === 'note-select') { selectedNote = element.dataset.id!; render(); return; }
  if (name.startsWith('note-export-')) { const n = currentNote(); if (n) await nativePicker(() => bridge.export(noteTitle(n), n.content, name.endsWith('md') ? 'md' : 'txt')); return; }
  if (name === 'file-open' || name === 'file-reveal') { const f = store().files.find(f => f.id === element.dataset.id); if (f) await (name === 'file-open' ? bridge.open(f.path) : bridge.reveal(f.path)); return; }
  if (name === 'flow-file-open') { const f = sessionById(element.dataset.session)?.linkedFiles[Number(element.dataset.index)]; if (f) await bridge.open(f.path); return; }
  if (name === 'flow-note-open') { const s = sessionById(element.dataset.id); if (s) await openSessionNote(s); return; }
  if (storage.blocked) throw new Error(t('原始数据受到保护，修复后才能编辑'));
  if (name === 'flow-history-delete') {
    const id = element.dataset.id, session = store().history.find(item => item.id === id); if (!session) return;
    await confirmAction(t('删除任务记录？','Delete task record?'), t(`将删除「${session.title}」的任务记录和快照。源笔记和磁盘文件会保留。`, `Delete the record and snapshots for “${session.title}”? Source notes and files will remain.`), async () => {
      storage.mutate(candidate => { candidate.history = candidate.history.filter(item => item.id !== id); }, true);
      if (selectedHistory === id) selectedHistory = null;
      render(); await persist();
    }); return;
  }
  if (name === 'gif-import') {
    nativeDialog = true;
    try { const gif = await bridge.importGif(); ensureEditing(); if (gif) { await setPreference('selectedGifId', gif.id); await refreshGifs(); if (view === 'settings') render(); } }
    finally { nativeDialog = false; } return;
  }
  if (name === 'gif-delete') {
    const id = store().settings.selectedGifId; if (!id) return;
    await confirmAction(t('删除所选 GIF？','Delete selected GIF?'), t('只删除 XNook 保存的副本，不删除导入来源。','Only the XNook copy is removed; the original remains.'), async () => {
      await bridge.deleteGif(id); await setPreference('selectedGifId', null); await refreshGifs(); if (view === 'settings') render();
    }); return;
  }
  if (name === 'calendar-import') {
    if (native) { const file = await nativePicker(bridge.calendar); if (file) await importCalendar(file); }
    else document.querySelector<HTMLInputElement>('#ics-input')?.click();
    return;
  }
  if (name === 'calendar-refresh') {
    const c = store().calendars.find(c => c.id === element.dataset.id), currentStore = store(), before = calendarSnapshot();
    if (c) { const file = await bridge.refreshCalendar(c.path); if (store() === currentStore && calendarSourcesCurrent(before)) await importCalendar(file); }
    return;
  }
  if (name === 'calendar-remove') { storage.mutate(candidate => { candidate.calendars = candidate.calendars.filter(c => c.id !== element.dataset.id); }, true); refreshEvents(); }
  else if (name === 'note-new') { const n = newNote(); storage.mutate(candidate => { candidate.notes.push(n); }); selectedNote = n.id; view = 'notes'; search = ''; }
  else if (name === 'note-delete') { deleted = storage.mutate(candidate => deleteNote(candidate, selectedNote!), true); selectedNote = searchNotes(store().notes, search)[0]?.id || null; }
  else if (name === 'note-undo') { if (deleted) { storage.mutate(candidate => undoDeleteNote(candidate, deleted!)); selectedNote = deleted.id; deleted = null; } }
  else if (name === 'note-link') { const n = currentNote(); if (n) { storage.mutate(candidate => linkNote(candidate, n)); toast(t('已关联到当前任务')); } }
  else if (name === 'files-add') { const files = await nativePicker(bridge.files); if (!files) return; ensureEditing(); storage.mutate(candidate => addFiles(candidate, files)); }
  else if (name === 'file-remove') storage.mutate(candidate => { candidate.files = candidate.files.filter(f => f.id !== element.dataset.id); }, true);
  else if (name === 'event-flow') { const e = events.find(e => e.id === element.dataset.id); if (e) { storage.mutate(candidate => startSession(candidate, e.title, e.id, e.end)); allHistory=false; selectedHistory=null; view = 'flow'; } }
  else if (name === 'flow-end') storage.mutate(candidate => endSession(candidate));
  else if (name === 'flow-resume') { storage.mutate(candidate => resumeSession(candidate, element.dataset.id!)); allHistory=false; selectedHistory=null; }
  else if (name === 'flow-files') { storage.mutate(candidate => linkFiles(candidate)); toast(t('文件架已关联到当前任务')); }
  else if (name === 'flow-note') {
    const active = store().activeSession!;
    if (active.linkedNote) { await openSessionNote(active); return; }
    const n = newNote(active.title); storage.mutate(candidate => { candidate.notes.push(n); linkNote(candidate, n); }); selectedNote = n.id; view = 'notes';
  } else return;
  render(); await persist();
  if (name==='files-add' || name==='file-remove') void refreshFileStatuses();
  if (name === 'note-new' || name === 'flow-note') document.querySelector<HTMLInputElement>('#note-title')?.focus();
}
root.addEventListener('click', event => {
  if (pillGesture.consumeClick()) { event.preventDefault(); event.stopPropagation(); return; }
  panelActionAt = Date.now(); collapsePolicy.reset();
  const target = (event.target as HTMLElement).closest<HTMLElement>('[data-action]');
  closeContextMenu(!target);
  if (target) void perform(() => action(target.dataset.action!, target));
});
function closeContextMenu(resize = true): void {
  if (!contextMenuOpen) return;
  contextMenuOpen=false; document.querySelector('#pill-menu')?.remove();
  if (resize) void perform(resizeWindow);
}
root.addEventListener('contextmenu',event=>{
  if (expanded || !(event.target as HTMLElement).closest('.pill,.pill-ticker')) return;
  event.preventDefault();
  void perform(async()=>{
    closeContextMenu(false); contextMenuOpen=true; await resizeWindow(); await bridge.focus();
    if (!contextMenuOpen || expanded) return;
    const menu=document.createElement('div'); menu.id='pill-menu'; menu.setAttribute('role','menu'); menu.setAttribute('aria-label',t('XNook 菜单','XNook menu'));
    menu.style.top=`${windowSize(store().settings,false,tickerVisible()).height}px`;
    menu.innerHTML=button('view:settings',t('设置'),'settings','text-button','role="menuitem"')+button('safe-exit',t('退出 XNook','Quit XNook'),'close','text-button','role="menuitem"');
    root.append(menu); menu.querySelector<HTMLButtonElement>('button')?.focus();
  });
});
document.addEventListener('keydown',event=>{ if (contextMenuOpen && event.key==='Escape') { event.preventDefault(); closeContextMenu(); } },true);
window.addEventListener('blur',()=>closeContextMenu());
let pillDragQueue=Promise.resolve(), pillUpdateQueued=false;
function applyPillGesture(action: ReturnType<PillGesture['move']> | ReturnType<PillGesture['end']>): void {
  if (action==='expand') { void perform(()=>transitionPanel(true)); return; }
  if (action==='none') return;
  if (action==='dragUpdate' && pillUpdateQueued) return;
  if (action==='dragUpdate') pillUpdateQueued=true;
  const phase=action==='dragBegin' ? 'begin' : action==='dragEnd' ? 'end' : 'update';
  const next=pillDragQueue.then(()=>bridge.drag(phase));
  pillDragQueue=next.then(()=>{},error=>{ toast(String(error)); }).finally(()=>{ if(action==='dragUpdate') pillUpdateQueued=false; });
}
root.addEventListener('pointerdown',event=>{
  const target=event.target as HTMLElement;
  const eligible=!expanded && event.button===0 && !!target.closest('.pill-open,.pill-copy,.pill-ticker') && !target.closest('.pill-art,.pill-switch') && !contextMenuOpen;
  if (pillGesture.begin(event.pointerId,event.clientX,event.clientY,eligible)) (event.target as Element).setPointerCapture(event.pointerId);
});
root.addEventListener('pointermove',event=>{
  const action=pillGesture.move(event.pointerId,event.clientX,event.clientY);
  if (action!=='none') event.preventDefault();
  applyPillGesture(action);
});
root.addEventListener('pointerup',event=>{
  applyPillGesture(pillGesture.end(event.pointerId));
  if ((event.target as Element).hasPointerCapture(event.pointerId)) (event.target as Element).releasePointerCapture(event.pointerId);
});
root.addEventListener('pointercancel',event=>applyPillGesture(pillGesture.cancel(event.pointerId)));
root.addEventListener('lostpointercapture',event=>applyPillGesture(pillGesture.cancel(event.pointerId)));
root.addEventListener('submit', event => {
  if ((event.target as HTMLElement).id !== 'flow-start-form') return;
  event.preventDefault();
  void perform(async () => { ensureEditing(); if (storage.blocked) throw new Error(t('存储受保护')); const title = document.querySelector<HTMLInputElement>('#flow-title')!.value; storage.mutate(candidate => startSession(candidate, title.trim() || t('未命名任务','Untitled task'))); flowDraft = ''; render(); await persist(); });
});
root.addEventListener('compositionstart', () => { composing = true; });
root.addEventListener('compositionend', event => { composing = false; updateEditor(event.target as HTMLInputElement); });
function updateEditor(target: HTMLInputElement | HTMLTextAreaElement): void {
  if (storage.blocked || exitGate.pending) return;
  if (target.id === 'flow-title') { flowDraft = target.value; return; }
  if (target.id === 'note-search') {
    search = target.value;
    const list = document.querySelector('#note-list'); if (list) list.innerHTML = renderNoteList(searchNotes(store().notes, search));
    return;
  }
  const note = currentNote();
  if (!note || !['note-title', 'note-content'].includes(target.id)) return;
  if (target.id === 'note-title') note.title = target.value; else note.content = target.value;
  note.updatedAt = new Date().toISOString(); refreshLinkedNote(store(), note);
  if (composing) return;
  scheduleSave();
  const length = document.querySelector('#note-length'); if (length) length.textContent = `${note.content.length}${t(' 字', ' characters')}`;
  const list = document.querySelector('#note-list'); if (list) list.innerHTML = renderNoteList(searchNotes(store().notes, search));
}
root.addEventListener('input', event => { panelActionAt = Date.now(); collapsePolicy.reset(); updateEditor(event.target as HTMLInputElement); });
root.addEventListener('pointerenter', () => {
  pointerInside = true; hoverEnteredAt = Date.now(); collapsePolicy.reset();
  if (!expanded && !reduceMotion() && store().settings.jellyIntensity !== 'off') { root.classList.remove('jelly'); requestAnimationFrame(() => root.classList.add('jelly')); }
});
root.addEventListener('pointerleave', () => { pointerInside = false; root.style.setProperty('--magnetic-x','0px'); root.classList.remove('jelly'); });
root.addEventListener('pointermove', event => {
  if (expanded || reduceMotion() || !store().settings.magnetic) return;
  const rect = root.getBoundingClientRect(), island = root.querySelector<HTMLElement>('.island');
  if (!island) return;
  const width = Number.parseFloat(getComputedStyle(island).width);
  root.style.setProperty('--magnetic-x', `${magneticOffset(event.clientX - rect.left - rect.width / 2, rect.width, width)}px`);
});
root.addEventListener('pointerdown', event => {
  const target = (event.target as HTMLElement).closest<HTMLElement>('[data-drag-file]');
  if (!target || event.button !== 0 || exitGate.pending) return;
  event.preventDefault();
  const file = store().files.find(file => file.id === target.dataset.dragFile); if (!file) return;
  fileDragging = true;
  void perform(async () => { try { await bridge.dragFiles([file.path]); } finally { fileDragging = false; panelActionAt = Date.now(); } });
});
root.addEventListener('change', event => {
  const target = event.target as HTMLInputElement;
  void perform(async () => {
    ensureEditing();
    panelActionAt = Date.now();
    if (target.dataset.pref) { await setPreference(target.dataset.pref as keyof Settings, target.type === 'checkbox' ? target.checked : target.type === 'number' ? Number(target.value) : target.dataset.pref === 'selectedGifId' ? target.value || null : target.value); return; }
    if (target.dataset.widget) {
      const widgets = store().settings.enabledWidgets.filter(id => id !== target.dataset.widget);
      if (target.checked) widgets.push(target.dataset.widget as WidgetId);
      await setPreference('enabledWidgets', widgetIds.filter(id => widgets.includes(id))); render(); return;
    }
    if (target.dataset.shared) {
      if (!sharedReady) throw new Error(t('联动配置尚未读取','Shared preferences have not loaded'));
      const key = target.dataset.shared as keyof IslandPreferences, value = target.type === 'checkbox' ? target.checked : target.value;
      sharedRevision++; sharedPending++; updateSharedControls();
      const attempt = sharedPreferenceQueue.then(async () => {
        try { sharedPreferences = await bridge.setIslandPreferences({ ...sharedPreferences, [key]: value }); }
        finally { sharedPending--; updateSharedControls(); }
      });
      sharedPreferenceQueue = attempt.catch(() => {});
      try { await attempt; } catch (error) { await refreshSharedPreferences(); throw error; }
      return;
    }
    if (target.id === 'ics-input' && target.files?.[0]) {
      const file = target.files[0]; if (file.size > 5 * 1024 * 1024) throw new Error(t('日历文件超过 5 MiB'));
      await importCalendar({ name: file.name, path: `browser-preview:${file.name}`, content: await file.text() });
    }
    if (target.id === 'media-source-select') await selectMediaSource(target.value || null);
    if (target.id === 'compact-nav' && [...visibleWidgets(),view].includes(target.value as View)) await selectView(target.value as View);
    if (target.id === 'media-seek') { if (await mediaSelection.control(target.dataset.sourceId || '', target.dataset.sessionToken || '', 'seek', Number(target.value))) await pollMedia(); }
  });
});
root.addEventListener('focusin', event => {
  if ((event.target as HTMLElement).matches('input, textarea, select, [contenteditable]')) void perform(bridge.focus);
});
root.addEventListener('focusout', event => {
  const id = (event.target as HTMLElement).id;
  if (id === 'media-source-select' || id === 'media-seek') setTimeout(() => {
    if (mediaSelectorDirty) updateSourcePicker();
    if (mediaContentDirty) updateMediaPanel();
  }, 0);
});
root.addEventListener('pointerdown', event => { panelActionAt = Date.now(); collapsePolicy.reset(); if ((event.target as HTMLElement).id === 'media-seek') seeking = true; });
root.addEventListener('pointerup', () => { seeking = false; });
root.addEventListener('pointercancel', () => { seeking = false; });
let wheelDistance = 0, wheelAt = 0, wheelCooldown = 0;
root.addEventListener('wheel', event => {
  const target = event.target as HTMLElement;
  if (protectedInteraction() || target.closest('input, textarea, select, [contenteditable], .note-editor')) return;
  const now = Date.now(); if (now < wheelCooldown) return;
  if (Math.abs(event.deltaY) > Math.abs(event.deltaX) && store().settings.scrollExpand) {
    if (!expanded && event.deltaY > 6) { event.preventDefault(); wheelCooldown = now + 700; void perform(() => transitionPanel(true)); }
    else if (expanded && event.deltaY < -12) {
      let scrolled = false; for (let node: HTMLElement | null = target; node && node !== root; node = node.parentElement) if (node.scrollTop > 1) scrolled = true;
      if (!scrolled) { event.preventDefault(); wheelCooldown = now + 700; void perform(() => transitionPanel(false)); }
    }
    return;
  }
  if (expanded || !sharedReady || !sharedPreferences.swipeEnabled || Math.abs(event.deltaX) <= Math.abs(event.deltaY) || Math.abs(event.deltaX) < 2) return;
  if (now - wheelAt > 250) wheelDistance = 0;
  wheelAt = now; wheelDistance += event.deltaX;
  if (Math.abs(wheelDistance) > {low:120,medium:80,high:45}[sharedPreferences.sensitivity]) { event.preventDefault(); wheelCooldown = now + 1800; wheelDistance = 0; void perform(switchIsland); }
}, { passive: false });
document.addEventListener('keydown', event => {
  if (exitGate.pending) return;
  panelActionAt = Date.now(); collapsePolicy.reset();
  if ((event.target as HTMLElement).closest('dialog')) return;
  const shortcut = panelShortcut({ ...event, key: event.key, ctrlKey: event.ctrlKey, metaKey: event.metaKey,
    altKey: event.altKey, shiftKey: event.shiftKey, repeat: event.repeat, isComposing: event.isComposing || composing }, expanded);
  if (!shortcut) return;
  event.preventDefault();
  if (shortcut === 'escape') void perform(() => { if (view==='flow' && selectedHistory) { selectedHistory=null; render(); } else if (view==='flow' && allHistory) { allHistory=false; render(); } else return view === 'overview' ? action('collapse', root) : selectView('overview'); });
  else if (shortcut === 'save') { if (!storage.blocked) void perform(persist); }
  else if (shortcut === 'new-note') void perform(() => action('note-new', root));
  else if (visibleWidgets().includes(shortcut)) void perform(() => selectView(shortcut));
});
let dragging = false, dragPending = false;
root.addEventListener('pointerdown', event => { if ((event.target as HTMLElement).id === 'drag-handle' && event.button === 0) { dragging = true; (event.target as HTMLElement).setPointerCapture(event.pointerId); void perform(() => bridge.drag('begin')); } });
root.addEventListener('pointermove', () => { if (dragging && !dragPending) { dragPending = true; void bridge.drag('update').catch(error => toast(String(error))).finally(() => { dragPending = false; }); } });
function endDrag(): void { if (dragging) { dragging = false; void perform(() => bridge.drag('end')); } }
root.addEventListener('pointerup', endDrag); root.addEventListener('pointercancel', endDrag);
async function selectMediaSource(preferredSourceId: string | null): Promise<void> {
  ensureEditing();
  if (storage.blocked) throw new Error(t('存储受保护，暂时不能保存播放器选择'));
  const attempt = preferenceQueue.then(async () => {
    storage.mutate(candidate => { candidate.settings.preferredMediaSourceId = preferredSourceId; });
    mediaSelection.select(preferredSourceId);
    media = mediaSelection.snapshot;
    mediaKey = ''; lyricController.cancel(); lyrics = null; lyricStatus = '';
    updateMediaPanel(true); updateMediaOverview();
    const saving = persist();
    void pollMedia();
    await saving;
  });
  preferenceQueue = attempt.catch(() => {});
  await attempt;
}
async function pollMedia(): Promise<void> {
    const previous = media, previousTicker=tickerVisible(), next = await mediaSelection.poll();
    if (!next) return;
    media = next;
    const generation = mediaSelection.generation;
    const nextKey = next.available ? trackKey(next) : '';
    const trackChanged = nextKey !== mediaKey;
    const sessionChanged = previous.sessionToken !== next.sessionToken;
    if (trackChanged || sessionChanged) {
      mediaKey = nextKey; lyricController.cancel(); lyrics = null; lyricStatus = '';
      if (next.available && store().settings.lyricsEnabled) {
        lyricStatus = t('正在寻找歌词…');
        const onError = (error: unknown): void => {
          if (mediaSelection.generation === generation && mediaKey === nextKey) { lyricStatus = `${t('歌词暂不可用：', 'Lyrics unavailable: ')}${String(error)}`; updateLyrics(); }
        };
        void lyricController.load(next, value => {
          if (mediaSelection.generation !== generation || mediaKey !== nextKey) return;
          lyrics = value; lyricStatus = value ? '' : t('没有找到可靠匹配的歌词'); updateLyrics();
        }, onError).catch(onError);
      }
    }
    updateSourcePicker();
    if (trackChanged || sessionChanged || previous.playing !== next.playing || previous.available !== next.available
      || previous.canSeek !== next.canSeek || previous.canPlayPause !== next.canPlayPause
      || previous.canNext !== next.canNext || previous.canPrevious !== next.canPrevious
      || (previous.position === null) !== (next.position === null) || previous.artwork !== next.artwork
      || previous.duration !== next.duration || previous.error !== next.error) updateMediaPanel(trackChanged || sessionChanged || previous.sourceId !== next.sourceId || (previous.available && !next.available));
    updateMediaOverview();
    if (previous.available !== next.available || previous.playing !== next.playing || previous.artwork !== next.artwork || sessionChanged) {
      updatePillDecorations();
      if (!expanded && previousTicker !== tickerVisible()) await resizeWindow();
    }
}
function updateMediaOverview(): void {
  const track = document.querySelector('#overview-track'); if (track) track.textContent = media.available ? media.title : t('等待音乐响起');
  const artist = document.querySelector('#overview-artist'); if (artist) artist.textContent = media.available ? media.artist : t('连接 Windows 系统媒体会话');
  const pill = document.querySelector('#pill-detail'); if (pill) pill.textContent = store().activeSession?.title || (media.available ? media.title : t('留一点空间给自己'));
  root.dataset.playing=String(media.available && media.playing);
  const controls=document.querySelector<HTMLElement>('#overview-media-controls');
  if (controls) {
    const signature=JSON.stringify([media.sourceId,media.sessionToken,media.available,media.playing,media.canPrevious,media.canNext,media.canPlayPause]);
    if (controls.dataset.signature!==signature) {
      const focused=controls.contains(document.activeElement) ? (document.activeElement as HTMLElement).dataset.action : null;
      controls.innerHTML=renderOverviewMediaControls(); controls.dataset.signature=signature;
      if (focused) [...controls.querySelectorAll<HTMLElement>('[data-action]')].find(button=>button.dataset.action===focused)?.focus({preventScroll:true});
    }
  }
}
function updateSourcePicker(): void {
  const select = document.querySelector<HTMLSelectElement>('#media-source-select');
  const status = document.querySelector('#media-source-status'); if (status) status.textContent = sourceStatus();
  if (!select) return;
  if (document.activeElement === select) { mediaSelectorDirty = true; return; }
  const signature = JSON.stringify([mediaSelection.preferredSourceId, media.playerName, media.sources]);
  if (select.dataset.signature !== signature) { select.innerHTML = renderSourceOptions(); select.dataset.signature = signature; }
  mediaSelectorDirty = false;
}
function updateLyrics(): void {
  const target = document.querySelector('#lyrics'); if (target) target.innerHTML = renderLyrics();
  updateClock();
}
function updateMediaPanel(force = false): void {
  updateSourcePicker();
  const panel = document.querySelector('#media-content');
  if (!panel) return;
  if (!force && (seeking || document.activeElement?.id === 'media-seek')) { mediaContentDirty = true; return; }
  panel.innerHTML = renderMediaContent(); mediaContentDirty = false; updateClock();
}
const tickerLayouts = new WeakMap<HTMLElement, string>();
function updateClock(): void {
  if (document.hidden) return;
  const position = mediaPosition(media);
  const label = document.querySelector('#media-position'), formatted = formatTime(position); if (label && label.textContent !== formatted) label.textContent = formatted;
  const progress = document.querySelector<HTMLInputElement>('#media-seek'); if (progress && document.activeElement !== progress) progress.value = String(position || 0);
  const line = position === null ? -1 : currentLyric(lyrics?.lines || [], position);
  for (const element of document.querySelectorAll<HTMLElement>('[data-lyric]')) {
    const active = Number(element.dataset.lyric) === line;
    if (active && !element.classList.contains('current')) element.scrollIntoView({ behavior: reduceMotion() ? 'instant' : 'smooth', block: 'nearest' });
    element.classList.toggle('current', active);
  }
  for (const element of document.querySelectorAll<HTMLElement>('[data-elapsed]')) {
    if (store().activeSession) { const elapsed = formatTime(Math.max(0, (Date.now() - +new Date(store().activeSession!.startedAt)) / 1000)); if (element.textContent !== elapsed) element.textContent = elapsed; }
  }
  const ticker = document.querySelector<HTMLElement>('#pill-ticker-text');
  if (ticker) {
    const text = activeTicker();
    if (ticker.title !== text) ticker.title=text;
    if (ticker.textContent !== text) { ticker.textContent = text; ticker.style.animation = 'none'; requestAnimationFrame(() => { if (!document.hidden && ticker.isConnected) ticker.style.animation = ''; }); }
    const width = ticker.scrollWidth, viewport = ticker.parentElement?.clientWidth || 0, speed = store().settings.tickerSpeed;
    const layout = JSON.stringify([text, width, viewport, speed, reduceMotion()]);
    if (tickerLayouts.get(ticker) !== layout) {
      tickerLayouts.set(ticker, layout);
      const distance = Math.max(0, width - viewport);
      ticker.style.setProperty('--ticker-distance', `${distance}px`); ticker.style.setProperty('--ticker-duration', `${Math.max(1, distance / speed)}s`);
      ticker.classList.toggle('scrolling', distance > 1 && !reduceMotion());
    }
  }
}
function interactionTick(): void {
  if (document.hidden) return;
  const protectedNow = protectedInteraction(), now = Date.now();
  if (!expanded && pointerInside && store().settings.hoverExpand && now - hoverEnteredAt >= 180 && !protectedNow) { void perform(() => transitionPanel(true, true)); return; }
  const delay = expandedByHover ? Math.max(1,store().settings.hoverExitDelayMs) : store().settings.idleCollapseMs;
  if (collapsePolicy.update(now,pointerInside,expanded,protectedNow,delay) && now - panelActionAt >= delay) void perform(() => transitionPanel(false));
}
function setPreference(key: keyof Settings, value: unknown): Promise<void> {
  ensureEditing(); if (storage.blocked) return Promise.reject(new Error(t('存储受保护')));
  const attempt = preferenceQueue.then(async () => {
    const previous = structuredClone(store().settings);
    const candidate = { ...previous, [key]: value };
    const next = { ...candidate, ...parsePreferences(candidate as unknown as Record<string, unknown>) } as Settings;
    if (key === 'launchAtLogin') next.launchAtLogin = await bridge.setLogin(Boolean(value));
    try { await bridge.preferences(next); }
    catch (error) {
      if (key === 'launchAtLogin') {
        try { await bridge.setLogin(previous.launchAtLogin); }
        catch (rollback) { throw new Error(`${String(error)}; ${t('登录项回滚失败：','Login preference rollback failed: ')}${String(rollback)}`); }
      }
      try { await bridge.preferences(previous); }
      catch (rollback) { throw new Error(`${String(error)}; ${t('窗口设置回滚失败：','Window preference rollback failed: ')}${String(rollback)}`); }
      throw error;
    }
    // 媒体来源和全部设置共用同一队列，原生迟到结果不会覆盖后来选择。
    store().settings = next; applyVisualPreferences();
    if (key === 'lyricsEnabled') { lyricController.cancel(); mediaKey = ''; void pollMedia(); }
    if (key === 'selectedGifId' || key === 'reduceMotion') await loadSelectedGif();
    if (key === 'autoRefreshCalendars' && !next.autoRefreshCalendars) refreshScheduler.cancel();
    if (key === 'autoCheckUpdates' && next.autoCheckUpdates) { nextAutomaticUpdate = 0; void maybeCheckUpdates(); }
    await persist(); await resizeWindow();
    if (key === 'enabledWidgets' && widgetIds.includes(view as WidgetId) && !next.enabledWidgets.includes(view as WidgetId)) view = 'overview';
    if (key === 'language' || key === 'appearance' || key === 'enabledWidgets') render();
    else updateClock();
  });
  preferenceQueue = attempt.catch(() => {});
  return attempt.catch(error => { if (view === 'settings') render(); throw error; });
}
async function applyAllPreferences(): Promise<void> { applyVisualPreferences(); await bridge.preferences(store().settings); await resizeWindow(); await loadSelectedGif(); }
async function refreshGifs(): Promise<void> {
  try { gifs = await bridge.gifs(); }
  catch (error) { toast(String(error)); return; }
  const select = document.querySelector<HTMLSelectElement>('[data-pref="selectedGifId"]');
  if (select && document.activeElement !== select) {
    select.innerHTML = html`<option value="">${t('默认波形','Default waveform')}</option>${gifs.map(gif => html`<option value="${escape(gif.id)}" ${store().settings.selectedGifId === gif.id ? 'selected' : ''}>${escape(gif.name)}</option>`).join('')}`;
  }
}
async function loadSelectedGif(): Promise<void> {
  const generation = ++gifGeneration; gifData = ''; gifStill = '';
  const id = store().settings.selectedGifId;
  if (!id || reduceMotion()) { updatePillDecorations(); return; }
  try {
    const data = await bridge.readGif(id);
    if (generation !== gifGeneration || !data.startsWith('data:image/gif;base64,')) return;
    const image = new Image(); image.src = data; await image.decode();
    if (generation !== gifGeneration || reduceMotion()) return;
    const canvas = document.createElement('canvas'); canvas.width = Math.min(image.naturalWidth, 256); canvas.height = Math.min(image.naturalHeight, 256);
    canvas.getContext('2d')?.drawImage(image, 0, 0, canvas.width, canvas.height);
    gifStill = canvas.toDataURL('image/png'); gifData = data; updatePillDecorations();
  } catch (error) { if (generation === gifGeneration) toast(String(error)); }
}
function updatePillDecorations(): void {
  if (!expanded && mounted && !contextMenuOpen && !pillGesture.active) render();
}
async function refreshSharedPreferences(): Promise<void> {
  if (sharedPending) return;
  const revision = ++sharedRevision;
  try {
    const value = await bridge.getIslandPreferences();
    if (revision !== sharedRevision || sharedPending) return;
    sharedPreferences = value; sharedReady = true; updateSharedControls();
  } catch (error) {
    if (revision !== sharedRevision || sharedPending) return;
    sharedReady = false;
    updateSharedControls();
    peer.detail = `${t('联动设置读取失败：','Could not read shared preferences: ')}${String(error)}`;
    const text = document.querySelector('#peer-detail'); if (text) text.textContent = peer.detail;
  }
}
function updateSharedControls(): void {
  for (const element of document.querySelectorAll<HTMLInputElement | HTMLSelectElement>('[data-shared]')) {
    element.disabled = !sharedReady || sharedPending > 0;
    if (document.activeElement === element || sharedPending) continue;
    const value = sharedPreferences[element.dataset.shared as keyof IslandPreferences];
    if (element instanceof HTMLInputElement) element.checked = Boolean(value); else element.value = String(value);
  }
}
async function checkUpdates(force: boolean): Promise<boolean> {
  try { updateStatus = await bridge.updates(force); }
  catch (error) {
    const summary = document.querySelector('.update-summary'); if (summary) summary.textContent = `${t('检查更新失败：','Update check failed: ')}${String(error)}`;
    if (force) throw error;
    return false;
  }
  const summary = document.querySelector('.update-summary'); if (summary) summary.textContent = updateStatus.message;
  const open = document.querySelector<HTMLButtonElement>('[data-action="updates-open"]'); if (open) open.disabled = !updateStatus.url;
  return true;
}
async function maybeCheckUpdates(): Promise<void> {
  if (!native || !store().settings.autoCheckUpdates || automaticUpdateBusy || Date.now() < nextAutomaticUpdate) return;
  automaticUpdateBusy = true;
  try {
    const success = await checkUpdates(false);
    nextAutomaticUpdate = Date.now() + (success ? 86400000 : 3600000);
  } finally { automaticUpdateBusy = false; }
}
async function serviceCalendars(): Promise<void> {
  if (!native || storage.blocked || exitGate.pending) return;
  if (calendarServiceBusy) { calendarServiceRequested = true; return; }
  calendarServiceBusy = true;
  try {
    const currentStore = store(), before = calendarSnapshot();
    const refreshed = await refreshScheduler.refresh(before, store().settings.autoRefreshCalendars);
    if (exitGate.pending || storage.blocked || store() !== currentStore || !calendarSourcesCurrent(before)) return;
    let changed = false;
    if (refreshed.updates.length) storage.mutate(candidate => {
      for (const update of refreshed.updates) {
        const current = candidate.calendars.find(source => source.id === update.id && source.path === update.path && source.content === update.previousContent);
        if (current) { current.content = update.content; current.name = update.name; current.importedAt = new Date().toISOString(); changed = true; }
      }
    });
    if (changed) await persist();
    // Worker 完成后再计划提醒；视图更新被取消不能跳过已提交数据的保存。
    if (!await refreshCalendarView()) return;
    if (refreshed.errors.length) { calendarErrors = refreshed.errors.map(error => `${error.path}: ${error.message}`); if (view === 'calendar') toast(calendarErrors.join('\n')); }
    // 刷新完成之后复核当前开关与勿扰；只有实际播放成功才消费提醒。
    const reminder = planReminders(events, store().settings, store().remindedEvents);
    if (reminder.due.length && !exitGate.pending) {
      await bridge.reminder(store().settings.reminderSound);
      store().remindedEvents = [...new Set([...reminder.remindedEvents, ...reminder.newKeys])].slice(-5000);
      // 保存失败也保留内存去重及错误状态，下一轮不会重复响铃。
      await persist(); toast(`${t('日程提醒：','Calendar reminder: ')}${reminder.due[0].title}${reminder.due.length > 1 ? t(` 等 ${reminder.due.length} 项`, ` and ${reminder.due.length - 1} more`) : ''}`);
    }
  } catch (error) { toast(String(error)); }
  finally {
    calendarServiceBusy = false;
    if (calendarServiceRequested) { calendarServiceRequested = false; void serviceCalendars(); }
  }
}
function closeConfirmation(): void { document.querySelector<HTMLDialogElement>('#confirmation-dialog')?.remove(); confirmationAction = null; }
async function confirmAction(title: string, detail: string, confirmed: () => Promise<void>): Promise<void> {
  if (!expanded) { expanded = true; render(); await resizeWindow(); }
  closeConfirmation(); confirmationAction = confirmed;
  const dialog = document.createElement('dialog'); dialog.id = 'confirmation-dialog'; dialog.setAttribute('aria-label', title);
  dialog.innerHTML = html`<h2>${escape(title)}</h2><p>${escape(detail)}</p><div>${button('cancel-action',t('取消'),'','subtle')}${button('confirm-action',t('确认','Confirm'),'','primary')}</div>`;
  dialog.addEventListener('cancel', event => { event.preventDefault(); closeConfirmation(); });
  root.querySelector('.island')!.append(dialog); dialog.showModal(); await bridge.focus();
}
async function refreshCalendarView(): Promise<boolean> {
  const today = dayKey(new Date());
  if (today !== lastToday) {
    if (selectedDay === lastToday) {
      selectedDay = today;
      if (dayKey(month).slice(0, 7) === lastToday.slice(0, 7)) month = new Date(new Date().getFullYear(), new Date().getMonth(), 1);
    }
    lastToday = today;
  }
  if (!await refreshEvents()) return false;
  if (!expanded || !['calendar', 'overview'].includes(view) || composing || exitGate.pending) return true;
  const content = document.querySelector<HTMLElement>('#content');
  if (!content || document.activeElement?.matches('input, textarea, select, [contenteditable]')) return true;
  const focused = document.activeElement instanceof HTMLElement ? document.activeElement : null;
  const focusedAction = focused?.dataset.action;
  const focusedIdentity = focused ? JSON.stringify([focused.dataset.id,focused.dataset.session,focused.dataset.index]) : '';
  const scrollTop = content.scrollTop;
  content.innerHTML = `<div id="content-inner">${renderView()}</div>`; content.scrollTop = scrollTop;
  contentObserver.disconnect(); const inner=content.firstElementChild; if (inner) contentObserver.observe(inner); schedulePanelSize();
  if (focusedAction && focused && !focused.isConnected) {
    const replacement = [...content.querySelectorAll<HTMLElement>('[data-action]')].find(el => el.dataset.action === focusedAction && JSON.stringify([el.dataset.id,el.dataset.session,el.dataset.index])===focusedIdentity);
    replacement?.focus({ preventScroll: true });
  }
  updateClock();
  return true;
}
async function calendarTick(): Promise<void> {
  if (native) await serviceCalendars(); else await refreshCalendarView();
  void maybeCheckUpdates();
}
function closeExitDialog(): void {
  const dialog = document.querySelector<HTMLDialogElement>('#exit-dialog');
  dialog?.close(); dialog?.remove();
}
async function cancelExit(): Promise<void> { await bridge.cancelExit(); discardOnExit = false; closeExitDialog(); }
async function beginExit(discard = false): Promise<void> {
  if (composing) { toast(t('请先完成当前中文输入，再退出应用')); return; }
  discardOnExit = discard;
  if (native) await bridge.beginExit(); else await requestExit(discard);
}
async function requestExit(discard = false): Promise<void> {
  if (composing) { await bridge.cancelExit(); toast(t('请先完成当前中文输入，再退出应用')); return; }
  closeExitDialog();
  try {
    await exitGate.request(async () => {
      if (!discard && !storage.blocked) { await preferenceQueue; await persist(); await storage.flush(); }
    }, bridge.confirmExit);
  } catch (error) {
    expanded = true; render();
    await resizeWindow().catch(() => {});
    const dialog = document.createElement('dialog'); dialog.id = 'exit-dialog'; dialog.setAttribute('aria-label', t('保存失败，选择退出方式'));
    dialog.innerHTML = html`<h2>修改还没有保存</h2><p>${escape(error instanceof Error ? error.message : String(error))}</p><p>草稿仍在应用中，你可以继续编辑或重新保存。</p><div>${button('exit-continue', t('继续编辑'), '', 'subtle')}${button('exit-retry', t('重试退出'), '', 'primary')}${button('exit-discard', t('不保存并退出'), '', 'text-button danger')}</div>`;
    dialog.addEventListener('cancel', event => { event.preventDefault(); void perform(cancelExit); });
    root.querySelector('.island')!.append(dialog); dialog.showModal();
    await bridge.focus().catch(() => {});
  }
}
window.addEventListener('beforeunload', event => { if (storage.state.kind === 'error' || storage.state.kind === 'saving' || saveTimer) { event.preventDefault(); event.returnValue = ''; } });
document.addEventListener('visibilitychange', () => {
  root.dataset.background=String(document.hidden);
  if (document.hidden) { root.classList.remove('jelly'); root.style.setProperty('--magnetic-x','0px'); }
  if (document.hidden && saveTimer && !storage.blocked) void persist().catch(() => {});
  if (!document.hidden) { panelActionAt = Date.now(); collapsePolicy.reset(); void perform(pollMedia); void calendarTick(); void refreshSharedPreferences(); if(view==='files') void refreshFileStatuses(); }
  updateClock();
});
window.addEventListener('pagehide',()=>{ lyricController.cancel(); calendarController?.abort(); calendarImportController?.abort(); refreshScheduler.cancel(); calendarClient.dispose(); });
darkMedia.addEventListener('change', () => { applyVisualPreferences(); });
reducedMedia.addEventListener('change', () => { applyVisualPreferences(); void loadSelectedGif(); updateClock(); });
async function init(): Promise<void> {
  await storage.load();
  let loginError: unknown = null;
  if (native && !storage.blocked) {
    try { store().settings.launchAtLogin = await bridge.getLogin(); }
    catch (error) { loginError = error; }
  }
  mediaSelection.select(store().settings.preferredMediaSourceId); media = mediaSelection.snapshot;
  void refreshCalendarView(); render();
  await perform(applyAllPreferences);
  await perform(() => bridge.subscribe(paths => { void perform(async () => { ensureEditing(); if (storage.blocked) throw new Error(t('存储受保护')); const files = await bridge.inspect(paths); ensureEditing(); storage.mutate(candidate => addFiles(candidate, files)); view = 'files'; expanded = true; render(); await resizeWindow(); await persist(); void refreshFileStatuses(); }); }, toast, () => {
    const discard = discardOnExit; discardOnExit = false; void perform(() => requestExit(discard));
  }, active => { dropActive = active; if (!active) panelActionAt = Date.now(); }, () => { void calendarTick(); }, async action => {
    await perform(async()=>{ await selectView('settings'); if(action==='checkUpdates') { updateStatus=await bridge.updates(true); render(); } });
  }));
  await Promise.all([refreshPeer(), refreshSharedPreferences(), refreshGifs(), perform(pollMedia)]);
  if (loginError) toast(`${t('无法读取登录项：','Could not read launch-at-login state: ')}${String(loginError)}`);
  if (native) {
    void maybeCheckUpdates();
    void serviceCalendars();
  }
  setInterval(() => { void perform(pollMedia); }, 1000);
  setInterval(() => { updateClock(); interactionTick(); }, 100);
  setInterval(() => { void refreshPeer(); void refreshSharedPreferences(); }, 5000);
  setInterval(() => { void calendarTick(); }, 30000);
}
void init().catch(error => { if (!mounted) root.textContent = html`XNook 启动失败：${String(error)}`; else toast(String(error)); });
