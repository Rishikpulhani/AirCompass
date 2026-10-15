// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AirCompass",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "AirCompass", targets: ["AirCompass"]),
        // Shared by the Mac app and the iOS/iPadOS companion (linked from its Xcode project).
        .library(name: "AirCompassCore", targets: ["AirCompassCore"]),
    ],
    targets: [
        // C declarations for the private MultitouchSupport.framework. Symbols are
        // resolved at runtime with dlopen/dlsym, so nothing links against the
        // private framework and the app degrades gracefully when it is missing.
        .target(name: "CMultitouchSupport"),

        // Cross-platform engine: geometry, wire protocol, AWDL networking,
        // transfers, acoustic positioning, compass UI. macOS-only pieces
        // (trackpad hook, Finder bridge) are compiled under #if os(macOS).
        .target(
            name: "AirCompassCore",
            dependencies: [
                .target(name: "CMultitouchSupport", condition: .when(platforms: [.macOS])),
            ],
            linkerSettings: [
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("ApplicationServices", .when(platforms: [.macOS])),
                .linkedFramework("Carbon", .when(platforms: [.macOS])),
                .linkedFramework("UIKit", .when(platforms: [.iOS])),
            ]
        ),

        // Menu-bar agent that wires the engine together.
        .executableTarget(
            name: "AirCompass",
            dependencies: ["AirCompassCore"]
        ),

        .testTarget(
            name: "AirCompassCoreTests",
            dependencies: ["AirCompassCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
