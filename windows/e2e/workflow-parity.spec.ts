import { test, expect, type Page } from '@playwright/test';
import { installParityFixture } from './parity-fixture';

const calls=(page:Page,command:string)=>page.evaluate(name=>(window as any).__parity.calls.filter((item:any)=>item.command===name),command);
const saved=(page:Page)=>page.evaluate(()=>JSON.parse(localStorage.getItem('parity-store')!));
async function open(page:Page){await page.goto('/');await page.getByRole('button',{name:'展开 XNook',exact:true}).click();}
async function nav(page:Page,name:string){await page.getByRole('navigation').getByRole('button',{name,exact:true}).click();}
const session=(index:number)=>({id:`task-${index}`,title:`历史任务 ${index}`,startedAt:new Date(Date.UTC(2026,9,1,0,index)).toISOString(),endedAt:new Date(Date.UTC(2026,9,1,1,index)).toISOString(),eventId:null,scheduledEndAt:null,linkedNote:null,linkedFiles:[]});
const source=(body:string)=>({id:'calendar',name:'课程.ics',path:'C:\\课程.ics',importedAt:'2026-10-17T00:00:00.000Z',content:`BEGIN:VCALENDAR\r\nVERSION:2.0\r\n${body}\r\nEND:VCALENDAR\r\n`});
const event=(id:string,start:string,end:string,title:string)=>`BEGIN:VEVENT\r\nUID:${id}\r\nDTSTART:${start}\r\nDTEND:${end}\r\nSUMMARY:${title}\r\nEND:VEVENT`;

test('概览直接开始空名任务、结束、媒体控制与新建笔记',async({page})=>{
  await installParityFixture(page);await open(page);
  await page.locator('#flow-start-form button').click();
  await expect(page.locator('.session-active')).toContainText('未命名任务');
  await page.getByRole('button',{name:'结束任务',exact:true}).click();
  expect((await saved(page)).history).toHaveLength(1);
  await page.locator('#overview-media-controls').getByRole('button',{name:'暂停',exact:true}).click();
  expect((await calls(page,'media_control')).at(-1).args).toMatchObject({sourceId:'cloudmusic.exe',sessionToken:'11111111-1111-4111-8111-111111111111',action:'toggle'});
  await expect(page.locator('#overview-media-controls').getByRole('button',{name:'播放',exact:true})).toBeVisible();
  await page.getByRole('button',{name:'新建笔记',exact:true}).click();
  await expect(page.getByRole('textbox',{name:'笔记标题',exact:true})).toBeFocused();
});

test('全部历史可翻到最早记录，详情显示真实起止并幂等恢复笔记',async({page})=>{
  const history=Array.from({length:43},(_,i)=>session(i));
  const first={...history[0],linkedNote:{id:'deleted-note',title:'原笔记',content:'原始快照'}};history[0]=first as any;
  await installParityFixture(page,{store:{history},settings:{historyLimit:1}});await open(page);await nav(page,'NookFlow');
  await expect(page.locator('.session-card')).toHaveCount(1);
  await page.getByRole('button',{name:'全部历史',exact:true}).click();
  await expect(page.locator('.session-card')).toHaveCount(20);
  await page.getByRole('button',{name:'下一页',exact:true}).click();await page.getByRole('button',{name:'下一页',exact:true}).click();
  await expect(page.locator('.session-card')).toHaveCount(3);
  await page.locator('.session-card').filter({has:page.getByRole('heading',{name:'历史任务 0',exact:true})}).getByRole('button',{name:'查看详情',exact:true}).click();
  await expect(page.locator('.session-times')).toContainText('开始：');await expect(page.locator('.session-times')).toContainText('结束：');
  await page.getByRole('button',{name:'原笔记',exact:true}).click();await expect(page.getByRole('textbox',{name:'笔记内容',exact:true})).toHaveValue('原始快照');
  await page.getByRole('textbox',{name:'笔记内容',exact:true}).fill('恢复后的编辑');
  await expect.poll(async()=> (await saved(page)).notes[0].content).toBe('恢复后的编辑');
  await nav(page,'NookFlow');await page.getByRole('button',{name:'原笔记',exact:true}).click();
  await expect(page.getByRole('textbox',{name:'笔记内容',exact:true})).toHaveValue('恢复后的编辑');
  expect((await saved(page)).notes).toHaveLength(1);expect((await saved(page)).history[0].linkedNote.content).toBe('原始快照');
});

test('长按新建快捷键不连续创建，编辑器仍保留原草稿',async({page})=>{
  await installParityFixture(page);await open(page);
  await page.keyboard.press('Control+n');await expect(page.getByRole('textbox',{name:'笔记内容',exact:true})).toBeVisible();
  await page.getByRole('textbox',{name:'笔记内容',exact:true}).fill('保留草稿');
  await page.getByRole('textbox',{name:'笔记内容',exact:true}).dispatchEvent('keydown',{key:'n',ctrlKey:true,repeat:true,bubbles:true});
  await expect.poll(async()=> (await saved(page)).notes.length).toBe(1);
  await expect(page.getByRole('textbox',{name:'笔记内容',exact:true})).toHaveValue('保留草稿');
});

