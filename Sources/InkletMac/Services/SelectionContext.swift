import AppKit
import ApplicationServices

/// Reads whatever text is selected in the frontmost app.
///
/// This is the one mechanism that reaches the apps with no scripting dictionary
/// — Obsidian, Notion, Craft, VS Code, every Electron client — so it carries more
/// weight than any per-app integration.
///
/// Two routes, in order:
///
/// 1. `kAXSelectedTextAttribute` on the focused element. Clean, read-only, and
///    instant, but the app has to publish an accessibility tree. Native Cocoa
///    text views do; Electron apps only do once Chromium's accessibility layer
///    has been switched on, which happens lazily and can't be relied on.
/// 2. A synthesized ⌘C, then read and restore the pasteboard. Works anywhere a
///    Copy command works, at the cost of touching the user's clipboard for a few
///    milliseconds. This is what the Electron client does today.
///
/// Both need Accessibility permission. Without it, this returns nil rather than
/// nagging — the composer still opens, just with no suggestion.
enum SelectionContext {
    @MainActor
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system's "grant access" prompt. Only ever from an explicit user
    /// action in Settings, never on launch.
    @MainActor
    static func requestPermission() {
        // The SDK exposes `kAXTrustedCheckOptionPrompt` as a mutable global, so
        // Swift 6 refuses to read it. The key's value is stable API.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Privacy & Security → Accessibility, where the switch lives once the
    /// prompt has been dismissed.
    @MainActor
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func selectedText(pid: pid_t) async -> String? {
        guard await MainActor.run(body: { AXIsProcessTrusted() }) else { return nil }

        if let direct = await Task.detached(priority: .userInitiated, operation: {
            accessibilitySelection(pid: pid)
        }).value {
            return direct
        }
        return await copyViaPasteboard()
    }

    // MARK: - Route 1: accessibility

    private static func accessibilitySelection(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(focused, to: AXUIElement.self)

        var selection: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selection) == .success,
              let text = selection as? String else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Route 2: synthesized copy

    /// Snapshots the pasteboard, sends ⌘C, reads what landed, then puts the old
    /// contents back. The restore is the important part: silently eating whatever
    /// the user had copied would be a far worse bug than a missing suggestion.
    @MainActor
    private static func copyViaPasteboard() async -> String? {
        let pasteboard = NSPasteboard.general
        let previousChangeCount = pasteboard.changeCount
        let saved = pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        } ?? []

        guard postCommandC() else { return nil }

        // Give the source app a moment to service the copy. 120ms is enough for
        // every app tested and short enough not to be felt.
        try? await Task.sleep(for: .milliseconds(120))

        var result: String?
        if pasteboard.changeCount != previousChangeCount {
            result = pasteboard.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        restore(saved, to: pasteboard)
        return (result?.isEmpty == false) ? result : nil
    }

    private static func postCommandC() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        let c: CGKeyCode = 8      // kVK_ANSI_C

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: c, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: c, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        let restored = items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
