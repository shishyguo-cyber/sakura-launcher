import Foundation

/// Why a playback ended. Decides whether focus goes back to the target.
public enum PlaybackEndReason: Equatable, Sendable {
    case completed
    case skipped
    /// The target window never became ready within `maxWaitSeconds`.
    case windowTimeout
    case targetExited
    /// The target was hidden (e.g. started hidden at login) before showing a window.
    case targetHidden
    case userSwitched
    case superseded
    case failed(String)

    /// Focus is offered back to the target only when the user did not go elsewhere and the target lives.
    /// The app still applies `PlaybackRules.shouldReturnFocus` before activating anything.
    public var offersFocusToTarget: Bool {
        switch self {
        case .completed, .skipped, .windowTimeout, .failed: return true
        case .targetExited, .targetHidden, .userSwitched, .superseded: return false
        }
    }

    public var logName: String {
        switch self {
        case .completed: return "completed"
        case .skipped: return "skipped"
        case .windowTimeout: return "window-timeout"
        case .targetExited: return "target-exited"
        case .targetHidden: return "target-hidden"
        case .userSwitched: return "user-switched"
        case .superseded: return "superseded"
        case .failed(let why): return "failed-\(why)"
        }
    }
}

/// Inputs the app layer reports to the machine.
public enum PlaybackEvent: Equatable, Sendable {
    /// A new target process was detected. `windowReady` is true if its window is already visible.
    case start(windowReady: Bool)
    /// The target's visible main window appeared (first report wins; repeats are ignored).
    case windowReady
    /// A non-looping segment played to its end.
    case segmentEnded(PackSegment)
    /// The looping segment wrapped around once.
    case loopCycleEnded
    /// Playback time in the final segment reached `PackManifest.handoffTime(finalDuration:)`.
    case reachedHandoff
    case fadeCompleted
    case skip
    /// `maxWaitSeconds` elapsed since `start` without the window becoming ready.
    case waitTimedOut
    case targetExited
    /// The target is hidden and has no window yet; ignored once the window was ready.
    case targetHidden
    case userSwitched
    case superseded
    case failed(String)
}

/// Outputs the app layer must carry out, in order.
public enum PlaybackCommand: Equatable, Sendable {
    /// Show the player centred on the screen the launch came from (segmented packs, before the window exists).
    case showOnLaunchScreen
    /// Show the player directly on the target window's frame (window already known).
    case showOnTargetWindow
    /// Move and resize the visible player onto the target window's frame.
    case moveToTargetWindow(animated: Bool)
    case play(PackSegment, looping: Bool)
    /// Keep the last frame of the intro on screen (intro without loop, window not ready yet).
    case holdLastFrame
    /// Fade window and audio to zero over `duration` seconds, then report `.fadeCompleted`.
    case beginFade(duration: Double)
    /// Tear the player down. `wasVisible` is false when nothing was ever shown.
    case close(PlaybackEndReason, wasVisible: Bool)
}

