// swift-tools-version:5.10
import PackageDescription

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
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "AskMailApp",
            dependencies: ["AskMailCore"]
        ),
        // Sandboxed XPC service (hardening H-6): all untrusted .emlx/MIME/
        // HTML/PDF parsing runs here, isolated from the main app's Full Disk
        // Access and Keychain access. Packaged into AskMail.app's
        // Contents/XPCServices by Packaging/build-app.sh — never run
        // directly. See docs/hardening.md and Sources/AskMailParserXPC.
        .executableTarget(
            name: "AskMailParserXPC",
            dependencies: ["AskMailCore"]
        ),
        .testTarget(
            name: "AskMailCoreTests",
            dependencies: ["AskMailCore"]
        ),
        .testTarget(
            name: "AskMailAppTests",
            dependencies: ["AskMailApp"]
        ),
    ]
)
