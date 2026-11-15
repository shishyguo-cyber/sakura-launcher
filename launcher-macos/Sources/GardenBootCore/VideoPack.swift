import Foundation

/// "从视频创建动画" (launcher-spec/PACK-FROM-VIDEO.md): turn one local video into a single-video pack.
public enum VideoPackRules {
    public static let fallbackName = "我的动画"
    public static let maximumNameLength = 40

    private static func lastDot(_ fileName: String) -> String.Index? { fileName.lastIndex(of: ".") }

    public static func defaultName(fileName: String) -> String {
        let stem = lastDot(fileName).map { String(fileName[..<$0]) } ?? fileName
        let spaced = stem.replacingOccurrences(of: "[_\\-\\s]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = String(spaced.prefix(maximumNameLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        return clipped.isEmpty ? fallbackName : clipped
    }

    public static func fileExtension(fileName: String) -> String? {
        guard let dot = lastDot(fileName) else { return nil }
        let ext = fileName[fileName.index(after: dot)...].lowercased()
        return PackDefaults.videoExtensions.contains(ext) ? ext : nil
    }

    public static func validName(_ name: String) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !clean.isEmpty && clean.count <= maximumNameLength && clean.rangeOfCharacter(from: .controlCharacters) == nil
    }

    public static func makeID(random: UInt32) -> String { String(format: "video-%08x", random) }

    public static func notice(name: String, sourceFileName: String, date: String) -> String {
        """
        # \(name)

        由 Sakura 从本地视频「\(sourceFileName)」创建（\(date)）。
        创建者确认这个视频是自己制作的，或有权使用它。
        这个动画包只供个人使用；分享或发布前请自行确认素材权利。

        """
    }

    /// Writes the pack folder (manifest, NOTICE.md, a copy of the video) inside `parent`; the caller imports it
    /// through the normal pack checks and removes `parent` afterwards.
    public static func build(video: URL, name: String, existingIDs: Set<String>, in parent: URL,
                             now: Date = Date(), random: () -> UInt32 = { UInt32.random(in: .min ... .max) }) throws -> URL {
        let sourceName = video.lastPathComponent
        guard let ext = fileExtension(fileName: sourceName) else { throw PackError.invalidManifest("请选择 mp4、m4v 或 mov 视频") }
        guard validName(name) else { throw PackError.invalidManifest("名称需为 1–40 个字符") }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var id = makeID(random: random())
        while existingIDs.contains(id) { id = makeID(random: random()) }
        let folder = parent.appendingPathComponent(id, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = "video.\(ext)"
        try fm.copyItem(at: video, to: folder.appendingPathComponent(file)) // APFS clones instead of copying bytes
        let manifest = PackManifest(id: id, name: clean, segments: [.video: file])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: folder.appendingPathComponent(PackManifest.fileName))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        try Data(notice(name: clean, sourceFileName: sourceName, date: formatter.string(from: now)).utf8)
            .write(to: folder.appendingPathComponent(PackDefaults.noticeFile))
        return folder
    }
}
