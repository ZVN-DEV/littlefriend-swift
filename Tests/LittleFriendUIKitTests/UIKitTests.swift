#if canImport(UIKit) && !os(watchOS)
import SwiftUI
import UIKit
import XCTest
@testable import LittleFriend

/// SwiftUI modifiers, autoScreens, the app block and the lifecycle on a device, through the public
/// API: the process-wide SDK is started once, with the live host and bundle, a recording transport
/// and temporary storage. Each test reads the events sent after it began.
final class UIKitTests: XCTestCase {
    private static let recorder = Recorder()
    private static let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent("lf-uikit-\(UUID().uuidString)").appendingPathComponent("littlefriend")
    @MainActor private static var window: UIWindow?

    override class func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            var environment = Environment.live()
            environment.storage = storage
            let recorder = self.recorder
            environment.makeTransport = { _, _ in recorder }
            var options = LittleFriend.Options()
            options.autoScreens = true
            Facade.shared.start(key: "lf_abcdefghijkl0123456789", options: options, environment: environment)
            let window = UIWindow(frame: UIScreen.main.bounds)
            window.makeKeyAndVisible()
            self.window = window
        }
    }

    override class func tearDown() {
        MainActor.assumeIsolated {
            window?.isHidden = true
            window = nil
        }
        try? FileManager.default.removeItem(at: storage.deletingLastPathComponent())
        super.tearDown()
    }

    // MARK: Helpers

    private var recorder: Recorder { Self.recorder }

    /// Every event sent after `marker`, once everything called so far has gone out.
    @MainActor
    private func events(after marker: Int) async -> [Recorder.Event] {
        await Facade.shared.flushed()
        return Array(recorder.events.dropFirst(marker))
    }

    /// The events sent after `marker` once `done` holds for them, or after 5 seconds. Each try
    /// sends what is queued first.
    @MainActor
    private func events(after marker: Int, until done: ([Recorder.Event]) -> Bool) async -> [Recorder.Event] {
        let deadline = Date() + 5
        while true {
            let sent = await events(after: marker)
            if done(sent) || Date() >= deadline { return sent }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// The `$pageview` events sent after `marker`, once their routes are `routes` or after 5 seconds.
    @MainActor
    private func views(_ routes: [String], after marker: Int) async -> [Recorder.Event] {
        let pageviews = { (events: [Recorder.Event]) in events.filter { $0.name == "$pageview" } }
        return await pageviews(events(after: marker) { pageviews($0).compactMap(\.route) == routes })
    }

    /// The screen routes sent after `marker`, once they are `routes` or after 5 seconds.
    @MainActor
    private func screens(_ routes: [String], after marker: Int) async -> [String] {
        await views(routes, after: marker).compactMap(\.route)
    }

    /// Shows `controller` as the window's root and waits, up to 5 seconds, for the screen it shows
    /// to be in the window: UIKit calls its `viewDidAppear(_:)` in that pass, inside the setter or
    /// on the next turn of the main queue. SwiftUI's `onAppear` comes with a later render pass.
    @MainActor
    private func show(_ controller: UIViewController) async {
        Self.window?.rootViewController = controller
        let shown = Self.leaf(of: controller)
        let deadline = Date() + 5
        while shown.viewIfLoaded?.window == nil, Date() < deadline {
            await mainTurn()
        }
        await mainTurn()
    }

    @MainActor
    private func mainTurn() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { done.resume() }
        }
    }

    /// The controller a container shows.
    @MainActor
    private static func leaf(of controller: UIViewController) -> UIViewController {
        switch controller {
        case let navigation as UINavigationController:
            return navigation.topViewController.map(leaf) ?? navigation
        case let tabs as UITabBarController:
            return tabs.selectedViewController.map(leaf) ?? tabs
        case let pages as UIPageViewController:
            return pages.viewControllers?.first.map(leaf) ?? pages
        case let split as UISplitViewController:
            return split.viewController(for: .primary).map(leaf) ?? split
        default:
            return controller
        }
    }

    // MARK: SwiftUI

    @MainActor
    func testLfScreenSendsOnAppearAndAgainAfterTheViewReappears() async throws {
        let marker = recorder.events.count
        let model = PageModel()
        await show(UIHostingController(rootView: Pages(model: model)))
        _ = await screens(["/products/:id"], after: marker)
        model.tick += 1
        model.page = 1
        _ = await screens(["/products/:id", "/cart"], after: marker)
        model.page = 0
        let sent = await views(["/products/:id", "/cart", "/products/:id"], after: marker)

        XCTAssertEqual(sent.compactMap(\.route), ["/products/:id", "/cart", "/products/:id"], "a re-render is not a new appearance")
        XCTAssertEqual(sent.map { $0.props?["page_type"] as? String }, ["product", nil, "product"])
    }

    @MainActor
    func testLfDeepLinksHandsLinksToTheSDK() async throws {
        let marker = recorder.events.count
        await show(UIHostingController(rootView: Text("links").lfScreen("/links").lfDeepLinks()))
        _ = await screens(["/links"], after: marker)
        DeepLinks.open(URL(string: "lfshop://open?utm_source=Newsletter&utm_campaign=Launch")!)
        // Each link's visit lands the screen on display when its landing window ends.
        _ = await screens(["/links", "/links"], after: marker)
        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.webpageURL = URL(string: "https://shop.example.com/sale?utm_source=partner")!
        DeepLinks.continueActivity(activity)
        DeepLinks.continueActivity(NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb))
        let views = await views(["/links", "/links", "/links"], after: marker)

        XCTAssertEqual(views.compactMap(\.route), ["/links", "/links", "/links"])
        XCTAssertEqual(views.map(\.landing), [nil, 1, 1], "each link lands the screen on display in a new visit")
        XCTAssertEqual(views.map { $0.campaign?["s"] }, [nil, "newsletter", "partner"])
        XCTAssertEqual(views[safe: 1]?.campaign?["c"], "launch")
    }

    // MARK: autoScreens

    @MainActor
    func testAutoScreensNamesTheAppsOwnControllers() async throws {
        let marker = recorder.events.count
        await show(CheckoutViewController())
        await show(OrderViewController())
        await show(UINavigationController(rootViewController: Settings()))
        let tabs = UITabBarController()
        tabs.viewControllers = [ProfileViewController()]
        await show(tabs)
        await show(UIPageViewController())
        await show(UIViewController())
        await show(UIHostingController(rootView: Text("hosted")))
        // The app's own containers and hosting controllers send nothing either.
        await show(AppNavigationController(rootViewController: CartViewController()))
        let appTabs = AppTabBarController()
        appTabs.viewControllers = [UIViewController()]
        await show(appTabs)
        let split = AppSplitViewController(style: .doubleColumn)
        split.setViewController(UIViewController(), for: .primary)
        await show(split)
        await show(AppPageViewController())
        await show(AppHostingController(rootView: Text("app hosted")))

        let expected = ["/Checkout", "/orders/:id", "/Settings", "/Profile", "/Cart"]
        let routes = await screens(expected, after: marker)
        XCTAssertEqual(routes, expected, "containers, hosting and system controllers send nothing")
    }

    func testControllerNames() {
        XCTAssertEqual(UIKitScreens.name(of: CheckoutViewController.self), "Checkout")
        XCTAssertEqual(UIKitScreens.name(of: Settings.self), "Settings")
        XCTAssertEqual(UIKitScreens.name(of: ViewController.self), "ViewController", "nothing is left without the suffix")
        XCTAssertEqual(UIKitScreens.name(of: ListViewController<Int>.self), "List")
    }

    // MARK: App block, lifecycle

    @MainActor
    func testTheBatchCarriesTheBundlesAppBlockAndTestTraffic() async throws {
        let marker = recorder.events.count
        LittleFriend.track("app_block_check")
        let after = await events(after: marker) { $0.contains { $0.name == "app_block_check" } }
        let sent = try XCTUnwrap(after.first { $0.name == "app_block_check" })
        let idiom = UIDevice.current.userInterfaceIdiom

        XCTAssertEqual(sent.batch["a"] as? [String: String], [
            "i": try XCTUnwrap(Bundle.main.bundleIdentifier),
            "p": "ios",
            "d": idiom == .pad ? "tablet" : "mobile",
            "v": try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String),
        ])
        XCTAssertEqual(sent.batch["d"] as? Int, 1, "the Simulator is test traffic")
        XCTAssertEqual(sent.batch["sv"] as? String, "ios-0.1.0")
        XCTAssertTrue(TestDetection.isTestTraffic())
    }

    @MainActor
    func testTheBackgroundClosesTheScreenAndSendsInsideABackgroundTask() async throws {
        XCTAssertEqual(UIApplication.shared.applicationState, .active, "start while active counted as the cold launch")
        let tasks = CountingTasks(replacing: BackgroundSend.tasks)
        BackgroundSend.tasks = tasks
        defer { BackgroundSend.tasks = tasks.replaced }
        let marker = recorder.events.count
        await show(UIHostingController(rootView: Text("background").lfScreen("/background")))
        _ = await screens(["/background"], after: marker)
        // Time on the screen, for its $engage.
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let before = recorder.requestCount
        for round in 1...2 {
            NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: UIApplication.shared)
            if round == 1 {
                let arrived = await recorder.waitForRequests(before + 1)
                XCTAssertTrue(arrived, "the background sends without a flush call")
            }
            let ended = await tasks.waitForEnds(round)
            XCTAssertTrue(ended, "round \(round): the task ends after the send")
            XCTAssertEqual(tasks.begun, round, "round \(round): one task begins per background")
            XCTAssertEqual(tasks.ended, round, "round \(round): and ends once")
            XCTAssertEqual(tasks.open, [], "round \(round): the task that began is the one that ended")
            NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: UIApplication.shared)
        }
        let engage = Array(recorder.events.dropFirst(marker)).first { $0.name == "$engage" }
        XCTAssertEqual(engage?.route, "/background")
        XCTAssertGreaterThanOrEqual((engage?.props?["ms"] as? Int) ?? 0, 1200)
        let routes = await screens(["/background"], after: marker)
        XCTAssertEqual(routes, ["/background"], "a short background is the same visit")
    }
}

