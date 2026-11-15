import AppKit
import GardenBootCore

/// Forwards workspace launch, quit and activation notifications to the controller.
@MainActor
final class ApplicationMonitor {
    var onLaunch: ((NSRunningApplication) -> Void)?
    var onTerminate: ((NSRunningApplication) -> Void)?
    var onActivate: ((NSRunningApplication) -> Void)?
    private var tokens: [NSObjectProtocol] = []

    func start() {
        stop()
        let center = NSWorkspace.shared.notificationCenter
        let routes: [(Notification.Name, (ApplicationMonitor) -> ((NSRunningApplication) -> Void)?)] = [
            (NSWorkspace.didLaunchApplicationNotification, { $0.onLaunch }),
            (NSWorkspace.didTerminateApplicationNotification, { $0.onTerminate }),
            (NSWorkspace.didActivateApplicationNotification, { $0.onActivate }),
        ]
        for (name, handler) in routes {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated {
                    guard let self else { return }
                    handler(self)?(app)
                }
            })
        }
    }

    func stop() {
        tokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        tokens.removeAll()
    }

    /// The target's main window in AppKit coordinates, or nil while it has none on screen.
    static func mainWindowFrame(pid: pid_t) -> CGRect? {
        WindowPicker.currentMainWindowFrame(of: pid, primaryDisplayHeight: Support.primaryDisplayHeight)
    }
}
