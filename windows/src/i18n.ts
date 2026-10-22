import type { Preferences } from './preferences';
let preference: Preferences['language'] = 'auto';
let systemLanguage = typeof navigator === 'undefined' ? 'zh-CN' : navigator.language;
export function setLanguage(value: Preferences['language'], system = systemLanguage): void { preference = value; systemLanguage = system; }
export function language(): 'zh' | 'en' { return preference === 'auto' ? systemLanguage.toLowerCase().startsWith('zh') ? 'zh' : 'en' : preference; }
export const locale = (): string => language() === 'zh' ? 'zh-CN' : 'en-US';
const en: Record<string, string> = {
  '打开播放器':'Open player','打开日历':'Open calendar','自定义 GIF':'Custom GIF','进行中':'In progress','正在检查 XIsland…':'Checking XIsland…',
  '存储受保护，暂时无法恢复笔记快照':'Storage is protected; note snapshots cannot be restored yet.',
  '存储受保护，暂时不能保存播放器选择':'Storage is protected; player selection cannot be saved yet.',
  'XNook 启动失败：':'XNook could not start: ',
  '概览':'Overview','音乐':'Music','日历':'Calendar','笔记':'Notes','文件架':'Files','设置':'Settings','播放器':'Player',
  'XNook 工具面板':'XNook tools','展开 XNook':'Expand XNook','切换到 XIsland':'Switch to XIsland','切换中…':'Switching…','打开设置':'Open settings','收起面板':'Collapse panel','拖动窗口':'Drag window','工具导航':'Tools',
  '浏览器开发预览 · 数据仅保存在此浏览器 · 系统功能需 Windows 客户端':'Browser preview · Isolated browser storage · System features require Windows',
  '留一点空间给自己':'A little room for yourself','把此刻，放在眼前。':'Keep this moment close.','一次，只专注一件事':'One thing at a time','把日程、笔记和文件留在同一个任务里。':'Keep your schedule, notes and files together.',
  '继续':'Continue','开始':'Start','正在进行':'In progress','正在播放':'Playing','等待音乐响起':'Waiting for music','连接 Windows 系统媒体会话':'Connect a Windows media player',
  '接下来的日程':'Up next','今天，留点空白':'A little room in your day','未来 90 天没有待办日程':'No upcoming events in the next 90 days','导入本地 .ics 日历':'Import a local .ics calendar','全天':'All day','随手记':'Quick notes',
  ' 篇笔记，想法随时落笔':' notes · Capture an idea',' 个文件，拖入即刻收好':' files · Your temporary workspace',
  '自动选择':'Automatic','系统当前':'System current','离线':'Offline','浏览器开发预览不连接系统播放器。':'Browser preview does not connect to system players.',
  '所选播放器暂不可用，将保留选择，不控制其他播放器。':'The selected player is unavailable. Your selection stays fixed; other players are not controlled.',
  '自动优先正在播放的网易云音乐和 QQ 音乐。':'Automatic mode prioritizes playing NetEase Cloud Music and QQ Music sessions.',
  '已固定 ':'Pinned: ','所选播放器':'Selected player','所选播放器暂未连接':'Selected player is offline','音乐，随你而来':'Your music, close at hand',
  '打开所选播放器并开始播放。连接恢复后会继续读取这个播放器，不会自动换到其他软件。':'Open the selected player and start playback. XNook will reconnect to it without switching to another player.',
  '打开网易云音乐、QQ 音乐或其他支持 Windows 系统媒体控制的播放器并开始播放。未公开媒体会话的客户端暂时无法检测。':'Start playback in NetEase Cloud Music, QQ Music, or another Windows media player. Players must expose a system media session to be detected.',
  '回到自动选择':'Return to automatic','未知曲目':'Unknown track','未知艺术家':'Unknown artist','专辑封面':'Album cover','播放进度':'Playback position','上一首':'Previous track','下一首':'Next track','暂停':'Pause','播放':'Play','歌词':'Lyrics',
  '歌词已关闭，可在设置中开启。':'Lyrics are disabled in settings.','没有找到匹配歌词':'No matching lyrics found','纯音乐 · 让旋律自己说话':'Instrumental · Let the music speak','暂无歌词':'No lyrics available','正在寻找歌词…':'Looking for lyrics…','没有找到可靠匹配的歌词':'No reliable lyric match found',
  '为今天留出时间':'Make room for today','导入 .ics':'Import .ics','上个月':'Previous month','下个月':'Next month','回到今天':'Today','开始专注':'Start focus','这一天还没有日程':'No events for this day','给自己一点自由的时间。':'Leave yourself a little free time.',
  '导入':'Import','刷新':'Refresh','移除':'Remove','只读取你选择的本地 .ics 文件；重新导入同一路径会更新日程。':'Only selected .ics files are read. Reimport the same path to update its events.',
  '接住一闪而过的想法':'Catch a passing thought','新建笔记':'New note','搜索笔记…':'Search notes…','搜索笔记':'Search notes','未命名笔记':'Untitled note','笔记标题':'Note title','笔记内容':'Note content','从这里开始写…':'Start writing here…',
  '导出 Markdown':'Export Markdown','关联任务':'Link to focus','删除':'Delete','留下一个想法':'Save an idea','选择一篇笔记，继续上次的思路。':'Choose a note and pick up your thought.','笔记自动保存到本机，支持 Markdown 原文导出。':'Notes save locally and can be exported as Markdown.','写第一篇笔记':'Write your first note',
  '撤销删除':'Undo delete','已删除「':'Deleted “','」':'”','还没有内容':'No content yet','没有匹配的笔记':'No matching notes','你的笔记会出现在这里':'Your notes will appear here',
  '常用文件，触手可及':'Your files within reach','添加文件':'Add files','把文件拖到岛上':'Drop files onto the island','保留原位置，随时打开或定位文件':'Files stay in their original location','打开':'Open','定位':'Reveal','复制文件':'Copy files','拖出文件':'Drag files out',
  '移除文件引用不会删除磁盘原文件。任务历史保留独立文件快照。':'Removing a reference leaves the original file untouched. Focus history keeps its own file snapshots.',
  '文件架还是空的。添加文件后，这里就是你的临时工作台。':'Your shelf is empty. Add files to start a temporary workspace.',
  '让思路停留在任务里':'Keep your thoughts with the task',' 次完成':' completed','现在，想专注什么？':'What would you like to focus on?','例如：完成项目方案':'For example: finish a project proposal',
  '从日历启动，或在这里开始一个新任务。':'Start from a calendar event or create a focus here.','任务记录':'Focus history','完成的任务会留在这里，笔记和文件关联也会一起保存。':'Completed focuses stay here with their linked notes and files.',
  '结束任务':'Finish focus','再次开始':'Start again','计划结束 ':'Scheduled end: ','打开任务笔记':'Open focus note','创建任务笔记':'Create focus note','关联文件架':'Link shelf files',
  '让岛适应你的习惯':'Make the island yours','跟随鼠标所在显示器':'Follow pointer display','展开和恢复时定位到当前工作屏幕':'Use your current display when expanding or restoring',
  '全屏应用时隐藏':'Hide for fullscreen apps','退出全屏后恢复当前拥有显示权的岛':'Restore the island that owns the display after fullscreen',
  '同步歌词':'Synchronized lyrics','联网查询 LRCLIB，发送曲名、歌手、专辑和时长':'Query LRCLIB using track, artist, album and duration',
  '与 XIsland 连成一体':'Connect with XIsland','点击切换或在非编辑区横向轻扫。对方确认显示后，本窗口才会隐藏。':'Click to switch or swipe horizontally outside editors. This window hides only after the other island is visible.',
  '切换':'Switch','音乐、日程、灵感和文件，安放在桌面的一角。':'Music, schedules, ideas and files in a corner of your desktop.',
  '日历来自本地 .ics。系统媒体、拖放、中文输入与多屏体验需在 Windows 实机验收。':'Calendars use local .ics files. System media, drag and drop, input methods and multiple displays still require Windows testing.',
  'Windows 预览版':'Windows preview','重试保存':'Retry save','横向轻扫 · 切换工作岛':'Swipe sideways · Switch islands','已保存到本机':'Saved locally','正在保存…':'Saving…','有未保存修改':'Unsaved changes',
  '正在保存并退出…':'Saving and quitting…','正在保存并退出，请稍候':'Saving and quitting. Please wait.','继续编辑':'Keep editing','重试退出':'Retry quit','不保存并退出':'Quit without saving','确认不保存并退出':'Confirm quit without saving',
  '确认放弃未保存的修改？':'Discard unsaved changes?','这次未能保存的内容会丢失，磁盘中已保存的原件不会被删除。':'Unsaved changes will be lost. Existing files on disk will remain.',
  '修改还没有保存':'Changes have not been saved','草稿仍在应用中，你可以继续编辑或重新保存。':'Your draft is still here. Keep editing or retry saving.','保存失败，选择退出方式':'Save failed: choose how to quit',
  '请先完成当前中文输入，再退出应用':'Finish the current input composition before quitting','存储受保护':'Storage is protected','原始数据受到保护，修复后才能编辑':'Original data is protected. Restore it before editing.',
  '已关联到当前任务':'Linked to the current focus','文件架已关联到当前任务':'Shelf files linked to the current focus','已从任务快照恢复一份笔记':'A note was restored from the focus snapshot','日历已导入':'Calendar imported','日历文件超过 5 MiB':'Calendar file exceeds 5 MiB',
  '重新读取':'Read again','备份并恢复为空数据':'Back up and reset data','原件受到保护，当前不可编辑。':'Original data is protected; editing is disabled.','确认备份并恢复为空数据？':'Back up and reset data?',
  '将先备份原始数据，再创建空数据。原文件不会被直接覆盖。':'The original data will be backed up before an empty store is created.','取消':'Cancel','确认恢复':'Confirm reset',
};
export function t(text: string, english?: string): string { return language() === 'zh' ? text : english ?? en[text] ?? text; }
const replacements = Object.entries(en).sort((a, b) => b[0].length - a[0].length);
export function translateLiteral(text: string): string {
  if (language() === 'zh') return text;
  for (const [zh, english] of replacements) text = text.split(zh).join(english);
  return text;
}
/** 仅翻译模板的静态片段；插值中的笔记、事件、路径、歌名绝不参与替换。 */
export function html(strings: TemplateStringsArray, ...values: unknown[]): string {
  return strings.reduce((result, literal, index) => result + translateLiteral(literal) + (index < values.length ? String(values[index]) : ''), '');
}
