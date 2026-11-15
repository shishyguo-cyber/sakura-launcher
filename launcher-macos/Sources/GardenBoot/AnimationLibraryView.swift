import SwiftUI
import GardenBootCore

struct AnimationLibraryView: View {
    @ObservedObject var editor: ExperienceEditor
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text("自动播放时")
                GardenMenu(title: "自动播放时", selection: $editor.draft.library.rotation,
                    options: [(PackRotation.fixed, "固定播放当前动画"), (.shuffleAll, "全部动画随机"), (.shuffleFavorites, "收藏动画随机")])
                Spacer(minLength: 0)
                if editor.libraryBusy { ProgressView().controlSize(.small) }
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(editor.entries.filter { $0.pack != nil }) { entry in AnimationCard(editor: editor, entry: entry) }
                AddTile(icon: "plus", title: "导入动画包", detail: nil, action: editor.onImport).disabled(editor.libraryBusy)
                AddTile(icon: "film", title: "从视频创建", detail: "选一个 mp4 / mov", action: editor.chooseVideo)
                    .disabled(editor.libraryBusy).accessibilityIdentifier("create-from-video")
            }
            ForEach(editor.entries.filter { $0.problem != nil }) { entry in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(entry.name)：\(entry.problem ?? "无法播放") 请修复后重新导入。")
                        .font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("移除…") { editor.remove(entry) }.buttonStyle(GardenButtonStyle(kind: .danger, small: true))
                        .disabled(editor.libraryBusy || entry.id == Support.demoID)
                }
            }
        }.sheet(item: $editor.videoDraft) { _ in VideoPackSheet(editor: editor) }
    }
}

/// Dashed "add" tile with the same footprint as an animation card.
private struct AddTile: View {
    let icon: String
    let title: String
    let detail: String?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                Color.clear.frame(height: 82)
            }.padding(12).frame(maxWidth: .infinity)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: icon).font(.system(size: 22, weight: .light))
                        Text(title).font(.system(size: 13))
                        if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary) }
                    }.foregroundStyle(Theme.accent)
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        }.buttonStyle(GardenPlainButtonStyle()).accessibilityLabel(title)
    }
}

/// Name + rights confirmation before a video becomes a pack (launcher-spec/PACK-FROM-VIDEO.md).
private struct VideoPackSheet: View {
    @ObservedObject var editor: ExperienceEditor
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        if let draft = editor.videoDraft {
            VStack(alignment: .leading, spacing: 16) {
                Text("从视频创建动画").font(.system(size: 16, weight: .semibold))
                Text(draft.fileName).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                VStack(alignment: .leading, spacing: 6) {
                    Text("名称")
                    TextField("名称", text: Binding(get: { editor.videoDraft?.name ?? "" }, set: { editor.videoDraft?.name = $0 }))
                        .modifier(GardenInput()).accessibilityLabel("动画名称")
                    if !VideoPackRules.validName(draft.name) {
                        Text("名称需为 1–40 个字符").font(.system(size: 12)).foregroundStyle(Theme.danger)
                    }
                }
                Toggle("这个视频是我自己制作的，或我有权使用它",
                       isOn: Binding(get: { editor.videoDraft?.confirmed ?? false }, set: { editor.videoDraft?.confirmed = $0 }))
                    .toggleStyle(.checkbox).accessibilityIdentifier("video-rights")
                Text("会复制一份视频到动画库，视频结尾前自动淡出；之后可在“声音与过渡”里调整淡出起点。")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("取消") { editor.videoDraft = nil; dismiss() }
                        .buttonStyle(GardenButtonStyle(kind: .text)).keyboardShortcut(.cancelAction)
                    Button("创建") { editor.createFromVideo() }
                        .buttonStyle(GardenButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                        .disabled(!draft.confirmed || !VideoPackRules.validName(draft.name))
                }
            }.padding(24).frame(width: 440).background(Theme.bg).foregroundStyle(Theme.text).font(.system(size: 13))
        }
    }
}

private struct AnimationCard: View {
    @ObservedObject var editor: ExperienceEditor
    let entry: LibraryEntry
    @State private var hovering = false
    private var selected: Bool { editor.pack?.id == entry.id }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Button { if let pack = entry.pack { editor.inspect(pack) } } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        PackThumbnailView(pack: entry.pack, name: entry.name)
                        Text(entry.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                            .lineLimit(1).help(entry.name)
                        HStack {
                            if editor.activeID == entry.id {
                                Text("当前").font(.system(size: 12)).foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.accentSoft, in: Capsule())
                            }
                            Spacer(minLength: 0)
                        }.frame(height: 20)
                    }
                }.buttonStyle(GardenPlainButtonStyle()).accessibilityLabel("调节\(entry.name)").disabled(editor.libraryBusy)
                Button { editor.toggleFavorite(entry.id) } label: {
                    Image(systemName: editor.draft.library.favorites.contains(entry.id) ? "star.fill" : "star")
                        .font(.system(size: 12, weight: .semibold)).frame(width: 24, height: 24)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(GardenButtonStyle(kind: .text, small: true)).padding(4)
                    .disabled(entry.id.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) == nil)
                    .help("收藏（保存设置后生效）").accessibilityLabel("收藏\(entry.name)")
            }
            HStack(spacing: 4) {
                Button("设为当前") { if let pack = entry.pack { editor.select(pack) } }
                    .buttonStyle(GardenButtonStyle(kind: .text, small: true))
                    .disabled(editor.libraryBusy || entry.pack == nil || editor.activeID == entry.id)
                Text("·").foregroundStyle(Theme.textSecondary)
                Button("移除…") { editor.remove(entry) }.buttonStyle(GardenButtonStyle(kind: .danger, small: true))
                    .disabled(editor.libraryBusy || entry.id == Support.demoID)
                    .help(entry.id == Support.demoID ? "随程序附带的示例动画不可移除" : "移到废纸篓，保留个人设置")
            }.padding(.top, 4)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.accentSoft : hovering ? Theme.hover : Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: selected ? 1.5 : 1))
            .onHover { hovering = $0 }
    }
}
