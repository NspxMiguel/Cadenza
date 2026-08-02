// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Cadenza",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "Cadenza", path: "Sources/Cadenza"),
        .executableTarget(name: "MusicKitProbe", path: "Sources/MusicKitProbe"),
    ]
)
