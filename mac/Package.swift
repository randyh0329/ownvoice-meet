// swift-tools-version: 6.0
// OwnVoice Meet for the Mac: a native SwiftUI app for Apple Silicon on macOS 26 or later.
// scripts/build-app.sh turns the executable into OwnVoice Meet.app and a .dmg.
import PackageDescription

let package = Package(
    name: "OwnVoiceMeet",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "Core")],
    targets: [
        .executableTarget(
            name: "OwnVoiceMeet",
            dependencies: [.product(name: "OwnVoiceCore", package: "Core")],
            path: "Sources/OwnVoiceMeet",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
