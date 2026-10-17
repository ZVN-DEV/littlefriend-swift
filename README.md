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

## Session replay (optional, iOS)

`LittleFriendReplay` is a separate product in the same package. It records masked, static
wireframes of your screens plus taps, keyed by the same journey session as analytics, so a
recording can be watched next to its session in the dashboard. Apps that only add the
`LittleFriend` product carry no view capture, masking or replay transport code at all.

Add both products, turn replay on for the project in the dashboard (journey mode required), and
start the add-on once, before or after `LittleFriend.start(key:)`:

```swift
import LittleFriend
import LittleFriendReplay

LittleFriend.start(key: "lf_YOUR_SITE_KEY")
LittleFriendReplay.start()
```

`LittleFriendReplay.stop()` stops recording and discards anything not yet sent.
`LittleFriendReplay.flush()` sends buffered taps right away.

Recording only happens while all of these hold: the project's replay config is on, the app is in
journey mode with a live session, the session is sampled in at the project's sample rate, and the
current route is not in the project's excluded routes. It stops on session rotation, consent
withdrawal, a replay-off config, an excluded route, and on `LittleFriend.optOut()`, which cancels
capture and clears pending chunks before it returns.

Privacy, enforced on the device before anything is sent, and again by the collector:

- Every text run is masked character for character. Layout keeps its shape, words never leave.
- Input values, checked and selected state, chosen options, screenshots, image and media
  content, accessibility labels and native view identifiers are never read. Text fields, pickers,
  switches, images, web views and other value-holding or custom-drawn views are recorded as
  empty boxes of their size.
- Web unmask selectors and full-capture overrides never unmask native content.
- Chunks live in a bounded in-memory queue only. Nothing is written to disk for replay, so a
  recording is lost when the process ends rather than stored on the device.

Limitations: this is masked static wireframe replay, not full-fidelity native animation. Each
screen appearance is captured once as positioned boxes (UIKit directly, SwiftUI through its
hosting view), later layout changes on the same screen are not re-recorded, and text drawn
straight into layers, including most SwiftUI text, appears as empty boxes. Taps are recorded in
window points against the captured boxes. macOS builds link the product but never record.

## About this repository

This repository is a mirror of `sdks/swift` in the Little Friend monorepo, published with each release. Changes are made there.

## License

MIT
