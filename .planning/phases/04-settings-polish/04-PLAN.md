---
plan_id: 04-settings-polish
phase: 4
wave: 1
depends_on:
  - 03-notes-tray
requirements:
  - SET-01
  - SET-02
  - SET-03
files_modified:
  - Sources/XNook/Settings/SettingsView.swift
  - Sources/XNook/Core/NotchWindow.swift
  - Sources/XNook/Features/NotchContentView.swift
autonomous: true
---

# Phase 4: Settings & Polish

## Objective

实现设置界面和整体优化。

## Tasks

### TASK-4.1: 实现 SettingsView 通用设置

**read_first:**
- Sources/XNook/Settings/SettingsView.swift
- Sources/XNook/Core/NotchWindow.swift

**acceptance_criteria:**
- SettingsView 能显示通用设置
- 支持全屏隐藏开关
- 支持悬停展开开关
- 支持显示在所有 Space 开关
- 设置保存到 UserDefaults

**action:**
1. 在 `SettingsView.swift` 中实现通用设置界面
2. 添加全屏隐藏开关（hideInFullscreen）
3. 添加悬停展开开关（hoverToExpand）
4. 添加显示在所有 Space 开关（showOnAllSpaces）
5. 使用 @AppStorage 保存设置到 UserDefaults
6. 在 NotchWindow 中读取设置并应用

---

### TASK-4.2: 实现 Widget 启用/禁用开关

**read_first:**
- Sources/XNook/Settings/SettingsView.swift
- Sources/XNook/Features/NotchContentView.swift

**acceptance_criteria:**
- SettingsView 能显示 Widget 启用/禁用开关
- 支持媒体 Widget 启用/禁用
- 支持日历 Widget 启用/禁用
- 支持笔记 Widget 启用/禁用
- 支持文件架 Widget 启用/禁用
- 设置保存到 UserDefaults

**action:**
1. 在 `SettingsView.swift` 中实现 Widget 设置界面
2. 添加媒体 Widget 启用/禁用开关
3. 添加日历 Widget 启用/禁用开关
4. 添加笔记 Widget 启用/禁用开关
5. 添加文件架 Widget 启用/禁用开关
6. 使用 @AppStorage 保存设置到 UserDefaults
7. 在 NotchContentView 中读取设置并控制 Widget 显示

---

### TASK-4.3: 实现关于页面

**read_first:**
- Sources/XNook/Settings/SettingsView.swift

**acceptance_criteria:**
- SettingsView 能显示关于页面
- 显示版本信息
- 显示应用图标和名称
- 显示作者信息
- 显示 GitHub 链接

**action:**
1. 在 `SettingsView.swift` 中实现关于页面
2. 显示版本信息（Bundle.main.infoDictionary）
3. 显示应用图标和名称
4. 显示作者信息
5. 显示 GitHub 链接

---

### TASK-4.4: 整体优化和测试

**read_first:**
- Sources/XNook/App/XNookApp.swift
- Sources/XNook/App/AppDelegate.swift
- Sources/XNook/Core/NotchWindow.swift
- Sources/XNook/Core/NotchViewModel.swift
- Sources/XNook/Features/NotchContentView.swift

**acceptance_criteria:**
- 应用启动正常
- 所有 Widget 功能正常
- 设置保存和读取正常
- 动画流畅
- 无内存泄漏

**action:**
1. 测试应用启动流程
2. 测试所有 Widget 功能
3. 测试设置保存和读取
4. 测试动画效果
5. 检查内存泄漏
6. 修复发现的问题

---

## Verification

- [ ] 设置界面正常显示
- [ ] 通用设置（全屏隐藏、悬停展开、显示在所有 Space）正常
- [ ] Widget 启用/禁用正常
- [ ] 关于页面正常显示
- [ ] 所有功能正常
- [ ] 动画流畅
- [ ] 无内存泄漏

## must_haves

- SettingsView 显示所有设置
- 设置保存到 UserDefaults
- 设置读取和应用正常
- 关于页面显示版本和链接
- 整体优化完成

## Risks

- 设置保存需要 UserDefaults
- 不同 macOS 版本 API 差异
- 动画性能需要优化

## Dependencies

- Phase 3: Notes & Tray
