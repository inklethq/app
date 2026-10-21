import Foundation

/// An inklet display that is advertising its Bluetooth setup window. Displays
/// only do so for 3 minutes after the user holds the touch strip while the
/// display is offline, so anything in this list is asking to be set up.
public struct InkletNearbyDisplay: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// "INKLET-2078": the name printed on the setup screen next to the code.
    public let name: String
    public var rssi: Int
}

public struct InkletWiFiNetwork: Identifiable, Hashable, Sendable {
    public var id: String { ssid }
    public let ssid: String
    public let rssi: Int
    public let channel: Int
    /// False for open networks: no password field needed.
    public let secured: Bool

    /// 0...3 bars for a signal icon.
    public var bars: Int {
        switch rssi {
        case (-55)...: return 3
        case (-67)...: return 2
        case (-80)...: return 1
        default: return 0
        }
    }
}

/// What the display reports about itself over the secured session. `bind` is
/// the display's claim credential — the same `inklet://bind?v=2&…` URI its NFC
/// tag carries — when the factory issued one.
public struct InkletDisplayInfo: Decodable, Equatable, Sendable {
    public let hwId: String
    public let thingName: String
    public let firmware: String?
    public let bind: String?
}

/// The setup screen's QR code: Espressif's standard provisioning JSON,
/// `{"ver":"v1","name":"INKLET-2078","pop":"Q4VV4MA5","transport":"ble"}`.
public struct InkletSetupQR: Equatable, Sendable {
    public let name: String
    public let code: String

    public init?(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String, let pop = obj["pop"] as? String,
              (obj["transport"] as? String ?? "ble") == "ble", !name.isEmpty, !pop.isEmpty
        else { return nil }
        self.name = name
        self.code = pop
    }
}

public enum InkletSetupError: LocalizedError, Equatable {
    case bluetoothOff
    case bluetoothUnauthorized
    case bluetoothUnsupported
    case displayNotFound
    case connectionFailed
    case disconnected
    case wrongCode
    case wifiWrongPassword
    case wifiNotFound
    case wifiTimeout
    case timeout
    case missingEndpoint(String)
    case protocolViolation(String)

    public var errorDescription: String? {
        switch self {
        case .bluetoothOff: return "Bluetooth is off. Turn it on to set up your display."
        case .bluetoothUnauthorized: return "inklet needs Bluetooth access to set up your display. Allow it in Settings."
        case .bluetoothUnsupported: return "This device doesn't support Bluetooth Low Energy."
        case .displayNotFound: return "Couldn't find that display. Make sure the setup screen is still showing."
        case .connectionFailed: return "Couldn't connect to the display. Move closer and try again."
        case .disconnected: return "The display disconnected. If the setup screen timed out, hold the touch strip for 3 seconds to start again."
        case .wrongCode: return "That code doesn't match. Check the code printed under the QR code on the display."
        case .wifiWrongPassword: return "The Wi-Fi password is incorrect."
        case .wifiNotFound: return "The display can't see that Wi-Fi network. It needs to be in range."
        case .wifiTimeout: return "The display didn't manage to join the Wi-Fi network."
        case .timeout: return "The display stopped responding."
        case .missingEndpoint(let name): return "This display's firmware doesn't support \(name)."
        case .protocolViolation(let what): return "Unexpected reply from the display (\(what))."
        }
    }
}
