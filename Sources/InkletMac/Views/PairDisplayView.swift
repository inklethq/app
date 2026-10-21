import InkletSetupKit
import SwiftUI

/// Setting up an inklet display from the Mac over Bluetooth: it gives the
/// display its Wi-Fi and claims it for this account in one pass. A display
/// only opens its 3-minute setup window when it can't get online and the user
/// holds its touch strip; it then shows a QR code with an 8-character code
/// under it. A Mac has no camera flow here, so the user picks the display from
/// the list and types the code instead.
struct PairDisplayView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?
    @StateObject private var flow = InkletSetupFlow()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Set up a display").font(.brand(34)).foregroundStyle(Ink.text)
                    Text("Your Mac connects to the display over Bluetooth, gives it your Wi-Fi, and adds it to your account.")
                        .font(.system(size: 14)).foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                stepView
                if let error = flow.errorMessage {
                    Text(error).font(.system(size: 13)).foregroundStyle(Ink.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 640, alignment: .leading).padding(32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.never)
        .foregroundStyle(Ink.text)
        .background(Ink.bg)
        .navigationTitle("Pair Display")
        .onAppear {
            flow.bindHandler = { uri in try await model.bindDisplay(uri: uri).id }
            flow.start()
        }
        .onDisappear { flow.stop() }
        // Once setup is over, a display that joins the list — claimed here, or
        // from the iPhone's NFC tap and then Refresh — is the one to open.
        // Refresh keeps the server's order, so look for the new id rather
        // than trusting a position.
        .onChange(of: model.devices.map(\.id)) { previous, current in
            guard case .finished = flow.step,
                  let added = current.first(where: { !previous.contains($0) }) else { return }
            selection = .device(added)
        }
    }

    @ViewBuilder private var stepView: some View {
        switch flow.step {
        case .pickDisplay:
            NearbyDisplaysCard(central: flow.central) { flow.choose($0) }
        case .enterCode(let display):
            CodeEntryCard(display: display,
                          onSubmit: { code in Task { await flow.submitCode(code) } },
                          onBack: { flow.restart() })
        case .connecting(let display):
            ProgressCard(title: "Connecting to \(display.name)…",
                         detail: "Your Mac may ask to pair with the display. Allow it.")
        case .scanningWiFi:
            ProgressCard(title: "Looking for Wi-Fi…", detail: "The display is listing the networks it can see.")
        case .pickNetwork:
            NetworkPickerCard(networks: flow.networks,
                              onJoin: { ssid, password in Task { await flow.join(ssid: ssid, password: password) } },
                              onRescan: { Task { await flow.rescanWiFi() } })
        case .joining(let ssid):
            ProgressCard(title: "Joining \(ssid)…", detail: "This can take up to half a minute.")
        case .binding:
            ProgressCard(title: "Adding the display to your account…", detail: nil)
        case .finished(let outcome):
            FinishedCard(outcome: outcome,
                         onOpen: { id in selection = .device(id) },
                         onRefresh: { Task { await model.refresh() } },
                         onAnother: { flow.restart() })
        }
    }
}

// MARK: - Steps

