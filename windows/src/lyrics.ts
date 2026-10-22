export type PlayerKind = 'netease' | 'qqmusic' | 'other';
export interface MediaSource { sourceId: string; name: string; kind: PlayerKind; playing: boolean; isSystemCurrent: boolean }
export interface MediaSnapshot {
  available: boolean; sourceId: string; sessionToken: string | null; playerName: string; playerKind: PlayerKind; sources: MediaSource[]; title: string; artist: string; album: string; playing: boolean;
  position: number | null; duration: number | null; artwork: string | null; playbackRate?: number | null;
  canPlayPause: boolean; canNext: boolean; canPrevious: boolean; canSeek: boolean; sampledAt: number; error?: string;
}
export interface LyricsCandidate { id: number; trackName: string; artistName: string; albumName: string; duration: number; instrumental: boolean; syncedLyrics: string | null; plainLyrics: string | null }
export interface LyricLine { at: number; text: string }
export interface Lyrics { lines: LyricLine[]; plain: string; instrumental: boolean }
export const emptyMedia = (): MediaSnapshot => ({ available: false, sourceId: '', sessionToken: null, playerName: '', playerKind: 'other', sources: [], title: '', artist: '', album: '', playing: false,
  position: null, duration: null, artwork: null, canPlayPause: false, canNext: false, canPrevious: false, canSeek: false, sampledAt: Date.now() });
const MAX_LRC_CHARACTERS = 2 * 1024 * 1024;
const MAX_LRC_LINES = 10000;
const MAX_LRC_RENDERED_CHARACTERS = 1024 * 1024;
class LyricsLimitError extends Error {}
/** 保留旧语义：只移除非空闭合标签，未闭合尾部和 [] 原样保留。 */
function withoutLrcTags(line: string): string {
  const pieces: string[] = [];
  let offset = 0;
  while (offset < line.length) {
    const start = line.indexOf('[', offset);
    if (start < 0) { pieces.push(line.slice(offset)); break; }
    const end = line.indexOf(']', start + 1);
    if (end < 0) { pieces.push(line.slice(offset)); break; }
    pieces.push(line.slice(offset, start));
    if (end === start + 1) pieces.push('[]');
    offset = end + 1;
  }
  return pieces.join('').trim();
}
export function parseLrc(content: string): LyricLine[] {
  if (content.length > MAX_LRC_CHARACTERS) throw new LyricsLimitError('歌词内容超过解析上限');
  const parsedOffset = Number(content.match(/\[offset:([+-]?\d+)\]/i)?.[1] || 0) / 1000;
  const offset = Number.isFinite(parsedOffset) ? parsedOffset : 0;
  const lines: LyricLine[] = [];
  let renderedCharacters = 0;
  for (const line of content.split(/\r?\n/)) {
    const stamps = line.matchAll(/\[(\d+):(\d{2})(?:[.:](\d{1,3}))?\]/g);
    const text = withoutLrcTags(line);
    for (const stamp of stamps) {
      if (+stamp[2] >= 60) continue;
      const at = +stamp[1] * 60 + +stamp[2] + Number(`0.${stamp[3] || '0'}`) + offset;
      if (Number.isFinite(at)) {
        if (lines.length >= MAX_LRC_LINES) throw new LyricsLimitError('歌词时间标签超过解析上限');
        renderedCharacters += text.length;
        if (renderedCharacters > MAX_LRC_RENDERED_CHARACTERS) throw new LyricsLimitError('歌词展开正文超过解析上限');
        lines.push({ at: Math.max(0, at), text });
      }
    }
  }
  return lines.sort((a, b) => a.at - b.at);
}
export function currentLyric(lines: LyricLine[], position: number): number {
  let low = 0, high = lines.length;
  while (low < high) { const mid = (low + high) >>> 1; if (lines[mid].at <= position) low = mid + 1; else high = mid; }
  return low - 1;
}
export const trackKey = (media: Pick<MediaSnapshot, 'sourceId' | 'title' | 'artist' | 'album' | 'duration'>): string =>
  JSON.stringify([media.sourceId, media.title, media.artist, media.album, media.duration]);
