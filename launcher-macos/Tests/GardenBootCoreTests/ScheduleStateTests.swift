import XCTest
@testable import GardenBootCore

final class ScheduleStateTests: XCTestCase {
    func testStateMissingCorruptUnsupportedAndIllegalResetWithoutWriting() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlaybackStateStore(directory: dir)
        var resets = 0
        XCTAssertEqual(store.load { resets += 1 }, .init())
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for raw in ["{", "{}", "{\"schemaVersion\":2}", "{\"schemaVersion\":1,\"snoozeUntil\":-1}",
                    "{\"schemaVersion\":1,\"lastPackId\":\"Bad\"}", "{\"schemaVersion\":1,\"lastAutoPlayAt\":\"12\"}",
                    "{\"schemaVersion\":1,\"lastAutoPlayAt\":true}"] {
            let data = Data(raw.utf8); try data.write(to: store.file)
            XCTAssertEqual(store.load { resets += 1 }, .init())
            XCTAssertEqual(try Data(contentsOf: store.file), data)
        }
        XCTAssertEqual(resets, 8)
        try store.save(.init(lastAutoPlayAt: 123.5, lastPackId: "a", snoozeUntil: 800))
        XCTAssertEqual(store.load(), .init(lastAutoPlayAt: 123.5, lastPackId: "a", snoozeUntil: 800))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["playback-state.json"])
    }
    func testStateNullFieldsAndInvalidSave() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlaybackStateStore(directory: dir)
        try store.save(.init())
        try Data(#"{"schemaVersion":1,"lastAutoPlayAt":null,"lastPackId":null,"snoozeUntil":null}"#.utf8).write(to: store.file)
        XCTAssertEqual(store.load(), .init())
        let before = try Data(contentsOf: store.file)
        for state in [PlaybackState(lastAutoPlayAt: .infinity), .init(snoozeUntil: .nan), .init(lastPackId: "../bad")] {
            XCTAssertThrowsError(try store.save(state))
            XCTAssertEqual(try Data(contentsOf: store.file), before)
        }
    }
    func testV1MigrationPreservesPreferencesAndWritesV3() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ExperienceStore(directory: dir)
        var original = ExperienceSettings(); original.masterVolume = 0.3
        original.packs["a"] = .init(overrides: .init(fadeDuration: 1.3))
        try original.addPreset(packID: "a", name: "保留方案")
        var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        raw["schemaVersion"] = 1; raw.removeValue(forKey: "playback"); raw.removeValue(forKey: "library")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: raw).write(to: store.file)
        let migrated = try store.load()
        XCTAssertEqual(migrated, original)
        try store.save(migrated)
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: store.file)) as! [String: Any]
        XCTAssertEqual(written["schemaVersion"] as? Int, 3)
        XCTAssertNotNil(written["playback"]); XCTAssertNotNil(written["library"])
    }
    func testClockRollbackThresholdAndDSTOffsets() {
        let state = PlaybackState(lastAutoPlayAt: 100_300)
        XCTAssertEqual(ScheduleDecision.decide(frequency: .firstOfDay, dayStartHour: 4, state: state,
            now: 100_000, nowOffset: 0, lastOffset: 0), .playedToday)
        XCTAssertEqual(ScheduleDecision.decide(frequency: .firstOfDay, dayStartHour: 4, state: state,
            now: 99_999, nowOffset: 0, lastOffset: 0), .play)
        // Same local hour across a daylight-saving fallback remains the same playback day.
        XCTAssertEqual(ScheduleDecision.decide(frequency: .firstOfDay, dayStartHour: 0,
            state: .init(lastAutoPlayAt: 1_794_719_000), now: 1_794_722_600,
            nowOffset: -18000, lastOffset: -14400), .playedToday)
    }
}
