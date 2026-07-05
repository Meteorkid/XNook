import SwiftUI
import AppKit

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

    class Coordinator {
        private var displayLink: CVDisplayLink?
        private var source: CGImageSource?
        private var frameCount: Int = 0
        private var currentFrame: Int = 0
        private var frameDurations: [TimeInterval] = []
        private var lastFrameTime: TimeInterval = 0
        private var isAnimating: Bool = false
        private weak var imageView: NSImageView?
        private(set) var currentGifData: Data?

        func setupAnimation(gifData: Data, imageView: NSImageView) {
            // 暂停当前动画，避免 tick() 读取中间状态
            let wasAnimating = isAnimating
            if wasAnimating, let displayLink = displayLink {
                CVDisplayLinkStop(displayLink)
                Unmanaged.passUnretained(self).release()
                self.displayLink = nil
            }
            isAnimating = false

            self.imageView = imageView
            self.currentGifData = gifData

            guard let source = CGImageSourceCreateWithData(gifData as CFData, nil) else {
                imageView.image = NSImage(data: gifData)
                return
            }

            self.frameCount = CGImageSourceGetCount(source)

            guard frameCount > 1 else {
                imageView.image = NSImage(data: gifData)
                return
            }

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

            // 显示第一帧
            if let firstImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                imageView.image = NSImage(cgImage: firstImage, size: imageView.frame.size)
            }
        }

        func resumeAnimation() {
            guard frameCount > 1 else { return }
            if displayLink == nil {
                startDisplayLink()
            }
            isAnimating = true
            lastFrameTime = CACurrentMediaTime()
        }

        func pauseAnimation() {
            isAnimating = false
        }

        private func startDisplayLink() {
            guard displayLink == nil else { return }

            CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
            guard let displayLink = displayLink else { return }

            CVDisplayLinkSetOutputCallback(displayLink, { _, _, _, _, _, userInfo -> CVReturn in
                guard let userInfo = userInfo else { return kCVReturnSuccess }
                let coordinator = Unmanaged<Coordinator>.fromOpaque(userInfo).takeUnretainedValue()
                // 全部在主线程处理，避免跨线程 data race
                DispatchQueue.main.async {
                    coordinator.tick()
                }
                return kCVReturnSuccess
            }, Unmanaged.passRetained(self).toOpaque())

            CVDisplayLinkStart(displayLink)
            isAnimating = true
            lastFrameTime = CACurrentMediaTime()
        }

        private func tick() {
            guard isAnimating, frameCount > 0 else { return }

            let now = CACurrentMediaTime()
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
            if let displayLink = displayLink {
                CVDisplayLinkStop(displayLink)
                // 释放 setupAnimation 和 startDisplayLink 中通过 passRetained 增加的引用计数
                Unmanaged.passUnretained(self).release()
            }
        }
    }
}
