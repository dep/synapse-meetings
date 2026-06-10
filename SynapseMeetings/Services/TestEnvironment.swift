import Foundation

enum TestEnvironment {
    /// True when running inside an XCTest host. Used to suppress launch side
    /// effects (permission prompts, model downloads) during unit tests.
    static let isRunningTests: Bool =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
}