test('概览过滤今日已结束，详情完整显示且按来源标记',async({page})=>{
  await page.clock.setFixedTime(new Date('2026-10-17T10:00:00+08:00'));
  const calendar=source([event('old','20261017T000000Z','20261017T010000Z','已经结束'),event('now','20261017T013000Z','20261017T023000Z','正在进行'),event('next','20261017T030000Z','20261017T040000Z','稍后安排')].join('\r\n'));
  await installParityFixture(page,{store:{calendars:[calendar]},settings:{autoRefreshCalendars:false}});await open(page);
  await expect(page.locator('.overview-agenda .event')).toHaveCount(2);await expect(page.locator('.overview-agenda')).not.toContainText('已经结束');
  await expect(page.locator('.overview-agenda')).toContainText('进行中');await nav(page,'日历');
  await expect(page.locator('.agenda .event')).toHaveCount(3);await expect(page.locator('.agenda [data-event-status="ended"]')).toContainText('已经结束');
  await expect(page.locator('.agenda .event-source').first()).toHaveText('课程.ics');
});

test('月历前溢日与跨日点标记完整，自动刷新保留同一个事件焦点',async({page})=>{
  await page.clock.setFixedTime(new Date('2026-10-17T10:00:00+08:00'));
  const calendar=source([event('aug','20260831T010000Z','20260831T020000Z','八月最后一天'),event('span','20261016T150000Z','20261017T160000Z','跨日日程'),event('two','20261017T030000Z','20261017T040000Z','第二条日程')].join('\r\n'));
  await installParityFixture(page,{store:{calendars:[calendar]},settings:{autoRefreshCalendars:false}});await open(page);await nav(page,'日历');
  await expect(page.locator('[data-action="day:2026-10-17"] i')).toHaveCount(1);await expect(page.locator('[data-action="day:2026-10-18"] i')).toHaveCount(0);
  const second=page.locator('.agenda [data-action="event-flow"]').nth(1);await second.focus();const identity=await second.getAttribute('data-id');
  await page.evaluate(()=>(window as any).__parity.emit('calendar-tick'));
  await expect(page.locator('.agenda [data-action="event-flow"]:focus')).toHaveAttribute('data-id',identity!);
  await page.getByRole('button',{name:'上个月',exact:true}).click();await page.locator('[data-action="day:2026-08-31"]').click();
  await expect(page.locator('.agenda')).toContainText('八月最后一天');await expect(page.locator('[data-action="day:2026-08-31"] i')).toHaveCount(1);
});

test('从历史页离开后启动日程，显示新活跃任务而非旧历史状态',async({page})=>{
  await page.clock.setFixedTime(new Date('2026-10-17T10:00:00+08:00'));
  await installParityFixture(page,{store:{history:[session(0)],calendars:[source(event('next','20261017T030000Z','20261017T040000Z','新日程'))]},settings:{autoRefreshCalendars:false}});await open(page);
  await page.getByRole('button',{name:'全部历史',exact:true}).click();await nav(page,'概览');
  await page.locator('.overview-agenda').getByRole('button',{name:'开始专注',exact:true}).click();
  await expect(page.locator('.session-active')).toContainText('新日程');await expect(page.getByRole('button',{name:'结束任务',exact:true})).toBeVisible();
});

test('文件状态逐项失败可恢复，慢刷新期间添加文件会续跑',async({page})=>{
  const file={id:'old',path:'C:\\旧文件.pdf',name:'旧文件.pdf',isDirectory:false,addedAt:'2026-10-17T00:00:00.000Z'};
  await installParityFixture(page,{store:{files:[file]}});await open(page);
  await page.evaluate(()=>{const state=(window as any).__parity;state.unavailablePaths=['C:\\旧文件.pdf'];state.statusGate=new Promise<void>(resolve=>state.releaseStatuses=resolve);});
  await nav(page,'文件架');await page.getByRole('button',{name:'添加文件',exact:true}).click();
  await page.evaluate(()=>{const state=(window as any).__parity;state.statusGate=null;state.releaseStatuses();});
  await expect(page.locator('.file-row[data-available="false"]')).toContainText('旧文件.pdf');
  await expect(page.locator('.file-row[data-available="true"]')).toContainText('2.0 KiB');
  expect((await saved(page)).files).toHaveLength(2);
  await page.evaluate(()=>{(window as any).__parity.unavailablePaths=[];});
  await page.getByRole('button',{name:'刷新文件状态',exact:true}).click();await expect(page.locator('.file-row[data-available="true"]')).toHaveCount(2);
});

