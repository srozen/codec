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
        .executableTarget(
            name: "Codec",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/Codec",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
