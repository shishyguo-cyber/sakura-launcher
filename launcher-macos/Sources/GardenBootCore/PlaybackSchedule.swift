import Foundation

public enum PlaybackFrequency: String, Codable, Sendable { case everyLaunch, firstOfDay }

public struct PlaybackPreferences: Codable, Equatable, Sendable {
    public var frequency: PlaybackFrequency = .everyLaunch
    public var dayStartHour = 4
    /// Skip while another app is full screen (COMPATIBILITY.md §3); optional in the file, default on.
    public var quietWhenFullscreen = true
    public init() {}
    private enum CodingKeys: String, CodingKey { case frequency, dayStartHour, quietWhenFullscreen }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frequency = try c.decode(PlaybackFrequency.self, forKey: .frequency)
        dayStartHour = try c.decode(Int.self, forKey: .dayStartHour)
        quietWhenFullscreen = try c.decodeIfPresent(Bool.self, forKey: .quietWhenFullscreen) ?? true
    }
    public func validated() throws {
        guard (0...23).contains(dayStartHour) else { throw ExperienceError.invalid("新的一天起点需为 0–23 点") }
    }
}

public enum PackRotation: String, Codable, Sendable {
    case fixed, shuffleAll, shuffleFavorites

    /// `available` is the playable set, ordered by ordinal pack id.
    public static func choose(rotation: Self, favorites: [String], available: [String], active: String?,
                              lastPackId: String?, random: Double) -> String? {
        guard rotation != .fixed else { return active }
        let favoriteSet = Set(favorites)
        var candidates = rotation == .shuffleAll ? available : available.filter { favoriteSet.contains($0) }
        guard !candidates.isEmpty else { return active }
        if candidates.count > 1 { candidates.removeAll { $0 == lastPackId } }
        let bounded = random.isNaN ? 0 : min(1, max(0, random))
        return candidates[min(Int(floor(bounded * Double(candidates.count))), candidates.count - 1)]
    }
}

public struct LibraryPreferences: Codable, Equatable, Sendable {
    public var rotation: PackRotation = .fixed
    public var favorites: [String] = []
    public init() {}
    public func validated() throws {
        guard favorites.count <= 200, Set(favorites).count == favorites.count,
              favorites.allSatisfy({ PlaybackState.validPackID($0) }) else {
            throw ExperienceError.invalid("收藏需为不重复的动画包标识，最多 200 个")
        }
    }
}

public enum ScheduleDecision: String, Sendable {
    case play, snoozed, playedToday
    public static func dayKey(_ time: Double, offset: Int, dayStartHour: Int) -> Double {
        floor((time + Double(offset) - Double(dayStartHour) * 3600) / 86400)
    }
    public static func decide(frequency: PlaybackFrequency, dayStartHour: Int, state: PlaybackState, targetID: String = "default-codex",
                              now: Double, nowOffset: Int, lastOffset: Int) -> Self {
        if let until = state.snoozeUntil, now < until { return .snoozed }
        guard frequency == .firstOfDay, let last = state.targets[targetID]?.lastAutoPlayAt, last <= now + 300 else { return .play }
        return dayKey(now, offset: nowOffset, dayStartHour: dayStartHour)
            == dayKey(last, offset: lastOffset, dayStartHour: dayStartHour) ? .playedToday : .play
    }
    public static func nextDayStart(now: Double, nowOffset: Int, dayStartHour: Int) -> Double {
        (dayKey(now, offset: nowOffset, dayStartHour: dayStartHour) + 1) * 86400
            + Double(dayStartHour) * 3600 - Double(nowOffset)
    }
}
