import Combine
import CoreBluetooth
import Foundation

/// Finds inklet displays that are in their Bluetooth setup window and opens a
/// setup session with one. Displays only advertise for 3 minutes after the
/// user holds the touch strip on an offline display; nothing advertises the
/// rest of the time.
@MainActor
public final class InkletSetupCentral: NSObject, ObservableObject {
    /// GATT service of the display's setup window (firmware: inklet_prov.cpp).
    public static let serviceUUID = CBUUID(string: "916F2646-B8AC-4CB2-AD93-897B29D2D87D")
    public static let namePrefix = "INKLET-"

    @Published public private(set) var bluetoothState: CBManagerState = .unknown
    @Published public private(set) var displays: [InkletNearbyDisplay] = []

    // Created on first use: creating it is what shows the Bluetooth prompt.
    private lazy var central = CBCentralManager(delegate: self, queue: .main)
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var lastSeen: [UUID: Date] = [:]
    private var wantsScan = false
    private var pruneTask: Task<Void, Never>?
    private var pendingConnect: (id: UUID, continuation: CheckedContinuation<Void, Error>)?
    private weak var session: InkletSetupSession?

    public override init() {
        super.init()
    }

    /// Why Bluetooth can't be used right now, if it can't.
    public var unavailableReason: InkletSetupError? {
        switch bluetoothState {
        case .poweredOff: return .bluetoothOff
        case .unauthorized: return .bluetoothUnauthorized
        case .unsupported: return .bluetoothUnsupported
        default: return nil
        }
    }

    public func startScanning() {
        wantsScan = true
        if central.state == .poweredOn { beginScan() }
    }

    public func stopScanning() {
        wantsScan = false
        pruneTask?.cancel()
        pruneTask = nil
        if central.state == .poweredOn { central.stopScan() }
    }

    /// The nearby display advertising `name` (from the setup QR code), waiting
    /// up to `timeout` for it to show up.
    public func waitForDisplay(named name: String, timeout: TimeInterval = 10) async throws -> InkletNearbyDisplay {
        startScanning()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let reason = unavailableReason { throw reason }
            if let match = displays.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return match
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw InkletSetupError.displayNotFound
    }

    /// Connects and maps the display's setup endpoints. The session is not yet
    /// secured: call `establish(code:)` next.
    public func connect(_ display: InkletNearbyDisplay, timeout: TimeInterval = 15) async throws -> InkletSetupSession {
        if let reason = unavailableReason { throw reason }
        guard let peripheral = peripherals[display.id] else { throw InkletSetupError.displayNotFound }
        stopScanning()
        session?.close()

        try await awaitStep(timeout: timeout, onTimeout: { [weak self] in
            self?.failPendingConnect(.connectionFailed)
        }) { c in
            pendingConnect = (peripheral.identifier, c)
            central.connect(peripheral)
        }

        let session = InkletSetupSession(display: display, peripheral: peripheral, central: self)
        self.session = session
        do {
            try await session.mapEndpoints()
        } catch {
            session.close()
            throw error
        }
        return session
    }

    func cancelConnection(_ peripheral: CBPeripheral) {
        if central.state == .poweredOn { central.cancelPeripheralConnection(peripheral) }
    }

    private func beginScan() {
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        pruneTask?.cancel()
        pruneTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.pruneStale()
            }
        }
    }

    /// A display stops advertising when its setup window closes; drop it.
    private func pruneStale() {
        let cutoff = Date().addingTimeInterval(-8)
        let stale = lastSeen.filter { $0.value < cutoff }.map(\.key)
        guard !stale.isEmpty else { return }
        for id in stale { lastSeen[id] = nil }
        displays.removeAll { stale.contains($0.id) }
    }

    private func failPendingConnect(_ error: InkletSetupError) {
        guard let pending = pendingConnect else { return }
        pendingConnect = nil
        if let peripheral = peripherals[pending.id] { cancelConnection(peripheral) }
        pending.continuation.resume(throwing: error)
    }
}

extension InkletSetupCentral: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        if central.state == .poweredOn {
            if wantsScan { beginScan() }
        } else {
            displays = []
            if let reason = unavailableReason { failPendingConnect(reason) }
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let named = advertisedName?.uppercased().hasPrefix(Self.namePrefix) ?? false
        guard named || services.contains(Self.serviceUUID) else { return }

        let rssi = RSSI.intValue
        guard rssi < 0 else { return }   // 127 = "not available"
        peripherals[peripheral.identifier] = peripheral
        lastSeen[peripheral.identifier] = Date()
        let name = advertisedName ?? "INKLET"
        if let i = displays.firstIndex(where: { $0.id == peripheral.identifier }) {
            if displays[i].name != name || abs(displays[i].rssi - rssi) >= 6 {
                displays[i] = InkletNearbyDisplay(id: peripheral.identifier, name: name, rssi: rssi)
            }
        } else {
            displays.append(InkletNearbyDisplay(id: peripheral.identifier, name: name, rssi: rssi))
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let pending = pendingConnect, pending.id == peripheral.identifier else { return }
        pendingConnect = nil
        pending.continuation.resume()
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                               error: Error?) {
        guard pendingConnect?.id == peripheral.identifier else { return }
        failPendingConnect(.connectionFailed)
    }

    // Only ever about a connection that was established. It can arrive late —
    // after a wrong code the display drops the link and the app is already
    // reconnecting — so it must not touch a connect still in flight; a failed
    // connect is reported through didFailToConnect instead.
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        if let session, session.peripheral.identifier == peripheral.identifier {
            session.handleDisconnect()
        }
    }
}

/// One delegate-driven Bluetooth step: `start` kicks it off and stores the
/// continuation for the delegate callback to resume. If it is still pending
/// after `timeout`, `onTimeout` runs (on the main actor) and must resume it
/// with an error — and must be a no-op when the step already finished.
@MainActor
func awaitStep<T>(
    timeout: TimeInterval,
    onTimeout: @escaping @MainActor () -> Void,
    _ start: (CheckedContinuation<T, Error>) -> Void
) async throws -> T {
    let timer = Task { @MainActor in
        try? await Task.sleep(for: .seconds(timeout))
        if !Task.isCancelled { onTimeout() }
    }
    defer { timer.cancel() }
    return try await withCheckedThrowingContinuation(start)
}
