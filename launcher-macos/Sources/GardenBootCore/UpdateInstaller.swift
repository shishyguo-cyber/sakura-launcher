import Foundation
import Darwin

/// Each request owns a private work directory. No preferences, library or playback paths are touched.
public enum UpdateInstaller {
    public struct RecoveryRequired: Error, LocalizedError {
        public var backup: String
        public var errorDescription: String? { "自动恢复未完成，旧版保留于：\(backup)。请手动恢复或去 GitHub 下载。" }
    }
    public struct Request: Codable {
        public var target: String
        public var staged: String
        public var work: String
        public var version: String
        public var parent: Int32
        public var arguments: [String]
    }
    public static func run(_ executable: String, _ args: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw SignedUpdate.Failure.structure }
    }
    public static func prepare(zip: URL, signature: URL, target: URL, version: String, current: String, work: URL, arguments: [String] = []) throws -> URL {
        let fm = FileManager.default
        let parent = target.deletingLastPathComponent()
        guard target.pathExtension == "app", try !target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLinkValue,
              fm.isWritableFile(atPath: parent.path) else { throw SignedUpdate.Failure.permission }
        let probe = parent.appendingPathComponent(".sakura-write-\(UUID().uuidString)")
        do { try fm.createDirectory(at: probe, withIntermediateDirectories: false); try fm.removeItem(at: probe) }
        catch { throw SignedUpdate.Failure.permission }
        let free = (try fm.attributesOfFileSystem(forPath: parent.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard free > 5 * 1024 * 1024 * 1024 else { throw SignedUpdate.Failure.space }
        let payload = try Data(contentsOf: zip, options: .mappedIfSafe)
        try SignedUpdate.verify(manifest: Data(contentsOf: signature), payload: payload, version: version, current: current, platform: "macOS")
        try SignedUpdate.checkZip(payload)
        let extract = work.appendingPathComponent("extracted")
        try fm.createDirectory(at: extract, withIntermediateDirectories: false)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, extract.path])
        let app = extract.appendingPathComponent("Sakura-\(version)-macOS/Sakura.app")
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["SakuraReleaseVersion"] as? String == version,
              info["CFBundleIdentifier"] as? String == "local.gardenboot.GardenBoot",
              fm.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/GardenBoot").path) else { throw SignedUpdate.Failure.structure }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        let staged = parent.appendingPathComponent(".Sakura-update-\(UUID().uuidString).app")
        do { try fm.copyItem(at: app, to: staged) } catch { try? fm.removeItem(at: staged); throw error }
        let request = Request(target: target.path, staged: staged.path, work: work.path, version: version, parent: getpid(), arguments: arguments)
        let path = work.appendingPathComponent("request.json")
        do { try JSONEncoder().encode(request).write(to: path, options: .atomic) }
        catch { try? fm.removeItem(at: staged); throw error }
        return path
    }
    /// Runs from a copy of the old executable outside the app; exchange is atomic on the destination volume.
    public static func apply(request path: URL) throws {
        let fm = FileManager.default
        let r = try JSONDecoder().decode(Request.self, from: Data(contentsOf: path))
        let ack = URL(fileURLWithPath: r.work).appendingPathComponent("ready")
        for _ in 0..<300 where kill(r.parent, 0) == 0 { Thread.sleep(forTimeInterval: 0.1) }
        guard kill(r.parent, 0) != 0 else { throw SignedUpdate.Failure.replacement }
        var swapped = false
        var launched: Process?
        func exchange() throws {
            guard renameatx_np(AT_FDCWD, r.target, AT_FDCWD, r.staged, UInt32(RENAME_SWAP)) == 0 else { throw SignedUpdate.Failure.replacement }
        }
        func start(_ args: [String]) throws -> Process {
            let p = Process(); p.executableURL = URL(fileURLWithPath: r.target + "/Contents/MacOS/GardenBoot"); p.arguments = r.arguments + args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); return p
        }
        do {
            try exchange(); swapped = true
            launched = try start(["--update-ready", ack.path, "--settings"])
            var confirmed = false
            for _ in 0..<300 {
                if launched?.isRunning == false { break }
                if (try? String(contentsOf: ack, encoding: .utf8)) == r.version { confirmed = true; break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            Thread.sleep(forTimeInterval: 2)
            guard confirmed, launched?.isRunning == true else { throw SignedUpdate.Failure.startup }
            try? fm.removeItem(atPath: r.staged)
            try? fm.removeItem(atPath: r.work)
        } catch {
            if launched?.isRunning == true { launched?.terminate(); launched?.waitUntilExit() }
            if swapped { do { try exchange() } catch { throw RecoveryRequired(backup: r.staged) } }
            // Preserve the old app even if re-opening it fails; retain local failure evidence.
            try? Data("\(error)".utf8).write(to: URL(fileURLWithPath: r.work).appendingPathComponent("failure"))
            do { _ = try start(["--update-failed", "--settings"]) } catch { throw RecoveryRequired(backup: r.target) }
            throw error
        }
    }
}

private extension URLResourceValues {
    var isSymbolicLinkValue: Bool { isSymbolicLink == true }
}

/// Streaming OS download, bounded on disk and at every redirect. Never changes proxy settings.
public final class UpdateDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private let destination: URL
    private let limit: Int64
    private let progress: @Sendable (Double) -> Void
    private let testOrigin: URL?
    public init(destination: URL, limit: Int64, testOrigin: URL? = nil, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination; self.limit = limit; self.progress = progress; self.testOrigin = testOrigin
    }
    public func fetch(_ url: URL) async throws -> URL {
        let production = url.scheme == "https" && url.user == nil && url.port == nil && url.host == "github.com" && url.path.hasPrefix("/shishyguo-cyber/sakura-launcher/releases/download/")
        let local = testOrigin.map { url.scheme == "http" && url.host == "127.0.0.1" && url.port == $0.port } ?? false
        guard production || local else { throw SignedUpdate.Failure.network }
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { c in
                continuation = c
                let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 1800
                session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                task = session!.downloadTask(with: url); task!.resume()
                if Task.isCancelled { task!.cancel() }
            }
        }, onCancel: { self.task?.cancel() })
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let u = request.url
        let allowed = u?.scheme == "https" && u?.user == nil && u?.port == nil &&
            (u?.host == "release-assets.githubusercontent.com" || (u?.host == "github.com" && u!.path.hasPrefix("/shishyguo-cyber/sakura-launcher/releases/download/")))
        let local = testOrigin.map { u?.scheme == "http" && u?.host == "127.0.0.1" && u?.port == $0.port } ?? false
        completionHandler(allowed || local ? request : nil)
    }
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel() }
        progress(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : -1)
    }
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
                  (try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= limit else { throw SignedUpdate.Failure.network }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch { continuation?.resume(throwing: error); continuation = nil }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume(returning: destination) }
        continuation = nil; session.finishTasksAndInvalidate()
    }
}
