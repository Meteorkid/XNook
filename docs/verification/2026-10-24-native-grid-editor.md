# X Nook 原生网格编辑器：实现与验收记录

交付更新：初次实现后补修了 160pt 媒体卡片溢出，并发布 1.3.20；随后正式 NSPanel 验收发现标题按钮拦截拖动，修复并发布 1.3.21。最终完整回归为 507 通过、1 条件跳过、0 失败，公开 1.3.21 已安装并完成 800pt 标题拖动、缩放、保存与真实重启恢复。当前结果以 [1.3.21 发行说明](../releases/1.3.21.md) 和 [机器可读验收](../releases/verification-1.3.21.json) 为准；下文为初次实现阶段记录，不能代替最终发行证据。

日期：2026-10-24。范围：按用户确认的网格吸附方案实现原生编辑器，并修复概览默认布局。状态：代码及隔离原生交互通过，未提交、推送、发布或替换正式应用。

## 代码基线与隔离范围

- 工作树：`/Users/meteor/.codex/worktrees/xnook-grid-editor`
- 分支：`codex/native-grid-editor-20261024`
- 基线：`6b4eb6668949df57afac95ee14faabcd1a7fedab`
- 版本文件保持 `1.3.19`，本轮不更改版本号。
- 另一聊天正在调整 XNook 视觉与安装验收。本轮从已提交基线创建独立工作树，未覆盖其未提交内容；尚未验证两批改动合并后的效果。
- 窗口测试使用私有 UserDefaults suite、临时笔记/托盘/任务数据和专属测试宿主，未写入正式偏好、数据库、客户端配置或信任设置。

## 使用方式

1. 展开概览，点击导航右侧的布局编辑图标；也可从设置点击“打开布局编辑器”。后一入口已接入生产代码，完整正式 App 的菜单跳转仍需候选安装验收。
2. 拖动组件标题改变位置，拖动右下角改变大小。释放后吸附网格，其他组件自动避让。
3. 工具栏可选择组件、宽度、高度和显示状态；“前移/后移”无需拖拽即可调整顺序。
4. 点击“保存”或按 Cmd-S 才写入布局；“取消”放弃草稿。“恢复默认”先修改草稿，仍需保存才能生效。
5. 编辑时保留各组件业务状态、停止自动收起并固定视口。笔记保存失败或尚未完成链接编辑时，先处理原操作再进入布局编辑。

六模块为媒体、日历、笔记、文件托盘、当前任务、最近任务。桌面采用 12 列网格，宽度为 1/3、1/2、2/3、整行，高度为离散档位。窄窗口临时折成两列或一列，不改写保存的桌面位置与尺寸。隐藏模块会收拢可见模块的空行，重新显示时仍可继续调整。

## 默认界面的改进

| 原问题 | 本轮行为 |
| --- | --- |
| 媒体封面、标题和按钮竖直堆叠，横向空间浪费 | 封面与内容横排；统一媒体标题，保留播放控制与详情入口 |
| 卡片标题/边距/高度不协调 | 媒体、日历、笔记、托盘采用统一标题区域与网格高度；按内容预算展示 |
| 日历日期条两端出现半格，权限提示占据大量高度 | 概览按宽度显示完整的 3/5/7 格；权限、空态、事件列表采用紧凑排版 |
| 日历缩放时误改变选择日期 | 同时处理 AppKit frame/bounds 变化，程序重居中期间隔离布局位移，保留用户横滚选日 |
| 笔记和文件托盘高度不一致或内容溢出 | 按可用高度减少行数，保留“查看全部”；最小托盘卡片保留一行，文字至少 11pt |
| NookFlow 左侧很短、右侧历史很长 | 当前任务与最近任务成为独立模块，可分别调整宽高与位置 |
| 编辑隐藏模块后留下空白 | 可见模块向上收拢；隐藏全部主组件时任务区从首行开始 |
| 退出编辑时面板高度可能抖动或丢失测量 | 测量携带编辑状态与布局签名，忽略编辑态对正常自适应高度的覆盖 |

模块内容缩减只影响概览展示，笔记、文件和任务数量不随布局减少。最近任务条数设置作为上限，小卡片显示更少条目，所有记录仍可从“查看全部”访问。

## 配置兼容与数据保护

