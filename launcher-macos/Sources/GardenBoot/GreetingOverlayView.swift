import AppKit
import CoreText
import GardenBootCore
import QuartzCore

@MainActor
final class GreetingOverlayView: NSView {
    private let treatment: Greeting.Treatment
    private let lighting: GreetingLighting
    private let scene: CALayer
    private let lettering = CALayer()
    private let pen = CALayer()
    private let lightSweep = CALayer()
    private let sparks = (0..<4).map { _ in CALayer() }
    private let lineWidth: CGFloat
    private let glyphs: [Letter]
    private let penLength: CGFloat
    private var lastSize: CGSize = .zero
    private static let em: CGFloat = 64

    init(light: Greeting.Light, name: String?, treatment: Greeting.Treatment, opaque: Bool) {
        self.treatment = treatment
        scene = CALayer()
        lighting = GreetingLighting(in: scene, light: light, opaque: opaque, still: treatment == .still)
        let line = Self.makeLine(light.salutation, name: name)
        lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        glyphs = Self.makeLetters(line, palette: lighting.palette, treatment: treatment)
        penLength = glyphs.last.map { $0.start + $0.travel } ?? 0
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(scene)
        scene.addSublayer(lettering)
        if treatment == .animated(.sweep) {
            lightSweep.bounds.size = CGSize(width: 162, height: 120)
            lightSweep.contents = GreetingLighting.glow(lighting.palette.lightColor)
            lightSweep.setAffineTransform(CGAffineTransform(rotationAngle: -0.28))
            lettering.addSublayer(lightSweep)
        }
        for glyph in glyphs { lettering.addSublayer(glyph.layer) }
        if treatment == .animated(.pen) {
            let glow = GreetingLighting.glow(lighting.palette.lightColor)
            for (index, spark) in ([pen] + sparks).enumerated() {
                spark.contents = glow
                let size = index == 0 ? 27.0 : 14.0 - 2 * Double(index)
                spark.bounds.size = CGSize(width: size, height: size)
                lettering.addSublayer(spark)
            }
        }
        setAccessibilityElement(false)
        render(time: 0, exit: nil)
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scene.frame = bounds
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        lighting.layout(in: bounds, dark: dark)
        if bounds.size != lastSize {
            let scale = min(bounds.width * 0.84 / max(1, lineWidth), bounds.height * 0.155 / Self.em, 1.45)
            lettering.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
            lettering.position = CGPoint(x: (bounds.width - lineWidth * scale) / 2, y: bounds.height * 0.51 - 18 * scale)
            lastSize = bounds.size
        }
        CATransaction.commit()
    }

