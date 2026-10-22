import { test, expect, type Page } from '@playwright/test';
import { readFile } from 'node:fs/promises';

const previewKey = 'xnook:browser-development-preview:v1';
async function openPanel(page: Page) {
  await page.goto('/');
  await page.getByRole('button', { name: '展开 XNook', exact: true }).click();
  await expect(page.getByRole('navigation', { name: '工具导航' })).toBeVisible();
}
async function navigate(page: Page, name: string) {
  await page.getByRole('navigation', { name: '工具导航' }).getByRole('button', { name, exact: true }).click();
}
const calendar = `BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//XNook//Acceptance//ZH\r\nBEGIN:VEVENT\r\nUID:xnook-test-day\r\nDTSTART;VALUE=DATE:20261017\r\nDTEND;VALUE=DATE:20261018\r\nSUMMARY:整理课程资料\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n`;

test('空状态与全部工具可用，浏览器预览不伪装原生能力', async ({ page }) => {
  const errors: string[] = [];
  page.on('pageerror', error => errors.push(error.message));
  await openPanel(page);
  await expect(page.locator('#retry-save')).toBeHidden();
  await expect(page.getByText('浏览器开发预览 · 数据仅保存在此浏览器 · 系统功能需 Windows 客户端')).toBeVisible();
  for (const name of ['音乐', '日历', '笔记', '文件架', 'NookFlow', '概览']) await navigate(page, name);
  await page.getByRole('button', { name: '打开设置' }).click();
  await expect(page.getByText('开发预览不连接 XIsland', { exact: true })).toBeVisible();
  await page.locator('#content [data-action="switch"]').click();
  await expect(page.locator('#toast')).toContainText('此操作需要 Windows 客户端');
  await expect(page.locator('.panel')).toBeVisible();
  expect(errors).toEqual([]);
});

test('中文笔记保存、重启恢复、搜索、导出与撤销删除', async ({ page }) => {
  await openPanel(page);
  await navigate(page, '笔记');
  await page.getByRole('button', { name: '新建笔记', exact: true }).click();
  await page.getByRole('textbox', { name: '笔记标题', exact: true }).fill('Windows 联动测试');
  const content = '# 中文笔记\n\n保留原文、Markdown 和 <script> 字符。';
  await page.getByRole('textbox', { name: '笔记内容', exact: true }).fill(content);
  await expect(page.locator('#save-status')).toHaveText('已保存到本机');
  await page.reload();
  await page.getByRole('button', { name: '展开 XNook', exact: true }).click();
  await navigate(page, '笔记');
  await expect(page.getByRole('textbox', { name: '笔记内容', exact: true })).toHaveValue(content);
  await page.getByRole('searchbox', { name: '搜索笔记' }).fill('保留原文');
  await expect(page.locator('.note-item')).toHaveCount(1);
  const downloadPromise = page.waitForEvent('download');
  await page.getByRole('button', { name: '导出 Markdown', exact: true }).click();
  const download = await downloadPromise;
  expect(await readFile((await download.path())!, 'utf8')).toBe(content);
  await page.getByRole('button', { name: '删除', exact: true }).click();
  await expect(page.locator('.note-item')).toHaveCount(0);
  await page.getByRole('button', { name: '撤销删除', exact: true }).click();
  await expect(page.getByRole('textbox', { name: '笔记内容', exact: true })).toHaveValue(content);
});

test('真实 ICS 文件导入后可从日程启动任务并保存到历史', async ({ page }) => {
  await page.clock.setFixedTime(new Date('2026-10-17T10:00:00+08:00'));
  await openPanel(page);
  await navigate(page, '日历');
  await page.locator('#ics-input').setInputFiles({ name: '课程.ics', mimeType: 'text/calendar', buffer: Buffer.from(calendar) });
  await expect(page.locator('.agenda')).toContainText('整理课程资料');
  await expect(page.locator('.event-time')).toHaveText('全天');
  await page.getByRole('button', { name: '开始专注', exact: true }).click();
  await expect(page.locator('.session-active')).toContainText('整理课程资料');
  await page.getByRole('button', { name: '结束任务', exact: true }).click();
  await expect(page.locator('.session-active')).toHaveCount(0);
  await expect(page.locator('.session-card')).toContainText('整理课程资料');
  await page.reload();
  await page.getByRole('button', { name: '展开 XNook', exact: true }).click();
  await navigate(page, 'NookFlow');
  await expect(page.locator('.session-card')).toContainText('整理课程资料');
});

test('损坏存储保持原样，界面明确禁用编辑', async ({ page }) => {
  await page.addInitScript(({ key }) => localStorage.setItem(key, '{broken'), { key: previewKey });
  await openPanel(page);
  await expect(page.getByRole('alert')).toContainText('已阻止覆盖原件');
  await navigate(page, '笔记');
  await expect(page.getByRole('button', { name: '新建笔记', exact: true })).toBeDisabled();
  await navigate(page, '日历');
  await expect(page.getByRole('button', { name: '导入 .ics', exact: true })).toBeDisabled();
  expect(await page.evaluate(key => localStorage.getItem(key), previewKey)).toBe('{broken');
});

test('导入无效 ICS 不破坏已有日历', async ({ page }) => {
  await page.clock.setFixedTime(new Date('2026-10-17T10:00:00+08:00'));
  await openPanel(page);
  await navigate(page, '日历');
  await page.locator('#ics-input').setInputFiles({ name: '课程.ics', mimeType: 'text/calendar', buffer: Buffer.from(calendar) });
  await expect(page.locator('.agenda')).toContainText('整理课程资料');
  const before = await page.evaluate(key => localStorage.getItem(key), previewKey);
  await page.locator('#ics-input').setInputFiles({ name: '错误.ics', mimeType: 'text/calendar', buffer: Buffer.from('not a calendar') });
  await expect(page.locator('#toast')).toBeVisible();
  expect(await page.evaluate(key => localStorage.getItem(key), previewKey)).toBe(before);
  await expect(page.locator('.agenda')).toContainText('整理课程资料');
});

test('窄窗口可导航和编辑，保存时不打断输入法组合输入', async ({ page }) => {
  await page.setViewportSize({ width: 360, height: 680 });
  await openPanel(page);
  await navigate(page, '笔记');
  await page.getByRole('button', { name: '新建笔记', exact: true }).click();
  const editor = page.getByRole('textbox', { name: '笔记内容', exact: true });
  await editor.focus();
  await editor.dispatchEvent('compositionstart');
  await editor.fill('正在输入中文');
  await editor.dispatchEvent('compositionend', { data: '正在输入中文' });
  await expect(editor).toHaveValue('正在输入中文');
  await expect(page.locator('#save-status')).toHaveText('已保存到本机');
  expect(await editor.evaluate(element => document.activeElement === element)).toBe(true);
  const box = await editor.boundingBox();
  expect(box!.x + box!.width).toBeLessThanOrEqual(360);
});
