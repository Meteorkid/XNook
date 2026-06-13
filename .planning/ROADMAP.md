# ROADMAP.md

## Overview

**4 phases** | **34 requirements mapped** | All v1 requirements covered ✓

| # | Phase | Goal | Requirements | Success Criteria |
|---|-------|------|--------------|------------------|
| 1 | Core Foundation | 基础框架搭建，实现窗口管理和应用切换 | CORE-01~06, SWITCH-01~04, UI-01~05 | 15 |
| 2 | Media & Calendar | 实现媒体播放和日历 Widget | MEDIA-01~05, CAL-01~04 | 9 |
| 3 | Notes & Tray | 实现笔记和文件架 Widget | NOTE-01~04, TRAY-01~04 | 8 |
| 4 | Settings & Polish | 设置界面完善和整体优化 | SET-01~03 | 3 |

---

## Phase 1: Core Foundation

**Goal:** 搭建项目核心框架，实现 Notch 窗口管理、应用切换和基础 UI

**Mode:** mvp

**Requirements:**
- CORE-01: 应用启动时自动检测 Notch 区域并适配窗口位置
- CORE-02: 窗口支持浮动层级（statusBar + 1），始终在最上层
- CORE-03: 窗口支持水平拖动，记住用户自定义位置
- CORE-04: 支持多显示器，窗口跟随鼠标所在屏幕
- CORE-05: 支持 Space 切换，在所有 Space 可见
- CORE-06: 支持全屏适配，全屏时自动隐藏
- SWITCH-01: 实现 URL Scheme（xnook://activate）接收切换请求
- SWITCH-02: 实现 AppSwitcher 类，支持切换到 X Island
- SWITCH-03: 双指滑动手势触发应用切换
- SWITCH-04: 切换时显示过渡动画
- UI-01: 收起状态显示小药丸（应用图标 + 名称缩写）
- UI-02: 展开状态显示完整 Widget 内容
- UI-03: 鼠标悬停自动展开
- UI-04: 点击外部区域自动收起
- UI-05: 展开/收起使用弹簧动画

**Success Criteria:**
1. 应用启动后在屏幕顶部显示小药丸
2. 鼠标悬停时展开显示 Widget 区域
3. 双指滑动可以切换到 X Island
4. 窗口在多显示器间正确跟随
5. 窗口在 Space 切换时保持可见

**Plans:**
1. `PLAN-1.1` — 项目框架搭建和 NotchWindow 核心实现
2. `PLAN-1.2` — 应用切换功能实现
3. `PLAN-1.3` — 基础 UI 和动画实现

---

## Phase 2: Media & Calendar

**Goal:** 实现媒体播放控制和日历事件显示

**Mode:** mvp

**Requirements:**
- MEDIA-01: 显示当前播放歌曲标题和艺术家
- MEDIA-02: 显示专辑封面
- MEDIA-03: 播放/暂停控制按钮
- MEDIA-04: 上一曲/下一曲控制
- MEDIA-05: 音量调节滑块
- CAL-01: 请求日历访问权限
- CAL-02: 显示即将到来的事件（按时间排序）
- CAL-03: 显示事件标题、时间、地点
- CAL-04: 支持点击事件打开系统日历

**Success Criteria:**
1. 媒体 Widget 显示当前播放信息
2. 可以通过 Widget 控制播放
3. 日历 Widget 显示即将到来的事件
4. 点击事件可以打开系统日历

**Plans:**
1. `PLAN-2.1` — 媒体播放 Widget 实现
2. `PLAN-2.2` — 日历 Widget 实现

---

## Phase 3: Notes & Tray

**Goal:** 实现笔记编辑器和文件架功能

**Mode:** mvp

**Requirements:**
- NOTE-01: 支持创建新笔记
- NOTE-02: 支持 Markdown 语法高亮
- NOTE-03: 支持编辑和保存笔记
- NOTE-04: 支持删除笔记
- TRAY-01: 支持拖放文件到文件架
- TRAY-02: 显示文件图标和名称
- TRAY-03: 支持点击打开文件
- TRAY-04: 支持从文件架移除文件

**Success Criteria:**
1. 可以创建和编辑笔记
2. 笔记支持 Markdown 语法
3. 可以拖放文件到文件架
4. 可以从文件架打开文件

**Plans:**
1. `PLAN-3.1` — 笔记 Widget 实现
2. `PLAN-3.2` — 文件架 Tray 实现

---

## Phase 4: Settings & Polish

**Goal:** 完善设置界面，整体优化和测试

**Mode:** mvp

**Requirements:**
- SET-01: 通用设置（全屏隐藏、悬停展开等）
- SET-02: Widget 启用/禁用开关
- SET-03: 关于页面（版本信息、链接）

**Success Criteria:**
1. 设置界面可以修改所有配置
2. 可以启用/禁用各个 Widget
3. 关于页面显示正确的版本信息

**Plans:**
1. `PLAN-4.1` — 设置界面实现
2. `PLAN-4.2` — 整体优化和测试

---

## Milestones

| Milestone | Phases | Target Date |
|-----------|--------|-------------|
| M1: MVP | Phase 1-4 | 2026-07-11 |

---

*Last updated: 2026-06-13 after initialization*
