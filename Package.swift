// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Speech2Text",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Speech2Text", targets: ["Speech2Text"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .target(name: "DictationSpeech"),
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
