import { test, expect, type Page } from '@playwright/test';

// 受控媒体会话检验前端合同与竞态，不提供厂商客户端或 Windows 真机兼容性证明。
async function installMediaFixture(page: Page) {
  await page.addInitScript(() => {
    const runtime = window as any;
    const callbacks = new Map<number, (event: unknown) => void>();
    let callbackId = 1;
    const players = [
      { sourceId: 'cloudmusic.exe', sessionToken: '11111111-1111-4111-8111-111111111111', name: '网易云音乐', kind: 'netease', playing: true, isSystemCurrent: false, title: '网易测试歌曲' },
      { sourceId: 'QQMusic.exe', sessionToken: '22222222-2222-4222-8222-222222222222', name: 'QQ 音乐', kind: 'qqmusic', playing: true, isSystemCurrent: false, title: 'QQ 测试歌曲' },
      { sourceId: 'chrome.exe', sessionToken: '33333333-3333-4333-8333-333333333333', name: 'Chrome', kind: 'other', playing: true, isSystemCurrent: true, title: '浏览器测试视频' },
    ];
    const state = {
      players, calls: [] as Array<{command: string; args: any}>,
      delayedSource: null as string | null, pendingSnapshots: [] as Array<() => void>,
      delayedLyricsTitle: null as string | null, pendingLyrics: [] as Array<() => void>,
      completedLyrics: [] as string[],
    };
    runtime.__mediaFixture = state;
    runtime.isTauri = true;
    runtime.__TAURI_EVENT_PLUGIN_INTERNALS__ = { unregisterListener() {} };
    runtime.__TAURI_INTERNALS__ = {
      metadata: { currentWindow: { label: 'main' }, currentWebview: { label: 'main' } },
      transformCallback(callback: (event: unknown) => void) { const id = callbackId++; callbacks.set(id, callback); return id; },
      unregisterCallback(id: number) { callbacks.delete(id); },
      async invoke(command: string, args: any = {}) {
        state.calls.push({ command, args });
        if (command === 'plugin:event|listen') return args.handler;
        if (command === 'plugin:event|unlisten') return null;
        if (command === 'take_tray_actions') return [];
        if (command === 'file_statuses') return args.paths.map((path:string) => ({path,available:true,error:null,sizeBytes:2048,isDirectory:false}));
        if (command === 'apply_preferences') return null;
        if (command === 'list_gifs') return [];
        if (command === 'get_launch_at_login') return false;
        if (command === 'island_get_preferences') return {swipeEnabled:true,sensitivity:'medium',startupDisplay:'lastUsed'};
        if (command === 'check_updates') return {currentVersion:'0.2.0',latestVersion:null,updateAvailable:false,url:null,checkedAt:new Date().toISOString(),message:'暂无 Windows 更新'};

        if (command === 'read_store') return localStorage.getItem('media-contract-store');
        if (command === 'write_store') { localStorage.setItem('media-contract-store', args.content); return null; }
        if (command === 'island_peer_status') return { installed: false, running: false, compatible: false, detail: '本测试仅模拟媒体会话' };
        if (command === 'media_snapshot') {
          const preferred = args.preferredSourceId ?? null;
          const active = state.players.find(player => player.sourceId === (preferred || 'cloudmusic.exe'));
          const snapshot = {
            available: !!active, sourceId: active?.sourceId || preferred || '', sessionToken: active?.sessionToken || null, playerName: active?.name || '离线播放器',
            playerKind: active?.kind || 'other', sources: structuredClone(state.players),
            title: active?.title || '', artist: active ? '测试歌手' : '', album: '测试专辑',
            playing: active?.playing || false, position: active ? 12 : null, duration: active ? 180 : null, artwork: null,
            canPlayPause: !!active, canNext: !!active, canPrevious: !!active, canSeek: !!active, sampledAt: Date.now(),
            ...(active ? {} : { error: '已固定的播放器当前离线，请打开后播放，或切回自动选择' }),
          };
          if (state.delayedSource === snapshot.sourceId) await new Promise<void>(resolve => state.pendingSnapshots.push(resolve));
          return snapshot;
        }
        if (command === 'media_control') {
          const player = state.players.find(player => player.sourceId === args.sourceId);
          if (!player) throw new Error('指定播放器已经退出');
          if (player.sessionToken !== args.sessionToken) throw new Error('播放器会话已经变化，未执行旧操作');
          if (args.action === 'toggle') player.playing = !player.playing;
          return null;
        }
        if (command === 'lookup_lyrics') {
          if (state.delayedLyricsTitle === args.title) await new Promise<void>(resolve => state.pendingLyrics.push(resolve));
          state.completedLyrics.push(args.title);
          return [{ id: 1, trackName: args.title, artistName: '测试歌手', albumName: '测试专辑', duration: 180,
            instrumental: false, syncedLyrics: `[00:00.00]${args.title}的歌词`, plainLyrics: `${args.title}的歌词` }];
        }
        if (['resize_island', 'configure_window', 'focus_input', 'drag_island', 'confirm_exit'].includes(command)) return null;
        throw new Error(`未约定的命令 ${command}`);
      },
    };
  });
}
async function showMusic(page: Page) {
  await page.goto('/');
  await page.getByRole('button', { name: '展开 XNook', exact: true }).click();
  await page.getByRole('navigation').getByRole('button', { name: '音乐', exact: true }).click();
}
test.beforeEach(async ({ page }) => { await installMediaFixture(page); });