    func render(time: Double, exit: Double?) {
        if treatment == .still, time >= 0.63, lettering.opacity == 1 { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        switch treatment {
        case .still:
            if time == 0 { lighting.render(in: bounds, time: 0, exit: nil, still: true) }
            lettering.opacity = Float(ease((time - 0.06) / 0.57))
        case .animated(let style):
            lighting.render(in: bounds, time: time, exit: exit, still: false)
            let dispersal = ease((exit ?? 0) / 0.80)
            lettering.opacity = Float(1 - dispersal * 0.88)
            let exposureTime = time - (exit ?? 0)
            let shimmer = (exposureTime - 1.89) / 0.49
            let glint = ease(shimmer * 5) * ease((1 - shimmer) * 5)
            let cursor = (exposureTime - 0.43) / 1.21
            let stroke = penPosition(cursor)
            let front = (exposureTime - 0.40) / 1.02
            if style == .sweep {
                lightSweep.position = CGPoint(x: lineWidth * front, y: 22)
                lightSweep.opacity = Float(0.23 * ease(front * 7) * ease((1.13 - front) * 6) * (1 - dispersal))
            }
            let interval = min(0.041, 0.91 / Double(max(1, glyphs.count)))
            for letter in glyphs {
                let column = (letter.origin.x + letter.box.midX) / max(1, lineWidth)
                let shine = glint * exp(-pow((column - shimmer) / 0.115, 2))
                letter.render(style: style, time: exposureTime, column: column, sweep: shine,
                              cursor: stroke, lightFront: front * lineWidth, dispersal: dispersal,
                              fittedInterval: interval)
            }
            if style == .pen { renderPen(cursor: cursor, dispersal: dispersal) }
        }
    }

    /// Modest acceleration and release with a steady middle so short contours still get time on screen.
    private func penPosition(_ progress: Double) -> Double {
        let t = min(1, max(0, progress))
        return penLength * (0.76 * t + 0.24 * ease(t))
    }

    private func renderPen(cursor: Double, dispersal: Double) {
        let intensity = ease(cursor * 20) * ease((1 - cursor) * 13) * (1 - dispersal)
        for (index, tip) in ([pen] + sparks).enumerated() {
            let distance = penPosition(cursor - Double(index) * 0.008)
            guard intensity > 0.001,
                  let letter = glyphs.first(where: { $0.start + $0.travel > distance }),
                  let position = letter.trace.point(at: distance - letter.start) else {
                tip.opacity = 0
                continue
            }
            let phase = distance / 95 + Double(index) * 0.9
            tip.position = CGPoint(x: position.x + letter.layer.position.x - Double(index) * 1.7,
                                   y: position.y + letter.layer.position.y + Double(index) * (2 + 1.4 * sin(phase)))
            tip.opacity = Float(intensity * (index == 0 ? 0.94 : 0.48 / Double(index)))
        }
    }

    private static let nameKey = NSAttributedString.Key("SakuraGreetingName")

    private static func makeLine(_ greeting: String, name: String?) -> CTLine {
        let regular = NSFont(name: "Georgia", size: em) ?? .systemFont(ofSize: em, weight: .regular)
        let italic = NSFont(name: "Georgia-Italic", size: em) ?? .systemFont(ofSize: em, weight: .medium)
        let line = NSMutableAttributedString(string: greeting + (name == nil ? "" : ", "), attributes: [.font: regular])
        if let name { line.append(NSAttributedString(string: name, attributes: [.font: italic, nameKey: true])) }
        return CTLineCreateWithAttributedString(line)
    }

    private static func makeLetters(_ line: CTLine, palette: GreetingLighting.Palette,
                                    treatment: Greeting.Treatment) -> [Letter] {
        var letters: [Letter] = []
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let font = attributes[kCTFontAttributeName] else { continue }
            let face = font as! CTFont
            let color = greetingColor(attributes[nameKey] == nil ? palette.ink : palette.name)
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRangeMake(0, 0), &glyphs)
            CTRunGetPositions(run, CFRangeMake(0, 0), &positions)
            for (glyph, origin) in zip(glyphs, positions) {
                let path = CTFontCreatePathForGlyph(face, glyph, nil)
                var g = glyph
                let box = path?.boundingBoxOfPath ?? CTFontGetBoundingRectsForGlyphs(face, .default, &g, nil, 1)
                guard !box.isEmpty, !box.isNull, box.width > 0, box.height > 0 else { continue }
                letters.append(Letter(path: path, font: face, glyph: glyph, origin: origin, box: box,
                                      color: color, lamp: palette.lightColor, treatment: treatment))
            }
        }
        letters.sort { $0.origin.x < $1.origin.x }
        var distance = 0.0
        for (index, letter) in letters.enumerated() {
            letter.index = index
            letter.start = distance
            distance += letter.travel
        }
        return letters
    }
}

@MainActor
private final class Letter {
    let origin: CGPoint
    let box: CGRect
    let layer = CALayer()
    let trace: OutlineTrace
    let travel: Double
    var start = 0.0
    var index = 0

    private let fill = CAShapeLayer()
    private let outline = CAShapeLayer()
    private let halo = CAShapeLayer()
    private let defocus = CALayer()
    private let iris = CAGradientLayer()
    private let sweepMask = CAGradientLayer()
    private let color: NSColor

