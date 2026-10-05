# Little Friend for iOS and macOS

Privacy-first analytics for Swift apps: screen views, events, goals and where visits came from, with no device identifiers and nothing that needs App Tracking Transparency. iOS 15 and later, macOS 12 and later, no dependencies.

The full guide, including the App Store privacy label answers, is at [littlefriend.io/docs/ios](https://littlefriend.io/docs/ios).

## Install

In Xcode, choose File, Add Package Dependencies, and enter `https://github.com/ZVN-DEV/littlefriend-swift`. Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/ZVN-DEV/littlefriend-swift", from: "0.1.0"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [.product(name: "LittleFriend", package: "littlefriend-swift")]
    ),
]
```

Add your app's bundle id under Settings, Project, Allowed apps in the dashboard. Batches from an app that is not listed are refused.

## Start

```swift
import LittleFriend
import SwiftUI

@main
struct ShopApp: App {
    init() {
        LittleFriend.start(key: "lf_YOUR_SITE_KEY")
    }

    var body: some Scene {
        WindowGroup {
            ContentView().lfDeepLinks()
        }
    }
}
```

## Screens and events

```swift
ProductDetail()
    .lfScreen("/products/:id", type: "product")

LittleFriend.screen("/orders/:id", type: "order")
LittleFriend.track("signup", props: ["plan": .string("pro")])
```

A screen is a route template such as `/orders/:id`, never a value. Goals are set up in the dashboard.

## About this repository

This repository is a mirror of `sdks/swift` in the Little Friend monorepo, published with each release. Changes are made there.

## License

MIT
