import Foundation

/// Lossless JSON values keep platform identities this build does not understand.
public enum PlatformValue: Codable, Equatable, Sendable {
    case object([String: PlatformValue]), array([PlatformValue]), string(String), number(Decimal), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Decimal.self) { self = .number(v) }
        else if let v = try? c.decode([String: Self].self) { self = .object(v) }
        else { self = .array(try c.decode([Self].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var string: String? { if case .string(let v) = self { return v }; return nil }
}

public struct ApplicationTarget: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var animation: String?
    /// Also play when an already-running app brings its window back (COMPATIBILITY.md §2); omitted when false.
    public var playOnReappear = false
    public var platforms: [String: PlatformValue]
    public var bundleID: String? {
        guard case .object(let mac) = platforms["mac"] else { return nil }
        return mac["bundleId"]?.string
    }
    public init(id: String = UUID().uuidString.lowercased(), name: String, enabled: Bool = true,
                animation: String? = nil, bundleID: String) {
        self.id = id; self.name = name; self.enabled = enabled; self.animation = animation
        platforms = ["mac": .object(["bundleId": .string(bundleID)])]
    }
    public static func validID(_ id: String) -> Bool {
        id.range(of: "^[a-z0-9-]{1,64}$", options: .regularExpression) != nil
    }
    public static var defaultTarget: Self {
        Self(id: "default-codex", name: "ChatGPT",
             bundleID: Bundle(url: URL(fileURLWithPath: "/Applications/ChatGPT.app"))?.bundleIdentifier ?? "com.openai.codex")
    }
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(intValue: Int) { return nil }
        init(stringValue: String) { self.stringValue = stringValue }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decode(String.self, forKey: Key(stringValue: "id"))
        name = try c.decode(String.self, forKey: Key(stringValue: "name"))
        enabled = try c.decode(Bool.self, forKey: Key(stringValue: "enabled"))
        let animationKey = Key(stringValue: "animation")
        guard c.contains(animationKey) else { throw ExperienceError.invalid("应用缺少动画设置") }
        animation = try c.decodeIfPresent(String.self, forKey: animationKey)
        playOnReappear = try c.decodeIfPresent(Bool.self, forKey: Key(stringValue: "playOnReappear")) ?? false
        platforms = [:]
        for key in c.allKeys where !["id", "name", "enabled", "animation", "playOnReappear"].contains(key.stringValue) {
            platforms[key.stringValue] = try c.decode(PlatformValue.self, forKey: key)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(id, forKey: Key(stringValue: "id"))
        try c.encode(name, forKey: Key(stringValue: "name"))
        try c.encode(enabled, forKey: Key(stringValue: "enabled"))
        try c.encode(animation, forKey: Key(stringValue: "animation"))
        if playOnReappear { try c.encode(true, forKey: Key(stringValue: "playOnReappear")) }
        for (key, value) in platforms { try c.encode(value, forKey: Key(stringValue: key)) }
    }
    public func validated() throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validID(id), !clean.isEmpty, clean.count <= 40,
              name.rangeOfCharacter(from: .controlCharacters) == nil,
              animation.map(PlaybackState.validPackID) ?? true else { throw ExperienceError.invalid("应用名称或标识无效") }
        if let mac = platforms["mac"] {
            guard case .object(let fields) = mac, fields.count == 1, let bundleID,
                  !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, bundleID.count <= 255 else {
                throw ExperienceError.invalid("应用 bundleId 无效")
            }
        }
        _ = try windowsIdentity()
    }
    /// Validate the shared Windows identity while retaining its original JSON block.
    func windowsIdentity() throws -> String? {
        guard let windows = platforms["windows"] else { return nil }
        guard case .object(let fields) = windows else { throw ExperienceError.invalid("Windows 应用身份无效") }
        if let path = fields["path"] {
            guard fields.count == 1, let p = path.string,
                  p.range(of: "^(?:[A-Za-z]:\\\\|\\\\\\\\[^\\\\]+\\\\[^\\\\]+\\\\).+\\.exe$", options: [.regularExpression, .caseInsensitive]) != nil else {
                throw ExperienceError.invalid("Windows 应用路径无效")
            }
            return "path:" + p.lowercased()
        }
        guard let package = fields["package"]?.string, !package.isEmpty,
              package.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil,
              Set(fields.keys).isSubset(of: ["package", "exe"]) else { throw ExperienceError.invalid("Windows 应用包无效") }
        var exe = ""
        if let value = fields["exe"] {
            guard let p = value.string, !p.isEmpty, !p.hasPrefix("\\"), !p.contains(":"),
                  !p.contains("/"), !p.split(separator: "\\").contains("..") else { throw ExperienceError.invalid("包内路径无效") }
            exe = p
        }
        return "package:" + package.lowercased() + "|" + exe.lowercased()
    }
    public static func validate(_ targets: [Self]) throws {
        guard targets.count <= 20 else { throw ExperienceError.invalid("最多添加 20 个应用") }
        var ids = Set<String>(), mac = Set<String>(), windows = Set<String>()
        for target in targets {
            try target.validated()
            guard ids.insert(target.id).inserted else { throw ExperienceError.invalid("应用标识重复") }
            if let identity = target.bundleID, !mac.insert(identity).inserted { throw ExperienceError.invalid("应用已添加") }
            if let identity = try target.windowsIdentity(), !windows.insert(identity).inserted { throw ExperienceError.invalid("Windows 应用已添加") }
        }
    }
}

public struct TargetPackChoice: Equatable, Sendable {
    public let id: String?
    public let missing: Bool
    public static func choose(animation: String?, rotation: PackRotation, favorites: [String], available: [String],
                              active: String?, lastPackId: String?, random: Double) -> Self {
        if let animation, available.contains(animation) { return Self(id: animation, missing: false) }
        return Self(id: PackRotation.choose(rotation: rotation, favorites: favorites, available: available,
                                           active: active, lastPackId: lastPackId, random: random), missing: animation != nil)
    }
}
