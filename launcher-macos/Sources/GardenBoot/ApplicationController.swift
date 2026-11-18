import AppKit
import Carbon
import ServiceManagement
import GardenBootCore

@MainActor
final class ApplicationController: NSObject, NSApplicationDelegate, NSMenuDelegate, OverviewRuntime {
    private let testTargetIdentifier: String?
    private var sessions: [String: LaunchSession] = [:]
    private var playbackTargetID: String?
    private let monitor = ApplicationMonitor()
    private var player: LaunchOverlay?
    private var libraryTask: Task<Void, Never>?
    private var autoTask: Task<Void, Never>?
    private var warmTask: Task<Void, Never>?
    private var warmPlayback: PreparedPlayback?
    private var warmKey: String?
    private var warmGeneration = UUID()
    private var warmPoll: Timer?
    private var wakeWatch: NSObjectProtocol?
    private var terminating = false
    // Isolated GUI checks can request a fresh decoder even if idle preparation wins the race.
    private var coldFirstFrame = CommandLine.arguments.contains("--test-root") && CommandLine.arguments.contains("--test-cold-start")
    private var generation = UUID()
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private let packsMenu = NSMenu()
    private var activePack: InstalledPack?
    private var experience = ExperienceSettings()
    private let playbackStore = PlaybackStateStore(directory: Support.root)
    private var playbackState = PlaybackState()
    private let snoozeTomorrowItem = NSMenuItem(title: "", action: #selector(snoozeTomorrow), keyEquivalent: "")
    private let resumeItem = NSMenuItem(title: "恢复自动播放", action: #selector(resumeAutoPlay), keyEquivalent: "")
    private let autoStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let experienceStore = ExperienceStore(directory: Support.root)
    private var settingsWindow: SettingsWindowController?
    private var experienceWarning = ""
    private var showSettingsWhenReady = false
    private var failedOverviewPacks: [String: String] = [:]
    private let stateItem = NSMenuItem(title: "正在准备动画…", action: nil, keyEquivalent: "")
    private let currentItem = NSMenuItem(title: "当前动画：无", action: nil, keyEquivalent: "")
    private var libraryProblemCount = 0
    private let pauseItem = NSMenuItem(title: "暂停自动播放", action: #selector(togglePause), keyEquivalent: "")
    private let motionItem = NSMenuItem(title: "关闭动画时仍播放", action: #selector(toggleMotion), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "开机自动运行", action: #selector(toggleLogin), keyEquivalent: "")
    private var paused = !CommandLine.arguments.contains("--logic-only") && Support.defaults.bool(forKey: "paused")
    private var playDespiteReduceMotion = Support.defaults.bool(forKey: "playDespiteReduceMotion")
    private let started = Date()
    /// Set from the system's open-application event when macOS starts the launcher as a login item.
    private var startedAtLogin = false

    init(testTargetIdentifier: String? = nil) {
        self.testTargetIdentifier = testTargetIdentifier
        super.init()
    }

    private var targets: [ApplicationTarget] {
        if let testTargetIdentifier {
            var test = ApplicationTarget(id: "default-codex", name: "测试应用", bundleID: testTargetIdentifier)
            test.playOnReappear = CommandLine.arguments.contains("--test-reappear")
            return [test]
        }
        return experience.targets.filter { $0.enabled && $0.bundleID != nil }
    }
    private var waitingTitle: String {
        targets.count > 1 ? "正在等待 \(targets.count) 个应用启动" : targets.isEmpty ? "尚未启用应用" : "正在等待目标下次启动"
    }
    private func configureTargets() {
        var next: [String: LaunchSession] = [:]
        for target in targets {
            let bundleID = target.bundleID!
            let previous = monitoredIdentities[target.id] == bundleID ? sessions[target.id] : nil
            let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            next[target.id] = previous ?? LaunchSession(targetIdentifier: bundleID, existingPIDs: Set(existing.map(\.processIdentifier)))
            if previous == nil { Support.log("monitor-started target=\(target.id) bundle=\(bundleID) baseline=\(existing.count) at-login=\(startedAtLogin)") }
        }
        sessions = next
        monitoredIdentities = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0.bundleID!) })
        if player == nil && autoTask == nil { stateItem.title = waitingTitle }
        configureReappear()
    }
    private var monitoredIdentities: [String: String] = [:]

    /// Double-clicking Sakura while it already runs (single instance) shows the settings instead of doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let loginReopen = event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        guard !loginReopen else { return false }
        Support.log("reopen-requested")
        openSettings()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // AppKit dispatches the initial open event here, after applicationWillFinishLaunching.
        let event = NSAppleEventManager.shared().currentAppleEvent
        startedAtLogin = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        NSApp.setActivationPolicy(.accessory)
        NativeMenu.install()
        do { experience = try experienceStore.load() }
        catch { experienceWarning = error.localizedDescription; Support.log("experience-load-failed") }
        playbackState = playbackStore.load { Support.log("playback-state-reset") }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = FlowerIcon.image()
        item.button?.toolTip = "Sakura"
        item.menu = menu
        menu.delegate = self
        statusItem = item
        menu.addItem(NSMenuItem(title: "Sakura", action: nil, keyEquivalent: ""))
        updateItem.target = self; updateItem.isHidden = true; menu.addItem(updateItem)
        menu.addItem(autoStatusItem)
        menu.addItem(currentItem)
        menu.addItem(.separator())
        add("调节启动体验…", action: #selector(openSettings), key: ",")
        add("预览当前动画", action: #selector(preview), key: "p")
        add("导入动画包…", action: #selector(choosePack))
        let packsItem = NSMenuItem(title: "切换动画", action: nil, keyEquivalent: "")
        packsItem.submenu = packsMenu
        menu.addItem(packsItem)
        menu.addItem(.separator())
        pauseItem.target = self; menu.addItem(pauseItem)
        add("暂停 1 小时", action: #selector(snoozeHour))
        snoozeTomorrowItem.target = self; menu.addItem(snoozeTomorrowItem)
        resumeItem.target = self; menu.addItem(resumeItem)
        motionItem.target = self; menu.addItem(motionItem)
        motionItem.toolTip = "系统开启“减弱动态效果”时仍播放动画。"
        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)
        add("检查更新…", action: #selector(checkForUpdatesManually))
        autoUpdateItem.target = self; menu.addItem(autoUpdateItem)
        add("在 GitHub 查看", action: #selector(openUpdatePage))
        autoUpdateItem.toolTip = "每周最多联网一次，只读取 GitHub 上的公开版本列表；不下载、不安装。"
        add("打开日志", action: #selector(openLog))
        menu.addItem(.separator())
        add("退出 Sakura", action: #selector(quit), key: "q")
        refreshMenu()
        reloadPacks()
        // Observe launches during first-run installation too. The bundled pack can
        // cover a launch immediately while its validated library copy is installed.
        if activePack == nil, let bundled = Bundle.main.resourceURL?.appendingPathComponent("demo-pack") {
            activePack = try? PackLibrary.load(directory: bundled)
        }
        startMonitoring()
        startUpdateChecks()
        refreshWarmup()
        // P-012: every 2 s with slack so the system can batch the wakeup; a launch re-checks freshness itself
        // (takeWarmPlayback compares the full preparation key), so this only affects how soon a re-warm happens.
        warmPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.player == nil, self.autoTask == nil else { return }
                // Re-read the manifest too, so external in-place edits invalidate the warm decoder.
                if let pack = self.activePack, let latest = try? PackLibrary.load(directory: pack.directory) {
                    self.activePack = latest
                }
                self.refreshWarmup()
            }
        }
        warmPoll?.tolerance = 0.5
        wakeWatch = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                       object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWarmup(force: true) }
        }
        libraryTask = Task { [weak self] in
            guard let self else { return }
            if let bundled = Bundle.main.resourceURL?.appendingPathComponent("demo-pack", isDirectory: true),
               FileManager.default.fileExists(atPath: bundled.path) {
                do {
                    if let installed = try await Support.library.installIfMissing(bundled: bundled, probe: PackMedia.probe, imageProbe: PackMedia.imageProbe) {
                        Support.log("pack-installed id=\(installed.id)")
                    }
                } catch { Support.log("bundled-pack-error=\(error.localizedDescription)") }
            }
            await self.installFeaturedPack()
            do {
                if let migrated = try await Support.library.migrateLegacyVideo(Support.media, probe: PackMedia.probe) {
                    Support.log("legacy-migrated id=\(migrated.id)")
                }
            } catch { Support.log("legacy-migration-error=\(error.localizedDescription)") }
            guard !Task.isCancelled else { return }
            self.reloadPacks()
            self.libraryTask = nil
            if self.player == nil { self.stateItem.title = self.paused ? "自动播放已暂停" : self.waitingTitle }
            if CommandLine.arguments.contains("--preview") { self.preview() }
            if let path = argument(after: "--test-create-video") {
                let video = URL(fileURLWithPath: path)
                do { try self.createPack(fromVideo: video, name: VideoPackRules.defaultName(fileName: video.lastPathComponent)) }
                catch { Support.log("pack-create-failed=\(error.localizedDescription)") }
            }
            if let id = argument(after: "--test-compat") {
                do { try self.testTarget(id) } catch { Support.log("compat-refused target=\(id)") }
            }
            // Opened by hand (Finder/Dock/Launchpad, no arguments) → show the settings; at login stay silent.
            if CommandLine.arguments.contains("--settings") || self.showSettingsWhenReady || (CommandLine.arguments.count == 1 && !self.startedAtLogin) {
                Support.log("settings-opened-on-launch")
                self.openSettings()
            }
            if let ack = argument(after: "--update-ready") { try? Data(Support.releaseVersion.utf8).write(to: URL(fileURLWithPath: ack), options: .atomic) }
            if CommandLine.arguments.contains("--update-failed") { self.updateAlert("更新未完成，已保留或恢复旧版。可去 GitHub 手动下载。", button: "去 GitHub 手动下载", url: "https://github.com/shishyguo-cyber/sakura-launcher/releases") }
        }
    }

    private func startMonitoring() {
        monitor.onLaunch = { [weak self] app in self?.launched(app) }
        monitor.onTerminate = { [weak self] app in
            guard let self, let target = self.targets.first(where: { $0.bundleID == app.bundleIdentifier }) else { return }
            Support.log("target-exited pid=\(app.processIdentifier) target=\(target.id)")
            let ended = self.sessions[target.id]?.didTerminate(pid: app.processIdentifier) == true
                || NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleID!).allSatisfy { $0.isTerminated || $0 == app }
            if ended, self.playbackTargetID == target.id {
                if self.player != nil { self.player?.send(.targetExited) }
                else { self.cancel(.targetExited) }
            }
        }
        monitor.onActivate = { [weak self] app in
            guard let self, let overlay = self.player else { return }
            let switched = PlaybackPolicy.endsOnActivation(
                isLauncher: app.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                isTarget: self.targets.contains { $0.bundleID == app.bundleIdentifier }, overlayAge: overlay.age)
            if switched {
                Support.log("foreground-cancel pid=\(app.processIdentifier) app=\(app.bundleIdentifier ?? "unknown") age=\(overlay.age) target=\(self.playbackTargetID ?? "preview")")
                self.cancel(.userSwitched)
            }
        }
        monitor.start()
        configureTargets()
    }

    private func add(_ title: String, action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    private func launched(_ app: NSRunningApplication) {
        guard let target = targets.first(where: { $0.bundleID == app.bundleIdentifier }),
              sessions[target.id]?.didLaunch(identifier: app.bundleIdentifier ?? "", pid: app.processIdentifier) == true else { return }
        // A new process: its first window is part of the cold start, not a reappearance.
        reappearTrackers[target.id] = ReappearTracker()
        awaitingFirstWindow.insert(target.id)
        let testing = compat?.id == target.id
        if testing {
            compat?.coldAt = Date(); compat?.pid = app.processIdentifier
            Support.log("compat-cold target=\(target.id) pid=\(app.processIdentifier)")
        }
        if CommandLine.arguments.contains("--logic-only") {
            Support.log("logic-trigger pid=\(app.processIdentifier) target=\(target.id)")
            sessions[target.id]?.finish()
            return
        }
        startLaunch(target: target, app: app, kind: "cold", testing: testing)
    }

    /// Shared decision path for cold starts and reappearances (COMPATIBILITY.md §2–3).
    /// While "测试" runs for this target, frequency, snooze, quiet and policy are ignored and nothing is recorded.
    private func startLaunch(target: ApplicationTarget, app: NSRunningApplication, kind: String, testing: Bool) {
        let detected = Date()
        Support.log("launch-detected target=\(target.id) kind=\(kind) pid=\(app.processIdentifier)")
        func skip(_ reason: String, _ detail: String? = nil) {
            // A reappearance never owns the cold-start session (which may still be playing).
            if kind == "cold" { sessions[target.id]?.finish() }
            Support.log("playback-skipped reason=\(reason) target=\(target.id)" + (detail.map { " detail=\($0)" } ?? ""))
        }
        if !testing {
            guard PlaybackPolicy.shouldAutoPlay(paused: paused,
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                playDespiteReduceMotion: playDespiteReduceMotion) else { skip("policy"); return }
            if kind == "cold", !CommandLine.arguments.contains("--test-root"),
               let reason = LaunchFilter.skip(targetHidden: app.isHidden, launcherAge: Date().timeIntervalSince(started),
                                            launcherStartedAtLogin: startedAtLogin, systemUptime: ProcessInfo.processInfo.systemUptime) {
                skip(reason.rawValue); return
            }
            let quiet = QuietRules.skip(enabled: experience.playback.quietWhenFullscreen, state: quietState(excluding: app.processIdentifier))
            if quiet.skip { skip("quiet", quiet.detail); return }
            guard player == nil, autoTask == nil else { skip("busy"); return }
            let now = Date()
            playbackState = playbackStore.load { Support.log("playback-state-reset") }
            let last = playbackState.targets[target.id]?.lastAutoPlayAt ?? now.timeIntervalSince1970
            let decision = ScheduleDecision.decide(frequency: experience.playback.frequency,
                dayStartHour: experience.playback.dayStartHour, state: playbackState, targetID: target.id,
                now: now.timeIntervalSince1970, nowOffset: TimeZone.current.secondsFromGMT(for: now),
                lastOffset: TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: last)))
            guard decision == .play else { skip(decision == .snoozed ? "snoozed" : "played-today"); refreshMenu(); return }
        }
        // Reserve the slot before asynchronous media checks; previews also occupy it.
        guard player == nil, autoTask == nil else { skip("busy"); return }
        playbackTargetID = target.id
        autoTask = Task { [weak self] in
            guard let self else { return }
            var installed: (packs: [InstalledPack], problems: [String: String])
            if target.animation == nil, self.experience.library.rotation == .fixed, let active = self.activePack {
                installed = ([active], [:])
            } else { installed = await PackMedia.playableLibrary(Support.library) }
            if installed.packs.isEmpty, self.libraryTask != nil, let bundled = self.activePack,
               bundled.directory.path == Bundle.main.resourceURL?.appendingPathComponent("demo-pack").path {
                installed.packs.append(bundled)
            }
            guard !Task.isCancelled else { return }
            guard !app.isTerminated else {
                self.autoTask = nil; self.sessions[target.id]?.finish(); self.playbackTargetID = nil; return
            }
            let active = PackLibrary.resolveActive(preferredID: Support.defaults.string(forKey: "activePackID"),
                packs: installed.packs, fallbackID: Support.demoID)
            let choice = TargetPackChoice.choose(animation: target.animation, rotation: self.experience.library.rotation,
                favorites: self.experience.library.favorites, available: installed.packs.map(\.id).sorted(), active: active?.id,
                lastPackId: self.playbackState.targets[target.id]?.lastPackId, random: Double.random(in: 0..<1))
            if choice.missing { Support.log("target-pack-missing target=\(target.id) pack=\(target.animation!)") }
            guard let chosen = installed.packs.first(where: { $0.id == choice.id }) else {
                self.autoTask = nil; self.sessions[target.id]?.finish(); self.playbackTargetID = nil
                self.stateItem.title = "尚无可用动画"
                Support.log("playback-skipped reason=no-configured-pack target=\(target.id)"); return
            }
            Support.log("pack-chosen id=\(chosen.id) rotation=\(target.animation != nil && !choice.missing ? "target" : self.experience.library.rotation.rawValue) target=\(target.id)")
            self.autoTask = nil
            if testing { self.compat?.pack = chosen }
            self.play(target: app, preview: false, pack: chosen, opened: detected, targetID: target.id, record: !testing)
        }
    }

    private func play(target: NSRunningApplication?, preview: Bool, using draft: ExperienceSettings? = nil, pack requested: InstalledPack? = nil, opened: Date? = nil, targetID: String? = nil, record: Bool = true) {
        guard player == nil, autoTask == nil else {
            Support.log("playback-skipped reason=busy target=\(targetID ?? "preview")")
            if preview { settingsWindow?.editor.message = "动画正在播放，请结束后再预览。" }
            return
        }
        playbackTargetID = targetID
        let detected = opened ?? Date()
        if preview { Support.log("preview-requested target=preview") }
        let token = UUID()
        generation = token
        guard let original = requested ?? activePack, let screen = Support.screenUnderPointer else {
            stateItem.title = "尚无可用动画"
            sessions[targetID ?? ""]?.finish(); playbackTargetID = nil
            Support.log("playback-skipped reason=no-configured-pack target=\(targetID ?? "preview")")
            return
        }
        let preferences = draft ?? experience
        let pack: InstalledPack
        do { pack = try original.applying(preferences) }
        catch { stateItem.title = "无法播放：个人设置无效"; sessions[targetID ?? ""]?.finish(); playbackTargetID = nil; return }
        Support.log("experience-applied pack=\(pack.id) preview=\(preview) volume=\(pack.manifest.effectiveVolume) fade=\(pack.manifest.effectiveFadeDuration) coverage=\(preferences.coverage(for: pack.id)) target=\(targetID ?? "preview")")
        let warm = takeWarmPlayback(for: original, preferences: preferences)
        let overlay = LaunchOverlay(pack: pack, target: target, screen: screen, preview: preview, opened: detected, warmPlayback: warm,
                                    launchCoverage: preferences.coverage(for: pack.id), targetID: targetID ?? "preview") { [weak self] reason in
            guard let self, self.generation == token else { return }
            self.player = nil
            if case .failed = reason { self.failedOverviewPacks[targetID ?? "preview"] = pack.id }
            if case .completed = reason { self.failedOverviewPacks = self.failedOverviewPacks.filter { $0.value != pack.id } }
            if preview, let editor = self.settingsWindow, editor.window?.isVisible == true, editor.editor.pack?.id == pack.id {
                if case .failed = reason { editor.editor.message = "预览失败，请检查动画包文件或重新导入。设置仍可编辑。" }
                else if case .windowTimeout = reason { editor.editor.message = "已达到等待上限并结束预览，可继续调整。" }
                else { editor.editor.message = "预览已结束，可继续调整或保存。" }
            }
            self.sessions[targetID ?? ""]?.finish()
            self.playbackTargetID = nil
            self.stateItem.title = self.waitingTitle
            self.refreshMenu()
            self.coldFirstFrame = false
            self.refreshWarmup(force: true)
        }
        overlay.onShown = { [weak self] in
            guard let self, self.generation == token else { return }
            guard !preview, record, let targetID else { return }
            var next = self.playbackState
            next.targets[targetID, default: .init()].lastAutoPlayAt = Date().timeIntervalSince1970
            next.targets[targetID, default: .init()].lastPackId = pack.id
            do { try self.savePlaybackState(next) }
            catch { Support.log("playback-state-write-failed=\(error.localizedDescription) target=\(targetID)") }
        }
        player = overlay
        stateItem.title = "正在播放：\(pack.manifest.name)"
        overlay.begin()
    }

    private func cancel(_ event: PlaybackEvent) {
        autoTask?.cancel(); autoTask = nil
        player?.send(event)
        if player == nil { sessions[playbackTargetID ?? ""]?.finish(); playbackTargetID = nil }
    }

    /// Include settings and file versions; never use a decoder for replaced media or a draft.
    private func preparationKey(_ pack: InstalledPack, _ preferences: ExperienceSettings) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let settings = (try? encoder.encode(preferences)) ?? Data()
        let manifest = (try? encoder.encode(pack.manifest)) ?? Data()
        let files = [PackManifest.fileName] + pack.manifest.segments.values.sorted()
        let versions = files.map { file -> String in
            let attributes = (try? FileManager.default.attributesOfItem(atPath: pack.url(for: file).path)) ?? [:]
            return "\(file):\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\(attributes[.size] ?? 0):\(attributes[.systemFileNumber] ?? 0)"
        }.joined(separator: "|")
        return pack.directory.path + manifest.base64EncodedString() + settings.base64EncodedString() + versions
    }

