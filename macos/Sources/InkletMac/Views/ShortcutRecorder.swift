import AppKit
import SwiftUI
import Carbon.HIToolbox

/// Click to record, press a combination, done. Esc cancels, ⌫ clears back to the
/// default.
///
/// The key press is caught with a local event monitor rather than SwiftUI's
/// `onKeyPress`, because recording has to swallow combinations that are already
/// menu shortcuts — ⌘W would otherwise close the window instead of being recorded.
struct ShortcutRecorder: View {
    @Environment(ShortcutStore.self) private var store

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var isHovering = false

    var body: some View {
        Button {
            isRecording ? stop() : start()
        } label: {
            content
                .frame(height: 26)
                .contentShape(.rect(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isRecording ? "Press a combination, or esc to cancel"
                          : "Click to change the shortcut")
        .onDisappear(perform: stop)
        .overlay(alignment: .trailing) {
            if store.isUnavailable && !isRecording {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Ink.danger)
                    .offset(x: 18)
                    .help("Another app already uses this combination")
            }
        }
    }

    /// One cap per key rather than a single run of glyphs — it reads as keys you
    /// press instead of a string, and each modifier stays legible on its own.
    @ViewBuilder
    private var content: some View {
        if isRecording {
            Text("Press keys…")
                .font(.system(size: 11))
                .foregroundStyle(Ink.muted)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Ink.text.opacity(0.5),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
        } else {
            HStack(spacing: 4) {
                ForEach(Array(store.shortcut.symbols.enumerated()), id: \.offset) { _, symbol in
                    KeyCap(symbol: symbol, isHighlighted: isHovering)
                }
            }
        }
    }

    private func start() {
        guard !isRecording else { return }
        isRecording = true

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            return nil          // swallow it, whatever it was
        }
    }

    private func stop() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            stop()
            return
        case kVK_Delete, kVK_ForwardDelete:
            store.resetToDefault()
            stop()
            return
        default:
            break
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // A global shortcut without a modifier would swallow that key everywhere,
        // so require at least one that isn't shift on its own.
        let mask = flags.carbonMask
        guard mask != 0, mask != UInt32(shiftKey) else { return }

        let key = (event.charactersIgnoringModifiers ?? "").uppercased()
        let label = Self.specialKeyNames[Int(event.keyCode)] ?? key
        guard !label.isEmpty else { return }

        store.update(to: .init(keyCode: UInt32(event.keyCode), modifiers: mask, key: label))
        stop()
    }

    /// A single key, drawn like a keycap: slightly raised, squared off, wide
    /// enough for a word like "Space" but square for a single glyph.
    private struct KeyCap: View {
        let symbol: String
        var isHighlighted = false

        var body: some View {
            Text(symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Ink.text)
                .padding(.horizontal, symbol.count > 1 ? 7 : 0)
                .frame(minWidth: 26, minHeight: 26)
                .background(isHighlighted ? Ink.border : Ink.input, in: .rect(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Ink.border)
                }
        }
    }

    /// Keys whose `charactersIgnoringModifiers` is blank or unprintable.
    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space",
        kVK_Return: "↩",
        kVK_Tab: "⇥",
        kVK_ANSI_KeypadEnter: "⌤",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_UpArrow: "↑",
        kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}
