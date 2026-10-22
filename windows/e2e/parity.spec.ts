import { test, expect, type Page } from '@playwright/test';
import { installParityFixture, reminderCalendar } from './parity-fixture';

async function open(page:Page){await page.goto('/');await page.getByRole('button',{name:'展开 XNook',exact:true}).click();}
async function settings(page:Page){await page.getByRole('button',{name:'打开设置',exact:true}).click();}
async function nav(page:Page,name:string){await page.getByRole('navigation').getByRole('button',{name,exact:true}).click();}
const calls=(page:Page,command:string)=>page.evaluate(c=>(window as any).__parity.calls.filter((x:any)=>x.command===c),command);
const saved=(page:Page)=>page.evaluate(()=>JSON.parse(localStorage.getItem('parity-store')!));

for (const width of [180,300,600]) test(`真实 ${width}px 窗口内果冻和磁吸不裁切`,async({page})=>{
  await page.setViewportSize({width,height:52});await page.emulateMedia({reducedMotion:'no-preference'});
  await installParityFixture(page,{settings:{islandWidth:width,jellyIntensity:'high',showTicker:false,lyricsEnabled:false,magnetic:true}});
  await page.goto('/');await expect(page.locator('.island')).toHaveCSS('width',`${width-12}px`);
  const frames=await page.evaluate(async()=>{
    const root=document.querySelector('#app')!, island=document.querySelector('.island')!;
    root.dispatchEvent(new PointerEvent('pointerenter'));
    await new Promise<void>(resolve=>requestAnimationFrame(()=>requestAnimationFrame(()=>resolve())));
    const animation=island.getAnimations().find(item=>(item as CSSAnimation).animationName==='island-jelly');
    if (!animation) throw new Error('果冻动画未启动');
    animation.pause();
    const frames=[];
    for (const x of [1,innerWidth-1]) {
      root.dispatchEvent(new PointerEvent('pointermove',{clientX:x,clientY:20}));
      for (const time of [0,75,150,250,325,410,499]) {
        animation.currentTime=time;
        const rect=island.getBoundingClientRect();frames.push({left:rect.left,right:rect.right,width:rect.width});
      }
    }
    return frames;
  });
  for (const frame of frames) {expect(frame.left).toBeGreaterThanOrEqual(-.01);expect(frame.right).toBeLessThanOrEqual(width+.01);}
  expect(Math.min(...frames.map(frame=>frame.width))).toBeLessThan(width-15);
});

test('深浅主题、尺寸和英文界面可持久化，用户笔记不被翻译',async({page})=>{
  await installParityFixture(page);await open(page);await nav(page,'笔记');
  await page.getByRole('button',{name:'新建笔记',exact:true}).click();
  await page.getByRole('textbox',{name:'笔记标题',exact:true}).fill('音乐');
  await page.getByRole('textbox',{name:'笔记内容',exact:true}).fill('设置\n日历\n用户原文保留');
  await settings(page);
  await page.locator('[data-pref="appearance"]').selectOption('light');
  await expect(page.locator('html')).toHaveAttribute('data-appearance','light');
  await page.locator('[data-pref="panelWidth"]').fill('720');await page.locator('[data-pref="panelWidth"]').blur();
  await expect.poll(async()=> (await saved(page)).settings.panelWidth).toBe(720);
  await expect(page.locator('.island')).toHaveCSS('width','708px');
  await page.locator('[data-pref="language"]').selectOption('en');
  await expect(page.getByRole('navigation').getByRole('button',{name:'Notes',exact:true})).toBeVisible();
  await page.getByRole('navigation').getByRole('button',{name:'Notes',exact:true}).click();
  await expect(page.getByRole('textbox',{name:'Note title',exact:true})).toHaveValue('音乐');
  await expect(page.getByRole('textbox',{name:'Note content',exact:true})).toHaveValue('设置\n日历\n用户原文保留');
  await page.reload();await page.getByRole('button',{name:'Expand XNook',exact:true}).click();
  await expect(page.locator('html')).toHaveAttribute('data-appearance','light');
  expect((await saved(page)).settings.panelWidth).toBe(720);
});

test('工具开关、登录项、虚拟桌面失败回滚和共享联动偏好走真实界面合同',async({page})=>{
  await installParityFixture(page);await open(page);await settings(page);
  await page.locator('[data-widget="files"]').uncheck();
  await expect(page.getByRole('navigation').getByRole('button',{name:'文件架',exact:true})).toHaveCount(0);
  await page.locator('[data-pref="launchAtLogin"]').check();
  await expect.poll(async()=> (await saved(page)).settings.launchAtLogin).toBe(true);
  expect((await calls(page,'set_launch_at_login')).at(-1).args.enabled).toBe(true);
  await page.evaluate(()=>{(window as any).__parity.failVirtualDesktop=true;});
  await page.locator('[data-pref="visibleOnAllDesktops"]').click();
  await expect(page.locator('#toast')).toContainText('不支持虚拟桌面');
  await expect(page.locator('[data-pref="visibleOnAllDesktops"]')).not.toBeChecked();
  await page.locator('[data-shared="swipeEnabled"]').uncheck();
  await page.locator('[data-shared="sensitivity"]').selectOption('high');
  await page.locator('[data-shared="startupDisplay"]').selectOption('xisland');
  await expect.poll(async()=> (await calls(page,'island_set_preferences')).at(-1)?.args.preferences).toEqual({swipeEnabled:false,sensitivity:'high',startupDisplay:'xisland'});
});

