// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VoiceQuestion",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic (no AppKit): models, IPC, answer matching, VAD state machine, app-specific parsers.
        .target(name: "VQCore", path: "Sources/VQCore"),
        // Menu-bar agent + CLI (`VoiceQuestion hook claude`, `ask`, `test`, `doctor`, ...).
        .executableTarget(name: "VoiceQuestion", dependencies: ["VQCore"], path: "Sources/VoiceQuestion"),
        .testTarget(name: "VQCoreTests", dependencies: ["VQCore"], path: "Tests/VQCoreTests"),
        .testTarget(name: "VQUITests", dependencies: ["VoiceQuestion", "VQCore"], path: "Tests/VQUITests"),
    ]
)
