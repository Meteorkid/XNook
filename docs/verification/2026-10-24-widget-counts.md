# 组件选择与数量适配验证

日期：2026-10-24。用户要求确认组件是否可单独或组合显示，并检查不同数量的布局。

## 功能结论

可以在“设置 → 显示 → Widget选择”独立开关媒体、日历、笔记、文件托盘。允许0–4个组件，组合共16种。显示顺序固定，当前没有拖动排序入口；单个组件仍使用设定的面板宽度，不会因数量减少而自动改写宽度。

当前源码在常用800pt宽度下的规则：

| 数量 | 布局 | 任务区 |
| --- | --- | --- |
| 0 | 无组件提示，仍保留设置入口 | 提示下方 |
| 1 | 一列一行 | 组件下方 |
| 2 | 两列一行 | 组件下方 |
| 3 | 三列一行 | 组件下方 |
| 4 | 两列两行 | 全部组件下方 |

320pt时改为单列；504–751pt最多两列；达到1000pt可容纳四列。行高按本行最高组件计算，窗口高度按内容计算，并受屏幕可用高度/手动高度限制，超出部分滚动。数量变化不会留下已关闭组件的空白单元格。三个组件并排的既定要求在默认800pt下保留。

这些规则是当前源码与隔离生产视图验证的结果，不代表本机旧安装包已经更新。

## 本轮修复

### 开关保存后仍显示旧状态

实机将日历和托盘关闭后，`enabledWidgets` 已保存为仅媒体，但同一设置页仍把两个开关显示为on；切换设置页签后才刷新。截图/AX与偏好读回已交叉确认，不能把UI开关旧状态当成保存失败。

根因：SettingsView的计算属性直接读UserDefaults，视图未观察这个数据键。现在用 `@AppStorage("enabledWidgets") Data` 读写同一份存储，保留不存在或无法解码时默认全开的行为。修复已编译；真实设置页持续挂载的修复后验收仍待完整候选运行，离屏AX没有提供可操作子节点。

### 等高组合切换丢失高度测量

父视图在组合变化时清空旧测量，但测量只有宽、高、详情选择。移除较矮组件后总高不变，PreferenceKey没有变化，便不再回调，父层可能保持400pt回退高度。

新增回归真实复现：`[media, calendar, tray] → [media, calendar]`，高度都为326pt，修复前回调数保持1；修复后变为2。测量现在携带有序组件组合，组合变化触发回写，同时父层拒绝旧组合的异步测量。

相关文件：

- `Sources/XNook/Core/ExpandedPanelLayout.swift`
- `Sources/XNook/Features/ExpandedPanelView.swift`
- `Sources/XNook/Features/NotchContentView.swift`
- `Sources/XNook/Settings/SettingsView.swift`
- `Tests/XNookTests/AdaptiveWorkflowPreviewTests.swift`
- `Tests/XNookTests/ExpandedPanelLayoutTests.swift`

已有未提交界面与上轮按钮修复保留，没有为了本轮验证安装或发布新版本。

## 测试与图像检查

最终40项测试通过，0失败，覆盖：

- 全部16组合 × 800/320pt，共32个生产视图host场景。
- 同一个host中的16次数量往返切换，检查无残留组件、无多余网格占位。
- 卡片几何不重叠，任务区位于组件之后；0组件空态的80pt留白有可见提示，不是残留卡片。
- 真实内容、长标题、窄宽、详情往返、短屏滚动与测量身份校验。
- 旧组合测量拒绝；等高组合切换从失败转为通过。

另外人工查看了单媒体、四组件和窄宽相关截图。矩阵是隔离数据及离屏NSHostingView验证，`realWindowAcceptance=false`；不把图像渲染当作原生完整窗口、动画或跨屏验收。视觉仍待按参考对照稿落实，本轮没有重新设计组件外观。

复现：

```sh
XNOOK_RENDER_UI=1 XNOOK_UI_EVIDENCE_DIR="$PWD/.build/widget-count-evidence-20261024/final" \
swift test --filter 'AdaptiveWorkflowPreviewTests|WorkflowPreviewTests|ExpandedPanelLayoutTests|IslandIntegrationSettingsTests'
```

Release构建：`swift build -c release`。

## 本机安装包检查与限制

实际安装包仍为1.3.19，SHA-256 `561656511a5e6dd10c82ea783f3e21d2247ac8989a20ac869ca91c55d0f6cbd4`，未替换。

本轮实机成功保存并读取了仅媒体、媒体+日历两种组合，面板导航随开关变化。但展开截图仍只能显示顶部及部分NookFlow，组件正文没有完整展示，因此不能认定本机显示正常。不能将未知源码归属的安装包截图直接归因于当前源码的等高测量问题。

准备切到三个组件时，控制工具对该应用窗口持续返回 `timeoutReached`；重新绑定与重置连接仍失败。进程样本显示主线程等待正常事件循环，没有据此认定应用崩溃或死锁，也没有强退应用。实机3/4组件测试因此未完成；0/1/2/3/4的完整覆盖来自上述隔离矩阵。

## 配置恢复与数据保护

原配置：媒体/日历/托盘开，笔记关；宽度800；自动高度true；最近任务关闭；无操作1秒自动收起。

测试临时把自动收起改为30秒，并切换组件选择。控制工具持续超时后，先确认当前偏好仍是本轮留下的媒体+日历与30秒，再仅用macOS `defaults` 恢复 `enabledWidgets` 和 `expandedInactivityAutoHideDelay` 两键，未覆盖整个偏好域。

读回确认原组件集合及1秒均已恢复；`notes.json`、`tray_files.json`、两个域的任务负载哈希不变，安装包哈希不变。控制工具未恢复，因此恢复后的运行界面没有重新截图，不将偏好读回当成实时界面验收。

## 证据目录

`.build/widget-count-evidence-20261024/`：

- `final-summary.json`、`final-regression.log`：组合、几何、测试结果及输入源码哈希。
- `measurement-red.log`、`measurement-red/`：修复前等高切换失败。
- `final/widget-measurement-callbacks.json`：修复后回调1→2。
- `final/widget-matrix-*.png/json`：32组合场景。
- `native/stale-toggle-state.txt`：实机设置页旧开关状态。
- `native/one-media.*`、`native/two-media-calendar.*`：实机窗口未完整显示的证据。
- `native/restored.json`：偏好恢复、数据/安装包不变及运行界面复验限制。
- `release-build.log`：Release构建记录。
