import SwiftUI

/// 图标级微动效。
///
/// 参考实现（TO-DO-Panel 的 `icon-motion.js`）靠 SVG 的 `stroke-dasharray`
/// 从 `.1 .9` 补到 `1 0`，即"描边画出来"。
///
/// 本项目提供两条实现路径，由 `IslandCapabilities.useNativeSymbolDraw` 选择：
///
/// **路径 A：遮罩扫出（默认）**
/// 用一条随进度变宽的矩形遮住图标，产生"从左到右画出来"的观感。
/// 只依赖 `mask`，macOS 14 到 26 走同一条代码路径，初始 `drawProgress = 1`
/// 保证图标**任何情况下都可见**。
///
/// **路径 B：系统原生 `.drawOn`（macOS 26+，默认关闭）**
/// 效果更接近真正的描边绘制，但有一个必须避开的陷阱——
/// `isActive` 是**状态**语义而非触发语义。已用离屏渲染实证：
/// - `isActive = false` → 齿轮完整可见
/// - `isActive = true`  → 完全空白（图标不可见）
///
/// 也就是说 `.drawOn` 等价于「`.disappear` 的绘制版」，而不是「播放一次绘制动画」。
/// 一旦某条路径让状态停在 `true`，图标会**永久消失**。因此这里做成严格的两段式：
/// 先置 `true`（擦除）→ 短暂延迟后置 `false`（绘制出现），并挂超时兜底强制归位。
struct IconMotionModifier: ViewModifier {
    /// 触发绘制动画的值；变化时重放一次扫出
    var trigger: Int
    /// 是否处于悬停态
    var isHovering: Bool
    /// 是否处于按下态
    var isPressed: Bool
    /// 空闲时是否持续呼吸
    var breathing: Bool
    /// 是否遵循"减少动态效果"
    var reduceMotion: Bool

    @State private var drawProgress: CGFloat = 1
    @State private var breathPhase = false
    @State private var lastTrigger: Int?
    /// 原生 drawOn 的 isActive 状态。**必须最终回到 false**，否则图标不可见。
    @State private var nativeDrawErasing = false
    /// 用于作废过期的原生动画回调
    @State private var nativeDrawGeneration = 0

    private var useNativeDraw: Bool {
        IslandCapabilities.supportsNativeSymbolDraw && IslandCapabilities.useNativeSymbolDraw
    }

    func body(content: Content) -> some View {
        applyMotion(to: applyDrawEffect(to: content))
    }

    /// 绘制效果层：按能力选择原生或遮罩。
    @ViewBuilder
    private func applyDrawEffect(to content: Content) -> some View {
        if useNativeDraw {
            if #available(macOS 26.0, *) {
                content
                    .symbolEffect(.drawOn, isActive: nativeDrawErasing)
                    .onChange(of: trigger) { _, newValue in
                        guard lastTrigger != newValue else { return }
                        lastTrigger = newValue
                        replayNativeDraw()
                    }
                    .onAppear { lastTrigger = trigger }
            } else {
                maskedDraw(content)
            }
        } else {
            maskedDraw(content)
        }
    }

    private func maskedDraw(_ content: Content) -> some View {
        content
            // 扫出遮罩：进度不足 1 时只显示左侧部分，模拟描边逐段画出
            .mask(alignment: .leading) {
                GeometryReader { geometry in
                    Rectangle()
                        .frame(width: geometry.size.width * drawProgress)
                }
            }
            .onAppear {
                lastTrigger = trigger
                if breathing && !reduceMotion { breathPhase = true }
            }
            .onChange(of: trigger) { _, newValue in
                guard lastTrigger != newValue else { return }
                lastTrigger = newValue
                replayDraw()
            }
    }

    /// 通用动效层：悬停 / 按下 / 呼吸，与绘制方案无关。
    private func applyMotion<V: View>(to content: V) -> some View {
        content
            .scaleEffect(scale)
            .brightness(isHovering && !reduceMotion ? 0.06 : 0)
            .offset(y: isHovering && !reduceMotion ? -1 : 0)
            .opacity(breathOpacity)
            .animation(
                reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.6),
                value: isHovering
            )
            .animation(
                reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.7),
                value: isPressed
            )
            .animation(
                breathing && !reduceMotion
                    ? .easeInOut(duration: 1.6).repeatForever(autoreverses: true)
                    : .default,
                value: breathPhase
            )
            .onChange(of: breathing) { _, enabled in
                breathPhase = enabled && !reduceMotion
            }
    }

    private var scale: CGFloat {
        guard !reduceMotion else { return 1 }
        if isPressed { return 0.94 }
        if isHovering { return 1.08 }
        return 1
    }

    private var breathOpacity: Double {
        guard breathing, !reduceMotion else { return 1 }
        return breathPhase ? 0.55 : 1
    }

    /// 重放一次遮罩扫出：先把遮罩收成 0，再动画放到 1。
    ///
    /// 两步必须落在**不同的渲染周期**：同一帧内写 0 再写 1，SwiftUI 合并后
    /// 看到的最终值与之前相同，会判定"值未变"而跳过动画。因此先同步落到 0，
    /// 再用 `DispatchQueue.main.async` 在下一轮启动动画。
    private func replayDraw() {
        guard !reduceMotion else { return }
        drawProgress = 0
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.42)) {
                drawProgress = 1
            }
        }
    }

    /// 重放一次原生绘制。
    ///
    /// 两段式：先擦除（isActive = true），再绘制出现（isActive = false）。
    /// 超时兜底是无条件的安全网——即使中间某个回调被丢弃，
    /// 也保证 `nativeDrawErasing` 最终回到 `false`，图标不会停在不可见状态。
    private func replayNativeDraw() {
        guard !reduceMotion else { return }
        nativeDrawGeneration += 1
        let generation = nativeDrawGeneration
        nativeDrawErasing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            guard generation == nativeDrawGeneration else { return }
            nativeDrawErasing = false
        }
        // 兜底：无论中途发生什么，0.5s 后强制归位到可见状态
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard generation == nativeDrawGeneration else { return }
            nativeDrawErasing = false
        }
    }
}

extension View {
    /// 给图标加悬停 / 按下反馈，可选扫出与空闲呼吸。
    func iconMotion(
        trigger: Int = 0,
        isHovering: Bool = false,
        isPressed: Bool = false,
        breathing: Bool = false,
        reduceMotion: Bool = false
    ) -> some View {
        modifier(IconMotionModifier(
            trigger: trigger,
            isHovering: isHovering,
            isPressed: isPressed,
            breathing: breathing,
            reduceMotion: reduceMotion
        ))
    }
}

/// 自带悬停状态的图标；点击和按压交由外层按钮处理。
///
/// 指针进入时自动递增 `trigger` 重放一次扫出，因此调用方只需给出图标名。
/// 指针离开不重放——来回移动指针时反复播放会显得躁动。
struct MotionIcon: View {
    let systemName: String
    var fontSize: CGFloat = 12
    var breathing: Bool = false
    var reduceMotion: Bool = false

    @State private var isHovering = false
    @State private var drawTrigger = 0

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: fontSize, weight: .medium))
            .iconMotion(
                trigger: drawTrigger,
                isHovering: isHovering,
                isPressed: false,
                breathing: breathing,
                reduceMotion: reduceMotion
            )
            .onHover { hovering in
                isHovering = hovering
                if hovering && !reduceMotion { drawTrigger += 1 }
            }
    }
}

