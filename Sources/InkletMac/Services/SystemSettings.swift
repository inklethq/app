import AppKit
import CoreLocation
import Observation
import ServiceManagement
import UserNotifications

/// The settings that reach outside the app: login items, the Dock, system
/// notifications, and the weather chip's location. Each one degrades to
/// "unavailable" in a bare `swift run` binary, which has no bundle for the
/// system to register or notify on behalf of.
enum SystemSettings {
    /// True for a packaged `.app`; false under `swift run` or a test host.
    static var isBundled: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    // MARK: UserDefaults keys the views and services share

    static let showInDockKey = "showInDock"
    static let showWeatherKey = "showWeather"
    static let notifyDeliveredKey = "notifyDelivered"
    static let notifyFailedKey = "notifyFailed"
    static let notifyOfflineKey = "notifyOffline"
}

// MARK: - Launch at login

/// `SMAppService` is the source of truth: the toggle reads the system's answer
/// rather than a stored preference that may have drifted from it.
@MainActor
@Observable
final class LaunchAtLogin {
    static let shared = LaunchAtLogin()

    private(set) var isEnabled = false
    private(set) var requiresApproval = false
    var error: String?

    let isAvailable = SystemSettings.isBundled

    private init() { refresh() }

    func refresh() {
        guard isAvailable else { return }
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }

    func set(_ enabled: Bool) {
        guard isAvailable else { return }
        error = nil
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    /// The system can hold a login item in "requires approval"; the user has to
    /// allow it in System Settings, which this opens.
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

// MARK: - Dock

/// "Show in Dock" only governs the app while it is nothing but the composer
/// panel. Whenever a real window (Home, Settings) is on screen the Dock icon
/// is shown regardless — a window with no Dock presence has nowhere to
/// go when it is minimised and cannot be found from the app switcher.
@MainActor
enum DockVisibility {
    private static var observers: [NSObjectProtocol] = []

    /// Called once at launch: applies the policy and keeps it in step with
    /// windows opening and closing.
    static func install() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                // `willClose` fires while the window still counts as visible;
                // re-evaluating on the next turn sees the window gone.
                Task { @MainActor in refresh() }
            })
        }
        refresh()
    }

    static var showInDock: Bool {
        UserDefaults.standard.object(forKey: SystemSettings.showInDockKey) as? Bool ?? true
    }

    /// A visible window that is not the composer panel or another utility panel.
    private static var hasMainWindow: Bool {
        NSApp.windows.contains { window in
            window.isVisible && !window.isMiniaturized && !(window is NSPanel)
                && window.styleMask.contains(.titled)
        }
    }

    static func refresh() {
        let policy: NSApplication.ActivationPolicy = (showInDock || hasMainWindow) ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular, hasMainWindow { NSApp.activate() }
    }
}

// MARK: - Notifications

/// System notifications for what the app does in the background: a card that
/// reached its display, one that failed, and a display that dropped offline.
@MainActor
@Observable
final class Notifier {
    static let shared = Notifier()

    enum Kind {
        case delivered, failed, offline

        var key: String {
            switch self {
            case .delivered: SystemSettings.notifyDeliveredKey
            case .failed: SystemSettings.notifyFailedKey
            case .offline: SystemSettings.notifyOfflineKey
            }
        }
    }

    let isAvailable = SystemSettings.isBundled
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    private init() {
        guard isAvailable else { return }
        Task { await refreshAuthorization() }
    }

