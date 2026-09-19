import SwiftUI

struct LoginView: View {
    @Environment(Session.self) private var session

    @State private var identifier = ""
    @State private var password = ""
    @FocusState private var focus: Field?

    private enum Field { case identifier, password }

    private var canSubmit: Bool {
        !identifier.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && !session.isWorking
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            // Rhythm from the web portal's sign-in page: the form, a 20pt band
            // around the divider, the two provider buttons 10pt apart, then the
            // footer. One spacing for everything read as a stack of unrelated
            // rows.
            VStack(spacing: 0) {
                wordmark
                    .padding(.bottom, 28)
                form
                divider
                    .padding(.vertical, 20)
                VStack(spacing: 10) {
                    appleButton
                    googleButton
                }
                footer
                    .padding(.top, 24)
            }
            .frame(width: 340)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.bg.ignoresSafeArea())
        .background(WindowStyler().frame(width: 0, height: 0))
        .onAppear { focus = .identifier }
    }

    private var wordmark: some View {
        VStack(spacing: 10) {
            Wordmark(size: 34)
            Text("Your second brain, on paper.")
                .font(.system(size: 13))
                .foregroundStyle(Ink.muted)
        }
        .padding(.bottom, 4)
    }

    private var form: some View {
        VStack(spacing: 10) {
            InkTextField(text: $identifier, placeholder: "Email or username")
                .focused($focus, equals: .identifier)
                .onSubmit { focus = .password }

            InkTextField(text: $password, placeholder: "Password", isSecure: true)
                .focused($focus, equals: .password)
                .onSubmit(submit)

            if let error = session.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }

            Button(action: submit) {
                Text(session.isWorking ? "Signing in…" : "Sign In")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Ink.bg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Ink.text.opacity(canSubmit ? 1 : 0.35),
                                in: .rect(cornerRadius: Ink.controlCorner))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 4)
        }
        .animation(.easeOut(duration: 0.15), value: session.error)
    }

    private var divider: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Ink.border).frame(height: 1)
            Text("or")
                .font(.system(size: 12))
                .foregroundStyle(Ink.muted)
            Rectangle().fill(Ink.border).frame(height: 1)
        }
    }

    private var appleButton: some View {
        ProviderButton(title: "Continue with Apple", isBusy: session.isWorking) {
            Image(systemName: "apple.logo")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 16, height: 16)
        } action: {
            await session.signInWithApple()
        }
    }

    private var googleButton: some View {
        ProviderButton(title: "Continue with Google", isBusy: session.isWorking) {
            GoogleMark().frame(width: 16, height: 16)
        } action: {
            await session.signInWithGoogle()
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Text("No account yet?")
                .font(.system(size: 12))
                .foregroundStyle(Ink.muted)
            // A `Link` paints itself the system link blue, which `.tint` doesn't
            // reach — a button that opens the URL keeps it in the ink palette.
            Button {
                NSWorkspace.shared.open(URL(string: "https://portal.iminklet.com/register")!)
            } label: {
                Text("Create one on the web portal")
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.text)
                    .underline()
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
        }
    }

    private func submit() {
        guard canSubmit else { return }
        Task { await session.signIn(identifier: identifier, password: password) }
    }
}

/// Text input in the ink palette. Same reason as `InkSearchField`: the system
/// field's `textBackgroundColor` is a cool grey that fights the warm paper.
struct InkTextField: View {
    @Binding var text: String
    var placeholder: String
    var isSecure = false

    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 14))
        .foregroundStyle(Ink.text)
        .focused($isFocused)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Ink.input, in: .rect(cornerRadius: Ink.controlCorner))
        .overlay {
            RoundedRectangle(cornerRadius: Ink.controlCorner)
                .strokeBorder(isFocused ? Ink.text.opacity(0.5) : Ink.border,
                              lineWidth: isFocused ? 1.5 : 1)
        }
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

/// "inklet PORTAL" is one trademark. It never wraps and never appears without the
/// second half, so every surface that shows it uses this — proportions scale off
/// the single `size` argument.
struct Wordmark: View {
    var size: CGFloat = 34

    /// Not a straight ratio of `size`. At 0.382 the small caps come out at 7pt on
    /// the HUD's 19pt wordmark, which reads as a smudge next to the serif — small
    /// sizes need optical compensation, so the ratio opens up below 24pt.
    private var portalSize: CGFloat {
        size < 24 ? size * 0.50 : size * 0.382
    }

    /// Letterspacing doesn't scale linearly either: the same 23% that looks right
    /// at 13pt reads as gappy once the caps drop near 9pt.
    private var portalTracking: CGFloat {
        portalSize * (portalSize < 11 ? 0.15 : 0.23)
    }

    var body: some View {
        // Baseline alignment rather than a hand-tuned top inset: two different
        // typefaces at two different sizes only line up reliably on the baseline.
        HStack(alignment: .firstTextBaseline, spacing: size * 0.206) {
            Text("inklet")
                .font(.brand(size))
                .foregroundStyle(Ink.text)
            Text("PORTAL")
                .font(.system(size: portalSize, weight: .medium))
                .tracking(portalTracking)
                .foregroundStyle(Ink.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
        .lineLimit(1)
        .accessibilityElement()
        .accessibilityLabel("inklet Portal")
    }
}

/// Shown while the stored session is being checked — a plain spinner would flash
/// on a warm restore, so this is deliberately quiet.
struct SplashView: View {
    var body: some View {
        VStack(spacing: 16) {
            Wordmark(size: 30)
            ProgressView()
                .controlSize(.small)
                .tint(Ink.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.bg.ignoresSafeArea())
        .background(WindowStyler().frame(width: 0, height: 0))
    }
}


/// The portal's `.portal-button-secondary`: paper-white on light, a lifted
/// charcoal on dark, a hairline border that darkens on hover, 36pt tall.
private struct ProviderButton<Icon: View>: View {
    let title: String
    var isBusy = false
    @ViewBuilder var icon: Icon
    let action: @MainActor () async -> Void

    @State private var isHovering = false

    private static var fill: Color { dynamic(light: 0xFBFAF7, dark: 0x242321) }
    private static var stroke: Color { dynamic(light: 0xCFCBC1, dark: 0x4A463F) }
    private static var strokeHover: Color { dynamic(light: 0x6F6B63, dark: 0x8E8980) }

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 8) {
                icon
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(Ink.text)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(Self.fill, in: .rect(cornerRadius: Ink.controlCorner))
            .overlay {
                RoundedRectangle(cornerRadius: Ink.controlCorner)
                    .strokeBorder(isHovering ? Self.strokeHover : Self.stroke)
            }
            .contentShape(.rect(cornerRadius: Ink.controlCorner))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .opacity(isBusy ? 0.6 : 1)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// Google's four-colour "G" (96px PNG in Resources, rendered from the same
/// SVG the web portal inlines; SwiftUI's `Path(String)` cannot parse it).
private struct GoogleMark: View {
    var body: some View {
        if let url = AppResources.url("google-mark", extension: "png"), let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
        } else {
            Image(systemName: "globe").font(.system(size: 14))
        }
    }
}
