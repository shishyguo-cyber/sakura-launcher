import Foundation

/// One video file inside a launch pack.
public enum PackSegment: String, Codable, CaseIterable, Sendable {
    case intro, loop, outro, video
}

/// When a waiting loop hands over to the outro after the target window is ready.
public enum LoopExit: String, Codable, Sendable {
    /// Finish the current loop cycle first (default; keeps the motion seamless).
    case cycleEnd
    /// Cut to the outro as soon as the window is ready.
    case immediate
}

/// `manifest.json` of a launch pack. Unknown keys are ignored for forward compatibility.
public struct PackManifest: Codable, Equatable, Sendable {
    public static let supportedSchema = 1
    public static let fileName = "manifest.json"

    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var segments: [PackSegment: String]
    /// Seconds into the final segment (outro, or the single video) where the fade-out starts.
    public var handoffAt: Double?
    public var fadeDuration: Double?
    public var volume: Double?
    /// Longest wait for the target window before the pack gives up and finishes.
    public var maxWaitSeconds: Double?
    public var loopExit: LoopExit?
    public var videoFit: VideoFit.Mode?
    /// Rights and licence statement shipped with the pack. Required.
    public var notice: String?
    public var cover: String?

    public init(schemaVersion: Int = PackManifest.supportedSchema, id: String, name: String,
                segments: [PackSegment: String], handoffAt: Double? = nil, fadeDuration: Double? = nil,
                volume: Double? = nil, maxWaitSeconds: Double? = nil, loopExit: LoopExit? = nil,
                notice: String? = nil, cover: String? = nil, videoFit: VideoFit.Mode? = nil) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.segments = segments
        self.handoffAt = handoffAt
        self.fadeDuration = fadeDuration
        self.volume = volume
        self.maxWaitSeconds = maxWaitSeconds
        self.loopExit = loopExit
        self.notice = notice
        self.cover = cover
        self.videoFit = videoFit
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, segments, handoffAt, fadeDuration, volume, maxWaitSeconds, loopExit, notice, cover, videoFit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        let raw = try c.decode([String: String].self, forKey: .segments)
        var parsed: [PackSegment: String] = [:]
        for (key, value) in raw {
            guard let segment = PackSegment(rawValue: key) else {
                throw PackError.invalidManifest("未知片段 \(key)")
            }
            parsed[segment] = value
        }
        segments = parsed
        handoffAt = try c.decodeIfPresent(Double.self, forKey: .handoffAt)
        fadeDuration = try c.decodeIfPresent(Double.self, forKey: .fadeDuration)
        volume = try c.decodeIfPresent(Double.self, forKey: .volume)
        maxWaitSeconds = try c.decodeIfPresent(Double.self, forKey: .maxWaitSeconds)
        loopExit = try c.decodeIfPresent(LoopExit.self, forKey: .loopExit)
        notice = try c.decodeIfPresent(String.self, forKey: .notice)
        cover = try c.decodeIfPresent(String.self, forKey: .cover)
        videoFit = try c.decodeIfPresent(VideoFit.Mode.self, forKey: .videoFit)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(Dictionary(uniqueKeysWithValues: segments.map { ($0.key.rawValue, $0.value) }), forKey: .segments)
        try c.encodeIfPresent(handoffAt, forKey: .handoffAt)
        try c.encodeIfPresent(fadeDuration, forKey: .fadeDuration)
        try c.encodeIfPresent(volume, forKey: .volume)
        try c.encodeIfPresent(maxWaitSeconds, forKey: .maxWaitSeconds)
        try c.encodeIfPresent(loopExit, forKey: .loopExit)
        try c.encodeIfPresent(notice, forKey: .notice)
        try c.encodeIfPresent(cover, forKey: .cover)
        try c.encodeIfPresent(videoFit, forKey: .videoFit)
    }
}

public enum PackError: Error, Equatable, LocalizedError {
    case invalidManifest(String)
    case missingFile(String)
    case invalidMedia(String)
    case invalidCover(String)

    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let why): return "动画包描述无效：\(why)。请修正 manifest.json 后重新导入。"
        case .missingFile(let name): return "这个动画包缺少 \(name)，请补齐文件后重新导入。"
        case .invalidCover(let reason): return "动画包封面无效：\(reason)。请更换封面后重新导入。"
        case .invalidMedia(let name): return "动画包视频无法播放：\(name)。请重新导出视频后导入。"
        }
    }
}

