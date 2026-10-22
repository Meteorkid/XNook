import { test, expect, type Page } from '@playwright/test';

// 浏览器中的 IPC 合同测试：验证真实前端传参及失败处理，不代表 Windows 原生验收。
async function mockNative(page: Page) {
  await page.addInitScript(() => {
    const runtime = window as unknown as Record<string, any>;
    const callbacks = new Map<number, (event: unknown) => void>();
    const listeners = new Map<string, number[]>();
    let nextId = 1;
    const state = { calls: [] as Array<{ command: string; args: any }>, failWrites: false, pauseWrites: false, pendingWrites: [] as Array<() => void>,
      content: null as string | null, playing: true, exitState: 'idle' as 'idle'|'saving'|'confirming'|'authorized',
      emit(event: string, payload: unknown) { if (event==='request-exit' && state.exitState==='idle') state.exitState='saving'; for (const id of listeners.get(event) || []) callbacks.get(id)?.({ event, id, payload }); } };
    runtime.__fixture = state;
    runtime.isTauri = true;
    runtime.__TAURI_EVENT_PLUGIN_INTERNALS__ = { unregisterListener: () => {} };
    runtime.__TAURI_INTERNALS__ = {
      metadata: { currentWindow: { label: 'main' }, currentWebview: { label: 'main' } },
      transformCallback(callback: (event: unknown) => void) { const id = nextId++; callbacks.set(id, callback); return id; },
      unregisterCallback(id: number) { callbacks.delete(id); },
      async invoke(command: string, args: any = {}) {
        state.calls.push({ command, args });
        if (command === 'plugin:event|listen') { listeners.set(args.event, [...(listeners.get(args.event) || []), args.handler]); return args.handler; }
        if (command === 'plugin:event|unlisten') return null;
        if (command === 'take_tray_actions') return [];
        if (command === 'file_statuses') return args.paths.map((path:string) => ({path,available:true,error:null,sizeBytes:2048,isDirectory:false}));
        if (command === 'apply_preferences') return null;
        if (command === 'begin_exit') { if (state.exitState==='idle') state.emit('request-exit',null); else if(state.exitState==='saving')state.exitState='confirming'; return null; }
        if (command === 'cancel_exit') { if (state.exitState==='saving'||state.exitState==='idle') { state.exitState='idle'; return null; } throw new Error('原生退出确认尚未结束'); }
        if (command === 'confirm_exit') { if (state.exitState!=='saving') throw new Error('没有待确认的退出请求'); state.exitState='authorized'; return null; }
        if (command === 'list_gifs') return [];
        if (command === 'get_launch_at_login') return false;
        if (command === 'island_get_preferences') return {swipeEnabled:true,sensitivity:'medium',startupDisplay:'lastUsed'};
        if (command === 'check_updates') return {currentVersion:'0.3.1',latestVersion:null,updateAvailable:false,url:null,checkedAt:new Date().toISOString(),message:'暂无 Windows 更新'};

        if (command === 'read_store') return state.content;
        if (command === 'write_store') {
          if (state.failWrites) throw new Error('测试磁盘不可写');
          if (state.pauseWrites) await new Promise<void>(resolve => state.pendingWrites.push(resolve));
          state.content = args.content; return null;
        }
        if (command === 'media_snapshot') return {
          available: true, sourceId: 'test-player', sessionToken: '11111111-1111-4111-8111-111111111111', playerName: '测试播放器', playerKind: 'other',
          sources: [{sourceId:'test-player',name:'测试播放器',kind:'other',playing:state.playing,isSystemCurrent:true}],
          title: '测试曲目', artist: '测试歌手', album: '测试专辑',
          playing: state.playing, position: 12, duration: 180, artwork: null,
          canPlayPause: true, canNext: true, canPrevious: false, canSeek: true, sampledAt: Date.now(),
        };
        if (command === 'lookup_lyrics') return [{ id: 1, trackName: '测试曲目', artistName: '测试歌手', albumName: '测试专辑',
          duration: 180, instrumental: false, syncedLyrics: '[00:00.00]第一句\n[00:10.00]第二句', plainLyrics: '第一句\n第二句' }];
        if (command === 'media_control') { if (args.action === 'toggle') state.playing = !state.playing; return null; }
        if (command === 'island_peer_status') return { installed: true, running: true, compatible: true, detail: '测试对方已注册' };
        if (command === 'switch_island') throw new Error('测试目标显示失败，当前窗口保留');
        if (command === 'pick_files') return [{ path: 'C:\\资料\\课程.pdf', name: '课程.pdf', isDirectory: false }];
        if (command === 'pick_calendar') return { path: 'C:\\资料\\课程.ics', name: '课程.ics',
          content: 'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:slow-import\r\nDTSTART:20261017T010000Z\r\nDTEND:20261017T020000Z\r\nSUMMARY:导入测试\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n' };
        if (['resize_island', 'configure_window', 'focus_input', 'drag_island', 'open_file', 'reveal_file', 'confirm_exit'].includes(command)) return null;
        throw new Error(`未约定的原生命令：${command}`);
      },
    };
  });
}
async function calls(page: Page, command: string) {
  return page.evaluate(name => (window as any).__fixture.calls.filter((call: any) => call.command === name), command);
}
async function navigate(page: Page, name: string) {
  await page.getByRole('navigation').getByRole('button', { name, exact: true }).click();
}
test.beforeEach(async ({ page }) => {
  await mockNative(page);
  await page.goto('/');
  await page.getByRole('button', { name: '展开 XNook', exact: true }).click();
});

