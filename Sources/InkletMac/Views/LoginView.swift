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

    /// Apple's HIG for custom Sign in with Apple buttons: black with white
    /// logo and title on light backgrounds, white on dark; the title in the
    /// system font at 43% of the button height (17pt of 40pt); logo and title
    /// only ever both black or both white.
    private var appleButton: some View {
        SignInButton(title: "Continue with Apple",
                     titleFont: .system(size: 17, weight: .medium),
                     fill: Self.dynamic(light: 0x000000, dark: 0xFFFFFF),
                     border: Self.dynamic(light: 0x000000, dark: 0xFFFFFF),
                     foreground: Self.dynamic(light: 0xFFFFFF, dark: 0x000000),
                     isBusy: session.isWorking) {
            Image(systemName: "apple.logo")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 20, height: 20)
        } action: {
            await session.signInWithApple()
        }
    }

    /// Google's Sign in with Google branding: 40pt tall, 1pt inside border,
    /// the unmodified 20pt colour G, a 14pt medium label 10pt from the logo,
    /// 12pt side padding; light #FFFFFF/#747775/#1F1F1F, dark
    /// #131314/#8E918F/#E3E3E3.
    private var googleButton: some View {
        SignInButton(title: "Continue with Google",
                     titleFont: BrandFonts.googleSignIn(14),
                     fill: Self.dynamic(light: 0xFFFFFF, dark: 0x131314),
                     border: Self.dynamic(light: 0x747775, dark: 0x8E918F),
                     foreground: Self.dynamic(light: 0x1F1F1F, dark: 0xE3E3E3),
                     isBusy: session.isWorking) {
            GoogleMark().frame(width: 20, height: 20)
        } action: {
            await session.signInWithGoogle()
        }
    }

    fileprivate static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
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

/// The stored session couldn't be checked: offline, a timeout, the server
/// having a bad moment. The session is kept, so this offers a retry rather
/// than the sign-in form, and tries again by itself when the network comes
/// back. Sign Out is there for the one case a retry can't fix — wanting a
/// different account while this one can't be reached.
struct UnreachableView: View {
    @Environment(Session.self) private var session

    var body: some View {
        VStack(spacing: 16) {
            Wordmark(size: 30)
            VStack(spacing: 4) {
                Text("Can't reach inklet")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Ink.text)
                Text("You're still signed in. Check your connection and try again.")
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.muted)
            }
            .multilineTextAlignment(.center)

            Button {
                Task { await session.retry() }
            } label: {
                Text(session.isWorking ? "Trying…" : "Try Again")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Ink.bg)
                    .frame(width: 160)
                    .padding(.vertical, 9)
                    .background(Ink.text.opacity(session.isWorking ? 0.35 : 1),
                                in: .rect(cornerRadius: Ink.controlCorner))
            }
            .buttonStyle(.plain)
            .disabled(session.isWorking)
            .keyboardShortcut(.defaultAction)

            Button("Sign Out") { Task { await session.signOut() } }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Ink.muted)
                .disabled(session.isWorking)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.bg.ignoresSafeArea())
        .background(WindowStyler().frame(width: 0, height: 0))
        .task { await session.retryWhenOnline() }
    }
}


/// One identity-provider button, sized to the stricter of the two brand
/// guidelines (Google: 40pt tall, 12pt side padding, 10pt between logo and
/// label). Both providers share the geometry so the pair reads as one set;
/// only colours, logos, and the title size each guideline fixes differ.
/// Both use the app's control corner so they line up with the sign-in form
/// above.
private struct SignInButton<Icon: View>: View {
    let title: String
    var titleFont: Font = .system(size: 14, weight: .medium)
    let fill: Color
    let border: Color
    let foreground: Color
    var isBusy = false
    @ViewBuilder var icon: Icon
    let action: @MainActor () async -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 10) {
                icon
                Text(title)
                    .font(titleFont)
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .padding(.horizontal, 12)
            .background(fill, in: .rect(cornerRadius: Ink.controlCorner))
            .overlay {
                RoundedRectangle(cornerRadius: Ink.controlCorner).strokeBorder(border)
            }
            // Google specifies an 8% state layer of the label colour on hover.
            .overlay {
                RoundedRectangle(cornerRadius: Ink.controlCorner)
                    .fill(foreground.opacity(isHovering ? 0.08 : 0))
            }
            .contentShape(.rect(cornerRadius: Ink.controlCorner))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .opacity(isBusy ? 0.6 : 1)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// Google's four-colour "G" at 120px in Resources, rendered from the SVG
/// Google publishes with its branding guidelines.
private struct GoogleMark: View {
    var body: some View {
        if let url = AppResources.url("google-mark", extension: "png"), let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
        } else {
            Image(systemName: "globe").font(.system(size: 14))
        }
    }
}
