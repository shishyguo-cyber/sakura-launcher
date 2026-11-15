import AppKit
import SwiftUI
import GardenBootCore

struct TargetsView: View {
    @ObservedObject var editor: ExperienceEditor
    @State private var choosing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup {
                ForEach(editor.draft.targets.filter { $0.bundleID != nil }) { target in
                    TargetRow(editor: editor, target: target)
                    SettingsDivider()
                }
                SettingsRow {
                    Button("＋ 添加应用") { choosing = true }
                        .buttonStyle(GardenButtonStyle(kind: .text))
                        .accessibilityIdentifier("add-target")
                }
            }
            Text("同一时间只播放一个动画；正在播放时打开的其他应用不再播放。")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }.sheet(isPresented: $choosing) { InstalledApplicationPicker(editor: editor) }
    }
}

private struct TargetRow: View {
    @ObservedObject var editor: ExperienceEditor
    let target: ApplicationTarget
    private var options: [(String, String)] {
        var result = [("", "跟随全局轮换")] + editor.entries.filter { $0.pack != nil }.map { ($0.id, $0.name) }
        if let id = target.animation, !result.contains(where: { $0.0 == id }) { result.append((id, "\(id)（暂不可用）")) }
        return result
    }
    private var testing: Bool { editor.testingTargetID == target.id }
    private var compat: CompatResult? { editor.playbackState.targets[target.id]?.compat }
    private var statusLine: (text: String, good: Bool)? {
        if testing { return ("请在 30 秒内打开\(target.name)；如果它正在运行，请先完全退出（⌘Q）", false) }
        guard let compat else { return nil }
        return (CompatibilityRules.message(compat.verdict, windowSeconds: compat.windowSeconds), compat.verdict == .good)
    }
    var body: some View {
        SettingsRow {
            VStack(alignment: .leading, spacing: 6) {
                mainLine
                if let statusLine {
                    Text(statusLine.text).font(.system(size: 12))
                        .foregroundStyle(statusLine.good ? Theme.success : Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 36).accessibilityIdentifier("target-status-\(target.id)")
                }
                if target.playOnReappear || compat?.verdict == .alreadyRunning {
                    Toggle("窗口重新出现时也播放", isOn: Binding(get: { target.playOnReappear }, set: { value in
                        editor.updateTarget(target.id) { $0.playOnReappear = value }
                    })).toggleStyle(GardenSwitchStyle()).font(.system(size: 12))
                        .padding(.leading, 36)
                        .help("应用一直在后台运行（关闭窗口后不退出）时，重新打开窗口也播放动画。最小化后还原、隐藏后再显示不算。")
                }
            }
        }
    }
    private var mainLine: some View {
            HStack(spacing: 12) {
                ApplicationIcon(bundleID: target.bundleID)
                Text(target.name).lineLimit(1).truncationMode(.middle).help(target.name)
                Spacer(minLength: 4)
                GardenMenu(title: "\(target.name)的动画", selection: Binding(get: { target.animation ?? "" }, set: { value in
                    editor.updateTarget(target.id) { $0.animation = value.isEmpty ? nil : value }
                }), options: options, maximumLabelWidth: 154)
                Toggle("", isOn: Binding(get: { target.enabled }, set: { value in
                    editor.updateTarget(target.id) { $0.enabled = value }
                })).labelsHidden().accessibilityLabel("启用\(target.name)")
                Button(testing ? "测试中…" : "测试") { editor.testTarget(target.id) }
                    .buttonStyle(GardenButtonStyle(kind: .text, small: true)).disabled(editor.testingTargetID != nil)
                    .accessibilityLabel("测试\(target.name)").help("30 秒内打开这个应用，检查动画是否能正确接上它的窗口。")
                Button("移除") { editor.removeTarget(target.id) }
                    .buttonStyle(GardenButtonStyle(kind: .danger, small: true)).accessibilityLabel("移除\(target.name)")
            }
    }
}

private struct ApplicationIcon: View {
    var bundleID: String? = nil
    var url: URL? = nil
    @State private var icon: NSImage?
    var body: some View {
        Group {
            if let icon { Image(nsImage: icon).resizable() }
            else { Image(systemName: "app").resizable().foregroundStyle(Theme.textSecondary) }
        }.frame(width: 24, height: 24).accessibilityHidden(true)
            .task(id: bundleID ?? url?.path) {
                let path = url ?? bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                icon = path.map { NSWorkspace.shared.icon(forFile: $0.path) }
            }
    }
}

private struct InstalledApplicationPicker: View {
    @ObservedObject var editor: ExperienceEditor
    @Environment(\.dismiss) private var dismiss
    @State private var applications: [InstalledApplication] = []
    @State private var loading = true
    @State private var query = ""
    private var filtered: [InstalledApplication] {
        applications.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("添加应用").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("完成") { dismiss() }.buttonStyle(GardenButtonStyle(kind: .text)).keyboardShortcut(.cancelAction)
            }
            TextField("搜索已安装的应用", text: $query).modifier(GardenInput()).accessibilityLabel("搜索已安装的应用")
            if loading {
                Text("正在读取已安装的应用…").foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { app in
                            let added = editor.draft.targets.contains { $0.bundleID == app.bundleID }
                            SettingsRow {
                                HStack(spacing: 12) {
                                    ApplicationIcon(url: app.url)
                                    Text(app.name).lineLimit(1)
                                    Spacer()
                                    Button(added ? "已添加" : "添加") { editor.addTarget(name: app.name, bundleID: app.bundleID) }
                                        .buttonStyle(GardenButtonStyle(kind: .text, small: true))
                                        .disabled(added || editor.draft.targets.count >= 20)
                                        .accessibilityLabel("\(app.name)\(added ? "已添加" : "添加")")
                                }
                            }
                            SettingsDivider()
                        }
                        if filtered.isEmpty { Text("没有找到应用").foregroundStyle(Theme.textSecondary).padding(24) }
                    }
                }.background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                if editor.draft.targets.count >= 20 { Text("最多添加 20 个应用").foregroundStyle(Theme.textSecondary) }
            }
        }.padding(24).frame(width: 520, height: 440).background(Theme.bg).foregroundStyle(Theme.text).font(.system(size: 13))
            .task {
                applications = await Task.detached(priority: .userInitiated) { InstalledApplications.read() }.value
                loading = false
            }
    }
}
