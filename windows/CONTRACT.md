# 前后端契约 v1

TypeScript 前端通过 Tauri invoke 调用原生层，参数 camelCase。日期持久化使用 ISO 8601，媒体 sampledAt 用 Unix 毫秒。

## 存储与窗口
- `read_store() -> string | null`：缺失返回 null，读取/损坏错误返回错误，不重置原件。
- `write_store({content:string}) -> void`：验证 JSON/大小，原子写入；失败不丢原件。
- `resize_island({width:number,height:number,expanded:boolean}) -> unknown`
- `focus_input() -> void`
- `configure_window({followPointer:boolean,hideInFullscreen:boolean}) -> void`
- `drag_island({phase:'begin'|'update'|'end'}) -> unknown`
- `request-exit` 事件触发前端刷新待保存草稿；保存成功或用户明确放弃后调用 `confirm_exit()`。保存失败不得自动退出。
- `native-error` 事件 payload 为 string，供原生后台错误提示。

## 文件与日历
- `pick_files() -> FileInfo[] | null`
- `inspect_files({paths:string[]}) -> FileInfo[]`
- `open_file({path:string}) -> void`
- `reveal_file({path:string}) -> void`
- `export_note({title:string,content:string,format:'md'|'txt'}) -> boolean`：false 为取消。
- `pick_calendar() -> CalendarFile | null`
- `read_calendar({path:string}) -> CalendarFile`
- FileInfo: `{path:string,name:string,isDirectory:boolean}`；前端生成 UUID，保留历史关联快照。
- CalendarFile: `{path:string,name:string,content:string}`，上限 5 MiB；前端解析 ICS。
- 原生拖入使用 Tauri `getCurrentWebviewWindow().onDragDropEvent`，调用 inspect_files 校验路径。

## 媒体与歌词
- `media_snapshot({preferredSourceId:string|null}) -> MediaSnapshot`：null 自动选择；指定原始来源 ID 时只能使用该应用，无可用会话则返回离线。
- `media_control({sourceId:string,sessionToken:string,action:'toggle'|'next'|'previous'|'seek',position?:number}) -> void`，位置单位秒。来源及会话令牌必须来自按钮显示时的快照；两者都匹配且对象仍存活才执行，禁止退回系统或同 ID 的另一会话。
- MediaSource: `{sourceId:string,name:string,kind:'netease'|'qqmusic'|'other',playing:boolean,isSystemCurrent:boolean}`。相同 sourceId 按播放器分组。
- MediaSnapshot: `{available:boolean,sourceId:string,sessionToken:string|null,playerName:string,playerKind:'netease'|'qqmusic'|'other',sources:MediaSource[],title:string,artist:string,album:string,playing:boolean,position:number|null,duration:number|null,artwork:string|null,canPlayPause:boolean,canNext:boolean,canPrevious:boolean,canSeek:boolean,sampledAt:number,error?:string}`。sessionToken 在相同会话对象生命周期内稳定，换对象必须改变；无可用会话为 null。
- 持久化 settings 增加 `preferredMediaSourceId:string|null`；v1 旧文件缺少此字段合法，前端归一为 null；出现其他类型/空字符串/NUL/长度超过4096则按损坏拒绝写入。
- `lookup_lyrics({title:string,artist:string,album:string,duration:number|null}) -> LyricsCandidate[]`
- LyricsCandidate: `{id:number,trackName:string,artistName:string,albumName:string,duration:number,instrumental:boolean,syncedLyrics:string|null,plainLyrics:string|null}`。仅请求固定 LRCLIB 服务；前端负责候选匹配、LRC 解析、缓存与请求代际校验。

## 双应用联动
- `island_peer_status() -> {installed:boolean,running:boolean,compatible:boolean,detail:string}`
- `switch_island() -> void`：完成确认后才 resolve，失败返回可显示错误。
- 原生层管理显隐和显示权；前端提供明确切换按钮、只在非编辑区触发的横向滚动手势，并防止重复请求。
- `island-link-error` 事件 payload 为 string。
