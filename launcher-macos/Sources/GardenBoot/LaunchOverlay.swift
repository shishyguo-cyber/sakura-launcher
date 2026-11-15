import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreImage
import GardenBootCore

/// Borderless panel that can hold keyboard focus without activating the launcher, so the target
/// app stays the active application underneath while the overlay is on screen.
private final class OverlayPanel: NSPanel {
    var onDismiss: (() -> Void)?

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        alphaValue = 0
        ignoresMouseEvents = true
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        level = .statusBar
        collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        title = "Sakura"
    }

    override var canBecomeKey: Bool { true }

    /// AppKit routes both Escape and Command-period here.
    override func cancelOperation(_ sender: Any?) { onDismiss?() }

    /// Belt and braces for Escape in case no responder turns it into `cancelOperation`.
    override func keyDown(with event: NSEvent) {
        guard Int(event.keyCode) == kVK_Escape else { return super.keyDown(with: event) }
        onDismiss?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, event.charactersIgnoringModifiers == "." {
            onDismiss?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Rounded video surface. Any click on it skips; a quiet hint fades in after a moment.
private final class OverlaySurface: NSView {
    @MainActor
    private final class Picture {
        let playback: PreparedPlayback
        var aspect: CGFloat
        let root = CALayer()
        let background = CALayer()
        let dim = CALayer()
        init(_ playback: PreparedPlayback) {
            self.playback = playback
            self.aspect = playback.media.videoAspect
            background.addSublayer(playback.backgroundVideoLayer)
            root.addSublayer(background)
            dim.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
            root.addSublayer(dim)
            root.addSublayer(playback.videoLayer)
        }
    }
    private var pictures: [Picture] = []
    private var requested: VideoFit.Mode = .auto
    private var videoAspect: CGFloat = .nan
    private var lastMode: VideoFit.Mode?
    let hint = NSTextField(labelWithString: "点击或按 Esc 跳过")
    var onClick: (() -> Void)?
    var targetID = "preview"

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        hint.font = .systemFont(ofSize: 12, weight: .medium)
        hint.textColor = NSColor.white.withAlphaComponent(0.9)
        hint.alphaValue = 0
        hint.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.6)
            s.shadowBlurRadius = 4
            return s
        }()
        hint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("跳过启动动画")
    }

    required init?(coder: NSCoder) { nil }

    func configure(requested: VideoFit.Mode) { self.requested = requested }

    /// Keep the outgoing picture underneath until the incoming layer can display a real frame.
    func stage(_ playback: PreparedPlayback) {
        let picture = Picture(playback)
        picture.root.opacity = 0
        layer?.insertSublayer(picture.root, at: 0)
        pictures.append(picture)
        updateVideoLayout()
    }

    func discard(_ playback: PreparedPlayback) {
        pictures.filter { $0.playback === playback }.forEach { $0.root.removeFromSuperlayer() }
        pictures.removeAll { $0.playback === playback }
    }

    func reveal(_ playback: PreparedPlayback) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for picture in pictures where picture.playback !== playback { picture.root.removeFromSuperlayer() }
        pictures.removeAll { $0.playback !== playback }
        pictures.first?.root.opacity = 1
        CATransaction.commit()
        setVideoAspect(playback.media.videoAspect)
    }

    func setVideoAspect(_ aspect: CGFloat) {
        pictures.first { $0.root.opacity > 0 }?.aspect = aspect
        guard aspect != videoAspect else { return }
        videoAspect = aspect
        updateVideoLayout()
    }

    /// Layer-backed (not layer-hosting), so the hint can stay an ordinary subview.
    override func makeBackingLayer() -> CALayer {
        let base = CALayer()
        base.backgroundColor = NSColor.black.cgColor
        base.cornerRadius = 16
        base.cornerCurve = .continuous
        base.masksToBounds = true
        return base
    }

    override func layout() {
        super.layout()
        updateVideoLayout()
    }

    private func updateVideoLayout() {
        let resolved = VideoFit.resolve(mode: requested, frameSize: bounds.size, videoAspect: videoAspect)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for picture in pictures {
            let aspect = picture.aspect
            let mode = VideoFit.resolve(mode: requested, frameSize: bounds.size, videoAspect: aspect)
            picture.root.frame = bounds
            picture.background.frame = bounds
            picture.playback.backgroundVideoLayer.frame = VideoFit.resolve(mode: .fill, frameSize: bounds.size, videoAspect: aspect).contentRect
            picture.playback.backgroundVideoLayer.videoGravity = .resizeAspectFill
            picture.dim.frame = bounds
            picture.playback.videoLayer.frame = mode.contentRect
            picture.playback.videoLayer.videoGravity = mode.mode == .fit ? .resizeAspect : .resizeAspectFill
            let showBackground = mode.mode == .fit
            picture.background.isHidden = !showBackground
            picture.dim.isHidden = !showBackground
            if showBackground {
                let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: min(bounds.width, bounds.height) * 0.04])
                let clamp = CIFilter(name: "CIAffineClamp")
                picture.background.filters = [clamp, blur].compactMap { $0 }
            } else { picture.background.filters = nil }
        }
        CATransaction.commit()
        if lastMode != resolved.mode {
            lastMode = resolved.mode
            Support.log("video-fit mode=\(resolved.mode.rawValue) requested=\(requested.rawValue) target=\(targetID)")
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// Runs one launch: turns AppKit / AVFoundation happenings into `PlaybackEvent`s for the pure
/// `PlaybackMachine`, and carries out the `PlaybackCommand`s it returns. All segments are
/// loaded independently; a pending segment keeps the outgoing picture on screen.
@MainActor
final class LaunchOverlay {
    private static let tickInterval = 1.0 / 60
    private static let moveDuration = 0.45
    /// Shorter glide used when the target window moves again after docking.
    private static let followDuration = 0.22
    private static let windowQueryInterval = 0.15
    private static let hintDelay = 0.8
    private static let revealDuration = 0.12
    private static let prepareLimit = 6.0
    private static let stallLimit = 6.0
    /// A preview has no target; pretend its window appears after this long so every segment shows.
    private static let previewWindowDelay = 3.0

    private let pack: InstalledPack
    private let target: NSRunningApplication?
    private let isPreview: Bool
    private let onFinish: (PlaybackEndReason) -> Void
    private var machine: PlaybackMachine
    private var inbox: [PlaybackEvent] = []
    private var draining = false

    private var launchFrame: CGRect
    private let launchScreen: CGRect
    private let launchCoverage: CGFloat
    private var targetFrame: CGRect?
    private var panel: OverlayPanel?
    private var surface: OverlaySurface?
    private var current: PreparedPlayback?
    private var incoming: PreparedPlayback?
    private var warmPlayback: PreparedPlayback?
    private var player: AVQueuePlayer? { current?.player }
    private var location = "launch-screen"
    private var usedWarm = false
    private var preparingSince: Date?
    private var revealStarted: Date?
    private var loopWatch: NSKeyValueObservation?
    private var itemWatches: [NSObjectProtocol] = []
    private var media: [PackSegment: PackMedia.Loaded] = [:]
    private var loading: Task<Void, Never>?
    private var clock: Timer?

    private let opened: Date
    var onShown: (() -> Void)?
    private var shownAt: Date?
    private var focusChecked = false
    private var lastWindowQuery = Date.distantPast
    private var windowReported = false
    private var timeoutReported = false
    private var queued: (segment: PackSegment, looping: Bool, since: Date)?
    private var handoffAt: Double?
    private var handoffReported = false
    private var waitingSince: Date?
    private var move: (from: CGRect, to: CGRect, start: Date, duration: Double)?
    private var lastFollowQuery = Date.distantPast
    private var fade: (start: Date, duration: Double, volume: Float, alpha: CGFloat)?

    var isFinished: Bool { machine.isClosed }
    /// Seconds since this launch began; the controller uses it for the activation grace period.
    var age: TimeInterval { Date().timeIntervalSince(opened) }

    private let targetID: String
    private func log(_ event: String) { Support.log(event + " target=\(targetID)") }

    init(pack: InstalledPack, target: NSRunningApplication?, screen: NSScreen, preview: Bool, opened: Date, warmPlayback: PreparedPlayback? = nil, launchCoverage: Double = 0.72, targetID: String = "preview",
         onFinish: @escaping (PlaybackEndReason) -> Void) {
        self.targetID = targetID
        self.opened = opened
        self.warmPlayback = warmPlayback
        self.pack = pack
        self.target = target
        self.isPreview = preview
        self.onFinish = onFinish
        self.launchScreen = screen.visibleFrame
        self.launchCoverage = CGFloat(launchCoverage)
        self.launchFrame = OverlayGeometry.launchFrame(in: screen.visibleFrame, coverage: CGFloat(launchCoverage))
        self.machine = PlaybackMachine(pack: pack)
    }

    func begin() {
        preload()
        let clock = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(clock, forMode: .common)
        self.clock = clock
        targetFrame = target.flatMap { ApplicationMonitor.mainWindowFrame(pid: $0.processIdentifier) }
        let ready = targetFrame != nil || (isPreview && !pack.layout.coversLaunch)
        windowReported = ready
        // Even single-video packs waiting for a target need Esc routing before their first frame.
        present(at: launchFrame, place: "launch-screen")
        send(.start(windowReady: ready))
    }

    /// Events can arrive while commands run (e.g. a close during a fade); queue them so each
    /// transition's commands always finish before the next event is handled.
    func send(_ event: PlaybackEvent) {
        guard !machine.isClosed else { return }
        inbox.append(event)
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while !inbox.isEmpty {
            for command in machine.handle(inbox.removeFirst()) { perform(command) }
        }
    }

    // MARK: Commands

    private func perform(_ command: PlaybackCommand) {
        switch command {
        case .showOnLaunchScreen:
            present(at: launchFrame, place: "launch-screen")
        case .showOnTargetWindow:
            present(at: targetFrame ?? launchFrame, place: "target-window")
        case .moveToTargetWindow(let animated):
            guard let panel else { return }
            location = "target-window"
            let destination = targetFrame ?? panel.frame
            self.log("player-move animated=\(animated) to=\(NSStringFromRect(destination))")
            if animated { move = (panel.frame, destination, Date(), Self.moveDuration) } else { setPanelFrame(destination) }
        case .play(let segment, let looping):
            current?.player.pause()
            stopObservingPlayback()
            if let incoming {
                surface?.discard(incoming)
                incoming.dispose()
                self.incoming = nil
            }
            queued = (segment, looping, Date())
            startQueuedSegment()
        case .holdLastFrame:
            player?.pause()
            self.log("player-hold-last-frame")
        case .beginFade(let duration):
            incoming?.player.pause()
            revealStarted = nil
            fade = (Date(), duration, player?.volume ?? 0, panel?.alphaValue ?? 0)
            self.log("player-fade duration=\(duration)")
        case .close(let reason, let wasVisible):
            finish(reason, wasVisible: wasVisible)
        }
    }

    private func present(at frame: CGRect, place: String) {
        location = place
        if panel != nil { setPanelFrame(frame); return }
        let panel = OverlayPanel(frame: frame)
        let surface = OverlaySurface(frame: CGRect(origin: .zero, size: frame.size))
        surface.targetID = targetID
        surface.autoresizingMask = [.width, .height]
        surface.configure(requested: pack.manifest.effectiveVideoFit)
        surface.onClick = { [weak self] in self?.send(.skip) }
        panel.onDismiss = { [weak self] in self?.send(.skip) }
        panel.contentView = surface
        self.log("overlay-alpha=0.000 phase=prepared")
        panel.orderFrontRegardless()
        // Keep Esc routing while invisible; mouse events still pass through to the target.
        panel.makeKey()
        self.panel = panel
        self.surface = surface
        location = place
    }

    /// Resize the video layers in the same tick as the panel, including each docking/follow step.
    private func setPanelFrame(_ frame: CGRect) {
        panel?.setFrame(frame, display: true)
        surface?.needsLayout = true
        surface?.layoutSubtreeIfNeeded()
    }

    // MARK: Media

    private func preload() {
        let files = PackSegment.allCases.compactMap { segment in pack.manifest.segments[segment].map { (segment, pack.url(for: $0)) } }
        let warm = warmPlayback
        if let warm { media[warm.segment] = warm.media }
        preparingSince = Date()
        loading = Task { [weak self] in
            do {
                try await withThrowingTaskGroup(of: (PackSegment, PackMedia.Loaded).self) { group in
                    for (segment, url) in files where segment != warm?.segment {
                        group.addTask { (segment, try await PackMedia.load(url)) }
                    }
                    for try await (segment, item) in group {
                        guard let self, !Task.isCancelled, !self.machine.isClosed else { group.cancelAll(); return }
                        self.media[segment] = item
                        self.startQueuedSegment()
                    }
                }
                guard let self, !Task.isCancelled, !self.machine.isClosed else { return }
                self.preparingSince = nil
                self.log("media-preloaded segments=\(self.media.count)")
            } catch {
                guard !Task.isCancelled else { return }
                self?.log("media-preload-failed=\(error.localizedDescription)")
                self?.send(.failed("media"))
            }
        }
    }

    private func startQueuedSegment() {
        guard machine.phase != .fading, !machine.isClosed,
              let request = queued, incoming == nil, let item = media[request.segment] else { return }
        // Pause on the existing frame while the new decoder/layer gets ready.
        current?.player.pause()
        stopObservingPlayback()
        let prepared: PreparedPlayback
        if let warm = warmPlayback, warm.segment == request.segment {
            prepared = warm
            usedWarm = warm.isPrerolled
            warmPlayback = nil
        } else {
            warmPlayback?.dispose(); warmPlayback = nil
            prepared = PreparedPlayback(segment: request.segment, media: item, looping: request.looping)
        }
        incoming = prepared
        prepared.player.isMuted = true
        prepared.player.volume = Float(pack.manifest.effectiveVolume)
        surface?.stage(prepared)
        prepared.player.play()
        self.log("player-prepare segment=\(request.segment.rawValue)")
    }

    private func displayIncomingIfReady() {
        guard machine.phase != .fading, !machine.isClosed, let incoming, let request = queued,
              incoming.videoLayer.isReadyForDisplay else { return }
        surface?.reveal(incoming)
        incoming.player.isMuted = false
        current?.dispose()
        current = incoming
        self.incoming = nil
        queued = nil
        surface?.setVideoAspect(incoming.media.videoAspect)
        if !machine.isOnTargetWindow, (machine.phase == .intro || machine.phase == .looping),
           incoming.media.videoAspect.isFinite, incoming.media.videoAspect > 0 {
            launchFrame = OverlayGeometry.launchFrame(in: launchScreen, aspect: incoming.media.videoAspect, coverage: launchCoverage)
            setPanelFrame(launchFrame)
        }
        if let looper = incoming.looper {
            loopWatch = looper.observe(\.loopCount, options: [.new]) { [weak self, weak incoming] _, _ in
                Task { @MainActor in
                    guard let self, let incoming, self.current === incoming else { return }
                    self.log("loop-cycle-ended")
                    self.send(.loopCycleEnded)
                }
            }
        } else if let item = incoming.player.currentItem {
            let center = NotificationCenter.default
            itemWatches.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item,
                                                  queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.send(.segmentEnded(request.segment)) }
            })
            itemWatches.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item,
                                                  queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.send(.failed("decode")) }
            })
        }
        let isFinal = request.segment == pack.layout.finalSegment
        handoffAt = isFinal ? pack.manifest.handoffTime(finalDuration: incoming.media.duration) : nil
        handoffReported = false
        self.log("player-play segment=\(request.segment.rawValue) looping=\(request.looping) length=\(String(format: "%.2f", incoming.media.duration))")
        if shownAt == nil, let panel {
            let now = Date()
            self.log("first-frame age=\(String(format: "%.3f", now.timeIntervalSince(opened))) warm=\(usedWarm) segment=\(request.segment.rawValue)")
            self.log("overlay-alpha=\(String(format: "%.3f", panel.alphaValue)) phase=before-show")
            shownAt = now
            revealStarted = now
            self.log("player-show location=\(location) frame=\(NSStringFromRect(panel.frame)) pack=\(pack.id)")
            panel.ignoresMouseEvents = false
            panel.makeKey()
            onShown?()
        }
    }

    private func stopObservingPlayback() {
        loopWatch?.invalidate(); loopWatch = nil
        itemWatches.forEach(NotificationCenter.default.removeObserver)
        itemWatches.removeAll()
        handoffAt = nil
        waitingSince = nil
    }

    // MARK: Clock

    private func tick() {
        guard !machine.isClosed else { return }
        let now = Date()
        // presentationSize follows the currently displayed item, including AVPlayerLooper copies
        // and any in-stream dimension change. Preloaded track dimensions cover startup.
        if let size = player?.currentItem?.presentationSize, size.width > 0, size.height > 0,
           size.width.isFinite, size.height.isFinite {
            surface?.setVideoAspect(size.width / size.height)
        }
        if let target, target.isTerminated { send(.targetExited); return }
        if let target, target.isHidden, !windowReported { send(.targetHidden); return }

        if let fade {
            let progress = now.timeIntervalSince(fade.start) / fade.duration
            let eased = OverlayGeometry.ease(progress)
            panel?.alphaValue = fade.alpha * CGFloat(1 - eased)
            player?.volume = fade.volume * Float(1 - eased)
            self.log("overlay-alpha=\(String(format: "%.3f", panel?.alphaValue ?? 0)) phase=fade-out")
            if progress >= 1 {
                self.fade = nil
                self.log("fade-completed")
                send(.fadeCompleted)
            }
            return
        }

        if let move, panel != nil {
            let progress = now.timeIntervalSince(move.start) / move.duration
            setPanelFrame(OverlayGeometry.interpolate(from: move.from, to: move.to, progress: progress))
            if progress >= 1 { self.move = nil }
        }

        if let shownAt, let surface {
            let visible = OverlayGeometry.ease((now.timeIntervalSince(shownAt) - Self.hintDelay) / 0.4)
            surface.hint.alphaValue = CGFloat(visible * 0.85)
            if !focusChecked, now.timeIntervalSince(shownAt) > 0.3 {
                focusChecked = true
                let isKey = panel?.isKeyWindow ?? false
                self.log("panel-key=\(isKey)")
                if !isKey, !isPreview { Support.requestFocus(); panel?.makeKey() }
            }
        }

        pollTargetWindow(now)
        followTargetWindow(now)
        if !windowReported, !timeoutReported,
           now.timeIntervalSince(opened) >= pack.manifest.effectiveMaxWait {
            timeoutReported = true
            self.log("wait-timed-out")
            send(.waitTimedOut)
        }

        guard machine.phase != .fading, !machine.isClosed else { return }
        if let since = preparingSince, now.timeIntervalSince(since) > Self.prepareLimit {
            send(.failed("prepare-timeout")); return
        }
        if let request = queued, now.timeIntervalSince(request.since) > Self.prepareLimit {
            send(.failed("prepare-timeout"))
            return
        }
        displayIncomingIfReady()
        if let start = revealStarted {
            let progress = now.timeIntervalSince(start) / Self.revealDuration
            panel?.alphaValue = CGFloat(OverlayGeometry.ease(progress))
            self.log("overlay-alpha=\(String(format: "%.3f", panel?.alphaValue ?? 0)) phase=fade-in")
            if progress >= 1 { revealStarted = nil }
        }
        if let handoffAt, let player, !handoffReported, CMTimeGetSeconds(player.currentTime()) >= handoffAt {
            handoffReported = true
            self.log("player-handoff")
            send(.reachedHandoff)
        }
        watchForStall(now)
    }

    private func pollTargetWindow(_ now: Date) {
        guard !windowReported, now.timeIntervalSince(lastWindowQuery) >= Self.windowQueryInterval else { return }
        lastWindowQuery = now
        if let target { targetFrame = ApplicationMonitor.mainWindowFrame(pid: target.processIdentifier) }
        let previewReady = isPreview && now.timeIntervalSince(opened) >= Self.previewWindowDelay
        guard targetFrame != nil || previewReady else { return }
        windowReported = true
        self.log("window-ready preview=\(isPreview)")
        send(.windowReady)
    }

    /// After docking, keep the overlay on the target window if it still moves or resizes
    /// (apps often restore their saved frame a moment after first appearing). Stops once fading.
    private func followTargetWindow(_ now: Date) {
        guard windowReported, machine.isOnTargetWindow, machine.phase != .fading, !machine.isClosed,
              let target, let panel,
              now.timeIntervalSince(lastFollowQuery) >= Self.windowQueryInterval else { return }
        lastFollowQuery = now
        guard let latest = ApplicationMonitor.mainWindowFrame(pid: target.processIdentifier) else { return }
        let docked = move?.to ?? panel.frame
        guard OverlayGeometry.shouldFollow(current: docked, latest: latest) else { return }
        targetFrame = latest
        self.log("player-follow to=\(NSStringFromRect(latest))")
        move = (panel.frame, latest, now, Self.followDuration)
    }

    /// Fails the launch if the media pipeline keeps waiting for data, or an item reports an error.
    private func watchForStall(_ now: Date) {
        if [current, incoming].compactMap({ $0 }).contains(where: { $0.player.currentItem?.status == .failed || $0.looper?.status == .failed }) {
            send(.failed("decode"))
            return
        }
        if (incoming?.player ?? player)?.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            let since = waitingSince ?? now
            waitingSince = since
            if now.timeIntervalSince(since) > Self.stallLimit { send(.failed("stalled")) }
        } else {
            waitingSince = nil
        }
    }

    // MARK: Teardown

    private func finish(_ reason: PlaybackEndReason, wasVisible _: Bool) {
        clock?.invalidate()
        clock = nil
        loading?.cancel()
        loading = nil
        stopObservingPlayback()
        current?.dispose(); current = nil
        incoming?.dispose(); incoming = nil
        warmPlayback?.dispose(); warmPlayback = nil
        media.removeAll()
        panel?.alphaValue = 0
        self.log("overlay-alpha=0.000 phase=closed")
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        surface = nil
        // The panel normally leaves the target active. Only if the launcher had to take focus
        // (fallback) does it hand focus back, and never away from an app the user switched to.
        let me = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if reason.offersFocusToTarget, front == me, let target,
           PlaybackRules.shouldReturnFocus(frontmost: front, player: me, target: target.processIdentifier,
                                           targetAlive: !target.isTerminated) {
            _ = target.activate(options: [])
        }
        self.log("player-finished reason=\(reason.logName) wasVisible=\(shownAt != nil)")
        onFinish(reason)
    }
}
