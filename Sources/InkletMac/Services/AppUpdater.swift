import AppKit
import Combine
import Sparkle
import SwiftUI

/// Sparkle-backed updates for the direct-download build.
///
/// `Scripts/build-app.sh` embeds `Sparkle.framework` and writes `SUFeedURL`
/// and `SUPublicEDKey` into the app's Info.plist. A bare `swift run` binary has
/// neither, so the updater only starts when those keys exist; everything else
/// (menu item, settings toggles) degrades to disabled instead of crashing or
/// showing Sparkle's misconfiguration alert.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    /// Whether this process is a packaged build that can actually update.
    let isAvailable: Bool

    /// Pre-release builds (a `-` in the marketing version, e.g. `0.2.0-beta.1`)
    /// always see the `beta` channel; stable builds opt in here.
    @AppStorage("InkletBetaUpdates") var includesBetaUpdates = false

    @Published private(set) var canCheckForUpdates = false

    private let channels = UpdateChannels()
    private let controller: SPUStandardUpdaterController
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        isAvailable = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
            && Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: channels, userDriverDelegate: nil)
        channels.includesBeta = { [weak self] in
            guard let self else { return false }
            return Self.isPrereleaseBuild || self.includesBetaUpdates
        }
        guard isAvailable else { return }
        controller.startUpdater()
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &cancellables)
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastUpdateCheckDate: Date? { controller.updater.lastUpdateCheckDate }

    /// User-initiated check: Sparkle shows progress and either the update
    /// sheet (Install / Remind Me Later / Skip This Version) or "up to date".
    func checkForUpdates() {
        guard isAvailable else { return }
        controller.checkForUpdates(nil)
    }

    static var isPrereleaseBuild: Bool {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return version.contains("-")
    }
}

/// Sparkle asks its delegate which extra channels to read from the appcast.
/// Items without a channel are always visible; `beta` items only when allowed.
private final class UpdateChannels: NSObject, SPUUpdaterDelegate {
    nonisolated(unsafe) var includesBeta: () -> Bool = { false }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        includesBeta() ? ["beta"] : []
    }
}

/// "Check for Updates…" for the application menu.
struct CheckForUpdatesCommand: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.isAvailable || !updater.canCheckForUpdates)
    }
}
