import AppKit
import SwiftUI
import GardenBootCore

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let editor: ExperienceEditor
    init(pack: InstalledPack?, settings: ExperienceSettings, warning: String, playbackState: PlaybackState,
         onImport: @escaping () -> Void, onSelect: @escaping (InstalledPack) -> Void,
         onRemove: @escaping (LibraryEntry) throws -> Void, onResetPlayback: @escaping () throws -> Void,
         onSave: @escaping (ExperienceSettings) throws -> Void,
         onPreview: @escaping (ExperienceSettings, InstalledPack) throws -> Void, runtime: OverviewRuntime? = nil) {
        editor = ExperienceEditor(pack: pack, settings: settings, warning: warning, playbackState: playbackState,
            onImport: onImport, onSelect: onSelect, onRemove: onRemove, onResetPlayback: onResetPlayback,
            onSave: onSave, onPreview: onPreview, runtime: runtime)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "启动体验"
        window.contentMinSize = NSSize(width: 820, height: 560)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: ExperienceSettingsView(editor: editor, onClose: { [weak self] in self?.requestClose() }))
        window.delegate = self
        window.center()
    }
    required init?(coder: NSCoder) { nil }
    func present() { editor.overviewActive = true; Support.requestFocus(); showWindow(nil); window?.makeKeyAndOrderFront(nil) }
    func windowWillClose(_ notification: Notification) { editor.overviewActive = false }
    func windowDidMiniaturize(_ notification: Notification) { editor.overviewActive = false }
    func windowDidDeminiaturize(_ notification: Notification) { editor.overviewActive = true }
    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmClose() }
    @discardableResult func requestClose() -> Bool {
        guard confirmClose() else { return false }
        close(); return true
    }
    private func confirmClose() -> Bool {
        window?.makeFirstResponder(nil)
        guard editor.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "保存启动体验的修改？"
        alert.informativeText = "尚未保存的应用、收藏、播放偏好、参数和方案会在关闭后丢失。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "放弃修改")
        alert.addButton(withTitle: "继续编辑")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return editor.save()
        case .alertSecondButtonReturn: editor.discard(); return true
        default: return false
        }
    }
}

struct ExperienceSettingsView: View {
    @ObservedObject var editor: ExperienceEditor
    var loadLibrary = true
    var onClose: () -> Void = {}
    @State var page: SettingsPage = .overview
    @State private var presetName = ""

