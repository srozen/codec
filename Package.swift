// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Codec",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Codec", targets: ["Codec"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        // Platform logic with no UI: layouts, shell integration, policies, system sampling, preferences.
        .target(
            name: "CodecCore",
            path: "Sources/CodecCore"
        ),
        // AppKit and SwiftUI: windows, panes, chrome, settings.
        .target(
            name: "CodecUI",
            dependencies: [
                "CodecCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/CodecUI"
        ),
        .executableTarget(
            name: "Codec",
            dependencies: ["CodecUI"],
            path: "Sources/Codec"
        ),
        .testTarget(
            name: "CodecCoreTests",
            dependencies: [
                "CodecCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Tests/CodecCoreTests"
        ),
        .testTarget(
            name: "CodecUITests",
            dependencies: ["CodecUI", "CodecCore"],
            path: "Tests/CodecUITests"
        ),
    ]
)
