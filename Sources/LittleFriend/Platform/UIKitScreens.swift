#if canImport(UIKit) && !os(watchOS)
import ObjectiveC
import UIKit

/// `autoScreens`: a screen from every `viewDidAppear(_:)` of the app's own view controllers.
enum UIKitScreens {
    /// Swaps `viewDidAppear(_:)` on UIViewController once per process.
    static func install() {
        _ = swizzled
    }

    private static let swizzled: Bool = {
        guard let original = class_getInstanceMethod(UIViewController.self, #selector(UIViewController.viewDidAppear(_:))),
              let replacement = class_getInstanceMethod(UIViewController.self, #selector(UIViewController.lf_viewDidAppear(_:)))
        else {
            Log.warn("autoScreens is off: viewDidAppear(_:) could not be observed")
            return false
        }
        method_exchangeImplementations(original, replacement)
        return true
    }()

    /// Containers and hosting controllers never name a screen: what they show does. Nor does a
    /// controller of the system's own frameworks. Otherwise the `LFScreen` route, or the class name
    /// without its `ViewController` suffix.
    @MainActor
    static func route(for controller: UIViewController) -> String? {
        if controller is UINavigationController || controller is UITabBarController
            || controller is UISplitViewController || controller is UIPageViewController
            || isHosting(type(of: controller)) {
            return nil
        }
        if let screen = controller as? LFScreen { return screen.lfRoute }
        if isSystem(type(of: controller)) { return nil }
        return name(of: type(of: controller))
    }

    /// `CheckoutViewController` is `Checkout`; generic arguments are left out.
    static func name(of type: AnyClass) -> String {
        var name = String(describing: type)
        if let open = name.firstIndex(of: "<") { name = String(name[..<open]) }
        let suffix = "ViewController"
        if name.hasSuffix(suffix), name.count > suffix.count { name.removeLast(suffix.count) }
        return name
    }

    /// SwiftUI's UIHostingController, or a subclass of it.
    private static func isHosting(_ type: AnyClass) -> Bool {
        var current: AnyClass? = type
        while let cls = current {
            if NSStringFromClass(cls).contains("UIHostingController") { return true }
            current = class_getSuperclass(cls)
        }
        return false
    }

    /// A class from a framework under a System/Library directory, the Simulator's included.
    private static func isSystem(_ type: AnyClass) -> Bool {
        let path = Bundle(for: type).bundlePath
        return path.contains("/System/Library/") || path.hasPrefix("/usr/lib/")
    }
}

extension UIViewController {
    /// Takes the place of `viewDidAppear(_:)` once swapped: runs the original, then sends the screen.
    @objc func lf_viewDidAppear(_ animated: Bool) {
        lf_viewDidAppear(animated)
        guard let route = UIKitScreens.route(for: self) else { return }
        LittleFriend.screen(route)
    }
}
#endif
