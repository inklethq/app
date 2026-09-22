import SwiftUI
import AuthenticationServices
import Network
import Observation

/// Who is signed in, and the three ways to change that.
@MainActor
@Observable
final class Session {
    enum State: Equatable {
        case restoring
        /// A stored session exists but the server couldn't be asked about it.
        /// Not signed out: the tokens are kept and the check can be retried.
        case unreachable
        case signedOut
        case signedIn(UserDTO)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.restoring, .restoring), (.unreachable, .unreachable), (.signedOut, .signedOut): true
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
        settle(await InkletAPI.shared.restore())
    }

    /// Checks the stored session again from the unreachable screen. That
    /// screen stays up while this runs, so a second failure doesn't flash the
    /// splash in between.
    func retry() async {
        guard state == .unreachable, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        settle(await InkletAPI.shared.restore())
    }

    /// Retries each time the network comes back, for as long as the calling
    /// task lives — the unreachable screen's. The usual way to land there is a
    /// Mac that launched at login before Wi-Fi joined, and that should sort
    /// itself out without a click.
    func retryWhenOnline() async {
        var wasOnline: Bool?
        for await online in Self.connectivity() {
            // The first report is how things stand now, not a change; only a
            // path that was down and came back is worth another request.
            if online, wasOnline == false { await retry() }
            wasOnline = online
        }
    }

    private static func connectivity() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { continuation.yield($0.status == .satisfied) }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "com.iminklet.mac.network-path"))
        }
    }

    private func settle(_ outcome: RestoreOutcome) {
        switch outcome {
        case .signedIn(let user): state = .signedIn(user)
        case .signedOut: state = .signedOut
        case .unreachable: state = .unreachable
        }
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
            let tokens: AuthTokens
            switch WebAuthCallback(callback) {
            case .tokens(let received):
                tokens = received
            case .failure(let failure):
                error = failure == "oauth_failed" ? "\(provider.displayName) sign-in failed" : failure
                return
            case nil:
                error = "\(provider.displayName) sign-in didn't return a session"
                return
            }

            await InkletAPI.shared.adopt(tokens)
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

/// What the portal's desktop callback page hands back:
/// `inklet://auth/callback?accessToken=…&refreshToken=…`, or `?error=…`.
///
/// `ASWebAuthenticationSession` completes on any `inklet:` URL, so the host
/// and path are checked exactly before anything in the query is believed —
/// tokens that arrive at some other `inklet:` address are not a sign-in.
/// There is no `state` to compare: the backend's desktop flow neither takes
/// nor echoes one (its OAuth `state` only names the client type).
enum WebAuthCallback: Equatable {
    case tokens(AuthTokens)
    case failure(String)

    /// Nil for anything that isn't the callback, or is the callback without
    /// both tokens or an error.
    init?(_ url: URL) {
        guard url.scheme?.lowercased() == "inklet", url.host()?.lowercased() == "auth",
              url.path() == "/callback",
              url.user() == nil, url.password() == nil, url.port == nil, url.fragment() == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? {
            let matches = items.filter { $0.name == name }
            // A repeated key is ambiguous; neither copy is taken.
            guard matches.count == 1, let value = matches[0].value, !value.isEmpty else { return nil }
            return value
        }

        if let failure = value("error") {
            self = .failure(failure)
        } else if let access = value("accessToken"), let refresh = value("refreshToken") {
            self = .tokens(AuthTokens(accessToken: access, refreshToken: refresh))
        } else {
            return nil
        }
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
