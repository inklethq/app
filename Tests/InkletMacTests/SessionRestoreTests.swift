import Foundation
import Testing
@testable import InkletMac

// Launch checks the stored session with `auth/me`, refreshing once on a 401.
// Only the server refusing the session may sign the user out; being offline,
// a timeout, a 5xx or a captive portal's page must keep the tokens for a retry.

/// A scripted auth server. Each path answers from its own queue, in order; a
/// request nobody scripted — a logout the test didn't expect — is a failure.
final class ScriptedAuthServer: @unchecked Sendable {
    enum Reply: Sendable {
        case status(Int, String)
        case offline
    }

    private let lock = NSLock()
    private var replies: [String: [Reply]]
    private var log: [(path: String, authorization: String?)] = []

    init(_ replies: [String: [Reply]]) {
        self.replies = replies
    }

    var paths: [String] { lock.withLock { log.map(\.path) } }
    func authorizations(for path: String) -> [String?] {
        lock.withLock { log.filter { $0.path == path }.map(\.authorization) }
    }

    func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
        let url = request.url!
        let path = url.path()
        let reply = lock.withLock { () -> Reply? in
            log.append((path, request.value(forHTTPHeaderField: "Authorization")))
            guard var queue = replies[path], !queue.isEmpty else { return nil }
            let next = queue.removeFirst()
            replies[path] = queue
            return next
        }
        switch reply {
        case .status(let code, let body)?:
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
        case .offline?:
            throw URLError(.notConnectedToInternet)
        case nil:
            Issue.record("Unexpected request to \(path)")
            throw URLError(.badServerResponse)
        }
    }
}

/// Stands in for the Keychain, which a test run must never touch.
final class MemoryTokenVault: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AuthTokens?
    private var didClear = false

    init(_ tokens: AuthTokens?) {
        stored = tokens
    }

    var tokens: AuthTokens? { lock.withLock { stored } }
    var cleared: Bool { lock.withLock { didClear } }

    var vault: InkletAPI.TokenVault {
        InkletAPI.TokenVault(
            load: { self.tokens },
            save: { tokens in self.lock.withLock { self.stored = tokens } },
            clear: { self.lock.withLock { self.stored = nil; self.didClear = true } })
    }
}

private let stored = AuthTokens(accessToken: "access-1", refreshToken: "refresh-1")
private let user = #"{"id":"u1","email":"kz@example.com","username":"kz"}"#
private let refreshed = #"{"accessToken":"access-2","refreshToken":"refresh-2"}"#

private func restore(_ server: ScriptedAuthServer, _ vault: MemoryTokenVault) async -> RestoreOutcome {
    let api = InkletAPI(transport: { try server.respond($0) }, vault: vault.vault)
    return await api.restore()
}

private func isUnreachable(_ outcome: RestoreOutcome) -> Bool {
    if case .unreachable = outcome { return true }
    return false
}

private func isSignedOut(_ outcome: RestoreOutcome) -> Bool {
    if case .signedOut = outcome { return true }
    return false
}

@Test func aSessionTheServerAcceptsSignsIn() async {
    let server = ScriptedAuthServer(["/auth/me": [.status(200, user)]])
    let vault = MemoryTokenVault(stored)
    guard case .signedIn(let signedIn) = await restore(server, vault) else {
        Issue.record("Expected a signed-in outcome")
        return
    }
    #expect(signedIn.id == "u1")
    #expect(vault.tokens == stored)
    #expect(server.authorizations(for: "/auth/me") == ["Bearer access-1"])
}

@Test func nothingStoredIsSignedOutWithoutAsking() async {
    let server = ScriptedAuthServer([:])
    let vault = MemoryTokenVault(nil)
    #expect(isSignedOut(await restore(server, vault)))
    #expect(server.paths.isEmpty)
}

@Test func noNetworkAtLaunchKeepsTheSession() async {
    let server = ScriptedAuthServer(["/auth/me": [.offline]])
    let vault = MemoryTokenVault(stored)
    #expect(isUnreachable(await restore(server, vault)))
    #expect(vault.tokens == stored)
    #expect(!vault.cleared)
    // No logout: the server-side session must not be revoked either.
    #expect(server.paths == ["/auth/me"])
}

