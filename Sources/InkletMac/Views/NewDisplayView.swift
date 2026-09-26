import SwiftUI
import InkletPresentationKit

/// Registration starts with a destination type. New integrations add a choice
/// here; registered instances all remain peers in the Displays sidebar.
private enum DisplayConnection: String, CaseIterable, Identifiable {
    case hardware, virtual, quote0
    var id: Self { self }
    var title: String {
        switch self {
        case .hardware: "inklet D1"
        case .virtual: "Virtual Display"
        case .quote0: "Quote/0"
        }
    }
    /// The mark on the card. SF Symbols for ours; for the Quote/0, Dot.'s own
    /// logo — the card is about their product, and a generic cloud glyph said
    /// nothing about which one.
    @ViewBuilder var icon: some View {
        switch self {
        case .hardware:
            Image(systemName: "rectangle.inset.filled").font(.system(size: 40, weight: .ultraLight))
        case .virtual:
            Image(systemName: "macwindow").font(.system(size: 40, weight: .ultraLight))
        case .quote0:
            DotLogo().frame(width: 38, height: 38)
        }
    }
    var description: String {
        switch self {
        case .hardware: "Pair an inklet display and give your ideas a place in the room."
        case .virtual: "Create a display for a Widget on your Mac, iPhone, or iPad."
        case .quote0: "Connect a Dot. Quote/0 through its own cloud."
        }
    }
    var action: String {
        switch self {
        case .hardware: "Pair a display"
        case .virtual: "Choose a canvas"
        case .quote0: "Connect with an API key"
        }
    }
}

struct NewDisplayView: View {
    @Binding var selection: SidebarItem?
    @State private var creatingVirtual = false
    @State private var connectingQuote0 = false

    var body: some View {
        Group {
            if creatingVirtual {
                MacVirtualDisplaySetupView(onBack: { creatingVirtual = false }, onCreated: { selection = .virtualDisplayDetail($0) })
            } else if connectingQuote0 {
                Quote0SetupView(onBack: { connectingQuote0 = false }, onConnected: { selection = .device($0) })
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("New Display").font(.brand(36)).foregroundStyle(Ink.text)
                            Text("Choose how you’d like to bring inklet into view.")
                                .font(.system(size: 14)).foregroundStyle(Ink.secondary)
                        }
                        // Adaptive: three cards fit in one row at the page's
                        // full width and wrap to two-plus-one in a narrow window.
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 18)], spacing: 18) {
                            ForEach(DisplayConnection.allCases) { connection in
                                DisplayConnectionCard(connection: connection) {
                                    switch connection {
                                    case .hardware: selection = .pair
                                    case .virtual: creatingVirtual = true
                                    case .quote0: connectingQuote0 = true
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 820, alignment: .leading)
                    .padding(32)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }.scrollIndicators(.never)
            }
        }
        .background(Ink.bg)
        .navigationTitle("New Display")
    }
}

private struct DisplayConnectionCard: View {
    let connection: DisplayConnection
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            InkCard(padding: 26) {
                VStack(alignment: .leading, spacing: 0) {
                    connection.icon
                        .frame(height: 64, alignment: .leading)
                    Spacer(minLength: 26)
                    Text(connection.title).font(.brand(27))
                        .padding(.bottom, 9)
                    Text(connection.description)
                        .font(.system(size: 14)).foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 24)
                    HStack {
                        Text(connection.action).font(.system(size: 13, weight: .medium))
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.system(size: 14))
                    }
                }.frame(height: 228, alignment: .topLeading)
            }
            .foregroundStyle(Ink.text)
            .overlay { RoundedRectangle(cornerRadius: Ink.cardCorner).strokeBorder(hovering ? Ink.text.opacity(0.25) : .clear) }
            .contentShape(.rect(cornerRadius: Ink.cardCorner))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct MacVirtualDisplaySetupView: View {
    @EnvironmentObject private var virtuals: VirtualDisplayController
    let onBack: () -> Void
    let onCreated: (UUID) -> Void
    @State private var name = "My inklet"
    @State private var profile: VirtualDisplaySizeProfile = .macLarge
    @State private var id = UUID()
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Button(action: onBack) { Label("Display types", systemImage: "chevron.left") }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Ink.secondary)
                    .disabled(virtuals.busy)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Create a Virtual Display").font(.brand(34)).foregroundStyle(Ink.text)
                    Text("Give it a name and a canvas. Your content will be composed for this size.")
                        .font(.system(size: 14)).foregroundStyle(Ink.secondary)
                }
                InkCard(padding: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Display name").font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.secondary)
                        TextField("My inklet", text: $name)
                            .textFieldStyle(.plain).font(.system(size: 16))
                            .padding(12).background(Ink.input, in: .rect(cornerRadius: Ink.controlCorner))
                            .accessibilityLabel("Display name")
                    }
                }.disabled(virtuals.busy)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Canvas size").font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.secondary)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                        ForEach(VirtualDisplaySizeProfile.available) { value in
                            Button { profile = value } label: {
                                InkCard(padding: 16) {
                                    HStack(spacing: 15) {
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill(Ink.paperWhite)
                                            .aspectRatio(value.aspectRatio, contentMode: .fit)
                                            .frame(width: 68, height: 48)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(value.title).font(.system(size: 13, weight: .medium))
                                            Text(value.width == value.height ? "Square canvas" : (value.width > value.height ? "Wide canvas" : "Portrait canvas"))
                                                .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                                        }
                                        Spacer(minLength: 0)
                                        Image(systemName: profile == value ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(profile == value ? Ink.text : Ink.border)
                                    }.frame(height: 60)
                                }
                                .overlay { RoundedRectangle(cornerRadius: Ink.cardCorner).strokeBorder(profile == value ? Ink.text.opacity(0.6) : .clear) }
                            }.buttonStyle(.plain).accessibilityAddTraits(profile == value ? .isSelected : [])
                        }
                    }.disabled(virtuals.busy)
                    Text("Only a matching Widget can use this display. Create another display for a different size.")
                        .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                }
                if let error = virtuals.error { Text(error).font(.system(size: 13)).foregroundStyle(Ink.danger) }
                Button {
                    Task { if await virtuals.create(id: id, name: trimmed, profile: profile) { onCreated(id) } }
                } label: {
                    HStack(spacing: 9) {
                        Text(virtuals.busy ? "Creating…" : "Create Virtual Display")
                        Image(systemName: "arrow.right")
                    }
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(Ink.bg)
                    .padding(.horizontal, 20).padding(.vertical, 13)
                    .background(Ink.text, in: .rect(cornerRadius: Ink.controlCorner))
                }.buttonStyle(.plain)
                    .disabled(virtuals.busy || trimmed.isEmpty || trimmed.unicodeScalars.count > 80)
            }
            .frame(maxWidth: 820, alignment: .leading).padding(32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.never).foregroundStyle(Ink.text).background(Ink.bg)
        .onChange(of: name) { _, _ in id = UUID() }
        .onChange(of: profile) { _, _ in id = UUID() }
    }
}

