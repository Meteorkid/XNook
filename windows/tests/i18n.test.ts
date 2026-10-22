import { test } from 'node:test';
import assert from 'node:assert/strict';
import { html, language, locale, setLanguage, t } from '../src/i18n';
import { settingsView } from '../src/settings-view';
import { emptyStore } from '../src/domain';

test('自动语言识别中文地区；显式语言覆盖系统且可切回', () => {
  setLanguage('auto','zh-TW'); assert.equal(language(),'zh'); assert.equal(locale(),'zh-CN');
  setLanguage('auto','ja-JP'); assert.equal(language(),'en');
  setLanguage('zh','en-US'); assert.equal(t('设置'),'设置');
  setLanguage('en','zh-CN'); assert.equal(t('设置'),'Settings'); assert.equal(locale(),'en-US');
  setLanguage('auto','zh-CN');
});

test('模板仅翻译固定界面文案，插入的笔记/文件/曲目同名词保持原文', () => {
  setLanguage('en');
  const userTitle='音乐', userContent='设置\n日历\n播放', file='C:\\笔记\\文件架.txt';
  const value = html`<h1>笔记</h1><p>${userTitle}</p><textarea>${userContent}</textarea><small>${file}</small><button aria-label="打开播放器">播放</button>`;
  assert.equal(value, '<h1>Notes</h1><p>音乐</p><textarea>设置\n日历\n播放</textarea><small>C:\\笔记\\文件架.txt</small><button aria-label="Open player">Play</button>');
  setLanguage('zh'); assert.equal(html`<h1>笔记</h1><p>${userTitle}</p>`, '<h1>笔记</h1><p>音乐</p>');
});

test('设置界面翻译主要分组但不翻译用户GIF文件名，锁定状态阻止本地写入', () => {
  setLanguage('en');
  const settings=emptyStore().settings; settings.selectedGifId='custom.gif';
  const rendered=settingsView(settings,{swipeEnabled:true,sensitivity:'medium',startupDisplay:'lastUsed'},[{id:'custom.gif',name:'音乐与设置.gif'}],null,true,false);
  assert.match(rendered,/Appearance and language/);assert.match(rendered,/Calendar and reminders/);
  assert.match(rendered,/value="custom.gif" selected>音乐与设置.gif/);
  assert.match(rendered,/data-pref="appearance" disabled/);
  assert.match(rendered,/data-shared="sensitivity" disabled/);
  assert.match(rendered,/Check updates/);assert.match(rendered,/Back up and reset/);
  setLanguage('auto','zh-CN');
});
