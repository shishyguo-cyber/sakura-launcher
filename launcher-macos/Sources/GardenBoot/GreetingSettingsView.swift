import SwiftUI
import GardenBootCore

struct GreetingSettingsView: View {
    @ObservedObject var editor: ExperienceEditor
    let title: String
    var skip: (() -> Void)?

    private var name: Binding<String> {
        Binding(get: { editor.draft.greetingName ?? "" },
                set: { editor.draft.greetingName = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 13, weight: .medium))
            HStack(spacing: 8) {
                TextField("可留空", text: name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("称呼")
                    .accessibilityIdentifier("greeting-name")
                Button("预览问候") {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    editor.previewGreeting()
                }
                .buttonStyle(GardenButtonStyle(kind: .text, small: true))
                .accessibilityIdentifier("greeting-preview")
                if let skip {
                    Button("跳过", action: skip)
                        .buttonStyle(GardenButtonStyle(kind: .text, small: true))
                        .accessibilityIdentifier("greeting-skip")
                }
            }
            Text("最多 20 个字符。保存后，内置的 Welcome 动画会把这个称呼写出来；只保存在这台设备。")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
