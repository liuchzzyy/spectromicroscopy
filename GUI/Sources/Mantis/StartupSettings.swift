import Foundation
import ServiceManagement

protocol LoginService {
    func register() throws
    func unregister() throws
    var enabled: Bool { get }
}

/// A bundled, signed login item launches the GUI with a private marker.
private struct SystemLoginService: LoginService {
    private let service = SMAppService.loginItem(identifier: "org.spectromicroscopy.mantis.login-helper")
    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
    var enabled: Bool { service.status == .enabled }
}

@MainActor enum StartupSettings {
    static let loginArgument = "--mantis-login-launch"
    static func shouldStartHidden(arguments: [String], preferences: InterfacePreferences) -> Bool {
        preferences.silentLaunch && arguments.contains(loginArgument)
    }
    static func shouldQuitAfterLastWindow(preferences: InterfacePreferences) -> Bool {
        preferences.closeBehavior == .quit
    }
    static func setLaunchAtLogin(_ enabled: Bool, preferences: InterfacePreferences,
                                 service: LoginService = SystemLoginService()) throws {
        if enabled { try service.register() } else { try service.unregister() }
        preferences.launchAtLogin = enabled
    }
    static var systemEnabled: Bool { SystemLoginService().enabled }
}
