import Foundation

/// Result of "测试一下" for one target app (launcher-spec/COMPATIBILITY.md §1).
public enum CompatVerdict: String, Codable, Equatable, Sendable {
    case good, slowWindow, noWindow, alreadyRunning, notOpened
}

public enum CompatibilityRules {
    public static let testSeconds = 30.0

    public static func verdict(runningAtStart: Bool, coldStart: Bool, windowSeconds: Double?, maxWait: Double) -> CompatVerdict {
        if coldStart {
            guard let windowSeconds else { return .noWindow }
            return windowSeconds <= maxWait ? .good : .slowWindow
        }
        return runningAtStart ? .alreadyRunning : .notOpened
    }

    /// The line shown under the app's name.
    public static func message(_ verdict: CompatVerdict, windowSeconds: Double?) -> String {
        let seconds = String(format: "%.1f", windowSeconds ?? 0)
        switch verdict {
        case .good: return "适配良好：打开后约 \(seconds) 秒出现窗口"
        case .slowWindow: return "窗口出现较慢（约 \(seconds) 秒），可调大“最长等待”"
        case .noWindow: return "检测到启动，但没找到主窗口（可能只在菜单栏运行）"
        case .alreadyRunning: return "它一直在后台运行，打开时不会产生新进程"
        case .notOpened: return "没有检测到它被打开"
        }
    }
}

public struct CompatResult: Codable, Equatable, Sendable {
    public var verdict: CompatVerdict
    public var windowSeconds: Double?
    public var at: Double
    public init(verdict: CompatVerdict, windowSeconds: Double?, at: Double) {
        self.verdict = verdict; self.windowSeconds = windowSeconds; self.at = at
    }
    private enum CodingKeys: String, CodingKey { case verdict, windowSeconds, at }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(verdict, forKey: .verdict)
        try c.encode(windowSeconds, forKey: .windowSeconds) // explicit null, as Windows writes it
        try c.encode(at, forKey: .at)
    }
}

/// Detects an already-running app bringing a window back after having none (closed to the menu bar / last window
/// closed), for targets with `playOnReappear` (COMPATIBILITY.md §2). Minimize/restore and hide/unhide do not count.
public struct ReappearTracker: Sendable {
    public static let collapseSeconds = 2.0
    private var since: Double?
    private var collapsed = false
    public init() {}

    /// Returns true once when the window reappears.
    public mutating func feed(t: Double, running: Bool, hidden: Bool, hasWindow: Bool, hasVisibleMain: Bool) -> Bool {
        guard running else { since = nil; collapsed = false; return false }
        if !hidden && !hasWindow {
            let start = since ?? t
            since = start
            if t - start >= Self.collapseSeconds { collapsed = true }
            return false
        }
        since = nil
        if collapsed && hasVisibleMain { collapsed = false; return true }
        return false
    }
}

public enum QuietState: String, Sendable {
    case normal, fullscreen, game, presentation
}

public enum QuietRules {
    /// Whether to skip because the user is in a full-screen app, game or presentation (COMPATIBILITY.md §3).
    public static func skip(enabled: Bool, state: QuietState) -> (skip: Bool, detail: String?) {
        guard enabled, state != .normal else { return (false, nil) }
        return (true, state.rawValue)
    }
}
