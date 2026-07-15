# 展开面板最大高度设置

## 目标

恢复面板高度调节入口，与 X Island 的 `panelMaxHeight` 上限语义保持一致，确保展开动画从顶部锚定向下丝滑展开。

## 交互

- 在「显示 → 面板尺寸」中提供「面板最大高度」滑块。
- 范围由 `NotchWindow.maximumExpandedContentSize()` 动态确定，默认 400pt。
- 文案说明：该值控制展开面板的高度上限；内容不足时按实际高度展开，超出时裁切。

## 行为

- `panelBaseHeight` 的 UserDefaults 默认值与 `@AppStorage` 绑定。
- 展开面板高度为 `min(内容计算高度, panelBaseHeight)`，与 X Island 一致。
- `cachedExpandedShapeHeight` 与 `expandedHeight` 使用同一计算，保证圆角/阴影过渡与形状展开同步。
- `NotchWindow` 继续负责屏幕边界保护。

## 验收与测试

- 内容较少时，面板高度等于内容自然高度（不被撑高），展开动画从顶部向下丝滑过渡。
- 内容超过 `panelBaseHeight` 时，面板高度裁切到上限。
- 设置入口、默认值和本地化文案均可用。
