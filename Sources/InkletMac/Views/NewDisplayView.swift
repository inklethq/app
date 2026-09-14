import SwiftUI
import InkletPresentationKit

/// Registration starts with a destination type. New integrations add a choice
/// here; registered instances all remain peers in the Displays sidebar.
private enum DisplayConnection: String, CaseIterable, Identifiable {
    case hardware, virtual
    var id: Self { self }
    var title: String { self == .hardware ? "Hardware Display" : "Virtual Display" }
    var symbol: String { self == .hardware ? "rectangle.inset.filled" : "macwindow" }
    var description: String {
        self == .hardware
            ? "Pair an inklet display and give your ideas a place in the room."
            : "Create a display for a Widget on your Mac, iPhone, or iPad."
    }
    var action: String { self == .hardware ? "Pair a display" : "Choose a canvas" }
}

struct NewDisplayView: View {
    @Binding var selection: SidebarItem?
    @State private var creatingVirtual = false

    var body: some View {
        Group {
            if creatingVirtual {
                MacVirtualDisplaySetupView(onBack: { creatingVirtual = false }, onCreated: { selection = .virtualDisplayDetail($0) })
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        VStack(alignment: .leading, spacing: 9) {
                            SectionLabel("Make room for your ideas")
                            Text("New Display").font(.brand(36)).foregroundStyle(Ink.text)
                            Text("Choose how you’d like to bring inklet into view.")
                                .font(.system(size: 14)).foregroundStyle(Ink.secondary)
                        }
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)], spacing: 18) {
                            ForEach(DisplayConnection.allCases) { connection in
                                DisplayConnectionCard(connection: connection) {
                                    switch connection {
                                    case .hardware: selection = .pair
                                    case .virtual: creatingVirtual = true
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
                    Image(systemName: connection.symbol)
                        .font(.system(size: 40, weight: .ultraLight))
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
                        SectionLabel("Display name")
                        TextField("My inklet", text: $name)
                            .textFieldStyle(.plain).font(.system(size: 16))
                            .padding(12).background(Ink.input, in: .rect(cornerRadius: Ink.controlCorner))
                            .accessibilityLabel("Display name")
                    }
                }.disabled(virtuals.busy)
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel("Canvas size")
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
