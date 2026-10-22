import { test, expect, type Page } from '@playwright/test';
import { installParityFixture } from './parity-fixture';

async function expand(page: Page): Promise<void> { await page.getByRole('button', {name:'展开 XNook',exact:true}).click(); }
async function navigate(page: Page, name: string): Promise<void> { if(name==='设置') await page.locator('[data-action="view:settings"]').click(); else await page.getByRole('navigation').getByRole('button', {name,exact:true}).click(); }
async function quit(page: Page): Promise<void> {
  if (await page.locator('.panel').isVisible()) await page.locator('[data-action="collapse"]').click();
  await page.locator('.pill').click({button:'right'});
  await page.locator('[data-action="safe-exit"]').click();
}
const snapshot = (page: Page) => page.evaluate(() => JSON.parse((window as any).__parity.content));
const calls = (page: Page, name: string) => page.evaluate(command => (window as any).__parity.calls.filter((call:any) => call.command===command), name);

test('首次胶囊右键退出经过原生开始请求、保存、确认，托盘路径同样保持', async ({page}) => {
  await installParityFixture(page); await page.goto('/');
  await expect.poll(async () => (await calls(page,'plugin:event|listen')).some((call:any)=>call.args.event==='request-exit')).toBe(true);
  await quit(page);
  await expect.poll(() => page.evaluate(() => (window as any).__parity.exitState)).toBe('authorized');
  const ordered=await page.evaluate(() => (window as any).__parity.calls.map((call:any)=>call.command));
  expect(ordered.indexOf('begin_exit')).toBeLessThan(ordered.indexOf('write_store'));
  expect(ordered.indexOf('write_store')).toBeLessThan(ordered.indexOf('confirm_exit'));
  expect(await page.evaluate(() => (window as any).__parity.nativeForceDialogs)).toBe(0);
  await page.reload(); await expect.poll(async () => (await calls(page,'plugin:event|listen')).some((call:any)=>call.args.event==='request-exit')).toBe(true);
  await page.evaluate(() => (window as any).__parity.requestExit());
  await expect.poll(() => page.evaluate(() => (window as any).__parity.exitState)).toBe('authorized');
  expect(await calls(page,'begin_exit')).toHaveLength(0);
});

test('保存失败可取消并继续编辑，再次退出不会误开强退，重试保存后完成', async ({page}) => {
  await installParityFixture(page); await page.goto('/'); await expand(page); await navigate(page,'笔记');
  await page.getByRole('button',{name:'新建笔记',exact:true}).click(); await expect(page.locator('#save-status')).toHaveText('已保存到本机');
  await page.evaluate(() => { (window as any).__parity.failWrite=true; });
  await page.locator('#note-content').fill('仍保留的编辑草稿'); await quit(page);
  await expect(page.locator('#exit-dialog')).toBeVisible(); expect(await calls(page,'confirm_exit')).toHaveLength(0);
  await page.locator('[data-action="exit-continue"]').click();
  await expect.poll(() => page.evaluate(() => (window as any).__parity.exitState)).toBe('idle');
  await expect(page.locator('#note-content')).toHaveValue('仍保留的编辑草稿');
  await quit(page); await expect(page.locator('#exit-dialog')).toBeVisible();
  await page.evaluate(() => { (window as any).__parity.failWrite=false; });
  await page.locator('[data-action="exit-retry"]').click();
  await expect.poll(() => page.evaluate(() => (window as any).__parity.exitState)).toBe('authorized');
  expect((await snapshot(page)).notes[0].content).toBe('仍保留的编辑草稿');
  expect(await page.evaluate(() => (window as any).__parity.nativeForceDialogs)).toBe(0);
});

test('放弃未保存草稿需要第二次明确确认，磁盘原件保持', async ({page}) => {
  await installParityFixture(page); await page.goto('/'); await expand(page); await navigate(page,'笔记');
  await page.getByRole('button',{name:'新建笔记',exact:true}).click(); await expect(page.locator('#save-status')).toHaveText('已保存到本机');
  const original=await snapshot(page);
  await page.evaluate(() => { (window as any).__parity.failWrite=true; });
  await page.locator('#note-content').fill('明确放弃的修改'); await quit(page);
  await page.locator('[data-action="exit-discard"]').click(); expect(await calls(page,'confirm_exit')).toHaveLength(0);
  await expect(page.locator('#exit-dialog')).toContainText('确认放弃');
  await page.locator('[data-action="exit-discard-confirm"]').click();
  await expect.poll(() => page.evaluate(() => (window as any).__parity.exitState)).toBe('authorized');
  expect(await snapshot(page)).toEqual(original);
});

for (const first of ['preference','source'] as const) test(`设置和播放器选择交错：${first}先发起，最终UI与保存一致`, async ({page}) => {
  await installParityFixture(page,{settings:{preferredMediaSourceId:'cloudmusic.exe'}}); await page.goto('/'); await expand(page);
  const hold = async (kind:'preference'|'write') => page.evaluate(kind => {
    const state=(window as any).__parity;
    state[`${kind}Gate`]=new Promise<void>(resolve=>{state.releaseGate=resolve;});
  },kind);
  if(first==='preference') {
    await navigate(page,'设置'); await hold('preference');
    await page.locator('[data-pref="followPointer"]').uncheck();
    await expect.poll(async () => (await calls(page,'apply_preferences')).at(-1)?.args.settings.followPointer).toBe(false);
    await navigate(page,'音乐'); await page.locator('#media-source-select').selectOption('');
  } else {
    await navigate(page,'音乐'); await hold('write'); await page.locator('#media-source-select').selectOption('');
    await navigate(page,'设置'); await page.locator('[data-pref="followPointer"]').uncheck();
  }
  await page.evaluate(() => { const state=(window as any).__parity;state.preferenceGate=null;state.writeGate=null;state.releaseGate(); });
  await expect.poll(async () => (await snapshot(page)).settings.followPointer).toBe(false);
  await expect.poll(async () => (await snapshot(page)).settings.preferredMediaSourceId).toBe(null);
  await navigate(page,'音乐'); await expect(page.locator('#media-source-select')).toHaveValue('');
  await page.reload(); await expand(page); await navigate(page,'音乐'); await expect(page.locator('#media-source-select')).toHaveValue('');
});