test('收起歌词、点击封面打开播放器、文件复制和拖出绑定正确原生参数',async({page})=>{
  await installParityFixture(page);await open(page);await nav(page,'音乐');
  await expect(page.locator('#lyrics')).toContainText('正在播放的歌词');
  await page.locator('[data-action="media-open"]').click();
  expect((await calls(page,'open_media_player')).at(-1).args).toEqual({sourceId:'cloudmusic.exe',sessionToken:'11111111-1111-4111-8111-111111111111'});
  await page.getByRole('button',{name:'收起面板',exact:true}).click();
  await expect(page.locator('.pill-ticker')).toBeVisible();
  await expect(page.locator('.pill-ticker')).toContainText('正在播放的歌词');
  await page.getByRole('button',{name:'展开 XNook',exact:true}).click();await nav(page,'文件架');
  await page.getByRole('button',{name:'添加文件',exact:true}).click();
  await page.getByRole('button',{name:'复制文件',exact:true}).click();
  expect((await calls(page,'copy_files')).at(-1).args.paths).toEqual(['C:\\资料\\课程.pdf']);
  const drag=page.getByRole('button',{name:'拖出文件',exact:true});const box=await drag.boundingBox();
  await page.mouse.move(box!.x+box!.width/2,box!.y+box!.height/2);await page.mouse.down();await page.mouse.move(box!.x+box!.width/2+15,box!.y+box!.height/2+15);await page.mouse.up();
  await expect.poll(async()=> (await calls(page,'start_file_drag')).length).toBe(1);
});

test('损坏存储先明确确认并备份，再恢复可编辑空数据',async({page})=>{
  await installParityFixture(page,{corrupt:true});await open(page);
  await page.locator('.storage-block [data-action="store-recover"]').click();
  const dialog=page.locator('#confirmation-dialog');await expect(dialog).toBeVisible();
  expect(await calls(page,'recover_store')).toEqual([]);
  await dialog.locator('[data-action="confirm-action"]').click();
  await expect(page.locator('.storage-block')).toHaveCount(0);
  expect(await page.evaluate(()=>(window as any).__parity.backup)).toBe('{broken original');
  await nav(page,'笔记');await expect(page.getByRole('button',{name:'新建笔记',exact:true})).toBeEnabled();
  await settings(page);await page.getByRole('button',{name:'查看备份',exact:true}).click();
  expect((await calls(page,'reveal_file')).at(-1).args.path).toBe('C:\\XNook\\store-backup.json');
});

test('GIF导入和删除只操作应用副本，减少动态效果停止动画',async({page})=>{
  await installParityFixture(page);await open(page);await settings(page);
  await page.getByRole('button',{name:'导入 GIF',exact:true}).click();
  await expect.poll(async()=> (await saved(page)).settings.selectedGifId).toBe('22222222-2222-4222-8222-222222222222');
  await page.locator('[data-pref="reduceMotion"]').check();
  await page.getByRole('button',{name:'收起面板',exact:true}).click();
  await expect(page.locator('.pill img[src^="data:image/gif"]')).toHaveCount(0);
  await page.getByRole('button',{name:'展开 XNook',exact:true}).click();await settings(page);
  await page.getByRole('button',{name:'删除所选 GIF',exact:true}).click();
  await page.locator('#confirmation-dialog [data-action="confirm-action"]').click();
  await expect.poll(async()=> (await calls(page,'delete_gif')).length).toBe(1);
});

test('原生日历tick自动刷新ICS，声音失败不消费提醒，成功后去重',async({page})=>{
  await page.clock.setFixedTime(new Date('2026-10-17T10:00:00+08:00'));
  await installParityFixture(page,{settings:{reminderEnabled:true}});await open(page);await nav(page,'日历');
  await page.getByRole('button',{name:'导入 .ics',exact:true}).click();
  await expect.poll(async()=> (await saved(page)).calendars.length).toBe(1);
  await page.evaluate(()=>{(window as any).__parity.failSound=true;(window as any).__parity.emit('calendar-tick');});
  await expect.poll(async()=> (await calls(page,'play_reminder_sound')).length).toBe(1);
  expect((await saved(page)).remindedEvents).toEqual([]);
  await page.evaluate(()=>{(window as any).__parity.failSound=false;(window as any).__parity.emit('calendar-tick');});
  await expect.poll(async()=> (await saved(page)).remindedEvents.length).toBe(1);
  await page.evaluate(()=>(window as any).__parity.emit('calendar-tick'));
  expect((await calls(page,'play_reminder_sound')).length).toBe(2);
  await page.clock.setFixedTime(new Date('2026-10-17T10:01:01+08:00'));
  await page.evaluate(text=>{(window as any).__parity.calendarText=text;(window as any).__parity.emit('calendar-tick');},reminderCalendar('更新后的讨论'));
  await expect.poll(async()=> (await saved(page)).calendars[0].content).toContain('更新后的讨论');
});

