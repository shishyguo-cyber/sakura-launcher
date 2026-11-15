import CoreGraphics

/// Where the overlay sits before it knows the target window, and how it travels onto that window.
public enum OverlayGeometry {
    /// Share of the visible area (each axis) the launch overlay may use.
    public static let launchCoverage: CGFloat = 0.72
    /// Upper bound for the launch overlay's width, in points.
    public static let launchMaxWidth: CGFloat = 1120

    /// The largest rectangle with `aspect` (width / height) inside the central `launchCoverage` share of
    /// `visible`, no wider than `launchMaxWidth`, centred and snapped to whole points.
    public static func launchFrame(in visible: CGRect, aspect: CGFloat = 16.0 / 9.0, coverage: CGFloat = launchCoverage) -> CGRect {
        guard visible.width > 0, visible.height > 0, aspect.isFinite, aspect > 0 else { return .zero }
        let ratio = coverage.isFinite && (0.4...0.9).contains(coverage) ? coverage : launchCoverage
        let box = CGSize(width: visible.width * ratio, height: visible.height * ratio)
        var size = CGSize(width: box.width, height: box.width / aspect)
        if size.height > box.height { size = CGSize(width: box.height * aspect, height: box.height) }
        if size.width > launchMaxWidth { size = CGSize(width: launchMaxWidth, height: launchMaxWidth / aspect) }
        // Shrink to whole points (never grow past the limits), then centre on whole points.
        size = CGSize(width: size.width.rounded(.down), height: size.height.rounded(.down))
        let origin = CGPoint(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded())
        return CGRect(origin: origin, size: size)
    }

    /// How far (points, any edge) the target window must move or resize before the overlay follows.
    public static let followTolerance: CGFloat = 2

    /// True when `latest` differs from `current` enough that the overlay should re-dock onto it.
    public static func shouldFollow(current: CGRect, latest: CGRect) -> Bool {
        abs(current.minX - latest.minX) > followTolerance || abs(current.minY - latest.minY) > followTolerance
            || abs(current.maxX - latest.maxX) > followTolerance || abs(current.maxY - latest.maxY) > followTolerance
    }

    /// Smooth start and stop for movement and fades (cubic smoothstep), clamped to 0...1.
    public static func ease(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return x * x * (3 - 2 * x)
    }

    /// Frame part-way between `from` and `to` for linear progress `t`, eased.
    public static func interpolate(from: CGRect, to: CGRect, progress t: Double) -> CGRect {
        let k = CGFloat(ease(t))
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * k }
        return CGRect(x: mix(from.minX, to.minX), y: mix(from.minY, to.minY),
                      width: mix(from.width, to.width), height: mix(from.height, to.height))
    }
}
