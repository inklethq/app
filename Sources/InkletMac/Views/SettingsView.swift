import SwiftUI

enum SettingsTab: String { case general, notifications, account, about }

struct SettingsView: View {
    @AppStorage("settingsTab") private var selection: SettingsTab = .general
    @State private var heights: [SettingsTab: CGFloat] = [:]
    var body: some View {
        TabView(selection: $selection) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            NotificationSettings()
                .tabItem { Label("Notifications", systemImage: "bell") }.tag(SettingsTab.notifications)
            AccountSettings()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }.tag(SettingsTab.account)
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }.tag(SettingsTab.about)
        }
        .tint(Ink.text)
        .background(Ink.bg)
        // The tab strip is a real NSToolbar with its own vibrant material, which
        // reads blue-grey next to the app's flat background. Paint it to match.
        .toolbarBackground(Ink.bg, for: .windowToolbar)
        .background(WindowStyler().frame(width: 0, height: 0))
        .frame(width: 520, height: min(heights[selection] ?? 400, (NSScreen.main?.visibleFrame.height ?? 800) - 140))
        .onPreferenceChange(SettingsHeightKey.self) { heights.merge($0) { _, new in new } }
    }
}

private struct GeneralSettings: View {
    @AppStorage(SystemSettings.showInDockKey) private var showInDock = true
    @AppStorage(SystemSettings.showWeatherKey) private var showWeather = false
    @ObservedObject private var updater = AppUpdater.shared
    private let loginItem = LaunchAtLogin.shared
    private let weather = WeatherService.shared
    /// The system posts nothing when Accessibility access changes, so this is
    /// read again whenever the app comes back to the front — which is how a
    /// user returning from System Settings arrives.
    @State private var readsSelection = SelectionContext.isTrusted
    /// The system prompt shows once; after that the switch is only in System Settings.
    @State private var askedForAccessibility = false

    private var lastCheckDescription: String {
        guard updater.isAvailable else { return "Run a packaged build to check for updates" }
        guard let date = updater.lastUpdateCheckDate else { return "Never checked" }
        return "Last checked " + date.formatted(.relative(presentation: .named))
    }

    private var loginItemSubtitle: String {
        if !loginItem.isAvailable { return "Available in the packaged app only" }
        if let error = loginItem.error { return error }
        if loginItem.requiresApproval { return "Waiting for approval in System Settings → Login Items" }
        return "Open inklet Portal when you log in"
    }

    private var weatherSubtitle: String {
        if !showWeather { return "Uses your approximate location, via Open-Meteo" }
        if weather.isDenied { return "Location access is off — allow it in System Settings" }
        if let problem = weather.problem { return problem }
        if let current = weather.current { return "\(current.summary), \(current.temperature) right now" }
        return "Uses your approximate location, via Open-Meteo"
    }

    private var selectionSubtitle: String {
        readsSelection
            ? "The composer offers the text you've highlighted"
            : "Needs Accessibility access in System Settings to offer highlighted text"
    }