    init(path: CGPath?, font: CTFont, glyph: CGGlyph, origin: CGPoint, box: CGRect,
         color: NSColor, lamp: NSColor, treatment: Greeting.Treatment) {
        self.origin = origin
        self.box = box.insetBy(dx: -3, dy: -3).integral
        self.color = color
        var shift = CGAffineTransform(translationX: -self.box.minX, y: -self.box.minY)
        let shape = path?.copy(using: &shift)
        trace = OutlineTrace(path: treatment == .animated(.pen) ? shape : nil)
        travel = max(24, trace.length)
        layer.anchorPoint = .zero
        layer.bounds.size = self.box.size
        layer.position = CGPoint(x: origin.x + self.box.minX, y: origin.y + self.box.minY)
        fill.frame = layer.bounds
        fill.path = shape
        fill.fillColor = color.cgColor

        if let shape {
            if treatment != .still {
                halo.frame = layer.bounds
                halo.path = shape
                halo.fillColor = lamp.withAlphaComponent(0.24).cgColor
                halo.shadowPath = shape
                halo.shadowColor = lamp.cgColor
                halo.shadowOffset = .zero
                halo.shadowRadius = 10
                halo.shadowOpacity = 0.56
                layer.addSublayer(halo)
            }
            if treatment == .animated(.sweep) {
                defocus.frame = layer.bounds.insetBy(dx: -10, dy: -10)
                defocus.contents = Self.softImage(shape, size: defocus.bounds.size, color: color)
                layer.addSublayer(defocus)
            } else if treatment == .animated(.pen) {
                outline.frame = layer.bounds
                outline.path = shape
                outline.fillColor = nil
                outline.strokeColor = lamp.blended(withFraction: 0.4, of: color)?.cgColor
                outline.lineWidth = 0.95
                outline.lineCap = .round
                outline.lineJoin = .round
                outline.shadowOffset = .zero
                outline.shadowRadius = 3.7
                outline.shadowColor = lamp.cgColor
                outline.shadowOpacity = 0.80
                layer.addSublayer(outline)
            }
        } else {
            // Color emoji have bitmap glyphs in Core Text. Render at Retina resolution once.
            fill.contents = Self.bitmap(size: self.box.size, scale: 4) { context in
                var g = glyph
                var p = CGPoint(x: -self.box.minX, y: -self.box.minY)
                CTFontDrawGlyphs(font, &g, &p, 1, context)
            }
        }
        iris.frame = layer.bounds
        iris.type = .radial
        iris.startPoint = CGPoint(x: 0.48, y: 0.53)
        iris.colors = [NSColor.white.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
        iris.locations = [0, 0.27, 1]
        sweepMask.frame = fill.bounds
        sweepMask.startPoint = CGPoint(x: 0, y: 0.5)
        sweepMask.endPoint = CGPoint(x: 1, y: 0.5)
        sweepMask.colors = [NSColor.white.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor, NSColor.clear.cgColor]
        layer.addSublayer(fill)
    }

    func render(style: Greeting.Style, time: Double, column: Double, sweep: Double,
                cursor: Double, lightFront: CGFloat, dispersal: Double, fittedInterval: Double) {
        let base = CGPoint(x: origin.x + box.minX, y: origin.y + box.minY)
        switch style {
        case .pen:
            let p = min(1, max(0, (cursor - start) / travel))
            let glow = ease((cursor - start - 0.54 * travel) / max(44, travel * 1.60))
            layer.position = base
            outline.strokeEnd = p
            outline.opacity = Float((1 - 0.86 * glow) * (1 - dispersal))
            fill.opacity = Float(ease(glow * 2.1))
            iris.endPoint = CGPoint(x: 0.48 + 2.2 * glow, y: 0.53 + 2.0 * glow)
            fill.mask = glow > 0 && glow < 1 ? iris : nil
            halo.opacity = Float(glow * 0.49)
            // The nib stops at the outline's end; the last glyph still needs time to fill.
            if time > 1.63 {
                let settle = ease((time - 1.63) / 0.22)
                outline.opacity *= Float(1 - settle)
                fill.opacity = max(fill.opacity, Float(settle))
                if settle > glow {
                    iris.endPoint = CGPoint(x: 0.48 + 2.2 * settle, y: 0.53 + 2.0 * settle)
                    fill.mask = settle < 1 ? iris : nil
                }
                halo.opacity = max(halo.opacity, Float(settle * 0.49))
            }
        case .sweep, .script: // Style C has its own view (ScriptGreetingView); only A/B reach this class.
            let front = (time - 0.40) / 1.02
            let gate = ease((front - column + 0.065) / 0.19)
            let stagger = ease((time - 0.42 - Double(index) * fittedInterval) / 0.32)
            let resolve = min(gate, stagger)
            let crest = exp(-pow((front - column - 0.04) / 0.115, 2)) * gate
            let drift = 1 - resolve
            layer.position = CGPoint(x: base.x + (column - 0.5) * 29 * drift, y: base.y - 12 * drift)
            defocus.opacity = Float(sin(.pi * resolve) * 0.83)
            fill.opacity = Float(fill.path == nil ? resolve : ease(resolve))
            let edge = (lightFront - layer.position.x) / box.width
            if edge >= 1 {
                if fill.mask != nil { fill.mask = nil }
            } else if edge > -0.6 {
                let core = max(0, edge)
                let fringe = min(1, max(0.001, edge + 0.60))
                sweepMask.locations = [0, NSNumber(value: core), NSNumber(value: fringe), 1]
                if fill.mask == nil { fill.mask = sweepMask }
            } else {
                fill.opacity = 0
            }
            halo.opacity = Float(resolve * (0.48 + 0.45 * crest))
        }
        if dispersal > 0 {
            layer.position.x += (column - 0.39) * dispersal * 37
            layer.position.y += (9 + 8 * noise(index + 90)) * dispersal
            halo.opacity *= Float(1 - dispersal * 0.44)
        }
        let highlight = sweep * 0.68
        fill.fillColor = color.blended(withFraction: highlight, of: .white)?.cgColor
        halo.shadowOpacity = Float(0.55 + sweep * 0.23)
    }

    private static func softImage(_ path: CGPath, size: CGSize, color: NSColor) -> CGImage? {
        bitmap(size: size, scale: 1.5) { context in
            context.setShadow(offset: .zero, blur: 5.2, color: color.withAlphaComponent(0.93).cgColor)
            context.translateBy(x: 10, y: 10)
            context.setFillColor(color.withAlphaComponent(0.30).cgColor)
            context.addPath(path)
            context.fillPath()
        }
    }

    private static func bitmap(size: CGSize, scale: CGFloat, draw: (CGContext) -> Void) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(ceil(size.width * scale)),
                                      height: Int(ceil(size.height * scale)), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        draw(context)
        return context.makeImage()
    }
}