test('手动固定QQ，显示与控制都针对QQ，重启后恢复选择', async ({ page }) => {
  await showMusic(page);
  const picker = page.getByRole('combobox', { name: '播放器', exact: true });
  await expect(picker.locator('option')).toContainText(['自动', '网易云音乐', 'QQ', 'Chrome']);
  await picker.selectOption('QQMusic.exe');
  await expect(page.getByRole('heading', { name: 'QQ 测试歌曲', exact: true })).toBeVisible();
  await expect(page.locator('#save-status')).toHaveText('已保存到本机');
  await page.getByRole('button', { name: '暂停', exact: true }).click();
  const controls = await page.evaluate(() => (window as any).__mediaFixture.calls.filter((c: any) => c.command === 'media_control'));
  expect(controls.at(-1).args).toEqual({ sourceId: 'QQMusic.exe', sessionToken: '22222222-2222-4222-8222-222222222222', action: 'toggle' });
  await showMusic(page);
  await expect(picker).toHaveValue('QQMusic.exe');
  await expect(page.getByRole('heading', { name: 'QQ 测试歌曲', exact: true })).toBeVisible();
  const first = await page.evaluate(() => (window as any).__mediaFixture.calls.find((c: any) => c.command === 'media_snapshot'));
  expect(first.args.preferredSourceId).toBe('QQMusic.exe');
});

test('固定播放器离线不控制其他来源，重新出现后恢复，用户可回到自动', async ({ page }) => {
  await showMusic(page);
  const picker = page.getByRole('combobox', { name: '播放器', exact: true });
  await picker.selectOption('QQMusic.exe');
  await expect(page.getByRole('heading', { name: 'QQ 测试歌曲', exact: true })).toBeVisible();
  await page.evaluate(() => { (window as any).__mediaFixture.players = (window as any).__mediaFixture.players.filter((p: any) => p.sourceId !== 'QQMusic.exe'); });
  await expect(page.locator('#media-panel')).toContainText('离线');
  await expect(picker).toHaveValue('QQMusic.exe');
  await expect(page.getByRole('button', { name: '暂停', exact: true })).toHaveCount(0);
  expect(await page.evaluate(() => (window as any).__mediaFixture.calls.filter((c: any) => c.command === 'media_control'))).toEqual([]);
  await page.evaluate(() => { (window as any).__mediaFixture.players.push({sourceId:'QQMusic.exe',sessionToken:'22222222-2222-4222-8222-222222222222',name:'QQ 音乐',kind:'qqmusic',playing:true,isSystemCurrent:false,title:'QQ 测试歌曲'}); });
  await expect(page.getByRole('heading', { name: 'QQ 测试歌曲', exact: true })).toBeVisible();
  await picker.selectOption('');
  await expect(page.getByRole('heading', { name: '网易测试歌曲', exact: true })).toBeVisible();
});

test('切换期间迟到的旧快照不能恢复旧播放器和旧歌词', async ({ page }) => {
  await showMusic(page);
  await expect(page.getByRole('heading', { name: '网易测试歌曲', exact: true })).toBeVisible();
  await page.evaluate(() => { (window as any).__mediaFixture.delayedSource = 'cloudmusic.exe'; });
  await expect.poll(() => page.evaluate(() => (window as any).__mediaFixture.pendingSnapshots.length)).toBeGreaterThan(0);
  await page.getByRole('combobox', { name: '播放器', exact: true }).selectOption('QQMusic.exe');
  await expect(page.getByRole('heading', { name: '网易测试歌曲', exact: true })).toHaveCount(0);
  await page.evaluate(() => { const f = (window as any).__mediaFixture; f.delayedSource = null; for (const release of f.pendingSnapshots.splice(0)) release(); });
  await expect(page.getByRole('heading', { name: 'QQ 测试歌曲', exact: true })).toBeVisible();
  await expect(page.locator('#lyrics')).toContainText('QQ 测试歌曲的歌词');
  await expect(page.locator('#lyrics')).not.toContainText('网易测试歌曲的歌词');
});