// MARK: Fixtures

/// Background tasks that are only counted: each begin hands out a new identifier.
@MainActor
final class CountingTasks: BackgroundTasks {
    let replaced: BackgroundTasks
    private(set) var begun = 0
    private(set) var ended = 0
    /// The identifiers handed out and not yet ended.
    private(set) var open: Set<Int> = []

    init(replacing replaced: BackgroundTasks) {
        self.replaced = replaced
    }

    func begin(expiration: @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier {
        begun += 1
        open.insert(begun)
        return UIBackgroundTaskIdentifier(rawValue: begun)
    }

    func end(_ id: UIBackgroundTaskIdentifier) {
        ended += 1
        open.remove(id.rawValue)
    }

    /// True once `count` tasks have ended, false after 5 seconds.
    func waitForEnds(_ count: Int) async -> Bool {
        let deadline = Date() + 5
        while ended < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return ended >= count
    }
}

final class PageModel: ObservableObject {
    @Published var page = 0
    @Published var tick = 0
}

struct Pages: View {
    @ObservedObject var model: PageModel

    var body: some View {
        if model.page == 0 {
            Text("product \(model.tick)").lfScreen("/products/:id", type: "product")
        } else {
            Text("cart").lfScreen("/cart")
        }
    }
}

final class CheckoutViewController: UIViewController {}
final class CartViewController: UIViewController {}
final class AppNavigationController: UINavigationController {}
final class AppTabBarController: UITabBarController {}
final class AppSplitViewController: UISplitViewController {}
final class AppPageViewController: UIPageViewController {}
final class AppHostingController: UIHostingController<SwiftUI.Text> {}
final class ProfileViewController: UIViewController {}
final class Settings: UIViewController {}
final class ViewController: UIViewController {}
final class ListViewController<Item>: UIViewController {}

final class OrderViewController: UIViewController, LFScreen {
    var lfRoute: String { "/orders/:id" }
}

/// A transport that keeps every body and accepts it.
final class Recorder: Transport, @unchecked Sendable {
    struct Event {
        let batch: [String: Any]
        let event: [String: Any]

        var name: String? { event["n"] as? String }
        var route: String? { event["u"] as? String }
        var landing: Int? { event["l"] as? Int }
        var campaign: [String: String]? { event["c"] as? [String: String] }
        var props: [String: Any]? { event["p"] as? [String: Any] }
    }

    private let lock = NSLock()
    private var bodies: [Data] = []

    func send(_ body: Data) async -> TransportResult {
        record(body)
        return .accepted
    }

    private func record(_ body: Data) {
        lock.lock()
        bodies.append(body)
        lock.unlock()
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return bodies.count
    }

    var events: [Event] {
        lock.lock()
        let all = bodies
        lock.unlock()
        return all.flatMap { body -> [Event] in
            guard let batch = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let events = batch["e"] as? [[String: Any]]
            else { return [] }
            return events.map { Event(batch: batch, event: $0) }
        }
    }

    /// True once `count` requests have arrived, false after `timeout`.
    func waitForRequests(_ count: Int, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date() + timeout
        while Date() < deadline {
            if requestCount >= count { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return requestCount >= count
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