/// Connecting a Quote/0: a Dot. API key and the panel's serial number, which
/// the backend proves against the Dot. cloud and seals. The key lives in this
/// form's state for exactly as long as the request takes.
private struct Quote0SetupView: View {
    @Environment(AppModel.self) private var model
    let onBack: () -> Void
    let onConnected: (String) -> Void
    @State private var name = ""
    @State private var apiKey = ""
    @State private var serial = ""
    @State private var isConnecting = false
    @State private var error: String?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedSerial: String { serial.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canConnect: Bool { !isConnecting && !trimmedKey.isEmpty && !trimmedSerial.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Button(action: onBack) { Label("Display types", systemImage: "chevron.left") }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Ink.secondary)
                    .disabled(isConnecting)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connect a Quote/0").font(.brand(34)).foregroundStyle(Ink.text)
                    Text("inklet sends pictures to the panel through the Dot. cloud, so the panel keeps its own firmware and app.")
                        .font(.system(size: 14)).foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                InkCard(padding: 18) {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionLabel("In the Dot. app first")
                        step(1, "Add an “Image API” item to this panel's loop task in Content Studio. Without it, Dot. refuses every picture.")
                        step(2, "More → API Key → Create. Copy the key; it starts with dot_app_.")
                        step(3, "Open the device and copy its Device Serial Number.")
                    }
                }

                InkCard(padding: 20) {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Name").font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.secondary)
                            TextField("Kitchen", text: $name)
                                .textFieldStyle(.plain).font(.system(size: 15))
                                .padding(12).background(Ink.input, in: .rect(cornerRadius: Ink.controlCorner))
                                .accessibilityLabel("Name")
                            // A serial number tells the agent nothing about where
                            // the panel is or what it is for.
                            Text("What you and inklet call it when choosing where a card goes. Blank keeps the serial number.")
                                .font(.system(size: 12)).foregroundStyle(Ink.muted)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Dot. API key").font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.secondary)
                            SecureField("dot_app_…", text: $apiKey)
                                .textFieldStyle(.plain).font(.system(size: 15, design: .monospaced))
                                .padding(12).background(Ink.input, in: .rect(cornerRadius: Ink.controlCorner))
                                .accessibilityLabel("Dot. API key")
                            Text("Stored encrypted on the inklet server, never shown again. Revoke it in the Dot. app at any time.")
                                .font(.system(size: 12)).foregroundStyle(Ink.muted)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Serial number").font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.secondary)
                            TextField("ABCD1234ABCD", text: $serial)
                                .textFieldStyle(.plain).font(.system(size: 15, design: .monospaced))
                                .autocorrectionDisabled()
                                .padding(12).background(Ink.input, in: .rect(cornerRadius: Ink.controlCorner))
                                .accessibilityLabel("Serial number")
                        }
                    }
                }.disabled(isConnecting)

                if let error {
                    Text(error).font(.system(size: 13)).foregroundStyle(Ink.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    connect()
                } label: {
                    HStack(spacing: 9) {
                        Text(isConnecting ? "Connecting…" : "Connect Quote/0")
                        Image(systemName: "arrow.right")
                    }
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(Ink.bg)
                    .padding(.horizontal, 20).padding(.vertical, 13)
                    .background(Ink.text, in: .rect(cornerRadius: Ink.controlCorner))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(!canConnect)
            }
            .frame(maxWidth: 820, alignment: .leading).padding(32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.never).foregroundStyle(Ink.text).background(Ink.bg)
    }

    private func connect() {
        guard canConnect else { return }
        guard trimmedKey.hasPrefix("dot_app_") else {
            error = "That doesn't look like a Dot. API key — they start with dot_app_."
            return
        }
        isConnecting = true
        error = nil
        let key = trimmedKey
        let serialNumber = trimmedSerial
        let nickname = trimmedName
        Task {
            defer { isConnecting = false }
            do {
                let device = try await model.bindQuote0(apiKey: key, serial: serialNumber, nickname: nickname)
                // Done with the key; drop it from the form before leaving.
                apiKey = ""
                onConnected(device.id)
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
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
