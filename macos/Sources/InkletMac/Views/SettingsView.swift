import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AccountSettings()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
            NotificationSettings()
                .tabItem { Label("Notifications", systemImage: "bell") }
        }
        .tint(Ink.text)
        .background(Ink.bg)
        // The tab strip is a real NSToolbar with its own vibrant material, which
        // reads blue-grey next to the app's flat background. Paint it to match.
        .toolbarBackground(Ink.bg, for: .windowToolbar)
        .background(WindowStyler().frame(width: 0, height: 0))
        .frame(width: 520, height: 400)
    }
}

private struct GeneralSettings: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = true
    @AppStorage("showInDock") private var showInDock = false
    @AppStorage("showWeather") private var showWeather = true

    var body: some View {
        SettingsPage {
            SettingsGroup("Startup") {
                SettingRow(title: "Launch at login",
                           subtitle: "Start in the menu bar when you log in") {
                    Toggle("", isOn: $launchAtLogin).labelsHidden()
                }
                SettingRow(title: "Show in Dock",
                           subtitle: "With this off, inklet lives in the menu bar only",
                           showsDivider: false) {
                    Toggle("", isOn: $showInDock).labelsHidden()
                }
            }

            SettingsGroup("Composer") {
                SettingRow(title: "Global shortcut",
                           subtitle: "Opens the composer from any app · ⌫ restores the default") {
                    ShortcutRecorder()
                }
                SettingRow(title: "Weather on Home",
                           subtitle: "Uses your location, via Apple Weather",
                           showsDivider: false) {
                    Toggle("", isOn: $showWeather).labelsHidden()
                }
            }
        }
    }
}

private struct AccountSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(Session.self) private var session

    var body: some View {
        SettingsPage {
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
    @AppStorage("notifyDelivered") private var delivered = true
    @AppStorage("notifyFailed") private var failed = true
    @AppStorage("notifyOffline") private var offline = false

    var body: some View {
        SettingsPage {
            SettingsGroup("Alerts") {
                SettingRow(title: "Content delivered",
                           subtitle: "When a push reaches a display's queue") {
                    Toggle("", isOn: $delivered).labelsHidden()
                }
                SettingRow(title: "Push failed",
                           subtitle: "Retry straight from the notification") {
                    Toggle("", isOn: $failed).labelsHidden()
                }
                SettingRow(title: "Display went offline",
                           subtitle: "Needs server-side events — not wired up yet",
                           showsDivider: false) {
                    Toggle("", isOn: $offline).labelsHidden()
                }
            }
        }
    }
}

// MARK: - Shared settings chrome

private struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 22)
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
