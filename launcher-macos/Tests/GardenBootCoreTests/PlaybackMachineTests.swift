import XCTest
@testable import GardenBootCore

final class PlaybackMachineTests: XCTestCase {
    private let full = PackLayout(intro: "i.mp4", loop: "l.mp4", final: "o.mp4", finalSegment: .outro)
    private let introOnly = PackLayout(intro: "i.mp4", loop: nil, final: "o.mp4", finalSegment: .outro)
    private let loopOnly = PackLayout(intro: nil, loop: "l.mp4", final: "o.mp4", finalSegment: .outro)
    private let single = PackLayout(intro: nil, loop: nil, final: "v.mp4", finalSegment: .video)

    private func machine(_ layout: PackLayout, loopExit: LoopExit = .cycleEnd) -> PlaybackMachine {
        PlaybackMachine(layout: layout, fadeDuration: 0.4, loopExit: loopExit)
    }

    func testFullPackFillsTheLaunchThenHandsOffOnTheWindow() {
        var m = machine(full)
        XCTAssertFalse(m.isOnTargetWindow)
        XCTAssertEqual(m.handle(.start(windowReady: false)), [.showOnLaunchScreen, .play(.intro, looping: false)])
        XCTAssertFalse(m.isOnTargetWindow)
        XCTAssertEqual(m.handle(.segmentEnded(.intro)), [.play(.loop, looping: true)])
        XCTAssertEqual(m.handle(.loopCycleEnded), [], "window not ready: keep looping")
        XCTAssertEqual(m.handle(.windowReady), [.moveToTargetWindow(animated: true)], "move now, finish the cycle on the window")
        XCTAssertTrue(m.isOnTargetWindow)
        XCTAssertEqual(m.phase, .looping)
        XCTAssertEqual(m.handle(.windowReady), [], "repeated report ignored")
        XCTAssertEqual(m.handle(.loopCycleEnded), [.play(.outro, looping: false)])
        XCTAssertEqual(m.handle(.loopCycleEnded), [])
        XCTAssertEqual(m.handle(.reachedHandoff), [.beginFade(duration: 0.4)])
        XCTAssertEqual(m.handle(.reachedHandoff), [])
        XCTAssertEqual(m.handle(.segmentEnded(.outro)), [], "already fading")
        XCTAssertEqual(m.handle(.fadeCompleted), [.close(.completed, wasVisible: true)])
        XCTAssertTrue(m.isClosed)
        XCTAssertTrue(m.isOnTargetWindow, "attachment records placement; fading/closed separately stop following")
        XCTAssertEqual(m.handle(.skip), [])
        XCTAssertEqual(m.handle(.targetExited), [])
    }

    func testWindowReadyDuringIntroLetsTheIntroFinishThenSkipsTheLoop() {
        var m = machine(full)
        _ = m.handle(.start(windowReady: false))
        XCTAssertEqual(m.handle(.windowReady), [.moveToTargetWindow(animated: true)])
        XCTAssertEqual(m.phase, .intro)
        XCTAssertTrue(m.isOnTargetWindow)
        XCTAssertEqual(m.handle(.windowReady), [])
        XCTAssertEqual(m.handle(.segmentEnded(.intro)), [.play(.outro, looping: false)])
    }

    func testIntroWithoutLoopAttachesWhilePlayingAndMovesOnlyOnce() {
        var m = machine(introOnly)
        _ = m.handle(.start(windowReady: false))
        XCTAssertEqual(m.handle(.windowReady), [.moveToTargetWindow(animated: true)])
        XCTAssertEqual(m.phase, .intro)
        XCTAssertTrue(m.isOnTargetWindow)
        XCTAssertEqual(m.handle(.waitTimedOut), [])
        XCTAssertEqual(m.handle(.loopCycleEnded), [])
        XCTAssertEqual(m.handle(.windowReady), [])
        XCTAssertEqual(m.handle(.segmentEnded(.intro)), [.play(.outro, looping: false)])
    }

