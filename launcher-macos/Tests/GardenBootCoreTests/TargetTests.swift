import XCTest
@testable import GardenBootCore

final class TargetTests: XCTestCase {
    func testForeignTargetsAndUnknownPlatformBlocksSurviveSave() throws {
        var settings = ExperienceSettings()
        var foreign = ApplicationTarget(id: "foreign", name: "Other", bundleID: "unused")
        foreign.platforms = ["windows": .object(["path": .string("C:\\Tools\\app.exe")]),
                             "futureOS": .object(["nested": .array([.number(3), .bool(true), .null])])]
        settings.targets.append(foreign)
        let decoded = try ExperienceSettings.decode(JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
        XCTAssertNil(decoded.targets[1].bundleID)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ExperienceStore(directory: dir)
        try store.save(decoded)
        XCTAssertEqual(try store.load().targets[1], foreign)
    }
    func testV1AndV2MigrateAndFutureVersionCannotBeOverwritten() throws {
        for version in [1, 2] {
            var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ExperienceSettings())) as! [String: Any]
            raw["schemaVersion"] = version; raw.removeValue(forKey: "targets")
            if version == 1 { raw.removeValue(forKey: "playback"); raw.removeValue(forKey: "library") }
            let migrated = try ExperienceSettings.decode(JSONSerialization.data(withJSONObject: raw))
            XCTAssertEqual(migrated.schemaVersion, 3)
            XCTAssertEqual(migrated.targets, [.defaultTarget])
            let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(migrated)) as! [String: Any]
            XCTAssertEqual(saved["schemaVersion"] as? Int, 3)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ExperienceStore(directory: dir), data = Data(#"{"schemaVersion":4}"#.utf8)
        try data.write(to: store.file)
        XCTAssertThrowsError(try store.save(.init()))
        XCTAssertEqual(try Data(contentsOf: store.file), data)
    }
    func testDailyRecordsAreIndependentAndSnoozeIsGlobal() {
        var state = PlaybackState()
        state.targets["one"] = .init(lastAutoPlayAt: 100_000, lastPackId: "a")
        func decide(_ id: String) -> ScheduleDecision {
            ScheduleDecision.decide(frequency: .firstOfDay, dayStartHour: 4, state: state, targetID: id,
                                    now: 100_100, nowOffset: 0, lastOffset: 0)
        }
        XCTAssertEqual(decide("one"), .playedToday)
        XCTAssertEqual(decide("two"), .play)
        state.snoozeUntil = 200_000
        XCTAssertEqual(decide("one"), .snoozed)
        XCTAssertEqual(decide("two"), .snoozed)
    }
    func testOnlyNoProcessToProcessTransitionTriggersAndSessionsAreIndependent() {
        var one = LaunchSession(targetIdentifier: "one", existingPIDs: [1])
        var two = LaunchSession(targetIdentifier: "two", existingPIDs: [])
        XCTAssertFalse(one.didLaunch(identifier: "one", pid: 2))
        XCTAssertTrue(two.didLaunch(identifier: "two", pid: 3))
        XCTAssertFalse(one.didTerminate(pid: 1))
        XCTAssertFalse(one.didLaunch(identifier: "one", pid: 4))
        _ = one.didTerminate(pid: 2); _ = one.didTerminate(pid: 4)
        XCTAssertTrue(one.didLaunch(identifier: "one", pid: 5))
        XCTAssertEqual(two.activePID, 3)
        XCTAssertFalse(two.didLaunch(identifier: "two", pid: 6))
        XCTAssertFalse(two.didTerminate(pid: 3))
        XCTAssertTrue(two.didTerminate(pid: 6))
    }
}

final class QuietWindowTests: XCTestCase {
    private func window(_ pid: Int32, _ rect: CGRect, layer: Int = 0, opacity: Double = 1) -> WindowRecord {
        WindowRecord(ownerPID: pid, layer: layer, opacity: opacity, bounds: rect)
    }
    func testFullScreenNeedsAWholeDisplay() {
        let displays = [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 1512, y: 0, width: 1920, height: 1080)]
        XCTAssertTrue(WindowPicker.coversDisplay(pid: 7, in: [window(7, displays[1])], displays: displays))
        XCTAssertTrue(WindowPicker.coversDisplay(pid: 7, in: [window(7, displays[0], layer: 25)], displays: displays))
        // Zoomed below the menu bar, another app's window, or a faded window are not full screen.
        XCTAssertFalse(WindowPicker.coversDisplay(pid: 7, in: [window(7, CGRect(x: 0, y: 33, width: 1512, height: 949))], displays: displays))
        XCTAssertFalse(WindowPicker.coversDisplay(pid: 7, in: [window(8, displays[0])], displays: displays))
        XCTAssertFalse(WindowPicker.coversDisplay(pid: 7, in: [window(7, displays[0], opacity: 0.1)], displays: displays))
    }
    func testMainWindowPresence() {
        let big = CGRect(x: 10, y: 10, width: 800, height: 600)
        XCTAssertTrue(WindowPicker.hasMainWindow(pids: [3], in: [window(3, big, opacity: 0)], requireOpaque: false))
        XCTAssertFalse(WindowPicker.hasMainWindow(pids: [3], in: [window(3, big, opacity: 0)], requireOpaque: true))
        XCTAssertFalse(WindowPicker.hasMainWindow(pids: [3], in: [window(3, CGRect(x: 0, y: 0, width: 200, height: 100))], requireOpaque: false))
        XCTAssertFalse(WindowPicker.hasMainWindow(pids: [3], in: [window(3, big, layer: 3)], requireOpaque: false))
    }
}
