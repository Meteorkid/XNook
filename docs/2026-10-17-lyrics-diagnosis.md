# Apple Music 歌词缺失与延迟排查

日期：2026-10-17。状态：代码修复、回归测试、安装与重启完成；用户确认现场歌曲歌词显示且正常换行。用户已授权将本轮修复提交 Git；未发布。

## 目标与范围

针对“Apple Music 有时直接不显示歌词”，逐段检查播放器读取、歌词获取、时间轴与显示状态。保留现有运行环境，以真实只读采样和可重复的故障测试区分已证实缺陷与待验证现象。

## 现场证据

- 排查开始时运行的是 `/Applications/X Nook.app`，版本 1.3.13；本地候选包版本标记为 1.3.16，包含此前已完成的工作流与界面改动。用户随后明确授权安装和重启，最终运行包已替换，见下方安装验收。
- 用户配置中 `showLyrics`、`showTickerLine` 均开启，排除设置关闭这个分支。
- 2026-10-14 的一次 Apple Music 只读采样取得了歌名、艺术家、专辑、时长与播放位置。对应 LRCLIB 精确查询返回 HTTP 200，包含同步与纯歌词，耗时约 6.68 秒；搜索约 7.43 秒。这仅证明该样本有歌词且当次服务较慢，不能推断全部歌曲。
- 2026-10-17 一次有 5 秒期限的 AppleEvent 读取出现 -1712 超时；后续读取播放状态成功，播放器处于暂停。说明播放器读取也可能失败，但没有据此将所有缺词归因于权限或网络。
- 隔离探针起初缺少 AppKit 初始化，后台完整快照超过外部 8 秒期限。同一二进制与完整脚本初始化 `NSApplication` 后，后台读取在约 173 毫秒完成。生产应用本来就初始化了 AppKit，因此该探针差异不构成将 AppleScript 搬回主线程的依据。[Apple 官方线程说明](https://developer.apple.com/library/archive/releasenotes/AppleScript/RN-AppleScript/RN-10_6/RN-10_6.html)允许后台调用。

## 可复现问题与修复

| 问题 | 复现证据 | 修复后的行为 |
| --- | --- | --- |
| 已取得纯歌词，后续搜索无结果或失败导致歌词被丢弃 | 精确查询返回 plain，注入空搜索或网络错误 | 保留并立即显示纯歌词；同步结果可用时再升级 |
| 已取得纯歌词，仍等待慢速同步搜索才显示 | 挂起搜索请求，检查中间可见状态 | 搜索未完成时已有纯歌词可显示 |
| 临时网络错误后，同一首歌不再请求 | 注入离线/503、推进时钟，再通过正常媒体轮询 | 单次请求有限重试；连续失败后以 15/30/60/120 秒间隔恢复，确认无匹配则停止重复查询 |
| 先失败再成功无匹配，仍残留错误状态 | 首次抛出离线错误、重试返回正常空结果 | 成功查询清除旧错误，不继续安排恢复请求 |
| 同步歌词格式无效却有可用纯文本 | 注入无法解析的 synced 和有效 plain | 使用纯歌词，不缓存无效同步内容 |
| 关闭歌词后旧请求回写 | 请求未完成时关闭歌词，再释放响应 | 取消任务并检查代际标识，拒绝过期内容 |
| 微小时长波动重复取消慢请求 | 同一首歌的时长仅变化 0.1 秒 | 忽略不足一秒的波动；有效时长晚到仍可重新查询 |
| 临时播放器读取失败清空最近歌词 | 先提供有效快照，再返回读取失败 | 保留最近有效内容；播放器全部关闭时正常清空 |
| 通知与轮询并发、陈旧时间轴持续外推 | 并发触发通知/轮询，推进超过 5 秒的采样时钟 | 共用请求保护；过期位置停止外推，等待有效校准 |
| 封面读取拖慢歌曲信息，旧封面可能晚到覆盖新歌 | 挂起封面请求，更新媒体快照并切歌 | 封面独立获取；过期结果作废，失败后退避 |

播放器快照使用带 AppleEvent 超时的串行脚本，先检查应用是否运行，再读取字段。脚本中的 2 秒是 AppleEvent 期限，不是整个脚本总耗时上限；媒体层另外设置 5 秒软期限并拒绝过期结果。

## 安装时发现的主题循环

旧版进程 PID 1615 无法正常响应退出；2 秒采样中，主线程约 700/790 次落在 `ThemeManager.startObservingSystemAppearance → syncAppAppearance → NSApplication.setAppearance` 路径，另有大量后台线程阻塞。保存记录 `/tmp/xnook-old-app-before-restart.sample` 后，结束该无响应进程并安装候选包。

当前源码仍有相同的外观回写路径。隔离 AppKit 探针只设置一次外观，150 毫秒内触发 11 次回调（达到阈值后主动停止观察）；修复后为 0 次。首次安装的候选进程采样处于正常事件等待，没有将旧版采样冒充为新版现场复现。

最小修复：观察回调只读取外观，配色真正变化才通知；仅系统模式注册与处理观察；切回系统模式先解除手动外观；相同外观不重复设置。增加 5 项回归测试，并将主题测试偏好设置隔离，避免改动用户配置。

## 验证

使用项目现有 Swift/XCTest 工具链，注入传输、缓存、时钟与播放器读取进行故障复现，避免测试依赖用户正在播放的歌曲。

```sh
swift test
XNOOK_RENDER_UI=1 swift test --filter 'WorkflowPreviewTests|NotchWindowInteractionTests'
XNOOK_BUILD_DMG=0 bash build-app.sh
codesign --verify --deep --strict '.build/X Nook.app'
git diff --check
```

- 歌词修复首轮为 264 项常规测试及 2 项显式界面测试通过。补充主题修复后，最终常规测试发现 271 项，其中 269 项通过，2 项界面测试按配置跳过，0 失败。
- 随后显式运行 2 项界面测试，全部通过，0 跳过。最终两次合计 271 项均实际执行通过。
- 提交前将暂存内容导出至独立临时目录，排除此前未提交的工作流与界面改动，执行 `swift test --filter 'Lyrics|Media|ScriptingBridge|Theme'`，104 项相关测试全部通过；记录为 `/tmp/xnook-lyrics-commit-tests.log`。271 项结果对应完整工作区，104 项结果对应本轮独立提交内容。
- Release 构建、严格签名检查和差异空白检查通过。
- 修复前测试记录：`/tmp/xnook-lyrics-red.log`、`/tmp/xnook-playback-red.log`、`/tmp/xnook-lyrics-partial-red.log`。
- 歌词首轮记录：`/tmp/xnook-lyrics-final-tests.log`、`/tmp/xnook-lyrics-final-ui-tests.log`、`/tmp/xnook-lyrics-final-build.log`。
- 包含主题修复的最终记录：`/tmp/xnook-post-install-final-tests.log`、`/tmp/xnook-post-install-ui-tests.log`、`/tmp/xnook-post-install-build.log`。临时目录记录可能由系统清理。
- 主要测试：`LyricsRequestTests.swift`、`MediaPlaybackPipelineTests.swift`、`ScriptingBridgeHelperTests.swift`；最终取消与重试路径另经只读复核，未发现阻断项。

## 安装验收与回滚准备

- 最终包：`.build/X Nook.app`，已安装至 `/Applications/X Nook.app` 并重启；版本标记为 1.3.16。
- 旧版备份：`.build/backups/X Nook-1.3.13-before-lyrics-20261017.app`。
- 旧版及备份可执行文件 SHA-256 一致：`ac567160abf438ad4a0f92e1f8e89455ea3e5e9d00fdb0eb541bed5d2a290336`。
- 首轮歌词修复候选可执行文件 SHA-256：`f5cd89571c086157e567666b46b23f86a1410346e290214b71ff06e260f6f25a`。
- 包含主题修复的最终已安装可执行文件 SHA-256：`e9ffcf5b2cdae37d42cdfb4f1d00b9c7296ba8086a47b5bc6bc87d797d049623`，与构建包一致。
- 最终核验时只有一个 `/Applications/X Nook.app/Contents/MacOS/X Nook` 进程，PID 80960；用户确认屏幕顶部面板可见。
- 用户自主在 Apple Music 切换并播放歌曲；现场缓存分别存在《孤独患者》和《有我呢》的有效 `synced` 条目，核对了 key、类型、获取时间和内容长度，没有输出歌词全文。
- 对当前《有我呢》，用户明确反馈“能显示且正常换行”。这是用户确认的真实显示结果；工具没有直接取得浮动面板截图，缓存证据本身不被当作视觉验收。
- 原包备份保留，发生回归时可退出当前版本并恢复备份；尚未执行回滚。

## 验证范围与限制

安装、版本、单实例与当前歌曲换行已验证。网络失败恢复、旧请求作废、时间轴过期等由自动化故障测试覆盖；真实拖动进度、暂停恢复、切歌首显耗时和长时间运行没有完成独立测量，不应声称这些现场场景全部通过。

本轮没有主动控制 Apple Music 播放、切歌或进度，保留用户当前播放状态。LRCLIB 的歌词覆盖、录音版本匹配与歌词自带时间戳仍可能影响显示；未实测 Spotify，也不承诺所有歌曲均有准确同步歌词。
