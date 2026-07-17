// swift-tools-version:5.10
import PackageDescription

// Complete strict-concurrency checking on every target: the app leans on
// @MainActor isolation and cross-thread stores, so Sendable/isolation
// violations must be compiler-verified, not convention.
let swiftSettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency")
]

let package = Package(
    name: "AskMail",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AskMailCore", targets: ["AskMailCore"]),
        .executable(name: "askmail", targets: ["AskMailApp"]),
        .executable(name: "AskMailParserXPC", targets: ["AskMailParserXPC"]),
    ],
    targets: [
        .target(
            name: "AskMailCore",
            swiftSettings: swiftSettings,
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "AskMailApp",
            dependencies: ["AskMailCore"],
            swiftSettings: swiftSettings
        ),
        // Sandboxed XPC service (hardening H-6): all untrusted .emlx/MIME/
        // HTML/PDF parsing runs here, isolated from the main app's Full Disk
        // Access and Keychain access. Packaged into AskMail.app's
        // Contents/XPCServices by Packaging/build-app.sh — never run
        // directly. See docs/hardening.md and Sources/AskMailParserXPC.
        .executableTarget(
            name: "AskMailParserXPC",
            dependencies: ["AskMailCore"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AskMailCoreTests",
            dependencies: ["AskMailCore"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AskMailAppTests",
            dependencies: ["AskMailApp"],
            swiftSettings: swiftSettings
        ),
    ]
)