    var body: some View {
        SettingsPage(tab: .general) {
            SettingsGroup("Startup") {
                SettingRow(title: "Launch at login", subtitle: loginItemSubtitle) {
                    HStack(spacing: 8) {
                        if loginItem.requiresApproval {
                            Button("Open Settings") { loginItem.openSystemSettings() }
                                .controlSize(.small)
                        }
                        Toggle("", isOn: Binding(
                            get: { loginItem.isEnabled || loginItem.requiresApproval },
                            set: { loginItem.set($0) }))
                            .labelsHidden()
                            .disabled(!loginItem.isAvailable)
                    }
                }
                SettingRow(title: "Keep in Dock",
                           subtitle: "With this off, the Dock icon goes away once only the composer is open",
                           showsDivider: false) {
                    Toggle("", isOn: $showInDock).labelsHidden()
                        .onChange(of: showInDock) { _, _ in DockVisibility.refresh() }
                }
            }

            SettingsGroup("Updates") {
                SettingRow(title: "Check for updates automatically",
                           subtitle: updater.isAvailable
                               ? "Once a day, in the background"
                               : "Available in the packaged app only") {
                    Toggle("", isOn: Binding(
                        get: { updater.isAvailable && updater.automaticallyChecksForUpdates },
                        set: { updater.automaticallyChecksForUpdates = $0 }))
                        .labelsHidden()
                        .disabled(!updater.isAvailable)
                }
                SettingRow(title: "Include beta versions",
                           subtitle: AppUpdater.isPrereleaseBuild
                               ? "This is a beta build, so betas are always offered"
                               : "Get pre-release builds before they are final") {
                    Toggle("", isOn: $updater.includesBetaUpdates).labelsHidden()
                        .disabled(!updater.isAvailable || AppUpdater.isPrereleaseBuild)
                }
                SettingRow(title: "Check now",
                           subtitle: lastCheckDescription,
                           showsDivider: false) {
                    Button("Check for Updates…") { updater.checkForUpdates() }
                        .disabled(!updater.isAvailable || !updater.canCheckForUpdates)
                }
            }

            SettingsGroup("Composer") {
                SettingRow(title: "Global shortcut",
                           subtitle: "Opens the composer from any app · ⌫ restores the default") {
                    ShortcutRecorder()
                }
                SettingRow(title: "Highlighted text", subtitle: selectionSubtitle) {
                    if !readsSelection {
                        if askedForAccessibility {
                            Button("Open Settings") { SelectionContext.openSystemSettings() }
                                .controlSize(.small)
                        } else {
                            Button("Allow…") {
                                SelectionContext.requestPermission()
                                askedForAccessibility = true
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .onAppear { readsSelection = SelectionContext.isTrusted }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    readsSelection = SelectionContext.isTrusted
                }
                SettingRow(title: "Weather on Home", subtitle: weatherSubtitle, showsDivider: false) {
                    HStack(spacing: 8) {
                        if showWeather, weather.isDenied {
                            Button("Open Settings") { weather.openSystemSettings() }
                                .controlSize(.small)
                        }
                        Toggle("", isOn: $showWeather).labelsHidden()
                            .onChange(of: showWeather) { _, value in if value { weather.refresh() } }
                    }
                }
            }
        }
    }
}

private struct AccountSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(Session.self) private var session

    var body: some View {
        SettingsPage(tab: .account) {
            InkCard(padding: 16) {
                HStack(spacing: 14) {
                    Text(model.account.username.prefix(1).lowercased())
                        .font(.brand(26))
                        .foregroundStyle(Ink.secondary)
                        .frame(width: 48, height: 48)
                        .background(Ink.input, in: .circle)
                        .overlay { Circle().strokeBorder(Ink.border) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.account.username)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Ink.text)
                        Text(model.account.email)
                            .font(.system(size: 13))
                            .foregroundStyle(Ink.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(model.account.plan.uppercased())
                        .font(.system(size: 11, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(Ink.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Ink.input, in: .capsule)
                }
            }

            SettingsGroup("Billing") {
                SettingRow(title: "Subscription", subtitle: "Plans and invoices live on the web portal") {
                    Link("Manage", destination: URL(string: "https://portal.iminklet.com")!)
                }
                SettingRow(title: "API tokens",
                           subtitle: "For scripts and automations",
                           showsDivider: false) {
                    Link("Open", destination: URL(string: "https://portal.iminklet.com/api-tokens")!)
                }
            }

            SettingsGroup("Session") {
                SettingRow(title: "Sign out",
                           subtitle: "Clears your credentials on this Mac",
                           showsDivider: false) {
                    Button("Sign Out", role: .destructive) {
                        Task { await session.signOut() }
                    }
                }
            }
        }
    }
}

private struct NotificationSettings: View {
    @AppStorage(SystemSettings.notifyDeliveredKey) private var delivered = true
    @AppStorage(SystemSettings.notifyFailedKey) private var failed = true
    @AppStorage(SystemSettings.notifyOfflineKey) private var offline = false
    private let notifier = Notifier.shared

    private var permissionSubtitle: String {
        if !notifier.isAvailable { return "Available in the packaged app only" }
        switch notifier.authorization {
        case .authorized, .provisional: return "Allowed in System Settings"
        case .denied: return "Turned off for inklet Portal in System Settings"
        default: return "You'll be asked the first time a notification is turned on"
        }
    }

    /// Turning any alert on asks the system once; a denied answer is shown
    /// next to the toggles rather than failing silently later.
    private func ask(if enabled: Bool) {
        guard enabled, notifier.authorization == .notDetermined else { return }
        Task { await notifier.requestAuthorization() }
    }

    var body: some View {
        SettingsPage(tab: .notifications) {
            SettingsGroup("Permission") {
                SettingRow(title: "System notifications", subtitle: permissionSubtitle, showsDivider: false) {
                    if notifier.authorization == .denied {
                        Button("Open Settings") { notifier.openSystemSettings() }
                            .controlSize(.small)
                    } else if notifier.authorization == .notDetermined, notifier.isAvailable {
                        Button("Allow…") { Task { await notifier.requestAuthorization() } }
                            .controlSize(.small)
                    }
                }
            }

            SettingsGroup("Alerts") {
                SettingRow(title: "Content delivered",
                           subtitle: "When a card is on its way to a display") {
                    Toggle("", isOn: $delivered).labelsHidden()
                        .onChange(of: delivered) { _, value in ask(if: value) }
                }
                SettingRow(title: "Send failed",
                           subtitle: "When inklet couldn't finish a card") {
                    Toggle("", isOn: $failed).labelsHidden()
                        .onChange(of: failed) { _, value in ask(if: value) }
                }
                SettingRow(title: "Display went offline",
                           subtitle: "When a display that was online stops checking in",
                           showsDivider: false) {
                    Toggle("", isOn: $offline).labelsHidden()
                        .onChange(of: offline) { _, value in ask(if: value) }
                }
            }
            .disabled(!notifier.isAvailable)
        }
        .task { await notifier.refreshAuthorization() }
    }
}

private struct AboutSettings: View {
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }

    var body: some View {
        SettingsPage(tab: .about, bottomPadding: 32) {
            VStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 96, height: 96)
                    .padding(.bottom, 4)
                Text("inklet Portal").font(.system(size: 24, weight: .bold))
                Text("Version \(version) (\(build))")
                    .font(.body).foregroundStyle(.secondary).textSelection(.enabled)
                VStack(spacing: 24) {
                    HStack(spacing: 8) {
                        Link("Privacy Policy", destination: URL(string: "https://www.iminklet.com/privacy-policy")!)
                        Text("·").foregroundStyle(.tertiary)
                        Link("Terms of Service", destination: URL(string: "https://www.iminklet.com/terms-of-service")!)
                    }
                    .font(.body)
                    VStack(spacing: 3) {
                        Text("© \(String(Calendar.current.component(.year, from: Date()))) inklet LLC.")
                        Text("All rights reserved.")
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
        }
    }
}

/// Routes the standard application-menu item into the existing settings scene.
struct AboutSettingsCommand: View {
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var selection: SettingsTab = .general
    var body: some View {
        Button("About inklet Portal") {
            selection = .about
            openSettings()
        }
    }
}

private struct SettingsHeightKey: PreferenceKey {
    static let defaultValue: [SettingsTab: CGFloat] = [:]
    static func reduce(value: inout [SettingsTab: CGFloat], nextValue: () -> [SettingsTab: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Shared settings chrome

private struct SettingsPage<Content: View>: View {
    let tab: SettingsTab
    var bottomPadding: CGFloat = 22
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, bottomPadding)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: SettingsHeightKey.self, value: [tab: geometry.size.height])
                }
            }
        }
        .scrollIndicators(.never)
        .background(Ink.bg)
    }
}

/// Titled group of rows — the rows own their padding so the divider can run the
/// full width of the card.
private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel(title)
            InkCard(padding: 0) {
                VStack(spacing: 0) { content }
            }
        }
    }
}

private struct SettingRow<Control: View>: View {
    let title: String
    var subtitle: String?
    var showsDivider = true
    @ViewBuilder var control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14))
                        .foregroundStyle(Ink.text)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(Ink.muted)
                    }
                }
                Spacer(minLength: 12)
                control
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            if showsDivider {
                Rectangle().fill(Ink.cardRule).frame(height: 1)
            }
        }
    }
}
