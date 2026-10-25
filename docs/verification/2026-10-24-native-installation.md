# 2026-10-24 本机候选版安装验收

## 交付

- `52ae04a`：整合遗漏功能，优化默认空态、进度定位和快捷唤出。
- `5bb008c`：修复安装验收发现的设置控制器错绑，以及真实 AppleScript 布尔返回值被误判失败。
- `78e1c73`：修复退出布局编辑时正常测量先到、父级编辑状态后更新造成的高度残留。
- 本机 `/Applications/X Nook.app` 已更新为 1.3.21 本地候选版，源码版本 `78e1c73`。未推送或发布。
- 安装后二进制 SHA256：`b004566bc18a5f2709df6cc98f9914dcfb0ca39fc63ef4ebf16ee6beac72f362`。
- arm64 Release 构建及严格深度签名校验通过；本机 XIsland 2.0.10 未被替换。

## 验证结果

| 项目 | 结果与边界 |
| --- | --- |
| 完整回归 | 在 `5bb008c` 上执行 971 项：967 通过，4 条件跳过，0 失败。 |
| 最后适配修复 | 在 `78e1c73` 上执行 83 项相关回归：82 通过，1 条件跳过，0 失败；包含新增 6 项测量时序测试。未将这组针对性测试称为全量重跑。 |
| 默认空态 | 实际安装窗口中验证未播放媒体、未授权日历、空文件托盘和空任务入口完整；默认概览约 800 × 295 pt，无需手工调整。 |
| 退出布局编辑 | 原先取消后残留约 400 pt 高度；最终安装版取消后立即收缩至内容高度，无需再次收起再展开。 |
| 播放器定位 | 实际点击 XNook 进度轨道后，Apple Music 定位、回读与歌词更新正常；暂停状态不被定位操作改变。先前实际命令成功却误报权限失败的问题已修正。 |
| 连续拖动 | 自动化工具的 drag 未产生可确认的指针移动；后续用户明确确认“拖动能跳转”，以手工反馈补记通过。 |
| 快捷唤出 | 实际设置窗口完成录制、Carbon 注册、重启保留、清除。排除配置时点歧义后，用户仍反馈物理按键无反应，未通过触发验收。2026-10-25 用户明确取消此功能的配置与排查；已清除临时组合、恢复 1 秒自动收起，不再作为本轮交付的验收项。 |
| 设置和关闭 | 设置窗口、布局入口、取消和收起操作均已实际操作。 |

测试模拟的 AppleScript handler 不含外部 `tell`，只用于确认真实 `typeTrue/typeFalse` 描述符；播放器定位则由已安装应用的真实按钮操作验收，二者分开记录。

## 恢复与数据

- 安装前备份时间为 2026-10-24 20:59（北京时间）。三个偏好域 `com.meteorkid.xnook`、`com.meteorkid.xnook.nookflow`、`dev.xisland.integration` 已逐键比较，与备份完全一致。
- 已恢复保存的媒体／文件托盘／日历网格、1 秒自动收起、最近任务关闭、未设置快捷键及原背景设置。
- 已恢复 XIsland 显示；更新后的 XNook 保持后台运行。临时快捷键已经清除，不能再用测试组合键验收。
- 保存网格 Data SHA256：`2fa8353bdfe44d700296620a1d809613518e25e80025903167b65248ed77b471`。
- 笔记、托盘、待办文件存在状态和 NookFlow 数据均未改变。未授权新的日历或自动化权限。
- Music 曾为测试媒体空态正常退出，随后重开并选回原曲《Je sais pas》，恢复暂停及约 1:18（78.66 秒，原 78.857 秒）。原播放队列顺序未核对，不宣称完整播放器上下文恢复。
- 测试工具发送的全局组合键曾被 Finder 解释为“用所选项目新建文件夹”；已通过两次撤销恢复应用路径，并重新核对安装包 SHA256。
- 原安装包 ZIP 已通过 CRC 检查，保留可回滚备份。

## 本机证据

证据目录：`.build/feature-reintegration-20261024/delivery/`（包含私有配置备份，不应提交或发布）。

- `final-installation.json`、`final-verification.json`、`restoration.json`、`business-data-comparison.json`
- `settings-lifecycle-red-v2.log` / `settings-lifecycle-green.log`
- `seek-boolean-red.log` / `seek-boolean-green.log`
- `fixed-full-tests.log`、`panel-transition-tests.log`、`final-release-build.log`
- `ui/empty-default-reopened.png`、`ui/final-editor-cancel.png`、`ui/music-context-restored.png`
- `ui/shortcut-registered.png`、`ui/shortcut-cleared.txt`、`ui/restored-settings.txt`

用户已确认完整鼠标拖动能跳转。全局快捷键按用户要求停止排查，不标记为修复或验收通过。2026-10-25 已在重启后的设置窗口确认“未启用／未设置”及“1.00s”，其余偏好未改；保持复验前用户正在使用的 XNook 显示状态。
