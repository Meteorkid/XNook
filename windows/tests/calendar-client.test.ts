import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Worker as NodeWorker } from 'node:worker_threads';
import { CalendarClient, type CalendarRequest, type CalendarResponse, type CalendarWorker } from '../src/calendar-client';

const from = new Date('2026-10-01T00:00:00Z'), to = new Date('2026-11-01T00:00:00Z');
const result = { events: [], warnings: [], errors: [] };
class FakeWorker implements CalendarWorker {
  onmessage: CalendarWorker['onmessage'] = null;
  onerror: CalendarWorker['onerror'] = null;
  onmessageerror: CalendarWorker['onmessageerror'] = null;
  request!: CalendarRequest;
  terminated = 0;
  postMessage(request: CalendarRequest): void { this.request = request; }
  terminate(): void { this.terminated++; }
  succeed(): void { this.onmessage?.(new MessageEvent<CalendarResponse>('message', { data: { id: this.request.id, result } })); }
}
const factory = (workers: FakeWorker[]) => () => { const worker = new FakeWorker(); workers.push(worker); return worker; };

test('同步死循环由主线程超时终止，清理所有监听且后续请求可恢复', async () => {
  const workers: FakeWorker[] = [], client = new CalendarClient(factory(workers), 15);
  const pending = client.expand([], from, to), oldMessage = workers[0].onmessage!;
  await assert.rejects(pending, /处理超时/);
  assert.equal(workers[0].terminated, 1);
  assert.equal(workers[0].onmessage, null); assert.equal(workers[0].onerror, null); assert.equal(workers[0].onmessageerror, null);
  const next = client.expand([], from, to);
  oldMessage(new MessageEvent<CalendarResponse>('message', { data: { id: 1, result } }));
  assert.equal(workers[1].terminated, 0);
  workers[1].succeed(); assert.deepEqual(await next, result); assert.equal(workers[1].terminated, 1);
});

test('始终只有一个活动 Worker，等待队列有界且取消会释放工作位', async () => {
  const workers: FakeWorker[] = [], client = new CalendarClient(factory(workers), 1000, 1), abort = new AbortController();
  const first = client.expand([], from, to, abort.signal), rejected = assert.rejects(first, { name: 'AbortError' });
  const next = client.expand([], from, to);
  assert.equal(workers.length, 1);
  await assert.rejects(client.expand([], from, to), /繁忙/);
  abort.abort(); await rejected;
  assert.equal(workers[0].terminated, 1); assert.equal(workers.length, 2);
  workers[1].succeed(); await next;
});

test('取消排队请求和 dispose 不遗留 Worker、监听或待决 Promise', async () => {
  const workers: FakeWorker[] = [], client = new CalendarClient(factory(workers), 1000), abort = new AbortController();
  const first = client.expand([], from, to), firstRejected = assert.rejects(first, { name: 'AbortError' });
  const queued = client.expand([], from, to, abort.signal), queuedRejected = assert.rejects(queued, { name: 'AbortError' });
  abort.abort(); await queuedRejected;
  assert.equal(workers.length, 1);
  const last = client.expand([], from, to), lastRejected = assert.rejects(last, { name: 'AbortError' });
  client.dispose(); await Promise.all([firstRejected, lastRejected]);
  assert.equal(workers.length, 1); assert.equal(workers[0].terminated, 1);
  await assert.rejects(client.expand([], from, to, abort.signal), { name: 'AbortError' });
});

test('加载、运行、消息解码和发送错误都终止 Worker 并继续处理队列', async () => {
  for (const fail of ['error', 'messageerror', 'response'] as const) {
    const workers: FakeWorker[] = [], client = new CalendarClient(factory(workers), 1000);
    const pending = client.expand([], from, to), rejected = assert.rejects(pending);
    const next = client.expand([], from, to);
    if (fail === 'error') workers[0].onerror?.({ preventDefault() {} } as ErrorEvent);
    if (fail === 'messageerror') workers[0].onmessageerror?.({} as MessageEvent);
    if (fail === 'response') workers[0].onmessage?.({ data: { id: workers[0].request.id, error: '无效 ICS' } } as MessageEvent<CalendarResponse>);
    await rejected; assert.equal(workers[0].terminated, 1);
    workers[1].succeed(); await next;
  }
  const broken = new FakeWorker(); broken.postMessage = () => { throw new Error('clone'); };
  await assert.rejects(new CalendarClient(() => broken).expand([], from, to), /发送/);
  assert.equal(broken.terminated, 1);
  await assert.rejects(new CalendarClient(() => { throw new Error('CSP'); }).expand([], from, to), /启动/);
});

