import AppKit
import GardenBootCore

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    /// P-011: timed close/reopen (a menu-bar style app), minimize/restore and hide/unhide, in seconds after the first window.
    func scheduleWindowChanges(_ args: [String]) {
        func after(_ flag: String, _ action: @escaping () -> Void) {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count, let seconds = Double(args[i + 1]), seconds.isFinite, seconds > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                action()
                print("fixture-\(flag.dropFirst(2))"); fflush(stdout)
            }
        }
        after("--close-after") { [self] in window?.close(); window = nil }
        after("--reopen-after") { [self] in
            let next = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 800, height: 500),
                                styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            next.title = "GardenBoot 受控测试窗口（重新打开）"
            next.isReleasedWhenClosed = false
            window = next
            if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
            next.makeKeyAndOrderFront(nil)
        }
        after("--minimize-after") { [self] in window?.miniaturize(nil) }
        after("--restore-after") { [self] in window?.deminiaturize(nil) }
        after("--hide-after") { NSApp.hide(nil) }
        after("--unhide-after") { NSApp.unhide(nil) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("fixture-ready")
        fflush(stdout)
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--window-delay"), index + 1 < args.count,
           let delay = Double(args[index + 1]) {
            fputs("fixture-scheduled pid=\(ProcessInfo.processInfo.processIdentifier) time=\(Date().timeIntervalSince1970) delay=\(delay)\n", stderr)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
                fputs("fixture-timer-fired time=\(Date().timeIntervalSince1970)\n", stderr)
                let window = NSWindow(contentRect: NSRect(x: 180, y: 180, width: 800, height: 500),
                                      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
                window.title = "GardenBoot 受控测试窗口"
                window.isReleasedWhenClosed = false
                // P-004: use the outer frame's ratio (including title bar), matching WindowPicker.
                if let i = args.firstIndex(of: "--frame-size"), i + 2 < args.count,
                   let width = Double(args[i + 1]), let height = Double(args[i + 2]),
                   width.isFinite, height.isFinite, width >= 200, height >= 200 {
                    window.setFrame(NSRect(x: 180, y: 180, width: width, height: height), display: false)
                }
                window.contentView?.wantsLayer = true
                window.contentView?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                self.window = window
                if #available(macOS 14, *) { NSApp.activate() }
                else { NSApp.activate(ignoringOtherApps: true) }
                window.makeKeyAndOrderFront(nil)
                if let i = args.firstIndex(of: "--resize-after"), i + 3 < args.count,
                   let seconds = Double(args[i + 1]), let width = Double(args[i + 2]), let height = Double(args[i + 3]),
                   seconds.isFinite, seconds > 0, width.isFinite, height.isFinite, width >= 200, height >= 200 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: width, height: height)), display: true)
                        print("fixture-window-resized width=\(width) height=\(height)")
                        fflush(stdout)
                    }
                }
                print("fixture-window-ready")
                fflush(stdout)
                self.scheduleWindowChanges(args)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    let frame = WindowPicker.currentMainWindowFrame(of: ProcessInfo.processInfo.processIdentifier,
                        primaryDisplayHeight: NSScreen.screens.first?.frame.height ?? 0)
                    fputs("fixture-window visible=\(window.isVisible) active=\(NSApp.isActive) on-active-space=\(window.isOnActiveSpace) frame=\(String(describing: frame))\n", stderr)
                }
            }
        }
    }
}
// Run the production AVFoundation probe without creating an NSApplication.
// Failures here are distinct from GUI-session availability failures below.
if let index = CommandLine.arguments.firstIndex(of: "--pack-check"), index + 2 < CommandLine.arguments.count {
    let demo = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    let root = URL(fileURLWithPath: CommandLine.arguments[index + 2])
    Task {
        do {
            let fm = FileManager.default
            let library = PackLibrary(root: root.appendingPathComponent("Packs"))
            for segment in ["intro", "loop", "outro"] {
                let info = try await PackMedia.probe(demo.appendingPathComponent("\(segment).mp4"))
                guard info.hasVideo, abs(info.duration - 1.5) < 0.05 else { throw CocoaError(.fileReadCorruptFile) }
            }
            let installed = try await library.installIfMissing(bundled: demo, probe: PackMedia.probe, imageProbe: PackMedia.imageProbe)
            guard let installed, installed.id == "demo-garden" else { throw CocoaError(.fileReadCorruptFile) }
            let preserved = try Data(contentsOf: installed.url(for: "intro.mp4"))
            let second = try await library.installIfMissing(bundled: demo, probe: PackMedia.probe, imageProbe: PackMedia.imageProbe)
            guard second == nil else { throw CocoaError(.fileWriteFileExists) }
            let bad = root.appendingPathComponent("bad-source")
            try fm.copyItem(at: demo, to: bad)
            try Data("invalid media".utf8).write(to: bad.appendingPathComponent("intro.mp4"))
            var rejected = false
            do { _ = try await library.importPack(from: bad, probe: PackMedia.probe, imageProbe: PackMedia.imageProbe) }
            catch { rejected = true }
            guard rejected, try Data(contentsOf: installed.url(for: "intro.mp4")) == preserved else {
                throw CocoaError(.fileWriteUnknown)
            }
            let invalidCover = root.appendingPathComponent("invalid-cover")
            try fm.copyItem(at: demo, to: invalidCover)
            try Data("invalid image".utf8).write(to: invalidCover.appendingPathComponent("cover.png"))
            guard try await !PackMedia.imageProbe(invalidCover.appendingPathComponent("cover.png")) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            rejected = false
            do { _ = try await library.importPack(from: invalidCover, probe: PackMedia.probe, imageProbe: PackMedia.imageProbe) }
            catch PackError.invalidCover { rejected = true }
            guard rejected, try Data(contentsOf: installed.url(for: "cover.png")) == Data(contentsOf: demo.appendingPathComponent("cover.png")) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let legacy = root.appendingPathComponent("startup.mp4")
            try preserved.write(to: legacy)
            let migrated = try await library.migrateLegacyVideo(legacy, probe: PackMedia.probe)
            guard migrated?.id == "imported-startup", migrated?.layout.finalSegment == .video,
                  try Data(contentsOf: legacy) == preserved else { throw CocoaError(.fileReadCorruptFile) }
            print("pack-check passed: AVFoundation three segments; install once; invalid video/cover imports preserve; ImageIO cover decode/copy; legacy migration preserves source")
            exit(0)
        } catch {
            fputs("pack-check failed: \(error)\n", stderr)
            exit(1)
        }
    }
    dispatchMain()
}
let app = NSApplication.shared
let delegate = FixtureDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { app.terminate(nil) }
app.run()
