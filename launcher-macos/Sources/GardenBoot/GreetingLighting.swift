import AppKit
import GardenBootCore
import QuartzCore
import simd

/// Translucent light painted into small textures once per appearance, then composited by Core Animation.
@MainActor
final class GreetingLighting {
    struct Palette {
        let shadow: SIMD3<Double>
        let air: SIMD3<Double>
        let lamp: SIMD3<Double>
        let scatter: SIMD3<Double>
        let ink: UInt32
        let name: UInt32

        init(_ light: Greeting.Light) {
            switch light {
            case .dawn:
                (shadow, air, lamp, scatter, ink, name) = (
                    rgb(0x141425), rgb(0x77564d), rgb(0xffcb83), rgb(0xb77862), 0xffeee0, 0xffd19b)
            case .daylight:
                (shadow, air, lamp, scatter, ink, name) = (
                    rgb(0x222b39), rgb(0x928171), rgb(0xfff0cf), rgb(0xb5ada0), 0xfff6e5, 0xffdfa9)
            case .dusk:
                (shadow, air, lamp, scatter, ink, name) = (
                    rgb(0x170f28), rgb(0x61446e), rgb(0xffb86e), rgb(0xa068ba), 0xffeae5, 0xffbd8b)
            case .moonlight:
                (shadow, air, lamp, scatter, ink, name) = (
                    rgb(0x070e24), rgb(0x2b4477), rgb(0xa1d5ff), rgb(0x718bc7), 0xe7f3ff, 0xb7ddff)
            }
        }

        var lightColor: NSColor { NSColor(srgbRed: lamp.x, green: lamp.y, blue: lamp.z, alpha: 1) }
    }

    private struct Dust {
        let layer = CALayer()
        let x: Double
        let y: Double
        let speed: Double
        let radius: Double
        let phase: Double

        init(_ index: Int) {
            x = noise(index * 13 + 2) * 1.08 - 0.06
            y = noise(index * 13 + 3) * 0.96 + 0.02
            speed = 0.006 + 0.011 * noise(index * 13 + 5)
            radius = index < 6 ? 3.5 + 5 * noise(index * 13 + 8) : 0.7 + 1.55 * noise(index * 13 + 8)
            phase = 2 * .pi * noise(index * 13 + 9)
        }
    }

    private let opaque: Bool
    // Keep the upper texture edge above the panel even as the rays tilt during the handoff.
    private static let rayHeight = 1.32
    private let base = CALayer()
    private let stars = CALayer()
    private let volume = CALayer()
    private let dust: [Dust]
    private var dark: Bool?
    let palette: Palette

    init(in layer: CALayer, light: Greeting.Light, opaque: Bool, still: Bool) {
        self.opaque = opaque
        palette = Palette(light)
        dust = still ? [] : (0..<68).map(Dust.init)
        layer.addSublayer(base)
        layer.addSublayer(volume)
        if light == .moonlight {
            let starColor = palette.lamp
            stars.contents = Self.image(width: 960, height: 600) { _, _, index in
                let x = index % 960, y = index / 960
                let seed = x / 49 + y / 47 * 21
                let px = Double(x % 49) - (4 + 41 * noise(seed * 5 + 930))
                let py = Double(y % 47) - (4 + 39 * noise(seed * 5 + 931))
                let radius = 0.5 + 0.72 * noise(seed * 5 + 932)
                let visible = x > 330 && y < 237 && noise(seed * 5 + 934) > 0.81
                let alpha = visible ? (0.17 + 0.24 * noise(seed * 5 + 936)) * bell(hypot(px, py) / radius) : 0
                return (starColor, alpha)
            }
            layer.addSublayer(stars)
        }
        volume.anchorPoint = CGPoint(x: 0.085, y: 1.08 / Self.rayHeight)
        let texture = Self.glow(palette.lightColor)
        for mot in dust {
            mot.layer.contents = texture
            layer.addSublayer(mot.layer)
        }
    }

