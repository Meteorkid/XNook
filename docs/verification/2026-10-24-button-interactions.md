# 按钮交互检查

日期：2026-10-24。范围：聊天中的参考对照稿，以及本机实际安装的 X Nook。

## 结论与边界

- 对照稿已修复设置、收起等静态图标，并补齐已有可操作入口的本地演示逻辑。34 项浏览器交互断言通过；测试过程中发现的表单提交失败已修复并复测。
- 当前源码的 145 项动作下游/窗口交互规则回归通过，0失败；测试不是已安装二进制的运行验收。
- 用户随后授权临时改为30秒并显示最近任务，已完成相关本机检查并恢复为1秒/关闭；个人任务、笔记和托盘数据前后哈希一致。
- 本机复现两个原生缺陷：菜单设置打开空白窗；头部齿轮和收起图标有悬停反馈，但真实鼠标点击不执行。前者已统一菜单路由，后者经隔离对照确认子拖拽拦截与点击区域缺失，并落实源码修复。
- 修复后直接编译生产图标的隔离窗口中，设置/关闭两按钮的中心与边缘鼠标点击均成功。Release构建、14项图标/窗口测试、7项设置相关测试通过；它们不等同于完整安装包的菜单和快捷键验收。
- 本机已检查媒体播放/暂停、模块导航、任务历史/资源/网页面板及草稿清空关闭。日历无权限、托盘无文件，没有新增权限或改变真实任务/文件来强行完成其余动作。
- 本轮新增生产改动仅3处，未更换安装包、未提交或发布；已生成排除旧界面改动的独立补丁。当前本机安装包仍包含原来的鼠标/菜单问题。

## 实际安装包身份

路径：`/Applications/X Nook.app`；显示版本：`1.3.19`。

可执行文件 SHA-256：`561656511a5e6dd10c82ea783f3e21d2247ac8989a20ac869ca91c55d0f6cbd4`。

该哈希不同于历史已验收的 `4d41e5f` 候选 (`aadadaf0…5b959`)，也不同于记录中的正式1.3.19发布包 (`5bca4900…d9f7e`)。已窄查相关发布/安装摘要，尚未定位此包源码提交。不能单凭1.3.19版本号将当前运行结果归属到上述任何一个提交。

## 对照稿根因与修复

1. 设置、关闭、上一/下一首、月份箭头、音量、歌词等只是 `i/span` 图标，没有按钮语义或事件；任务输入是静态文本。改为真实 `button/input`，补标签、焦点恢复和可见反馈。
2. 首次补齐表单后，浏览器实测“添加任务”仍无响应：预览 iframe 的 sandbox 只有 `allow-scripts`，原生表单提交在触发处理逻辑前被阻止。修为 `type=button` 显式调用共享本地提交函数；Enter走同一路径并阻止默认提交，IME组合态和229键码不误提交。未放宽sandbox。

### 对照稿入口矩阵

| 入口 | 现在的行为 | 验证 |
| --- | --- | --- |
| 设置、返回、Escape | 打开设置；更改模块底色/最近任务显示；返回恢复焦点 | 浏览器点击与输入通过 |
| 收起、恢复 | 保留当前演示状态，提供可见恢复入口 | 两种布局均通过 |
| 媒体封面、详情箭头、返回 | 进入独立详情并返回概览 | 浏览器通过 |
| 上一首、下一首 | 内置示例曲目循环，标题/封面/时长同步，进度归零 | 浏览器通过 |
| 播放/暂停、进度 | 演示状态切换；进度同步两种布局 | 浏览器通过；不播放声音、不自动计时 |
| 音量、静音、歌词 | 展开音量、静音恢复、歌词区域开关 | 浏览器通过；仅演示状态 |
| 空态打开播放器 | 返回有曲目的演示概览 | 浏览器通过；不启动本机播放器 |
| 月份前后、日期 | 实际月份算法，支持跨年与日期选择 | 浏览器跨年/选日通过；闰日边界静态逻辑检查通过 |
| 文件添加、预览、返回、移除 | 管理内置示例文件，数量同步 | 浏览器通过；不读取或修改真实文件 |
| 文件拖放 | 拦截默认导航，提示只支持示例文件 | 静态检查有拦截；未实际拖入私人文件 |
| 新增任务、Enter | 新增仅内存示例，空白/长度/数量限制有错误反馈 | 空白、有效按钮、有效Enter实测通过 |
| 任务详情、完成、恢复、删除 | 示例状态与数量同步 | 浏览器通过 |
| 关联链接编辑、保存、解除 | 仅允许完整HTTP(S)，拒绝危险协议/凭据；留空解除 | 危险协议、有效地址、Enter/按钮、解除实测通过 |
| 原图放大、收起、方案轮播 | 本地展示切换，使用宿主轮播 | 浏览器通过 |
| 参考来源外链 | 保留指向固定GitHub来源的链接 | 地址静态核对；未逐个重新跳转外站 |

