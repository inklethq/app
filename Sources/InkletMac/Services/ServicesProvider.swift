import AppKit

/// Puts "Send to inklet" in every app's Services menu (and the right-click menu
/// that mirrors it).
///
/// This is the cheapest reach the app has: no permissions, no per-app support, no
/// polling. It works in the apps with no scripting dictionary and in the ones
/// whose accessibility tree stays closed, because the user hands us the payload
/// through the pasteboard instead of us going to fetch it.
///
/// The declaration lives in Info.plist under `NSServices`; this is the receiver.
///
/// The menu item is in every app whether or not anyone is signed in — the
/// declaration is static — so the receiver is installed for the life of the
/// app and answers a signed-out request the way a widget link does: it keeps
/// the payload, puts up the window where sign-in happens, and hands the
/// payload to the composer once someone is signed in.
@MainActor
final class ServicesProvider: NSObject {
    /// AppKit keeps `servicesProvider` weakly. This is the reference that keeps
    /// it alive for as long as the app runs, not as long as some window does.
    private(set) static var installed: ServicesProvider?

    private let model: AppModel
    private let session: Session
    private let openMainWindow: () -> Void
    /// What arrived while nobody was signed in, or before the stored session
    /// had been checked on a cold launch from the Services menu.
    private var pending: Capture?

    private init(model: AppModel, session: Session, openMainWindow: @escaping () -> Void) {
        self.model = model
        self.session = session
        self.openMainWindow = openMainWindow
        super.init()
    }

    /// Once per launch; later calls find it already in place.
    static func install(model: AppModel, session: Session, openMainWindow: @escaping () -> Void) {
        guard installed == nil else { return }
        let provider = ServicesProvider(model: model, session: session, openMainWindow: openMainWindow)
        installed = provider
        NSApp.servicesProvider = provider
        // Tells the system to re-read our Info.plist. Without it a freshly built
        // app doesn't appear in other apps' Services menus until logout.
        NSUpdateDynamicServices()
    }

    /// Matches `NSMessage` in Info.plist. The selector shape is fixed by AppKit.
    @objc func sendToInklet(_ pasteboard: NSPasteboard,
                            userData: String?,
                            error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let context = Self.read(pasteboard) else {
            error.pointee = "Nothing inklet can send." as NSString
            return
        }
        guard session.user != nil else {
            pending = context
            openMainWindow()
            NSApp.activate()
            return
        }
        model.presentComposer(with: context)
    }

    /// Someone is signed in now: the composer gets what was waiting for them.
    func deliverPending() {
        guard let context = pending else { return }
        pending = nil
        model.presentComposer(with: context)
    }

    /// Files first: a Finder selection also puts its names on the pasteboard as
    /// a string, and the files are the thing worth sending.
    private static func read(_ pasteboard: NSPasteboard) -> Capture? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let files = urls.filter(\.isFileURL)
            if !files.isEmpty { return Capture(files: files, appName: "Services") }

            if let web = urls.first(where: { $0.scheme?.hasPrefix("http") == true }) {
                return Capture(link: .init(url: web.absoluteString, title: nil), appName: "Services")
            }
        }

        if let text = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            // A bare URL sent as text is still a link.
            if let url = URL(string: text), url.scheme?.hasPrefix("http") == true,
               !text.contains(" ") {
                return Capture(link: .init(url: text, title: nil), appName: "Services")
            }
            return Capture(text: text, appName: "Services")
        }

        return nil
    }
}
