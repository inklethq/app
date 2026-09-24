import SwiftUI

@main
struct InkletMacApp: App {
    @NSApplicationDelegateAdaptor(WidgetRouter.self) private var widgetRouter
    @State private var session = Session()
    @State private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    // Note: system menu highlight follows the user's accent color and `.tint`
    // can't reach it. Forcing the graphite accent through defaults recolors the
    // menus but also greys out the window's traffic lights, so it's not worth it.
    // The clean fix is an `AccentColor` asset (app-scoped, leaves traffic lights
    // alone) — that needs Xcode's actool, so it lands when we move to an Xcode project.
    init() {
        BrandFonts.register()
        // Photos exports from a previous run belong to nobody now.
        Task.detached(priority: .utility) { AppContext.discardStaleExports() }
    }

    static let mainWindowID = "main"

    var body: some Scene {
        // `Window`, not `WindowGroup`: this is a single-instance companion window.
        // A group would let ⌘N stack duplicates that all show the same account.
        Window("inklet Portal", id: Self.mainWindowID) {
            AppGate()
                .environment(session)
                .environment(model)
                .environmentObject(model.virtualDisplays)
                .environment(widgetRouter)
                .onAppear {
                    widgetRouter.openMainWindow = { openWindow(id: Self.mainWindowID) }
                }
        }
        .defaultSize(width: 1080, height: 720)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) { AboutSettingsCommand() }
            CommandGroup(after: .appInfo) { CheckForUpdatesCommand() }
            // A single-instance Window contributes no "New Window" item, so
            // closing it would otherwise leave no way back into the app. This
            // reopens the one window (or focuses it if it's already up).
            CommandGroup(after: .newItem) {
                Button("inklet Portal Window") { openWindow(id: Self.mainWindowID) }
                    .keyboardShortcut("n")

                Button("Create Presentation…") { model.startComposing() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(session.user == nil)

                Button("Ask inklet…") { openWindow(id: Self.mainWindowID); NSApp.activate(); model.openAsk() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(session.user == nil)
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
                    .disabled(session.user == nil)
            }
            CommandGroup(replacing: .help) {
                Link("inklet Help", destination: URL(string: "https://iminklet.com")!)
            }
        }

        // Always present: with "Show in Dock" off this is the only way back in.
        MenuBarExtra("inklet Portal", systemImage: "square.and.pencil") {
            Button("Open inklet Portal") { openWindow(id: Self.mainWindowID); NSApp.activate() }
            Button("Create Presentation…") { model.startComposing() }
                .disabled(session.user == nil)
            Button("Ask inklet…") { openWindow(id: Self.mainWindowID); NSApp.activate(); model.openAsk() }
                .disabled(session.user == nil)
            Divider()
            CheckForUpdatesCommand()
            SettingsLink { Text("Settings…") }
            Divider()
            Button("Quit inklet Portal") { NSApp.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(session)
                .environment(model)
                .environmentObject(model.virtualDisplays)
                .environment(ShortcutStore.shared)
        }
        .windowResizability(.contentSize)
    }
}

/// Chooses the surface for the current auth state and owns the load/teardown that
/// goes with crossing that boundary.
private struct AppGate: View {
    @Environment(Session.self) private var session
    @Environment(AppModel.self) private var model
    @Environment(WidgetRouter.self) private var widgetRouter

    var body: some View {
        Group {
            switch session.state {
            case .restoring:
                SplashView()
            case .unreachable:
                UnreachableView()
            case .signedOut:
                LoginView()
            case .signedIn:
                RootView()
            }
        }
        .task {
            DockVisibility.install()
            ServicesProvider.install(model: model, session: session) { widgetRouter.openMainWindow?() }
            // Only a launch checks the stored session. This view goes away with
            // its window and comes back with the next one, and a session that
            // is already settled must not be put through the check again.
            if session.state == .restoring { await session.restore() }
        }
        .onChange(of: session.state) { _, state in
            switch state {
            case .signedIn(let user):
                model.attach(session: session)
                model.account = Account(dto: user)
                Task { await model.load() }
                installHotKey()
                ServicesProvider.installed?.deliverPending()
            case .signedOut:
                model.reset()
                ComposerPanelController.shared.hide()
                ShortcutStore.shared.deactivate()
            case .restoring, .unreachable:
                break
            }
        }
    }

    /// Registered only while signed in — a shortcut that opens a composer you
    /// can't send from would be worse than no shortcut.
    private func installHotKey() {
        ShortcutStore.shared.activate { model.toggleComposer() }
    }
}
