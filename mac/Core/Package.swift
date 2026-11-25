// swift-tools-version: 6.0
// The parts of OwnVoice Meet that are plain logic (no audio, no UI): prompts, Taiwan Chinese,
// caption bookkeeping, the Gemini Live messages and the request formats. Kept at macOS 13 so its
// tests run on CI machines older than the app's macOS 26.
import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.macOS(.v13)],
    products: [.library(name: "OwnVoiceCore", targets: ["OwnVoiceCore"])],
    targets: [
        .target(name: "OwnVoiceCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "OwnVoiceCoreTests", dependencies: ["OwnVoiceCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
