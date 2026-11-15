import AppKit

/// Accessory apps need a responder-chain menu too, so text editing and window shortcuts work.
@MainActor
enum NativeMenu {
    static func install() {
        let bar = NSMenu()
        let application = NSMenu(title: "Sakura")
        let quit = NSMenuItem(title: "退出 Sakura", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        application.addItem(quit)
        let appItem = NSMenuItem(); appItem.submenu = application; bar.addItem(appItem)
        let edit = NSMenu(title: "编辑")
        for (title, selector, key) in [
            ("撤销", Selector(("undo:")), "z"),
            ("剪切", #selector(NSText.cut(_:)), "x"),
            ("复制", #selector(NSText.copy(_:)), "c"),
            ("粘贴", #selector(NSText.paste(_:)), "v"),
            ("全选", #selector(NSText.selectAll(_:)), "a")
        ] { edit.addItem(NSMenuItem(title: title, action: selector, keyEquivalent: key)) }
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        editItem.submenu = edit; bar.addItem(editItem)
        let windows = NSMenu(title: "窗口")
        windows.addItem(NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windows.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        windowItem.submenu = windows; bar.addItem(windowItem)
        NSApp.mainMenu = bar
        NSApp.windowsMenu = windows
    }
}