const normalize = (s: string): string => s.normalize('NFKC').toLowerCase().replace(/[\p{P}\p{Z}\s]/gu, '');
// 只消除排版差异；不拆分艺人、不做子串匹配，AC/DC 等姓名中的符号必须保留。
const normalizeArtist = (s: string): string => s.normalize('NFKC').toLowerCase().trim().replace(/\s+/g, ' ').replace(/\s*\/\s*/g, '/');
export function chooseCandidate(candidates: LyricsCandidate[], media: Pick<MediaSnapshot, 'title' | 'artist' | 'album' | 'duration'>): LyricsCandidate | null {
  const title = normalize(media.title), artist = normalizeArtist(media.artist);
  if (!title || !artist) return null;
  const ranked: { candidate: LyricsCandidate; score: number }[] = [];
  let rejectedLimit: LyricsLimitError | null = null;
  for (const candidate of candidates) {
    if (normalize(candidate.trackName) !== title || normalizeArtist(candidate.artistName) !== artist
      || media.duration !== null && Math.abs(candidate.duration - media.duration) > 8) continue;
    let synchronized: boolean;
    try { synchronized = parseLrc(candidate.syncedLyrics || '').length > 0; }
    catch (error) { if (error instanceof LyricsLimitError) { rejectedLimit=error; continue; } throw error; }
    if (!candidate.instrumental && !candidate.plainLyrics?.trim() && !synchronized) continue;
    ranked.push({ candidate, score: (normalize(candidate.albumName) === normalize(media.album) ? 2 : 0) + (synchronized ? 3 : 0)
      - (media.duration === null ? 0 : Math.abs(candidate.duration - media.duration) / 8) });
  }
  if (!ranked.length && rejectedLimit) throw rejectedLimit;
  return ranked.sort((a, b) => b.score - a.score)[0]?.candidate || null;
}
export function mediaPosition(media: MediaSnapshot, now = Date.now()): number | null {
  if (media.position === null) return null;
  const rate = media.playbackRate === null || media.playbackRate === undefined ? 1
    : Number.isFinite(media.playbackRate) && media.playbackRate >= 0 && media.playbackRate <= 16 ? media.playbackRate : 1;
  // 失联时最多补偿 3 秒，避免无限假定播放器仍在播放。
  const progressed = media.position + (media.playing ? Math.min(3, Math.max(0, now - media.sampledAt) / 1000) * rate : 0);
  return Math.max(0, media.duration === null ? progressed : Math.min(media.duration, progressed));
}

export type RetryScheduler = (callback: () => void, delayMs: number) => () => void;
const scheduleRetry: RetryScheduler = (callback, delay) => {
  const timer = setTimeout(callback, delay);
  return () => clearTimeout(timer);
};
const retryableError = (error: unknown): boolean => /network|fetch|timeout|连接|网络|超时|过于频繁|\b429\b|\b5\d\d\b/i
  .test(error instanceof Error ? error.message : String(error));
interface CachedLyrics { value: Lyrics | null; candidate: LyricsCandidate | null; expires: number }
const trackIdentity = (media: MediaSnapshot): string => JSON.stringify([media.sourceId, media.title, media.artist, media.album]);