    private func number(_ key: WritableKeyPath<PlaybackOverrides, Double?>, fallback: Double) -> Binding<Double> {
        Binding(get: { editor.preferences.overrides[keyPath: key] ?? fallback },
                set: { value in editor.update { $0[keyPath: key] = value } })
    }
    private func enabled(_ key: WritableKeyPath<PlaybackOverrides, Double?>, fallback: Double) -> Binding<Bool> {
        Binding(get: { editor.preferences.overrides[keyPath: key] != nil },
                set: { value in editor.update { $0[keyPath: key] = value ? fallback : nil } })
    }
    private func valueLabel(_ value: Double, percent: Bool = false) -> String {
        percent ? String(format: "%.0f%%", value * 100) : String(format: "%.1f 秒", value)
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func slider(_ title: String, key: WritableKeyPath<PlaybackOverrides, Double?>,
                        fallback: Double, range: ClosedRange<Double>, step: Double, percent: Bool = false) -> some View {
        let custom = editor.preferences.overrides[keyPath: key] != nil
        return SettingsRow {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(title)
                    Spacer(minLength: 8)
                    if !custom { Text("默认 \(valueLabel(fallback, percent: percent))").foregroundStyle(Theme.textSecondary).font(.system(size: 12)).monospacedDigit() }
                    Toggle("自定义", isOn: enabled(key, fallback: fallback)).accessibilityLabel("\(title)自定义")
                }
                if custom {
                    HStack(spacing: 12) {
                        GardenSlider(title: title, value: number(key, fallback: fallback), range: range, step: step)
                        Text(valueLabel(number(key, fallback: fallback).wrappedValue, percent: percent))
                            .monospacedDigit().foregroundStyle(Theme.textSecondary).frame(width: 64, alignment: .trailing)
                    }
                }
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 180)
            Rectangle().fill(Theme.border).frame(width: 1)
            VStack(alignment: .leading, spacing: 16) {
                if page != .overview { SettingsHero(editor: editor) }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            switch page {
                            case .overview: OverviewView(editor: editor) { page = $0 }
                            case .animation: AnimationLibraryView(editor: editor)
                            case .targets: TargetsView(editor: editor)
                            case .playback: playback
                            case .sound: soundPage { id in withAnimation { proxy.scrollTo(id, anchor: .center) } }
                            case .display: if let pack = editor.pack { display(pack) } else { emptyParameters }
                            case .presets: if editor.pack != nil { presets } else { emptyParameters }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
                    }.id(page)
                }
                if !editor.message.isEmpty {
                    Text(editor.message).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings-status").accessibilityLabel("操作状态：\(editor.message)")
                }
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .font(.system(size: 13)).foregroundStyle(Theme.text)
        .background(Theme.bg).tint(Theme.accentFill).accentColor(Theme.accentFill)
        .toggleStyle(GardenSwitchStyle())
        .frame(minWidth: 820, minHeight: 560)
        .onExitCommand(perform: onClose)
        .onChange(of: editor.pack?.id) { _ in presetName = "" }
        .task { if loadLibrary { await editor.reloadLibrary() } }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 8) {
                Image(nsImage: FlowerIcon.image()).resizable().frame(width: 24, height: 24).foregroundStyle(Theme.accentFill)
                Text("Sakura").font(.system(size: 13, weight: .semibold))
            }.padding(.top, 24).padding(.horizontal, 16)
            VStack(spacing: 4) {
                ForEach(SettingsPage.allCases) { item in
                    NavigationItem(page: item, selected: page == item) { page = item }
                }
            }.padding(.horizontal, 12)
            Spacer(minLength: 16)
            VStack(alignment: .leading, spacing: 12) {
                statusLabel
                Button { NSApp.keyWindow?.makeFirstResponder(nil); editor.save() } label: {
                    Text("保存设置").frame(maxWidth: .infinity)
                }.buttonStyle(GardenButtonStyle(kind: .primary)).keyboardShortcut("s", modifiers: .command)
            }.padding(16)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.sidebar)
    }
    private var statusLabel: some View {
        let saved = editor.didSave && !editor.isDirty
        let color = editor.isDirty ? Theme.accent : saved ? Theme.success : Theme.textSecondary
        return HStack(spacing: 6) {
            if editor.isDirty { Circle().fill(color).frame(width: 5, height: 5) }
            else if saved { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)) }
            Text(editor.isDirty ? "有未保存的修改" : saved ? "设置已保存" : "当前设置")
        }.font(.system(size: 12)).foregroundStyle(color).accessibilityIdentifier("settings-draft-state")
    }
    private var emptyParameters: some View {
        SettingsGroup { SettingsRow { note("请先在动画页导入可用动画包，再调节参数与方案。") } }
    }

    private var playback: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup {
                SettingsRow {
                    HStack {
                        Text("播放频率")
                        Spacer()
                        frequencySegments
                    }
                }
                if editor.draft.playback.frequency == .firstOfDay {
                    SettingsDivider()
                    SettingsRow {
                        HStack(spacing: 8) {
                            Text("新的一天从")
                            GardenMenu(title: "起始小时", selection: $editor.draft.playback.dayStartHour,
                                       options: (0..<24).map { ($0, "\($0):00") }).monospacedDigit()
                            Text("开始")
                            Spacer()
                        }
                    }
                    SettingsDivider()
                    SettingsRow {
                        HStack {
                            TimelineView(.periodic(from: .now, by: 30)) { _ in
                                Text(editor.todayStatus).foregroundStyle(Theme.textSecondary).font(.system(size: 12))
                            }
                            Spacer()
                            Button("下次启动照常播放", action: editor.resetPlayback)
                                .buttonStyle(GardenButtonStyle(kind: .text, small: true))
                                .help("立即清空播放记录，仍遵循暂停与系统动态效果设置。")
                        }
                    }
                }
            }.help("频率与每日起点在保存后生效；动画出现后，即使跳过也计入今日播放。")
            SettingsGroup {
                SettingsRow {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("全屏或演示时不播放")
                            Text("当前台是其他应用的全屏窗口（视频、演示、游戏）时跳过动画。勿扰模式和屏幕共享暂时无法检测。")
                                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Toggle("", isOn: $editor.draft.playback.quietWhenFullscreen)
                            .accessibilityLabel("全屏或演示时不播放").accessibilityIdentifier("quiet-when-fullscreen")
                    }
                }
            }
            note("临时暂停在菜单栏菜单里。")
        }
    }
    private var frequencySegments: some View {
        HStack(spacing: 2) {
            ForEach([PlaybackFrequency.everyLaunch, .firstOfDay], id: \.rawValue) { value in
                Button { editor.draft.playback.frequency = value } label: {
                    Text(value == .everyLaunch ? "每次启动" : "每天首次")
                        .foregroundStyle(editor.draft.playback.frequency == value ? Theme.accent : Theme.textSecondary)
                        .frame(width: 94, height: 28)
                        .background(editor.draft.playback.frequency == value ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(GardenPlainButtonStyle()).accessibilityAddTraits(editor.draft.playback.frequency == value ? .isSelected : [])
            }
        }.padding(3).background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 8)).accessibilityLabel("播放频率")
    }

    private func soundPage(scroll: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let pack = editor.pack {
                let overrides = editor.preferences.overrides
                HStack(spacing: 12) {
                    metric("淡出", value: valueLabel(overrides.fadeDuration ?? pack.manifest.effectiveFadeDuration)) { scroll("fade") }
                    metric("最长等待", value: valueLabel(overrides.maxWaitSeconds ?? pack.manifest.effectiveMaxWait)) { scroll("wait") }
                    metric("窗口就绪时", value: loopLabel(overrides.loopExit ?? pack.manifest.effectiveLoopExit, short: true)) { scroll("ready") }
                }
            }
            SettingsGroup {
                SettingsRow {
                    VStack(spacing: 8) {
                        HStack {
                            Text("总音量")
                            Spacer()
                            Button("恢复音量") { editor.draft.masterVolume = 1; editor.draft.muted = false }
                                .buttonStyle(GardenButtonStyle(kind: .text, small: true))
                            Toggle("静音", isOn: $editor.draft.muted)
                        }
                        HStack(spacing: 12) {
                            GardenSlider(title: "总音量", value: $editor.draft.masterVolume, range: 0...1, step: 0.01).disabled(editor.draft.muted)
                            Text(valueLabel(editor.draft.masterVolume, percent: true)).monospacedDigit()
                                .foregroundStyle(Theme.textSecondary).frame(width: 64, alignment: .trailing)
                        }
                    }
                }.help("应用于所有动画，保留动画本身的音量比例。")
                if let pack = editor.pack {
                    SettingsDivider()
                    slider("淡出时长", key: \.fadeDuration, fallback: pack.manifest.effectiveFadeDuration, range: 0.1...2, step: 0.1).id("fade")
                    SettingsDivider()
                    handoff(pack)
                    SettingsDivider()
                    slider("最长等待", key: \.maxWaitSeconds, fallback: pack.manifest.effectiveMaxWait, range: 1...60, step: 1).id("wait")
                    SettingsDivider()
                    loopExit(pack).id("ready")
                }
            }
        }
    }
    private func metric(_ title: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Text(value).font(.system(size: 16, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
        }.buttonStyle(GardenPlainButtonStyle()).help("转到\(title)设置")
    }
    private func handoff(_ pack: InstalledPack) -> some View {
        let custom = editor.preferences.overrides.handoffAt != nil
        return SettingsRow {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("淡出起点")
                    Spacer()
                    if !custom {
                        Text(pack.manifest.handoffAt.map { "默认 \(valueLabel($0))" } ?? "默认 自动交接")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    Toggle("自定义", isOn: enabled(\.handoffAt, fallback: pack.manifest.handoffAt ?? 0)).accessibilityLabel("淡出起点自定义")
                }
                if custom {
                    HStack(spacing: 8) {
                        TextField("秒", value: number(\.handoffAt, fallback: pack.manifest.handoffAt ?? 0), format: .number)
                            .modifier(GardenInput()).frame(width: 88).monospacedDigit().accessibilityLabel("淡出起点秒数")
                        Text("秒").foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }.help("超出片段时长时会自动收紧。")
    }
    private func loopLabel(_ value: LoopExit, short: Bool = false) -> String {
        value == .cycleEnd ? (short ? "播完循环" : "播完当前循环再收尾") : (short ? "立即收尾" : "立即进入收尾")
    }
    private func loopExit(_ pack: InstalledPack) -> some View {
        let custom = editor.preferences.overrides.loopExit != nil
        return SettingsRow {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("窗口就绪时")
                    Spacer()
                    if !custom { Text("默认 \(loopLabel(pack.manifest.effectiveLoopExit, short: true))").font(.system(size: 12)).foregroundStyle(Theme.textSecondary) }
                    Toggle("自定义", isOn: Binding(get: { custom }, set: { on in
                        editor.update { $0.loopExit = on ? pack.manifest.effectiveLoopExit : nil }
                    })).accessibilityLabel("窗口就绪时自定义")
                }
                if custom {
                    GardenMenu(title: "窗口就绪时", selection: Binding(get: { editor.preferences.overrides.loopExit ?? pack.manifest.effectiveLoopExit },
                        set: { value in editor.update { $0.loopExit = value } }),
                        options: [(LoopExit.cycleEnd, loopLabel(.cycleEnd)), (.immediate, loopLabel(.immediate))])
                }
            }
        }
    }

    private func display(_ pack: InstalledPack) -> some View {
        SettingsGroup {
            slider("开场尺寸", key: \.launchCoverage, fallback: 0.72, range: 0.4...0.9, step: 0.01, percent: true)
                .help("按所在屏幕的可见区域缩放；收尾仍与目标窗口对齐。")
            SettingsDivider()
            SettingsRow {
                HStack {
                    Text("贴到窗口时")
                    Spacer()
                    GardenMenu(title: "贴到窗口时", selection: Binding(get: { editor.preferences.overrides.videoFit?.rawValue ?? "default" },
                        set: { value in editor.update { $0.videoFit = VideoFit.Mode(rawValue: value) } }),
                        options: [("default", "使用动画默认设置"), ("auto", "自动适配（推荐）"), ("fill", "铺满（可能裁边）"), ("fit", "完整显示（模糊补边）")])
                }
            }
        }
    }
    private var presets: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup {
                ForEach(editor.preferences.presets) { preset in
                    SettingsRow {
                        HStack(spacing: 12) {
                            Text(preset.name).lineLimit(2)
                            Spacer()
                            Button("应用") { editor.applyPreset(preset.id) }.buttonStyle(GardenButtonStyle(kind: .text, small: true))
                            Button("删除") { editor.deletePreset(preset.id) }.buttonStyle(GardenButtonStyle(kind: .danger, small: true))
                        }
                    }
                    SettingsDivider()
                }
                SettingsRow {
                    HStack(spacing: 12) {
                        TextField("方案名称", text: $presetName).modifier(GardenInput()).accessibilityLabel("方案名称")
                        Button("存为方案") { NSApp.keyWindow?.makeFirstResponder(nil); editor.addPreset(presetName) }
                            .buttonStyle(GardenButtonStyle(kind: .text))
                    }
                }
            }.help("方案保存本动画的过渡、等待、尺寸和适配；总音量与静音独立设置。")
            Button("恢复本包默认参数", action: editor.resetPack).buttonStyle(GardenButtonStyle())
            note("不会删除已存方案。")
        }
    }
}

private struct NavigationItem: View {
    let page: SettingsPage
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.symbol).font(.system(size: 14)).frame(width: 18)
                Text(page.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }.padding(.horizontal, 12).frame(height: 40)
                .foregroundStyle(selected ? Theme.accent : Theme.text)
                .background(selected ? Theme.surface : hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(GardenPlainButtonStyle()).onHover { hovering = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
