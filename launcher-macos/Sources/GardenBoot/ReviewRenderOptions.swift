import AppKit

enum ReviewRenderError: LocalizedError {
    case arguments(String)
    case bitmap
    var errorDescription: String? {
        switch self {
        case .arguments(let message): return message
        case .bitmap: return "无法生成离屏 PNG。"
        }
    }
}

struct ReviewRenderOptions {
    enum Content { case settings, icon }
    let content: Content
    let destination: URL
    let appearance: NSAppearance.Name?
    let page: SettingsPage
    let size: NSSize

    /// Parse before login-item handling and before constructing the application controller.
    static func parse(_ arguments: [String]) throws -> Self? {
        let settings = arguments.contains("--render-settings")
        let icon = arguments.contains("--render-menubar-icon")
        guard settings || icon || arguments.contains("--appearance") || arguments.contains("--page") || arguments.contains("--size") else { return nil }
        guard settings != icon else { throw ReviewRenderError.arguments("请仅选择一个 --render-settings 或 --render-menubar-icon。") }
        func value(_ flag: String) throws -> String {
            guard arguments.filter({ $0 == flag }).count == 1,
                  let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1),
                  !arguments[index + 1].hasPrefix("--"), !arguments[index + 1].isEmpty else {
                throw ReviewRenderError.arguments("\(flag) 后需要提供一个值。")
            }
            return arguments[index + 1]
        }
        guard Set(arguments).isDisjoint(with: ["--register-login", "--unregister-login", "--status", "--preview", "--settings"]) else {
            throw ReviewRenderError.arguments("离屏渲染不能与应用操作命令一起使用。")
        }
        if arguments.contains("--test-root") { _ = try value("--test-root") }
        var appearance: NSAppearance.Name?
        if arguments.contains("--appearance") {
            switch try value("--appearance") {
            case "light": appearance = .aqua
            case "dark": appearance = .darkAqua
            default: throw ReviewRenderError.arguments("--appearance 仅支持 light 或 dark。")
            }
        }
        var page = SettingsPage.animation
        if arguments.contains("--page") {
            guard settings, let requested = SettingsPage(rawValue: try value("--page")) else {
                throw ReviewRenderError.arguments("--page 仅用于设置渲染，支持 overview、animation、targets、playback、sound、display、presets。")
            }
            page = requested
        }
        var size = NSSize(width: 960, height: 640)
        if arguments.contains("--size") {
            let pieces = try value("--size").split(separator: "x", omittingEmptySubsequences: false)
            guard settings, pieces.count == 2, let width = Int(pieces[0]), let height = Int(pieces[1]),
                  (820...1600).contains(width), (560...1200).contains(height) else {
                throw ReviewRenderError.arguments("--size 仅用于设置渲染，格式如 820x560，范围为 820–1600 × 560–1200。")
            }
            size = NSSize(width: width, height: height)
        }
        return Self(content: settings ? .settings : .icon,
                    destination: URL(fileURLWithPath: try value(settings ? "--render-settings" : "--render-menubar-icon")),
                    appearance: appearance, page: page, size: size)
    }
}

