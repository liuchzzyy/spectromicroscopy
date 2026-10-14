import Foundation
import AppKit

/// Login item only: launch the main app, never touch analysis data.
let app = Bundle.main.bundleURL
    .deletingLastPathComponent() // LoginItems
    .deletingLastPathComponent() // Library
    .deletingLastPathComponent() // Contents
    .deletingLastPathComponent() // Mantis.app
let config = NSWorkspace.OpenConfiguration()
config.arguments = ["--mantis-login-launch"]
config.activates = false
var finished = false
var launchError: Error?
NSWorkspace.shared.openApplication(at: app, configuration: config) { _, error in
    launchError = error
    finished = true
}
let deadline = Date().addingTimeInterval(15)
while !finished && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}
guard finished else { fputs("MANTiS login helper: launch timed out\n", stderr); exit(1) }
if let launchError { fputs("MANTiS login helper: \(launchError.localizedDescription)\n", stderr); exit(1) }
