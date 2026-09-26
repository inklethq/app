import SwiftUI
import AppKit
import CoreText

/// The paper-and-ink palette shared with the iOS client. Dark mode is a warm
/// inversion: the near-black CTA color becomes the background and the parchment
/// background becomes the foreground, so every semantic token flips together.
enum Ink {
    static let bg        = dynamic(light: 0xF5F3ED, dark: 0x1A1A1A)
    static let sidebar   = dynamic(light: 0xEFEDE7, dark: 0x201F1D)
    /// Content cards separate from the page by tone alone — no border. Apple's
    /// guidance for the content layer is to build hierarchy from grouping and
    /// spacing rather than stacking extra backgrounds and strokes.
    static let card      = dynamic(light: 0xEAE7DE, dark: 0x262421)
    static let input     = dynamic(light: 0xE2DED4, dark: 0x2F2D29)
    static let border    = dynamic(light: 0xDBD6CB, dark: 0x393631)
    /// Divider inside a card — a step darker than the card, never the page border.
    static let cardRule  = dynamic(light: 0xDCD7CC, dark: 0x333029)
    static let text      = dynamic(light: 0x1A1A1A, dark: 0xF5F3ED)
    static let secondary = dynamic(light: 0x666666, dark: 0xA8A39A)
    static let muted     = dynamic(light: 0x999999, dark: 0x7D786F)
    static let paperWhite = dynamic(light: 0xFDFCF9, dark: 0xE8E4DB)   // the e-ink sheet itself
    static let online    = dynamic(light: 0x3E8E5A, dark: 0x6FBF8B)
    static let danger    = dynamic(light: 0x8B4444, dark: 0xE0A0A0)
    /// Something to notice that is not a failure: a retry, a blocked step.
    static let warn      = dynamic(light: 0x9A6B2F, dark: 0xD1A05C)
    /// A run that is still going.
    static let working   = dynamic(light: 0xD99B4E, dark: 0xD99B4E)

    /// Corner radii — Tahoe rounds generously, and nested shapes stay concentric
    /// with whatever contains them.
    static let cardCorner: CGFloat = 18
    static let controlCorner: CGFloat = 8
    static let screenCorner: CGFloat = 4

    /// AppKit twins, for the places SwiftUI colors can't reach (window chrome,
    /// custom-drawn menu rows).
    static let bgNS        = dynamicNS(light: 0xF5F3ED, dark: 0x1A1A1A)
    static let textNS      = dynamicNS(light: 0x1A1A1A, dark: 0xF5F3ED)
    static let secondaryNS = dynamicNS(light: 0x666666, dark: 0xA8A39A)
    static let dangerNS    = dynamicNS(light: 0x8B4444, dark: 0xE0A0A0)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: dynamicNS(light: light, dark: dark))
    }

    private static func dynamicNS(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        }
    }
}

/// Window-level settings SwiftUI has no modifier for: the paper background behind
/// the content, and the main window's resize range.
///
/// The titlebar strip itself is handled by `.windowStyle(.hiddenTitleBar)` on the
/// scene, not here — see the note on `StylerView`.
struct WindowStyler: NSViewRepresentable {
    /// Only the main window gets a size range; the settings window sizes itself.
    var constrainSize = false

    func makeNSView(context: Context) -> NSView {
        let view = StylerView()
        view.constrainSize = constrainSize
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? StylerView else { return }
        view.constrainSize = constrainSize
        view.applyStyle()
    }
}

