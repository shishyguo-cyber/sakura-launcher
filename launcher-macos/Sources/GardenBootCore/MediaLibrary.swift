import Foundation

public enum MediaLibrary {
    public static func importFile(_ source: URL, to destination: URL) throws -> URL {
        let fm = FileManager.default
        // Read fresh filesystem attributes: URL resourceValues can cache an old file size.
        let values = try fm.attributesOfItem(atPath: source.path)
        guard values[.type] as? FileAttributeType == .typeRegular,
              (values[.size] as? NSNumber)?.intValue ?? 0 > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let directory = destination.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".import-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        try fm.copyItem(at: source, to: temporary)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: destination)
        }
        return destination
    }
}
