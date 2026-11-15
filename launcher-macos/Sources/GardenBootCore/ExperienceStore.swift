import Foundation

/// Personal settings are independent of packs and existing application switches.
public struct ExperienceStore: Sendable {
    public let directory: URL
    public var file: URL { directory.appendingPathComponent("experience.json") }
    public init(directory: URL) { self.directory = directory }
    public func load() throws -> ExperienceSettings {
        guard FileManager.default.fileExists(atPath: file.path) else { return .init() }
        return try ExperienceSettings.decode(Data(contentsOf: file))
    }
    public func save(_ settings: ExperienceSettings) throws {
        try settings.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: file.path) {
            let previous = try Data(contentsOf: file)
            do { _ = try ExperienceSettings.decode(previous) }
            catch ExperienceError.unsupportedVersion { throw ExperienceError.unsupportedVersion }
            catch {
                let recovery = directory.appendingPathComponent("experience.recovery-\(UUID().uuidString).json")
                try previous.write(to: recovery, options: .withoutOverwriting)
            }
        }
        try data.write(to: file, options: .atomic)
    }
}
