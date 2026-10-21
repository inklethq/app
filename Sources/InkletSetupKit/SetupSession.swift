import CoreBluetooth
import Foundation

/// A Bluetooth setup session with one display, speaking Espressif's
/// network_provisioning protocol: every endpoint is a GATT characteristic the
/// app writes a request to and then reads the reply from.
///
/// Typical use: `establish(code:)` → `deviceInfo()` → `scanWiFi()` →
/// `joinWiFi(ssid:password:)`. Read the device info before joining: once the
/// display is on Wi-Fi it reboots within seconds and the session ends.
@MainActor
public final class InkletSetupSession: NSObject {
    public let display: InkletNearbyDisplay
    let peripheral: CBPeripheral
    private weak var central: InkletSetupCentral?

    private var endpoints: [String: CBCharacteristic] = [:]
    private var security: SetupSecurity1?
    private var pending: CheckedContinuation<Data, Error>?
    private var stepID = 0
    private var closed = false

    /// Endpoint names by the 16-bit id the firmware's provisioning manager
    /// assigns them; used only if a characteristic has no name descriptor.
    private static let fallbackNames: [UInt16: String] = [
        0xFF4F: "prov-ctrl", 0xFF50: "prov-scan", 0xFF51: "prov-session",
        0xFF52: "prov-config", 0xFF53: "proto-ver", 0xFF54: "inklet-device",
    ]

    init(display: InkletNearbyDisplay, peripheral: CBPeripheral, central: InkletSetupCentral) {
        self.display = display
        self.peripheral = peripheral
        self.central = central
        super.init()
        peripheral.delegate = self
    }

    public var isSecured: Bool { security != nil }
    /// False once the link is gone or the session gave up on it.
    public var isOpen: Bool { !closed }

    public func close() {
        guard !closed else { return }
        closed = true
        finishStep(.failure(InkletSetupError.disconnected))
        central?.cancelConnection(peripheral)
    }

    // MARK: Session

    /// Runs the Security 1 handshake with the code printed on the display.
    /// Throws `.wrongCode` when the display rejects it.
    public func establish(code: String) async throws {
        let pop = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let sec = SetupSecurity1()

        var cmd0 = ProtoWriter()
        cmd0.varint(2, 1)                                   // sec_ver = SecScheme1
        cmd0.message(11) { sec1 in                          // sec1
            sec1.varint(1, 0)                               //   msg = Session_Command0
            sec1.message(20) { $0.bytes(1, sec.clientPublicKey) }  // sc0.client_pubkey
        }
        let reply0 = try ProtoMessage(await transact("prov-session", cmd0.data))
        guard let sr0 = try reply0.message(11)?.message(21) else {
            throw InkletSetupError.protocolViolation("no session response")
        }
        guard sr0.varint(1) == 0, let devicePublicKey = sr0.bytes(2), let deviceRandom = sr0.bytes(3) else {
            throw InkletSetupError.protocolViolation("session refused (\(sr0.varint(1)))")
        }
        try sec.start(devicePublicKey: devicePublicKey, deviceRandom: deviceRandom, proofOfPossession: pop)

        var cmd1 = ProtoWriter()
        cmd1.varint(2, 1)
        let clientVerify = try sec.apply(devicePublicKey)
        cmd1.message(11) { sec1 in
            sec1.varint(1, 2)                               // msg = Session_Command1
            sec1.message(22) { $0.bytes(2, clientVerify) }  // sc1.client_verify_data
        }
        // A wrong code makes the display's check fail; it drops the request
        // (an ATT error or an empty reply) rather than answering.
        let reply1: ProtoMessage
        do {
            reply1 = try ProtoMessage(await transact("prov-session", cmd1.data))
        } catch InkletSetupError.disconnected {
            throw InkletSetupError.wrongCode
        } catch is CBATTError {
            throw InkletSetupError.wrongCode
        }
        guard let sr1 = try reply1.message(11)?.message(23), sr1.varint(1) == 0,
              let deviceVerify = sr1.bytes(3),
              try sec.apply(deviceVerify) == sec.clientPublicKey
        else { throw InkletSetupError.wrongCode }
        security = sec
    }

    /// Who the display is, and its bind credential if the factory issued one.
    public func deviceInfo() async throws -> InkletDisplayInfo {
        let reply = try await secureTransact("inklet-device", Data("{}".utf8))
        do {
            return try JSONDecoder().decode(InkletDisplayInfo.self, from: reply)
        } catch {
            throw InkletSetupError.protocolViolation("device info")
        }
    }

    // MARK: Wi-Fi

