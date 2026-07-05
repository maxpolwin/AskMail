// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AskMail",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AskMailCore", targets: ["AskMailCore"]),
        .executable(name: "askmail", targets: ["AskMailApp"]),
    ],
    targets: [
        .target(
            name: "AskMailCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "AskMailApp",
            dependencies: ["AskMailCore"]
        ),
        .testTarget(
            name: "AskMailCoreTests",
            dependencies: ["AskMailCore"]
        ),
    ]
)
