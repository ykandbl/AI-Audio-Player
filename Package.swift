// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HistoryPodcastPlayer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "HistoryPodcastPlayer", targets: ["HistoryPodcastPlayer"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "HistoryPodcastPlayer",
            dependencies: ["WhisperKit"],
            path: "Sources"
        )
    ]
)