/// Arc lengths of flattened Core Text contours, for the point at the end of strokeEnd.
private struct OutlineTrace {
    private struct Edge {
        let from: CGPoint
        let to: CGPoint
        let start: CGFloat
        let end: CGFloat
    }

    private var edges: [Edge] = []
    private(set) var length: CGFloat = 0

    init(path: CGPath?) {
        var previous = CGPoint.zero
        var start = CGPoint.zero
        func add(_ point: CGPoint) {
            let end = length + hypot(point.x - previous.x, point.y - previous.y)
            if end > length { edges.append(.init(from: previous, to: point, start: length, end: end)) }
            length = end
            previous = point
        }
        path?.applyWithBlock { element in
            let points = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint:
                previous = points[0]
                start = previous
            case .addLineToPoint: add(points[0])
            case .closeSubpath: add(start)
            case .addQuadCurveToPoint, .addCurveToPoint:
                let cubic = element.pointee.type == .addCurveToPoint
                let a = previous
                for i in 1...20 {
                    let t = Double(i) / 20
                    let u = 1 - t
                    let ab = a * u + points[0] * t
                    let bc = points[0] * u + points[1] * t
                    let ac = ab * u + bc * t
                    if cubic {
                        let cd = points[1] * u + points[2] * t
                        add(ac * u + (bc * u + cd * t) * t)
                    } else {
                        add(ac)
                    }
                }
            @unknown default: break
            }
        }
    }

    func point(at distance: CGFloat) -> CGPoint? {
        guard let edge = edges.first(where: { $0.end >= distance }) ?? edges.last else { return nil }
        let t = min(1, max(0, (distance - edge.start) / (edge.end - edge.start)))
        return edge.from * (1 - t) + edge.to * t
    }
}

private func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
private func * (point: CGPoint, scale: CGFloat) -> CGPoint { CGPoint(x: point.x * scale, y: point.y * scale) }