@Test(arguments: [503, 500, 429, 404])
func aServerThatCannotAnswerKeepsTheSession(status: Int) async {
    let server = ScriptedAuthServer(["/auth/me": [.status(status, #"{"error":"unavailable"}"#)]])
    let vault = MemoryTokenVault(stored)
    #expect(isUnreachable(await restore(server, vault)))
    #expect(vault.tokens == stored)
    #expect(server.paths == ["/auth/me"])
}

@Test func aCaptivePortalAnsweringForTheServerKeepsTheSession() async {
    let server = ScriptedAuthServer(["/auth/me": [.status(200, "<html>Sign in to Wi-Fi</html>")]])
    let vault = MemoryTokenVault(stored)
    #expect(isUnreachable(await restore(server, vault)))
    #expect(vault.tokens == stored)
}

@Test(arguments: [ScriptedAuthServer.Reply.offline, .status(500, #"{"error":"refresh failed"}"#),
                  .status(502, "Bad Gateway"), .status(200, "<html>captive</html>")])
func aRefreshThatIsNotARefusalKeepsTheSession(refresh: ScriptedAuthServer.Reply) async {
    let server = ScriptedAuthServer(["/auth/me": [.status(401, #"{"error":"unauthorized"}"#)], "/auth/refresh": [refresh]])
    let vault = MemoryTokenVault(stored)
    #expect(isUnreachable(await restore(server, vault)))
    #expect(vault.tokens == stored)
    #expect(!vault.cleared)
    #expect(server.paths == ["/auth/me", "/auth/refresh"])
}

@Test(arguments: [401, 400])
func aRefusedRefreshSignsOut(status: Int) async {
    let server = ScriptedAuthServer([
        "/auth/me": [.status(401, #"{"error":"unauthorized"}"#)],
        "/auth/refresh": [.status(status, #"{"error":"session not found"}"#)],
        "/auth/logout": [.status(401, #"{"error":"unauthorized"}"#)],
    ])
    let vault = MemoryTokenVault(stored)
    #expect(isSignedOut(await restore(server, vault)))
    #expect(vault.tokens == nil)
    #expect(vault.cleared)
    #expect(server.paths == ["/auth/me", "/auth/refresh", "/auth/logout"])
}

@Test func aStaleAccessTokenIsRefreshedAndTheNewSessionKept() async {
    let server = ScriptedAuthServer([
        "/auth/me": [.status(401, #"{"error":"unauthorized"}"#), .status(200, user)],
        "/auth/refresh": [.status(200, refreshed)],
    ])
    let vault = MemoryTokenVault(stored)
    guard case .signedIn = await restore(server, vault) else {
        Issue.record("Expected a signed-in outcome")
        return
    }
    #expect(vault.tokens == AuthTokens(accessToken: "access-2", refreshToken: "refresh-2"))
    #expect(server.authorizations(for: "/auth/me") == ["Bearer access-1", "Bearer access-2"])
}

@Test func aFreshTokenTheServerStillRefusesSignsOut() async {
    let server = ScriptedAuthServer([
        "/auth/me": [.status(401, #"{"error":"unauthorized"}"#), .status(401, #"{"error":"unauthorized"}"#)],
        "/auth/refresh": [.status(200, refreshed)],
        "/auth/logout": [.status(204, "")],
    ])
    let vault = MemoryTokenVault(stored)
    #expect(isSignedOut(await restore(server, vault)))
    #expect(vault.cleared)
}

@Test func onlyARefusalEndsASession() {
    #expect(APIError.endsSession(APIError.sessionExpired))
    #expect(APIError.endsSession(APIError.notAuthenticated))
    for error: Error in [APIError.network, APIError.http(503, nil), APIError.decoding, APIError.cancelled,
                         APIError.noPush, URLError(.timedOut), CancellationError()] {
        #expect(!APIError.endsSession(error))
    }
}
