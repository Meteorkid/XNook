import { test } from 'node:test';
import assert from 'node:assert/strict';
import { CollapsePolicy, defaultPreferences, jellyScale, magneticOffset, parsePreferences, protectsPanel, resolvedAppearance, windowSize, type InteractionState } from '../src/preferences';
import { emptyStore } from '../src/domain';
import { parseStore } from '../src/storage';
import { settingsView } from '../src/settings-view';

const idle: InteractionState = { editing: false, composing: false, selection: false, menu: false, dragging: false, fileDrop: false };

test('旧存储在内存补齐偏好，不改正文或独立默认数组', () => {
  const legacy = { ...emptyStore(), settings: { followPointer: true, hideInFullscreen: true, lyricsEnabled: true } };
  const raw = JSON.stringify(legacy);
  const restored = parseStore(raw);
  assert.deepEqual(restored.settings.enabledWidgets, ['media','calendar','notes','files']);
  assert.equal(restored.settings.reminderEnabled, false);
  assert.equal(restored.settings.language, 'auto');
  assert.deepEqual(restored.remindedEvents, []);
  restored.settings.enabledWidgets.pop();
  assert.equal(parseStore(raw).settings.enabledWidgets.length, 4);
  assert.equal(defaultPreferences.enabledWidgets.length, 4);
});

test('偏好拒绝无穷数、越界、分数整数、错误枚举和畸形时间', () => {
  for (const [key, value] of [
    ['panelWidth',159],['panelWidth',1201],['panelHeight',Infinity],['tickerSpeed',NaN],
    ['historyLimit',1.5],['hoverExitDelayMs',-1],['idleCollapseMs',600001],
    ['reminderLeadMinutes',1441],['appearance','blue'],['language','fr'],
    ['jellyIntensity','maximum'],['hoverExpand','true'],['quietHoursStart','24:00'],['quietHoursEnd','7:00'],
    ['enabledWidgets',['media','media']],['enabledWidgets',['flow']],['selectedGifId','../\0test'],
  ] as [string, unknown][]) assert.throws(() => parsePreferences({[key]:value}), /无效/);
  assert.deepEqual(parsePreferences({ enabledWidgets: [], quietHoursStart:'00:00', quietHoursEnd:'23:59', idleCollapseMs:0 }).enabledWidgets, []);
});

test('六项尺寸接受Mac最小值和旧Windows边界，设置表单使用相同范围', () => {
  const settings = emptyStore().settings;
  const form = settingsView(settings, {swipeEnabled:true,sensitivity:'medium',startupDisplay:'lastUsed'}, [], null, false, true);
  for (const [key, min, previousMin, max] of [
    ['panelWidth',160,360,1200],['panelHeight',160,360,1000],['islandWidth',40,180,600],
    ['islandHeight',8,36,120],['lyricsIslandWidth',60,200,800],['lyricsIslandHeight',10,48,160],
  ] as const) {
    for (const size of [min, min + 0.25, previousMin, max]) assert.equal(parsePreferences({[key]:size})[key], size);
    for (const size of [min - 0.01, max + 0.01]) assert.throws(() => parsePreferences({[key]:size}), /无效/);
    assert.match(form, new RegExp(`data-pref="${key}" type="number" min="${min}" max="${max}"`));
  }
  const minimum = { ...settings, islandWidth:40,islandHeight:8,lyricsIslandWidth:60,lyricsIslandHeight:10,panelWidth:160,panelHeight:160 };
  assert.deepEqual(windowSize(minimum,false,false), {width:40,height:8});
  assert.deepEqual(windowSize(minimum,false,true), {width:60,height:10});
  assert.deepEqual(windowSize(minimum,true,false), {width:160,height:160});
  assert.equal(parseStore(JSON.stringify({...emptyStore(),settings:minimum})).settings.islandHeight, 8);
});

test('窗口选择展开、普通收起和歌词收起尺寸；系统主题按系统状态解析', () => {
  const settings = { ...defaultPreferences, panelWidth:720,panelHeight:640,islandWidth:240,islandHeight:44,lyricsIslandWidth:420,lyricsIslandHeight:80 };
  assert.deepEqual(windowSize(settings,true,true), {width:720,height:640});
  assert.deepEqual(windowSize(settings,false,false), {width:240,height:44});
  assert.deepEqual(windowSize(settings,false,true), {width:420,height:80});
  assert.equal(resolvedAppearance('system',false), 'light');
  assert.equal(resolvedAppearance('system',true), 'dark');
  assert.equal(resolvedAppearance('dark',false), 'dark');
  assert.equal(resolvedAppearance('light',true), 'light');
});

test('果冻强度逐级向内形变，磁吸和形变合成不会越过真实窗口', () => {
  assert.equal(jellyScale('off'), 1);
  assert.ok(jellyScale('low') < 1 && jellyScale('low') > jellyScale('medium') && jellyScale('medium') > jellyScale('high'));
  for (const frame of [40,60,160,180,200,300,360,600,800]) {
    for (const width of [frame - 12,frame - 2,frame]) {
      for (const pointer of [-10000,-frame/2,0,frame/2,10000]) {
        const offset = magneticOffset(pointer,frame,width);
        for (const intensity of ['off','low','medium','high'] as const) {
          for (const scale of [1,jellyScale(intensity),.995]) {
            assert.ok(frame/2 + offset - width*scale/2 >= -1e-9);
            assert.ok(frame/2 + offset + width*scale/2 <= frame+1e-9);
          }
        }
      }
    }
  }
  assert.equal(magneticOffset(1000,300,298),1);
  assert.equal(magneticOffset(-1000,300,298),-1);
  assert.equal(magneticOffset(1000,300,300),0);
  assert.equal(magneticOffset(1000,300,301),0);
  assert.equal(magneticOffset(NaN,300,288),0);
});

test('编辑、输入法、选择、菜单、窗口和文件拖动均保护面板', () => {
  assert.equal(protectsPanel(idle), false);
  for (const key of Object.keys(idle)) assert.equal(protectsPanel({...idle,[key]:true}), true, key);
});

test('离开计时在返回、编辑和重新展开时归零；0关闭自动收起', () => {
  const policy = new CollapsePolicy();
  assert.equal(policy.update(1000,false,true,false,200), false);
  assert.equal(policy.update(1199,false,true,false,200), false);
  assert.equal(policy.update(1200,false,true,false,200), true);
  assert.equal(policy.update(1300,true,true,false,200), false);
  assert.equal(policy.update(2000,false,true,false,200), false);
  assert.equal(policy.update(2300,false,true,true,200), false);
  assert.equal(policy.update(2400,false,true,false,200), false);
  assert.equal(policy.update(2500,false,false,false,200), false);
  assert.equal(policy.update(2900,false,true,false,200), false);
  policy.reset();
  assert.equal(policy.update(3900,false,true,false,200), false);
  assert.equal(policy.update(10000,false,true,false,0), false);
  assert.equal(policy.update(20000,false,true,false,0), false);
});
