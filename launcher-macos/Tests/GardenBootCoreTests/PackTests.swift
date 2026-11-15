import XCTest
@testable import GardenBootCore

final class PackTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("packs-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private let goodProbe: MediaProbe = { _ in MediaInfo(duration: 2, hasVideo: true) }

    /// Writes a pack folder. `files` maps file name → bytes; manifest is written as given.
    private func makePack(_ name: String, manifest: String, files: [String: Data]) throws -> URL {
        let dir = root.appendingPathComponent("src-\(name)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: dir.appendingPathComponent("manifest.json"))
        for (file, data) in files { try data.write(to: dir.appendingPathComponent(file)) }
        return dir
    }

    private func segmentedManifest(id: String = "demo-garden", extra: String = "") -> String {
        """
        {"schemaVersion":1,"id":"\(id)","name":"花园 · 示例",
         "segments":{"intro":"intro.mp4","loop":"loop.mp4","outro":"outro.mp4"}\(extra)}
        """
    }

    private let segmentedFiles: [String: Data] = [
        "intro.mp4": Data([1]), "loop.mp4": Data([2]), "outro.mp4": Data([3]), "NOTICE.md": Data("n".utf8),
    ]

    // MARK: Manifest validation

    func testSegmentedAndSingleLayouts() throws {
        let segmented = PackManifest(id: "a", name: "A", segments: [.intro: "i.mp4", .loop: "l.mp4", .outro: "o.mp4"])
        let layout = try segmented.validatedLayout()
        XCTAssertEqual(layout, PackLayout(intro: "i.mp4", loop: "l.mp4", final: "o.mp4", finalSegment: .outro))
        XCTAssertTrue(layout.coversLaunch)

        let single = try PackManifest(id: "b", name: "B", segments: [.video: "v.mov"]).validatedLayout()
        XCTAssertEqual(single.finalSegment, .video)
        XCTAssertFalse(single.coversLaunch)

        let outroOnly = try PackManifest(id: "c", name: "C", segments: [.outro: "o.mp4"]).validatedLayout()
        XCTAssertFalse(outroOnly.coversLaunch)
    }

    func testInvalidManifestsAreRejected() {
        let cases: [PackManifest] = [
            PackManifest(schemaVersion: 2, id: "a", name: "A", segments: [.video: "v.mp4"]),
            PackManifest(id: "Bad ID", name: "A", segments: [.video: "v.mp4"]),
            PackManifest(id: "a", name: "  ", segments: [.video: "v.mp4"]),
            PackManifest(id: "a", name: "A", segments: [:]),
            PackManifest(id: "a", name: "A", segments: [.intro: "i.mp4"]),
            PackManifest(id: "a", name: "A", segments: [.video: "v.mp4", .outro: "o.mp4"]),
            PackManifest(id: "a", name: "A", segments: [.video: "../v.mp4"]),
            PackManifest(id: "a", name: "A", segments: [.video: "sub/v.mp4"]),
            PackManifest(id: "a", name: "A", segments: [.video: ".hidden.mp4"]),
            PackManifest(id: "a", name: "A", segments: [.video: "v.gif"]),
            PackManifest(id: "a", name: "A", segments: [.video: "v.mp4"], volume: 1.5),
            PackManifest(id: "a", name: "A", segments: [.video: "v.mp4"], fadeDuration: 0),
            PackManifest(id: "a", name: "A", segments: [.video: "v.mp4"], maxWaitSeconds: 600),
            PackManifest(id: "a", name: "A", segments: [.video: "v.mp4"], handoffAt: -1),
            PackManifest(id: "a", name: "A", segments: [.video: "v.mp4"], notice: "../NOTICE.md"),
        ]
        for manifest in cases {
            XCTAssertThrowsError(try manifest.validatedLayout(), "\(manifest)")
        }
    }

    func testUnknownSegmentKeyIsRejectedButUnknownTopLevelKeysAreIgnored() throws {
        let unknownSegment = #"{"schemaVersion":1,"id":"a","name":"A","segments":{"credits":"c.mp4"}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(PackManifest.self, from: Data(unknownSegment.utf8)))
        let futureKey = #"{"schemaVersion":1,"id":"a","name":"A","segments":{"video":"v.mp4"},"theme":"x"}"#
        XCTAssertNoThrow(try JSONDecoder().decode(PackManifest.self, from: Data(futureKey.utf8)))
    }

    func testManifestRoundTrips() throws {
        let manifest = PackManifest(id: "a", name: "A", segments: [.intro: "i.mp4", .outro: "o.mp4"],
                                    handoffAt: 1.2, fadeDuration: 0.5, volume: 0.8, maxWaitSeconds: 12,
                                    loopExit: .immediate, notice: "LICENSE.md")
        let decoded = try JSONDecoder().decode(PackManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(decoded, manifest)
    }

    func testHandoffTimeIsClampedSoTheFadeFits() {
        var manifest = PackManifest(id: "a", name: "A", segments: [.video: "v.mp4"], fadeDuration: 0.5)
        XCTAssertEqual(manifest.handoffTime(finalDuration: 4), 3.5, accuracy: 1e-9)
        manifest.handoffAt = 1.2
        XCTAssertEqual(manifest.handoffTime(finalDuration: 4), 1.2, accuracy: 1e-9)
        manifest.handoffAt = 10
        XCTAssertEqual(manifest.handoffTime(finalDuration: 4), 3.5, accuracy: 1e-9)
        XCTAssertEqual(manifest.handoffTime(finalDuration: 0.2), 0, accuracy: 1e-9)
    }

    // MARK: Library

    func testImportCopiesOnlyReferencedFilesAndLists() async throws {
        var files = segmentedFiles
        files["private-raw-footage.mov"] = Data([9])
        let source = try makePack("ok", manifest: segmentedManifest(), files: files)
        let library = PackLibrary(root: root.appendingPathComponent("Packs"))
        let pack = try await library.importPack(from: source, probe: goodProbe)
        XCTAssertEqual(pack.id, "demo-garden")
        XCTAssertEqual(pack.directory.lastPathComponent, "demo-garden")
        let copied = Set(try fm.contentsOfDirectory(atPath: pack.directory.path))
        XCTAssertEqual(copied, ["manifest.json", "intro.mp4", "loop.mp4", "outro.mp4", "NOTICE.md"])
        let listed = library.installed()
        XCTAssertEqual(listed.packs.map(\.id), ["demo-garden"])
        XCTAssertTrue(listed.problems.isEmpty)
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: library.root.path).contains { $0.hasPrefix(".") })
    }

    func testMissingNoticeOrVideoIsRejected() async throws {
        var noNotice = segmentedFiles
        noNotice["NOTICE.md"] = nil
        let a = try makePack("nonotice", manifest: segmentedManifest(), files: noNotice)
        var noLoop = segmentedFiles
        noLoop["loop.mp4"] = Data()
        let b = try makePack("emptyloop", manifest: segmentedManifest(), files: noLoop)
        let library = PackLibrary(root: root.appendingPathComponent("Packs"))
        for source in [a, b] {
            do { _ = try await library.importPack(from: source, probe: goodProbe); XCTFail("accepted \(source)") }
            catch { XCTAssertTrue(error is PackError) }
        }
    }

    func testFailedReimportKeepsInstalledPack() async throws {
        let library = PackLibrary(root: root.appendingPathComponent("Packs"))
        let good = try makePack("v1", manifest: segmentedManifest(), files: segmentedFiles)
        try await library.importPack(from: good, probe: goodProbe)

        var changed = segmentedFiles
        changed["outro.mp4"] = Data([7, 7])
        let broken = try makePack("v2", manifest: segmentedManifest(), files: changed)
        let badProbe: MediaProbe = { url in
            MediaInfo(duration: url.lastPathComponent == "outro.mp4" ? .nan : 1, hasVideo: true)
        }
        do { try await library.importPack(from: broken, probe: badProbe); XCTFail("accepted undecodable outro") }
        catch { XCTAssertEqual(error as? PackError, .invalidMedia("outro.mp4")) }
        let installed = library.root.appendingPathComponent("demo-garden/outro.mp4")
        XCTAssertEqual(try Data(contentsOf: installed), Data([3]))

        let throwingProbe: MediaProbe = { _ in throw CocoaError(.fileReadCorruptFile) }
        do { try await library.importPack(from: broken, probe: throwingProbe); XCTFail("accepted") }
        catch { XCTAssertEqual(error as? PackError, .invalidMedia("intro.mp4")) }

        try await library.importPack(from: broken, probe: goodProbe)
        XCTAssertEqual(try Data(contentsOf: installed), Data([7, 7]))
    }

    func testInstallIfMissingDoesNotOverwriteUserCopy() async throws {
        let library = PackLibrary(root: root.appendingPathComponent("Packs"))
        let bundled = try makePack("bundled", manifest: segmentedManifest(), files: segmentedFiles)
        let first = try await library.installIfMissing(bundled: bundled, probe: goodProbe)
        XCTAssertNotNil(first)
        try Data([5]).write(to: library.root.appendingPathComponent("demo-garden/intro.mp4"))
        let second = try await library.installIfMissing(bundled: bundled, probe: goodProbe)
        XCTAssertNil(second)
        XCTAssertEqual(try Data(contentsOf: library.root.appendingPathComponent("demo-garden/intro.mp4")), Data([5]))
    }

    func testLegacyVideoBecomesSingleVideoPackAndOriginalStays() async throws {
        let legacy = root.appendingPathComponent("startup.mp4")
        try Data([4, 2]).write(to: legacy)
        let library = PackLibrary(root: root.appendingPathComponent("Packs"))
        let pack = try await library.migrateLegacyVideo(legacy, probe: goodProbe)
        XCTAssertEqual(pack?.id, PackLibrary.legacyPackID)
        XCTAssertEqual(pack?.layout.finalSegment, .video)
        XCTAssertEqual(try Data(contentsOf: pack!.url(for: pack!.layout.final)), Data([4, 2]))
        XCTAssertTrue(fm.fileExists(atPath: pack!.noticeURL.path))
        XCTAssertTrue(fm.fileExists(atPath: legacy.path))
        let again = try await library.migrateLegacyVideo(legacy, probe: goodProbe)
        XCTAssertNil(again)
        let none = try await library.migrateLegacyVideo(root.appendingPathComponent("missing.mp4"), probe: goodProbe)
        XCTAssertNil(none)
    }

    func testBrokenOrMisnamedFoldersAreReportedNotListed() async throws {
        let library = PackLibrary(root: root.appendingPathComponent("Packs"))
        try await library.importPack(from: makePack("ok", manifest: segmentedManifest(), files: segmentedFiles),
                                     probe: goodProbe)
        let misnamed = library.root.appendingPathComponent("renamed")
        try fm.copyItem(at: library.root.appendingPathComponent("demo-garden"), to: misnamed)
        let broken = library.root.appendingPathComponent("broken")
        try fm.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: broken.appendingPathComponent("manifest.json"))
        let listed = library.installed()
        XCTAssertEqual(listed.packs.map(\.id), ["demo-garden"])
        XCTAssertEqual(Set(listed.problems.keys), ["renamed", "broken"])
    }

    func testActivePackResolution() throws {
        func pack(_ id: String, _ name: String) -> InstalledPack {
            InstalledPack(manifest: PackManifest(id: id, name: name, segments: [.video: "v.mp4"]),
                          layout: PackLayout(intro: nil, loop: nil, final: "v.mp4", finalSegment: .video),
                          directory: URL(fileURLWithPath: "/tmp/\(id)"))
        }
        let packs = [pack("a", "A"), pack("demo-garden", "D"), pack("night-garden", "R")]
        XCTAssertEqual(PackLibrary.resolveActive(preferredID: "night-garden", packs: packs, fallbackID: "demo-garden")?.id,
                       "night-garden")
        XCTAssertEqual(PackLibrary.resolveActive(preferredID: "deleted", packs: packs, fallbackID: "demo-garden")?.id,
                       "demo-garden")
        XCTAssertEqual(PackLibrary.resolveActive(preferredID: nil, packs: [pack("a", "A")], fallbackID: "demo-garden")?.id, "a")
        XCTAssertNil(PackLibrary.resolveActive(preferredID: nil, packs: [], fallbackID: "demo-garden"))
    }
}

