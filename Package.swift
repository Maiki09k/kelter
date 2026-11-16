// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Kelter",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "Kelter",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CryptoKit")
            ]
        ),
        .testTarget(name: "KelterTests", dependencies: ["Kelter"])
    ],
    // Swift 5 mode keeps Process handling simple; all UI state lives on the main actor anyway.
    swiftLanguageModes: [.v5]
)
