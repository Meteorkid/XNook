---
plan_id: 01-core-foundation
phase: 1
wave: 1
depends_on: []
requirements:
  - CORE-01
  - CORE-02
  - CORE-03
  - CORE-04
  - CORE-05
  - CORE-06
  - SWITCH-01
  - SWITCH-02
  - SWITCH-03
  - SWITCH-04
  - UI-01
  - UI-02
  - UI-03
  - UI-04
  - UI-05
files_modified:
  - Sources/XNook/App/XNookApp.swift
  - Sources/XNook/App/AppDelegate.swift
  - Sources/XNook/Core/NotchWindow.swift
  - Sources/XNook/Core/NotchViewModel.swift
  - Sources/XNook/Core/AppSwitcher.swift
  - Sources/XNook/Features/NotchContentView.swift
autonomous: true
---

# Phase 1: Core Foundation

## Objective

实现 X Nook 的核心窗口管理、应用切换和基础 UI 功能，建立可运行的 Notch 风格浮动窗口。

## Tasks

### TASK-1.1: 完善 NotchWindow 核心功能

**read_first:**
- Sources/XNook/Core/NotchWindow.swift
- Sources/XNook/App/AppDelegate.swift

**acceptance_criteria:**
- NotchWindow 能正确检测 Notch 区域（NSScreen.safeAreaInsets）
- 窗口始终在最上层（level = .statusBar + 1）
- 窗口支持水平拖动，记住自定义位置（customX 属性）
- 支持多显示器，窗口跟随鼠标所在屏幕
- 支持 Space 切换（collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]）
- 全屏时自动隐藏（activeSpaceDidChange 通知）

**action:**
1. 在 `NotchWindow.swift` 中验证 `isObscuredByPhysicalNotch()` 方法正确检测 Notch
2. 确认 `applySpaceBehavior()` 正确设置 `collectionBehavior`
3. 确认 `followMouseIfScreenChanged()` 实现多显示器跟随
4. 确认 `sendEvent()` 实现水平拖动逻辑
5. 确认 `activeSpaceDidChange()` 实现全屏隐藏逻辑
6. 确认 `resizeToFit()` 和 `resizeToFitCollapse()` 实现窗口尺寸调整

---

### TASK-1.2: 完善 AppSwitcher 应用切换

**read_first:**
- Sources/XNook/Core/AppSwitcher.swift
- Sources/XNook/Core/NotchViewModel.swift

**acceptance_criteria:**
- AppSwitcher 能通过 URL Scheme（xnook://activate / xisland://activate）切换应用
- AppSwitcher 能通过 AppleScript 备选方案切换应用
- `isOtherAppRunning()` 正确检测另一个应用是否运行
- `otherAppName` 返回正确的应用名称

**action:**
1. 在 `AppSwitcher.swift` 中验证 `switchToXIsland()` 和 `switchToXNook()` 方法
2. 确认 URL Scheme 和 AppleScript 双重切换机制
3. 确认 `isOtherAppRunning()` 使用 `NSRunningApplication` 检测

---

### TASK-1.3: 完善 NotchViewModel 状态管理

**read_first:**
- Sources/XNook/Core/NotchViewModel.swift
- Sources/XNook/Core/AppSwitcher.swift

**acceptance_criteria:**
- NotchViewModel 正确管理三种状态（collapsed、expanded、switching）
- `expand()` 和 `collapse()` 使用弹簧动画
- `toggleExpansion()` 正确切换状态
- `switchToOtherApp()` 调用 AppSwitcher 并更新 currentApp

**action:**
1. 在 `NotchViewModel.swift` 中验证状态枚举和 Published 属性
2. 确认 `expand()` 和 `collapse()` 使用 `.spring(response: 0.3, dampingFraction: 0.8)`
3. 确认 `switchToOtherApp()` 更新 `currentApp` 并调用 `AppSwitcher.shared.switchToOtherApp()`

---

### TASK-1.4: 完善 NotchContentView UI

**read_first:**
- Sources/XNook/Features/NotchContentView.swift
- Sources/XNook/Core/NotchViewModel.swift

**acceptance_criteria:**
- 收起状态显示小药丸（应用图标 + 名称缩写）
- 展开状态显示完整 Widget 内容
- 鼠标悬停自动展开（onHover）
- 点击外部区域自动收起（通过窗口失去焦点）
- 展开/收起使用弹簧动画

**action:**
1. 在 `NotchContentView.swift` 中验证 `collapsedContent` 显示小药丸
2. 确认 `expandedContent` 显示完整内容
3. 确认 `.onHover` 修饰符实现悬停展开
4. 确认动画使用 `.spring(response: 0.3, dampingFraction: 0.8)`

---

### TASK-1.5: 完善 AppDelegate 集成

**read_first:**
- Sources/XNook/App/AppDelegate.swift
- Sources/XNook/Core/NotchWindow.swift
- Sources/XNook/Features/NotchContentView.swift

**acceptance_criteria:**
- AppDelegate 正确设置 NotchWindow 和 NotchContentView
- 菜单栏图标正常显示
- URL Scheme（xnook://activate）正确处理
- 应用启动时自动显示 Notch 窗口

**action:**
1. 在 `AppDelegate.swift` 中验证 `setupNotchWindow()` 创建 NotchWindow 并添加 NotchContentView
2. 确认 `setupMenuBarItem()` 创建菜单栏图标和菜单
3. 确认 `application(_:open:)` 处理 URL Scheme
4. 确认 `applicationDidFinishLaunching` 调用 `setupNotchWindow()` 和 `setupMenuBarItem()`

---

### TASK-1.6: 创建 Info.plist URL Scheme 配置

**read_first:**
- Info.plist（如果存在）

**acceptance_criteria:**
- Info.plist 包含 CFBundleURLTypes 配置
- URL Scheme 包含 xnook
- URL Scheme 支持 http 和 https

**action:**
1. 检查是否存在 Info.plist 文件
2. 如果不存在，创建 Info.plist 并添加 URL Scheme 配置
3. 如果存在，添加 URL Scheme 配置

---

## Verification

- [ ] 应用能正常启动，显示 Notch 窗口
- [ ] 窗口在最上层，支持水平拖动
- [ ] 鼠标悬停自动展开，点击外部自动收起
- [ ] 多显示器支持正常
- [ ] Space 切换正常
- [ ] 全屏隐藏正常
- [ ] 菜单栏图标正常
- [ ] URL Scheme（xnook://activate）正常

## must_haves

- NotchWindow 能正确显示在 Notch 区域
- 窗口支持水平拖动
- 窗口支持多显示器跟随
- 窗口支持 Space 切换
- 窗口支持全屏隐藏
- 应用切换功能正常
- 基础 UI（收起/展开）正常

## Risks

- 多显示器测试需要实际环境验证
- Space 切换在不同 macOS 版本可能有差异
- 全屏检测依赖系统 API，可能有兼容性问题

## Dependencies

- 无外部依赖