    /// Networks the display itself can see (it may be in a different spot, and
    /// on a different band, than this phone or Mac), strongest first.
    public func scanWiFi() async throws -> [InkletWiFiNetwork] {
        var start = ProtoWriter()
        start.varint(1, 0)                                  // TypeCmdScanWifiStart
        start.message(10) { cmd in                          // cmd_scan_wifi_start
            cmd.bool(1, true)                               //   blocking
            cmd.bool(2, false)                              //   passive
            cmd.varint(3, 0)                                //   group_channels
            cmd.varint(4, 120)                              //   period_ms
        }
        try checkScanStatus(try ProtoMessage(await secureTransact("prov-scan", start.data, timeout: 30)))

        var count = 0
        for _ in 0..<30 {
            var status = ProtoWriter()
            status.varint(1, 2)                             // TypeCmdScanWifiStatus
            status.message(12)
            let reply = try ProtoMessage(await secureTransact("prov-scan", status.data))
            try checkScanStatus(reply)
            guard let st = try reply.message(13) else { throw InkletSetupError.protocolViolation("scan status") }
            if st.bool(1) {                                 // scan_finished
                count = Int(st.varint(2))                   // result_count
                break
            }
            try await Task.sleep(for: .milliseconds(500))
        }

        var best: [String: InkletWiFiNetwork] = [:]
        var index = 0
        while index < count {
            let batch = min(4, count - index)
            var request = ProtoWriter()
            request.varint(1, 4)                            // TypeCmdScanWifiResult
            request.message(14) { cmd in
                cmd.varint(1, UInt64(index))                //   start_index
                cmd.varint(2, UInt64(batch))                //   count
            }
            let reply = try ProtoMessage(await secureTransact("prov-scan", request.data))
            try checkScanStatus(reply)
            guard let results = try reply.message(15) else { throw InkletSetupError.protocolViolation("scan results") }
            for entry in try results.messages(1) {
                let ssid = String(decoding: entry.bytes(1) ?? Data(), as: UTF8.self)
                guard !ssid.isEmpty else { continue }       // hidden networks
                let network = InkletWiFiNetwork(ssid: ssid, rssi: Int(entry.int32(3)),
                                                channel: Int(entry.varint(2)), secured: entry.varint(5) != 0)
                if let known = best[ssid], known.rssi >= network.rssi { continue }
                best[ssid] = network
            }
            index += batch
        }
        return best.values.sorted { $0.rssi > $1.rssi }
    }

    /// Hands the display a network and waits until it has actually joined it.
    /// Throws `.wifiWrongPassword` / `.wifiNotFound` so the user can retry in
    /// the same session.
    public func joinWiFi(ssid: String, password: String) async throws {
        var set = ProtoWriter()
        set.varint(1, 2)                                    // TypeCmdSetWifiConfig
        set.message(12) { cmd in
            cmd.bytes(1, Data(ssid.utf8))                   //   ssid
            cmd.bytes(2, Data(password.utf8))               //   passphrase
        }
        let setReply = try ProtoMessage(await secureTransact("prov-config", set.data))
        guard let setResp = try setReply.message(13), setResp.varint(1) == 0 else {
            throw InkletSetupError.protocolViolation("set Wi-Fi refused")
        }

        var apply = ProtoWriter()
        apply.varint(1, 4)                                  // TypeCmdApplyWifiConfig
        apply.message(14)
        let applyReply = try ProtoMessage(await secureTransact("prov-config", apply.data))
        guard let applyResp = try applyReply.message(15), applyResp.varint(1) == 0 else {
            throw InkletSetupError.protocolViolation("apply Wi-Fi refused")
        }

        for _ in 0..<45 {
            try await Task.sleep(for: .seconds(1))
            var get = ProtoWriter()
            get.varint(1, 0)                                // TypeCmdGetWifiStatus
            get.message(10)
            let reply = try ProtoMessage(await secureTransact("prov-config", get.data))
            guard let status = try reply.message(11) else { throw InkletSetupError.protocolViolation("Wi-Fi status") }
            // Connected (0) is proto3's default and so never on the wire; the
            // wifi_connected details (field 11) are what really says so.
            if status.has(11) { return }
            switch status.varint(2) {                       // wifi_sta_state
            case 3:                                         // ConnectionFailed
                throw status.varint(10) == 0 ? InkletSetupError.wifiWrongPassword : InkletSetupError.wifiNotFound
            default:
                continue                                    // Connecting / Disconnected (retrying)
            }
        }
        throw InkletSetupError.wifiTimeout
    }

