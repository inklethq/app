import AppKit
import InkletPresentationKit
import Observation

/// Retains a cold-launch URL while the account is restoring or signing in.
@MainActor
@Observable
final class WidgetRouter: NSObject, NSApplicationDelegate {
    var pending: WidgetDestination?
    var pendingDisplayID: UUID?
    var openMainWindow: (() -> Void)?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.last else { return }
        if let id = VirtualDisplayLinks.displayID(url) {
            pendingDisplayID = id
            pending = .display
        } else if let destination = WidgetDestination(url: url) {
            pendingDisplayID = nil
            pending = destination
        } else { return }
        openMainWindow?()
        application.activate(ignoringOtherApps: true)
    }
}
