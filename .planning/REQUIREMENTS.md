# REQUIREMENTS.md

## v1 Requirements

### Core (CORE)

- [ ] **CORE-01**: 应用启动时自动检测 Notch 区域并适配窗口位置
- [ ] **CORE-02**: 窗口支持浮动层级（statusBar + 1），始终在最上层
- [ ] **CORE-03**: 窗口支持水平拖动，记住用户自定义位置
- [ ] **CORE-04**: 支持多显示器，窗口跟随鼠标所在屏幕
- [ ] **CORE-05**: 支持 Space 切换，在所有 Space 可见
- [ ] **CORE-06**: 支持全屏适配，全屏时自动隐藏

### App Switcher (SWITCH)

- [ ] **SWITCH-01**: 实现独立 URL Scheme（xnook://island/show 与 xisland://island/show）接收切换请求
- [ ] **SWITCH-02**: 实现 AppSwitcher 类，支持切换到 X Island
- [ ] **SWITCH-03**: 双指滑动手势触发应用切换
- [ ] **SWITCH-04**: 切换时显示过渡动画

### UI (UI)

- [ ] **UI-01**: 收起状态显示小药丸（应用图标 + 名称缩写）
- [ ] **UI-02**: 展开状态显示完整 Widget 内容
- [ ] **UI-03**: 鼠标悬停自动展开
- [ ] **UI-04**: 点击外部区域自动收起
- [ ] **UI-05**: 展开/收起使用弹簧动画

### Media Widget (MEDIA)

- [ ] **MEDIA-01**: 显示当前播放歌曲标题和艺术家
- [ ] **MEDIA-02**: 显示专辑封面
- [ ] **MEDIA-03**: 播放/暂停控制按钮
- [ ] **MEDIA-04**: 上一曲/下一曲控制
- [ ] **MEDIA-05**: 音量调节滑块

### Calendar Widget (CAL)

- [ ] **CAL-01**: 请求日历访问权限
- [ ] **CAL-02**: 显示即将到来的事件（按时间排序）
- [ ] **CAL-03**: 显示事件标题、时间、地点
- [ ] **CAL-04**: 支持点击事件打开系统日历

### Notes Widget (NOTE)

- [ ] **NOTE-01**: 支持创建新笔记
- [ ] **NOTE-02**: 支持 Markdown 语法高亮
- [ ] **NOTE-03**: 支持编辑和保存笔记
- [ ] **NOTE-04**: 支持删除笔记

### Tray Widget (TRAY)

- [ ] **TRAY-01**: 支持拖放文件到文件架
- [ ] **TRAY-02**: 显示文件图标和名称
- [ ] **TRAY-03**: 支持点击打开文件
- [ ] **TRAY-04**: 支持从文件架移除文件

### Settings (SET)

- [ ] **SET-01**: 通用设置（全屏隐藏、悬停展开等）
- [ ] **SET-02**: Widget 启用/禁用开关
- [ ] **SET-03**: 关于页面（版本信息、链接）

## v2 Requirements

### Weather Widget (WEATHER)

- [ ] **WEATHER-01**: 显示当前天气状况
- [ ] **WEATHER-02**: 显示温度和天气图标
- [ ] **WEATHER-03**: 支持天气动画效果

### Pomodoro Widget (POMO)

- [ ] **POMO-01**: 番茄钟计时器
- [ ] **POMO-02**: 工作/休息交替
- [ ] **POMO-03**: 统计完成的番茄数

### Bluetooth Widget (BT)

- [ ] **BT-01**: 显示已连接的蓝牙设备
- [ ] **BT-02**: 显示设备电量
- [ ] **BT-03**: 支持快速连接/断开

## Out of Scope

- AI Agent 监控 — X Island 的功能，不重复实现
- App Store 发布 — 先 GitHub Release，后续考虑
- 实时歌词显示 — 复杂度高，v2 考虑
- 网络速度监控 — 非核心功能，v2 考虑

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| CORE-01 | Phase 1 | Planned |
| CORE-02 | Phase 1 | Planned |
| CORE-03 | Phase 1 | Planned |
| CORE-04 | Phase 1 | Planned |
| CORE-05 | Phase 1 | Planned |
| CORE-06 | Phase 1 | Planned |
| SWITCH-01 | Phase 1 | Planned |
| SWITCH-02 | Phase 1 | Planned |
| SWITCH-03 | Phase 1 | Planned |
| SWITCH-04 | Phase 1 | Planned |
| UI-01 | Phase 1 | Planned |
| UI-02 | Phase 1 | Planned |
| UI-03 | Phase 1 | Planned |
| UI-04 | Phase 1 | Planned |
| UI-05 | Phase 1 | Planned |
| MEDIA-01 | Phase 2 | Planned |
| MEDIA-02 | Phase 2 | Planned |
| MEDIA-03 | Phase 2 | Planned |
| MEDIA-04 | Phase 2 | Planned |
| MEDIA-05 | Phase 2 | Planned |
| CAL-01 | Phase 2 | Planned |
| CAL-02 | Phase 2 | Planned |
| CAL-03 | Phase 2 | Planned |
| CAL-04 | Phase 2 | Planned |
| NOTE-01 | Phase 3 | Planned |
| NOTE-02 | Phase 3 | Planned |
| NOTE-03 | Phase 3 | Planned |
| NOTE-04 | Phase 3 | Planned |
| TRAY-01 | Phase 3 | Planned |
| TRAY-02 | Phase 3 | Planned |
| TRAY-03 | Phase 3 | Planned |
| TRAY-04 | Phase 3 | Planned |
| SET-01 | Phase 4 | Planned |
| SET-02 | Phase 4 | Planned |
| SET-03 | Phase 4 | Planned |

---
*Last updated: 2026-06-13 after initialization*
