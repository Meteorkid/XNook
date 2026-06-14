---
plan_id: 03-notes-tray
phase: 3
wave: 1
depends_on:
  - 02-media-calendar
requirements:
  - NOTE-01
  - NOTE-02
  - NOTE-03
  - NOTE-04
  - TRAY-01
  - TRAY-02
  - TRAY-03
  - TRAY-04
files_modified:
  - Sources/XNook/Features/NotesWidget/NotesManager.swift
  - Sources/XNook/Features/TrayWidget/TrayManager.swift
  - Sources/XNook/Features/NotesWidget/NotesWidgetView.swift
  - Sources/XNook/Features/TrayWidget/TrayWidgetView.swift
  - Sources/XNook/Features/NotchContentView.swift
autonomous: true
---

# Phase 3: Notes & Tray Widgets

## Objective

实现笔记编辑器和文件架两个 Widget 功能。

## Tasks

### TASK-3.1: 实现 NotesManager 笔记管理

**read_first:**
- Sources/XNook/Features/NotesWidget/NotesManager.swift
- Sources/XNook/Features/NotchContentView.swift

**acceptance_criteria:**
- NotesManager 能创建新笔记
- NotesManager 能保存笔记到本地存储
- NotesManager 能加载笔记列表
- NotesManager 能删除笔记

**action:**
1. 在 `NotesManager.swift` 中实现 `Note` 结构体
2. 实现 `createNote()` 创建新笔记
3. 实现 `saveNote()` 保存笔记
4. 实现 `loadNotes()` 加载笔记列表
5. 实现 `deleteNote()` 删除笔记
6. 使用 UserDefaults 或文件系统存储笔记
7. 创建 `NotesWidgetView.swift` 显示笔记列表和编辑器

---

### TASK-3.2: 实现 TrayManager 文件架

**read_first:**
- Sources/XNook/Features/TrayWidget/TrayManager.swift
- Sources/XNook/Features/NotchContentView.swift

**acceptance_criteria:**
- TrayManager 能接收拖放文件
- TrayManager 能显示文件图标和名称
- TrayManager 能点击打开文件
- TrayManager 能从文件架移除文件

**action:**
1. 在 `TrayManager.swift` 中实现 `TrayFile` 结构体
2. 实现 `addFile()` 添加文件到文件架
3. 实现 `removeFile()` 从文件架移除文件
4. 实现 `openFile()` 打开文件
5. 实现 `loadFiles()` 加载文件列表
6. 使用 UserDefaults 或文件系统存储文件列表
7. 创建 `TrayWidgetView.swift` 显示文件架界面

---

### TASK-3.3: 集成 NotesWidget 到 NotchContentView

**read_first:**
- Sources/XNook/Features/NotchContentView.swift
- Sources/XNook/Features/NotesWidget/NotesWidgetView.swift
- Sources/XNook/Core/NotchViewModel.swift

**acceptance_criteria:**
- NotchContentView 能显示 NotesWidget
- 点击笔记按钮显示笔记列表和编辑器
- 笔记编辑器支持 Markdown 语法高亮
- 笔记编辑器支持编辑和保存

**action:**
1. 在 `NotchContentView.swift` 中添加 `@StateObject var notesManager = NotesManager()`
2. 修改 `xnookPreview` 中的笔记按钮，点击时显示 `NotesWidgetView`
3. 添加 `selectedWidget` 状态管理当前显示的 Widget
4. 在展开内容区显示选中的 Widget

---

### TASK-3.4: 集成 TrayWidget 到 NotchContentView

**read_first:**
- Sources/XNook/Features/NotchContentView.swift
- Sources/XNook/Features/TrayWidget/TrayWidgetView.swift
- Sources/XNook/Core/NotchViewModel.swift

**acceptance_criteria:**
- NotchContentView 能显示 TrayWidget
- 点击文件架按钮显示文件架界面
- 文件架支持拖放文件
- 文件架显示文件图标和名称

**action:**
1. 在 `NotchContentView.swift` 中添加 `@StateObject var trayManager = TrayManager()`
2. 修改 `xnookPreview` 中的文件架按钮，点击时显示 `TrayWidgetView`
3. 添加 `selectedWidget` 状态管理当前显示的 Widget
4. 在展开内容区显示选中的 Widget

---

## Verification

- [ ] 笔记创建、编辑、保存、删除正常
- [ ] 笔记编辑器支持 Markdown 语法高亮
- [ ] 文件架支持拖放文件
- [ ] 文件架显示文件图标和名称
- [ ] 点击文件能打开
- [ ] Widget 切换正常

## must_haves

- NotesManager 能管理笔记
- NotesWidgetView 显示笔记列表和编辑器
- TrayManager 能管理文件
- TrayWidgetView 显示文件架
- Widget 集成到 NotchContentView

## Risks

- 笔记存储需要本地持久化
- 文件架拖放需要系统权限
- Markdown 语法高亮需要额外库

## Dependencies

- Phase 2: Media & Calendar
