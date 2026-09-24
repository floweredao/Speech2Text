// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Speech2Text",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Speech2Text", targets: ["Speech2Text"])],
    targets: [
        .target(name: "DictationSpeech"),
        .executableTarget(name: "Speech2Text", dependencies: ["DictationSpeech"]),
        .testTarget(name: "DictationSpeechTests", dependencies: ["DictationSpeech"]),
        .testTarget(name: "Speech2TextTests", dependencies: ["Speech2Text"])
    ],
    swiftLanguageModes: [.v6]
)
