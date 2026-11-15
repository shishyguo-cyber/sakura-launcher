import Foundation

/// Append-only diagnostic log: one timestamped line per event, rotated to `events.previous.log`
/// once it grows past `limit` bytes so it never grows without bound. Records event names, PIDs and
/// reasons only — never chat content or video frames.
public final class EventLog: @unchecked Sendable {
    public static let fileName = "events.log"
    public static let previousFileName = "events.previous.log"

    public let directory: URL
    public let limit: Int
    private let lock = NSLock()
    private let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(directory: URL, limit: Int = 512 * 1024) {
        self.directory = directory
        self.limit = limit
    }

    public var url: URL { directory.appendingPathComponent(Self.fileName) }
    public var previousURL: URL { directory.appendingPathComponent(Self.previousFileName) }

    public func write(_ event: String, at date: Date = Date()) {
        let line = Data((stamp.string(from: date) + " " + event + "\n").utf8)
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber, size.intValue + line.count > limit {
            try? fm.removeItem(at: previousURL)
            try? fm.moveItem(at: url, to: previousURL)
        }
        guard let stream = OutputStream(url: url, append: true) else { return }
        stream.open()
        defer { stream.close() }
        line.withUnsafeBytes { buffer in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = stream.write(base + offset, maxLength: buffer.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }
}