test('大笔记关联超限保留活动任务，明确删除历史后可以关联并保存', async ({page}) => {
  const stamp='2026-10-17T00:00:00.000Z', content='a'.repeat(6*1024*1024);
  const note={id:'large-note',title:'大笔记',content,createdAt:stamp,updatedAt:stamp};
  const session={id:'active',title:'保留当前任务',startedAt:stamp,endedAt:null,eventId:null,scheduledEndAt:null,linkedNote:null,linkedFiles:[]};
  const history={...session,id:'history',title:'已有快照',endedAt:stamp,linkedNote:{id:note.id,title:note.title,content}};
  await installParityFixture(page,{memoryStore:true,store:{notes:[note],activeSession:session,history:[history]}});
  await page.goto('/'); await expand(page); await navigate(page,'笔记');
  await page.locator('[data-action="note-link"]').click(); await expect(page.locator('#toast')).toContainText('16 MiB');
  expect((await snapshot(page)).activeSession.linkedNote).toBeNull();
  await navigate(page,'NookFlow'); await page.locator('[data-action="flow-history-delete"]').click();
  await expect(page.locator('#confirmation-dialog')).toContainText('源笔记和磁盘文件会保留');
  await page.locator('[data-action="cancel-action"]').click(); expect((await snapshot(page)).history).toHaveLength(1);
  await page.locator('[data-action="flow-history-delete"]').click(); await page.locator('[data-action="confirm-action"]').click();
  await expect.poll(async ()=>(await snapshot(page)).history.length).toBe(0);
  await navigate(page,'笔记'); await page.locator('[data-action="note-link"]').click();
  await expect.poll(async ()=>(await snapshot(page)).activeSession.linkedNote?.id).toBe('large-note');
  expect((await snapshot(page)).notes[0].content.length).toBe(content.length);
  expect((await snapshot(page)).activeSession.title).toBe('保留当前任务');
});

test('隐藏窗口的100ms时钟不查询DOM，稳定跑马灯不重复写样式', async ({page}) => {
  await page.clock.install(); await installParityFixture(page); await page.goto('/');
  await expect(page.locator('#pill-ticker-text')).toContainText('正在播放的歌词');
  await page.evaluate(() => {
    const state=(window as any).__parity; state.tickerWrites=0; state.clockQueries=0;
    const set=CSSStyleDeclaration.prototype.setProperty;
    CSSStyleDeclaration.prototype.setProperty=function(name,value,priority){if(name.startsWith('--ticker-'))state.tickerWrites++;return set.call(this,name,value,priority);};
    const query=Document.prototype.querySelector;
    Document.prototype.querySelector=function(selector:string){if(['#media-position','#media-seek','#pill-ticker-text'].includes(selector))state.clockQueries++;return query.call(this,selector);};
  });
  await page.clock.runFor(800);
  expect(await page.evaluate(()=>(window as any).__parity.tickerWrites)).toBe(0);
  await page.evaluate(() => { Object.defineProperty(document,'hidden',{configurable:true,value:true});document.dispatchEvent(new Event('visibilitychange'));(window as any).__parity.clockQueries=0; });
  await page.clock.runFor(800);
  expect(await page.evaluate(()=>(window as any).__parity.clockQueries)).toBe(0);
});

test('同批1100项提醒失败不消费，成功只响一次并跨下轮完整去重', async ({page}) => {
  await page.clock.install({time:new Date('2026-10-18T02:00:00Z')});
  const content=['BEGIN:VCALENDAR','VERSION:2.0',...Array.from({length:1100},(_,i)=>`BEGIN:VEVENT\r\nUID:batch-${i}\r\nDTSTART:20261018T020400Z\r\nDTEND:20261018T030000Z\r\nSUMMARY:批量事件${i}\r\nEND:VEVENT`),'END:VCALENDAR',''].join('\r\n');
  await installParityFixture(page,{settings:{autoRefreshCalendars:false,reminderEnabled:true,reminderLeadMinutes:5},store:{calendars:[{id:'batch',name:'批量.ics',path:'C:\\batch.ics',content,importedAt:'2026-10-18T01:00:00.000Z'}]}});
  await page.addInitScript(()=>{(window as any).__parity.failSound=true;});
  await page.goto('/');
  await expect.poll(async ()=>(await calls(page,'play_reminder_sound')).length).toBe(1);
  expect((await snapshot(page)).remindedEvents).toEqual([]);
  await expect(page.locator('#toast')).toContainText('声音设备失败');
  await page.evaluate(()=>{const state=(window as any).__parity;state.failSound=false;state.emit('calendar-tick');});
  await expect.poll(async ()=>(await snapshot(page)).remindedEvents.length).toBe(1100);
  expect(await calls(page,'play_reminder_sound')).toHaveLength(2);
  await page.clock.runFor(31000);
  expect(await calls(page,'play_reminder_sound')).toHaveLength(2);
});