/// The resolved, validated playback layout of a pack.
public struct PackLayout: Equatable, Sendable {
    public let intro: String?
    public let loop: String?
    /// `outro` for a segmented pack, `video` for a single-video pack.
    public let final: String
    public let finalSegment: PackSegment

    /// True when the pack can play while the target is still launching.
    public var coversLaunch: Bool { intro != nil || loop != nil }
}

public enum PackDefaults {
    public static let fadeDuration = 0.4
    public static let skipFadeDuration = 0.3
    public static let volume = 1.0
    public static let maxWaitSeconds = 10.0
    public static let noticeFile = "NOTICE.md"
    public static let videoExtensions: Set<String> = ["mp4", "m4v", "mov"]
}

extension PackManifest {
    public var effectiveFadeDuration: Double { fadeDuration ?? PackDefaults.fadeDuration }
    public var effectiveVolume: Double { volume ?? PackDefaults.volume }
    public var effectiveMaxWait: Double { maxWaitSeconds ?? PackDefaults.maxWaitSeconds }
    public var effectiveLoopExit: LoopExit { loopExit ?? .cycleEnd }
    public var effectiveVideoFit: VideoFit.Mode { videoFit ?? .auto }
    public var noticeFile: String { notice ?? PackDefaults.noticeFile }

    /// Structural validation: everything that can be checked without decoding video.
    public func validatedLayout() throws -> PackLayout {
        guard schemaVersion == Self.supportedSchema else {
            throw PackError.invalidManifest("不支持的 schemaVersion \(schemaVersion)")
        }
        guard id.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil else {
            throw PackError.invalidManifest("id 只能用小写字母、数字和连字符，最长 64 个字符")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PackError.invalidManifest("name 不能为空")
        }
        for file in Array(segments.values) + [noticeFile] {
            try Self.checkFileName(file)
        }
        if let cover {
            try Self.checkFileName(cover)
            guard ["png", "jpg", "jpeg"].contains((cover as NSString).pathExtension.lowercased()) else {
                throw PackError.invalidManifest("cover 必须是 png、jpg 或 jpeg")
            }
        }
        for (segment, file) in segments {
            let ext = (file as NSString).pathExtension.lowercased()
            guard PackDefaults.videoExtensions.contains(ext) else {
                throw PackError.invalidManifest("\(segment.rawValue) 必须是 mp4、m4v 或 mov")
            }
        }
        if let v = volume, !(0...1).contains(v) { throw PackError.invalidManifest("volume 需在 0–1 之间") }
        if let f = fadeDuration, !(0.1...2).contains(f) { throw PackError.invalidManifest("fadeDuration 需在 0.1–2 秒之间") }
        if let w = maxWaitSeconds, !(1...60).contains(w) { throw PackError.invalidManifest("maxWaitSeconds 需在 1–60 秒之间") }
        if let h = handoffAt, !(h >= 0 && h.isFinite) { throw PackError.invalidManifest("handoffAt 不能为负数") }

        if let video = segments[.video] {
            guard segments.count == 1 else {
                throw PackError.invalidManifest("video 不能和 intro、loop、outro 同时使用")
            }
            return PackLayout(intro: nil, loop: nil, final: video, finalSegment: .video)
        }
        guard let outro = segments[.outro] else {
            throw PackError.invalidManifest("需要 outro，或只提供一个 video")
        }
        return PackLayout(intro: segments[.intro], loop: segments[.loop], final: outro, finalSegment: .outro)
    }

    /// Fade start inside the final segment, clamped so the fade always fits.
    public func handoffTime(finalDuration: Double) -> Double {
        let latest = max(0, finalDuration - effectiveFadeDuration)
        guard let handoffAt else { return latest }
        return min(max(0, handoffAt), latest)
    }

    static func checkFileName(_ name: String) throws {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != "..",
              !name.hasPrefix(".") else {
            throw PackError.invalidManifest("文件名必须是包内的普通文件：\(name)")
        }
    }
}
