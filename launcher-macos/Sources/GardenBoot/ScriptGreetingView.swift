import AppKit
import CoreText
import GardenBootCore
import QuartzCore

/// Anything the launch overlay can drive frame by frame while a greeting is on screen.
@MainActor
protocol GreetingRendering: AnyObject {
    func render(time: Double, exit: Double?)
}

extension GreetingOverlayView: GreetingRendering {}

/// Style C: "welcome <name>" written out in one rainbow neon line on black, like a signature.
/// The pen strokes come from the skeleton of a system script face, so any nickname can be written.
@MainActor
final class ScriptGreetingView: NSView, GreetingRendering {
    private let still: Bool
    private let backdrop = CALayer()
    private let lettering = CALayer()
    private let haze = CALayer()           // wide, soft outer glow
    private let hazeGradient = CAGradientLayer()
    private let hazeMask = CAShapeLayer()
    private let bloom = CALayer()          // tighter glow hugging the tube
    private let bloomGradient = CAGradientLayer()
    private let bloomMask = CAShapeLayer()
    private let tube = CAGradientLayer()   // the coloured neon line itself
    private let tubeMask = CAShapeLayer()
    private let core = CAShapeLayer()      // white-hot centre of the tube
    private let nib = CALayer()
    private var art: ScriptArt?
    private var readyAt: Double?
    /// True once the pen strokes have been traced (they are built off the main thread).
    var isReady: Bool { art != nil }
    private var lastSize: CGSize = .zero

    init(name: String?, still: Bool) {
        self.still = still
        super.init(frame: .zero)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        setAccessibilityElement(false)
        guard let root = layer else { return }
        backdrop.backgroundColor = NSColor.black.cgColor
        root.addSublayer(backdrop)
        root.addSublayer(lettering)
        lettering.anchorPoint = CGPoint(x: 0.5, y: 0.5)

        for (host, gradient, mask) in [(haze, hazeGradient, hazeMask), (bloom, bloomGradient, bloomMask)] {
            gradient.mask = mask
            host.addSublayer(gradient)
            lettering.addSublayer(host)
        }
        tube.mask = tubeMask
        lettering.addSublayer(tube)
        lettering.addSublayer(core)
        nib.contents = GreetingLighting.glow(NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)) // glow() reads RGB components
        nib.opacity = 0
        lettering.addSublayer(nib)
        for shape in [hazeMask, bloomMask, tubeMask, core] {
            shape.fillColor = nil
            shape.strokeColor = NSColor.white.cgColor
            shape.lineCap = .round
            shape.lineJoin = .round
            shape.strokeEnd = 0
        }
        core.strokeColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.38).cgColor
        lettering.opacity = 0

        let text = Greeting.scriptText(name: name)
        Task.detached(priority: .userInitiated) {
            let art = ScriptArt(text: text)
            await MainActor.run { [weak self] in self?.install(art) }
        }
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func install(_ art: ScriptArt) {
        self.art = art
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let box = CGRect(origin: .zero, size: art.size)
        lettering.bounds = box
        let width = art.lineWidth
        let colors = ScriptArt.rainbow.map { NSColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1).cgColor }
        for gradient in [hazeGradient, bloomGradient, tube] {
            gradient.frame = box
            gradient.colors = colors
            gradient.startPoint = CGPoint(x: art.inkStart, y: 0.5)
            gradient.endPoint = CGPoint(x: art.inkEnd, y: 0.5)
        }
        for host in [haze, bloom] { host.frame = box }
        for (shape, scale) in [(hazeMask, 2.6), (bloomMask, 1.5), (tubeMask, 1.0), (core, 0.28)] {
            shape.frame = box
            shape.path = art.path
            shape.lineWidth = width * scale
        }
        haze.filters = [Self.blur(width * 2.2)]
        bloom.filters = [Self.blur(width * 0.75)]
        haze.opacity = 0.55
        bloom.opacity = 0.9
        nib.bounds.size = CGSize(width: width * 4, height: width * 4)
        lastSize = .zero
        needsLayout = true
        CATransaction.commit()
    }

    private static func blur(_ radius: Double) -> CIFilter {
        let filter = CIFilter(name: "CIGaussianBlur")!
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        return filter
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = bounds
        if let art, bounds.size != lastSize {
            let scale = min(bounds.width * 0.80 / art.size.width, bounds.height * 0.40 / art.size.height)
            lettering.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
            lettering.position = CGPoint(x: bounds.midX, y: bounds.midY)
            lastSize = bounds.size
        }
        CATransaction.commit()
    }

    func render(time: Double, exit: Double?) {
        guard let art else { return }
        if readyAt == nil { readyAt = time }
        let t = time - (readyAt ?? time)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if bounds.size != lastSize { layout() }

        let leaving = ease((exit ?? 0) / 0.8)
        if still {
            setProgress(1, art: art, tip: nil)
            lettering.opacity = Float(ease(t / 0.5) * (1 - 0.6 * leaving))
            return
        }
        lettering.opacity = Float(ease(t / 0.12) * (1 - 0.6 * leaving))
        let progress = (t - ScriptArt.writeStart) / art.writeDuration
        // A touch slower into the first letter, then an even, flowing hand.
        let travel = 0.2 * ease(progress) + 0.8 * min(1, max(0, progress))
        let (drawn, tip) = art.pen(at: travel)
        setProgress(drawn / art.inkLength, art: art, tip: travel > 0 && travel < 1 ? tip : nil)

        let settled = max(0, progress - 1) * art.writeDuration
        let breathe = 1 + 0.12 * sin(settled * 5) * ease(settled * 3)
        let flare = sin(.pi * min(1, (exit ?? 0) / 0.5)) * 0.35
        haze.opacity = Float(0.55 * breathe + flare)
        bloom.opacity = Float(min(1, 0.9 * breathe + flare))
    }

    private func setProgress(_ fraction: Double, art: ScriptArt, tip: CGPoint?) {
        let end = CGFloat(min(1, max(0, fraction)))
        for shape in [hazeMask, bloomMask, tubeMask, core] { shape.strokeEnd = end }
        if let tip {
            nib.position = tip
            nib.opacity = 0.95
        } else {
            nib.opacity = 0
        }
    }
}