/// The styling has to run from `viewDidMoveToWindow`, not from `makeNSView`.
/// A zero-sized representable isn't in the hierarchy yet when it's created, so
/// `view.window` is still nil there and every window tweak silently no-ops.
///
/// The white titlebar strip was a separate problem: on Tahoe the container above
/// the titlebar carries its own decoration view, which neither
/// `titlebarAppearsTransparent` nor painting the container's layer removes.
/// `.windowStyle(.hiddenTitleBar)` on the scene is what actually clears it.
private final class StylerView: NSView {
    var constrainSize = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyStyle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    func applyStyle() {
        guard let window else { return }

        window.backgroundColor = Ink.bgNS
        window.titlebarSeparatorStyle = .none

        // Resizable, but only within a range the layout is actually designed for —
        // and never full screen, since this is a companion window, not a workspace.
        if constrainSize {
            window.minSize = NSSize(width: 940, height: 640)
            window.maxSize = NSSize(width: 1560, height: 1100)
            window.collectionBehavior.insert(.fullScreenNone)
        }
    }
}

private extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255,
                  alpha: 1)
    }
}

// MARK: - Brand type

extension Font {
    /// Newsreader carries the brand voice; body copy stays on the system face.
    /// Falls back to the system serif if the bundled face failed to register.
    static func brand(_ size: CGFloat) -> Font {
        BrandFonts.isAvailable
            ? .custom("Newsreader-Regular", size: size)
            : .system(size: size, design: .serif)
    }
}

/// Bundled files, resolved through `Bundle.main` only.
///
/// Deliberately *not* `Bundle.module`: SPM's generated accessor probes candidate
/// directories including the build directory by absolute path. That path is under
/// `~/Desktop` here, so the very first resource lookup opens a TCC-protected
/// directory and blocks — in `InkletMacApp.init()`, before any window exists, so
/// the app just sits there with no UI at all.
///
/// `Scripts/build-app.sh` flattens the SPM resource bundle into
/// `Contents/Resources`, which is what `Bundle.main` reads.
enum AppResources {
    static func url(_ name: String, extension ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext)
    }
}

enum BrandFonts {
    private(set) nonisolated(unsafe) static var isAvailable = false

    /// Registers bundled faces with Core Text at launch. A missing resource just
    /// leaves `isAvailable` false, so the UI degrades to the system serif.
    /// Google Sans Medium, which Google's Sign in with Google branding
    /// specifies for the button label (OFL, from Google Fonts).
    private(set) nonisolated(unsafe) static var isGoogleSansAvailable = false

    static func register() {
        if let url = AppResources.url("Newsreader-Regular", extension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            isAvailable = NSFont(name: "Newsreader-Regular", size: 12) != nil
        }
        if let url = AppResources.url("GoogleSans-Medium", extension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            isGoogleSansAvailable = NSFont(name: "GoogleSans-Medium", size: 12) != nil
        }
    }

    /// The Sign in with Google label: Google Sans Medium 14, or the system
    /// font at the same weight when the face did not register.
    static func googleSignIn(_ size: CGFloat) -> Font {
        isGoogleSansAvailable ? .custom("GoogleSans-Medium", size: size) : .system(size: size, weight: .medium)
    }
}

// MARK: - Shared containers

/// One card shape for the entire app. Borderless: the tone step does the work, and
/// `containerShape` lets anything nested inside round concentrically.
struct InkCard<Content: View>: View {
    var padding: CGFloat = 18
    /// Grow to the height offered. Stretching from the outside doesn't work: the
    /// background is applied to the content's own size, so the fill would stay
    /// short while the frame grew.
    var stretches = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity,
                   maxHeight: stretches ? .infinity : nil,
                   alignment: .topLeading)
            .background(Ink.card, in: .rect(cornerRadius: Ink.cardCorner))
            .clipShape(.rect(cornerRadius: Ink.cardCorner))
            .containerShape(.rect(cornerRadius: Ink.cardCorner))
    }
}

/// Shared type roles: serif page titles, readable section headings and quiet metadata.
enum InkType {
    static let title = Font.brand(34)
    static let section = Font.system(size: 16, weight: .semibold)
    static let body = Font.system(size: 15)
    static let metadata = Font.system(size: 12)
}

/// A section heading, never a decorative all-caps eyebrow.
struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(InkType.section)
            .foregroundStyle(Ink.text)
    }
}
