// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KeoCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "KeoCore", targets: ["KeoCore"]),
    ],
    targets: [
        .target(
            name: "CZip",
            path: "Sources/CZip",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(
            name: "KeoCore",
            dependencies: ["CZip"]
        ),
        .testTarget(
            name: "KeoCoreTests",
            dependencies: ["KeoCore"]
        ),
    ]
)