test('勿扰期间不发提醒，检查更新仅打开发布页而不安装',async({page})=>{
  await page.clock.setFixedTime(new Date('2026-10-17T10:00:00+08:00'));
  await installParityFixture(page,{settings:{reminderEnabled:true,quietHoursEnabled:true,quietHoursStart:'00:00',quietHoursEnd:'23:59'}});await open(page);await nav(page,'日历');
  await page.getByRole('button',{name:'导入 .ics',exact:true}).click();
  await expect.poll(async()=> (await saved(page)).calendars.length).toBe(1);
  await page.evaluate(()=>(window as any).__parity.emit('calendar-tick'));
  await expect.poll(async()=> (await calls(page,'read_calendar')).length).toBeGreaterThan(0);
  expect(await calls(page,'play_reminder_sound')).toEqual([]);
  await settings(page);await page.getByRole('button',{name:'检查更新',exact:true}).click();
  await expect(page.getByRole('button',{name:'打开发布页',exact:true})).toBeDisabled();
  await page.evaluate(()=>{(window as any).__parity.update={currentVersion:'0.3.1',latestVersion:'0.4.0',updateAvailable:true,url:'https://github.com/Meteorkid/XNook/releases/tag/windows-v0.4.0',checkedAt:new Date().toISOString(),message:'发现 Windows 新版本'};});
  await page.getByRole('button',{name:'检查更新',exact:true}).click();
  await expect(page.getByRole('button',{name:'打开发布页',exact:true})).toBeEnabled();
  await page.getByRole('button',{name:'打开发布页',exact:true}).click();expect((await calls(page,'open_update_page')).length).toBe(1);
});

test('悬停展开不抢焦点，移出收起；编辑中的笔记受到保护',async({page})=>{
  await installParityFixture(page,{settings:{hoverExpand:true,hoverExitDelayMs:100,idleCollapseMs:300}});
  await page.goto('/');
  await page.getByRole('button',{name:'展开 XNook',exact:true}).hover();
  await expect(page.locator('.panel')).toBeVisible();
  expect(await calls(page,'focus_input')).toEqual([]);
  await page.locator('#app').dispatchEvent('pointerleave');
  await expect(page.locator('.panel')).toBeHidden();
  await page.getByRole('button',{name:'展开 XNook',exact:true}).click();await nav(page,'笔记');
  await page.getByRole('button',{name:'新建笔记',exact:true}).click();
  await page.getByRole('textbox',{name:'笔记内容',exact:true}).fill('正在编辑，不应自动收起');
  await page.locator('#app').dispatchEvent('pointerleave');
  await page.waitForTimeout(600);
  await expect(page.locator('.panel')).toBeVisible();
  await expect(page.getByRole('textbox',{name:'笔记内容',exact:true})).toHaveValue('正在编辑，不应自动收起');
});

test('纵向手势能展开收起，但不会抢走内容区域的滚动',async({page})=>{
  await installParityFixture(page);await page.goto('/');
  await page.locator('.pill').dispatchEvent('wheel',{deltaY:80,deltaX:0,bubbles:true});
  await expect(page.locator('.panel')).toBeVisible();
  await settings(page);
  await page.locator('#content').evaluate(el=>{el.scrollTop=150;});
  await page.waitForTimeout(750);
  await page.locator('#content').dispatchEvent('wheel',{deltaY:-80,deltaX:0,bubbles:true});
  await expect(page.locator('.panel')).toBeVisible();
  await page.locator('#content').evaluate(el=>{el.scrollTop=0;});
  await page.locator('#content').dispatchEvent('wheel',{deltaY:-80,deltaX:0,bubbles:true});
  await expect(page.locator('.panel')).toBeHidden();
});

test('自动更新成功后24小时再检查，关闭开关后不继续发请求',async({page})=>{
  await page.clock.setFixedTime(new Date('2026-10-17T10:00:00+08:00'));
  await installParityFixture(page);await open(page);
  await expect.poll(async()=> (await calls(page,'check_updates')).length).toBe(1);
  await page.clock.setFixedTime(new Date('2026-10-17T11:00:00+08:00'));
  await page.evaluate(()=>(window as any).__parity.emit('calendar-tick'));
  expect((await calls(page,'check_updates')).length).toBe(1);
  await page.clock.setFixedTime(new Date('2026-10-18T10:00:01+08:00'));
  await page.evaluate(()=>(window as any).__parity.emit('calendar-tick'));
  await expect.poll(async()=> (await calls(page,'check_updates')).length).toBe(2);
  await settings(page);await page.locator('[data-pref="autoCheckUpdates"]').uncheck();
  await expect.poll(async()=> (await saved(page)).settings.autoCheckUpdates).toBe(false);
  await page.clock.setFixedTime(new Date('2026-10-19T11:00:01+08:00'));
  await page.evaluate(()=>(window as any).__parity.emit('calendar-tick'));
  expect((await calls(page,'check_updates')).length).toBe(2);
});