private struct NearbyDisplaysCard: View {
    @ObservedObject var central: InkletSetupCentral
    let onChoose: (InkletNearbyDisplay) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            InkCard(padding: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel("On the display")
                    PairStep(1, "It shows WIFI OFFLINE or SET UP WIFI when it can't get online.")
                    PairStep(2, "Hold the touch strip for 3 seconds. A QR code and a code appear.")
                    PairStep(3, "Choose it below. Bluetooth stays on for 3 minutes.")
                }
            }
            InkCard(padding: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        SectionLabel("Nearby displays")
                        Spacer()
                        if central.unavailableReason == nil { ProgressView().controlSize(.small) }
                    }
                    if let reason = central.unavailableReason {
                        Text(reason.errorDescription ?? "Bluetooth is unavailable.")
                            .font(.system(size: 13)).foregroundStyle(Ink.danger)
                    } else if central.displays.isEmpty {
                        Text("Searching… Displays appear here while their setup screen is showing.")
                            .font(.system(size: 13)).foregroundStyle(Ink.secondary)
                    } else {
                        ForEach(central.displays) { display in
                            Button { onChoose(display) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "rectangle.inset.filled").font(.system(size: 20, weight: .light))
                                    Text(display.name).font(.system(size: 14, weight: .medium, design: .monospaced))
                                    Spacer()
                                    SignalBars(bars: display.rssi > -60 ? 3 : display.rssi > -75 ? 2 : 1)
                                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Ink.muted)
                                }
                                .padding(12)
                                .background(Ink.input, in: .rect(cornerRadius: Ink.controlCorner))
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            // A display that is already online never opens a setup window, so
            // this page can't reach it; its NFC tag still can.
            Text("Already online? Tap the NFC tag on its back with the inklet app on your iPhone, and it shows up in the sidebar.")
                .font(.system(size: 12)).foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CodeEntryCard: View {
    let display: InkletNearbyDisplay
    let onSubmit: (String) -> Void
    let onBack: () -> Void
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button(action: onBack) { Label("Nearby displays", systemImage: "chevron.left") }
                .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Ink.secondary)
            InkCard(padding: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Code shown on \(display.name)")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.secondary)
                    TextField("ABCD2345", text: $code)
                        .textFieldStyle(.plain).font(.system(size: 22, weight: .medium, design: .monospaced))
                        .padding(12).background(Ink.input, in: .rect(cornerRadius: Ink.controlCorner))
                        .autocorrectionDisabled()
                        .onSubmit(submit)
                        .onChange(of: code) { _, value in
                            let cleaned = String(value.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(8))
                            if cleaned != value { code = cleaned }
                        }
                        .accessibilityLabel("Setup code")
                    Text("It's printed under the QR code, next to the display's name.")
                        .font(.system(size: 12)).foregroundStyle(Ink.muted)
                }
            }
            PrimaryButton(title: "Connect", enabled: code.count == 8, action: submit)
        }
    }

    private func submit() {
        guard code.count == 8 else { return }
        onSubmit(code)
    }
}

private struct NetworkPickerCard: View {
    let networks: [InkletWiFiNetwork]
    let onJoin: (String, String) -> Void
    let onRescan: () -> Void
    @State private var selected: InkletWiFiNetwork?
    @State private var otherSSID = ""
    @State private var choosingOther = false
    @State private var password = ""

