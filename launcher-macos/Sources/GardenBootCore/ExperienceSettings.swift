import Foundation

public enum ExperienceError: LocalizedError {
    case invalid(String)
    case unsupportedVersion
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .unsupportedVersion: return "设置来自较新的软件版本，请升级软件后再编辑。原设置已保留。"
        }
    }
}

public struct PlaybackOverrides: Codable, Equatable, Sendable {
    public var fadeDuration: Double?
    public var handoffAt: Double?
    public var maxWaitSeconds: Double?
    public var loopExit: LoopExit?
    public var launchCoverage: Double?
    public var videoFit: VideoFit.Mode?
    public init(fadeDuration: Double? = nil, handoffAt: Double? = nil, maxWaitSeconds: Double? = nil,
                loopExit: LoopExit? = nil, launchCoverage: Double? = nil, videoFit: VideoFit.Mode? = nil) {
        self.fadeDuration = fadeDuration; self.handoffAt = handoffAt; self.maxWaitSeconds = maxWaitSeconds
        self.loopExit = loopExit; self.launchCoverage = launchCoverage
        self.videoFit = videoFit
    }
    public func validated() throws {
        for (value, range, name) in [(fadeDuration, 0.1...2, "淡出时长"), (maxWaitSeconds, 1.0...60, "最长等待"),
                                     (launchCoverage, 0.4...0.9, "开场尺寸")] {
            if let value, !value.isFinite || !range.contains(value) { throw ExperienceError.invalid("\(name)超出允许范围") }
        }
        if let handoffAt, !handoffAt.isFinite || handoffAt < 0 { throw ExperienceError.invalid("淡出起点需为非负秒数") }
    }
}

public struct ExperiencePreset: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var overrides: PlaybackOverrides
    public init(name: String, overrides: PlaybackOverrides) {
        id = UUID().uuidString; self.name = name; self.overrides = overrides
    }
}

public struct PackPreferences: Codable, Equatable, Sendable {
    public var overrides: PlaybackOverrides
    public var presets: [ExperiencePreset]
    public init(overrides: PlaybackOverrides = .init(), presets: [ExperiencePreset] = []) {
        self.overrides = overrides; self.presets = presets
    }
}

public struct ExperienceSettings: Codable, Equatable, Sendable {
    public var schemaVersion = 3
    public var masterVolume = 1.0
    public var muted = false
    public var packs: [String: PackPreferences] = [:]
    public var playback = PlaybackPreferences()
    public var library = LibraryPreferences()
    public var targets: [ApplicationTarget] = [.defaultTarget]
    public init() {}

    private enum CodingKeys: String, CodingKey { case schemaVersion, masterVolume, muted, packs, playback, library, targets }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard (1...3).contains(version) else { throw ExperienceError.unsupportedVersion }
        schemaVersion = 3
        masterVolume = try c.decode(Double.self, forKey: .masterVolume)
        muted = try c.decode(Bool.self, forKey: .muted)
        packs = try c.decode([String: PackPreferences].self, forKey: .packs)
        if version >= 2 {
            playback = try c.decode(PlaybackPreferences.self, forKey: .playback)
            library = try c.decode(LibraryPreferences.self, forKey: .library)
        }
        if version == 3 { targets = try c.decode([ApplicationTarget].self, forKey: .targets) }
    }

    public func validated() throws {
        guard schemaVersion == 3 else { throw ExperienceError.unsupportedVersion }
        guard masterVolume.isFinite, (0...1).contains(masterVolume) else { throw ExperienceError.invalid("总音量需在 0–100% 之间") }
        try playback.validated()
        try library.validated()
        try ApplicationTarget.validate(targets)
        for (id, preferences) in packs {
            guard id.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil else {
                throw ExperienceError.invalid("设置中的动画包标识无效")
            }
            try preferences.overrides.validated()
            var names = Set<String>(), ids = Set<String>()
            for preset in preferences.presets {
                let name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.count <= 40, name == preset.name,
                      name.rangeOfCharacter(from: .controlCharacters) == nil,
                      !preset.id.isEmpty, preset.id.count <= 64,
                      names.insert(name).inserted, ids.insert(preset.id).inserted else {
                    throw ExperienceError.invalid("方案名称需为不重复的 1–40 个字符")
                }
                try preset.overrides.validated()
            }
        }
    }

    public func resolved(_ manifest: PackManifest) throws -> PackManifest {
        try validated()
        let values = packs[manifest.id]?.overrides ?? .init()
        var result = manifest
        result.volume = muted ? 0 : manifest.effectiveVolume * masterVolume
        if let v = values.fadeDuration { result.fadeDuration = v }
        if let v = values.handoffAt { result.handoffAt = v }
        if let v = values.maxWaitSeconds { result.maxWaitSeconds = v }
        if let v = values.loopExit { result.loopExit = v }
        if let v = values.videoFit { result.videoFit = v }
        _ = try result.validatedLayout()
        return result
    }

    public func coverage(for packID: String) -> Double { packs[packID]?.overrides.launchCoverage ?? 0.72 }
    public mutating func resetPack(_ id: String) { packs[id, default: .init()].overrides = .init() }
    public mutating func addPreset(packID: String, name: String) throws {
        var next = self
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var pack = next.packs[packID] ?? .init()
        pack.presets.append(ExperiencePreset(name: clean, overrides: pack.overrides))
        next.packs[packID] = pack
        try next.validated()
        self = next
    }

    public static func decode(_ data: Data) throws -> Self {
        do {
            if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = root["schemaVersion"] as? Int, !(1...3).contains(version) { throw ExperienceError.unsupportedVersion }
            let result = try JSONDecoder().decode(Self.self, from: data)
            try result.validated()
            return result
        } catch let error as ExperienceError { throw error }
        catch { throw ExperienceError.invalid("无法读取个人设置。原文件已保留；保存新设置时会另存恢复副本。") }
    }
}

extension InstalledPack {
    public func applying(_ settings: ExperienceSettings) throws -> InstalledPack {
        let snapshot = try settings.resolved(manifest)
        return InstalledPack(manifest: snapshot, layout: try snapshot.validatedLayout(), directory: directory)
    }
}