用户输入的任务/URL只保存在本次页面内存中，不存入会回传模型的 `modelContent`。模拟操作不会控制本机软件、打开任务外链或读写个人文件。文本使用DOM文本赋值，没有通过HTML插入用户输入。

对照页内容宽度1024px和320px（概览及设置）均未出现横向溢出；本轮浏览器控制台未记录warning/error。

## 原生应用检查矩阵

| 项目 | 已确认 | 尚未确认 |
| --- | --- | --- |
| 打开设置 | 面板齿轮通过辅助功能动作可打开完整设置；原生鼠标点击失败已复现并在源码修复 | 修复的完整安装包菜单/快捷键/齿轮联调，未替换本机 |
| 设置页签与关闭设置窗 | 通用/显示/联动/关于均能进入；设置窗可关闭；临时参数已恢复 | 系统权限授权与真实安装/更新动作，未触发 |
| 菜单设置 | 原版菜单打开 `com_apple_SwiftUI_Settings_window` 空窗，已定位空Settings scene并替换命令 | 新菜单及Cmd+,在完整候选中的实测 |
| 展开/收起面板 | 30秒状态下辅助功能收起立即执行；鼠标收起失败已复现。修复后隔离原生按钮中心/边缘均通过 | 完整候选应用的窗口收起动画与操作路径 |
| 媒体 | 本机Pause→Play→Pause验证播放/暂停并恢复播放；概览/详情可进入 | 切歌、拖进度、启动播放器未操作，以免扰动当前播放；源码及控制脚本检查单列 |
| 日历 | 鼠标点击日历导航有效；详情显示日期及未授权提示；点选相邻日期后回到今天 | 未授权，无法验收事件结果；未点击授权或打开系统日历 |
| 托盘 | 文件托盘导航可进入，正确显示0个文件；隔离存储测试通过 | 未导入文件，因此不声称实机打开/删除/拖放已验证 |
| 最近任务及链接 | 临时显示3条记录，记录/全部历史/关联资料/网页面板均打开；输入草稿后清空并关闭，数据哈希一致 | 检查的网页面板均无关联网页，未新增真实链接来测试编辑/保存/解除；隔离动作测试覆盖这些写路径 |

原生源码回调原先已接通，但这没有证明普通鼠标点击有效。本轮用真实鼠标复现后才修改图标手势与命中区域；没有把辅助功能动作成功升级为鼠标验收成功。

## 原生根因对照与源码修复

### 菜单设置空窗

`XNookApp` 的 `Settings { EmptyView() }` 生成默认Settings菜单并打开空内容窗；面板齿轮使用 `AppDelegate.openPreferences()` 打开完整设置。现在用 `CommandGroup(replacing: .appSettings)` 将“设置…”和Cmd+,统一转发给后者，保留已有设置窗复用及环境注入。

### 图标子手势与命中区域

本机截图中光标精确位于齿轮/关闭图标并有悬停蓝光，但首次及悬停后再次点击均不执行；同一坐标体系下点击日历文字导航成功。随后以当前生产 `IconMotion` 为输入制作任务专用原生对照窗，不连接个人数据：

