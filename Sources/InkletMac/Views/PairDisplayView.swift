import SwiftUI

/// Pairing is NFC-only (docs/api/nfc-v2-protocol.md): the six-character code
/// route now answers 410, and claiming a display means tapping its tag with a
/// phone. A Mac has no NFC radio, so this page explains the flow and gets out of
/// the way — anything else here would be a button that can only fail.
struct PairDisplayView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "wave.3.right.circle")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(Ink.muted)

            VStack(spacing: 8) {
                Text("Pair a new display")
                    .font(.brand(30))
                    .foregroundStyle(Ink.text)
                Text("inklet displays are claimed by tapping the NFC tag on the back with your iPhone. Your Mac can't read NFC, so this one step happens on the phone.")
                    .font(.system(size: 14))
                    .foregroundStyle(Ink.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            InkCard(padding: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    step(1, "Open the inklet app on your iPhone.")
                    step(2, "Hold the top of the phone against the tag on the back of the display.")
                    step(3, "Confirm the pairing, then hit Refresh below — the display shows up in the sidebar.")
                }
            }
            .frame(width: 420)

            Button {
                Task { await model.refresh() }
            } label: {
                Text(model.isRefreshing ? "Refreshing…" : "Refresh")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Ink.bg)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Ink.text, in: .rect(cornerRadius: Ink.controlCorner))
            }
            .buttonStyle(.plain)
            .disabled(model.isRefreshing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.bg)
        .navigationTitle("Pair Display")
        // Landing on a freshly-paired display is the whole point of the button
        // above, so jump to it as soon as one shows up.
        .onChange(of: model.devices.count) { previous, current in
            guard current > previous, let newest = model.devices.last else { return }
            selection = .device(newest.id)
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
