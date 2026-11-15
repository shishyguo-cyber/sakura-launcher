import CoreGraphics

/// Video placement in frame-local coordinates, independent of AppKit / AVFoundation.
public enum VideoFit {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case auto, fill, fit
    }

    public struct Resolution: Equatable, Sendable {
        public let mode: Mode
        public let contentRect: CGRect
    }

    public static func resolve(mode: Mode, frameSize: CGSize, videoAspect: CGFloat) -> Resolution {
        let fallback = Resolution(mode: .fill, contentRect: CGRect(origin: .zero, size: frameSize))
        let width = frameSize.width, height = frameSize.height
        guard width.isFinite, height.isFinite, videoAspect.isFinite,
              width > 0, height > 0, videoAspect > 0 else { return fallback }
        let aspect = width / height
        let crop = 1 - min(aspect, videoAspect) / max(aspect, videoAspect)
        // Ratio division can put a mathematically exact 12% crop one rounding step above
        // the boundary (e.g. a 100 × 88 frame with square video). Include that rounding error.
        let actual: Mode = mode == .auto ? (crop <= 0.12 + CGFloat.ulpOfOne ? .fill : .fit) : mode
        let scale = actual == .fill ? max(width / videoAspect, height) : min(width / videoAspect, height)
        let contentWidth = videoAspect * scale
        return Resolution(mode: actual, contentRect: CGRect(x: (width - contentWidth) / 2,
            y: (height - scale) / 2, width: contentWidth, height: scale))
    }
}