| 输入 | A 原样 | B 只加contentShape | C 只关闭子Drag | D 两项同时 |
| --- | --- | --- | --- | --- |
| 中心第一次，累计计数 | 0 | 0 | 1 | 1 |
| 中心第二次，累计计数 | 0 | 0 | 2 | 2 |
| 右边缘，累计计数 | 0 | 1 | 2 | 3 |

结论限定于这个受控原生对照：零距离子Drag阻止Button中心动作；明确的矩形点击区域还恢复了26pt框内、字形外的点击。修改为：

- `IconMotion` 移除子 `DragGesture(minimumDistance: 0)` 和对应按压状态，保留悬停动画；不让装饰图标接管父Button手势。
- `ExpandedPanelView.headerButton` 在26×26 frame后添加 `contentShape(Rectangle())`。

最终v2探针直接编译修复后的生产 `IconMotion.swift`（SHA-256 `09a0a0025feac9d05ed56e356015ce7dea84c7d2a8fea4febe946e6d4a1cf119`），设置和关闭分别经历中心一次、边缘一次，两个计数均为2。测试输入是CUA鼠标坐标点击，不是AXPress或直接调用闭包。原版/修复版探针均已退出。

生产源文件中只有3处属于本次修复：`XNookApp.swift`、`IconMotion.swift`、`ExpandedPanelView.swift` 的header点击区域。其余已有未提交界面改动保留。

## 回归与数据保护

运行命令：

```sh
XNOOK_RENDER_UI=1 scripts/test-signed-bookmarks.sh --filter '(FocusSessionManagerTests|NookFlowActionsTests|TaskLinkEditingTests|TrayManagerTests|CalendarManagerTests|NotchWindowInteractionTests|ExpandedAutoHideControllerTests|NotchContentViewTests|PanelKeyboardActionTests|TaskLinkEditorPreviewTests/testLinkEditingKeepsResourcePopoverOpenUntilFinished|TaskLinksReleasePreviewTests/testTaskLinksProtectAutomaticCollapseWithoutBlockingExplicitHandoff|ScriptingBridgeHelperTests)'
```

结果：145 tests，0 failures，进程退出0。使用独立签名书签测试宿主；没有安装测试应用或替换本机 X Nook。

第一次原型检查时111份Swift源码/测试文件保持不变。用户批准本机验收后的续轮新增上述3处原生修复；再次记录并核对 `notes.json`、`tray_files.json`、主偏好域与独立NookFlow域的 `nookflow.sessions`，哈希均未变化。两项临时设置已恢复为1秒/关闭，安装包哈希不变。

续轮运行 `swift test --filter IslandIntegrationSettingsTests`，7项通过；随后 `XNOOK_RENDER_UI=1 swift test --filter 'IconMotionTests|NotchWindowInteractionTests|NotchWindowVisibilityTests'`，14项通过且无跳过。`swift build -c release` 退出0，构建成功。图标与窗口自动测试不能替代上述真实鼠标对照；菜单路由本轮未新增依赖SwiftUI私有值树的脆弱测试。

证据位于 `.build/control-audit-20261024/`：

- `preview-checks.json`：34项成功断言及最初失败/修复记录。
- `native-tests.log`：145项回归。
- `integrity.json`：安装包、对照稿、源码和个人数据一致性记录。
- `settings-preview.jpg`、`overview-preview.jpg`：修复后的浏览器预览截图。
- `native-live/blank-menu-settings.png`：本机菜单设置空窗。
- `native-live/hit-probe-result.png`、`mouse-hit-regression.json`：原样与三种变体的真实鼠标结果。
- `native-live/fixed-mouse-result.png`、`.txt`：最终生产图标的中心/边缘验收。
- `native-live/restored.json`：临时设置恢复、个人数据与安装包保持不变。
- `native-live/release-build.log`：Release构建。
- `native-live/native-button-fixes.patch`、`patch-manifest.json`：以HEAD `4d41e5f` 为基线、排除旧界面改动的3文件独立补丁；`git apply --check --cached`通过，尚未应用到索引、提交或安装。

对照稿 SHA-256：`d6ca406ea2f1b6c0c5b7e3893011baa23d20d6f01bbfa8221b6c95553b6323cd`。
