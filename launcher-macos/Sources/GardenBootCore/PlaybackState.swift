import Foundation

public struct TargetPlaybackState: Codable, Equatable, Sendable {
    public var lastAutoPlayAt: Double?
    public var lastPackId: String?
    /// Last "测试一下" result (COMPATIBILITY.md §1); an unreadable entry is dropped, not a reason to reset.
    public var compat: CompatResult?
    public init(lastAutoPlayAt: Double? = nil, lastPackId: String? = nil, compat: CompatResult? = nil) {
        self.lastAutoPlayAt = lastAutoPlayAt; self.lastPackId = lastPackId; self.compat = compat
    }
    private enum CodingKeys: String, CodingKey { case lastAutoPlayAt, lastPackId, compat }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastAutoPlayAt = try c.decodeIfPresent(Double.self, forKey: .lastAutoPlayAt)
        lastPackId = try c.decodeIfPresent(String.self, forKey: .lastPackId)
        compat = (try? c.decodeIfPresent(CompatResult.self, forKey: .compat)).flatMap { $0 }
        if let at = compat?.at, !at.isFinite || at < 0 { compat = nil }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(lastAutoPlayAt, forKey: .lastAutoPlayAt)
        try c.encodeIfPresent(lastPackId, forKey: .lastPackId)
        try c.encodeIfPresent(compat, forKey: .compat)
    }
}

public struct PlaybackState: Codable, Equatable, Sendable {
    public var schemaVersion = 2
    public var snoozeUntil: Double?
    public var targets: [String: TargetPlaybackState] = [:]
    // Compatibility accessors for the legacy default target; never encoded at top level.
    public var lastAutoPlayAt: Double? {
        get { targets["default-codex"]?.lastAutoPlayAt }
        set { targets["default-codex", default: .init()].lastAutoPlayAt = newValue }
    }
    public var lastPackId: String? {
        get { targets["default-codex"]?.lastPackId }
        set { targets["default-codex", default: .init()].lastPackId = newValue }
    }
    public init(lastAutoPlayAt: Double? = nil, lastPackId: String? = nil, snoozeUntil: Double? = nil) {
        self.snoozeUntil = snoozeUntil
        if lastAutoPlayAt != nil || lastPackId != nil {
            targets["default-codex"] = .init(lastAutoPlayAt: lastAutoPlayAt, lastPackId: lastPackId)
        }
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, snoozeUntil, targets, lastAutoPlayAt, lastPackId }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 || version == 2 else { throw ExperienceError.invalid("播放状态版本无效") }
        snoozeUntil = try c.decodeIfPresent(Double.self, forKey: .snoozeUntil)
        if version == 1 {
            let last = try c.decodeIfPresent(Double.self, forKey: .lastAutoPlayAt)
            let pack = try c.decodeIfPresent(String.self, forKey: .lastPackId)
            if last != nil || pack != nil { targets["default-codex"] = .init(lastAutoPlayAt: last, lastPackId: pack) }
        } else { targets = try c.decode([String: TargetPlaybackState].self, forKey: .targets) }
        try validated()
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encodeIfPresent(snoozeUntil, forKey: .snoozeUntil)
        try c.encode(targets, forKey: .targets)
    }
    static func validPackID(_ id: String) -> Bool {
        id.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil
    }
    public func validated() throws {
        let times = [snoozeUntil] + targets.values.map(\.lastAutoPlayAt)
        guard schemaVersion == 2,
              times.allSatisfy({ $0 == nil || ($0!.isFinite && $0! >= 0) }),
              targets.allSatisfy({ ApplicationTarget.validID($0.key) && ($0.value.lastPackId.map(Self.validPackID) ?? true) }) else {
            throw ExperienceError.invalid("播放状态无效")
        }
    }
}

/// Regenerable state; invalid input is reset in memory, never backed up.
public struct PlaybackStateStore: Sendable {
    public let directory: URL
    public var file: URL { directory.appendingPathComponent("playback-state.json") }
    public init(directory: URL) { self.directory = directory }
    public func load(onReset: () -> Void = {}) -> PlaybackState {
        do {
            let state = try JSONDecoder().decode(PlaybackState.self, from: Data(contentsOf: file))
            try state.validated()
            return state
        } catch { onReset(); return .init() }
    }
    public func save(_ state: PlaybackState) throws {
        try state.validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
}