    func testImmediateLoopExitStillFinishesAnAlreadyAttachedIntro() {
        var m = machine(full, loopExit: .immediate)
        _ = m.handle(.start(windowReady: false))
        XCTAssertEqual(m.handle(.windowReady), [.moveToTargetWindow(animated: true)])
        XCTAssertEqual(m.phase, .intro)
        XCTAssertTrue(m.isOnTargetWindow)
        XCTAssertEqual(m.handle(.loopCycleEnded), [])
        XCTAssertEqual(m.handle(.segmentEnded(.intro)), [.play(.outro, looping: false)])
    }

    func testWindowArrivingAfterSkipDoesNotAttach() {
        var m = machine(full)
        _ = m.handle(.start(windowReady: false))
        _ = m.handle(.skip)
        XCTAssertEqual(m.handle(.windowReady), [])
        XCTAssertEqual(m.phase, .fading)
        XCTAssertFalse(m.isOnTargetWindow)
        _ = m.handle(.fadeCompleted)
        XCTAssertEqual(m.handle(.windowReady), [])
        XCTAssertFalse(m.isOnTargetWindow)
    }

    func testImmediateLoopExitCutsToTheOutro() {
        var m = machine(full, loopExit: .immediate)
        _ = m.handle(.start(windowReady: false))
        _ = m.handle(.segmentEnded(.intro))
        XCTAssertEqual(m.handle(.windowReady), [.moveToTargetWindow(animated: true), .play(.outro, looping: false)])
        XCTAssertTrue(m.isOnTargetWindow)
        XCTAssertEqual(m.phase, .final)
        XCTAssertEqual(m.handle(.loopCycleEnded), [])
    }

    func testIntroWithoutLoopHoldsTheLastFrame() {
        var m = machine(introOnly)
        _ = m.handle(.start(windowReady: false))
        XCTAssertEqual(m.handle(.segmentEnded(.intro)), [.holdLastFrame])
        XCTAssertEqual(m.handle(.windowReady), [.moveToTargetWindow(animated: true), .play(.outro, looping: false)])
    }

    func testLoopOnlyPackStartsLooping() {
        var m = machine(loopOnly)
        XCTAssertEqual(m.handle(.start(windowReady: false)), [.showOnLaunchScreen, .play(.loop, looping: true)])
        XCTAssertEqual(m.handle(.windowReady), [.moveToTargetWindow(animated: true)])
        XCTAssertEqual(m.phase, .looping)
        XCTAssertTrue(m.isOnTargetWindow)
        XCTAssertEqual(m.handle(.loopCycleEnded), [.play(.outro, looping: false)])
    }

    func testSegmentedPackWithWindowAlreadyReadyGoesStraightToTheOutroOnTheWindow() {
        var m = machine(full)
        XCTAssertEqual(m.handle(.start(windowReady: true)), [.showOnTargetWindow, .play(.outro, looping: false)])
        XCTAssertTrue(m.isOnTargetWindow)
        XCTAssertEqual(m.handle(.segmentEnded(.intro)), [])
    }

    func testSingleVideoWaitsInvisiblyForTheWindow() {
        var m = machine(single)
        XCTAssertEqual(m.handle(.start(windowReady: false)), [])
        XCTAssertEqual(m.phase, .waitingForWindow)
        XCTAssertFalse(m.isOnTargetWindow)
        XCTAssertEqual(m.handle(.windowReady), [.showOnTargetWindow, .play(.video, looping: false)])
        XCTAssertTrue(m.isOnTargetWindow)
        XCTAssertEqual(m.handle(.segmentEnded(.video)), [.beginFade(duration: 0.4)], "end without handoff report still fades")
        XCTAssertEqual(m.handle(.fadeCompleted), [.close(.completed, wasVisible: true)])
    }

    func testTimeoutBeforeAnythingIsShownClosesWithoutAWindow() {
        var m = machine(single)
        _ = m.handle(.start(windowReady: false))
        XCTAssertEqual(m.handle(.waitTimedOut), [.close(.windowTimeout, wasVisible: false)])
    }