- 新配置以 `panelLayout.v1` 保存完整 JSON，设置中的组件开关和编辑器共享这一数据源。
- 首次读取缺省新配置时，沿用 `enabledWidgets` 与 `showNookFlowHistory`。只读取或渲染不会写入新配置。
- 编辑草稿独立于已保存配置；取消、窗口宽度改变、反复进入编辑均不会偷偷保存。
- 保存前重新读取存储并比较起始配置签名，避免覆盖另一设置窗口在编辑期间做出的修改。
- 无法解析或版本过新的配置保持只读；用户明确恢复默认时，原始数据先存入 `panelLayout.v1.recoveryBackup`。
- 六模块使用固定身份；测试核对当前任务 ID、开始时间及笔记/文件/历史数量在编辑前后不变。

## 自动测试与构建

| 层级 | 最终结果 | 原始证据 |
| --- | --- | --- |
| 全量 XCTest | 508 项，476 通过、32 条件跳过、0 失败 | `.build/grid-editor-evidence/full-tests-final.log` |
| 原生渲染与编辑专项 | 26 项，25 通过、1 交互入口条件跳过、0 失败 | `.build/grid-editor-evidence/native-suite-final.log` |
| 最终源码独立交互宿主 | 1 项通过，窗口正常关闭，进程正常退出 | `.build/grid-editor-evidence/live-final-source.log` |
| Release 编译 | 通过 | `.build/grid-editor-evidence/release-build-final.log` |
| 补丁空白检查 | `git diff --check` 通过 | 交付时再次检查 |

新增 51 项测试均在上述组合中实际执行通过。全量默认跳过的本轮 7 项渲染测试和 1 项交互测试已分别执行；其他历史可选测试未因此变为通过。不同运行包含重叠测试，不能将运行次数简单累加为独立用例数。

覆盖点包括：64 种模块可见组合与 7 个宽度、1,000 次随机编辑、非有限/越界输入、碎片空间避碰、隐藏收拢、600pt 两列横向交换、草稿取消和并发保存冲突、旧配置迁移与未来版本保护。

原生几何与截图覆盖概览/编辑状态的 320、600、800、1000pt 及明暗主题；单组件覆盖 220、320、480、720pt 与中英文，另外检查权限/空内容。测试断言模块无重叠、关键文本和操作入口位于卡片/视口内。

日历回归检查连续改变日期条宽度后选择日期不变；真实 NSClipView 横向滚动 72pt 后选择前两日，再次缩放保持新的日期。保留失败与修复日志：`calendar-scroll-before.log`、`calendar-scroll-fixed.log`。

## 最终源码的真实鼠标验收

使用 `/Users/meteor/.codex/worktrees/xnook-grid-editor/.build/grid-editor-evidence/XNook Grid Test.app`，Bundle ID 为 `dev.xnook.tests.grid-editor`。宿主运行实际 SwiftUI/AppKit 视图，不运行正式 AppDelegate；正式单实例、配置和系统接入不参与此测试。

最终运行 PID：`75631`；时间：2026-10-24 17:00:24–17:04:25（Asia/Shanghai）；窗口宽度：800pt。

| 实际鼠标操作 | 结果 |
| --- | --- |
| 把媒体标题拖向日历位置 | 媒体吸附第 4 列，日历向左避让 |
| 拖媒体右下角 | 从 4×4 调为 6 列×6 行 |
| 保存前读取私有存储 | 与编辑前一致，未提前持久化 |
| 点击保存 | 保存整个布局并返回普通概览 |
| 打开媒体详情后返回概览 | 入口和往返正常 |
| 再进入编辑，隐藏媒体后取消 | 恢复刚才保存的布局 |
| 恢复默认并保存 | 与初始默认布局一致 |
| 关闭测试窗口 | 宿主正常退出，临时业务数据目录清理完成 |

全过程当前任务 ID 和开始时间未变；笔记 8 条、托盘 6 项、历史 5 条数量不变。

独立交互结果为 `.build/grid-editor-evidence/live/final-source-cua-validation.json`。宿主原始 `state.json` 自身的 `cuaInteractionVerified=false` 表示自动截图不自称鼠标验收；交互结论由独立 CUA 操作与前后存储比对产生。测试宿主准备记录中的 `runtimeVerified=false` 同样只描述准备阶段，不覆盖后续运行记录。

实际操作截图：

- `.build/grid-editor-evidence/live/final-source-resize.png`：真实拖动与缩放后的编辑器。
- `.build/grid-editor-evidence/live/final-source-dashboard.png`：恢复默认后的真实窗口。
- `.build/grid-editor-evidence/dashboard/default-800-dark.png`：独立渲染的默认概览。

## 复现命令

在本工作树中执行：