    func layout(in bounds: CGRect, dark: Bool) {
        if self.dark != dark {
            self.dark = dark
            base.contents = texture(dark: dark, rays: false)
            volume.contents = texture(dark: dark, rays: true)
        }
        base.frame = bounds
        stars.frame = bounds
        volume.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height * Self.rayHeight)
        volume.position = CGPoint(x: bounds.width * 0.085, y: bounds.height * 1.08)
    }

    func render(in bounds: CGRect, time: Double, exit: Double?, still: Bool) {
        let entry = still ? 1 : ease(time / 0.64)
        let spread = still ? 0 : ease((exit ?? 0) / 0.72)
        let rotation = still ? 0 : -0.30 * (1 - entry) + 0.045 * sin(time * 1.05) - 0.22 * spread
        volume.setAffineTransform(CGAffineTransform(rotationAngle: rotation).scaledBy(x: 1 + spread * 0.26, y: 1 + spread * 0.18))
        volume.opacity = Float(still ? 0.74 : (0.05 + entry * 0.91) * (1 - spread * 0.57))
        let scale = max(0.5, min(1.5, bounds.width / 960))
        for mot in dust {
            let x = mot.x + time * mot.speed + 0.01 * sin(time * 0.7 + mot.phase) + spread * (mot.x - 0.32) * 0.15
            let y = mot.y + time * mot.speed * 0.27 + spread * (mot.y - 0.55) * 0.18
            let rayAngle = atan2(x - 0.085, 1.08 - y)
            let exposure = bell((rayAngle - 0.58 - rotation) / 0.35)
            let twinkle = 0.76 + 0.24 * sin(time * 1.6 + mot.phase)
            let diameter = mot.radius * scale * (1 + spread * 0.4)
            mot.layer.bounds.size = CGSize(width: diameter * 2, height: diameter * 2)
            mot.layer.position = CGPoint(x: x * bounds.width, y: y * bounds.height)
            mot.layer.opacity = Float((mot.radius > 3 ? 0.22 : 0.62) * exposure * entry * twinkle * (1 - spread))
        }
    }

    private func texture(dark: Bool, rays: Bool) -> CGImage? {
        let p = palette
        // Explicit types throughout: older Swift compilers time out inferring this closure (CI, Xcode on macOS 14).
        return Self.image(width: 480, height: rays ? 396 : 300) { (x: Double, v: Double, index: Int) -> (SIMD3<Double>, Double) in
            let y: Double = rays ? v * Self.rayHeight : v
            let dx: Double = x - 0.085
            let dy: Double = 1.08 - y
            let distance: Double = hypot(dx * 1.12, dy)
            let angle: Double = atan2(dx, dy)
            let mistWave: Double = sin(x * 17 + y * 11) * sin(y * 23 - x * 8)
            let mist: Double = (mistWave + 1) * 0.5
            let wobble: Double = sin(x * 7 - y * 5) * 2
            let filament: Double = sin(x * 19 + y * 32 + wobble)
            if rays {
                let beamA: Double = 0.29 * bell((angle - 0.40) / 0.13) + 0.20 * bell((angle - 0.66) / 0.22)
                let beamB: Double = 0.12 * bell((angle - 0.87) / 0.09) + 0.17 * bell((angle - 0.22) / 0.063)
                let beamC: Double = 0.079 * bell((angle - 0.76) / 0.031)
                let intensity: Double = beamA + beamB + beamC
                let atmosphere: Double = 0.72 + 0.18 * mist + 0.10 * filament
                let falloff: Double = exp(-distance * 1.52)
                let glare: Double = 0.42 * bell(distance / 0.23)
                let edgesX: Double = ease(x / 0.055) * ease((1 - x) / 0.18)
                let edgesY: Double = ease(y / 0.15) * ease((Self.rayHeight - y) / 0.12)
                let lit: Double = intensity * (0.24 + falloff * 1.29) * atmosphere
                let strength: Double = (lit + glare) * edgesX * edgesY
                let lampColor: SIMD3<Double> = p.lamp * (0.89 - distance * 0.14)
                let scatterColor: SIMD3<Double> = p.scatter * (0.11 + distance * 0.14)
                let color: SIMD3<Double> = lampColor + scatterColor
                return (color, min(0.69, strength * (dark ? 0.83 : 1.04)))
            }
            let fogBand: Double = (y - 0.37 + x * 0.2 + 0.025 * filament) / 0.15
            let fog: Double = bell(fogBand) * (0.11 + 0.083 * mist)
            let sky: Double = 0.31 * bell(distance / 0.72)
            let pool: Double = 0.13 * bell(hypot((x - 0.92) * 0.6, y - 0.18) / 0.47)
            let vignette: Double = 1 - 0.27 * min(1, hypot((x - 0.5) * 1.8, (y - 0.51) * 1.45))
            let grain: Double = (noise(index) - 0.5) * 0.009
            let grade: Double = dark ? 0.81 : 1.05
            let base: SIMD3<Double> = p.shadow + p.air * (sky + fog) + p.scatter * pool
            let color: SIMD3<Double> = base * (vignette * grade)
            return (color + SIMD3(repeating: grain), opaque ? 1 : 0.64)
        }
    }

    private static func image(width: Int, height: Int, pixel: (Double, Double, Int) -> (SIMD3<Double>, Double)) -> CGImage? {
        var data = Data(capacity: width * height * 4)
        data.count = width * height * 4
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            for row in 0..<height {
                for column in 0..<width {
                    let index = row * width + column
                    let (color, alpha) = pixel(Double(column) / Double(width), 1 - Double(row) / Double(height), index)
                    for channel in 0..<3 {
                        raw[index * 4 + channel] = UInt8((255 * alpha * min(1, max(0, color[channel]))).rounded())
                    }
                    raw[index * 4 + 3] = UInt8((255 * alpha).rounded())
                }
            }
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func glow(_ color: NSColor) -> CGImage? {
        let components = SIMD3(Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
        return image(width: 64, height: 64) { x, y, _ in
            let radius = hypot(x - 0.5, y - 0.5) * 2
            return (components, max(0, exp(-radius * radius * 6) - exp(-6)))
        }
    }

}

private func rgb(_ hex: UInt32) -> SIMD3<Double> {
    SIMD3(Double((hex >> 16) & 255), Double((hex >> 8) & 255), Double(hex & 255)) / 255
}

func greetingColor(_ hex: UInt32) -> NSColor {
    let color = rgb(hex)
    return NSColor(srgbRed: color.x, green: color.y, blue: color.z, alpha: 1)
}

private func bell(_ x: Double) -> Double { exp(-x * x) }

func ease(_ value: Double) -> Double {
    let t = min(1, max(0, value))
    return t * t * (3 - 2 * t)
}

func noise(_ seed: Int) -> Double {
    var value = UInt32(truncatingIfNeeded: seed) &+ 0x9e3779b9
    value = (value ^ (value >> 16)) &* 0x21f0aaad
    value = (value ^ (value >> 15)) &* 0x735a2d97
    return Double(value ^ (value >> 15)) / Double(UInt32.max)
}
