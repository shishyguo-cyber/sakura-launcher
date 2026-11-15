import AppKit
import SwiftUI
import GardenBootCore

struct SettingsHero: View {
    @ObservedObject var editor: ExperienceEditor
    @State private var duration: Double?
    private var subtitle: String {
        guard editor.pack != nil else { return "导入动画，开始调节启动体验" }
        if editor.draft.library.rotation != .fixed { return "轮换中" }
        let context = editor.pack?.id == editor.activeID ? "当前动画" : "正在调节"
        return duration.map { "\(context) · \(String(format: "%.0f", $0)) 秒" } ?? context
    }
    private var mediaVersion: String {
        guard let pack = editor.pack else { return "empty" }
        return pack.directory.path + pack.manifest.segments.values.sorted().map { file in
            let attributes = try? FileManager.default.attributesOfItem(atPath: pack.url(for: file).path)
            return "|\(file)|\(attributes?[.modificationDate] as? Date ?? .distantPast)|\(attributes?[.size] as? NSNumber ?? 0)"
        }.joined()
    }
    var body: some View {
        HStack(spacing: 16) {
            PackThumbnailView(pack: editor.pack, name: editor.pack?.manifest.name ?? "尚未选择动画")
                .frame(width: 104 * 16 / 9, height: 104)
            VStack(alignment: .leading, spacing: 8) {
                Text(editor.pack?.manifest.name ?? "尚未选择动画")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.heroText).lineLimit(2)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.heroSecondary)
                Spacer(minLength: 0)
                HStack {
                    Spacer(minLength: 0)
                    Button("▶ 预览") { NSApp.keyWindow?.makeFirstResponder(nil); editor.preview() }
                        .buttonStyle(GardenButtonStyle(kind: .preview)).keyboardShortcut("p", modifiers: .command)
                        .disabled(editor.pack == nil || editor.libraryBusy).help("预览当前草稿（⌘P）")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(16).frame(height: 136)
            .background(Theme.hero, in: RoundedRectangle(cornerRadius: 14))
            .task(id: mediaVersion) {
                duration = nil
                guard let pack = editor.pack else { return }
                var total = 0.0
                for file in Set(pack.manifest.segments.values).sorted() {
                    guard let media = try? await PackMedia.load(pack.url(for: file)), !Task.isCancelled else { return }
                    total += media.duration
                }
                if !Task.isCancelled { duration = total }
            }
    }
}