    private func checkScanStatus(_ reply: ProtoMessage) throws {
        let status = reply.varint(2)
        if status != 0 { throw InkletSetupError.protocolViolation("scan refused (\(status))") }
    }

    // MARK: Transport

    func handleDisconnect() {
        closed = true
        finishStep(.failure(InkletSetupError.disconnected))
    }

    /// Reads each characteristic's user-description descriptor, which carries
    /// the endpoint name ("prov-session", "prov-config", …).
    func mapEndpoints() async throws {
        try await step { peripheral.discoverServices([InkletSetupCentral.serviceUUID]) }
        guard let service = peripheral.services?.first(where: { $0.uuid == InkletSetupCentral.serviceUUID }) else {
            throw InkletSetupError.missingEndpoint("Bluetooth setup")
        }
        try await step { peripheral.discoverCharacteristics(nil, for: service) }
        let nameUUID = CBUUID(string: CBUUIDCharacteristicUserDescriptionString)
        for characteristic in service.characteristics ?? [] {
            try await step { peripheral.discoverDescriptors(for: characteristic) }
            if let descriptor = characteristic.descriptors?.first(where: { $0.uuid == nameUUID }) {
                try await step { peripheral.readValue(for: descriptor) }
                if let name = Self.descriptorString(descriptor.value), !name.isEmpty {
                    endpoints[name] = characteristic
                    continue
                }
            }
            if let name = Self.fallbackName(for: characteristic.uuid) {
                endpoints[name] = characteristic
            }
        }
        guard endpoints["prov-session"] != nil, endpoints["prov-config"] != nil else {
            throw InkletSetupError.missingEndpoint("Wi-Fi setup")
        }
    }

    private func secureTransact(_ endpoint: String, _ request: Data, timeout: TimeInterval = 15) async throws -> Data {
        guard let security else { throw InkletSetupError.protocolViolation("session not established") }
        guard endpoints[endpoint] != nil else { throw InkletSetupError.missingEndpoint(endpoint) }
        // Encrypting the request advances the shared keystream. If its reply
        // never arrives, this end and the display no longer agree on where the
        // stream is, and everything after would decrypt to noise: end the
        // session rather than keep talking past it.
        let reply: Data
        do {
            reply = try await transact(endpoint, try security.apply(request), timeout: timeout)
        } catch {
            close()
            throw error
        }
        return try security.apply(reply)
    }

    private func transact(_ endpoint: String, _ request: Data, timeout: TimeInterval = 15) async throws -> Data {
        guard let characteristic = endpoints[endpoint] else { throw InkletSetupError.missingEndpoint(endpoint) }
        try await step(timeout: timeout) { peripheral.writeValue(request, for: characteristic, type: .withResponse) }
        return try await dataStep(timeout: timeout) { peripheral.readValue(for: characteristic) }
    }

    private func step(timeout: TimeInterval = 10, _ start: () -> Void) async throws {
        _ = try await dataStep(timeout: timeout, start)
    }

    private func dataStep(timeout: TimeInterval = 10, _ start: () -> Void) async throws -> Data {
        guard !closed else { throw InkletSetupError.disconnected }
        // One request at a time: there is a single continuation slot, and the
        // keystream has to be consumed in order.
        guard pending == nil else { throw InkletSetupError.protocolViolation("busy") }
        stepID += 1
        let id = stepID
        return try await awaitStep(timeout: timeout, onTimeout: { [weak self] in
            guard let self, self.stepID == id else { return }
            self.finishStep(.failure(InkletSetupError.timeout))
        }) { continuation in
            pending = continuation
            start()
        }
    }

    private func finishStep(_ result: Result<Data, Error>) {
        guard let continuation = pending else { return }
        pending = nil
        continuation.resume(with: result)
    }

    private func finishStep(error: Error?, value: Data? = nil) {
        if let error {
            finishStep(.failure(error))
        } else {
            finishStep(.success(value ?? Data()))
        }
    }

    private static func descriptorString(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let data = value as? Data { return String(data: data, encoding: .utf8) }
        return nil
    }

    private static func fallbackName(for uuid: CBUUID) -> String? {
        let bytes = [UInt8](uuid.data)
        guard bytes.count == 16 else { return nil }
        return fallbackNames[UInt16(bytes[2]) << 8 | UInt16(bytes[3])]
    }
}

extension InkletSetupSession: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        finishStep(error: error)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        finishStep(error: error)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic,
                           error: Error?) {
        finishStep(error: error)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor,
                           error: Error?) {
        finishStep(error: error)
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        finishStep(error: error)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        finishStep(error: error, value: characteristic.value)
    }
}
