import CoreGraphics
import Foundation

/// One on-screen window as reported by the window server (top-left-origin coordinates).
public struct WindowRecord: Equatable, Sendable {
    public let ownerPID: Int32
    public let layer: Int
    public let opacity: Double
    public let bounds: CGRect

    public init(ownerPID: Int32, layer: Int, opacity: Double, bounds: CGRect) {
        self.ownerPID = ownerPID
        self.layer = layer
        self.opacity = opacity
        self.bounds = bounds
    }

    /// Reads one entry of `CGWindowListCopyWindowInfo`; nil when a required field is missing.
    public init?(windowInfo info: [String: Any]) {
        func number(_ key: CFString) -> NSNumber? { info[key as String] as? NSNumber }
        guard let pid = number(kCGWindowOwnerPID)?.int32Value,
              let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: boundsInfo) else { return nil }
        self.init(ownerPID: pid,
                  layer: number(kCGWindowLayer)?.intValue ?? Int.max,
                  opacity: number(kCGWindowAlpha)?.doubleValue ?? 1,
                  bounds: rect)
    }
}

/// Chooses the target app's main window from the window server list, without extra permissions.
public enum WindowPicker {
    /// Windows smaller than this are treated as splash screens, popovers or helpers.
    public static let minimumSize = CGSize(width: 240, height: 180)
    /// Windows fading in below this opacity are not considered shown yet.
    public static let minimumOpacity = 0.5

    /// The frontmost ordinary window of `pid` (the list is front-to-back), converted to AppKit's
    /// bottom-left-origin coordinates using the height of the primary display.
    public static func mainWindowFrame(of pid: Int32, in records: [WindowRecord], primaryDisplayHeight: CGFloat) -> CGRect? {
        let found = records.first { record in
            record.ownerPID == pid && record.layer == 0 && record.opacity >= minimumOpacity
                && record.bounds.width >= minimumSize.width && record.bounds.height >= minimumSize.height
        }
        guard let bounds = found?.bounds else { return nil }
        return CGRect(x: bounds.minX, y: primaryDisplayHeight - bounds.maxY, width: bounds.width, height: bounds.height)
    }

    /// Whether any of `pids` owns an ordinary window of main-window size in `records`
    /// (the full list includes minimized and other-Space windows; the on-screen list only visible ones).
    public static func hasMainWindow(pids: Set<Int32>, in records: [WindowRecord], requireOpaque: Bool) -> Bool {
        records.contains { record in
            pids.contains(record.ownerPID) && record.layer == 0 && (!requireOpaque || record.opacity >= minimumOpacity)
                && record.bounds.width >= minimumSize.width && record.bounds.height >= minimumSize.height
        }
    }

    /// Whether `pid` shows a window covering a whole display (native full screen, a presentation or a game);
    /// `displays` and the records share the window server's top-left-origin coordinates.
    public static func coversDisplay(pid: Int32, in records: [WindowRecord], displays: [CGRect]) -> Bool {
        records.contains { record in
            record.ownerPID == pid && record.layer >= 0 && record.opacity >= minimumOpacity
                && displays.contains { display in
                    abs(record.bounds.minX - display.minX) <= 1 && abs(record.bounds.minY - display.minY) <= 1
                        && abs(record.bounds.width - display.width) <= 1 && abs(record.bounds.height - display.height) <= 1
                }
        }
    }

    /// One window-server snapshot (geometry only; needs no screen-recording permission).
    public static func windows(options: CGWindowListOption) -> [WindowRecord] {
        (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []).compactMap(WindowRecord.init(windowInfo:))
    }

    /// Live query of the window server. Needs no screen-recording permission (only geometry is read).
    public static func currentMainWindowFrame(of pid: Int32, primaryDisplayHeight: CGFloat) -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        return mainWindowFrame(of: pid, in: raw.compactMap(WindowRecord.init(windowInfo:)),
                               primaryDisplayHeight: primaryDisplayHeight)
    }
}
