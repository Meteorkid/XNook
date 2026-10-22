# 实现来源

- `windows/src-tauri/src/windowing.rs` 以作者现有 XIsland Windows 窗口模块为基础，新增 XNook 窗口接入与联动显示权保护；保留多屏/DPI、全屏和拖动测试。
- `windows/crates/island-link` 是本次为 XNook/XIsland 编写的共同协议实现，分别随两个项目分发，构建不依赖相邻仓库路径。
- Windows 图标从本仓库 `Assets/app-icon.png` 通过 Tauri 图标工具生成。
- 日历解析使用 ICAL.js；界面不复制其他第三方灵动岛项目代码。依赖版本由 package-lock.json / Cargo.lock 固定。
- 现有软件许可证保持不变；本轮不发布或向第三方上传代码和产物。
