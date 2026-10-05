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
    private static var window: UIWindow?

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
    private func events(after marker: Int) async -> [Recorder.Event] {
        await Facade.shared.flushed()
        return Array(recorder.events.dropFirst(marker))
    }

    private func screens(after marker: Int) async -> [String] {
        await events(after: marker).filter { $0.name == "$pageview" }.compactMap(\.route)
    }

    /// Shows `controller` as the window's root and lets it appear.
    @MainActor
    private func show(_ controller: UIViewController) async {
        Self.window?.rootViewController = controller
        await settle()
    }

    /// Lets UIKit and SwiftUI run their appearance callbacks.
    @MainActor
    private func settle() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    // MARK: SwiftUI

    @MainActor
    func testLfScreenSendsOnAppearAndAgainAfterTheViewReappears() async throws {
        let marker = recorder.events.count
        let model = PageModel()
        await show(UIHostingController(rootView: Pages(model: model)))
        model.tick += 1
        await settle()
        model.page = 1
        await settle()
        model.page = 0
        await settle()
        let sent = await events(after: marker).filter { $0.name == "$pageview" }

        XCTAssertEqual(sent.compactMap(\.route), ["/products/:id", "/cart", "/products/:id"], "a re-render is not a new appearance")
        XCTAssertEqual(sent.map { $0.props?["page_type"] as? String }, ["product", nil, "product"])
    }

    @MainActor
    func testLfDeepLinksHandsLinksToTheSDK() async throws {
        let marker = recorder.events.count
        await show(UIHostingController(rootView: Text("links").lfScreen("/links").lfDeepLinks()))
        DeepLinks.open(URL(string: "lfshop://open?utm_source=Newsletter&utm_campaign=Launch")!)
        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.webpageURL = URL(string: "https://shop.example.com/sale?utm_source=partner")!
        DeepLinks.continueActivity(activity)
        DeepLinks.continueActivity(NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb))
        let views = await events(after: marker).filter { $0.name == "$pageview" }

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

        let routes = await screens(after: marker)
        XCTAssertEqual(
            routes, ["/Checkout", "/orders/:id", "/Settings", "/Profile", "/Cart"],
            "containers, hosting and system controllers send nothing"
        )
    }

    func testControllerNames() {
        XCTAssertEqual(UIKitScreens.name(of: CheckoutViewController.self), "Checkout")
        XCTAssertEqual(UIKitScreens.name(of: Settings.self), "Settings")
        XCTAssertEqual(UIKitScreens.name(of: ViewController.self), "ViewController", "nothing is left without the suffix")
        XCTAssertEqual(UIKitScreens.name(of: ListViewController<Int>.self), "List")
    }

    // MARK: App block, lifecycle

    func testTheBatchCarriesTheBundlesAppBlockAndTestTraffic() async throws {
        let marker = recorder.events.count
        LittleFriend.track("app_block_check")
        let after = await events(after: marker)
        let sent = try XCTUnwrap(after.first)
        let idiom = await MainActor.run { UIDevice.current.userInterfaceIdiom }

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
        let marker = recorder.events.count
        await show(UIHostingController(rootView: Text("background").lfScreen("/background")))
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let before = recorder.requestCount
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: UIApplication.shared)
        let arrived = await recorder.waitForRequests(before + 1)
        XCTAssertTrue(arrived, "the background sends without a flush call")
        let engage = Array(recorder.events.dropFirst(marker)).last { $0.name == "$engage" }
        XCTAssertEqual(engage?.route, "/background")
        XCTAssertGreaterThanOrEqual((engage?.props?["ms"] as? Int) ?? 0, 1200)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: UIApplication.shared)
        await settle()
        let routes = await screens(after: marker)
        XCTAssertEqual(routes, ["/background"], "a short background is the same visit")
    }
}

// MARK: Fixtures

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
