import AppKit
import GardenBootCore

@MainActor final class OverviewStub: OverviewRuntime {
    var welcomeDismissed = false
    var actions: [String] = []
    var reason: PlaybackStatusReason = .paused
    func setWelcomeDismissed(_ value: Bool) throws { welcomeDismissed = value }
    func overview(targetID: String?) -> OverviewSnapshot {
        OverviewSnapshot(targets: [OverviewTarget(id: "saved-target", name: "已保存应用")], selectedID: "saved-target", reason: reason)
    }
    func performOverviewAction(_ action: String) throws { actions.append(action); reason = .ready }
    var tested: [String] = []
    func testTarget(_ id: String) throws {
        guard id == "saved-target" else { throw ExperienceError.invalid("请先保存设置并打开这个应用的开关，再测试。") }
        tested.append(id)
    }
    var created: [String] = []
    func createPack(fromVideo video: URL, name: String) throws { created.append(name) }
}

// Model-only checks: load the production editor without creating NSApplication or windows.
MainActor.assumeIsolated {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    func pack(_ id: String) -> InstalledPack {
        let manifest = PackManifest(id: id, name: id, segments: [.video: "video.mp4"])
        // InstalledPack's public memberwise construction is deliberately not exposed; load a real fixture folder.
        let dir = root.appendingPathComponent(id)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try! JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try! Data([1]).write(to: dir.appendingPathComponent("video.mp4"))
        try! Data([1]).write(to: dir.appendingPathComponent("NOTICE.md"))
        return try! PackLibrary.load(directory: dir)
    }
    let a = pack("a"), b = pack("b")
    var saved = ExperienceSettings(), saves = 0, imports = 0, selected = ""
    var previewSettings: ExperienceSettings?, previewID: String?
    var state = PlaybackState(lastAutoPlayAt: 123, lastPackId: "a", snoozeUntil: 900)
    let editor = ExperienceEditor(pack: a, settings: saved, warning: "", playbackState: state,
        onImport: { imports += 1 }, onSelect: { selected = $0.id }, onRemove: { _ in },
        onResetPlayback: { state.lastAutoPlayAt = nil },
        onSave: { saved = $0; saves += 1 }, onPreview: { previewSettings = $0; previewID = $1.id })
    precondition(!editor.isDirty)
    editor.draft.masterVolume = 0.4; editor.draft.playback.frequency = .firstOfDay
    editor.draft.library.rotation = .shuffleFavorites; editor.toggleFavorite("b")
    editor.update { $0.fadeDuration = 1.2 }; editor.addPreset("保留方案")
    let draft = editor.draft
    editor.toggleFavorite("Bad ID"); precondition(editor.draft == draft)
    // Inspecting a card changes the draft context without changing the automatic-play selection.
    editor.inspect(b)
    precondition(editor.pack?.id == "b" && editor.activeID == "a" && selected.isEmpty && saves == 0)
    editor.update { $0.fadeDuration = 0.7 }
    editor.preview()
    precondition(previewID == "b" && previewSettings?.packs["b"]?.overrides.fadeDuration == 0.7)
    editor.inspect(a)
    precondition(editor.preferences.overrides.fadeDuration == 1.2 && editor.preferences.presets.count == 1)
    editor.inspect(b)
    precondition(editor.preferences.overrides.fadeDuration == 0.7 && editor.activeID == "a")
    editor.draft = draft // Keep the existing selection/import/reset/preview/save assertions unchanged.
    editor.select(b)
    precondition(selected == "b" && editor.activeID == "b" && editor.draft == draft && saves == 0)
    editor.onImport(); editor.resetPlayback()
    precondition(imports == 1 && state.lastAutoPlayAt == nil && state.lastPackId == "a" && state.snoozeUntil == 900)
    precondition(editor.draft == draft && editor.isDirty && saves == 0)
    editor.preview(a)
    precondition(previewID == "a" && previewSettings == draft && saves == 0)
    editor.draft.masterVolume = 0.8
    precondition(previewSettings?.masterVolume == 0.4) // Preview snapshot is independent of later edits.
    precondition(editor.save() && saves == 1 && !editor.isDirty && saved.masterVolume == 0.8)
    editor.draft.playback.dayStartHour = 24
    precondition(!editor.save() && saves == 1 && editor.isDirty && saved.playback.dayStartHour == 4)
    editor.discard()
    precondition(!editor.isDirty && editor.activeID == "b" && saved.packs["a"]?.presets.count == 1)
    precondition(saved.library.favorites == ["b"] && editor.pack?.id == "b")
    // Fit mode follows the same production draft → preview → preset → save path.
    editor.select(a)
    let beforeFit = saved
    editor.update { $0.videoFit = .fit }
    editor.addPreset("完整画面")
    let fitPreset = editor.preferences.presets.last!
    precondition(editor.isDirty && saved == beforeFit && fitPreset.overrides.videoFit == .fit)
    editor.preview()
    precondition(previewID == "a" && previewSettings?.packs["a"]?.overrides.videoFit == .fit && saved == beforeFit)
    editor.update { $0.videoFit = .fill }
    precondition(previewSettings?.packs["a"]?.overrides.videoFit == .fit)
    editor.applyPreset(fitPreset.id)
    precondition(editor.preferences.overrides.videoFit == .fit)
    precondition(editor.save() && saved.packs["a"]?.overrides.videoFit == .fit)
    let decoded = try! ExperienceSettings.decode(JSONEncoder().encode(saved))
    precondition(decoded == saved && decoded.packs["a"]?.presets.last?.overrides.videoFit == .fit)
    editor.update { $0.videoFit = .auto }
    precondition(editor.preferences.overrides.videoFit == .auto && editor.isDirty)
    editor.discard()
    precondition(editor.preferences.overrides.videoFit == .fit && !editor.isDirty)
    editor.update { $0.videoFit = nil }
    editor.preview()
    precondition(previewSettings?.packs["a"]?.overrides.videoFit == nil)
    precondition(try! previewSettings!.resolved(a.manifest).effectiveVideoFit == .auto)
    editor.resetPack()
    precondition(editor.preferences.overrides.videoFit == nil && editor.preferences.presets.last == fitPreset)
    editor.discard()
    let originalTargets = saved.targets
    editor.addTarget(name: "  第二个应用  ", bundleID: "local.fixture.second")
    precondition(editor.isDirty && saved.targets == originalTargets && editor.draft.targets.count == originalTargets.count + 1)
    let added = editor.draft.targets.last!
    precondition(added.name == "第二个应用" && UUID(uuidString: added.id) != nil && added.id == added.id.lowercased())
    editor.addTarget(name: "重复", bundleID: "local.fixture.second")
    precondition(editor.draft.targets.count == originalTargets.count + 1)
    editor.updateTarget(added.id) { $0.enabled = false; $0.animation = "b" }
    precondition(saved.targets == originalTargets && editor.draft.targets.last?.enabled == false)
    precondition(editor.save() && saved.targets.last?.animation == "b")
    editor.removeTarget(added.id)
    precondition(editor.isDirty && saved.targets.last?.id == added.id)
    editor.discard()
    precondition(editor.draft.targets.last?.id == added.id && !editor.isDirty)
    var foreign = ApplicationTarget(id: "foreign", name: "Windows", bundleID: "unused")
    foreign.platforms = ["windows": .object(["package": .string("Example.App")]), "future": .object(["keep": .bool(true)])]
    editor.draft.targets.append(foreign)
    editor.removeTarget("foreign")
    precondition(editor.draft.targets.last == foreign && editor.save())
    editor.removeTarget(added.id)
    precondition(editor.save() && saved.targets.last == foreign)
    let targetDraft = editor.draft
    editor.addTarget(name: String(repeating: "名", count: 41), bundleID: "local.invalid")
    precondition(editor.draft == targetDraft)

    // Installed application enumeration uses only controlled bundles here, with the production reader.
    let runtime = OverviewStub()
    var overviewSaves = 0, overviewPreviews = 0
    let overview = ExperienceEditor(pack: a, settings: .init(), warning: "", playbackState: .init(),
        onImport: {}, onSelect: { _ in }, onRemove: { _ in }, onResetPlayback: {},
        onSave: { _ in overviewSaves += 1 }, onPreview: { _, _ in overviewPreviews += 1 }, runtime: runtime)
    overview.draft.masterVolume = 0.2
    overview.addTarget(name: "未保存应用", bundleID: "fixture.unsaved")
    let beforeGuide = overview.draft
    precondition(overview.overview(targetID: nil).targets.map(\.name) == ["已保存应用"])
    precondition(overview.overview(targetID: nil).reason == .paused && overview.isDirty)
    overview.setWelcomeDismissed(true)
    precondition(runtime.welcomeDismissed && overview.welcomeDismissed && overview.draft == beforeGuide && overviewSaves == 0)
    overview.setWelcomeDismissed(false)
    precondition(!runtime.welcomeDismissed && !overview.welcomeDismissed)
    overview.performOverviewAction("unpause")
    precondition(runtime.actions == ["unpause"] && overview.overview(targetID: nil).reason == .ready && overviewSaves == 0)
    overview.preview()
    precondition(overviewPreviews == 1 && overviewSaves == 0 && overview.draft == beforeGuide)
    // "测试": an unsaved target reports why; a saved one is handed to the runtime without touching the draft.
    let unsavedID = overview.draft.targets.first { $0.bundleID == "fixture.unsaved" }!.id
    overview.testTarget(unsavedID)
    precondition(runtime.tested.isEmpty && overview.message.contains("请先保存设置"))
    overview.testTarget("saved-target")
    precondition(runtime.tested == ["saved-target"] && overview.draft == beforeGuide && overviewSaves == 0)
    overview.updateTarget(unsavedID) { $0.playOnReappear = true }
    precondition(overview.draft.targets.first { $0.id == unsavedID }!.playOnReappear && overview.isDirty)
    overview.updateTarget(unsavedID) { $0.playOnReappear = false }
    precondition(overview.draft == beforeGuide)
    let emptyOverview = ExperienceEditor(pack: nil, settings: .init(), warning: "", playbackState: .init(),
        onImport: {}, onSelect: { _ in }, onRemove: { _ in }, onResetPlayback: {}, onSave: { _ in },
        onPreview: { _, _ in preconditionFailure("No-pack preview must not invoke playback") })
    emptyOverview.preview()
    precondition(emptyOverview.message.contains("导入可用动画包"))
    print("overview-model passed: saved-state isolation, guide dismissal/reopen without draft save, explicit status actions, 测试 routing, reappear draft toggle, preview and no-pack recovery")
    let apps = root.appendingPathComponent("installed")
    func app(_ path: String, _ id: String?) {
        let folder = apps.appendingPathComponent(path).appendingPathComponent("Contents")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var info = ["CFBundleName": "Fixture", "CFBundlePackageType": "APPL"]
        if let id { info["CFBundleIdentifier"] = id }
        try! PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: folder.appendingPathComponent("Info.plist"))
    }
    app("Alpha.app", "fixture.alpha")
    app("Tools/Beta.app", "fixture.beta")
    app("Tools/Deep/Ignored.app", "fixture.deep")
    app("NoID.app", nil)
    app("Own.app", "fixture.own")
    app("Alpha.app/Contents/Helper.app", "fixture.helper")
    let installed = InstalledApplications.read(roots: [apps, apps], excluding: "fixture.own")
    precondition(Set(installed.map(\.bundleID)) == ["fixture.alpha", "fixture.beta"])
    precondition(installed.map(\.name) == installed.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    print("targets-model passed: draft add/update/remove/save/discard, duplicate rejection, foreign retention; controlled enumeration roots, depth, bundle exclusion and deduplication")
    print("video-fit settings-model passed: draft, preview snapshot, preset apply/save/round-trip, explicit auto, discard, inheritance and reset")
    print("settings-model passed: independent inspection preserves per-pack drafts/current; immediate selection/import/reset preserve draft; requested-pack preview snapshot; save validation; discard retains immediate state")
}
