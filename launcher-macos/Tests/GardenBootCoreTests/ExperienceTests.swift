import XCTest
@testable import GardenBootCore

final class ExperienceTests: XCTestCase {
    private var manifest: PackManifest {
        PackManifest(id: "a", name: "A", segments: [.outro: "outro.mp4"], volume: 0.8)
    }

    func testGreetingNameSurvivesSettingsMigrationAndSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ExperienceStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"schemaVersion":1,"masterVolume":0.5,"muted":true,"packs":{}}"#.utf8).write(to: store.file)
        XCTAssertNil(try store.load().greetingName)
        try Data(#"{"schemaVersion":1,"masterVolume":0.5,"muted":true,"packs":{},"greetingName":" 郭👩‍💻 "}"#.utf8).write(to: store.file)
        let migrated = try store.load()
        XCTAssertEqual(migrated.schemaVersion, 3)
        XCTAssertEqual(migrated.greetingName, "郭👩‍💻")
        XCTAssertEqual(migrated.masterVolume, 0.5)
        try store.save(migrated)
        XCTAssertEqual(try store.load(), migrated)
        var cleared = migrated
        cleared.greetingName = "  "
        try store.save(cleared)
        XCTAssertNil(try store.load().greetingName)
    }

    func testSharedResolution() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("launcher-spec/conformance/experience.json"))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for c in raw["cases"] as! [[String: Any]] {
            let json = try JSONSerialization.data(withJSONObject: c["settings"]!)
            if !(c["valid"] as! Bool) {
                XCTAssertThrowsError(try ExperienceSettings.decode(json), c["name"] as! String)
                continue
            }
            let settings = try ExperienceSettings.decode(json)
            let resolved = try settings.resolved(manifest)
            let e = c["expect"] as! [String: Any]
            XCTAssertEqual(resolved.effectiveVolume, (e["volume"] as! NSNumber).doubleValue, accuracy: 1e-9)
            XCTAssertEqual(resolved.effectiveFadeDuration, (e["fadeDuration"] as! NSNumber).doubleValue, accuracy: 1e-9)
            XCTAssertEqual(resolved.effectiveMaxWait, (e["maxWaitSeconds"] as! NSNumber).doubleValue, accuracy: 1e-9)
            XCTAssertEqual(resolved.effectiveLoopExit.rawValue, e["loopExit"] as! String)
            XCTAssertEqual(settings.coverage(for: "a"), (e["launchCoverage"] as! NSNumber).doubleValue, accuracy: 1e-9)
            XCTAssertEqual(resolved.handoffTime(finalDuration: 10), (e["handoffTime"] as! NSNumber).doubleValue, accuracy: 1e-9)
            XCTAssertEqual(manifest.volume, 0.8, "resolution must not mutate the pack")
        }
    }

    func testPresetCopiesSettingsAndResetKeepsPresetsAndOtherPacks() throws {
        var settings = ExperienceSettings()
        settings.packs["a"] = PackPreferences(overrides: PlaybackOverrides(fadeDuration: 1.2))
        settings.packs["b"] = PackPreferences(overrides: PlaybackOverrides(maxWaitSeconds: 25))
        try settings.addPreset(packID: "a", name: "  轻柔  ")
        settings.packs["a"]?.overrides.fadeDuration = 2
        XCTAssertEqual(settings.packs["a"]?.presets.first?.overrides.fadeDuration, 1.2)
        settings.resetPack("a")
        XCTAssertNil(settings.packs["a"]?.overrides.fadeDuration)
        XCTAssertEqual(settings.packs["a"]?.presets.count, 1)
        XCTAssertEqual(settings.packs["a"]?.presets.first?.name, "轻柔")
        XCTAssertEqual(settings.packs["b"]?.overrides.maxWaitSeconds, 25)
        XCTAssertThrowsError(try settings.addPreset(packID: "a", name: "轻柔"))
        XCTAssertThrowsError(try settings.addPreset(packID: "a", name: "\n "))
    }

    func testStoreRoundTripAndCorruptRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ExperienceStore(directory: root)
        XCTAssertEqual(try store.load(), ExperienceSettings())
        var settings = ExperienceSettings()
        settings.masterVolume = 0.35
        try settings.addPreset(packID: "a", name: "我的方案")
        try store.save(settings)
        XCTAssertEqual(try store.load(), settings)
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: store.file)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.file), corrupt)
        try store.save(settings)
        XCTAssertEqual(try store.load(), settings)
        let recovery = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("experience.recovery-") }
        XCTAssertEqual(recovery.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(recovery.first)), corrupt)
    }

    func testFutureSchemaAndInvalidSaveNeverOverwriteExistingData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ExperienceStore(directory: root)
        let future = Data("{\"schemaVersion\":99}".utf8)
        try future.write(to: store.file)
        XCTAssertThrowsError(try store.save(ExperienceSettings()))
        XCTAssertEqual(try Data(contentsOf: store.file), future)
        try FileManager.default.removeItem(at: store.file)
        try store.save(ExperienceSettings())
        let before = try Data(contentsOf: store.file)
        var invalid = ExperienceSettings()
        invalid.masterVolume = .nan
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(try Data(contentsOf: store.file), before)
    }

    func testExplicitDefaultIsDifferentFromNoOverride() throws {
        var settings = ExperienceSettings()
        settings.packs["a"] = PackPreferences(overrides: PlaybackOverrides(fadeDuration: 0.4))
        var updatedPack = manifest
        updatedPack.fadeDuration = 1.8
        XCTAssertEqual(try settings.resolved(updatedPack).effectiveFadeDuration, 0.4)
        settings.resetPack("a")
        XCTAssertEqual(try settings.resolved(updatedPack).effectiveFadeDuration, 1.8)
    }

    func testFinderHiddenFlagDoesNotRemoveInstalledPack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var folder = root.appendingPathComponent("a", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try Data([1]).write(to: folder.appendingPathComponent("outro.mp4"))
        try Data("notice".utf8).write(to: folder.appendingPathComponent("NOTICE.md"))
        var flags = URLResourceValues(); flags.isHidden = true
        try folder.setResourceValues(flags)
        XCTAssertEqual(PackLibrary(root: root).installed().packs.map(\.id), ["a"])
    }

    func testCustomCoverageRespectsScreenAndWidthLimit() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(OverlayGeometry.launchFrame(in: screen, coverage: 0.4), CGRect(x: 576, y: 324, width: 768, height: 432))
        XCTAssertEqual(OverlayGeometry.launchFrame(in: screen, coverage: 0.9), CGRect(x: 400, y: 225, width: 1120, height: 630))
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(OverlayGeometry.launchFrame(in: left, coverage: 0.4).minX, -1344)
        XCTAssertEqual(OverlayGeometry.launchFrame(in: screen, coverage: .nan), OverlayGeometry.launchFrame(in: screen))
    }

    func testFullScreenIsAnOptionalPerAnimationSwitch() throws {
        var settings = ExperienceSettings()
        XCTAssertFalse(settings.fullScreen(for: "a"), "off by default")
        settings.packs["a"] = PackPreferences(overrides: PlaybackOverrides(fullScreen: true))
        XCTAssertTrue(settings.fullScreen(for: "a"))
        XCTAssertFalse(settings.fullScreen(for: "b"), "per animation")
        let data = try JSONEncoder().encode(settings)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"fullScreen\":true"))
        XCTAssertTrue(try JSONDecoder().decode(ExperienceSettings.self, from: data).fullScreen(for: "a"))
        settings.packs["a"]?.overrides.fullScreen = nil
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(settings), as: UTF8.self).contains("fullScreen"), "off is not written")
    }
}
