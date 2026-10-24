// swift-tools-version: 6.2
import PackageDescription
import Foundation

// scripts/fetch-wake-model.sh puts the pinned sherpa-onnx static libraries here before a build or test run.
let sherpaLibraries = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Vendor/sherpa-onnx/lib").path

let package = Package(
    name: "Speech2Text",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Speech2Text", targets: ["Speech2Text"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .target(
            name: "CSherpaOnnx",
            linkerSettings: [
                .unsafeFlags(["-L", sherpaLibraries]),
                .linkedLibrary("sherpa-onnx-c-api"), .linkedLibrary("sherpa-onnx-core"),
                .linkedLibrary("kaldi-decoder-core"), .linkedLibrary("sherpa-onnx-kaldifst-core"),
                .linkedLibrary("sherpa-onnx-fstfar"), .linkedLibrary("sherpa-onnx-fst"),
                .linkedLibrary("kaldi-native-fbank-core"), .linkedLibrary("kissfft-float"),
                .linkedLibrary("ssentencepiece_core"), .linkedLibrary("utf8proc"), .linkedLibrary("onnxruntime"),
                .linkedLibrary("c++")
            ]
        ),
        .target(name: "DictationSpeech", dependencies: ["CSherpaOnnx"]),
        .executableTarget(
            name: "Speech2Text",
            dependencies: ["DictationSpeech", .product(name: "Sparkle", package: "Sparkle")],
            // The app bundle embeds Sparkle.framework in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "DictationSpeechTests", dependencies: ["DictationSpeech"]),
        .testTarget(name: "Speech2TextTests", dependencies: ["Speech2Text"])
    ],
    swiftLanguageModes: [.v6]
)