test('收起药丸横拖不误展开，向下拖动可展开',async({page})=>{
  await installParityFixture(page);await page.goto('/');const pill=page.locator('.pill-open');let box=(await pill.boundingBox())!;
  await page.mouse.move(box.x+25,box.y+20);await page.mouse.down();await page.mouse.move(box.x+70,box.y+20,{steps:5});await page.mouse.up();
  await expect(page.locator('.panel')).toBeHidden();
  await expect.poll(async()=> (await calls(page,'drag_island')).at(-1)?.args.phase).toBe('end');
  expect((await calls(page,'drag_island')).map((call:any)=>call.args.phase)).toEqual(expect.arrayContaining(['begin','update','end']));
  box=(await pill.boundingBox())!;await page.mouse.move(box.x+25,box.y+10);await page.mouse.down();await page.mouse.move(box.x+25,box.y+35,{steps:4});await page.mouse.up();
  await expect(page.locator('.panel')).toBeVisible();
});

test('展开横滚不切岛，收起手势仍会调用联动',async({page})=>{
  await installParityFixture(page);await open(page);
  await page.locator('#content').dispatchEvent('wheel',{deltaX:200,deltaY:0,bubbles:true});expect(await calls(page,'switch_island')).toEqual([]);
  await page.getByRole('button',{name:'收起面板',exact:true}).click();
  await page.locator('.pill').dispatchEvent('wheel',{deltaX:200,deltaY:0,bubbles:true});
  await expect.poll(async()=> (await calls(page,'switch_island')).length).toBe(1);
});

test('药丸右键和托盘动作打开设置，退出仍走保存保护',async({page})=>{
  await installParityFixture(page);await page.goto('/');
  await page.locator('.pill-open').click({button:'right'});await expect(page.getByRole('menu')).toBeVisible();
  await page.getByRole('menuitem',{name:'设置',exact:true}).click();await expect(page.locator('[data-pref="appearance"]')).toBeVisible();
  await page.getByRole('button',{name:'收起面板',exact:true}).click();
  await page.evaluate(()=>{const state=(window as any).__parity;state.trayActions.push('checkUpdates');state.emit('tray-actions-pending');});
  await expect(page.locator('.panel')).toBeVisible();await expect.poll(async()=> (await calls(page,'check_updates')).some((call:any)=>call.args.force===true)).toBe(true);
  await page.getByRole('button',{name:'收起面板',exact:true}).click();await page.evaluate(()=>{(window as any).__parity.failWrite=true;});
  await page.locator('.pill-open').click({button:'right'});await page.getByRole('menuitem',{name:'退出 XNook',exact:true}).click();
  await expect(page.locator('#exit-dialog')).toBeVisible();expect(await calls(page,'confirm_exit')).toEqual([]);
});

test('短内容收缩高度，长设置滚动且未提交任务草稿不被刷新清空',async({page})=>{
  await installParityFixture(page,{settings:{panelHeight:900,enabledWidgets:[],showHistory:false}});await open(page);
  await expect.poll(async()=> (await calls(page,'resize_island')).at(-1)?.args.height).toBeLessThan(900);
  await page.locator('#flow-title').fill('尚未提交的任务');await page.evaluate(()=>(window as any).__parity.emit('calendar-tick'));
  await expect(page.locator('#flow-title')).toHaveValue('尚未提交的任务');await expect(page.locator('#flow-title')).toBeFocused();
  await page.getByRole('button',{name:'打开设置',exact:true}).click();
  await expect.poll(async()=> (await calls(page,'resize_island')).at(-1)?.args.height).toBe(900);
  expect(await page.locator('#content').evaluate(element=>element.scrollHeight>element.clientHeight)).toBe(true);
});

test('同曲三次网络失败后可自动恢复歌词，暂停时收起歌词隐藏',async({page})=>{
  await page.clock.install({time:new Date('2026-10-17T10:00:00+08:00')});
  await installParityFixture(page,{failLyrics:true,settings:{showTicker:false}});await open(page);await nav(page,'音乐');
  await page.clock.runFor(4500);await expect(page.locator('#lyrics')).toContainText('歌词暂不可用');
  expect((await calls(page,'lookup_lyrics')).length).toBe(3);
  await page.evaluate(()=>{(window as any).__parity.failLyrics=false;});await page.clock.runFor(15000);
  await expect(page.locator('#lyrics')).toContainText('正在播放的歌词');
  await page.getByRole('button',{name:'收起面板',exact:true}).click();await expect(page.locator('.pill-ticker')).toBeVisible();
  await page.getByRole('button',{name:'展开 XNook',exact:true}).click();await nav(page,'音乐');await page.getByRole('button',{name:'暂停',exact:true}).click();
  await page.getByRole('button',{name:'收起面板',exact:true}).click();await expect(page.locator('.pill-ticker')).toBeHidden();
});
