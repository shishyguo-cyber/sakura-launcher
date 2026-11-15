import AppKit
import SwiftUI

/// DESIGN.md v2 tokens, resolved again whenever the system appearance changes.
enum Theme {
    static let bg = color("bg", 0xFBFAF7, 0x18171C)
    static let sidebar = color("sidebar", 0xF3F0EA, 0x121116)
    static let surface = color("surface", 0xFFFFFF, 0x211F27)
    static let hover = color("hover", 0xECE8E0, 0x2A2731)
    static let border = color("border", 0xE6E1D8, 0x34313C)
    static let divider = color("divider", 0xEFEBE4, 0x2B2832)
    static let text = color("text", 0x2B2A33, 0xEEECF2)
    static let textSecondary = color("textSecondary", 0x6B6776, 0xA8A3B3)
    static let accent = color("accent", 0x6B4FC0, 0xB9A6F2)
    static let accentFill = color("accentFill", 0x8A6FD1, 0x9D86E6)
    static let accentSoft = color("accentSoft", 0xECE7F7, 0x2C2638)
    static let onAccent = color("onAccent", 0xFFFFFF, 0x16131D)
    static let hero = color("hero", 0xE9F1EA, 0x1E2B23)
    static let heroText = color("heroText", 0x24402E, 0xDCEBDD)
    static let heroSecondary = color("heroSecondary", 0x4E6B57, 0x9FBBA5)
    static let danger = color("danger", 0xB3423F, 0xE07A76)
    static let success = color("success", 0x3C7D5A, 0x7CC39C)

    private static func color(_ name: String, _ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name("GardenBoot.\(name)")) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        })
    }
}

struct GardenButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, text, danger, preview }
    var kind: Kind = .secondary
    var small = false
    func makeBody(configuration: Configuration) -> some View {
        ButtonContent(configuration: configuration, kind: kind, small: small)
    }
    private struct ButtonContent: View {
        let configuration: ButtonStyle.Configuration
        let kind: Kind
        let small: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @State private var hovering = false
        private var isText: Bool { kind == .text || kind == .danger }
        private var radius: CGFloat { kind == .preview ? 16 : 8 }
        var body: some View {
            configuration.label
                .font(.system(size: small ? 12 : 13, weight: kind == .primary ? .semibold : .regular))
                .padding(.horizontal, isText ? 2 : 12)
                .frame(height: small ? 26 : 32)
                .foregroundStyle(!enabled ? Theme.textSecondary.opacity(0.55) :
                    kind == .primary ? Theme.onAccent : kind == .danger ? Theme.danger :
                    isText || kind == .preview ? Theme.accent : Theme.text)
                .background(RoundedRectangle(cornerRadius: radius).fill(
                    kind == .primary ? Theme.accentFill.opacity(enabled && (hovering || configuration.isPressed) ? 0.85 : 1) :
                    isText ? Color.clear : hovering || configuration.isPressed ? Theme.hover : Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(isText || kind == .primary || kind == .preview ? Color.clear : Theme.border))
                .overlay(RoundedRectangle(cornerRadius: radius + 2).stroke(Theme.accent, lineWidth: 2).padding(-2).opacity(focused ? 1 : 0))
                .contentShape(Rectangle()).onHover { hovering = $0 }
        }
    }
}

/// Keep shaped buttons' keyboard focus visible without adding a mouse focus ring.
struct GardenPlainButtonStyle: ButtonStyle {
    var radius: CGFloat = 8
    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration, radius: radius)
    }
    private struct Content: View {
        let configuration: ButtonStyle.Configuration
        let radius: CGFloat
        @Environment(\.isFocused) private var focused
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label.opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.5)
                .overlay(RoundedRectangle(cornerRadius: radius).stroke(Theme.accent, lineWidth: 2).padding(-2).opacity(focused ? 1 : 0))
                .contentShape(Rectangle())
        }
    }
}
