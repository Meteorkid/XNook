import SwiftUI

/// 面板的度量与节奏 token。
///
/// 存在的理由：面板层此前散落着 `12`、`10`、`8`、`0.2` 这类字面量，
/// 同一个视觉意图在不同文件里取值不一致，改一处要全局搜。
/// 这里给出单一事实源，新增代码优先引用 token；旧的字面量按需逐步替换。
enum IslandTokens {

    // MARK: - 间距（8pt 基准，含半档）

    enum Spacing {
        /// 4pt — 行内图标与文字
        static let inline: CGFloat = 4
        /// 6pt — 紧密控件组
        static let tight: CGFloat = 6
        /// 8pt — 默认控件间距
        static let compact: CGFloat = 8
        /// 12pt — 卡片内边距 / 卡片间距
        static let standard: CGFloat = 12
        /// 14pt — 段落间距
        static let section: CGFloat = 14
        /// 20pt — 分组之间
        static let group: CGFloat = 20
    }

    // MARK: - 圆角

    enum Radius {
        /// 6pt — 小图标底板
        static let chip: CGFloat = 6
        /// 7pt — 导航按钮
        static let control: CGFloat = 7
        /// 8pt — 封面 / 缩略图
        static let thumbnail: CGFloat = 8
        /// 10pt — 卡片
        static let card: CGFloat = 10
        /// 14pt — 浮层容器
        static let sheet: CGFloat = 14
    }

    // MARK: - 字号

    enum Font {
        /// 9pt — 元数据、时间戳
        static let micro: CGFloat = 9
        /// 10pt — 滚动文字
        static let caption: CGFloat = 10
        /// 11pt — 次要正文
        static let small: CGFloat = 11
        /// 12pt — 正文
        static let body: CGFloat = 12
        /// 13pt — 标题
        static let title: CGFloat = 13
        /// 16pt — 播放控制等主操作
        static let action: CGFloat = 16
    }

    // MARK: - 动效时长

    enum Duration {
        /// 0.12s — 内容退场
        static let fast: TimeInterval = 0.12
        /// 0.2s — 默认淡入淡出
        static let standard: TimeInterval = 0.2
        /// 0.25s — 文本切换
        static let text: TimeInterval = 0.25
        /// 0.45s — 形状形变后的窗口收尾
        static let shapeSettle: TimeInterval = 0.45
        /// 0.65s — 收起后重新允许悬停展开的冷却
        static let hoverCooldown: TimeInterval = 0.65
    }

    // MARK: - 缓动曲线

    enum Easing {
        /// 入场主曲线 — 起步快、尾部慢，适合内容出现
        static var out: Animation { .timingCurve(0.16, 1, 0.3, 1, duration: Duration.standard) }
        /// 尺寸形变 — 两端都缓，避免边缘被裁切
        static var soft: Animation { .timingCurve(0.4, 0, 0.2, 1, duration: Duration.standard) }
        /// 带轻微过冲的弹簧 — 用于强调性位移
        static var springy: Animation { .timingCurve(0.34, 1.1, 0.4, 1, duration: Duration.standard) }
    }

    // MARK: - 布局

    enum Layout {
        /// 卡片最小宽度，用于列数计算
        static let cardMinWidth: CGFloat = 272
        /// 标题、导航与窗口操作共享的工具栏高度
        static let headerHeight: CGFloat = 40
    }
}
