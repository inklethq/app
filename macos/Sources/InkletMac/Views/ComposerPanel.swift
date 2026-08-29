import AppKit
import SwiftUI

/// The composer's own floating window.
///
/// It used to be a popover anchored on the toolbar button, which was wrong twice
/// over: a popover closes as soon as anything else takes focus (so opening the
/// file chooser dismissed it), and being tethered to a button it could never read
/// as something a global shortcut summons. This is the HUD layer from the design:
/// a non-activating floating panel that can be raised from any app.
@MainActor
final class ComposerPanelController {
    static let shared = ComposerPanelController()

    private var panel: ComposerPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(model: AppModel) {
        let panel = panel ?? makePanel(model: model)
        self.panel = panel

        position(panel)
        // Bring the app forward so typing lands in the panel. `.nonactivatingPanel`
        // keeps it from stealing focus when it's merely on screen; this is the
        // deliberate exception for when the user asked for it.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func toggle(model: AppModel) {
        isVisible ? hide() : show(model: model)
    }

    private func makePanel(model: AppModel) -> ComposerPanel {
        // Same shape as the Electron client's window: hidden-inset titlebar, real
        // traffic lights, fixed size. Leaving `.miniaturizable` and `.resizable`
        // out of the mask greys out the amber and green buttons the way a utility
        // window should, without hiding them and leaving a gap.
        let panel = ComposerPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 200),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = Ink.bgNS
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        // Survives the file chooser and app switches; a HUD that vanishes when
        // you reach for another window is useless.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        // No system window animation: it plays over our own resize and reads as a
        // twitch rather than a transition.
        panel.animationBehavior = .none

        let hosting = NSHostingView(rootView:
            ComposerView()
                .environment(model)
                .tint(Ink.text)
        )
        // Deliberately no `sizingOptions`. It drives `setContentSize`, and on a
        // titled window the content rect excludes the titlebar — so the window
        // came out 28pt taller than the view, which then centred itself in the
        // slack and put ~14pt of dead space above and below. `resize(to:)` sets
        // the whole frame instead, so the window is exactly the content.
        //
        // `safeAreaRegions` still matters: without it SwiftUI insets the content
        // below the titlebar as if it were a safe area.
        hosting.safeAreaRegions = []
        panel.contentView = hosting

        // Settle the size before the first appearance. Otherwise the panel shows
        // at the placeholder height above and then jumps to the measured one.
        hosting.layoutSubtreeIfNeeded()
        resize(panel, to: hosting.fittingSize)

        return panel
    }

    /// Keeps the window the same size as its content, pinned by its top edge so
    /// growth goes downwards and the header doesn't jump.
    func resize(to size: CGSize) {
        guard let panel else { return }
        resize(panel, to: size)
    }

    private func resize(_ panel: NSPanel, to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        var frame = panel.frame
        guard abs(frame.height - size.height) > 0.5 || abs(frame.width - size.width) > 0.5 else { return }

        frame.origin.y -= size.height - frame.height
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    /// Upper third of whichever screen has the pointer — the usual place for a
    /// summoned panel, and never under the user's hands at the bottom.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        // Re-measure: attachments left over from a previous send change the height.
        if let hosting = panel.contentView {
            hosting.layoutSubtreeIfNeeded()
            resize(panel, to: hosting.fittingSize)
        }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + frame.height * 0.62))
    }
}

/// `canBecomeKey` is the whole point: a panel that can't become key can't take
/// keyboard input, and this one is a text field.
private final class ComposerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc closes it, matching every other summoned panel on the system.
    override func cancelOperation(_ sender: Any?) {
        ComposerPanelController.shared.hide()
    }
}
