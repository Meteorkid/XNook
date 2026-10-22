# 核心工作流最终验收

日期：2026-09-18。状态：通过。未执行 Git 提交或发布。

## 验收结果

| 要求 | 当前实现与证据 | 结果 |
| --- | --- | --- |
| 笔记全部列表、搜索、改名、删除撤销、导出 | NotesWidgetView 详情使用完整列表；NotesManagerTests 覆盖超出概览范围的搜索、中英文内容、草稿与标题同时保存、恢复原位置、导出原文及内部存储保护 | 通过 |
| 日历完整日程与刷新 | CalendarManagerTests 覆盖已结束/进行中/未来事件、午夜边界、授权变化、前台及日期通知、长休眠后的日期范围；详情渲染已检查 | 通过 |
| 任务创建、资料关联、历史重开与旧数据 | FocusSessionManagerTests 覆盖手动任务、旧 JSON 和书签持久化；NookFlowActionsTests 覆盖结束、重载、打开笔记、文件架清理后仍保留独立引用，以及旧引用回退和失败状态 | 通过 |
| 首轮可靠性与流畅度修复 | 笔记/文件架损坏数据保护、自动收起单任务与取消、GIF 暂停/恢复/替换/释放回归测试保持通过 | 通过 |
| 概览、详情、窄屏和长内容 | WorkflowPreviewTests 正式 XCTest 运行，渲染 7 个隔离场景；检查 800pt / 160pt 概览、320pt 笔记与日历详情、深浅色和历史区域 | 通过 |
| 键盘、动效与输入路由 | PanelKeyboardActionTests 覆盖导航、新建、保存和不抢占文字命令；代码核对系统/应用动效开关；NotchWindowInteractionTests 验证展开不拖窗、收起仍可拖窗 | 通过 |
| 构建、签名和差异 | 标准 Xcode 工具链下 Release 打包、严格签名检查、git diff --check | 通过 |
| 文档与总结 | README、CHANGELOG、WORKFLOWS、设计说明及 Obsidian 总结已同步 | 完成 |

## 实际执行

工具链为 Apple Swift 6.4，项目最低部署目标仍为 macOS 14。

```sh
swift test
XNOOK_RENDER_UI=1 swift test --filter 'WorkflowPreviewTests|NotchWindowInteractionTests'
XNOOK_BUILD_DMG=0 bash build-app.sh
codesign --verify --deep --strict '.build/X Nook.app'
git diff --check
```

- 常规运行发现 238 项测试，236 项执行通过，2 项 UI 测试按配置跳过，0 失败。
- 随后显式开启 UI 验证，两项均执行通过，0 跳过、0 失败。合计 238 项测试均已实际执行通过。
- 本轮使用正常 Xcode 工具链，没有设置关闭预览的编译标志。
- 测试包位置为 `.build/X Nook.app`，未安装到 Applications、未发布、未提交 Git。

## 验证范围

界面与输入验证使用隐藏窗口、临时笔记/文件架和独立任务存储；日历使用注入事件，没有修改用户真实业务数据。截图输出到 `/tmp/xnook-workflow-ui/`，已检查宽窄布局和可读性。

外部日历授权、真实多显示器切换和持续运行的帧率/能耗未做现场测量；本报告不承诺未经测量的性能提升比例。Swift 6.4 对三处测试中的局部 weak var 给出“未修改”提示，不影响构建或测试；保留该写法以兼容项目的 Swift 5.9 工具版本。

此前 Xcode 许可未确认造成的测试阻塞已经解除，本报告替代 2026-09-17 总结中的待验收状态。
