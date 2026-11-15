import AppKit
import SwiftUI

// AppKit color/geometry checks without NSApplication, screens or a WindowServer connection.
let tokens: [(Color, UInt32, UInt32)] = [
    (Theme.bg, 0xFBFAF7, 0x18171C), (Theme.sidebar, 0xF3F0EA, 0x121116),
    (Theme.surface, 0xFFFFFF, 0x211F27), (Theme.hover, 0xECE8E0, 0x2A2731),
    (Theme.border, 0xE6E1D8, 0x34313C), (Theme.divider, 0xEFEBE4, 0x2B2832),
    (Theme.text, 0x2B2A33, 0xEEECF2), (Theme.textSecondary, 0x6B6776, 0xA8A3B3),
    (Theme.accent, 0x6B4FC0, 0xB9A6F2), (Theme.accentFill, 0x8A6FD1, 0x9D86E6),
    (Theme.accentSoft, 0xECE7F7, 0x2C2638), (Theme.onAccent, 0xFFFFFF, 0x16131D),
    (Theme.hero, 0xE9F1EA, 0x1E2B23), (Theme.heroText, 0x24402E, 0xDCEBDD),
    (Theme.heroSecondary, 0x4E6B57, 0x9FBBA5), (Theme.danger, 0xB3423F, 0xE07A76),
    (Theme.success, 0x3C7D5A, 0x7CC39C),
]
for (name, dark) in [(NSAppearance.Name.aqua, false), (.darkAqua, true), (.aqua, false)] {
    NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
        for (color, lightHex, darkHex) in tokens {
            let resolved = NSColor(color).usingColorSpace(.sRGB)!
            let hex = dark ? darkHex : lightHex
            precondition(abs(resolved.redComponent * 255 - CGFloat((hex >> 16) & 255)) < 1)
            precondition(abs(resolved.greenComponent * 255 - CGFloat((hex >> 8) & 255)) < 1)
            precondition(abs(resolved.blueComponent * 255 - CGFloat(hex & 255)) < 1)
        }
    }
}
let image = FlowerIcon.image()
precondition(image.isTemplate && image.size == NSSize(width: 18, height: 18))
let bitmap = image.representations.first as! NSBitmapImageRep
precondition(bitmap.pixelsWide == 36 && bitmap.pixelsHigh == 36)
precondition(bitmap.colorAt(x: 18, y: 18)!.alphaComponent == 0)
precondition(bitmap.colorAt(x: 0, y: 0)!.alphaComponent == 0)
// Each radial petal center is solid, while all filled pixels remain monochrome.
for index in 0..<5 {
    let theta = CGFloat(index) * 2 * .pi / 5
    let x = Int((0.5 - sin(theta) * 0.235) * 36)
    let y = Int((0.5 - cos(theta) * 0.235) * 36)
    precondition(bitmap.colorAt(x: x, y: y)!.alphaComponent > 0.99)
}
for y in 0..<36 { for x in 0..<36 {
    let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
    if color.alphaComponent > 0 {
        precondition(color.redComponent == 0 && color.greenComponent == 0 && color.blueComponent == 0)
    }
} }
// Review sheet keeps the original 36 px icon beside a white-on-dark template simulation.
let review = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 48,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 96 * 4, bitsPerPixel: 32)!
let context = NSGraphicsContext(bitmapImageRep: review)!.cgContext
context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
context.setFillColor(NSColor(srgbRed: 23/255, green: 21/255, blue: 28/255, alpha: 1).cgColor)
context.fill(CGRect(x: 48, y: 0, width: 48, height: 48))
context.draw(bitmap.cgImage!, in: CGRect(x: 6, y: 6, width: 36, height: 36))
context.clip(to: CGRect(x: 54, y: 6, width: 36, height: 36), mask: bitmap.cgImage!)
context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 48, y: 0, width: 48, height: 48))
try review.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("design-model passed: all 17 dynamic tokens light/dark/light; 18 pt @2x template, five petals, transparent center and monochrome pixels")

// All page/appearance parsing is safe to check before NSApplication exists.
precondition(SettingsPage.allCases.map(\.rawValue) == ["overview", "animation", "targets", "playback", "sound", "display", "presets"])
for page in SettingsPage.allCases {
    let options = try ReviewRenderOptions.parse(["app", "--render-settings", "/tmp/review.png", "--page", page.rawValue, "--appearance", "dark"])!
    precondition(options.page == page && options.appearance == .darkAqua)
}
let normal = try ReviewRenderOptions.parse(["app"])
precondition(normal == nil)
let defaultPage = try ReviewRenderOptions.parse(["app", "--render-settings", "/tmp/review.png"])!
precondition(defaultPage.page == .animation)
let invalid = [
    ["--page", "animation"], ["--appearance", "light"],
    ["--render-settings"], ["--render-menubar-icon"],
    ["--render-settings", "/tmp/x", "--page"],
    ["--render-settings", "/tmp/x", "--page", "unknown"],
    ["--render-settings", "/tmp/x", "--page", "sound", "--page", "display"],
    ["--render-settings", "/tmp/x", "--appearance", "sepia"],
    ["--render-settings", "/tmp/x", "--register-login"],
    ["--render-settings", "/tmp/x", "--render-menubar-icon", "/tmp/y"],
    ["--render-menubar-icon", "/tmp/x", "--page", "animation"],
]
for arguments in invalid {
    do { _ = try ReviewRenderOptions.parse(["app"] + arguments); fatalError("Accepted invalid render arguments") }
    catch ReviewRenderError.arguments { /* Expected before any GUI initialization. */ }
}
let compact = try! ReviewRenderOptions.parse(["Sakura", "--render-settings", "/tmp/compact.png", "--size", "820x560"])
precondition(compact?.size == NSSize(width: 820, height: 560))
for arguments in [["--size", "800x560"], ["--size", "820x500"], ["--size", "bad"], ["--size", "820x560", "--size", "960x640"]] {
    do { _ = try ReviewRenderOptions.parse(["Sakura", "--render-settings", "/tmp/invalid.png"] + arguments); preconditionFailure("Invalid viewport accepted") }
    catch { }
}
print("render-options passed: seven pages, default page, appearance, invalid/missing/duplicate arguments and action isolation")