    private func discardWarmup() {
        warmGeneration = UUID()
        warmTask?.cancel(); warmTask = nil
        warmPlayback?.dispose(); warmPlayback = nil
        warmKey = nil
    }

    private func refreshWarmup(force: Bool = false) {
        guard !terminating, !CommandLine.arguments.contains("--logic-only"), !coldFirstFrame else { return }
        guard player == nil, autoTask == nil else {
            if force { discardWarmup() }
            return
        }
        guard let pack = activePack else { discardWarmup(); return }
        let key = preparationKey(pack, experience)
        guard force || key != warmKey else { return }
        discardWarmup()
        warmKey = key
        let token = warmGeneration
        let segment: PackSegment = pack.layout.intro != nil ? .intro : (pack.layout.loop != nil ? .loop : pack.layout.finalSegment)
        guard let file = pack.manifest.segments[segment] else { return }
        warmTask = Task { [weak self] in
            do {
                let media = try await PackMedia.load(pack.url(for: file))
                guard let self, !Task.isCancelled, self.warmGeneration == token, self.player == nil else { return }
                let playback = PreparedPlayback(segment: segment, media: media, looping: segment == .loop)
                self.warmPlayback = playback
                self.warmTask = nil
                playback.prepare { [weak self] ready in
                    guard let self, self.warmGeneration == token else { return }
                    if ready { Support.log("warm-ready pack=\(pack.id) segment=\(segment.rawValue) time=0") }
                    else { self.warmPlayback = nil; Support.log("warm-failed pack=\(pack.id)") }
                }
            } catch {
                guard let self, !Task.isCancelled, self.warmGeneration == token else { return }
                self.warmTask = nil
                Support.log("warm-failed pack=\(pack.id)")
            }
        }
    }

