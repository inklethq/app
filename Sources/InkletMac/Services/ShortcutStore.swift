import AppKit
import Carbon.HIToolbox
import Observation

/// One system-wide shortcut, its persisted definition, and its registration.
///
/// Keeps the display string alongside the key code rather than translating back
/// through the current keyboard layout on every launch: the layout can change
/// under us, and the label the user recorded is the one they expect to see.
@MainActor
@Observable
final class ShortcutStore {
    static let shared = ShortcutStore()

    struct Shortcut: Equatable {
        var keyCode: UInt32
        /// Carbon modifier mask (`cmdKey`, `shiftKey`, …).
        var modifiers: UInt32
        /// The key's own label, e.g. "I" or "Space".
        var key: String

        static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_I),
                                        modifiers: UInt32(cmdKey | shiftKey),
                                        key: "I")

        static let bothOptions = Shortcut(keyCode: UInt32.max, modifiers: 0, key: "Left ⌥ + Right ⌥")
        var isBothOptions: Bool { self == .bothOptions }

        /// One entry per key, in the order macOS uses on menus: ⌃⌥⇧⌘ then the key.
        var symbols: [String] {
            if isBothOptions { return ["Left ⌥", "Right ⌥"] }
            var result: [String] = []
            if modifiers & UInt32(controlKey) != 0 { result.append("⌃") }
            if modifiers & UInt32(optionKey) != 0 { result.append("⌥") }
            if modifiers & UInt32(shiftKey) != 0 { result.append("⇧") }
            if modifiers & UInt32(cmdKey) != 0 { result.append("⌘") }
            result.append(key)
            return result
        }

        var display: String { symbols.joined() }
    }

    private enum Key {
        static let code = "composerShortcutKeyCode"
        static let modifiers = "composerShortcutModifiers"
        static let label = "composerShortcutKey"
    }

    private(set) var shortcut: Shortcut
    /// True when the combination was refused by the system — almost always
    /// because another app already owns it.
    private(set) var isUnavailable = false

    private var hotKey: GlobalHotKey?
    private var modifierHotKey: ModifierHotKey?
    var isRecording = false
    private var action: (() -> Void)?

    private init() {
        let defaults = UserDefaults.standard
        if let key = defaults.string(forKey: Key.label),
           defaults.object(forKey: Key.code) != nil {
            shortcut = Shortcut(keyCode: UInt32(defaults.integer(forKey: Key.code)),
                                modifiers: UInt32(defaults.integer(forKey: Key.modifiers)),
                                key: key)
        } else {
            shortcut = .default
        }
    }

    /// Called once the user is signed in. Re-registering with a new action
    /// replaces the old one.
    func activate(action: @escaping () -> Void) {
        self.action = action
        reregister()
    }

    func deactivate() {
        hotKey?.invalidate()
        hotKey = nil
        modifierHotKey?.invalidate()
        modifierHotKey = nil
        action = nil
        isUnavailable = false
    }

    func update(to shortcut: Shortcut) {
        guard shortcut != self.shortcut else { return }
        self.shortcut = shortcut

        let defaults = UserDefaults.standard
        defaults.set(Int(shortcut.keyCode), forKey: Key.code)
        defaults.set(Int(shortcut.modifiers), forKey: Key.modifiers)
        defaults.set(shortcut.key, forKey: Key.label)

        reregister()
    }

    func resetToDefault() {
        update(to: .default)
    }

    private func reregister() {
        guard let action else { return }
        // Drop the old registration first, and explicitly: releasing the last
        // reference isn't enough on its own, and a lingering registration means
        // the previous combination keeps firing alongside the new one.
        hotKey?.invalidate()
        hotKey = nil
        modifierHotKey?.invalidate()
        modifierHotKey = nil
        let fire = { [weak self] in
            guard self?.isRecording == false else { return }
            action()
        }
        if shortcut.isBothOptions {
            modifierHotKey = ModifierHotKey(action: fire)
            isUnavailable = !modifierHotKey!.isRegistered
            return
        }
        hotKey = GlobalHotKey(keyCode: shortcut.keyCode,
                              modifiers: shortcut.modifiers,
                              action: fire)
        isUnavailable = hotKey == nil
    }
}

extension NSEvent.ModifierFlags {
    /// The Carbon mask `RegisterEventHotKey` expects.
    var carbonMask: UInt32 {
        var mask: UInt32 = 0
        if contains(.command) { mask |= UInt32(cmdKey) }
        if contains(.shift) { mask |= UInt32(shiftKey) }
        if contains(.option) { mask |= UInt32(optionKey) }
        if contains(.control) { mask |= UInt32(controlKey) }
        return mask
    }
}
