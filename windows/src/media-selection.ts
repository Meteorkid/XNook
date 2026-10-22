import { validMediaSourceId } from './domain';
import { emptyMedia, trackKey, type MediaSnapshot } from './lyrics';
export type MediaAction = 'toggle' | 'next' | 'previous' | 'seek';

/** 来源与异步请求一起换代，任何控制都绑定点击时实际显示的来源。 */
export class MediaSelection {
  snapshot: MediaSnapshot = emptyMedia();
  preferredSourceId: string | null = null;
  generation = 0;
  private pollingGeneration: number | null = null;
  constructor(private io: {
    snapshot(preferredSourceId: string | null): Promise<MediaSnapshot>;
    control(sourceId: string, sessionToken: string, action: MediaAction, position?: number): Promise<void>;
  }) {}
  select(preferredSourceId: string | null): void {
    if (preferredSourceId !== null && !validMediaSourceId(preferredSourceId)) throw new Error('播放器来源标识无效');
    if (preferredSourceId === this.preferredSourceId) return;
    this.preferredSourceId = preferredSourceId;
    this.generation++;
    const source = this.snapshot.sources.find(source => source.sourceId === preferredSourceId);
    this.snapshot = { ...emptyMedia(), sources: this.snapshot.sources, sourceId: preferredSourceId || '',
      playerName: source?.name || '', playerKind: source?.kind || 'other' };
  }
  async poll(): Promise<MediaSnapshot | null> {
    const generation = this.generation;
    if (this.pollingGeneration === generation) return null;
    this.pollingGeneration = generation;
    try {
      const next = await this.io.snapshot(this.preferredSourceId);
      if (generation !== this.generation) return null;
      if (this.preferredSourceId && next.available && next.sourceId !== this.preferredSourceId) throw new Error('播放器来源已经变化，请重新选择');
      if (trackKey(next) !== trackKey(this.snapshot) || next.sessionToken !== this.snapshot.sessionToken || next.available !== this.snapshot.available) this.generation++;
      this.snapshot = next;
      return next;
    } catch (error) {
      if (generation !== this.generation) return null;
      this.snapshot = { ...emptyMedia(), sourceId: this.preferredSourceId || '', sources: this.snapshot.sources,
        playerName: this.snapshot.playerName, playerKind: this.snapshot.playerKind, error: error instanceof Error ? error.message : String(error) };
      this.generation++;
      return this.snapshot;
    } finally {
      if (this.pollingGeneration === generation) this.pollingGeneration = null;
    }
  }
  async control(sourceId: string, sessionToken: string, action: MediaAction, position?: number): Promise<boolean> {
    if (!this.snapshot.available || !validMediaSourceId(sourceId) || sourceId !== this.snapshot.sourceId
      || !sessionToken || sessionToken !== this.snapshot.sessionToken) throw new Error('播放器会话已变化，请使用当前播放器的控制按钮');
    const generation = this.generation;
    try {
      await this.io.control(sourceId, sessionToken, action, position);
      return generation === this.generation && sourceId === this.snapshot.sourceId && sessionToken === this.snapshot.sessionToken;
    } catch (error) {
      if (generation !== this.generation || sourceId !== this.snapshot.sourceId || sessionToken !== this.snapshot.sessionToken) return false;
      throw error;
    }
  }
}
