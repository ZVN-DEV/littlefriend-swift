#if canImport(SwiftUI)
import SwiftUI

extension View {
    /// Sends `route` as a screen each time this view appears: once on appear, and again after it
    /// disappears and appears again. A view that appears while the app is in the background is
    /// sent when the app returns to the foreground, if it is still the screen on display.
    public func lfScreen(_ route: String, type: String? = nil) -> some View {
        onAppear { LittleFriend.screen(route, type: type) }
    }

    /// Hands the URLs that open the app, deep links and universal links, to `LittleFriend.handle(url:)`.
    public func lfDeepLinks() -> some View {
        onOpenURL(perform: DeepLinks.open)
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb, perform: DeepLinks.continueActivity)
    }
}

/// The handlers `lfDeepLinks()` installs.
enum DeepLinks {
    static func open(_ url: URL) {
        LittleFriend.handle(url: url)
    }

    /// A universal link: the activity's web page URL.
    static func continueActivity(_ activity: NSUserActivity) {
        guard let url = activity.webpageURL else { return }
        LittleFriend.handle(url: url)
    }
}
#endif
