# 详情页“概览”按钮修复

用户截图为 X Nook 媒体详情页。原左上角来自窄宽度导航回退 `Menu + Picker`，显示当前工具图标，不是直接返回概览的按钮。本次按要求将所有详情页左上角固定为带文字的“概览”普通按钮，点击设置 `selectedWidget = nil`。

实现位于独立工作树 `xnook-overview-header`，分支 `codex/overview-header-20261025`，基于已提交的 `e7830bd`。另一聊天正在进行的网页标题功能及 XIsland 去数字改动均未混入。

## 行为与保护

- 媒体、日历、笔记和文件详情左上角均显示“概览”，不再退化成当前工具图标。
- 返回概览不收起窗口、不重置布局或任务；概览页原有工具导航继续保留。
- 详情按钮预留完整文字宽度；小窗口左右空间不足时把工具栏放到物理刘海下方。
- 布局编辑中的导航禁用规则保留；离开笔记前先完成 `closeEditor()`，保存失败不切走。
- 不改变链接编辑弹层的关闭保护、播放行为或用户配置。

## 验证

- 原生渲染和笔记回归：38 项，37 通过、1 个交互入口条件跳过、0 失败。
- 布局与链接编辑回归：58 项通过、0 失败。
- 交互入口单独执行：1 项通过；合计 96 个不同用例均已执行通过。
- 中文/英文，320、380、400、412、460、800pt，200×32pt 模拟刘海：按钮包含完整文字，位于标题区内，不与刘海、设置或关闭按钮重叠。
- 460pt 隔离原生窗口从媒体详情启动，CUA 点击 `expandedPanelOverview` 后 `selectedWidget` 从 `media` 变为 `overview`，媒体/日历/笔记等概览组件出现，窗口继续显示。
- 前后任务 ID、开始时间、笔记/文件/历史数量与保存布局均一致；测试窗口正常关闭，临时业务夹具清理完成。

证据目录：`.build/overview-header-20261025/`。其中 `before-click.png`、`after-click.png`、对应 JSON 和 `validation.json` 为实际隔离窗口证据，原生布局图片位于 `.build/grid-editor-evidence/dashboard/media-overview-header-zh.png` 与 `media-overview-header-en.png`。

日志仍保留两条既有测试事件泵附近的负尺寸警告，已检查的按钮几何及点击结果正常，本次不声称定位或修复了该警告。正式 App/NSPanel 安装、多屏实机没有在本轮重新验收。

## 复现

```sh
XNOOK_RENDER_UI=1 swift test --filter 'PanelGridNativeTests|NotesManagerTests'
swift test --filter 'TaskLinkEditingTests|ExpandedPanelLayoutTests'
python3 scripts/prepare-grid-ui-host.py
XNOOK_GRID_LIVE=1 XNOOK_GRID_LIVE_DETAIL=media XNOOK_GRID_LIVE_SECONDS=180 \
  '.build/grid-editor-evidence/XNook Grid Test.app/Contents/MacOS/xctest' \
  -XCTest XNookTests.PanelGridNativeTests/testRunIsolatedLiveGridEditor \
  .build/out/Products/Debug/XNookTests.xctest
```

本轮未提交、推送、发布或替换正式应用。
