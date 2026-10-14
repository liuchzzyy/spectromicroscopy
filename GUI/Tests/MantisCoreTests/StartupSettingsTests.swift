import XCTest
@testable import Mantis

@MainActor final class StartupSettingsTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "mantis.startup.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
    func testClosingBehaviorDefaultsToEndingSessionAndPersistsMenuBarChoice() {
        let defaults = defaults()
        let first = InterfacePreferences(defaults: defaults)
        XCTAssertEqual(first.closeBehavior, .quit)
        XCTAssertTrue(StartupSettings.shouldQuitAfterLastWindow(preferences: first))
        first.closeBehavior = .menuBar
        let second = InterfacePreferences(defaults: defaults)
        XCTAssertEqual(second.closeBehavior, .menuBar)
        XCTAssertFalse(StartupSettings.shouldQuitAfterLastWindow(preferences: second))
    }
    func testSilentLaunchOnlyHidesLoginLaunchAndManualLaunchStaysVisible() {
        let prefs = InterfacePreferences(defaults: defaults())
        prefs.silentLaunch = true
        XCTAssertFalse(StartupSettings.shouldStartHidden(arguments: ["MantisNative"], preferences: prefs))
        XCTAssertTrue(StartupSettings.shouldStartHidden(arguments: ["MantisNative", StartupSettings.loginArgument], preferences: prefs))
    }
    func testLoginRegistrationFailureDoesNotPersistEnabledState() throws {
        let prefs = InterfacePreferences(defaults: defaults())
        XCTAssertThrowsError(try StartupSettings.setLaunchAtLogin(true, preferences: prefs, service: FailingLoginService()))
        XCTAssertFalse(prefs.launchAtLogin)
    }
}

private struct FailingLoginService: LoginService {
    var enabled: Bool { false }
    func register() throws { throw NSError(domain: "fixture", code: 1) }
    func unregister() throws { throw NSError(domain: "fixture", code: 1) }
}
