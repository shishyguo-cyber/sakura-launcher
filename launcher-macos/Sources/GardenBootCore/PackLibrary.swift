import Foundation

/// What the app layer learns about a video file (AVFoundation lives outside the core).
public struct MediaInfo: Equatable, Sendable {
    public let duration: Double
    public let hasVideo: Bool
    public init(duration: Double, hasVideo: Bool) {
        self.duration = duration
        self.hasVideo = hasVideo
    }
}

/// Image decoding is injected by the App layer; omitted probes reject packs with covers.
public typealias ImageProbe = @Sendable (URL) async throws -> Bool

/// Decodes enough of a file to say whether it can play. Injected so the core stays testable.
public typealias MediaProbe = @Sendable (URL) async throws -> MediaInfo

public struct InstalledPack: Equatable, Sendable {
    public let manifest: PackManifest
    public let layout: PackLayout
    public let directory: URL

    public var id: String { manifest.id }
    public func url(for file: String) -> URL { directory.appendingPathComponent(file) }
    public var noticeURL: URL { url(for: manifest.noticeFile) }
}

/// Launch packs installed under one root, normally
/// `~/Library/Application Support/GardenBoot/Packs/`, one folder per pack id.
public struct PackLibrary: Sendable {
    public static let legacyPackID = "imported-startup"

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Reads and structurally validates a pack folder. Does not decode video.
    public static func load(directory: URL) throws -> InstalledPack {
        let manifestURL = directory.appendingPathComponent(PackManifest.fileName)
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw PackError.missingFile(PackManifest.fileName)
        }
        let manifest: PackManifest
        do {
            manifest = try JSONDecoder().decode(PackManifest.self, from: data)
        } catch let error as PackError {
            throw error
        } catch {
            throw PackError.invalidManifest("JSON 无法解析")
        }
        let layout = try manifest.validatedLayout()
        for file in Array(manifest.segments.values) + [manifest.noticeFile] {
            guard isNonEmptyRegularFile(directory.appendingPathComponent(file)) else {
                throw PackError.missingFile(file)
            }
        }
        if let cover = manifest.cover {
            let url = directory.appendingPathComponent(cover)
            guard isNonEmptyRegularFile(url) else { throw PackError.invalidCover("\(cover) 不存在或为空") }
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
            guard let size, size.intValue <= 8 * 1024 * 1024 else { throw PackError.invalidCover("\(cover) 超过 8 MB") }
        }
        return InstalledPack(manifest: manifest, layout: layout, directory: directory)
    }

    /// Valid installed packs sorted by name, plus folder name → reason for anything skipped.
    public func installed() -> (packs: [InstalledPack], problems: [String: String]) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: []) else { return ([], [:]) }
        var packs: [InstalledPack] = []
        var problems: [String: String] = [:]
        // Import staging folders start with a dot. A renamed staging directory may retain
        // Finder's hidden flag; that flag must not make an installed pack disappear on restart.
        for entry in entries where !entry.lastPathComponent.hasPrefix(".")
            && (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            do {
                let pack = try Self.load(directory: entry)
                if pack.id == entry.lastPathComponent { packs.append(pack) }
                else { problems[entry.lastPathComponent] = "文件夹名与 id 不一致" }
            } catch {
                problems[entry.lastPathComponent] = error.localizedDescription
            }
        }
        packs.sort { ($0.manifest.name, $0.id) < ($1.manifest.name, $1.id) }
        return (packs, problems)
    }

    /// Validates `source` completely (structure and every video), then atomically installs a clean copy
    /// at `root/<id>`. Only the manifest, referenced videos, cover and the notice are copied.
    /// On any failure the previously installed pack with the same id is left untouched.
    @discardableResult
    public func importPack(from source: URL, probe: MediaProbe, imageProbe: ImageProbe = { _ in false }) async throws -> InstalledPack {
        let pack = try Self.load(directory: source)
        // Deterministic order (intro, loop, outro, video) so errors name the first bad segment.
        for file in PackSegment.allCases.compactMap({ pack.manifest.segments[$0] }) {
            let info: MediaInfo
            do { info = try await probe(source.appendingPathComponent(file)) }
            catch { throw PackError.invalidMedia(file) }
            guard info.hasVideo, info.duration.isFinite, info.duration > 0 else {
                throw PackError.invalidMedia(file)
            }
        }
        if let cover = pack.manifest.cover {
            guard (try? await imageProbe(source.appendingPathComponent(cover))) == true else {
                throw PackError.invalidCover("\(cover) 无法解码为图片")
            }
        }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        let files = Set([PackManifest.fileName, pack.manifest.noticeFile] + Array(pack.manifest.segments.values) + [pack.manifest.cover].compactMap { $0 })
        for file in files {
            try fm.copyItem(at: source.appendingPathComponent(file), to: staging.appendingPathComponent(file))
        }
        _ = try Self.load(directory: staging)
        let destination = root.appendingPathComponent(pack.id, isDirectory: true)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
        return try Self.load(directory: destination)
    }

    /// Installs a pack shipped inside the app bundle unless a pack with that id already exists.
    /// Returns the newly installed pack, or nil when nothing was done.
    @discardableResult
    public func installIfMissing(bundled source: URL, probe: MediaProbe, imageProbe: ImageProbe = { _ in false }) async throws -> InstalledPack? {
        let pack = try Self.load(directory: source)
        let destination = root.appendingPathComponent(pack.id, isDirectory: true)
        if (try? Self.load(directory: destination)) != nil { return nil }
        return try await importPack(from: source, probe: probe, imageProbe: imageProbe)
    }

    /// Wraps a v1 `startup.mp4` into a single-video pack. The original file is kept.
    /// Returns nil when there is no legacy video or the legacy pack already exists.
    @discardableResult
    public func migrateLegacyVideo(_ video: URL, probe: MediaProbe) async throws -> InstalledPack? {
        guard Self.isNonEmptyRegularFile(video) else { return nil }
        if (try? Self.load(directory: root.appendingPathComponent(Self.legacyPackID))) != nil { return nil }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        let ext = video.pathExtension.isEmpty ? "mp4" : video.pathExtension.lowercased()
        let file = "video.\(ext)"
        try fm.copyItem(at: video, to: staging.appendingPathComponent(file))
        let notice = "# 说明\n\n此视频由用户在旧版启动器中自行导入，权利归原提供者。仅供本机使用。\n"
        try Data(notice.utf8).write(to: staging.appendingPathComponent(PackDefaults.noticeFile))
        let manifest = PackManifest(id: Self.legacyPackID, name: "已导入的视频", segments: [.video: file])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: staging.appendingPathComponent(PackManifest.fileName))
        return try await importPack(from: staging, probe: probe)
    }

    /// The pack a brand-new install starts on. Returns nil (leave things alone) once the user has a choice,
    /// or when this install already went through the featured-pack offer (an upgrade from an earlier version).
    public static func newInstallChoice(preferredID: String?, alreadyOfferedFeatured: Bool, defaultID: String) -> String? {
        preferredID == nil && !alreadyOfferedFeatured ? defaultID : nil
    }

    /// Called only after the featured pack's first successful installation. Existing choices are preserved;
    /// the app's offered-once marker prevents a removed pack from reaching this step again.
    public static func preferredAfterFirstFeaturedInstall(preferredID: String?, featuredID: String) -> String {
        preferredID ?? featuredID
    }

    /// The pack to play: the user's choice if still installed, else `fallbackID`, else the first by name.
    public static func resolveActive(preferredID: String?, packs: [InstalledPack], fallbackID: String) -> InstalledPack? {
        if let preferredID, let pack = packs.first(where: { $0.id == preferredID }) { return pack }
        if let pack = packs.first(where: { $0.id == fallbackID }) { return pack }
        return packs.first
    }

    static func isNonEmptyRegularFile(_ url: URL) -> Bool {
        // Fresh attributes: URL resource values can cache an old size.
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return values[.type] as? FileAttributeType == .typeRegular && ((values[.size] as? NSNumber)?.intValue ?? 0) > 0
    }
}
