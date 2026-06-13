# X Nook 架构规划

> 基于对 NotchNook、X Island、NookX 三个应用的逆向分析

---

## 一、竞品分析总结

### 1. NotchNook（闭源商业软件）

**核心功能**：
- 媒体播放控制（Apple Music/Spotify）
- 日历 Widget
- 笔记 Widget（代码/Markdown）
- 文件架 Tray
- 快捷指令集成
- 摄像头镜像
- 蓝牙设备显示
- 波浪动画（Perlin Noise）
- 流体渐变（FluidGradient）

**技术栈**：
- Swift/SwiftUI + AppKit
- Lottie 4.5.0（动画）
- Sparkle 2.6.4（更新）
- RichTextKit（富文本）
- Highlightr（代码高亮）

**架构特点**：
- 单体应用，功能聚合
- 使用私有 MediaRemote API
- 自定义 Pipeline 扩展系统

---

### 2. X Island（开源 AI Agent 监控）

**核心功能**：
- 多 Agent 监控（Claude Code、Cursor 等 19 种）
- 权限审批、问题回答、计划审查
- 终端跳转（iTerm2 标签级精确）
- 活动日志、工具事件详情
- SSH 远程管理
- 配额追踪
- Subagent 嵌套可视化

**技术栈**：
- Swift/SwiftUI（纯代码）
- Unix Socket 通信
- 零配置管理（ZeroConfigManager）

**架构特点**：
- 开源可学习
- SessionManager 核心状态机
- SocketServer 与 Agent 通信
- 56 个 Swift 文件，结构清晰

---

### 3. NookX（闭源，功能最丰富）

**核心功能**：
- 媒体播放 + 实时歌词弹幕
- 待办事项 + 日历同步 + 提醒同步
- 天气显示 + 动画
- 番茄钟 + 统计
- AI 聊天 + 弹幕
- 笔记编辑器（WKWebView）
- 网络速度监控
- 电池监控
- 快捷启动
- 热键管理
- 文件预览

**技术栈**：
- Swift/SwiftUI + AppKit
- WKWebView（笔记编辑器）
- AppleScript（音乐/浏览器集成）
- 自定义字体（Alimama 系列）
- InfomaniakRichHTMLEditor

**架构特点**：
- 功能极其丰富（50+ 个类）
- 使用 WKWebView 实现富文本编辑
- 多服务架构（MusicService、WeatherService 等）
- 缓存系统完善（ImageCache、WidgetCache 等）

---

## 二、X Nook 定位

### 目标用户
- 需要桌面增强工具的 Mac 用户
- 想要 NotchNook 功能但不想付费的用户
- 开发者（可扩展）

### 核心差异化
1. **开源免费** — MIT 许可
2. **应用切换** — 与 X Island 联动
3. **模块化** — 可选功能，按需启用
4. **现代架构** — Swift Concurrency、Observation

---

## 三、功能规划

### Phase 1：核心基础（当前）

| 功能 | 状态 | 优先级 |
|------|------|--------|
| Notch 检测与适配 | ✅ 完成 | P0 |
| 窗口管理 | ✅ 完成 | P0 |
| 应用切换（X Island） | ✅ 完成 | P0 |
| 基础 UI（收起/展开） | ✅ 完成 | P0 |
| 设置界面 | ✅ 完成 | P1 |

### Phase 2：Widget 系统

| 功能 | 状态 | 优先级 |
|------|------|--------|
| 媒体播放 Widget | 🟡 骨架 | P0 |
| 日历 Widget | 🟡 骨架 | P0 |
| 笔记 Widget | 🟡 骨架 | P1 |
| 文件架 Tray | 🟡 骨架 | P1 |
| 天气 Widget | ⬜ 待做 | P2 |
| 番茄钟 Widget | ⬜ 待做 | P2 |

### Phase 3：高级功能

| 功能 | 状态 | 优先级 |
|------|------|--------|
| 波浪动画 | ⬜ 待做 | P2 |
| 流体渐变 | ⬜ 待做 | P2 |
| 触觉反馈 | ⬜ 待做 | P2 |
| 快捷指令集成 | ⬜ 待做 | P2 |
| 蓝牙设备显示 | ⬜ 待做 | P3 |

---

## 四、技术架构

### 目录结构

```
XNook/
├── Package.swift
├── Sources/XNook/
│   ├── App/
│   │   ├── XNookApp.swift              # 入口
│   │   └── AppDelegate.swift           # 应用委托
│   │
│   ├── Core/                           # 核心模块
│   │   ├── NotchWindow.swift           # 窗口管理
│   │   ├── NotchDetector.swift         # 刘海检测
│   │   ├── NotchViewModel.swift        # 状态管理
│   │   └── AppSwitcher.swift           # 应用切换
│   │
│   ├── Features/                       # 功能模块
│   │   ├── NotchContentView.swift      # 主界面
│   │   │
│   │   ├── MediaWidget/                # 媒体播放
│   │   │   ├── MediaManager.swift
│   │   │   └── MediaWidgetView.swift
│   │   │
│   │   ├── CalendarWidget/             # 日历
│   │   │   ├── CalendarManager.swift
│   │   │   └── CalendarWidgetView.swift
│   │   │
│   │   ├── NotesWidget/                # 笔记
│   │   │   ├── NotesManager.swift
│   │   │   └── NotesWidgetView.swift
│   │   │
│   │   ├── TrayWidget/                 # 文件架
│   │   │   ├── TrayManager.swift
│   │   │   └── TrayWidgetView.swift
│   │   │
│   │   ├── WeatherWidget/              # 天气
│   │   │   ├── WeatherManager.swift
│   │   │   └── WeatherWidgetView.swift
│   │   │
│   │   └── PomodoroWidget/             # 番茄钟
│   │       ├── PomodoroManager.swift
│   │       └── PomodoroWidgetView.swift
│   │
│   ├── Managers/                       # 服务管理器
│   │   ├── MusicService.swift          # 音乐服务
│   │   ├── CalendarSyncService.swift   # 日历同步
│   │   ├── WeatherService.swift        # 天气服务
│   │   ├── NetworkMonitor.swift        # 网络监控
│   │   ├── BatteryManager.swift        # 电池管理
│   │   └── HapticManager.swift         # 触觉反馈
│   │
│   ├── UI/                             # 通用 UI 组件
│   │   ├── WaveView.swift              # 波浪动画
│   │   ├── FluidGradientView.swift     # 流体渐变
│   │   └── Components/
│   │
│   ├── Settings/                       # 设置
│   │   ├── SettingsView.swift
│   │   └── PreferencesManager.swift
│   │
│   └── Utils/                          # 工具类
│       ├── PerlinNoise.swift           # 噪声生成
│       └── Constants.swift
│
└── Resources/
    ├── Assets.xcassets/
    └── Localizable.xcstrings
```

