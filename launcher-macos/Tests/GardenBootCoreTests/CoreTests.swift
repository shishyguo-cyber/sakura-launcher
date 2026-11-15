import XCTest
import CoreGraphics
@testable import GardenBootCore

final class CoreTests: XCTestCase {
    let target = "com.openai.codex"

    func testFinishingDoesNotStealFocusFromAnotherApplication() {
        XCTAssertTrue(PlaybackRules.shouldReturnFocus(frontmost: 1, player: 1, target: 2, targetAlive: true))
        XCTAssertTrue(PlaybackRules.shouldReturnFocus(frontmost: 2, player: 1, target: 2, targetAlive: true))
        XCTAssertFalse(PlaybackRules.shouldReturnFocus(frontmost: 3, player: 1, target: 2, targetAlive: true))
        XCTAssertFalse(PlaybackRules.shouldReturnFocus(frontmost: 1, player: 1, target: 2, targetAlive: false))
        XCTAssertFalse(PlaybackRules.shouldReturnFocus(frontmost: nil, player: 1, target: 2, targetAlive: true))
    }

    func testExistingAndUnrelatedApplicationsDoNotTrigger() {
        var state = LaunchSession(targetIdentifier: target, existingPIDs: [10])
        XCTAssertFalse(state.didLaunch(identifier: target, pid: 10))
        XCTAssertFalse(state.didLaunch(identifier: "unrelated.app", pid: 11))
        XCTAssertNil(state.activePID)
    }

    func testNewLaunchPlaysOnceEvenAfterFinishing() {
        var state = LaunchSession(targetIdentifier: target, existingPIDs: [])
        XCTAssertTrue(state.didLaunch(identifier: target, pid: 20))
        XCTAssertEqual(state.activePID, 20)
        XCTAssertFalse(state.didLaunch(identifier: target, pid: 20))
        state.finish()
        state.finish()
        XCTAssertNil(state.activePID)
        XCTAssertFalse(state.didLaunch(identifier: target, pid: 20))
        _ = state.didTerminate(pid: 20)
        XCTAssertTrue(state.didLaunch(identifier: target, pid: 21))
    }

    func testLateTerminationCannotCancelNewSession() {
        var state = LaunchSession(targetIdentifier: target, existingPIDs: [])
        XCTAssertTrue(state.didLaunch(identifier: target, pid: 30))
        XCTAssertFalse(state.didLaunch(identifier: target, pid: 31))
        XCTAssertFalse(state.didTerminate(pid: 30))
        XCTAssertEqual(state.activePID, 30)
        XCTAssertTrue(state.didTerminate(pid: 31))
        XCTAssertNil(state.activePID)
        XCTAssertFalse(state.didTerminate(pid: 31))
        XCTAssertTrue(state.didLaunch(identifier: target, pid: 32))
    }

    func testMediaReplacementIsCompleteAndFailureKeepsOldFile() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source with spaces.mp4")
        let destination = root.appendingPathComponent("library/startup.mp4")
        try Data([1, 2, 3]).write(to: source)
        XCTAssertEqual(try MediaLibrary.importFile(source, to: destination), destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data([1, 2, 3]))
        try Data([4, 5]).write(to: source)
        _ = try MediaLibrary.importFile(source, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data([4, 5]))
        XCTAssertThrowsError(try MediaLibrary.importFile(root.appendingPathComponent("missing"), to: destination))
        XCTAssertThrowsError(try MediaLibrary.importFile(root, to: destination))
        try Data().write(to: source)
        XCTAssertThrowsError(try MediaLibrary.importFile(source, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data([4, 5]))
    }
}