    func refreshAuthorization() async {
        guard isAvailable else { return }
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Asked when the first notification toggle is switched on, not at launch.
    @discardableResult
    func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        await refreshAuthorization()
        return granted
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Posts only when the matching toggle is on and the system allows it.
    func post(_ kind: Kind, title: String, body: String, id: String? = nil) {
        guard isAvailable, UserDefaults.standard.bool(forKey: kind.key) else { return }
        guard authorization == .authorized || authorization == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = kind == .failed ? .default : nil
        let request = UNNotificationRequest(identifier: id ?? UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Weather

/// The Home page's weather chip. Location comes from CoreLocation; conditions
/// from Open-Meteo, which needs no key and no WeatherKit entitlement.
@MainActor
@Observable
final class WeatherService: NSObject, CLLocationManagerDelegate {
    static let shared = WeatherService()

    struct Current: Equatable {
        var temperatureC: Double
        var code: Int
        var fetchedAt: Date

        var summary: String { WeatherService.describe(code) }
        var symbol: String { WeatherService.symbol(for: code) }
        var temperature: String {
            let measurement = Measurement(value: temperatureC, unit: UnitTemperature.celsius)
            return measurement.formatted(.measurement(width: .narrow, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0))))
        }
    }

    private(set) var current: Current?
    /// Why there is no chip: permission, no fix, or a network failure.
    private(set) var problem: String?
    private(set) var isLoading = false

    private let manager = CLLocationManager()
    private var pendingFetch = false
    private let session = URLSession(configuration: .ephemeral)

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    var isDenied: Bool {
        manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted
    }

    /// Refreshes when the chip is enabled and the last fix is older than 30 minutes.
    /// Never the thing that asks for location: Home calls this on every visit,
    /// and the prompt belongs to the moment the user turns weather on.
    func refreshIfStale() {
        if let current, Date().timeIntervalSince(current.fetchedAt) < 30 * 60 { return }
        guard manager.authorizationStatus != .notDetermined else { return }
        refresh()
    }

    /// Asks for location access if it hasn't been asked for yet — so only from
    /// turning the setting on, or a chip that can't exist without access.
    func refresh() {
        guard !isLoading else { return }
        problem = nil
        switch manager.authorizationStatus {
        case .notDetermined:
            pendingFetch = true
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            problem = "Location access is off for inklet Portal in System Settings."
        default:
            isLoading = true
            manager.requestLocation()
        }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard pendingFetch else { return }
            pendingFetch = false
            refresh()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let coordinate = location.coordinate
        Task { @MainActor in await fetch(latitude: coordinate.latitude, longitude: coordinate.longitude) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            isLoading = false
            problem = "Couldn't find your location."
        }
    }

    private struct Response: Decodable {
        struct CurrentBlock: Decodable {
            let temperature_2m: Double
            let weather_code: Int
        }
        let current: CurrentBlock
    }

    private func fetch(latitude: Double, longitude: Double) async {
        defer { isLoading = false }
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(format: "%.2f", latitude)),
            .init(name: "longitude", value: String(format: "%.2f", longitude)),
            .init(name: "current", value: "temperature_2m,weather_code"),
        ]
        guard let url = components.url else { return }
        do {
            let (data, _) = try await session.data(from: url)
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            current = Current(temperatureC: decoded.current.temperature_2m, code: decoded.current.weather_code, fetchedAt: Date())
        } catch {
            problem = "Weather is unavailable right now."
        }
    }

    /// WMO weather interpretation codes, as Open-Meteo reports them.
    nonisolated static func describe(_ code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1: "Mostly clear"
        case 2: "Partly cloudy"
        case 3: "Overcast"
        case 45, 48: "Fog"
        case 51, 53, 55, 56, 57: "Drizzle"
        case 61, 63, 65, 66, 67: "Rain"
        case 71, 73, 75, 77: "Snow"
        case 80, 81, 82: "Showers"
        case 85, 86: "Snow showers"
        case 95: "Thunderstorm"
        case 96, 99: "Thunderstorm with hail"
        default: "Weather"
        }
    }

    nonisolated static func symbol(for code: Int) -> String {
        switch code {
        case 0: "sun.max"
        case 1, 2: "cloud.sun"
        case 3: "cloud"
        case 45, 48: "cloud.fog"
        case 51, 53, 55, 56, 57: "cloud.drizzle"
        case 61, 63, 65, 66, 67, 80, 81, 82: "cloud.rain"
        case 71, 73, 75, 77, 85, 86: "cloud.snow"
        case 95, 96, 99: "cloud.bolt.rain"
        default: "cloud"
        }
    }
}
