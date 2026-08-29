import SwiftUI
import AppKit

/// Pops a real `NSMenu` from a custom SwiftUI control.
///
/// SwiftUI's `Menu` insists on laying out its label as a control, which flattens a
/// rich label (avatar + name + plan) into a stub. Driving `NSMenu` directly keeps
/// the trigger fully ours, and the menu keeps the system's window: shadow, corner
/// shape, Esc, click-outside-to-dismiss and keyboard traversal.
///
/// The rows are custom views because AppKit paints menu highlights with the user's
/// accent color, and there is no API to override it per app without an asset
/// catalog. Drawing them ourselves keeps the menu in the ink palette.
@MainActor
final class NativeMenu: NSObject {
    struct Item {
        var title: String
        var symbol: String?
        var isDestructive = false
        var isSeparator = false
        var action: (() -> Void)?

        init(title: String, symbol: String? = nil, isDestructive: Bool = false, action: (() -> Void)? = nil) {
            self.title = title
            self.symbol = symbol
            self.isDestructive = isDestructive
            self.action = action
        }

        static var separator: Item {
            var item = Item(title: "")
            item.isSeparator = true
            return item
        }
    }

    private var handlers: [Int: () -> Void] = [:]

    func present(_ items: [Item], width: CGFloat = 236) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        handlers.removeAll()

        for (index, item) in items.enumerated() {
            guard !item.isSeparator else {
                menu.addItem(.separator())
                continue
            }
            let menuItem = NSMenuItem(title: item.title, action: #selector(fire(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.tag = index
            menuItem.view = MenuRowView(title: item.title,
                                        symbol: item.symbol,
                                        isDestructive: item.isDestructive,
                                        width: width)
            handlers[index] = item.action
            menu.addItem(menuItem)
        }

        // A nil view means `at:` is in screen coordinates, which is where the
        // pointer already is — the menu opens right under the cursor.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func fire(_ sender: NSMenuItem) {
        handlers[sender.tag]?()
    }
}

/// One ink-themed menu row. Tracks the pointer itself so the highlight follows the
/// palette instead of the system accent.
private final class MenuRowView: NSView {
    private let title: String
    private let symbol: String?
    private let isDestructive: Bool
    private let preferredWidth: CGFloat
    private var isHighlighted = false

    private let rowHeight: CGFloat = 30
    private let inset: CGFloat = 6
    /// Icons are scaled to fit this slot, never stretched to fill it.
    private let iconSlot: CGFloat = 18
    private let iconHeight: CGFloat = 15

    init(title: String, symbol: String?, isDestructive: Bool, width: CGFloat) {
        self.title = title
        self.symbol = symbol
        self.isDestructive = isDestructive
        self.preferredWidth = width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: rowHeight))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: preferredWidth, height: rowHeight) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let item = enclosingMenuItem, let menu = item.menu else { return }
        menu.cancelTracking()
        // Let the menu finish dismissing before the action runs, so anything it
        // opens (a window, a URL) isn't fighting the closing menu for focus.
        DispatchQueue.main.async {
            menu.performActionForItem(at: menu.index(of: item))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let foreground: NSColor = isHighlighted
            ? Ink.bgNS
            : (isDestructive ? Ink.dangerNS : Ink.textNS)

        if isHighlighted {
            let fill = isDestructive ? Ink.dangerNS : Ink.textNS
            let rect = bounds.insetBy(dx: inset, dy: 1)
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            fill.setFill()
            path.fill()
        }

        var textX = inset + 10

        if let symbol,
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            let sized = (image.withSymbolConfiguration(config) ?? image).tinted(foreground)

            // Symbols don't share an aspect ratio — a key is tall and narrow, a
            // credit card short and wide. Drawing each into the same fixed box
            // stretches every one by a different amount, so scale to fit and
            // centre inside a fixed-width slot instead. The slot keeps the text
            // baseline aligned no matter which symbol lands in it.
            let slot = NSRect(x: textX, y: 0, width: iconSlot, height: bounds.height)
            let natural = sized.size
            if natural.width > 0, natural.height > 0 {
                let scale = min(iconSlot / natural.width, iconHeight / natural.height)
                let drawn = NSSize(width: natural.width * scale, height: natural.height * scale)
                sized.draw(in: NSRect(x: slot.midX - drawn.width / 2,
                                      y: slot.midY - drawn.height / 2,
                                      width: drawn.width,
                                      height: drawn.height))
            }
            textX += iconSlot + 8
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: foreground,
        ]
        let text = NSAttributedString(string: title, attributes: attributes)
        let size = text.size()
        text.draw(at: NSPoint(x: textX, y: (bounds.height - size.height) / 2))
    }
}

private extension NSImage {
    /// Symbol images arrive as templates; bake in a color so it survives `draw(in:)`.
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}