test('媒体控制、歌词显示与切换失败经过真实前端命令链', async ({ page }) => {
  await navigate(page, '音乐');
  await expect(page.getByRole('heading', { name: '测试曲目' })).toBeVisible();
  await expect(page.locator('[data-lyric="1"]')).toHaveClass('current');
  await expect(page.getByRole('button', { name: '上一首', exact: true })).toBeDisabled();
  await page.getByRole('button', { name: '暂停', exact: true }).click();
  await expect(page.getByRole('button', { name: '播放', exact: true })).toBeVisible();
  expect((await calls(page, 'media_control')).at(-1).args).toEqual({ sourceId: 'test-player', sessionToken: '11111111-1111-4111-8111-111111111111', action: 'toggle' });
  await page.getByRole('button', { name: 'XIsland', exact: true }).click();
  await expect(page.locator('#toast')).toContainText('目标显示失败');
  await expect(page.locator('.panel')).toBeVisible();
  expect((await calls(page, 'switch_island')).length).toBe(1);
  expect((await calls(page, 'lookup_lyrics'))[0].args).toEqual({ title: '测试曲目', artist: '测试歌手', album: '测试专辑', duration: 180 });
});

test('文件架关联任务后移除引用，历史仍以独立路径打开文件', async ({ page }) => {
  await navigate(page, '文件架');
  await page.getByRole('button', { name: '添加文件', exact: true }).click();
  await expect(page.locator('.file-row')).toContainText('课程.pdf');
  await navigate(page, 'NookFlow');
  await page.locator('#flow-title').fill('整理课程');
  await page.locator('#flow-start-form').getByRole('button').click();
  await page.getByRole('button', { name: '关联文件架', exact: true }).click();
  await navigate(page, '文件架');
  await page.getByRole('button', { name: '移除 课程.pdf', exact: true }).click();
  await expect(page.locator('.file-row')).toHaveCount(0);
  await navigate(page, 'NookFlow');
  await page.getByRole('button', { name: '结束任务', exact: true }).click();
  await page.getByRole('button', { name: '课程.pdf', exact: true }).click();
  expect((await calls(page, 'open_file')).at(-1).args.path).toBe('C:\\资料\\课程.pdf');
  const saved = await page.evaluate(() => JSON.parse((window as any).__fixture.content));
  expect(saved.files).toEqual([]);
  expect(saved.history[0].linkedFiles[0].path).toBe('C:\\资料\\课程.pdf');
});

test('退出请求先保存，写入失败时保持窗口和草稿，恢复后才确认退出', async ({ page }) => {
  await navigate(page, '笔记');
  await page.getByRole('button', { name: '新建笔记', exact: true }).click();
  await expect(page.locator('#save-status')).toHaveText('已保存到本机');
  await page.evaluate(() => { (window as any).__fixture.failWrites = true; });
  await page.getByRole('textbox', { name: '笔记内容', exact: true }).fill('还没有保存的中文内容');
  await page.evaluate(() => (window as any).__fixture.emit('request-exit', null));
  await expect(page.locator('#save-status')).toContainText('保存失败');
  expect(await calls(page, 'confirm_exit')).toEqual([]);
  await expect(page.getByRole('textbox', { name: '笔记内容', exact: true })).toHaveValue('还没有保存的中文内容');
  await page.evaluate(() => { (window as any).__fixture.failWrites = false; (window as any).__fixture.emit('request-exit', null); });
  await expect.poll(async () => (await calls(page, 'confirm_exit')).length).toBe(1);
  const saved = await page.evaluate(() => JSON.parse((window as any).__fixture.content));
  expect(saved.notes[0].content).toBe('还没有保存的中文内容');
});

test('退出等待慢速磁盘时禁止漏存后续编辑', async ({ page }) => {
  await navigate(page, '笔记');
  await page.getByRole('button', { name: '新建笔记', exact: true }).click();
  await expect(page.locator('#save-status')).toHaveText('已保存到本机');
  await page.evaluate(() => { (window as any).__fixture.pauseWrites = true; });
  const editor = page.getByRole('textbox', { name: '笔记内容', exact: true });
  await editor.fill('等待保存的内容 A');
  await page.evaluate(() => (window as any).__fixture.emit('request-exit', null));
  await expect.poll(() => page.evaluate(() => (window as any).__fixture.pendingWrites.length)).toBe(1);
  const acceptsMoreInput = await editor.isEditable();
  if (acceptsMoreInput) await editor.fill('后输入的内容 B');
  expect(await calls(page, 'confirm_exit')).toEqual([]);
  await page.evaluate(() => {
    const state = (window as any).__fixture; state.pauseWrites = false;
    for (const release of state.pendingWrites.splice(0)) release();
  });
  await expect.poll(async () => (await calls(page, 'confirm_exit')).length).toBe(1);
  const saved = await page.evaluate(() => JSON.parse((window as any).__fixture.content));
  expect(saved.notes[0].content).toBe(acceptsMoreInput ? '后输入的内容 B' : '等待保存的内容 A');
});

test('日历异步保存完成不清空用户在另一个工具中输入的任务名', async ({ page }) => {
  await navigate(page, '日历');
  await page.evaluate(() => { (window as any).__fixture.pauseWrites = true; });
  await page.getByRole('button', { name: '导入 .ics', exact: true }).click();
  await expect.poll(() => page.evaluate(() => (window as any).__fixture.pendingWrites.length)).toBe(1);
  await navigate(page, 'NookFlow');
  await page.locator('#flow-title').fill('正在输入的任务草稿');
  await page.evaluate(() => {
    const state = (window as any).__fixture; state.pauseWrites = false;
    for (const release of state.pendingWrites.splice(0)) release();
  });
  await expect(page.locator('#save-status')).toHaveText('已保存到本机');
  await expect(page.locator('#flow-title')).toHaveValue('正在输入的任务草稿');
});
