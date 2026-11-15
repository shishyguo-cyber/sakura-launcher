// swift-tools-version: 5.9
// Sakura for macOS. Module names keep the internal "GardenBoot" prefix so existing settings and logs stay valid.
import PackageDescription

let coreModule = "GardenBootCore"
let appModule = "GardenBoot"

let package = Package(
    name: appModule,
    platforms: [.macOS(.v13)],
    products: [
        // The menu-bar app; scripts/build.sh wraps this executable into Sakura.app.
        .executable(name: appModule, targets: [appModule])
    ],
    targets: [
        // Platform-neutral rules shared with the Windows port through launcher-spec/conformance.
        .target(name: coreModule, path: "Sources/\(coreModule)"),
        // AppKit / SwiftUI / AVFoundation layer.
        .executableTarget(name: appModule, dependencies: [.target(name: coreModule)], path: "Sources/\(appModule)"),
        .testTarget(name: "\(coreModule)Tests", dependencies: [.target(name: coreModule)], path: "Tests/\(coreModule)Tests"),
    ]
)
