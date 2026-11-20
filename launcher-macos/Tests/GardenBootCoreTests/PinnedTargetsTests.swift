import XCTest
@testable import GardenBootCore

final class PinnedTargetsTests: XCTestCase {
    private func target(_ name: String, _ animation: String?, enabled: Bool = true) -> ApplicationTarget {
        ApplicationTarget(id: name.lowercased(), name: name, enabled: enabled, animation: animation, bundleID: "com.example." + name)
    }

    func testOnlyEnabledAppsPinnedToAnotherAnimationAreReported() {
        let targets = [target("ChatGPT", "raiden-garden"), target("Notes", nil), target("Mail", "sakura-greeting"),
                       target("Off", "raiden-garden", enabled: false)]
        XCTAssertEqual(PinnedTargets.unaffected(activeID: "sakura-greeting", targets: targets).map(\.name), ["ChatGPT"])
        XCTAssertEqual(PinnedTargets.unaffected(activeID: "raiden-garden", targets: targets).map(\.name), ["Mail"])
        XCTAssertTrue(PinnedTargets.unaffected(activeID: nil, targets: [target("Notes", nil)]).isEmpty)
    }

    func testFollowingCurrentClearsEveryChoiceAndKeepsTheRest() {
        let targets = [target("ChatGPT", "raiden-garden"), target("Off", "x", enabled: false)]
        let cleared = PinnedTargets.followingCurrent(targets)
        XCTAssertEqual(cleared.map(\.animation), [nil, nil])
        XCTAssertEqual(cleared.map(\.enabled), [true, false])
        XCTAssertEqual(cleared.map(\.id), targets.map(\.id))
    }

    func testHintNamesAppsAndPacks() {
        let names = ["raiden-garden": "雷电将军 · 花园", "demo-garden": "花园 · 占位示例"]
        let name = { (id: String) in names[id] ?? id }
        XCTAssertNil(PinnedTargets.hint([], packName: name))
        XCTAssertEqual(PinnedTargets.hint([target("ChatGPT", "raiden-garden")], packName: name),
                       "ChatGPT 单独指定了「雷电将军 · 花园」，不跟随切换。")
        XCTAssertEqual(PinnedTargets.hint([target("A", "raiden-garden"), target("B", "demo-garden"), target("C", "gone")], packName: name),
                       "A 单独指定了「雷电将军 · 花园」，B 单独指定了「花园 · 占位示例」，另有 1 个应用也单独指定了动画，不跟随切换。")
    }
}
