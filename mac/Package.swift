// swift-tools-version: 6.0
// OwnVoice Meet for the Mac: a native SwiftUI app for Apple Silicon on macOS 26 or later.
// scripts/build-app.sh turns the executable into OwnVoice Meet.app and a .dmg; it first fetches
// sherpa-onnx's static libraries (scripts/fetch-sherpa.sh), which the speaker detection links.
import Foundation
import PackageDescription

let sherpaLib = Context.packageDirectory + "/vendor/sherpa-onnx/lib"
let sherpaLibraries = [
    "sherpa-onnx-c-api", "sherpa-onnx-core", "sherpa-onnx-cxx-api", "sherpa-onnx-fst", "sherpa-onnx-fstfar",
    "sherpa-onnx-kaldifst-core", "sherpa-onnx-portaudio_static", "kaldi-decoder-core", "kaldi-hmm-gmm-core",
    "kaldi-native-fbank-core", "kaldi-native-io-core", "kissfft-float", "onnxruntime", "ssentencepiece_core", "utf8proc",
]

let package = Package(
    name: "OwnVoiceMeet",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "Core")],
    targets: [
        .target(
            name: "CSherpaOnnx",
            path: "Sources/CSherpaOnnx",
            linkerSettings: [.unsafeFlags(["-L", sherpaLib])]
                + sherpaLibraries.map { .linkedLibrary($0) }
                + [.linkedLibrary("c++")]
                + ["Foundation", "CoreFoundation", "CoreML", "Accelerate", "CoreAudio", "AudioToolbox", "AudioUnit"].map { .linkedFramework($0) }
        ),
        .executableTarget(
            name: "OwnVoiceMeet",
            dependencies: [.product(name: "OwnVoiceCore", package: "Core"), "CSherpaOnnx"],
            path: "Sources/OwnVoiceMeet",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