extension PackTests {
    func testCoverCopiedAndDecodeFailureKeepsInstalledPack() async throws {
        var files = segmentedFiles; files["cover.png"] = Data([42])
        let source = try makePack("cover", manifest: segmentedManifest(extra: ",\"cover\":\"cover.png\""), files: files)
        let library = PackLibrary(root: root.appendingPathComponent("Packs"))
        let pack = try await library.importPack(from: source, probe: goodProbe, imageProbe: { _ in true })
        XCTAssertEqual(pack.manifest.cover, "cover.png")
        XCTAssertEqual(try Data(contentsOf: pack.url(for: "cover.png")), Data([42]))
        try Data([43]).write(to: source.appendingPathComponent("cover.png"))
        do { try await library.importPack(from: source, probe: goodProbe, imageProbe: { _ in false }); XCTFail("accepted") }
        catch { XCTAssertEqual(error as? PackError, .invalidCover("cover.png 无法解码为图片")) }
        XCTAssertEqual(try Data(contentsOf: pack.url(for: "cover.png")), Data([42]))
    }
    func testMissingEmptyOversizeAndBoundaryCover() async throws {
        let library = PackLibrary(root: root.appendingPathComponent("Packs"))
        for size in [-1, 0, 8 * 1024 * 1024 + 1, 8 * 1024 * 1024] {
            var files = segmentedFiles
            if size >= 0 { files["cover.png"] = Data(repeating: 1, count: size) }
            let source = try makePack("size-\(size)", manifest: segmentedManifest(extra: ",\"cover\":\"cover.png\""), files: files)
            if size == 8 * 1024 * 1024 {
                _ = try await library.importPack(from: source, probe: goodProbe, imageProbe: { _ in true })
            } else {
                do { try await library.importPack(from: source, probe: goodProbe, imageProbe: { _ in true }); XCTFail("accepted \(size)") }
                catch { guard case .invalidCover = error as? PackError else { return XCTFail("\(error)") } }
            }
        }
    }
}
