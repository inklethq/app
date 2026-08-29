import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut.
///
/// Carbon's `RegisterEventHotKey` is still the right tool here. The AppKit
/// alternative, `NSEvent.addGlobalMonitorForEvents`, can only observe keys — it
/// can't consume them, so the shortcut would also reach whatever app is in front
/// — and it requires Accessibility permission. Carbon needs neither.
@MainActor
final class GlobalHotKey {
    /// Weak on purpose. Holding the instance here kept it alive forever, so
    /// `deinit` — the only thing that called `UnregisterEventHotKey` — never ran,
    /// and every combination the user had ever set stayed live at once.
    private final class Box {
        weak var key: GlobalHotKey?
        init(_ key: GlobalHotKey) { self.key = key }
    }

    private static var registry: [UInt32: Box] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    private let id: UInt32
    private let action: () -> Void
    /// `nonisolated(unsafe)` so `deinit` — which is nonisolated — can unregister.
    /// It's an opaque pointer written once during init and read once at teardown.
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?

    /// Returns nil when the combination is already claimed by another app, so a
    /// caller can fall back to the menu shortcut instead of silently doing nothing.
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        self.id = Self.nextID
        Self.nextID += 1

        Self.installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x494E_4B4C), id: id)   // 'INKL'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }

        hotKeyRef = ref
        Self.registry[id] = Box(self)
    }

    /// Releases the system registration now, instead of whenever ARC gets around
    /// to it. Callers that swap one shortcut for another need the old one gone
    /// before the new one is registered — Carbon refuses duplicates.
    func invalidate() {
        guard let ref = hotKeyRef else { return }
        UnregisterEventHotKey(ref)
        hotKeyRef = nil
        Self.registry[id] = nil
    }

    deinit {
        // Backstop for an instance dropped without `invalidate()`. The registry
        // entry is weak, so the stale key clears itself.
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    }

    fileprivate func fire() { action() }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler,
                            1, &eventType, nil, nil)
    }

    /// Looked up by id because an `EventHandlerUPP` is a bare C function pointer
    /// and can't capture anything.
    fileprivate static func dispatch(_ id: UInt32) {
        guard let key = registry[id]?.key else {
            registry[id] = nil          // the box outlived its key
            return
        }
        key.fire()
    }
}

private let hotKeyEventHandler: EventHandlerUPP = { _, event, _ in
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hotKeyID)
    guard status == noErr else { return status }

    // Carbon hot-key events are delivered on the main run loop.
    MainActor.assumeIsolated { GlobalHotKey.dispatch(hotKeyID.id) }
    return noErr
}
