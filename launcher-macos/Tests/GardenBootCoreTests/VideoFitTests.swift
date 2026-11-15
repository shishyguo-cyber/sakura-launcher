import XCTest
@testable import GardenBootCore

final class VideoFitTests: XCTestCase {
    func testThresholdIncludesExactlyTwelvePercent() {
        XCTAssertEqual(VideoFit.resolve(mode: .auto, frameSize: CGSize(width: 88, height: 100), videoAspect: 1).mode, .fill)
        XCTAssertEqual(VideoFit.resolve(mode: .auto, frameSize: CGSize(width: 87.999, height: 100), videoAspect: 1).mode, .fit)
        XCTAssertEqual(VideoFit.resolve(mode: .auto, frameSize: CGSize(width: 100, height: 88), videoAspect: 1).mode, .fill)
    }

    func testInvalidDimensionsFallBackToFrameEvenForForcedFit() {
        for bad in [CGFloat.zero, -1, .infinity, -.infinity, .nan] {
            let size = CGSize(width: 800, height: 600)
            XCTAssertEqual(VideoFit.resolve(mode: .fit, frameSize: size, videoAspect: bad),
                           VideoFit.Resolution(mode: .fill, contentRect: CGRect(origin: .zero, size: size)))
            for frame in [CGSize(width: bad, height: 600), CGSize(width: 800, height: bad)] {
                let got = VideoFit.resolve(mode: .auto, frameSize: frame, videoAspect: 16 / 9)
                XCTAssertEqual(got.mode, .fill)
                // CGRect equality does not consider NaN equal to itself.
                for (actual, expected) in [(got.contentRect.size.width, frame.width), (got.contentRect.size.height, frame.height)] {
                    XCTAssertTrue(expected.isNaN ? actual.isNaN : actual == expected)
                }
                XCTAssertEqual(got.contentRect.origin, .zero)
            }
        }
    }

    func testResizeAndSegmentAspectRecalculateWithoutRetainingOldMode() {
        let wide = CGSize(width: 1440, height: 900), square = CGSize(width: 1024, height: 768)
        XCTAssertEqual(VideoFit.resolve(mode: .auto, frameSize: wide, videoAspect: 16 / 9).mode, .fill)
        XCTAssertEqual(VideoFit.resolve(mode: .auto, frameSize: square, videoAspect: 16 / 9).mode, .fit)
        XCTAssertEqual(VideoFit.resolve(mode: .auto, frameSize: square, videoAspect: 4 / 3).mode, .fill)
        XCTAssertEqual(VideoFit.resolve(mode: .auto, frameSize: wide, videoAspect: 16 / 9).mode, .fill)
    }

    func testOverrideInheritanceAndExplicitAuto() throws {
        var pack = PackManifest(id: "a", name: "A", segments: [.video: "v.mp4"])
        var settings = ExperienceSettings()
        XCTAssertEqual(try settings.resolved(pack).effectiveVideoFit, .auto)
        pack.videoFit = .fill
        XCTAssertEqual(try settings.resolved(pack).effectiveVideoFit, .fill)
        settings.packs["a"] = .init(overrides: .init(videoFit: .fit))
        XCTAssertEqual(try settings.resolved(pack).effectiveVideoFit, .fit)
        settings.packs["a"]?.overrides.videoFit = .auto
        XCTAssertEqual(try settings.resolved(pack).effectiveVideoFit, .auto)
        settings.packs["a"]?.overrides.videoFit = nil
        XCTAssertEqual(try settings.resolved(pack).effectiveVideoFit, .fill)
        XCTAssertEqual(pack.videoFit, .fill)
    }

    func testPresetStoreRoundTripResetAndReapply() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = ExperienceSettings()
        settings.packs["a"] = .init(overrides: .init(videoFit: .fit))
        try settings.addPreset(packID: "a", name: "完整画面")
        settings.packs["a"]?.overrides.videoFit = .fill
        try settings.addPreset(packID: "a", name: "铺满画框")
        settings.packs["a"]?.overrides.videoFit = .auto
        try settings.addPreset(packID: "a", name: "自动")
        settings.resetPack("a")
        XCTAssertNil(settings.packs["a"]?.overrides.videoFit)
        let store = ExperienceStore(directory: directory)
        try store.save(settings)
        var loaded = try store.load()
        XCTAssertEqual(loaded, settings)
        XCTAssertEqual(loaded.schemaVersion, 3)
        XCTAssertEqual(loaded.packs["a"]?.presets.map { $0.overrides.videoFit }, [.fit, .fill, .auto])
        let preset = try XCTUnwrap(loaded.packs["a"]?.presets.first?.overrides)
        loaded.packs["a"]?.overrides = preset
        XCTAssertEqual(try loaded.resolved(PackManifest(id: "a", name: "A", segments: [.video: "v.mp4"])).effectiveVideoFit, .fit)
    }

    func testInvalidPresetModeIsRejected() throws {
        let data = Data("""
        {"schemaVersion":2,"masterVolume":1,"muted":false,
         "packs":{"a":{"overrides":{},"presets":[{"id":"p","name":"bad","overrides":{"videoFit":"stretch"}}]}},
         "playback":{"frequency":"everyLaunch","dayStartHour":4},"library":{"rotation":"fixed","favorites":[]}}
        """.utf8)
        XCTAssertThrowsError(try ExperienceSettings.decode(data))
    }
}
