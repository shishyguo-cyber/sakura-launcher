import SwiftUI

struct GardenSwitchStyle: ToggleStyle {
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                configuration.label.foregroundStyle(Theme.text)
                Capsule().fill(configuration.isOn ? Theme.accentFill : scheme == .dark ? Theme.border : Theme.accentSoft)
                    .frame(width: 32, height: 18)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(Theme.onAccent).frame(width: 14, height: 14).padding(2)
                    }
            }
        }
        .buttonStyle(GardenButtonStyle(kind: .text, small: true))
        .accessibilityValue(configuration.isOn ? "打开" : "关闭")
    }
}

/// Same bounded bindings as the native slider; includes keyboard and VoiceOver adjustment.
struct GardenSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    @Environment(\.isEnabled) private var enabled
    @FocusState private var focused: Bool
    @State private var pointerInteraction = false
    private var fraction: Double { min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound))) }
    private func set(_ next: Double) {
        value = min(range.upperBound, max(range.lowerBound, (next / step).rounded() * step))
    }
    var body: some View {
        GeometryReader { geometry in
            let length = max(1, geometry.size.width - 16)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.accentSoft).frame(height: 4)
                Capsule().fill(Theme.accentFill).frame(width: 8 + length * fraction, height: 4)
                Circle().fill(Theme.surface).overlay(Circle().strokeBorder(Theme.accentFill, lineWidth: 2))
                    .frame(width: 16, height: 16).offset(x: length * fraction)
            }.frame(height: 24).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    guard enabled else { return }
                    pointerInteraction = true
                    focused = true
                    set(range.lowerBound + min(1, max(0, (drag.location.x - 8) / length)) * (range.upperBound - range.lowerBound))
                })
        }
        .frame(height: 24).opacity(enabled ? 1 : 0.5)
        .focusable(enabled).focused($focused)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent, lineWidth: focused && !pointerInteraction ? 2 : 0).padding(-2))
        .onChange(of: focused) { if !$0 { pointerInteraction = false } }
        .onMoveCommand { direction in
            guard enabled else { return }
            pointerInteraction = false
            if direction == .right || direction == .up { set(value + step) }
            if direction == .left || direction == .down { set(value - step) }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(title)
        .accessibilityValue(String(format: "%.2f", value))
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            if direction == .increment { set(value + step) }
            if direction == .decrement { set(value - step) }
        }
    }
}

struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }
}

struct SettingsRow<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 12)
    }
}

struct SettingsDivider: View {
    var body: some View { Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, 14) }
}

struct GardenInput: ViewModifier {
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).padding(.horizontal, 10).frame(height: 32)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Theme.accent : Theme.border, lineWidth: focused ? 2 : 1))
            .focused($focused)
    }
}

struct GardenMenu<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    var maximumLabelWidth: CGFloat? = nil
    var body: some View {
        Menu {
            ForEach(options, id: \.0) { value, label in
                Button { selection = value } label: {
                    if selection == value { Label(label, systemImage: "checkmark") } else { Text(label) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(options.first(where: { $0.0 == selection })?.1 ?? title).lineLimit(1).truncationMode(.middle).frame(maxWidth: maximumLabelWidth)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            }.padding(.horizontal, 10).frame(height: 32)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            .accessibilityLabel(title)
    }
}
