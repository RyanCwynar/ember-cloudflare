// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EmberDesktop",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "EmberDesktop",
            // Shared is also compiled into the iOS app (iOS/project.yml); macOS holds the Mac's own screens.
            path: "Sources",
            sources: ["Shared", "macOS"],
            resources: [.copy("Resources/ember-logo.png")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "EmberDesktopTests",
            dependencies: ["EmberDesktop"],
            path: "Tests/EmberDesktopTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
