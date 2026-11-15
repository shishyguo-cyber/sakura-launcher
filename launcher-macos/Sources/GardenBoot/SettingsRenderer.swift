import AppKit
import SwiftUI
import GardenBootCore

@MainActor enum SettingsRenderer {
    nonisolated static func renderIcon(to destination: URL) throws {
        guard let bitmap = FlowerIcon.image().representations.first as? NSBitmapImageRep,
              let data = bitmap.representation(using: .png, properties: [:]) else { throw ReviewRenderError.bitmap }
        try data.write(to: destination, options: .atomic)
    }

    static func render(_ options: ReviewRenderOptions) async throws {
        if options.content == .icon {
            try renderIcon(to: options.destination)
            return
        }
        if let name = options.appearance { NSApp.appearance = NSAppearance(named: name) }
        var warning = ""
        var settings: ExperienceSettings
        do { settings = try ExperienceStore(directory: Support.root).load() }
        catch { settings = .init(); warning = error.localizedDescription }
        if options.page == .targets {
            settings.targets = [
                // Placeholder bundle ids: rendered pages (used in public docs) show the generic app glyph,
                // never another company's app icon.
                ApplicationTarget(id: "default-codex", name: "ChatGPT", bundleID: "sample.render.chatgpt"),
                ApplicationTarget(id: "sample-safari", name: "Safari", animation: Support.demoID, bundleID: "sample.render.safari")
            ]
        }
        var playbackState = PlaybackStateStore(directory: Support.root).load()
        if options.page == .targets {
            settings.targets[1].playOnReappear = true
            playbackState.targets["default-codex", default: .init()].compat = .init(verdict: .good, windowSeconds: 1.8, at: 0)
            playbackState.targets["sample-safari", default: .init()].compat = .init(verdict: .alreadyRunning, windowSeconds: nil, at: 0)
        }
        let editor = ExperienceEditor(pack: nil, settings: settings, warning: warning,
            playbackState: playbackState,
            onImport: {}, onSelect: { _ in }, onRemove: { _ in }, onResetPlayback: {}, onSave: { _ in }, onPreview: { _, _ in })
        await editor.reloadLibrary()
        let size = options.size
        let view = NSHostingView(rootView: ExperienceSettingsView(editor: editor, loadLibrary: false, page: options.page))
        view.frame = NSRect(origin: .zero, size: size)
        // An unordered backing window supplies native control appearance and layout.
        // It is never shown, activated or captured from the screen.
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        let appearance = options.appearance.flatMap(NSAppearance.init(named:)) ?? NSApp.effectiveAppearance
        window.appearance = appearance
        view.appearance = appearance
        view.layoutSubtreeIfNeeded()
        // Allow SwiftUI's thumbnail tasks (including the bounded first-frame fallback) to settle.
        try await Task.sleep(nanoseconds: 2_200_000_000)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: Int(size.width * 2) * 4, bitsPerPixel: 32) else { throw ReviewRenderError.bitmap }
        bitmap.size = size
        appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw ReviewRenderError.bitmap }
        try data.write(to: options.destination, options: .atomic)
        withExtendedLifetime(window) {}
    }
}
