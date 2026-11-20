import AppKit
import Combine
import GardenBootCore

@MainActor
final class ExperienceEditor: ObservableObject {
    @Published var draft: ExperienceSettings
    @Published var message: String
    @Published var pack: InstalledPack?
    @Published var entries: [LibraryEntry] = []
    @Published var activeID: String?
    @Published var playbackState: PlaybackState
    @Published var libraryBusy = false
    @Published private(set) var welcomeDismissed = false
    @Published private(set) var greetingStepSkipped = false
    @Published var overviewActive = false
    struct VideoDraft: Identifiable {
        let id = UUID()
        let url: URL
        var name: String
        var confirmed = false
        var fileName: String { url.lastPathComponent }
    }
    /// "从视频创建" sheet state (launcher-spec/PACK-FROM-VIDEO.md).
    @Published var videoDraft: VideoDraft?
    /// The target whose 30-second "测试" is running, if any (set by the controller).
    @Published var testingTargetID: String?
    private weak var runtime: OverviewRuntime?
    @Published private(set) var didSave = false
    let onImport: () -> Void
    let onSelect: (InstalledPack) -> Void
    let onRemove: (LibraryEntry) throws -> Void
    let onResetPlayback: () throws -> Void
    private var saved: ExperienceSettings
    private let onSave: (ExperienceSettings) throws -> Void
    private let onPreview: (ExperienceSettings, InstalledPack) throws -> Void
    var isDirty: Bool { draft != saved }
    var preferences: PackPreferences { pack.flatMap { draft.packs[$0.id] } ?? .init() }

    init(pack: InstalledPack?, settings: ExperienceSettings, warning: String, playbackState: PlaybackState,
         onImport: @escaping () -> Void, onSelect: @escaping (InstalledPack) -> Void,
         onRemove: @escaping (LibraryEntry) throws -> Void, onResetPlayback: @escaping () throws -> Void,
         onSave: @escaping (ExperienceSettings) throws -> Void,
         onPreview: @escaping (ExperienceSettings, InstalledPack) throws -> Void, runtime: OverviewRuntime? = nil) {
        self.runtime = runtime; self.welcomeDismissed = runtime?.welcomeDismissed ?? false
        self.playbackState = playbackState; self.activeID = pack?.id
        self.onImport = onImport; self.onSelect = onSelect; self.onRemove = onRemove; self.onResetPlayback = onResetPlayback
        self.pack = pack; draft = settings; saved = settings; message = warning
        self.onSave = onSave; self.onPreview = onPreview
    }
    func overview(targetID: String?) -> OverviewSnapshot {
        if let runtime { return runtime.overview(targetID: targetID) }
        let targets = saved.targets.filter { $0.bundleID != nil }.map { OverviewTarget(id: $0.id, name: $0.name) }
        return OverviewSnapshot(targets: targets, selectedID: targets.first(where: { $0.id == targetID })?.id ?? targets.first?.id,
                                reason: .ready, connected: false)
    }
    func updateOverview() -> UpdateOverview {
        runtime?.updateOverview() ?? UpdateOverview(version: Support.releaseVersion, automatic: false,
            message: "正式运行 Sakura 后，可在这里检查更新。", connected: false)
    }
    func checkForUpdates() { runtime?.checkForUpdatesFromSettings(); objectWillChange.send() }
    func setAutomaticUpdates(_ value: Bool) {
        do { try runtime?.setAutomaticUpdates(value); objectWillChange.send() }
        catch { message = "更新偏好未保存，请稍后重试。" }
    }
    func openUpdateDownload() { runtime?.openUpdateDownload(); objectWillChange.send() }
    func openUpdateFallback() { runtime?.openUpdateFallback() }
    func setWelcomeDismissed(_ value: Bool) {
        do { try runtime?.setWelcomeDismissed(value); welcomeDismissed = value }
        catch { message = "引导偏好未保存，请稍后重试。" }
    }
    func performOverviewAction(_ action: String) {
        do { try runtime?.performOverviewAction(action); objectWillChange.send() }
        catch { message = "操作未完成：\(error.localizedDescription)" }
    }
    func update(_ change: (inout PlaybackOverrides) -> Void) {
        guard let pack else { return }
        var next = draft
        change(&next.packs[pack.id, default: .init()].overrides)
        draft = next
        message = "调整后可直接预览；保存后用于下次播放。"
    }
    func resetPack() { guard let pack else { return }; draft.resetPack(pack.id); message = "已恢复本包默认参数，已存方案仍保留。" }
    func addPreset(_ name: String) {
        guard let pack else { return }
        do { try draft.addPreset(packID: pack.id, name: name); message = "方案已加入草稿，点击保存设置后保留。" }
        catch { message = error.localizedDescription }
    }
    func applyPreset(_ id: String) {
        guard let preset = preferences.presets.first(where: { $0.id == id }) else { return }
        update { $0 = preset.overrides }
        message = "已应用「\(preset.name)」，可先预览再保存。"
    }
    func deletePreset(_ id: String) {
        guard let pack else { return }
        draft.packs[pack.id]?.presets.removeAll { $0.id == id }
        message = "方案已从草稿移除，保存后生效。"
    }
    @discardableResult func save() -> Bool {
        do {
            var next = draft
            next.greetingName = try Greeting.normalizedName(draft.greetingName)
            try next.validated()
            try onSave(next)
            draft = next; saved = next; didSave = true; message = "已保存，下次播放使用这些设置。"
            return true
        }
        catch { message = "未保存：\(error.localizedDescription)"; return false }
    }
    func preview(_ requested: InstalledPack? = nil) {
        guard let selected = requested ?? pack else { message = "请先导入可用动画包，再进行预览。"; return }
        do { try draft.validated(); try onPreview(draft, selected); message = "正在预览当前调整；未保存的设置不会用于自动播放。" }
        catch { message = "无法预览：\(error.localizedDescription)" }
    }
    func skipGreetingStep() {
        greetingStepSkipped = true
    }

