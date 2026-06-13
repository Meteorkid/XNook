# X Nook

## What This Is

X Nook 是一款 macOS 灵动岛风格的工具中心应用，作为 X Island 的配套软件。它提供媒体播放、日历、笔记、文件架等实用功能，用户可以通过双指滑动在 X Nook 和 X Island 之间快速切换。目标用户是需要桌面增强工具的 Mac 用户，特别是开发者。

## Core Value

在屏幕顶部提供一个紧凑、可快速访问的工具中心，让用户无需切换窗口即可访问常用功能。

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] Notch 检测与适配（多显示器、Space 切换、全屏适配）
- [ ] 窗口管理（浮动窗口、层级控制、水平拖动）
- [ ] 应用切换功能（与 X Island 双指滑动切换）
- [ ] 基础 UI（收起/展开状态、切换指示器）
- [ ] 媒体播放 Widget（播放控制、专辑封面）
- [ ] 日历 Widget（显示即将到来的事件）
- [ ] 笔记 Widget（Markdown 编辑器）
- [ ] 文件架 Tray（拖放文件、快速访问）
- [ ] 设置界面（通用设置、Widget 配置）

### Out of Scope

- AI Agent 监控（X Island 的功能，不重复实现）
- 天气 Widget（v2 版本）
- 番茄钟 Widget（v2 版本）
- 蓝牙设备显示（v2 版本）
- 摄像头镜像（v2 版本）
- App Store 发布（先 GitHub Release）

## Context

### 竞品分析

- **NotchNook**：闭源商业软件，$25 买断，功能丰富（媒体、日历、笔记、文件架、蓝牙、摄像头）
- **X Island**：开源 AI Agent 监控器，MIT 许可，已有 Notch 窗口管理实现
- **NookX**：闭源全能工具箱，功能最丰富（50+ 类），使用 WKWebView 实现笔记编辑器

### 技术决策

- 基于 X Island 的 NotchWindow 实现进行扩展
- 使用 SwiftUI + AppKit 混合架构
- 使用 @Observable（Swift 5.9+）进行状态管理
- 使用 UserDefaults + FileManager 进行数据持久化

## Constraints

- **Tech Stack**: Swift/SwiftUI + AppKit，macOS 14.0+
- **Dependencies**: 与 X Island 保持架构一致性
- **Performance**: 窗口动画需流畅（60fps），避免卡顿
- **Compatibility**: 支持所有带 Notch 的 MacBook 和外接显示器

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| 从 X Island 借鉴 NotchWindow | 复用成熟的窗口管理实现，减少开发时间 | ✓ Good |
| 使用 URL Scheme 进行应用切换 | 标准的 macOS 应用间通信方式，简单可靠 | — Pending |
| 使用 SwiftUI + AppKit 混合 | SwiftUI 用于 Widget 视图，AppKit 用于窗口管理 | — Pending |
| 开源免费（MIT 许可） | 社区共建，与 X Island 保持一致 | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-06-13 after initialization*
