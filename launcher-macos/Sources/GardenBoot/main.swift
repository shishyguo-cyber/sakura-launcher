import AppKit
import ServiceManagement
import GardenBootCore

if let request = argument(after: "--apply-update") {
    do { try UpdateInstaller.apply(request: URL(fileURLWithPath: request)); exit(0) }
    catch let error as UpdateInstaller.RecoveryRequired {
        MainActor.assumeIsolated {
            let alert = NSAlert(); alert.messageText = "更新失败"; alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "去 GitHub 手动下载"); alert.addButton(withTitle: "关闭")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(URL(string: "https://github.com/shishyguo-cyber/sakura-launcher/releases")!) }
        }
        exit(1)
    }
    catch { exit(1) }
}


// Review commands never construct ApplicationController, monitor apps or register login items.
do {
    if let options = try ReviewRenderOptions.parse(CommandLine.arguments) {
        if options.content == .icon {
            try SettingsRenderer.renderIcon(to: options.destination)
            exit(EXIT_SUCCESS)
        }
        MainActor.assumeIsolated {
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited)
            Task { @MainActor in
                do { try await SettingsRenderer.render(options); exit(EXIT_SUCCESS) }
                catch {
                    FileHandle.standardError.write(Data("render: \(error.localizedDescription)\n".utf8))
                    exit(EXIT_FAILURE)
                }
            }
            application.run()
        }
        exit(EXIT_SUCCESS)
    }
} catch {
    FileHandle.standardError.write(Data("render: \(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}

/// Command-line login-item switches for scripts; they print the resulting status as JSON and exit.
let args = Set(CommandLine.arguments)
if !args.isDisjoint(with: ["--register-login", "--unregister-login", "--status"]) {
    let service = SMAppService.mainApp
    do {
        if args.contains("--register-login") { try service.register() }
        if args.contains("--unregister-login") { try service.unregister() }
        print(#"{"loginStatus":\#(service.status.rawValue)}"#)
        exit(EXIT_SUCCESS)
    } catch {
        FileHandle.standardError.write(Data("login item: \(error.localizedDescription)\n".utf8))
        exit(EXIT_FAILURE)
    }
}

MainActor.assumeIsolated {
    let controller = ApplicationController(testTargetIdentifier: argument(after: "--test-target"))
    let application = NSApplication.shared
    application.delegate = controller
    withExtendedLifetime(controller) { application.run() }
}
