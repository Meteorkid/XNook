import { test } from 'node:test';
import assert from 'node:assert/strict';
import { panelShortcut } from '../src/keyboard';
const key = (value: string) => ({ key: value, ctrlKey: true, metaKey: false, altKey: false, shiftKey: false, isComposing: false });
test('Ctrl+0..4 对应概览和四个工具，Ctrl+N 新建笔记，Ctrl+S 保存', () => {
  assert.deepEqual(['0', '1', '2', '3', '4', 'n', 's'].map(value => panelShortcut(key(value), true)),
    ['overview', 'media', 'calendar', 'notes', 'files', 'new-note', 'save']);
});
test('中文输入、收起状态和其他修饰组合不触发快捷键', () => {
  assert.equal(panelShortcut(key('n'), false), null);
  assert.equal(panelShortcut({ ...key('n'), isComposing: true }, true), null);
  assert.equal(panelShortcut({ ...key('n'), altKey: true }, true), null);
  assert.equal(panelShortcut({ ...key('n'), shiftKey: true }, true), null);
  assert.equal(panelShortcut({ ...key('1'), ctrlKey: false }, true), null);
});
test('Ctrl+Z/Y 不被拦截，Escape 仅不带修饰键时生效', () => {
  assert.equal(panelShortcut(key('z'), true), null);
  assert.equal(panelShortcut(key('y'), true), null);
  assert.equal(panelShortcut({ ...key('Escape'), ctrlKey: false }, true), 'escape');
  assert.equal(panelShortcut(key('Escape'), true), null);
});
test('按住快捷键只在首次按下执行，重复事件不新建、保存或切换界面', () => {
  for (const value of ['0', '1', '2', '3', '4', 'n', 's']) {
    assert.notEqual(panelShortcut({ ...key(value), repeat: false }, true), null);
    assert.equal(panelShortcut({ ...key(value), repeat: true }, true), null);
  }
  assert.equal(panelShortcut({ ...key('Escape'), ctrlKey: false, repeat: true }, true), null);
  assert.equal(panelShortcut({ ...key('n'), ctrlKey: false, metaKey: true }, true), 'new-note');
});
