import { test, expect, type Page } from '@playwright/test';
import { installParityFixture } from './parity-fixture';

const saved=(page:Page)=>page.evaluate(()=>JSON.parse(localStorage.getItem('parity-store')!));
const calls=(page:Page,command:string)=>page.evaluate(name=>(window as any).__parity.calls.filter((item:any)=>item.command===name),command);

for (const size of [{width:40,height:8,ticker:false},{width:60,height:10,ticker:true}]) {
  test(`${size.width}×${size.height} 最小药丸能点击展开且不越界`,async({page})=>{
    await page.setViewportSize({width:size.width,height:size.height});
    await installParityFixture(page,{settings:{islandWidth:40,islandHeight:8,lyricsIslandWidth:60,lyricsIslandHeight:10,lyricsEnabled:size.ticker,showTicker:size.ticker}});
    await page.goto('/');
    await expect(page.locator('#app')).toHaveAttribute('data-squashed','true');
    const rect=(await page.locator('.island').boundingBox())!;
    expect(rect.x).toBeGreaterThanOrEqual(0);expect(rect.x+rect.width).toBeLessThanOrEqual(size.width);expect(rect.y+rect.height).toBeLessThanOrEqual(size.height);
    await page.getByRole('button',{name:'展开 XNook',exact:true}).click();
    await expect.poll(async()=> (await calls(page,'resize_island')).at(-1)?.args.expanded).toBe(true);
  });
}

test('160像素窄面板用下拉导航，笔记可编辑、保存和删除撤销',async({page})=>{
  await page.setViewportSize({width:160,height:590});
  await installParityFixture(page,{settings:{panelWidth:160,panelHeight:590}});await page.goto('/');
  await page.getByRole('button',{name:'展开 XNook',exact:true}).click();
  await expect(page.getByRole('combobox',{name:'选择工具',exact:true})).toBeVisible();
  await page.getByRole('combobox',{name:'选择工具',exact:true}).selectOption('notes');
  await page.getByRole('button',{name:'新建笔记',exact:true}).click();
  await page.getByRole('textbox',{name:'笔记标题',exact:true}).fill('窄窗口笔记');
  await page.getByRole('textbox',{name:'笔记内容',exact:true}).fill('可以编辑、滚动并保留中文草稿。');
  await expect.poll(async()=> (await saved(page)).notes[0].content).toBe('可以编辑、滚动并保留中文草稿。');
  await page.getByRole('button',{name:'删除',exact:true}).click();await page.getByRole('button',{name:'撤销删除',exact:true}).click();
  await expect(page.getByRole('textbox',{name:'笔记内容',exact:true})).toHaveValue('可以编辑、滚动并保留中文草稿。');
  expect(await page.locator('#content').evaluate(element=>element.scrollWidth<=element.clientWidth)).toBe(true);
});

test('160×160面板设置可滚动，恢复确认对话框可取消',async({page})=>{
  await page.setViewportSize({width:160,height:160});
  await installParityFixture(page,{settings:{panelWidth:160,panelHeight:160}});await page.goto('/');
  await page.getByRole('button',{name:'展开 XNook',exact:true}).click();await page.getByRole('button',{name:'打开设置',exact:true}).click();
  await expect.poll(async()=> (await calls(page,'resize_island')).at(-1)?.args.height).toBe(160);
  await page.locator('[data-pref="language"]').selectOption('en');
  await expect(page.getByRole('combobox',{name:'Choose tool',exact:true})).toBeVisible();
  await page.getByRole('button',{name:'Back up and reset',exact:true}).click();await expect(page.locator('#confirmation-dialog')).toBeVisible();
  await page.locator('#confirmation-dialog').getByRole('button',{name:'Cancel',exact:true}).click();
  await expect(page.locator('#confirmation-dialog')).toHaveCount(0);expect(await calls(page,'recover_store')).toEqual([]);
});

test('40像素药丸右键时为菜单扩宽宿主，关闭后恢复原尺寸',async({page})=>{
  await page.setViewportSize({width:40,height:8});
  await installParityFixture(page,{settings:{islandWidth:40,islandHeight:8,lyricsEnabled:false,showTicker:false}});await page.goto('/');
  await page.getByRole('button',{name:'展开 XNook',exact:true}).click({button:'right'});
  await expect.poll(async()=> (await calls(page,'resize_island')).at(-1)?.args.width).toBe(220);
  await page.setViewportSize({width:220,height:108});await expect(page.getByRole('menu')).toBeVisible();
  const menu=(await page.getByRole('menu').boundingBox())!;expect(menu.x).toBeGreaterThanOrEqual(0);expect(menu.x+menu.width).toBeLessThanOrEqual(220);expect(menu.y+menu.height).toBeLessThanOrEqual(108);
  await page.keyboard.press('Escape');await expect.poll(async()=> (await calls(page,'resize_island')).at(-1)?.args).toMatchObject({width:40,height:8,expanded:false});
});