    private func takeWarmPlayback(for pack: InstalledPack, preferences: ExperienceSettings) -> PreparedPlayback? {
        let ready = warmKey == preparationKey(pack, preferences) && warmPlayback?.isPrerolled == true
        let result = ready ? warmPlayback : nil
        if ready { warmPlayback = nil }
        discardWarmup()
        return result
    }

    var welcomeDismissed: Bool { Support.defaults.bool(forKey: "welcomeDismissed") }
    func setWelcomeDismissed(_ value: Bool) throws { Support.defaults.set(value, forKey: "welcomeDismissed") }
    func overview(targetID: String?) -> OverviewSnapshot {
        let configured = testTargetIdentifier == nil ? experience.targets.filter { $0.bundleID != nil } : targets
        let selected = configured.first(where: { $0.id == targetID }) ?? configured.first
        var input = PlaybackStatusInput()
        input.preparing = libraryTask != nil || autoTask != nil
        input.playing = player != nil
        input.preview = player != nil && playbackTargetID == nil
        input.hasTarget = selected != nil; input.targetEnabled = selected?.enabled ?? false
        input.paused = paused
        input.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        input.allowMotion = playDespiteReduceMotion
        if !CommandLine.arguments.contains("--test-root") {
            input.loginGrace = LaunchFilter.skip(targetHidden: false, launcherAge: Date().timeIntervalSince(started),
                launcherStartedAtLogin: startedAtLogin, systemUptime: ProcessInfo.processInfo.systemUptime) != nil
        }
        let now = Date()
        if let selected {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: selected.bundleID!)
            input.running = !apps.isEmpty
            input.hidden = !apps.isEmpty && apps.allSatisfy { $0.isHidden }
            let last = playbackState.targets[selected.id]?.lastAutoPlayAt ?? now.timeIntervalSince1970
            let schedule = ScheduleDecision.decide(frequency: experience.playback.frequency, dayStartHour: experience.playback.dayStartHour,
                state: playbackState, targetID: selected.id, now: now.timeIntervalSince1970,
                nowOffset: TimeZone.current.secondsFromGMT(for: now), lastOffset: TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: last)))
            input.snoozed = schedule == .snoozed; input.playedToday = schedule == .playedToday
            let preferred = selected.animation.flatMap { try? PackLibrary.load(directory: Support.library.root.appendingPathComponent($0)) }
            let chosen = preferred ?? activePack
            input.hasPack = chosen.map { pack in pack.manifest.segments.values.allSatisfy {
                FileManager.default.fileExists(atPath: pack.directory.appendingPathComponent($0).path)
            } } ?? false
            if let chosen { input.failed = failedOverviewPacks[selected.id] == chosen.id || failedOverviewPacks["preview"] == chosen.id }
        }
        return OverviewSnapshot(targets: configured.map { OverviewTarget(id: $0.id, name: $0.name) },
                                selectedID: selected?.id, reason: .resolve(input))
    }
    func performOverviewAction(_ action: String) throws {
        if action == "unpause", paused { togglePause() }
        if action == "unsnooze" {
            var next = playbackState; next.snoozeUntil = nil
            try savePlaybackState(next); refreshMenu()
        }
    }

    // MARK: Featured built-in animation (launcher-spec/PACK-FORMAT.md, "内置动画")

    /// Installs the bundled featured pack once per user. A user who removes it does not get it back on the next
    /// launch; users without a current choice select it, while existing choices are preserved. Test roots skip it
    /// unless `--test-featured` is given, so controlled checks keep using the demo pack.
    private func installFeaturedPack() async {
        guard argument(after: "--test-root") == nil || CommandLine.arguments.contains("--test-featured"),
              let folder = Bundle.main.resourceURL?.appendingPathComponent(Support.featuredResource, isDirectory: true),
              let bundled = try? PackLibrary.load(directory: folder) else { return }
        var installed = Support.defaults.stringArray(forKey: "featuredInstalled") ?? []
        guard !installed.contains(bundled.id) else { return }
        do {
            let pack = try await Support.library.installIfMissing(bundled: folder, probe: PackMedia.probe, imageProbe: PackMedia.imageProbe)
            // Persist "offered once" before reporting, so a quit right after installing never reinstalls it.
            installed.append(bundled.id)
            Support.defaults.set(installed, forKey: "featuredInstalled")
            let previousID = Support.defaults.string(forKey: "activePackID")
            let preferredID = PackLibrary.preferredAfterFirstFeaturedInstall(preferredID: previousID, featuredID: bundled.id)
            if previousID == nil { Support.defaults.set(preferredID, forKey: "activePackID") }
            Support.defaults.synchronize()
            if let pack { Support.log("pack-installed id=\(pack.id) featured=true") }
            if previousID == nil { Support.log("featured-made-current id=\(bundled.id)") }
        } catch { Support.log("featured-pack-error=\(error.localizedDescription)") }
    }

    // MARK: "测试一下" (COMPATIBILITY.md §1)

    private struct CompatTest {
        let id: String
        let bundleID: String
        let started = Date()
        let runningAtStart: Bool
        var coldAt: Date?
        var pid: pid_t?
        var windowSeconds: Double?
        var pack: InstalledPack?
    }
    private var compat: CompatTest?
    private var compatTimer: Timer?

    func testTarget(_ id: String) throws {
        guard compat == nil else { return }
        guard let target = targets.first(where: { $0.id == id }), let bundleID = target.bundleID else {
            throw ExperienceError.invalid("请先保存设置并打开这个应用的开关，再测试。")
        }
        cancel(.superseded)
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        compat = CompatTest(id: id, bundleID: bundleID, runningAtStart: running)
        Support.log("compat-start target=\(id) running=\(running)")
        compatTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.compatTick() } }
        RunLoop.main.add(timer, forMode: .common)
        compatTimer = timer
        settingsWindow?.editor.testingTargetID = id
    }

    private func compatTick() {
        guard var test = compat else { compatTimer?.invalidate(); compatTimer = nil; return }
        let now = Date()
        if let coldAt = test.coldAt, test.windowSeconds == nil, let pid = test.pid,
           ApplicationMonitor.mainWindowFrame(pid: pid) != nil {
            test.windowSeconds = (now.timeIntervalSince(coldAt) * 10).rounded() / 10
            Support.log("compat-window target=\(test.id) seconds=\(test.windowSeconds!)")
            compat = test
        }
        let limit = argument(after: "--test-compat-seconds").flatMap(Double.init) ?? CompatibilityRules.testSeconds
        let settled = test.coldAt != nil && test.windowSeconds != nil && player == nil && autoTask == nil
        guard settled || now.timeIntervalSince(test.started) >= limit else { return }
        compatTimer?.invalidate(); compatTimer = nil
        let pack = test.pack ?? activePack
        let maxWait = (pack.flatMap { try? experience.resolved($0.manifest) })?.effectiveMaxWait ?? PackDefaults.maxWaitSeconds
        let verdict = CompatibilityRules.verdict(runningAtStart: test.runningAtStart, coldStart: test.coldAt != nil,
                                                 windowSeconds: test.windowSeconds, maxWait: maxWait)
        var next = playbackState
        next.targets[test.id, default: .init()].compat = .init(verdict: verdict, windowSeconds: test.windowSeconds, at: now.timeIntervalSince1970)
        do { try savePlaybackState(next) }
        catch { Support.log("playback-state-write-failed=\(error.localizedDescription) target=\(test.id)") }
        Support.log("compat-result target=\(test.id) verdict=\(verdict.rawValue) window=\(test.windowSeconds.map { String($0) } ?? "none")")
        compat = nil
        settingsWindow?.editor.testingTargetID = nil
    }

    // MARK: Reappear (COMPATIBILITY.md §2)

    private var reappearTimer: Timer?
    private var reappearTrackers: [String: ReappearTracker] = [:]
    /// Targets whose newest process has not shown a window yet (cold start in progress).
    private var awaitingFirstWindow: Set<String> = []

    private func configureReappear() {
        let watched = Set(targets.filter(\.playOnReappear).map(\.id))
        reappearTrackers = reappearTrackers.filter { watched.contains($0.key) }
        awaitingFirstWindow.formIntersection(watched)
        for id in watched where reappearTrackers[id] == nil { reappearTrackers[id] = ReappearTracker() }
        guard !watched.isEmpty, !CommandLine.arguments.contains("--logic-only") || CommandLine.arguments.contains("--test-reappear") else {
            reappearTimer?.invalidate(); reappearTimer = nil; return
        }
        guard reappearTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.reappearTick() } }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        reappearTimer = timer
    }

    private func reappearTick() {
        let watched = targets.filter(\.playOnReappear)
        let apps = watched.map { ($0, NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID!).filter { !$0.isTerminated }) }
        guard apps.contains(where: { !$0.1.isEmpty }) else {
            for target in watched { _ = reappearTrackers[target.id]?.feed(t: 0, running: false, hidden: false, hasWindow: false, hasVisibleMain: false) }
            return
        }
        let all = WindowPicker.windows(options: [.optionAll, .excludeDesktopElements])
        let visible = WindowPicker.windows(options: [.optionOnScreenOnly, .excludeDesktopElements])
        let t = ProcessInfo.processInfo.systemUptime
        for (target, running) in apps {
            let pids = Set(running.map(\.processIdentifier))
            let hidden = !running.isEmpty && running.allSatisfy(\.isHidden)
            // Minimized windows stay in the full list, so minimize/restore is not a reappearance.
            let hasWindow = WindowPicker.hasMainWindow(pids: pids, in: all, requireOpaque: false)
            let hasVisibleMain = WindowPicker.hasMainWindow(pids: pids, in: visible, requireOpaque: true)
            if awaitingFirstWindow.contains(target.id) {
                if hasVisibleMain || running.isEmpty { awaitingFirstWindow.remove(target.id) }
                continue
            }
            var tracker = reappearTrackers[target.id] ?? ReappearTracker()
            let fired = tracker.feed(t: t, running: !running.isEmpty, hidden: hidden, hasWindow: hasWindow, hasVisibleMain: hasVisibleMain)
            reappearTrackers[target.id] = tracker
            if fired, let app = running.first(where: { pids.contains($0.processIdentifier) }) {
                Support.log("target-reappeared target=\(target.id) pid=\(app.processIdentifier)")
                if !CommandLine.arguments.contains("--logic-only") { startLaunch(target: target, app: app, kind: "reappear", testing: false) }
            }
        }
    }

    // MARK: Quiet (COMPATIBILITY.md §3)

    /// Another frontmost app (not the target, not Sakura) showing a window that covers a whole display.
    private func quietState(excluding targetPID: pid_t) -> QuietState {
        if let forced = argument(after: "--test-quiet") { return QuietState(rawValue: forced) ?? .normal }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != targetPID, front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              front.bundleIdentifier != NSRunningApplication(processIdentifier: targetPID)?.bundleIdentifier else { return .normal }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return .normal }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return .normal }
        let screens = displays.prefix(Int(count)).map(CGDisplayBounds)
        let windows = WindowPicker.windows(options: [.optionOnScreenOnly, .excludeDesktopElements])
        return WindowPicker.coversDisplay(pid: front.processIdentifier, in: windows, displays: screens) ? .fullscreen : .normal
    }

    @objc private func openSettings() {
        guard libraryTask == nil else { showSettingsWhenReady = true; return }
        showSettingsWhenReady = false
        if let current = settingsWindow, current.window?.isVisible == true { current.present(); return }
        guard settingsWindow?.requestClose() != false else { return }
        cancel(.superseded)
        let window = SettingsWindowController(pack: activePack, settings: experience, warning: experienceWarning,
            playbackState: playbackState,
            onImport: { [weak self] in self?.choosePack() },
            onSelect: { [weak self] pack in
                guard let self else { return }
                self.cancel(.superseded)
                Support.defaults.set(pack.id, forKey: "activePackID"); self.reloadPacks()
            }, onRemove: { [weak self] entry in
                guard let self, entry.id != Support.demoID else { return }
                self.cancel(.superseded)
                // Entries are direct children enumerated from the library, including broken packs.
                let folder = Support.library.root.appendingPathComponent(entry.id, isDirectory: true)
                try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
                self.reloadPacks()
                Task { await self.settingsWindow?.editor.reloadLibrary() }
                Support.log("pack-removed id=\(entry.id)")
            }, onResetPlayback: { [weak self] in
                guard let self else { return }
                var next = self.playbackState
                for id in next.targets.keys { next.targets[id]?.lastAutoPlayAt = nil }
                try self.savePlaybackState(next)
                Support.log("playback-record-cleared")
            }, onSave: { [weak self] settings in
                guard let self else { return }
                try self.experienceStore.save(settings)
                self.experience = settings; self.experienceWarning = ""
                self.configureTargets()
                self.refreshMenu()
                self.refreshWarmup(force: true)
                Support.log("experience-saved")
            }, onPreview: { [weak self] settings, pack in
                try settings.validated()
                guard let self else { return }
                guard self.player == nil, self.autoTask == nil else {
                    Support.log("playback-skipped reason=busy target=preview")
                    throw ExperienceError.invalid("动画正在播放，请结束后再预览。")
                }
                self.play(target: nil, preview: true, using: settings, pack: pack)
            }, runtime: self)
        window.editor.testingTargetID = compat?.id
        settingsWindow = window; window.present()
        Support.log("settings-opened pack=\(activePack?.id ?? "none")")
    }

    @objc private func preview() {
        guard libraryTask == nil else { return }
        play(target: nil, preview: true)
    }

    func createPack(fromVideo video: URL, name: String) throws {
        guard libraryTask == nil else { throw ExperienceError.invalid("动画库正在更新，请稍后再试。") }
        cancel(.superseded)
        stateItem.title = "正在从视频创建动画…"
        settingsWindow?.editor.libraryBusy = true
        settingsWindow?.editor.message = "正在检查视频…"
        let staging = Support.root.appendingPathComponent(".video-\(UUID().uuidString)", isDirectory: true)
        libraryTask = Task { [weak self] in
            defer { try? FileManager.default.removeItem(at: staging) }
            do {
                let existing = Set(Support.library.installed().packs.map(\.id))
                let folder = try VideoPackRules.build(video: video, name: name, existingIDs: existing, in: staging)
                let pack = try await Support.library.importPack(from: folder, probe: PackMedia.probe, imageProbe: PackMedia.imageProbe)
                guard !Task.isCancelled else { return }
                Support.defaults.set(pack.id, forKey: "activePackID")
                self?.reloadPacks()
                self?.stateItem.title = "动画已更新，可点击预览"
                if let editor = self?.settingsWindow?.editor {
                    await editor.reloadLibrary(); editor.pack = pack; editor.activeID = pack.id
                    editor.message = "已创建「\(pack.manifest.name)」。可在“声音与过渡”里调整淡出起点。"
                }
                Support.log("pack-created-from-video id=\(pack.id)")
            } catch {
                self?.stateItem.title = "创建失败，动画库未改变"
                self?.settingsWindow?.editor.message = "无法用这个视频创建动画：\(error.localizedDescription)"
                self?.settingsWindow?.editor.libraryBusy = false
                Support.log("pack-create-failed=\(error.localizedDescription)")
            }
            self?.libraryTask = nil
        }
    }

    @objc private func choosePack() {
        guard libraryTask == nil else { return }
        cancel(.superseded)
        Support.requestFocus()
        let panel = NSOpenPanel()
        panel.title = "选择动画包文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        stateItem.title = "正在检查动画包…"
        settingsWindow?.editor.libraryBusy = true
        libraryTask = Task { [weak self] in
            do {
                let pack = try await Support.library.importPack(from: url, probe: PackMedia.probe, imageProbe: PackMedia.imageProbe)
                guard !Task.isCancelled else { return }
                Support.defaults.set(pack.id, forKey: "activePackID")
                self?.reloadPacks()
                self?.stateItem.title = "动画已更新，可点击预览"
                if let editor = self?.settingsWindow?.editor {
                    await editor.reloadLibrary(); editor.pack = pack
                    editor.message = "已导入「\(pack.manifest.name)」并设为当前。"
                }
                Support.log("pack-imported id=\(pack.id)")
            } catch {
                self?.stateItem.title = "导入失败，已保留原包"
                self?.settingsWindow?.editor.message = "导入失败：\(error.localizedDescription)"
                self?.settingsWindow?.editor.libraryBusy = false
                Support.log("pack-import-failed=\(error.localizedDescription)")
            }
            self?.libraryTask = nil
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if libraryTask == nil { reloadPacks(); refreshMenu() }
    }

    private func reloadPacks() {
        let installed = Support.library.installed()
        activePack = PackLibrary.resolveActive(preferredID: Support.defaults.string(forKey: "activePackID"),
                                              packs: installed.packs, fallbackID: Support.demoID)
        currentItem.title = "当前动画：\(activePack?.manifest.name ?? "无")"
        libraryProblemCount = installed.problems.count
        packsMenu.removeAllItems()
        for pack in installed.packs {
            let item = NSMenuItem(title: pack.manifest.name, action: #selector(selectPack(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = pack.id
            item.state = pack.id == activePack?.id ? .on : .off
            packsMenu.addItem(item)
        }
        refreshWarmup()
        Support.log("packs-loaded count=\(installed.packs.count) skipped=\(installed.problems.count) active=\(activePack?.id ?? "none")")
    }

    @objc private func selectPack(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        cancel(.superseded)
        Support.defaults.set(id, forKey: "activePackID")
        reloadPacks()
        if let selected = Support.library.installed().packs.first(where: { $0.id == id }) {
            settingsWindow?.editor.activeID = id; settingsWindow?.editor.pack = selected
        }
    }

    // MARK: Update check (launcher-spec/UPDATES.md)

    private let updateItem = NSMenuItem(title: "", action: #selector(installUpdate), keyEquivalent: "")
    private let autoUpdateItem = NSMenuItem(title: "自动检查更新", action: #selector(toggleAutoUpdate), keyEquivalent: "")
    private var updateTimer: Timer?
    private var updateTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var updateMessage = "尚未检查更新" { didSet { if installTask != nil { updateItem.title = updateMessage + " · 取消下载" } } }
    private var autoUpdateEnabled: Bool {
        // Isolated test roots never go online by default.
        let fallback = argument(after: "--test-root") == nil || CommandLine.arguments.contains("--test-check-update")
        return Support.defaults.object(forKey: "autoCheckUpdates") as? Bool ?? fallback
    }

    private func startUpdateChecks() {
        refreshUpdateItem()
        let first = CommandLine.arguments.contains("--test-check-update") ? 0.5 : 60
        DispatchQueue.main.asyncAfter(deadline: .now() + first) { [weak self] in self?.checkForUpdates(manual: false) }
        let timer = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForUpdates(manual: false) }
        }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }

    /// Stored result from an earlier check; cleared once this build is at least that version.
    private func refreshUpdateItem() {
        autoUpdateItem.state = autoUpdateEnabled ? .on : .off
        guard let version = Support.defaults.string(forKey: "updateAvailableVersion"),
              (UpdateRules.compare(version, Support.releaseVersion) ?? 0) > 0 else {
            Support.defaults.removeObject(forKey: "updateAvailableVersion")
            Support.defaults.removeObject(forKey: "updateAvailableURL")
            updateItem.isHidden = true
            return
        }
        updateItem.title = "有新版本 \(version) · 更新…"
        if updateItem.isHidden { Support.log("update-available latest=\(version)") }
        updateItem.isHidden = false
    }

    private func fetchReleases() async throws -> [UpdateRules.Release] {
        if let feed = argument(after: "--test-update-feed") {
            return try UpdateRules.decodeReleases(Data(contentsOf: URL(fileURLWithPath: feed)))
        }
        guard argument(after: "--test-root") == nil else { throw URLError(.notConnectedToInternet) }
        var request = URLRequest(url: UpdateRules.releasesURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("Sakura/\(Support.releaseVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try UpdateRules.decodeReleases(data)
    }

    private func checkForUpdates(manual: Bool, showAlert: Bool = true) {
        guard updateTask == nil, installTask == nil else { return }
        if !manual {
            let last = Support.defaults.object(forKey: "updateLastCheckAt") as? Double
            guard autoUpdateEnabled, UpdateRules.isDue(lastCheckAt: last, now: Date().timeIntervalSince1970) else { return }
        }
        let source = manual ? "manual" : "auto"
        updateMessage = "正在检查更新…"
        updateTask = Task { [weak self] in
            let result: Result<[UpdateRules.Release], Error>
            do { result = .success(try await self?.fetchReleases() ?? []) } catch { result = .failure(error) }
            guard let self else { return }
            self.updateTask = nil
            switch result {
            case .failure(let error):
                Support.log("update-check source=\(source) result=failed latest=none error=\(type(of: error))")
                self.updateMessage = "暂时无法检查更新，请稍后再试。"
                if manual && showAlert { self.updateAlert(self.updateMessage, button: nil, url: nil) }
            case .success(let releases):
                Support.defaults.set(Date().timeIntervalSince1970, forKey: "updateLastCheckAt")
                if let newer = UpdateRules.newest(releases, current: Support.releaseVersion) {
                    Support.defaults.set(newer.version, forKey: "updateAvailableVersion")
                    Support.defaults.set(newer.url, forKey: "updateAvailableURL")
                    Support.log("update-check source=\(source) result=newer latest=\(newer.version)")
                    self.updateMessage = "发现新版本 \(newer.version)"
                    if manual && showAlert { self.openSettings() }
                } else {
                    Support.defaults.removeObject(forKey: "updateAvailableVersion")
                    Support.defaults.removeObject(forKey: "updateAvailableURL")
                    Support.log("update-check source=\(source) result=current latest=none")
                    self.updateMessage = "已是最新版本（\(Support.releaseVersion)）。"
                    if manual && showAlert { self.updateAlert("已是最新版本（\(Support.releaseVersion)）。", button: nil, url: nil) }
                }
                self.refreshUpdateItem()
            }
        }
    }

    private func updateAlert(_ text: String, button: String?, url: String?) {
        Support.requestFocus()
        let alert = NSAlert()
        alert.messageText = "检查更新"
        alert.informativeText = text
        if let button { alert.addButton(withTitle: button) }
        alert.addButton(withTitle: button == nil ? "好" : "以后再说")
        if alert.runModal() == .alertFirstButtonReturn, button != nil, let url, let target = URL(string: url) {
            NSWorkspace.shared.open(target)
        }
    }

    @objc private func checkForUpdatesManually() { checkForUpdates(manual: true) }
    func updateOverview() -> UpdateOverview {
        let newer = Support.defaults.string(forKey: "updateAvailableVersion").flatMap {
            (UpdateRules.compare($0, Support.releaseVersion) ?? 0) > 0 ? $0 : nil
        }
        let message = updateMessage == "尚未检查更新" ? newer.map { "发现新版本 \($0)" } ?? updateMessage : updateMessage
        return UpdateOverview(version: Support.releaseVersion, automatic: autoUpdateEnabled,
            checking: updateTask != nil, message: message, availableVersion: newer, installing: installTask != nil)
    }
    func checkForUpdatesFromSettings() { checkForUpdates(manual: true, showAlert: false) }
    func openUpdateDownload() { installUpdate() }
    func openUpdateFallback() { openUpdatePage() }
    @objc private func installUpdate() {
        if let task = installTask { task.cancel(); return }
        guard let version = updateOverview().availableVersion else { return }
        installTask = Task { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("Sakura-update-" + UUID().uuidString)
            var prepared: URL?
            do {
                guard argument(after: "--test-root") == nil else { throw SignedUpdate.Failure.permission }
                try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let free = try fm.attributesOfFileSystem(forPath: work.path)[.systemFreeSize] as? NSNumber
                guard (free?.int64Value ?? 0) > 5 * 1024 * 1024 * 1024 else { throw SignedUpdate.Failure.space }
                let asset = try SignedUpdate.asset(version: version, current: Support.releaseVersion, platform: "macOS")
                let sig = UpdateDownload(destination: work.appendingPathComponent("update.sig"), limit: 16384) { _ in }
                let signature = try await sig.fetch(URL(string: asset.absoluteString + ".sig")!)
                let downloader = UpdateDownload(destination: work.appendingPathComponent("update.zip"), limit: Int64(SignedUpdate.maxArchive)) { [weak self] progress in
                    Task { @MainActor in self?.updateMessage = progress < 0 ? "正在下载更新…" : "正在下载更新 \(Int(progress * 100))%" }
                }
                let zip = try await downloader.fetch(asset)
                try Task.checkCancellation()
                self.updateMessage = "正在验证并准备安装…"
                let target = Bundle.main.bundleURL
                let request = try await Task.detached {
                    try UpdateInstaller.prepare(zip: zip, signature: signature, target: target, version: version, current: Support.releaseVersion, work: work)
                }.value
                prepared = request
                try Task.checkCancellation()
                let helper = work.appendingPathComponent("SakuraUpdater")
                try fm.copyItem(at: Bundle.main.executableURL!, to: helper)
                let p = Process(); p.executableURL = helper; p.arguments = ["--apply-update", request.path]
                try p.run()
                NSApp.terminate(nil)
            } catch {
                if let prepared, let data = try? Data(contentsOf: prepared), let r = try? JSONDecoder().decode(UpdateInstaller.Request.self, from: data) { try? fm.removeItem(atPath: r.staged) }
                try? fm.removeItem(at: work)
                let cancelled = Task.isCancelled
                self.updateMessage = cancelled ? "下载已取消，旧版仍可使用。" : "更新失败：\(error.localizedDescription) 可去 GitHub 手动下载。"
                if !cancelled { self.updateAlert(self.updateMessage, button: "去 GitHub 手动下载", url: "https://github.com/shishyguo-cyber/sakura-launcher/releases") }
                self.installTask = nil
                self.refreshUpdateItem()
            }
        }
    }

    @objc private func toggleAutoUpdate() { setAutomaticUpdates(!autoUpdateEnabled) }
    func setAutomaticUpdates(_ value: Bool) {
        Support.defaults.set(value, forKey: "autoCheckUpdates")
        refreshUpdateItem()
        Support.log("auto-update-check enabled=\(autoUpdateEnabled)")
    }
    @objc private func openUpdatePage() {
        let version = updateOverview().availableVersion
        let page = version.map { "https://github.com/shishyguo-cyber/sakura-launcher/releases/tag/v\($0)" }
            ?? "https://github.com/shishyguo-cyber/sakura-launcher/releases"
        if let target = URL(string: page) { NSWorkspace.shared.open(target) }
    }

    private func refreshMenu() {
        pauseItem.state = paused ? .on : .off
        snoozeTomorrowItem.title = "暂停到明天 \(experience.playback.dayStartHour):00"
        let until = playbackState.snoozeUntil.flatMap { $0 > Date().timeIntervalSince1970 ? $0 : nil }
        resumeItem.isHidden = until == nil
        if paused { autoStatusItem.title = "自动播放已暂停" }
        else if let until { autoStatusItem.title = "自动播放已暂停到 \(Support.clockTime(until))" }
        else { autoStatusItem.title = "自动播放：\(experience.playback.frequency == .firstOfDay ? "每天首次" : "每次启动")" }
        autoStatusItem.title = stateItem.title + " · " + autoStatusItem.title
        if libraryProblemCount > 0 { autoStatusItem.title += " · 已跳过 \(libraryProblemCount) 个无效动画" }
        motionItem.state = playDespiteReduceMotion ? .on : .off
        let status = SMAppService.mainApp.status
        loginItem.state = status == .enabled ? .on : .off
        loginItem.title = "开机自动运行"
        loginItem.toolTip = status == .requiresApproval ? "等待系统批准；请在系统设置的登录项中允许 Sakura。" : nil
    }

    private func savePlaybackState(_ next: PlaybackState) throws {
        guard !CommandLine.arguments.contains("--logic-only") else { return }
        try playbackStore.save(next); playbackState = next
        refreshMenu(); settingsWindow?.editor.playbackState = next
    }
    private func snooze(until: Double?) {
        var next = playbackState; next.snoozeUntil = until
        do { try savePlaybackState(next); if until != nil { cancel(.skip) } }
        catch { stateItem.title = "暂停设置未保存"; Support.log("playback-state-write-failed=\(error.localizedDescription)") }
    }
    @objc private func snoozeHour() { snooze(until: Date().timeIntervalSince1970 + 3600) }
    @objc private func snoozeTomorrow() {
        let now = Date()
        snooze(until: ScheduleDecision.nextDayStart(now: now.timeIntervalSince1970,
            nowOffset: TimeZone.current.secondsFromGMT(for: now), dayStartHour: experience.playback.dayStartHour))
    }
    @objc private func resumeAutoPlay() { snooze(until: nil) }

    @objc private func togglePause() {
        paused.toggle()
        Support.defaults.set(paused, forKey: "paused")
        if paused { cancel(.skip) }
        refreshMenu()
        refreshWarmup(force: true)
        stateItem.title = paused ? "自动播放已暂停" : waitingTitle
    }
    @objc private func toggleMotion() {
        playDespiteReduceMotion.toggle()
        Support.defaults.set(playDespiteReduceMotion, forKey: "playDespiteReduceMotion")
        refreshMenu()
        refreshWarmup(force: true)
    }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { stateItem.title = "登录项未更新，请检查系统设置"; Support.log("login-update-error=\(error.localizedDescription)") }
        refreshMenu()
    }
    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    @objc private func openLog() { NSWorkspace.shared.open(Support.root.appendingPathComponent("events.log")) }
    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        settingsWindow?.requestClose() == false ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        compatTimer?.invalidate(); reappearTimer?.invalidate(); updateTimer?.invalidate(); updateTask?.cancel(); installTask?.cancel()
        warmPoll?.invalidate(); warmPoll = nil
        if let wakeWatch { NSWorkspace.shared.notificationCenter.removeObserver(wakeWatch) }
        discardWarmup()
        cancel(.superseded)
        monitor.stop()
        libraryTask?.cancel()
        autoTask?.cancel()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
