// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LittleFriend",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "LittleFriend", targets: ["LittleFriend"]),
        // Optional add-on: masked static wireframe replay for iOS. The core product carries no
        // view capture, masking or replay transport code.
        .library(name: "LittleFriendReplay", targets: ["LittleFriendReplay"]),
    ],
    targets: [
        .target(name: "LittleFriend"),
        .target(name: "LittleFriendReplay", dependencies: ["LittleFriend"]),
        .testTarget(name: "LittleFriendTests", dependencies: ["LittleFriend"]),
        // UIKit and SwiftUI on a device: `xcodebuild test -scheme LittleFriend` with an iOS Simulator
        // destination. Empty on macOS.
        .testTarget(name: "LittleFriendUIKitTests", dependencies: ["LittleFriend"]),
        // Replay logic runs on macOS; its UIKit serialization tests compile in only where UIKit
        // exists and run under the same simulator invocation as LittleFriendUIKitTests.
        .testTarget(
            name: "LittleFriendReplayTests",
            dependencies: ["LittleFriendReplay", "LittleFriend"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
