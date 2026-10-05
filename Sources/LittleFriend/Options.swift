import Foundation

public enum LittleFriend {
    public struct Options: Sendable {
        /// `aggregate` stores no session or other identifier; `journey` keeps a session.
        public var mode: Mode = .aggregate
        /// `required` runs in aggregate mode until `consent(.journey)`.
        public var consent: Consent = .none
        /// The collector's base URL; batches go to `<endpoint>/v1/e`.
        public var endpoint = URL(string: "https://in.littlefriend.io")!
        /// Marks traffic as test (`d: 1`). Nil: detected.
        public var test: Bool? = nil
        /// Also reads `utm_term` and `utm_content` from deep links.
        public var utmExtended = false
        /// Nil: CFBundleShortVersionString.
        public var appVersion: String? = nil
        /// UIKit only: screens from `viewDidAppear(_:)`.
        public var autoScreens = false
        /// Moves the SDK's whole clock back, for test traffic only: negative, at most 23 hours.
        public var testClockOffset: TimeInterval = 0

        public init() {}
    }

    public enum Mode: Sendable {
        case aggregate, journey
    }

    public enum Consent: Sendable {
        case none, required, journey
    }
}