/// Pen strokes for one line of script text, in a y-up box ready for Core Animation.
private struct ScriptArt: @unchecked Sendable {
    /// Red → orange → yellow → green → cyan → blue → violet → pink. Blue and violet are lifted toward white
    /// so every part of the line reads equally bright (pure blue looks thinner and dimmer on black).
    static let rainbow: [(CGFloat, CGFloat, CGFloat)] = [
        (1.00, 0.26, 0.34), (1.00, 0.56, 0.18), (1.00, 0.87, 0.26), (0.38, 1.00, 0.42),
        (0.24, 0.93, 1.00), (0.42, 0.64, 1.00), (0.70, 0.47, 1.00), (1.00, 0.42, 0.84),
    ]
    static let writeStart = 0.15
    /// Shear about the baseline (leans the upright hand toward a script) and letter spacing as a share of type size.
    static let slant: CGFloat = 0.20
    static let tracking: CGFloat = -0.04
    private static let typeSize: CGFloat = 150

    let size: CGSize
    let path: CGPath
    let strokes: [[CGPoint]]
    let lengths: [Double]
    let inkLength: Double
    let lineWidth: CGFloat
    let liftCost: Double
    let writeDuration: Double
    let inkStart: CGFloat
    let inkEnd: CGFloat

    init(text: String) {
        // An even-weight hand traces into even pen strokes. Bradley Hand, leaned and set tighter, sits between
        // a legible print hand and a flowing brush script (chosen by the user from side-by-side renders).
        let preferred = ["BradleyHandITCTT-Bold", "BrushScriptMT", "SnellRoundhand-Bold"]
        let face = preferred.lazy
            .map { CTFontCreateWithName($0 as CFString, Self.typeSize, nil) }
            .first { font in preferred.contains(CTFontCopyPostScriptName(font) as String) }
            ?? CTFontCreateUIFontForLanguage(.system, Self.typeSize, nil)!
        let slant = Self.slant, tracking = Self.tracking
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): face,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            NSAttributedString.Key(kCTKernAttributeName as String): tracking * Self.typeSize,
        ]))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let advance = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let pad = 36 + Int(abs(slant) * Self.typeSize * 0.8)
        let width = Int(ceil(advance)) + pad * 2, height = Int(ceil(ascent + descent)) + pad * 2
        var mask = [UInt8](repeating: 0, count: width * height)
        mask.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.setFillColor(gray: 1, alpha: 1)
            // Extra slant (shear about the baseline) leans the hand further, or upright with a negative value.
            context.textMatrix = CGAffineTransform(a: 1, b: 0, c: slant, d: 1, tx: 0, ty: 0)
            context.textPosition = CGPoint(x: CGFloat(pad), y: CGFloat(pad) + descent)
            CTLineDraw(line, context)
        }
        // Skeleton rows grow downward; Core Animation layers here are y-up.
        strokes = ScriptSkeleton.strokes(mask: mask, width: width, height: height, unit: Double(Self.typeSize))
            .map { $0.map { CGPoint(x: $0.x, y: CGFloat(height) - $0.y) } }
        lengths = strokes.map(ScriptSkeleton.length)
        inkLength = max(1, lengths.reduce(0, +))
        let path = CGMutablePath()
        for stroke in strokes where !stroke.isEmpty {
            path.move(to: stroke[0])
            for point in stroke.dropFirst() { path.addLine(to: point) }
        }
        self.path = path
        size = CGSize(width: width, height: height)
        lineWidth = Self.typeSize * 0.058
        liftCost = Double(Self.typeSize) * 0.18
        writeDuration = min(2.8, max(1.6, 1.2 + 0.08 * Double(text.count)))
        inkStart = CGFloat(pad) / CGFloat(width)
        inkEnd = 1 - inkStart
    }

    /// Drawn ink length and nib position after `travel` (0…1) of the whole performance, pen lifts included.
    func pen(at travel: Double) -> (Double, CGPoint?) {
        let total = inkLength + liftCost * Double(max(0, strokes.count - 1))
        var budget = min(1, max(0, travel)) * total
        var drawn = 0.0
        var tip: CGPoint?
        for (index, stroke) in strokes.enumerated() {
            if index > 0 { budget -= liftCost }
            if budget <= 0 { break }
            for (a, b) in zip(stroke, stroke.dropFirst()) {
                let d = hypot(b.x - a.x, b.y - a.y)
                if budget >= d {
                    budget -= d; drawn += d; tip = b
                } else {
                    let f = budget / d
                    tip = CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
                    drawn += budget
                    budget = 0
                    break
                }
            }
            if budget <= 0 { break }
        }
        return (drawn, tip)
    }
}
