---
plan_id: 02-media-calendar
phase: 2
wave: 1
depends_on:
  - 01-core-foundation
requirements:
  - MEDIA-01
  - MEDIA-02
  - MEDIA-03
  - MEDIA-04
  - MEDIA-05
  - CAL-01
  - CAL-02
  - CAL-03
  - CAL-04
files_modified:
  - Sources/XNook/Features/MediaWidget/MediaManager.swift
  - Sources/XNook/Features/CalendarWidget/CalendarManager.swift
  - Sources/XNook/Features/MediaWidget/MediaWidgetView.swift
  - Sources/XNook/Features/CalendarWidget/CalendarWidgetView.swift
  - Sources/XNook/Features/NotchContentView.swift
autonomous: true
---

# Phase 2: Media & Calendar Widgets

## Objective

实现媒体播放控制和日历事件显示两个核心 Widget 功能。

## Tasks

### TASK-2.1: 实现 MediaManager 媒体播放控制

**read_first:**
- Sources/XNook/Features/MediaWidget/MediaManager.swift
- Sources/XNook/Features/NotchContentView.swift

**acceptance_criteria:**
- MediaManager 能获取当前播放歌曲标题和艺术家
- MediaManager 能获取专辑封面（NSImage）
- MediaManager 支持播放/暂停控制
- MediaManager 支持上一曲/下一曲控制
- MediaManager 支持音量调节

**action:**
1. 在 `MediaManager.swift` 中实现 `NowPlayingInfo` 结构体
2. 实现 `fetchNowPlaying()` 方法获取当前播放信息
3. 实现 `playPause()`、`next()`、`previous()` 控制方法
4. 实现 `setVolume()` 音量调节方法
5. 添加定时轮询机制更新播放信息
6. 创建 `MediaWidgetView.swift` 显示媒体播放界面

---

### TASK-2.2: 实现 CalendarManager 日历事件

**read_first:**
- Sources/XNook/Features/CalendarWidget/CalendarManager.swift
- Sources/XNook/Features/NotchContentView.swift

**acceptance_criteria:**
- CalendarManager 能请求日历访问权限
- CalendarManager 能获取即将到来的事件（按时间排序）
- CalendarManager 能获取事件标题、时间、地点
- CalendarManager 支持点击事件打开系统日历

**action:**
1. 在 `CalendarManager.swift` 中实现 `CalendarEvent` 结构体
2. 实现 `requestAccess()` 请求日历权限
3. 实现 `fetchUpcomingEvents()` 获取即将到来的事件
4. 实现 `openEventInCalendar()` 打开系统日历
5. 创建 `CalendarWidgetView.swift` 显示日历事件列表

---

### TASK-2.3: 集成 MediaWidget 到 NotchContentView

**read_first:**
- Sources/XNook/Features/NotchContentView.swift
- Sources/XNook/Features/MediaWidget/MediaWidgetView.swift
- Sources/XNook/Core/NotchViewModel.swift

**acceptance_criteria:**
- NotchContentView 能显示 MediaWidget
- 点击媒体按钮显示媒体播放界面
- 媒体播放界面显示歌曲信息和控制按钮
- 媒体播放界面支持播放/暂停、上一曲/下一曲

**action:**
1. 在 `NotchContentView.swift` 中添加 `@StateObject var mediaManager = MediaManager()`
2. 修改 `xnookPreview` 中的媒体按钮，点击时显示 `MediaWidgetView`
3. 添加 `selectedWidget` 状态管理当前显示的 Widget
4. 在展开内容区显示选中的 Widget

---

### TASK-2.4: 集成 CalendarWidget 到 NotchContentView

**read_first:**
- Sources/XNook/Features/NotchContentView.swift
- Sources/XNook/Features/CalendarWidget/CalendarWidgetView.swift
- Sources/XNook/Core/NotchViewModel.swift

**acceptance_criteria:**
- NotchContentView 能显示 CalendarWidget
- 点击日历按钮显示日历事件列表
- 日历事件列表显示事件标题、时间、地点
- 点击事件能打开系统日历

**action:**
1. 在 `NotchContentView.swift` 中添加 `@StateObject var calendarManager = CalendarManager()`
2. 修改 `xnookPreview` 中的日历按钮，点击时显示 `CalendarWidgetView`
3. 添加 `selectedWidget` 状态管理当前显示的 Widget
4. 在展开内容区显示选中的 Widget

---

## Verification

- [ ] 媒体播放控制正常（播放/暂停、上一曲/下一曲、音量）
- [ ] 媒体播放界面显示歌曲信息和专辑封面
- [ ] 日历事件列表正常显示
- [ ] 点击事件能打开系统日历
- [ ] Widget 切换正常

## must_haves

- MediaManager 能获取当前播放信息
- MediaManager 支持播放控制
- CalendarManager 能获取日历事件
- CalendarManager 支持打开系统日历
- Widget 集成到 NotchContentView

## Risks

- 媒体播放信息获取依赖系统 API
- 日历权限需要用户授权
- 不同 macOS 版本 API 差异

## Dependencies

- Phase 1: Core Foundation
