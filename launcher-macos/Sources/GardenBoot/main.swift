import AppKit
import ServiceManagement

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