export class LyricsController {
  private generation = 0;
  private cache = new Map<string, CachedLyrics>();
  private lastMatch: { identity: string; duration: number | null; entry: CachedLyrics } | null = null;
  private retryWait: { cancel: () => void; finish: (active: boolean) => void } | null = null;
  private backgroundRetry: (() => void) | null = null;
  private readonly retryDelays: readonly number[];
  private readonly schedule: RetryScheduler;
  constructor(private lookup: (media: MediaSnapshot) => Promise<LyricsCandidate[]>, private now = Date.now,
    options: { retryDelaysMs?: readonly number[]; scheduleRetry?: RetryScheduler } = {}) {
    this.retryDelays = (options.retryDelaysMs ?? [1000, 3000]).slice(0, 2).map(delay => Math.min(30000, Math.max(0, Number.isFinite(delay) ? delay : 1000)));
    this.schedule = options.scheduleRetry ?? scheduleRetry;
  }
  cancel(): void {
    this.generation++;
    if (this.retryWait) { const waiting = this.retryWait; this.retryWait = null; waiting.cancel(); waiting.finish(false); }
    this.backgroundRetry?.(); this.backgroundRetry = null;
  }
  private wait(delay: number): Promise<boolean> {
    return new Promise(resolve => {
      const cancel = this.schedule(() => { this.retryWait = null; resolve(true); }, delay);
      this.retryWait = { cancel, finish: resolve };
    });
  }
  private currentMatch(media: MediaSnapshot, entry: CachedLyrics): void {
    this.lastMatch = entry.value && entry.candidate ? { identity: trackIdentity(media), duration: media.duration, entry } : null;
  }
  private remember(media: MediaSnapshot, candidates: LyricsCandidate[], generation: number): Lyrics | null {
    const selected = chooseCandidate(candidates, media);
    const value = selected ? { lines: parseLrc(selected.syncedLyrics || ''), plain: selected.plainLyrics || '', instrumental: selected.instrumental } : null;
    const entry = { value, candidate: selected, expires: this.now() + (value ? 86400000 : 300000) };
    this.cache.set(trackKey(media), entry);
    if (this.cache.size > 150) this.cache.delete(this.cache.keys().next().value!);
    // 迟到结果可留在其精确键缓存，但不能顶掉当前曲目的复用候选。
    if (generation === this.generation) this.currentMatch(media, entry);
    return value;
  }
  private retryLater(media: MediaSnapshot, generation: number, attempt: number, apply: (lyrics: Lyrics | null) => void,
    onError: (error: unknown) => void): void {
    if (generation !== this.generation) return;
    const delay = [15000, 30000, 60000, 120000][Math.min(attempt, 3)];
    this.backgroundRetry = this.schedule(() => {
      this.backgroundRetry = null;
      if (generation !== this.generation) return;
      // 一次请求结束才安排下一次，同一首歌不会积压并发请求。
      const report = (error: unknown): void => { try { onError(error); } catch { /* 错误展示不能中断恢复重试。 */ } };
      void Promise.resolve().then(() => generation === this.generation ? this.lookup(media) : null).then(candidates => {
        if (candidates === null) return;
        const value = this.remember(media, candidates, generation);
        if (generation === this.generation) apply(value);
      }, error => {
        if (generation !== this.generation) return;
        if (retryableError(error)) this.retryLater(media, generation, attempt + 1, apply, onError);
        report(error);
      }).catch(error => { if (generation === this.generation) report(error); });
    }, delay);
  }
  async load(media: MediaSnapshot, apply: (lyrics: Lyrics | null) => void, onError: (error: unknown) => void = () => {}): Promise<void> {
    this.cancel();
    const generation = this.generation, key = trackKey(media), cached = this.cache.get(key);
    if (cached && cached.expires > this.now()) {
      this.cache.delete(key); this.cache.set(key, cached);
      this.currentMatch(media, cached);
      apply(cached.value); return;
    }
    const previous = this.lastMatch;
    if (previous && previous.identity === trackIdentity(media) && previous.entry.expires > this.now()
      && previous.duration !== null && media.duration !== null && Number.isFinite(previous.duration) && Number.isFinite(media.duration)
      && Math.abs(previous.duration - media.duration) < 1 && previous.entry.candidate
      && chooseCandidate([previous.entry.candidate], media)) {
      // 小幅采样波动复用已验证结果；仍按新时长严格检查，不跨越候选的 8 秒匹配边界。
      this.cache.set(key, previous.entry);
      if (this.cache.size > 150) this.cache.delete(this.cache.keys().next().value!);
      this.currentMatch(media, previous.entry);
      apply(previous.entry.value); return;
    }
    let candidates: LyricsCandidate[] = [];
    for (let attempt = 0; ; attempt++) {
      try { candidates = await this.lookup(media); break; }
      catch (error) {
        if (generation !== this.generation) return;
        if (!retryableError(error)) throw error;
        if (attempt >= this.retryDelays.length) { this.retryLater(media, generation, 0, apply, onError); throw error; }
        if (!await this.wait(this.retryDelays[attempt]) || generation !== this.generation) return;
      }
    }
    const value = this.remember(media, candidates, generation);
    if (generation === this.generation) apply(value);
  }
}
