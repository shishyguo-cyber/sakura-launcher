import XCTest
import CoreGraphics
@testable import GardenBootCore

final class LaunchRulesTests: XCTestCase {
    // MARK: Login and hidden launches

    func testHiddenTargetNeverPlays() {
        XCTAssertEqual(LaunchFilter.skip(targetHidden: true, launcherAge: 3600, launcherStartedAtLogin: false,
                                         systemUptime: 99_999), .hidden)
    }

    func testLaunchesRightAfterALoginStartAreSkipped() {
        // Launcher opened as a login item, target follows 10 s later.
        XCTAssertEqual(LaunchFilter.skip(targetHidden: false, launcherAge: 10, launcherStartedAtLogin: true,
                                         systemUptime: 50_000), .atLogin)
        // Login-item flag missing, but the launcher started 40 s after boot: still a login session.
        XCTAssertEqual(LaunchFilter.skip(targetHidden: false, launcherAge: 20, launcherStartedAtLogin: false,
                                         systemUptime: 60), .atLogin)
    }

    func testOrdinaryLaunchesPlay() {
        // Same login session, but the grace period is over: the user opened it.
        XCTAssertNil(LaunchFilter.skip(targetHidden: false, launcherAge: LaunchFilter.loginGrace + 1,
                                       launcherStartedAtLogin: true, systemUptime: 50_000))
        // Launcher started by hand long after boot, target opened 5 s later.
        XCTAssertNil(LaunchFilter.skip(targetHidden: false, launcherAge: 5, launcherStartedAtLogin: false,
                                       systemUptime: 50_000))
    }

    // MARK: Activation grace

    func testOtherAppsFlickeringDuringTheLaunchDoNotEndPlayback() {
        XCTAssertFalse(PlaybackPolicy.endsOnActivation(isLauncher: false, isTarget: false, overlayAge: 0.4))
        XCTAssertFalse(PlaybackPolicy.endsOnActivation(isLauncher: false, isTarget: false,
                                                       overlayAge: PlaybackPolicy.activationGrace - 0.01))
        XCTAssertTrue(PlaybackPolicy.endsOnActivation(isLauncher: false, isTarget: false,
                                                      overlayAge: PlaybackPolicy.activationGrace))
        XCTAssertFalse(PlaybackPolicy.endsOnActivation(isLauncher: true, isTarget: false, overlayAge: 30))
        XCTAssertFalse(PlaybackPolicy.endsOnActivation(isLauncher: false, isTarget: true, overlayAge: 30))
    }

    // MARK: Hidden target in the machine

    func testHiddenTargetBeforeItsWindowClosesQuietly() {
        var m = PlaybackMachine(layout: PackLayout(intro: "i.mp4", loop: "l.mp4", final: "o.mp4", finalSegment: .outro))
        _ = m.handle(.start(windowReady: false))
        XCTAssertEqual(m.handle(.targetHidden), [.close(.targetHidden, wasVisible: true)])
        XCTAssertFalse(PlaybackEndReason.targetHidden.offersFocusToTarget)
        XCTAssertEqual(PlaybackEndReason.targetHidden.logName, "target-hidden")
    }

    func testHidingAfterTheWindowWasReadyIsIgnored() {
        var m = PlaybackMachine(layout: PackLayout(intro: nil, loop: nil, final: "v.mp4", finalSegment: .video))
        _ = m.handle(.start(windowReady: true))
        XCTAssertEqual(m.handle(.targetHidden), [])
        XCTAssertEqual(m.phase, .final)
    }

    // MARK: Following the window

    func testFollowsOnlyRealMovesOrResizes() {
        let docked = CGRect(x: 100, y: 100, width: 1000, height: 700)
        XCTAssertFalse(OverlayGeometry.shouldFollow(current: docked, latest: docked))
        XCTAssertFalse(OverlayGeometry.shouldFollow(current: docked, latest: docked.offsetBy(dx: 1.5, dy: -1)))
        XCTAssertTrue(OverlayGeometry.shouldFollow(current: docked, latest: docked.offsetBy(dx: 40, dy: 0)))
        XCTAssertTrue(OverlayGeometry.shouldFollow(current: docked,
                                                   latest: CGRect(x: 100, y: 100, width: 1200, height: 700)))
        XCTAssertTrue(OverlayGeometry.shouldFollow(current: docked,
                                                   latest: CGRect(x: 100, y: 100, width: 1000, height: 703)))
    }
}