test('没有选择字段的旧设置仍能打开，并在首次写入后保留新字段', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('media-contract-store', JSON.stringify({ version: 1, notes: [], files: [], calendars: [], activeSession: null, history: [],
    settings: { followPointer: true, hideInFullscreen: true, lyricsEnabled: true } })));
  await showMusic(page);
  await expect(page.getByRole('alert')).toHaveCount(0);
  const picker = page.getByRole('combobox', { name: '播放器', exact: true });
  await expect(picker).toHaveValue('');
  await picker.selectOption('QQMusic.exe');
  await expect(page.locator('#save-status')).toHaveText('已保存到本机');
  expect(await page.evaluate(() => JSON.parse(localStorage.getItem('media-contract-store')!).settings.preferredMediaSourceId)).toBe('QQMusic.exe');
});

test('网易歌词迟到时不能覆盖已手选QQ的歌词', async ({ page }) => {
  await page.addInitScript(() => { (window as any).__mediaFixture.delayedLyricsTitle = '网易测试歌曲'; });
  await showMusic(page);
  await expect.poll(() => page.evaluate(() => (window as any).__mediaFixture.pendingLyrics.length)).toBe(1);
  await page.getByRole('combobox', { name: '播放器', exact: true }).selectOption('QQMusic.exe');
  await expect(page.locator('#lyrics')).toContainText('QQ 测试歌曲的歌词');
  await page.evaluate(() => { const f = (window as any).__mediaFixture; for (const release of f.pendingLyrics.splice(0)) release(); });
  await expect.poll(() => page.evaluate(() => (window as any).__mediaFixture.completedLyrics.includes('网易测试歌曲'))).toBe(true);
  await expect(page.locator('#lyrics')).toContainText('QQ 测试歌曲的歌词');
  await expect(page.locator('#lyrics')).not.toContainText('网易测试歌曲的歌词');
});

test('操作播放器下拉框时来源刷新不重建选项，失焦后刷新列表', async ({ page }) => {
  await showMusic(page);
  const picker = page.getByRole('combobox', { name: '播放器', exact: true });
  await picker.focus();
  await picker.locator('option[value="QQMusic.exe"]').evaluate(option => { (option as HTMLElement).dataset.retained = 'yes'; });
  const before = await page.evaluate(() => (window as any).__mediaFixture.calls.filter((c: any) => c.command === 'media_snapshot').length);
  await page.evaluate(() => { (window as any).__mediaFixture.players.push({sourceId:'other.exe',sessionToken:'44444444-4444-4444-8444-444444444444',name:'其他播放器',kind:'other',playing:false,isSystemCurrent:false,title:'其他曲目'}); });
  await expect.poll(() => page.evaluate(() => (window as any).__mediaFixture.calls.filter((c: any) => c.command === 'media_snapshot').length)).toBeGreaterThan(before);
  await expect(picker.locator('option[value="QQMusic.exe"]')).toHaveAttribute('data-retained', 'yes');
  await expect(picker).toBeFocused();
  await picker.blur();
  await expect(picker.locator('option[value="other.exe"]')).toHaveCount(1);
});

test('同名来源的新会话尚未回包时旧按钮不能控制新会话', async ({ page }) => {
  await showMusic(page);
  await page.getByRole('combobox', { name: '播放器', exact: true }).selectOption('QQMusic.exe');
  await expect(page.getByRole('heading', { name: 'QQ 测试歌曲', exact: true })).toBeVisible();
  await page.evaluate(() => {
    const f = (window as any).__mediaFixture;
    f.players.find((p: any) => p.sourceId === 'QQMusic.exe').sessionToken = '55555555-5555-4555-8555-555555555555';
    f.delayedSource = 'QQMusic.exe';
  });
  await expect.poll(() => page.evaluate(() => (window as any).__mediaFixture.pendingSnapshots.length)).toBeGreaterThan(0);
  await page.getByRole('button', { name: '暂停', exact: true }).click();
  await expect(page.locator('#toast')).toContainText('会话已经变化');
  const sent = await page.evaluate(() => (window as any).__mediaFixture.calls.filter((c: any) => c.command === 'media_control').at(-1));
  expect(sent.args.sessionToken).toBe('22222222-2222-4222-8222-222222222222');
  expect(await page.evaluate(() => (window as any).__mediaFixture.players.find((p: any) => p.sourceId === 'QQMusic.exe').playing)).toBe(true);
  await page.evaluate(() => { const f = (window as any).__mediaFixture; f.delayedSource = null; for (const release of f.pendingSnapshots.splice(0)) release(); });
  await expect(page.getByRole('button', { name: '暂停', exact: true })).toHaveAttribute('data-session-token', '55555555-5555-4555-8555-555555555555');
  await page.getByRole('button', { name: '暂停', exact: true }).click();
  await expect(page.getByRole('button', { name: '播放', exact: true })).toBeVisible();
});
