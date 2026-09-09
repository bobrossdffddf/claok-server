// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CloakKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CloakKit", targets: ["CloakKit"])
    ],
    targets: [
        .target(
            name: "CloakKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CloakKitTests",
            dependencies: ["CloakKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
