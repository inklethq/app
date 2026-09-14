import AppKit
import IOKit

/// Device-specific flags distinguish the two physical Option keys.
struct OptionChord {
    private var latched = false

    static func matches(flags: UInt) -> Bool {
        let both = UInt(NX_DEVICELALTKEYMASK | NX_DEVICERALTKEYMASK)
        let other = NSEvent.ModifierFlags([.command, .control, .shift, .function]).rawValue
        return flags & both == both && flags & other == 0
    }

    mutating func update(flags: UInt) -> Bool {
        let optionKeys = UInt(NX_DEVICELALTKEYMASK | NX_DEVICERALTKEYMASK)
        // Rearm only after both keys are released, not when just one bounces.
        if flags & optionKeys == 0 { latched = false }
        guard Self.matches(flags: flags), !latched else { return false }
        latched = true
        return true
    }
}

@MainActor
final class ModifierHotKey {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var chord = OptionChord()
    private let action: () -> Void
    var isRegistered: Bool { globalMonitor != nil && localMonitor != nil }

    init(action: @escaping () -> Void) {
        self.action = action
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        if chord.update(flags: event.modifierFlags.rawValue) { action() }
    }

    func invalidate() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        chord = OptionChord()
    }
}