    private var ssid: String { choosingOther ? otherSSID.trimmingCharacters(in: .whitespaces) : (selected?.ssid ?? "") }
    private var needsPassword: Bool { choosingOther || (selected?.secured ?? false) }
    // WPA needs 8+ characters; a typed-in network may be open, so allow empty there.
    private var canJoin: Bool { !ssid.isEmpty && (!needsPassword || password.count >= 8 || (choosingOther && password.isEmpty)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            InkCard(padding: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SectionLabel("Wi-Fi the display can see")
                        Spacer()
                        Button("Scan again", action: onRescan).buttonStyle(.plain)
                            .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                    }
                    ForEach(networks) { network in
                        networkRow(network)
                    }
                    Button {
                        choosingOther = true
                        selected = nil
                    } label: {
                        rowLabel(title: "Other network…", selected: choosingOther) { EmptyView() }
                    }
                    .buttonStyle(.plain)
                }
            }
            if choosingOther || selected != nil {
                InkCard(padding: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        if choosingOther {
                            Text("Network name").font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.secondary)
                            TextField("Network", text: $otherSSID)
                                .textFieldStyle(.plain).font(.system(size: 15))
                                .padding(12).background(Ink.input, in: .rect(cornerRadius: Ink.controlCorner))
                                .autocorrectionDisabled()
                        }
                        if needsPassword {
                            Text("Password").font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.secondary)
                            SecureField("Wi-Fi password", text: $password)
                                .textFieldStyle(.plain).font(.system(size: 15))
                                .padding(12).background(Ink.input, in: .rect(cornerRadius: Ink.controlCorner))
                                .onSubmit { if canJoin { onJoin(ssid, password) } }
                        }
                        Text("Sent to the display over the encrypted setup session; your Mac doesn't keep it.")
                            .font(.system(size: 12)).foregroundStyle(Ink.muted)
                    }
                }
                PrimaryButton(title: "Join \(ssid.isEmpty ? "network" : ssid)", enabled: canJoin) {
                    onJoin(ssid, password)
                }
            }
        }
    }

    private func networkRow(_ network: InkletWiFiNetwork) -> some View {
        Button {
            selected = network
            choosingOther = false
            password = ""
        } label: {
            rowLabel(title: network.ssid, selected: selected == network) {
                HStack(spacing: 8) {
                    if network.secured { Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(Ink.muted) }
                    SignalBars(bars: network.bars)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func rowLabel<Trailing: View>(title: String, selected: Bool,
                                          @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Ink.text : Ink.border)
            Text(title).font(.system(size: 14)).lineLimit(1)
            Spacer()
            trailing()
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(selected ? Ink.input : .clear, in: .rect(cornerRadius: Ink.controlCorner))
        .contentShape(.rect)
    }
}

private struct ProgressCard: View {
    let title: String
    let detail: String?

    var body: some View {
        InkCard(padding: 22) {
            HStack(spacing: 14) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 15, weight: .medium))
                    if let detail { Text(detail).font(.system(size: 13)).foregroundStyle(Ink.secondary) }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct FinishedCard: View {
    let outcome: InkletSetupFlow.Outcome
    let onOpen: (String) -> Void
    let onRefresh: () -> Void
    let onAnother: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            InkCard(padding: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(title, systemImage: isSuccess ? "checkmark.circle.fill" : "wifi")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isSuccess ? Ink.online : Ink.text)
                    Text(detail).font(.system(size: 13)).foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 14) {
                if case .bound(let id?) = outcome {
                    PrimaryButton(title: "Open display", enabled: true) { onOpen(id) }
                } else if !isSuccess {
                    PrimaryButton(title: "Refresh", enabled: true, action: onRefresh)
                }
                Button("Set up another display", action: onAnother).buttonStyle(.plain)
                    .font(.system(size: 13)).foregroundStyle(Ink.secondary)
            }
        }
    }

    private var isSuccess: Bool {
        if case .bound = outcome { return true }
        return false
    }

    private var title: String {
        isSuccess ? "Your display is set up" : "The display is on Wi-Fi"
    }

    private var detail: String {
        switch outcome {
        case .bound:
            "It's restarting on your Wi-Fi and will show your content in a moment."
        case .wifiOnly:
            "It didn't hand over a pairing credential, so it isn't in your account yet. Tap the NFC tag on its back with the inklet app on your iPhone, then hit Refresh."
        case .bindFailed(let message):
            "But it couldn't be added to your account. \(message)"
        }
    }
}

// MARK: - Bits

private struct PairStep: View {
    let number: Int
    let text: String
    init(_ number: Int, _ text: String) { self.number = number; self.text = text }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ink.bg)
                .frame(width: 20, height: 20)
                .background(Ink.text, in: .circle)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Ink.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private struct SignalBars: View {
    let bars: Int
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...3, id: \.self) { level in
                RoundedRectangle(cornerRadius: 1)
                    .fill(level <= bars ? Ink.text : Ink.border)
                    .frame(width: 3, height: CGFloat(4 + level * 3))
            }
        }
        .accessibilityLabel("Signal \(bars) of 3")
    }
}

private struct PrimaryButton: View {
    let title: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Text(title)
                Image(systemName: "arrow.right")
            }
            .font(.system(size: 14, weight: .medium)).foregroundStyle(Ink.bg)
            .padding(.horizontal, 20).padding(.vertical, 13)
            .background(Ink.text, in: .rect(cornerRadius: Ink.controlCorner))
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .disabled(!enabled)
    }
}
