import type { Settings } from './domain';
import type { GifInfo, IslandPreferences, UpdateStatus } from './bridge';
import { t } from './i18n';
const escape = (value: unknown): string => String(value).replace(/[&<>"']/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' })[c]!);
export function settingsView(settings: Settings, shared: IslandPreferences, gifs: GifInfo[], update: UpdateStatus | null, blocked: boolean, sharedReady: boolean, backupPath: string | null = null): string {
  const disabled = blocked ? ' disabled' : '';
  const row = (label: string, english: string, control: string, help = '') => `<label class="setting"><span><b>${t(label, english)}</b>${help ? `<small>${help}</small>` : ''}</span>${control}</label>`;
  const check = (key: keyof Settings, label: string, english: string, help = '') => row(label, english, `<input id="setting-${key}" data-pref="${key}" type="checkbox" ${settings[key] ? 'checked' : ''}${disabled}>`, help);
  const number = (key: keyof Settings, label: string, english: string, min: number, max: number, step = 1) => row(label, english, `<input class="setting-number" data-pref="${key}" type="number" min="${min}" max="${max}" step="${step}" value="${settings[key]}"${disabled}>`);
  const select = (key: keyof Settings, label: string, english: string, options: [string,string,string][]) => row(label, english, `<select data-pref="${key}"${disabled}>${options.map(([value,zh,en]) => `<option value="${value}" ${settings[key] === value ? 'selected' : ''}>${t(zh,en)}</option>`).join('')}</select>`);
  const section = (label: string, english: string, content: string) => `<details class="preference-section" open><summary>${t(label,english)}</summary><div class="settings-group">${content}</div></details>`;
  const button = (action: string, zh: string, en: string, attrs = '') => `<button class="subtle" data-action="${action}" ${attrs}>${t(zh,en)}</button>`;
  return `<div class="section-heading"><div><span class="eyebrow">MAKE IT YOURS</span><h1>${t('让岛适应你的习惯')}</h1></div></div>`
    + section('外观与语言','Appearance and language', select('appearance','外观','Appearance',[['dark','深色','Dark'],['light','浅色','Light'],['system','跟随系统','System']])
      + select('language','语言','Language',[['auto','跟随系统','System'],['zh','中文','中文'],['en','English','English']])
      + check('reduceMotion','减少动态效果','Reduce motion') + select('jellyIntensity','果冻强度','Jelly intensity',[['off','关闭','Off'],['low','低','Low'],['medium','中','Medium'],['high','高','High']])
      + check('magnetic','鼠标靠近时轻微吸附','Magnetic hover') + check('hideCursor','悬停时隐藏光标','Hide cursor while hovering'))
    + section('窗口尺寸','Window dimensions', number('islandWidth','药丸宽度','Island width',40,600) + number('islandHeight','药丸高度','Island height',8,120)
      + number('lyricsIslandWidth','歌词药丸宽度','Ticker island width',60,800) + number('lyricsIslandHeight','歌词药丸高度','Ticker island height',10,160)
      + number('panelWidth','面板宽度','Panel width',160,1200) + number('panelHeight','面板最大高度','Maximum panel height',160,1000))
    + section('面板与交互','Panel and interaction', ['media','calendar','notes','files'].map((id,i) => row(['音乐','日历','笔记','文件架'][i],['Music','Calendar','Notes','Files'][i], `<input data-widget="${id}" type="checkbox" ${settings.enabledWidgets.includes(id as never) ? 'checked' : ''}${disabled}>`)).join('')
      + check('showHistory','显示任务历史','Show focus history') + number('historyLimit','历史显示条数','History entries',1,20)
      + check('hoverExpand','悬停展开','Expand on hover') + check('scrollExpand','上下滑动展开与收起','Swipe down to expand, up to collapse')
      + number('hoverExitDelayMs','悬停移出收起延迟（毫秒）','Hover exit delay (ms)',0,10000)
      + number('idleCollapseMs','空闲收起延迟（毫秒，0 关闭）','Idle collapse delay (ms, 0 disables)',0,600000))
    + section('歌词与 GIF','Lyrics and GIF', check('lyricsEnabled','同步歌词','Synchronized lyrics',t('联网查询 LRCLIB，发送曲名、歌手、专辑和时长'))
      + check('showTicker','显示收起曲目信息','Show collapsed track information') + number('tickerSpeed','跑马灯速度（像素/秒）','Ticker speed (px/s)',1,200)
      + row('当前 GIF','Selected GIF', `<select data-pref="selectedGifId"${disabled}><option value="">${t('默认波形','Default waveform')}</option>${gifs.map(gif => `<option value="${escape(gif.id)}" ${settings.selectedGifId === gif.id ? 'selected' : ''}>${escape(gif.name)}</option>`).join('')}</select>`)
      + `<div class="settings-actions">${button('gif-import','导入 GIF','Import GIF',disabled)}${button('gif-delete','删除所选 GIF','Delete selected GIF', !settings.selectedGifId || blocked ? 'disabled' : '')}</div>`)
    + section('日历与提醒','Calendar and reminders', check('autoRefreshCalendars','自动刷新本地日历','Refresh local calendars automatically')
      + check('reminderEnabled','播放日历提醒音','Play calendar reminders') + number('reminderLeadMinutes','提前提醒分钟数','Reminder lead (minutes)',0,1440)
      + select('reminderSound','提醒声音','Reminder sound',[['default','默认','Default'],['asterisk','提示','Asterisk'],['exclamation','注意','Exclamation']])
      + `<div class="settings-actions">${button('reminder-test','试听提醒音','Preview reminder sound')}</div>`
      + check('quietHoursEnabled','启用勿扰时段','Enable quiet hours')
      + row('勿扰开始','Quiet hours start',`<input data-pref="quietHoursStart" type="time" value="${settings.quietHoursStart}"${disabled}>`)
      + row('勿扰结束','Quiet hours end',`<input data-pref="quietHoursEnd" type="time" value="${settings.quietHoursEnd}"${disabled}>`))
    + section('系统与更新','System and updates', check('followPointer','跟随鼠标所在显示器','Follow pointer display') + check('hideInFullscreen','全屏应用时隐藏','Hide for fullscreen apps')
      + check('visibleOnAllDesktops','所有虚拟桌面可见','Visible on all virtual desktops') + check('launchAtLogin','登录时启动','Launch at login')
      + check('autoCheckUpdates','自动检查更新','Check for updates automatically')
      + `<div class="update-summary">${update ? escape(update.message) : t('尚未检查更新','Updates have not been checked')}</div><div class="settings-actions">${button('updates-check','检查更新','Check updates')}${button('updates-open','打开发布页','Open release page', update?.url ? '' : 'disabled')}</div>`)
    + section('双岛联动','Island switching', row('启用横滑切换','Enable horizontal switching',`<input data-shared="swipeEnabled" type="checkbox" ${shared.swipeEnabled ? 'checked' : ''} ${sharedReady ? '' : 'disabled'}>`)
      + row('切换灵敏度','Swipe sensitivity',`<select data-shared="sensitivity" ${sharedReady ? '' : 'disabled'}>${[['low','低','Low'],['medium','中','Medium'],['high','高','High']].map(([v,z,e])=>`<option value="${v}" ${shared.sensitivity===v?'selected':''}>${t(z,e)}</option>`).join('')}</select>`)
      + row('启动显示','Show on startup',`<select data-shared="startupDisplay" ${sharedReady ? '' : 'disabled'}>${[['lastUsed','上次使用','Last used'],['xnook','XNook','XNook'],['xisland','XIsland','XIsland']].map(([v,z,e])=>`<option value="${v}" ${shared.startupDisplay===v?'selected':''}>${t(z,e)}</option>`).join('')}</select>`)
      + `<p class="hint" id="peer-detail"></p><div class="settings-actions">${button('switch','切换到 XIsland','Switch to XIsland')}</div>`)
    + section('数据与恢复','Data and recovery',`<p class="hint">${t('读取失败时会保护原件。恢复操作先备份，再创建空数据。','Read failures protect the original file. A reset backs it up before creating an empty store.')}</p><div class="settings-actions">${button('store-reload','重新读取','Read again')}${button('store-recover','备份并恢复为空数据','Back up and reset')}${backupPath ? button('store-backup','查看备份','Show backup',`title="${escape(backupPath)}"`) : ''}</div>`)
    + `<div class="about"><b>XNook <span>0.3.2 · ${t('Windows 预览版')}</span></b><p>${t('音乐、日程、灵感和文件，安放在桌面的一角。')}</p></div>`;
}
