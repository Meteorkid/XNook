# Windows 网易云音乐 / QQ 音乐兼容性核查

证据日期：**2026-10-17（Asia/Shanghai）**。用户使用两家 Windows 最新版。本次仅检索官方页面、开发者文档和发布源码，不安装播放器、不执行安装包、不注入 DLL、不修改播放器配置；没有 Windows 实机播放验证。

## 结论与实现约束

- 可以优先识别 `cloudmusic.exe` 与 `qqmusic.exe`，并对当前枚举到的完整原始 `SourceAppUserModelId` 提供手动选择。证据是第三方媒体消费者的发布源码精确匹配，不是两家厂商关于所有版本的官方保证。
- 大小写不敏感的完整 exe 基名相等，或已经验证格式的绝对 exe 路径取基名，可以作为保守名称识别。不能用 `contains("qq")`、`contains("music")` 等子串规则，也不添加猜测的商店包家族。未知 AUMID 仍显示原始来源，允许手选。
- 用户选定某个来源后，该来源退出或暂不可用时应提示等待该来源，不能默默控制另一播放器。控制前重新核对本次操作选定的会话身份。
- 必须按本次媒体会话提供的 capability / timeline 决定按钮与进度是否可用。看见歌名、SMTC 会话或 `Playing` 不能证明时间轴、seek、歌词同步全部可用。
- 不把“从切歌开始累加时间”、桌面音量变化、读取窗口标题或未验证 UI Automation 作为准确播放进度的静默替代。

## 官方下载入口与当前版本

| 项目 | 本次实际核对结果 | 证据级别 |
| --- | --- | --- |
| QQ 音乐 Windows | 官方下载页标注 **22.7.6**，发布日期 **2026-10-13** | 官方网页直接证据 |
| QQ 下载按钮 | `https://dldir.y.qq.com/music/clntupate/QQMusic_YQQWinPCDL.exe` | 官方页面中的下载地址；未验证安装包内容 |
| 网易云音乐 Windows | 官方下载页存在 PC 下载入口；页面未给出可用的 Windows 版本号 | 官方网页直接证据，版本号未确认 |
| 网易 PC 最新入口 | `https://music.163.com/download/pc/latest` | 官方页面中的地址；本次 HEAD 请求返回 HTTP 403 |

