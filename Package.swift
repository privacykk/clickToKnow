// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClickToKnow",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "ClickToKnow",
            path: "Sources/ClickToKnow"
        )
    ]
)