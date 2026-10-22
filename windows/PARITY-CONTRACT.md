# 0.2.0 / 0.3.x 对齐补充契约

沿用 CONTRACT.md。新增命令都以 camelCase 参数调用，旧命令保留。错误必须 reject，不能返回成功假象。Settings 增量可缺省，旧文件合法；新值严格验证。

## Settings 新字段（默认值）

```
appearance: dark | light | system = dark
language: auto | zh | en = auto
panelWidth: number 160..1200 = 620
panelHeight: number 160..1000 = 590
islandWidth: number 40..600 = 300
islandHeight: number 8..120 = 52
lyricsIslandWidth: number 60..800 = 360
lyricsIslandHeight: number 10..160 = 72
enabledWidgets: (media|calendar|notes|files)[] = [media,calendar,notes,files]
showHistory: boolean = true
historyLimit: integer 1..20 = 3
hoverExpand: boolean = false
scrollExpand: boolean = true
hoverExitDelayMs: integer 0..10000 = 200
idleCollapseMs: integer 0..600000 = 1000  // 0关闭
reduceMotion: boolean = false
jellyIntensity: off|low|medium|high = medium
magnetic: boolean = true
hideCursor: boolean = false
showTicker: boolean = true
tickerSpeed: number 1..200 = 25
selectedGifId: string|null = null
reminderEnabled: boolean = false
reminderLeadMinutes: integer 0..1440 = 5
reminderSound: default|asterisk|exclamation = default
quietHoursEnabled: boolean = false
quietHoursStart: HH:mm = 22:00
quietHoursEnd: HH:mm = 07:00
autoRefreshCalendars: boolean = true
autoCheckUpdates: boolean = true
launchAtLogin: boolean = false
visibleOnAllDesktops: boolean = false
```

Store 可选新增 `remindedEvents: string[]` 默认空，0.3.2最多5000个以匹配整批日程输出。仅用于提醒去重，不改变会话历史；可读取旧版记录。

## 原生系统（native agent）

- `apply_preferences({settings: Settings}) -> void`：窗口主题/多屏/全屏/虚拟桌面；不自动修改登录项。
- `set_launch_at_login({enabled:boolean}) -> boolean`、`get_launch_at_login() -> boolean`：返回真实状态。
- `copy_files({paths:string[]}) -> void`：Windows CF_HDROP 文件剪贴板。
- `start_file_drag({paths:string[]}) -> void`：真实 Windows 文件拖放，只从用户文件架拖动触发。
- `open_media_player({sourceId:string,sessionToken:string}) -> void`：激活已绑定播放器，不能把任意输入当命令执行。
- `recover_store({content:string}) -> {backupPath:string}`：先备份原始文件，再原子写合法空存储；由用户明确确认触发。
- `list_gifs() -> {id:string,name:string}[]`
- `import_gif() -> {id:string,name:string}|null`
- `read_gif({id:string}) -> string`（data:image/gif;base64,...）
- `delete_gif({id:string}) -> void`（仅删除本应用复制件）
- `open_calendar({path?:string}) -> void`：有path时打开已导入ICS原件；缺省时尝试系统注册日历入口，失败必须说明。
- `play_reminder_sound({sound:'default'|'asterisk'|'exclamation'}) -> void`

## 服务（services agent）

- 保留 `lookup_lyrics` 参数与 LyricsCandidate[]，原生 LyricsClient 增加磁盘缓存/精确查询→搜索→宽松查询回退；只缓存成功/真实空结果，不缓存网络错误为空；不放松最终曲目/艺人/时长匹配。
- 前端 `LyricsController` 保持现有构造与load/cancel接口，补有上限的同曲失败重试（可取消）。歌词是否同步必须取决于真实位置。
- 新 `calendar-services.ts` 提供纯提醒计划及自动刷新调度，接口与frontend直接协调；不能改 main.ts/domain.ts。
- 新 `src-tauri/src/updates.rs` 提供 `UpdateService::new(dataDirectory)`, `check(force:bool)` 异步和 `latest_url()`；返回 `{currentVersion,latestVersion:string|null,updateAvailable:boolean,url:string|null,checkedAt:string,message:string}`。
- native agent 包装命令 `check_updates({force:boolean}) -> UpdateStatus`、`open_update_page() -> void`，只打开已校验项目GitHub发布页。

