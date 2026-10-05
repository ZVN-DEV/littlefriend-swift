// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LittleFriend",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "LittleFriend", targets: ["LittleFriend"]),
    ],
    targets: [
        .target(name: "LittleFriend"),
        .testTarget(name: "LittleFriendTests", dependencies: ["LittleFriend"]),
    ],
    swiftLanguageVersions: [.v5]
)
