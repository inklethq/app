import Combine
import Foundation

/// The whole "set up a display over Bluetooth" conversation, UI-agnostic so the
/// iPhone and Mac apps walk the same steps:
///
///   pick display (or scan its QR) → enter the code on its screen → pick the
///   Wi-Fi it should join → wait for it to join → claim it for this account.
///
/// Claiming uses the display's bind credential (the `inklet://bind?…` URI its
/// NFC tag carries), handed over inside the code-secured session; the app
/// supplies `bindHandler` to post it to `POST /api/devices/bind/nfc`.
@MainActor
public final class InkletSetupFlow: ObservableObject {
    public enum Step: Equatable {
        case pickDisplay
        case enterCode(InkletNearbyDisplay)
        case connecting(InkletNearbyDisplay)
        case scanningWiFi
        case pickNetwork
        case joining(String)
        case binding
        case finished(Outcome)
    }

    public enum Outcome: Equatable {
        /// On Wi-Fi and claimed; the new device's id when the server returned it.
        case bound(deviceID: String?)
        /// On Wi-Fi, but the display carries no bind credential (or the app
        /// has no way to use it): it still has to be claimed via its NFC tag.
        case wifiOnly
        /// On Wi-Fi, but the server refused the claim (message is user-facing).
        case bindFailed(String)
    }

    public let central = InkletSetupCentral()
    @Published public private(set) var step: Step = .pickDisplay
    @Published public private(set) var networks: [InkletWiFiNetwork] = []
    @Published public private(set) var info: InkletDisplayInfo?
    /// The last thing that went wrong, worded for the user. Cleared on the
    /// next action.
    @Published public var errorMessage: String?

    /// Claims the display with its bind URI; returns the new device id if known.
    public var bindHandler: (@MainActor (String) async throws -> String?)?

    private var session: InkletSetupSession?
    private var display: InkletNearbyDisplay?

    public init() {}

    public func start() {
        central.startScanning()
    }

    /// Leaving the setup screen: drop the connection and stop scanning.
    public func stop() {
        session?.close()
        session = nil
        central.stopScanning()
    }

    /// Back to the list of nearby displays.
    public func restart() {
        session?.close()
        session = nil
        display = nil
        info = nil
        networks = []
        errorMessage = nil
        step = .pickDisplay
        central.startScanning()
    }

    public func choose(_ display: InkletNearbyDisplay) {
        errorMessage = nil
        self.display = display
        step = .enterCode(display)
    }

    /// The setup QR carries both the display's name and its code.
    public func useQRCode(_ text: String) async {
        guard let qr = InkletSetupQR(text) else {
            errorMessage = "That isn't an inklet setup code."
            return
        }
        errorMessage = nil
        do {
            let match = try await central.waitForDisplay(named: qr.name)
            display = match
            await connect(to: match, code: qr.code)
        } catch {
            fail(error, backTo: .pickDisplay)
        }
    }

    public func submitCode(_ code: String) async {
        guard case .enterCode(let display) = step else { return }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await connect(to: display, code: trimmed)
    }

    public func rescanWiFi() async {
        guard let session else { return restart() }
        // A second tap (or Return plus the default button) while a request is
        // out would talk over it.
        guard step == .pickNetwork else { return }
        errorMessage = nil
        step = .scanningWiFi
        do {
            networks = try await session.scanWiFi()
            step = .pickNetwork
        } catch {
            fail(error, backTo: .pickNetwork)
        }
    }

    public func join(ssid: String, password: String) async {
        guard let session else { return restart() }
        guard step == .pickNetwork else { return }
        errorMessage = nil
        step = .joining(ssid)
        do {
            try await session.joinWiFi(ssid: ssid, password: password)
        } catch let error as InkletSetupError where error == .wifiWrongPassword || error == .wifiNotFound {
            // The display stays in setup; let the user fix it and try again.
            errorMessage = error.errorDescription
            step = .pickNetwork
            return
        } catch {
            fail(error, backTo: .pickNetwork)
            return
        }
        // The display reboots onto Wi-Fi a few seconds from now; this session
        // is over either way.
        session.close()
        self.session = nil
        central.stopScanning()

        guard let uri = info?.bind, !uri.isEmpty, let bindHandler else {
            step = .finished(.wifiOnly)
            return
        }
        step = .binding
        do {
            step = .finished(.bound(deviceID: try await bindHandler(uri)))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            step = .finished(.bindFailed(message))
        }
    }

    private func connect(to display: InkletNearbyDisplay, code: String) async {
        errorMessage = nil
        step = .connecting(display)
        session?.close()
        do {
            let session = try await central.connect(display)
            self.session = session
            try await session.establish(code: code)
            // Before Wi-Fi: once the display joins a network it reboots and
            // this session ends.
            info = try await session.deviceInfo()
            step = .scanningWiFi
            networks = try await session.scanWiFi()
            step = .pickNetwork
        } catch {
            session?.close()
            session = nil
            if (error as? InkletSetupError) == .wrongCode {
                errorMessage = InkletSetupError.wrongCode.errorDescription
                step = .enterCode(display)
            } else {
                fail(error, backTo: .pickDisplay)
            }
        }
    }

    private func fail(_ error: Error, backTo fallback: Step) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if (error as? InkletSetupError) == .disconnected || session?.isOpen != true {
            session?.close()
            session = nil
            step = .pickDisplay
            central.startScanning()
        } else {
            step = fallback
        }
    }
}