/// Pure state machine for one launch: intro → loop (until the window is ready) → outro → fade.
/// A single-video pack waits invisibly for the window, then plays on it and fades.
/// Events after the machine has closed produce no commands.
public struct PlaybackMachine: Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case waitingForWindow
        case intro
        case holding
        case looping
        case final
        case fading
        case closed(PlaybackEndReason)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var windowReady = false
    private var visible = false
    private var fadeReason: PlaybackEndReason = .completed
    private var attached = false
    private let layout: PackLayout
    private let fadeDuration: Double
    private let loopExit: LoopExit

    public init(layout: PackLayout, fadeDuration: Double = PackDefaults.fadeDuration, loopExit: LoopExit = .cycleEnd) {
        self.layout = layout
        self.fadeDuration = fadeDuration
        self.loopExit = loopExit
    }

    public init(pack: InstalledPack) {
        self.init(layout: pack.layout, fadeDuration: pack.manifest.effectiveFadeDuration,
                  loopExit: pack.manifest.effectiveLoopExit)
    }

    public var isClosed: Bool {
        if case .closed = phase { return true }
        return false
    }

    /// True once placed on the target window; the app follows it until fading or closing.
    public var isOnTargetWindow: Bool { attached }

    public mutating func handle(_ event: PlaybackEvent) -> [PlaybackCommand] {
        if isClosed { return [] }
        switch event {
        case .start(let ready):
            guard phase == .idle else { return [] }
            windowReady = ready
            return begin()
        case .windowReady:
            guard !windowReady else { return [] }
            windowReady = true
            return windowBecameReady()
        case .segmentEnded(let segment):
            return segmentEnded(segment)
        case .loopCycleEnded:
            guard phase == .looping, windowReady, loopExit == .cycleEnd else { return [] }
            return playFinal()
        case .reachedHandoff:
            guard phase == .final else { return [] }
            return fade(.completed, duration: fadeDuration)
        case .fadeCompleted:
            guard phase == .fading else { return [] }
            return close(fadeReason)
        case .skip:
            switch phase {
            case .idle: return []
            case .waitingForWindow: return close(.skipped)
            case .fading: return []
            default: return fade(.skipped, duration: PackDefaults.skipFadeDuration)
            }
        case .waitTimedOut:
            guard !windowReady else { return [] }
            switch phase {
            case .waitingForWindow:
                return close(.windowTimeout)
            case .intro, .holding, .looping:
                // Finish on the launch screen rather than leaving a cover over nothing.
                return fade(.windowTimeout, duration: fadeDuration)
            default:
                return []
            }
        case .targetExited:
            return close(.targetExited)
        case .targetHidden:
            // Hidden before any window: nothing for the user to see, so leave quietly.
            guard !windowReady else { return [] }
            return close(.targetHidden)
        case .userSwitched:
            return close(.userSwitched)
        case .superseded:
            return close(.superseded)
        case .failed(let why):
            return close(.failed(why))
        }
    }

    private mutating func begin() -> [PlaybackCommand] {
        if layout.coversLaunch && !windowReady {
            visible = true
            if let _ = layout.intro {
                phase = .intro
                return [.showOnLaunchScreen, .play(.intro, looping: false)]
            }
            phase = .looping
            return [.showOnLaunchScreen, .play(.loop, looping: true)]
        }
        if windowReady { return showFinalOnWindow() }
        phase = .waitingForWindow
        return []
    }

    private mutating func windowBecameReady() -> [PlaybackCommand] {
        switch phase {
        case .waitingForWindow:
            return showFinalOnWindow()
        case .holding:
            return playFinal()
        case .looping where loopExit == .immediate:
            return playFinal()
        case .intro where !attached, .looping where !attached:
            // Move now; the intro or current cycle keeps playing on the target window.
            return attach()
        default:
            return []
        }
    }

    private mutating func attach() -> [PlaybackCommand] {
        attached = true
        return [.moveToTargetWindow(animated: true)]
    }

    private mutating func segmentEnded(_ segment: PackSegment) -> [PlaybackCommand] {
        switch (phase, segment) {
        case (.intro, .intro):
            if windowReady { return playFinal() }
            if layout.loop != nil {
                phase = .looping
                return [.play(.loop, looping: true)]
            }
            phase = .holding
            return [.holdLastFrame]
        case (.final, layout.finalSegment):
            // Reached the end without a handoff report (e.g. very short video): fade anyway.
            return fade(.completed, duration: fadeDuration)
        default:
            return []
        }
    }

    private mutating func showFinalOnWindow() -> [PlaybackCommand] {
        visible = true
        attached = true
        phase = .final
        return [.showOnTargetWindow, .play(layout.finalSegment, looping: false)]
    }

    private mutating func playFinal() -> [PlaybackCommand] {
        phase = .final
        var commands: [PlaybackCommand] = []
        if !attached {
            attached = true
            commands.append(.moveToTargetWindow(animated: true))
        }
        commands.append(.play(layout.finalSegment, looping: false))
        return commands
    }

    private mutating func fade(_ reason: PlaybackEndReason, duration: Double) -> [PlaybackCommand] {
        guard visible else { return close(reason) }
        fadeReason = reason
        phase = .fading
        return [.beginFade(duration: duration)]
    }

    private mutating func close(_ reason: PlaybackEndReason) -> [PlaybackCommand] {
        let wasVisible = visible
        phase = .closed(reason)
        return [.close(reason, wasVisible: wasVisible)]
    }
}

/// Whether an automatic launch should play at all.
public enum PlaybackPolicy {
    public static func shouldAutoPlay(paused: Bool, reduceMotion: Bool, playDespiteReduceMotion: Bool) -> Bool {
        !paused && (!reduceMotion || playDespiteReduceMotion)
    }

    /// While the overlay is this young, other apps flickering active (Spotlight, Raycast, Finder
    /// handing over to the launching app) are part of the launch, not the user leaving.
    public static let activationGrace: TimeInterval = 1.5

    /// Whether another app becoming active should end the playback as "user switched away".
    public static func endsOnActivation(isLauncher: Bool, isTarget: Bool, overlayAge: TimeInterval) -> Bool {
        !isLauncher && !isTarget && overlayAge >= activationGrace
    }
}

/// Launches that should not get an animation at all.
public enum LaunchFilter {
    public enum Skip: String, Equatable, Sendable {
        /// The target started hidden (e.g. a login item set to hide).
        case hidden
        /// The target came up as part of logging in, not because the user just opened it.
        case atLogin = "at-login"
    }

    /// How long after a login-session start the launcher ignores target launches.
    public static let loginGrace: TimeInterval = 45
    /// A launcher started this soon after boot is treated as started at login.
    public static let bootWindow: TimeInterval = 180

    /// - Parameters:
    ///   - launcherAge: seconds since the launcher itself started.
    ///   - launcherStartedAtLogin: the launcher was opened as a login item.
    ///   - systemUptime: seconds since boot, now.
    public static func skip(targetHidden: Bool, launcherAge: TimeInterval, launcherStartedAtLogin: Bool,
                            systemUptime: TimeInterval) -> Skip? {
        if targetHidden { return .hidden }
        let uptimeAtLauncherStart = systemUptime - launcherAge
        let loginSession = launcherStartedAtLogin || uptimeAtLauncherStart < bootWindow
        return loginSession && launcherAge < loginGrace ? .atLogin : nil
    }
}
