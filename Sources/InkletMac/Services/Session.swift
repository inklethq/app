import SwiftUI
import AuthenticationServices
import Observation

/// Who is signed in, and the three ways to change that.
@MainActor
@Observable
final class Session {
    enum State: Equatable {
        case restoring
        case signedOut
        case signedIn(UserDTO)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.restoring, .restoring), (.signedOut, .signedOut): true
            case (.signedIn(let a), .signedIn(let b)): a.id == b.id
            default: false
            }
        }
    }

    private(set) var state: State = .restoring
    private(set) var isWorking = false
    var error: String?

    var user: UserDTO? {
        if case .signedIn(let user) = state { return user }
        return nil
    }

    func restore() async {
        let user = await InkletAPI.shared.restore()
        state = user.map(State.signedIn) ?? .signedOut
    }

    func signIn(identifier: String, password: String) async {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }

        do {
            let user = try await InkletAPI.shared.login(identifier: identifier, password: password)
            state = .signedIn(user)
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Google sign-in runs through the portal's desktop callback page, which
    /// bounces the tokens back as `inklet://auth/callback?...`.
    /// `ASWebAuthenticationSession` claims that scheme for the duration of the
    /// flow, so the app doesn't have to register a URL handler and fight the
    /// Electron client for it.
    func signInWithGoogle() async {
        await signInWithProvider(.google)
    }

    /// Sign in with Apple uses the same portal desktop callback as Google. The
    /// backend's `/auth/oauth/apple?client=desktop` flow already exists for the
    /// web portal and iOS, so nothing here needs the restricted
    /// `com.apple.developer.applesignin` entitlement or a provisioning profile.
    func signInWithApple() async {
        await signInWithProvider(.apple)
    }

    enum OAuthProvider: String {
        case google, apple

        var displayName: String {
            switch self {
            case .google: "Google"
            case .apple: "Apple"
            }
        }

        var authorizationURL: URL {
            URL(string: "https://auth.iminklet.com/auth/oauth/\(rawValue)?client=desktop")!
        }
    }

    private func signInWithProvider(_ provider: OAuthProvider) async {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }

        do {
            let callback = try await Self.runWebAuth(url: provider.authorizationURL)
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

            if let failure = value("error") {
                error = failure == "oauth_failed" ? "\(provider.displayName) sign-in failed" : failure
                return
            }
            guard let access = value("accessToken"), let refresh = value("refreshToken") else {
                error = "\(provider.displayName) sign-in didn't return a session"
                return
            }

            await InkletAPI.shared.adopt(AuthTokens(accessToken: access, refreshToken: refresh))
            let user = try await InkletAPI.shared.me()
            state = .signedIn(user)
        } catch is CancellationError {
            return
        } catch {
            if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { return }
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    func signOut() async {
        await InkletAPI.shared.signOut()
        state = .signedOut
    }

    /// Called when a request comes back 401 after a failed refresh — the tokens
    /// are dead, so drop straight back to the login screen.
    func invalidate() async {
        await InkletAPI.shared.signOut()
        state = .signedOut
        error = "Your session expired — sign in again"
    }

    private static func runWebAuth(url: URL) async throws -> URL {
        let coordinator = WebAuthCoordinator()
        return try await coordinator.run(url: url)
    }
}

/// Holds the `ASWebAuthenticationSession` and its context provider alive for the
/// length of the flow — the session keeps only a weak reference to the provider,
/// and nothing else would retain the session itself once `run` suspends.
@MainActor
private final class WebAuthCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var webSession: ASWebAuthenticationSession?

    func run(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let result = WebAuthResultRelay(continuation)
            let webSession = ASWebAuthenticationSession(
                url: url, callbackURLScheme: "inklet", completionHandler: result.completion)
            webSession.presentationContextProvider = self
            webSession.prefersEphemeralWebBrowserSession = false
            self.webSession = webSession

            if !webSession.start() {
                result.finish(callback: nil, error: APIError.network)
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        }
    }
}