test('完成后移除取消监听并清除超时，返回结果不会被迟到信号更改', async () => {
  const workers: FakeWorker[] = [], client = new CalendarClient(factory(workers), 10), abort = new AbortController();
  let removed = 0;
  const original = abort.signal.removeEventListener.bind(abort.signal);
  abort.signal.removeEventListener = (...args: Parameters<AbortSignal['removeEventListener']>) => { removed++; original(...args); };
  const pending = client.expand([], from, to, abort.signal); workers[0].succeed(); await pending;
  abort.abort(); await new Promise(resolve => setTimeout(resolve, 20));
  assert.equal(workers[0].terminated, 1); assert.equal(removed, 1);
});

test('克隆前限制来源数和总输入，拒绝超大排队载荷', async () => {
  const workers: FakeWorker[] = [], client = new CalendarClient(factory(workers));
  const source = { id: 'a', name: 'a.ics', path: 'a.ics', importedAt: from.toISOString(), content: '' };
  await assert.rejects(client.expand(Array.from({ length: 101 }, () => source), from, to), /上限/);
  await assert.rejects(client.expand([{ ...source, content: 'a'.repeat(5 * 1024 * 1024 + 1) }], from, to), /上限/);
  await assert.rejects(client.expand(Array.from({ length: 3 }, () => ({ ...source, content: 'a'.repeat(4 * 1024 * 1024) })), from, to), /上限/);
  assert.equal(workers.length, 0);
});

test('真实 ICS 内部死循环在 Worker 中被终止，主线程可响应且正常日历随后恢复', async t => {
  const workers: { started: boolean; terminated: number }[] = [];
  const client = new CalendarClient(() => {
    const state = { started: false, terminated: 0 }; workers.push(state);
    const worker = new NodeWorker(`
      const { parentPort, workerData } = require('node:worker_threads');
      (async () => {
        globalThis.self = { postMessage: data => parentPort.postMessage(data) };
        const { tsImport } = await import('tsx/esm/api');
        await tsImport(workerData.entry, workerData.parent);
        parentPort.on('message', data => {
          parentPort.postMessage({ started: true });
          self.onmessage({ data });
        });
      })();
    `, { eval: true, workerData: { entry: new URL('../src/calendar-worker.ts', import.meta.url).href, parent: import.meta.url } });
    const adapter: CalendarWorker = {
      onmessage: null, onerror: null, onmessageerror: null,
      postMessage: request => worker.postMessage(request),
      terminate: () => { state.terminated++; void worker.terminate(); },
    };
    worker.on('message', data => {
      if (data.started) state.started = true;
      else adapter.onmessage?.(new MessageEvent<CalendarResponse>('message', { data }));
    });
    worker.on('error', () => adapter.onerror?.({ preventDefault() {} } as ErrorEvent));
    return adapter;
  }, 1000);
  t.after(() => client.dispose());
  const prefix = 'BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VEVENT\nUID:loop\nDTSTART:20261019T090000Z\n';
  const suffix = '\nEND:VEVENT\nEND:VCALENDAR';
  const source = { id: 'real', name: 'real.ics', path: 'real.ics', importedAt: from.toISOString(),
    content: prefix + 'RRULE:FREQ=DAILY;INTERVAL=7;BYDAY=TU' + suffix };
  let ticks = 0; const timer = setInterval(() => { ticks++; }, 10);
  try {
    await assert.rejects(client.expand([source], from, to), /处理超时/);
    assert.equal(workers[0].started, true); assert.equal(workers[0].terminated, 1); assert.ok(ticks > 5);
    const recovered = await client.expand([{ ...source, content: prefix + 'SUMMARY:恢复' + suffix }], from, to);
    assert.equal(recovered.events[0].title, '恢复'); assert.equal(workers[1].terminated, 1);
  } finally { clearInterval(timer); }
});