```sh
swift test
XNOOK_RENDER_UI=1 swift test --filter 'PanelGridNativeTests|GridWidgetNativePreviewTests|GridWidgetContentLayoutTests|PanelLayoutEditingSessionTests|FocusSessionGridSectionTests'
swift build -c release
python3 scripts/prepare-grid-ui-host.py
```

准备脚本只复制 Xcode 的 `xctest` 到任务目录、调整副本 rpath 并签名，不修改原件，也不自动启动。原件前后 SHA256 相同。实际测试 bundle 路径不同可使用 `--test-bundle` 参数。

在保持桌面解锁的测试环境中，运行一次交互宿主，然后实际操作窗口：

```sh
XNOOK_GRID_LIVE=1 XNOOK_GRID_LIVE_SECONDS=480 \
  '.build/grid-editor-evidence/XNook Grid Test.app/Contents/MacOS/xctest' \
  -XCTest XNookTests.PanelGridNativeTests/testRunIsolatedLiveGridEditor \
  .build/out/Products/Debug/XNookTests.xctest
```

窗口关闭即结束；超时最多 600 秒。仅启动宿主或截屏不能算拖动/保存验收。若上次留下该任务专用 `live/stop` 标记，先确认旧测试进程已结束，再移除该标记后重新运行。

## 当前限制与待验收项

- 未替换正式 XNook；设置入口到真实灵动岛、生产窗口自动高度/收起、双应用切换和实际冷启动恢复未做完整候选安装验收。存储测试中的“重启”指重新创建 store 并读取已保存配置。
- 600pt 横向交换已通过布局/手势计算测试与原生渲染；实际鼠标验收仅完成 800pt。测试宿主窗口宽度拖动未成功改变尺寸，不据此推断正式 App 存在缩放缺陷。
- 未实测 VoiceOver 朗读、外接多屏或实际帧率；静态渲染及布局计算不等同这些验收。
- 未触发真实媒体播放、文件打开和系统日历权限授权。
- 最终交互日志保留两条 `Invalid view geometry: width/height is negative` 警告，行号指向测试宿主取事件循环，根因未定位。独立几何断言通过；复核 16 份 dashboard 与 5 份最终交互快照，均无非有限或负尺寸，每份的 6 个模块均为正宽高，未观察到持久布局异常或已测功能失败。live 循环未逐帧执行几何断言，不能排除瞬时无效布局，也不能直接归因为隐藏内容的临时测量；后续应在原生候选 App 捕获布局堆栈复核。
- 全量测试日志的歌词网络不可用/HTTP 503 输出未导致 XCTest 失败；本轮不把它作为真实歌词服务连通性通过证据。

## 交付文件

- 布局与存储：`Core/PanelLayoutConfiguration.swift`、`PanelGridGeometry.swift`、`PanelLayoutDragUpdate.swift`、`PanelLayoutStore.swift`、`PanelLayoutEditingSession.swift`。
- 原生编辑器与接入：`Features/PanelLayoutEditorView.swift`、`ExpandedPanelView.swift`、`NotchContentView.swift`、`Settings/SettingsView.swift`、`App/AppDelegate.swift`、`Core/ExpandedPanelLayout.swift`。
- 组件：媒体、日历、笔记、托盘、`NookFlow/FocusSessionView.swift`、`GridWidgetContentLayout.swift` 和对应本地化。
- 测试：7 个新增 `Tests/XNookTests/*Grid*Tests.swift` / `PanelLayout*Tests.swift` 文件及 `scripts/prepare-grid-ui-host.py`。
- 原始证据、源码 SHA256 清单及汇总：`.build/grid-editor-evidence/validation.json`、`source-manifest.sha256`。证据目录为本地构建产物，清理 `.build` 前应另行归档。

最终冻结记录：

| 内容 | SHA256 |
| --- | --- |
| 126 个源码/测试/构建输入文件的清单 | `438be2db64ad2bccb7e6b34fd2e398779eaa9b4fa147145f370442afcdc6d9d8` |
| 最终 Debug 测试二进制，与宿主准备记录一致 | `9e068369fcbcbadd204f6dea468733ee488c93079ba93d24628cee38c855ea3b` |
| Release 可执行文件 | `9fa01ea61173296f735b6a47028852df9d09a1676d8577af4f592a8290225f5f` |

下一步为用户确认后提交本分支，再整合并行视觉改动、制作候选应用并验证上述正式应用路径。提交、发布和本机正式更新需使用对应明确授权。