官方页面：[QQ 音乐下载](https://y.qq.com/download/download.html)、[网易云音乐下载](https://music.163.com/download)。QQ HTML 已冻结在 `.build/music-compat-research/qq-download.html` 第 46–50 行；网易 PC 入口位于 `netease-download.html` 第 1760 行。

微软 winget 社区清单另有网易 `3.1.41.205529`、QQ `22.22`，但它们不能替代厂商页面的当前版本结论。尤其 QQ 页面使用 `22.7.6`，不应仅按清单数字猜测孰新孰旧。网易清单中的官方 CDN 固定地址也返回 HTTP 403。本次**没有下载到厂商安装包**，因此没有二进制静态检查结果。

## 精确来源标识证据

微软 [SourceAppUserModelId 文档](https://learn.microsoft.com/en-us/uwp/api/windows.media.control.globalsystemmediatransportcontrolssession.sourceappusermodelid?view=winrt-26100)仅定义它为媒体会话来源应用的 App User Model ID，不保证它总是进程名、路径或厂商名称。

[Lyrix 26.10.1 发布源码 `src/models/music_player.rs`](https://docs.rs/crate/lyrix/26.10.1/source/src/models/music_player.rs) 第 32–35 行的 `id2player(app_id)` 使用精确匹配：

| 原始 app_id | 原代码识别结果 |
| --- | --- |
| `cloudmusic.exe` | `MusicPlayer::Netease` |
| `qqmusic.exe` | `MusicPlayer::QQMusic` |

该代码是可检查的消费者实现，强于 README 示例或含省略号的示范 JSON；但它没有提供厂商版本号、捕获日志或本机验收记录。`QQMusic.exe` 的大小写等价是本项目基于 Windows 可执行名称的识别规则，而非额外捕获样本。

本次下载了 crates.io 的 `lyrix/26.10.1` 源码包，SHA-256 与 crates.io 发布元数据一致；未执行源码。固定 Git 提交也保留相同精确映射：[Lyrix `3188b4b05c77709f97562fc116ab33dfd55f0f7d`](https://github.com/cXp1r/Lyrix/blob/3188b4b05c77709f97562fc116ab33dfd55f0f7d/src/models/music_player.rs)。本地证据与哈希见 `.build/music-compat-research/verification.json`、`music_player.rs`、`lyrix-music-player-pinned.rs`。

不采用检索中 `NetEase.CloudMusic...` 这种带省略号的 README 占位示例作为真实 AUMID，也不把历史 UWP 包身份推断成最新 Win32 客户端身份。

## SMTC 支持与版本边界

### QQ 音乐

- [QQMusicSMTC 原插件作者的归档说明](https://github.com/FoskyM/QQMusicSMTC)记载：2024-06-13 的 **20.22.2692.0613** 增加原生 SMTC，作者因此停止维护。它属于第三方开发者的历史观察，不是腾讯发布说明。
- [Lyricify 开发者的 QQ 音乐说明](https://docs.lyricify.app/lyricify-lite/app-faq/qq-music/)将**时间轴**支持下限记为 **21.10.2962**，并指向 `设置 → 常规设置 → 通知 → 显示系统媒体传输控件（SMTC）`。这与“首次出现 SMTC”是不同能力层级，不能混为同一个最低版本。
- [Now Playing 的真实 QQ SMTC 适配源码](https://github.com/Widdit/now-playing-service/blob/2336c5fc6c57300bc7cf5fa85c7f273042bb86b1/external_programs/AudioService/GetMusicStatus/MusicServices/SMTC/QQMusicSMTC.cs)记录：在某些环境，不打开 Windows 媒体控制面板时播放状态可能不刷新；元数据与封面可能异步更新。该项目采用音量推断状态，但 XNook 不应直接照搬为真实暂停判断，静音、无声片段等会使它失真。

上述材料支持“优先适配新版 QQ 原生 SMTC，并验证各字段”，不支持“官方最新版所有机器无条件完整兼容”。

### 网易云音乐

- [Lyricify 的网易说明](https://docs.lyricify.app/lyricify-lite/app-faq/netease-cloud-music/)同时保留了旧 Win32 不支持 SMTC、自带 SMTC 不提供时间轴、旧插件时间轴错误等描述。这些内容缺少当前官方版本限定，不能直接套用于用户的最新版。
- [InfLink-rs 的生产者源码](https://github.com/apoint123/inflink-rs/blob/e4ad4946ce24f63b99082fe8be3f30ca92d4428e/packages/backend/src/smtc_core.rs)实现了额外的 SMTC 信息与控制；它说明插件可以增强协议，不能证明官方客户端在不装插件时具备同样能力。本项目不自动安装该插件。
- [Now Playing issue #39](https://github.com/Widdit/now-playing-service/issues/39#issuecomment-4312804194)里，作者明确说明其旧实现用内置计时器模拟进度，拖动不能同步。这是**消费端自己的设计限制**，不能错误引用成“网易原生 SMTC 一定坏了”的证据。后来作者说明其进度同步来自窗口 UI 抓取：[作者跟进](https://github.com/Widdit/now-playing-service/issues/39#issuecomment-4966289267)。
- [该项目当前网易实现](https://github.com/Widdit/now-playing-service/blob/2336c5fc6c57300bc7cf5fa85c7f273042bb86b1/external_programs/AudioService/GetMusicStatus/MusicServices/NeteaseMusicService.cs)确实采用 UI Automation 缓存进度；这条路线尚未在 XNook 验证，不能作为本次隐藏 fallback。

本次结论是：网易最新 Win32 的完整时间轴能力**仍需在用户机器验证**。没有 timeline 时显示“播放器未提供进度”，保留仍有效的元数据和控制能力，避免制造同步歌词进度。

## 歌手字段与歌词匹配

没有找到两家最新版原生 SMTC `Artist` 多艺人分隔符的官方稳定规范。第三方 QQ 消费源码会把 `/` 替换为带空格的斜杠；InfLink-rs 的说明也提到用 `/` 拼接艺人，但这些不能定义全部官方输出格式。艺人自身也可能包含斜杠，例如 AC/DC。

建议自动匹配只接受完整归一化名字相等，避免用双向 `includes` 接受“张三”与“张三丰”；不扩展未知分隔符、不删 Live/Remix 等曲目版本标记。不完全相等的候选交由用户明确选择。

## Windows 实机验收最小集合

1. 记录两家“关于”页面实际版本，以及枚举得到的原始 `SourceAppUserModelId`；不要仅记录产品显示名。
2. 两播放器同时运行、分别暂停/播放；确认手选来源不会被另一播放器抢走。
3. 对每家分别验证标题、艺人、专辑、封面、暂停/恢复、上一首/下一首；控制不支持时按钮禁用或报告真实失败。
4. 读取 timeline 并执行前后拖动；缺失、恒零、过期、换歌时未更新的数据不能当作可靠当前进度。
5. 关闭当前选定播放器，确认应用提示不可用且不控制另一个；重新启动后再次核对身份。
6. 若用户启用了第三方 SMTC 插件，单独记录；不能把插件效果记作原生最新版能力。