    func testTimeoutWhileCoveringTheLaunchFadesOut() {
        var m = machine(full)
        _ = m.handle(.start(windowReady: false))
        _ = m.handle(.segmentEnded(.intro))
        XCTAssertEqual(m.handle(.waitTimedOut), [.beginFade(duration: 0.4)])
        XCTAssertEqual(m.handle(.windowReady), [], "late window does not restart anything while fading")
        XCTAssertEqual(m.handle(.fadeCompleted), [.close(.windowTimeout, wasVisible: true)])
    }

    func testTimeoutAfterTheWindowIsReadyIsIgnored() {
        var m = machine(full)
        _ = m.handle(.start(windowReady: false))
        _ = m.handle(.windowReady)
        XCTAssertEqual(m.handle(.waitTimedOut), [])
    }

    func testSkipFadesQuicklyFromAnyVisiblePhase() {
        for steps: [PlaybackEvent] in [[], [.segmentEnded(.intro)], [.windowReady, .segmentEnded(.intro)]] {
            var m = machine(full)
            _ = m.handle(.start(windowReady: false))
            steps.forEach { _ = m.handle($0) }
            XCTAssertEqual(m.handle(.skip), [.beginFade(duration: PackDefaults.skipFadeDuration)], "\(steps)")
            XCTAssertEqual(m.handle(.skip), [])
            XCTAssertEqual(m.handle(.reachedHandoff), [])
            XCTAssertEqual(m.handle(.fadeCompleted), [.close(.skipped, wasVisible: true)])
        }
    }

    func testSkipWhileInvisiblyWaitingClosesImmediately() {
        var m = machine(single)
        _ = m.handle(.start(windowReady: false))
        XCTAssertEqual(m.handle(.skip), [.close(.skipped, wasVisible: false)])
    }

    func testInterruptionsCloseImmediatelyAndDecideFocus() {
        let cases: [(PlaybackEvent, PlaybackEndReason, Bool)] = [
            (.targetExited, .targetExited, false),
            (.userSwitched, .userSwitched, false),
            (.superseded, .superseded, false),
            (.failed("decode"), .failed("decode"), true),
        ]
        for (event, reason, focus) in cases {
            var m = machine(full)
            _ = m.handle(.start(windowReady: false))
            XCTAssertEqual(m.handle(event), [.close(reason, wasVisible: true)])
            XCTAssertEqual(reason.offersFocusToTarget, focus)
            XCTAssertEqual(m.handle(event), [])
        }
        var fading = machine(full)
        _ = fading.handle(.start(windowReady: false))
        _ = fading.handle(.skip)
        XCTAssertEqual(fading.handle(.targetExited), [.close(.targetExited, wasVisible: true)])
    }

    func testEventsBeforeStartAreIgnored() {
        var m = machine(full)
        for event: PlaybackEvent in [.windowReady, .segmentEnded(.intro), .loopCycleEnded, .reachedHandoff,
                                     .fadeCompleted, .skip, .waitTimedOut] {
            XCTAssertEqual(m.handle(event), [], "\(event)")
        }
        XCTAssertEqual(m.handle(.start(windowReady: false)), [.showOnLaunchScreen, .play(.intro, looping: false)])
        XCTAssertEqual(m.handle(.start(windowReady: true)), [], "second start ignored")
    }

    func testAutoPlayPolicy() {
        XCTAssertTrue(PlaybackPolicy.shouldAutoPlay(paused: false, reduceMotion: false, playDespiteReduceMotion: false))
        XCTAssertFalse(PlaybackPolicy.shouldAutoPlay(paused: true, reduceMotion: false, playDespiteReduceMotion: true))
        XCTAssertFalse(PlaybackPolicy.shouldAutoPlay(paused: false, reduceMotion: true, playDespiteReduceMotion: false))
        XCTAssertTrue(PlaybackPolicy.shouldAutoPlay(paused: false, reduceMotion: true, playDespiteReduceMotion: true))
    }
}