### 核心模块详解

#### 1. NotchWindow（借鉴 X Island）

```swift
// 核心功能
- 多显示器支持
- Space 切换适配
- 全屏检测
- 水平拖动
- 窗口层级管理（statusBar + 1）

// 关键属性
- isFloatingPanel: true
- level: .statusBar + 1
- collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
```

#### 2. AppSwitcher（X Nook 独创）

```swift
// 切换机制
1. URL Scheme: xnook://activate / xisland://activate
2. AppleScript: tell application "X Island" to activate
3. 双指滑动手势触发

// 切换流程
用户双指左滑 → 检测手势 → 调用 AppSwitcher → URL Scheme 通知目标应用 → 目标应用激活
```

#### 3. Widget 系统

```swift
// 每个 Widget 包含
- Manager: 数据管理（ObservableObject）
- View: 界面展示（View）
- Settings: 配置项（可选）

// 数据流
Manager → @Published → View → 用户交互 → Manager
```

---

## 五、从 NookX 学习的架构模式

### 1. 多服务架构

```swift
// NookX 的服务划分
MusicService        // 音乐播放
WeatherService      // 天气数据
CalendarSyncService // 日历同步
ReminderSyncService // 提醒同步
ShortcutsService    // 快捷指令
MailService         // 邮件
ChromeService       // Chrome 浏览器
SafariService       // Safari 浏览器

// 优点
- 职责单一
- 易于测试
- 可独立启用/禁用
```

### 2. 缓存系统

```swift
// NookX 的缓存
ImageCache          // 图片缓存
AppIconCache        // 应用图标缓存
WidgetCacheManager  // Widget 缓存
PhotoCacheManager   // 照片缓存

// 优点
- 减少重复加载
- 提升性能
- 支持离线使用
```

### 3. 监控系统

```swift
// NookX 的监控
SystemMonitor       // 系统状态
VolumeMonitor       // 音量监听
NetworkAvailabilityMonitor // 网络状态
BatteryManager      // 电池状态

// 优点
- 实时响应系统变化
- 统一管理监听器
- 避免内存泄漏
```

---

## 六、开发路线图

### Phase 1：MVP（2 周）

- [x] 项目框架搭建
- [x] Notch 检测与窗口管理
- [x] 应用切换功能
- [x] 基础 UI（收起/展开）
- [ ] 媒体播放 Widget
- [ ] 日历 Widget

### Phase 2：功能完善（4 周）

- [ ] 笔记 Widget
- [ ] 文件架 Tray
- [ ] 天气 Widget
- [ ] 番茄钟 Widget
- [ ] 设置界面完善

### Phase 3：高级功能（4 周）

- [ ] 波浪动画
- [ ] 流体渐变
- [ ] 触觉反馈
- [ ] 快捷指令集成
- [ ] 蓝牙设备显示

### Phase 4：发布（2 周）

- [ ] 打包 DMG
- [ ] GitHub Release
- [ ] 文档完善
- [ ] 社区推广

---

## 七、技术决策

### 1. UI 框架选择

**选择**：SwiftUI + AppKit 混合

**原因**：
- SwiftUI 用于 Widget 视图（声明式、易维护）
- AppKit 用于窗口管理（NSWindow 控制更精细）
- 参考 X Island 和 NookX 的实现

### 2. 状态管理

**选择**：@Observable（Swift 5.9+）

**原因**：
- 比 ObservableObject 更高效
- 支持细粒度更新
- 与 SwiftUI 深度集成

### 3. 数据持久化

**选择**：UserDefaults + FileManager

**原因**：
- UserDefaults：轻量配置
- FileManager：笔记、文件等大数据
- 参考 NookX 的缓存模式

### 4. 音乐集成

**选择**：AppleScript + MediaPlayer

**原因**：
- AppleScript：控制 Music.app 和 Spotify
- MediaPlayer：系统媒体控制
- 注意：MediaRemote 是私有 API，App Store 有限制

---

## 八、风险与对策

| 风险 | 影响 | 对策 |
|------|------|------|
| MediaRemote 私有 API | App Store 审核 | 使用 AppleScript 替代 |
| 多显示器兼容性 | 用户体验 | 参考 X Island 的实现 |
| 内存泄漏 | 稳定性 | 使用 weak self、及时移除监听 |
| 性能问题 | 流畅度 | 缓存系统、懒加载 |

---

*最后更新：2026-06-13*