    func previewGreeting() {
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent(Support.greetingResource),
              let greeting = try? PackLibrary.load(directory: directory) else {
            message = "问候动画不可用。"
            return
        }
        preview(greeting)
    }

    func discard() { draft = saved }
    func updateTarget(_ id: String, change: (inout ApplicationTarget) -> Void) {
        guard let index = draft.targets.firstIndex(where: { $0.id == id && $0.bundleID != nil }) else { return }
        change(&draft.targets[index])
    }
    func chooseVideo() {
        let panel = NSOpenPanel()
        panel.title = "选择一个视频"
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .appleProtectedMPEG4Video, .movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard VideoPackRules.fileExtension(fileName: url.lastPathComponent) != nil else {
            message = "请选择 mp4、m4v 或 mov 视频。"; return
        }
        videoDraft = VideoDraft(url: url, name: VideoPackRules.defaultName(fileName: url.lastPathComponent))
    }
    func createFromVideo() {
        guard let draft = videoDraft, draft.confirmed, VideoPackRules.validName(draft.name) else { return }
        videoDraft = nil
        do { try runtime?.createPack(fromVideo: draft.url, name: draft.name) }
        catch { message = error.localizedDescription }
    }
    func testTarget(_ id: String) {
        do { try runtime?.testTarget(id) }
        catch { message = error.localizedDescription }
    }
    func removeTarget(_ id: String) { draft.targets.removeAll { $0.id == id && $0.bundleID != nil } }
    func addTarget(name: String, bundleID: String) {
        guard !draft.targets.contains(where: { $0.bundleID == bundleID }) else { return }
        var next = draft
        next.targets.append(ApplicationTarget(name: name.trimmingCharacters(in: .whitespacesAndNewlines), bundleID: bundleID))
        do { try next.validated(); draft = next }
        catch { message = error.localizedDescription }
    }
    func toggleFavorite(_ id: String) {
        guard id.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil else {
            message = "包标识无效，请修复动画包后再收藏。"; return
        }
        if draft.library.favorites.contains(id) { draft.library.favorites.removeAll { $0 == id } }
        else if draft.library.favorites.count < 200 { draft.library.favorites.append(id) }
        else { message = "最多收藏 200 个动画。" }
    }
    func inspect(_ selected: InstalledPack) { pack = selected }
    func select(_ selected: InstalledPack) { onSelect(selected); activeID = selected.id; pack = selected; message = "已设为当前动画。" }
    func resetPlayback() {
        do { try onResetPlayback(); message = "已清空播放记录，下次启动按当前暂停和动态效果设置播放。" }
        catch { message = "播放记录未清空：\(error.localizedDescription)" }
    }
    func remove(_ entry: LibraryEntry) {
        guard !Support.protectedPackIDs.contains(entry.id) else { return }
        let alert = NSAlert()
        alert.messageText = "移除「\(entry.name)」？"
        alert.informativeText = "动画包会移到废纸篓。个人参数、方案与收藏会保留。"
        alert.addButton(withTitle: "移到废纸篓"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try onRemove(entry); message = "已将「\(entry.name)」移到废纸篓。" }
        catch { message = "未移除：\(error.localizedDescription)" }
    }
    func reloadLibrary() async {
        libraryBusy = true
        let result = await PackMedia.playableLibrary(Support.library)
        entries = result.packs.map { LibraryEntry(id: $0.id, name: $0.manifest.name, pack: $0, problem: nil) }
        for (id, problem) in result.problems {
            let file = Support.library.root.appendingPathComponent(id).appendingPathComponent("manifest.json")
            let raw = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            entries.append(LibraryEntry(id: id, name: raw?["name"] as? String ?? id, pack: nil, problem: problem))
        }
        entries.sort { $0.id < $1.id }
        let active = PackLibrary.resolveActive(preferredID: Support.defaults.string(forKey: "activePackID"), packs: result.packs, fallbackID: Support.defaultPackID)
        activeID = active?.id
        pack = result.packs.first(where: { $0.id == pack?.id }) ?? active
        libraryBusy = false
    }
    var todayStatus: String {
        let now = Date(), hour = draft.playback.dayStartHour
        let records = draft.targets.filter { $0.enabled && $0.bundleID != nil }.compactMap { playbackState.targets[$0.id]?.lastAutoPlayAt }
        guard let last = records.max(), last <= now.timeIntervalSince1970 + 300,
              ScheduleDecision.dayKey(last, offset: TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: last)), dayStartHour: hour)
                == ScheduleDecision.dayKey(now.timeIntervalSince1970, offset: TimeZone.current.secondsFromGMT(for: now), dayStartHour: hour)
        else { return "今天尚未播放" }
        return draft.targets.filter { $0.enabled && $0.bundleID != nil }.count > 1
            ? "最近于 \(Support.clockTime(last)) 播放（各应用单独记录）" : "今天已于 \(Support.clockTime(last)) 播放"
    }
}

struct LibraryEntry: Identifiable {
    let id: String
    let name: String
    let pack: InstalledPack?
    let problem: String?
}

