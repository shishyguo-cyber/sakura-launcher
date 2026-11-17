import Foundation
import Darwin
@main struct Driver {
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
    }
    static func run() async throws {
        let a = CommandLine.arguments
        guard a.count == 7, URL(string: a[1])?.host == "127.0.0.1", FileManager.default.fileExists(atPath: URL(fileURLWithPath: a[3]).deletingLastPathComponent().appendingPathComponent(".update-test-root").path) else { exit(2) }
        let work = URL(fileURLWithPath: a[2]); try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let url = URL(string: a[1])!
        let signature = try await UpdateDownload(destination: work.appendingPathComponent("update.sig"), limit: 16384, testOrigin: url) { _ in }.fetch(URL(string: url.absoluteString + ".sig")!)
        let download = Task { try await UpdateDownload(destination: work.appendingPathComponent("update.zip"), limit: Int64(SignedUpdate.maxArchive), testOrigin: url) { _ in }.fetch(url) }
        if url.path.contains("/cancel/") { try await Task.sleep(nanoseconds: 150_000_000); download.cancel() }
        let zip = try await download.value
        let r = try UpdateInstaller.prepare(zip: zip, signature: signature, target: URL(fileURLWithPath: a[3]), version: a[4], current: "0.2.0-preview.7", work: work, arguments: ["--test-root",a[5]])
        var request = try JSONDecoder().decode(UpdateInstaller.Request.self, from: Data(contentsOf: r)); request.parent = Int32(a[6])!
        try JSONEncoder().encode(request).write(to: r)
        print(r.path)
    }
}