## 联动（root）

- `island_get_preferences() -> {swipeEnabled:boolean,sensitivity:'low'|'medium'|'high',startupDisplay:'lastUsed'|'xnook'|'xisland'}`
- `island_set_preferences({preferences:...}) -> same`，由同一用户两客户端共享；不放进 Store 的本地settings。
- 阈值低/中/高=120/80/45，横向动作必须避开编辑区和选择控件。
- 启动偏好应用于首个客户端启动；首选另一客户端且已登记时尝试唤起，失败回到当前。已有运行中的owner保持；托盘显式显示优先。lastUsed记录成功显示者。

## 0.3.0 增量

- `file_statuses({paths:string[]}) -> FileStatus[]`：每次最多128项，bridge自动分批。每项独立返回 `{path,available,error:string|null,sizeBytes:number|null,isDirectory:boolean|null}`；目录不递归计大小，不删除坏引用，不改历史快照。
- `take_tray_actions() -> ('settings'|'checkUpdates')[]`：一次领取当前队列。原生先确认显示权再入队并发 `tray-actions-pending`；前端先订阅再领取，处理启动/隐藏时请求。
- MediaSnapshot 新增可选 `playbackRate:number|null`；缺省按1倍，播放位置最多外推3秒，仍以SMTC真实位置为锚。
- `LyricsController.load(media,apply,onError?)`：初始错误仍reject，瞬时网络错误耗尽短重试后按15/30/60/120秒恢复；后台错误经onError，cancel同时取消短/长定时器。空结果正常缓存，不持续重查。
- `panelHeight` 是最大高度；普通设置下短内容可收缩，0.3.1进一步允许160px上限，内容滚动访问。所有尺寸下限见上表，保留旧默认值与上限。
- `showTicker` 控制收起曲目信息，`lyricsEnabled` 控制查询及收起歌词；播放时任一开启使用歌词药丸尺寸，暂停时返回普通药丸。横向联动手势仅在收起时触发。
- 继续用Store v1；历史页码、文件实时状态与菜单状态仅保存在内存。

0.3.1：同曲时长变化小于1秒且来源/标题/艺人/专辑一致时，只有已选候选仍通过精确时长校验才能同步复用；不延长缓存有效期，不复用真正空结果。40×8/60×10等极矮收起态保留点击区，隐藏放不下的内容；右键菜单期间临时宿主宽度至少220px，关闭后恢复用户尺寸。160px展开布局使用下拉导航和纵向控件。

## 0.3.2 增量

- `begin_exit() -> void` 请求原生退出状态，随后由 `request-exit` 事件驱动保存；`cancel_exit() -> void` 取消等待保存的请求；`confirm_exit()` 仍只接受已建立的保存确认状态。
- 日历只在 `CalendarWorker` 中解析，`CalendarClient` 3秒后终止不返回的任务；最多一个在途和两个待处理工作，取消与迟到响应隔离。
- 每批最多100来源、单源5MiB、总输入10MiB、10000组件、40000属性、4000日期值、25000展开步、5000输出事件、8MiB输出；深度8、UID最多1024字符。500ms为协作检查预算，3秒Worker才是同步内层的硬截止。
- 歌词输入最多2Mi字符、时间标签最多10000、展开正文最多1Mi字符；HTML转义后正文最坏放大受该预算约束。超额候选局部拒绝，只有全部匹配候选超额时向上报告错误。
- 离散状态操作先验证完整候选，再替换内存Store；不能因一次超限关联/导入把当前任务变成无法保存的半成品。已有超限草稿允许减少数据，未保存编辑不静默丢弃。
- 保存最多保留一份在途快照和一份最新待写快照；合并请求在最新对应批次落盘后完成，`flush`等待期间新增请求也会等待。
- GIF库保留{id,name}接口；坏条目用诊断名称呈现。删除先重命名到 `.deleting-<UUID>`，只清理允许的普通文件；原id可重试，未知文件和链接不删除。列表只轻量检查，完整GIF内容校验仍在导入/选中读取。
