import SwiftUI
import AppKit
import QuartzCore

/// GIF 动画视图 — 播放时动画，暂停时冻结
struct GifView: NSViewRepresentable {
    let gifData: Data
    let isPlaying: Bool
    let targetSize: NSSize

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: NSRect(origin: .zero, size: targetSize))
        container.wantsLayer = true

        let imageView = NSImageView(frame: container.bounds)
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        container.addSubview(imageView)

        // 初始化 GIF 帧信息（不启动动画）
        context.coordinator.setupAnimation(gifData: gifData, imageView: imageView)

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.frame = NSRect(origin: .zero, size: targetSize)

        // 检测 GIF 数据变化，重新加载动画
        if context.coordinator.currentGifData != gifData {
            if let imageView = nsView.subviews.first as? NSImageView {
                context.coordinator.setupAnimation(gifData: gifData, imageView: imageView)
            }
        }

        if isPlaying {
            context.coordinator.resumeAnimation()
        } else {
            context.coordinator.pauseAnimation()
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.dismantle()
    }

    class Coordinator {
        private var displayLink: GifDisplayLinkDriving?
        private let displayLinkFactory: (NSView, @escaping () -> Void) -> GifDisplayLinkDriving
        private let clock: () -> TimeInterval
        private var source: CGImageSource?
        private var frameCount: Int = 0
        private var currentFrame: Int = 0
        private var frameDurations: [TimeInterval] = []
        private var lastFrameTime: TimeInterval = 0
        private var isAnimating: Bool = false
        private var isDismantled = false
        private var animationGeneration = 0
        private weak var imageView: NSImageView?
        private(set) var currentGifData: Data?

        init(
            displayLinkFactory: @escaping (NSView, @escaping () -> Void) -> GifDisplayLinkDriving = {
                ViewGifDisplayLink(view: $0, callback: $1)
            },
            clock: @escaping () -> TimeInterval = CACurrentMediaTime
        ) {
            self.displayLinkFactory = displayLinkFactory
            self.clock = clock
        }

        func setupAnimation(gifData: Data, imageView: NSImageView) {
            guard !isDismantled else { return }
            let wasAnimating = isAnimating
            clearAnimation()

            self.imageView = imageView
            self.currentGifData = gifData

            imageView.image = nil
            guard let resource = try? GifResource(data: gifData) else {
                return
            }
            let source = resource.source
            guard let firstImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                return
            }
            imageView.image = NSImage(cgImage: firstImage, size: imageView.frame.size)
            self.frameCount = resource.frameCount
            guard frameCount > 1 else { return }

            var durations: [TimeInterval] = []
            for i in 0..<frameCount {
                if let frameProperties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any],
                   let gifProperties = frameProperties[kCGImagePropertyGIFDictionary as String] as? [String: Any],
                   let delayTime = gifProperties[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double {
                    durations.append(delayTime > 0 ? delayTime : 0.1)
                } else {
                    durations.append(0.1)
                }
            }
            self.frameDurations = durations
            self.source = source

            if wasAnimating {
                resumeAnimation()
            }
        }

        func resumeAnimation() {
            guard !isDismantled, !isAnimating, frameCount > 1, let imageView else { return }
            if displayLink == nil {
                let generation = animationGeneration
                displayLink = displayLinkFactory(imageView) { [weak self] in
                    guard let self, self.animationGeneration == generation else { return }
                    self.tick()
                }
            }
            isAnimating = true
            lastFrameTime = clock()
            displayLink?.resume()
        }

        func pauseAnimation() {
            guard isAnimating else { return }
            isAnimating = false
            displayLink?.pause()
        }

        func dismantle() {
            isDismantled = true
            clearAnimation()
            imageView = nil
            currentGifData = nil
        }

        private func clearAnimation() {
            isAnimating = false
            // GIF 替换或拆卸后，旧驱动已排队的回调不能推进新动画。
            animationGeneration += 1
            displayLink?.invalidate()
            displayLink = nil
            source = nil
            frameCount = 0
            currentFrame = 0
            frameDurations = []
            lastFrameTime = 0
        }

        private func tick() {
            guard isAnimating, frameCount > 0 else { return }

            let now = clock()
            let elapsed = now - lastFrameTime
            let duration = frameDurations[currentFrame]

            if elapsed >= duration {
                currentFrame = (currentFrame + 1) % frameCount
                lastFrameTime = now
                updateFrame()
            }
        }

        private func updateFrame() {
            guard let source = source, let imageView = imageView else { return }

            if let cgImage = CGImageSourceCreateImageAtIndex(source, currentFrame, nil) {
                let frameImage = NSImage(cgImage: cgImage, size: imageView.frame.size)
                imageView.image = frameImage
            }
        }

        deinit {
            displayLink?.invalidate()
        }
    }
}

protocol GifDisplayLinkDriving: AnyObject {
    func resume()
    func pause()
    func invalidate()
}

/// 使用视图所在屏幕的主 run loop 回调，避免跨线程排队和手动引用计数。
private final class ViewGifDisplayLink: GifDisplayLinkDriving {
    private let displayLink: CADisplayLink

    init(view: NSView, callback: @escaping () -> Void) {
        let target = CallbackTarget(callback: callback)
        displayLink = view.displayLink(target: target, selector: #selector(CallbackTarget.tick(_:)))
        displayLink.isPaused = true
        displayLink.add(to: .main, forMode: .common)
    }

    func resume() { displayLink.isPaused = false }
    func pause() { displayLink.isPaused = true }
    func invalidate() { displayLink.invalidate() }

    deinit { displayLink.invalidate() }

    // displayLink 保留此代理，代理的闭包只弱引用 Coordinator。
    private final class CallbackTarget: NSObject {
        let callback: () -> Void

        init(callback: @escaping () -> Void) {
            self.callback = callback
        }

        @objc func tick(_ displayLink: CADisplayLink) {
            callback()
        }
    }
}
