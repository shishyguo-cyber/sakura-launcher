import AppKit
import CryptoKit
import GardenBootCore

/// Process-wide locations and small helpers shared by the controller and the overlay.
enum Support {
    /// `--test-root DIR` keeps tests out of the user's real Application Support folder.
    static let root: URL = {
        if let custom = argument(after: "--test-root") { return URL(fileURLWithPath: custom, isDirectory: true) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("GardenBoot", isDirectory: true)
    }()
    /// Test roots also isolate the existing switches and current-pack preference.
    static let defaults: UserDefaults = {
        guard argument(after: "--test-root") != nil else { return .standard }
        let key = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return UserDefaults(suiteName: "local.gardenboot.test.\(key)")!
    }()

    /// Where v1 kept its single imported video; migrated into a pack on launch, never deleted.
    static let media = root.appendingPathComponent("startup.mp4")
    static let library = PackLibrary(root: root.appendingPathComponent("Packs", isDirectory: true))
    static let demoID = "demo-garden"
    static let events = EventLog(directory: root)

    static func log(_ event: String) {
        events.write(event)
    }

    static func clockTime(_ unix: Double) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: unix))
    }

    /// Brings the launcher forward, e.g. for the pack chooser. The overlay panel itself does not need it.
    @MainActor static func requestFocus() {
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
        }
    }

    /// The screen under the pointer — usually where the Dock icon or Spotlight result was clicked.
    @MainActor static var screenUnderPointer: NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSPointInRect(pointer, $0.frame) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Height of the display holding the menu bar; window-server coordinates flip around it.
    @MainActor static var primaryDisplayHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }
}

func argument(after flag: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
    return args[index + 1]
}
