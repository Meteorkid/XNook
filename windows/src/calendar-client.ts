import type { CalendarBatchResult } from './calendar';
import type { CalendarSource } from './domain';

export interface CalendarRequest { id: number; sources: readonly CalendarSource[]; from: string; to: string }
export type CalendarResponse = { id: number; result: CalendarBatchResult } | { id: number; error: string };
export interface CalendarWorker {
  onmessage: ((event: MessageEvent<CalendarResponse>) => void) | null;
  onerror: ((event: ErrorEvent) => void) | null;
  onmessageerror: ((event: MessageEvent) => void) | null;
  postMessage(request: CalendarRequest): void;
  terminate(): void;
}
interface Job {
  request: CalendarRequest; signal?: AbortSignal; abort: () => void;
  resolve(value: CalendarBatchResult): void; reject(error: Error): void;
}
const cancelled = (): Error => new DOMException('日历处理已取消', 'AbortError');

/** 一次只运行一个 Worker；超时通过 terminate 抢占第三方库内部同步循环。 */
export class CalendarClient {
  private nextId = 0;
  private queue: Job[] = [];
  private active: { job: Job; worker: CalendarWorker; timer: ReturnType<typeof setTimeout> } | null = null;
  constructor(private createWorker: () => CalendarWorker = () => new Worker(new URL('./calendar-worker.ts', import.meta.url), { type: 'module' }),
    private timeoutMs = 3000, private maxQueued = 2) {}

  expand(sources: readonly CalendarSource[], from: Date, to: Date, signal?: AbortSignal): Promise<CalendarBatchResult> {
    if (signal?.aborted) return Promise.reject(cancelled());
    // 在结构化克隆之前限制载荷；精确 UTF-8 大小和各项总预算在 Worker 中验证。
    if (sources.length > 100 || sources.some(source => source.content.length > 5 * 1024 * 1024)
      || sources.reduce((size, source) => size + source.content.length, 0) > 10 * 1024 * 1024) return Promise.reject(new Error('日历输入超过安全上限'));
    if (this.active && this.queue.length >= this.maxQueued) return Promise.reject(new Error('日历处理繁忙，请稍后重试'));
    if (!Number.isFinite(+from) || !Number.isFinite(+to) || to <= from) return Promise.reject(new Error('日历查询时间范围无效'));
    return new Promise((resolve, reject) => {
      const job: Job = { request: { id: ++this.nextId, sources: sources.map(source => ({ ...source })), from: from.toISOString(), to: to.toISOString() }, signal,
        resolve, reject, abort: () => this.abort(job) };
      signal?.addEventListener('abort', job.abort, { once: true });
      this.queue.push(job); this.startNext();
    });
  }
  dispose(): void {
    const jobs = this.queue.splice(0);
    for (const job of jobs) { this.detach(job); job.reject(cancelled()); }
    if (this.active) this.finish(this.active.job, cancelled());
  }
  private detach(job: Job): void { job.signal?.removeEventListener('abort', job.abort); }
  private abort(job: Job): void {
    if (this.active?.job === job) { this.finish(job, cancelled()); return; }
    const index = this.queue.indexOf(job);
    if (index >= 0) { this.queue.splice(index, 1); this.detach(job); job.reject(cancelled()); }
  }
  private startNext(): void {
    if (this.active) return;
    const job = this.queue.shift(); if (!job) return;
    let worker: CalendarWorker;
    try { worker = this.createWorker(); }
    catch (error) { this.detach(job); job.reject(new Error(`无法启动日历处理：${String(error)}`)); this.startNext(); return; }
    const timer = setTimeout(() => this.finish(job, new Error('日历处理超时，已停止此文件；请减少重复规则或导出较短日期范围')), this.timeoutMs);
    this.active = { job, worker, timer };
    worker.onmessage = ({ data }) => {
      if (data.id !== job.request.id) return;
      if ('error' in data) this.finish(job, new Error(data.error));
      else this.finish(job, undefined, data.result);
    };
    worker.onerror = event => { event.preventDefault(); this.finish(job, new Error('日历处理线程加载或运行失败')); };
    worker.onmessageerror = () => this.finish(job, new Error('无法读取日历处理结果'));
    try { worker.postMessage(job.request); }
    catch (error) { this.finish(job, new Error(`无法发送日历内容：${String(error)}`)); }
  }
  private finish(job: Job, error?: Error, result?: CalendarBatchResult): void {
    if (this.active?.job !== job) return;
    const { worker, timer } = this.active;
    this.active = null; clearTimeout(timer); this.detach(job);
    worker.onmessage = null; worker.onerror = null; worker.onmessageerror = null; worker.terminate();
    if (error) job.reject(error); else job.resolve(result!);
    this.startNext();
  }
}
