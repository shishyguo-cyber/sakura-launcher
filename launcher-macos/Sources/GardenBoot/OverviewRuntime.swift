import Foundation
import GardenBootCore

struct OverviewTarget: Identifiable { let id: String; let name: String }
struct OverviewSnapshot {
    var targets: [OverviewTarget]
    var selectedID: String?
    var reason: PlaybackStatusReason
    var connected = true
}

struct UpdateOverview {
    var version: String
    var automatic: Bool
    var checking = false
    var message = "尚未检查更新"
    var availableVersion: String?
    var connected = true
}

@MainActor protocol OverviewRuntime: AnyObject {
    func updateOverview() -> UpdateOverview
    func checkForUpdatesFromSettings()
    func setAutomaticUpdates(_ value: Bool) throws
    func openUpdateDownload()
    var welcomeDismissed: Bool { get }
    func setWelcomeDismissed(_ value: Bool) throws
    func overview(targetID: String?) -> OverviewSnapshot
    func performOverviewAction(_ action: String) throws
    /// "测试一下" for a saved, enabled target (COMPATIBILITY.md §1); throws a user-facing message otherwise.
    func testTarget(_ id: String) throws
    /// "从视频创建" (PACK-FROM-VIDEO.md): build a single-video pack and import it through the normal checks.
    func createPack(fromVideo video: URL, name: String) throws
}
