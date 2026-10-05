import Foundation

/// Whether the SDK runs as test traffic (`d: 1`) when the `test` option is not given.
enum TestDetection {
    /// True in the Simulator, and under XCTest: `XCTestConfigurationFilePath` in the environment, or
    /// the XCTest runtime loaded, as `swift test` loads it without that variable.
    static func isTestTraffic(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
        #endif
    }
}
