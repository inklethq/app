import Foundation
import InkletPresentationKit

enum APIError: LocalizedError, Sendable {
    case notAuthenticated
    case sessionExpired
    case invalidCredentials
    case network
    case http(Int, String?)
    case decoding
    case widgetCache
    case noPush              // 404 from a push endpoint: nothing on screen yet
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: "Not signed in"
        case .sessionExpired: "Your session expired — sign in again"
        case .invalidCredentials: "Wrong email or password"
        case .network: "Can't reach inklet"
        case .http(let code, let message): message ?? "Server error (\(code))"
        case .decoding: "Unexpected response from the server"
        case .widgetCache: "Couldn't update the inklet Widget"
        case .noPush: "Nothing on screen yet"
        case .cancelled: nil
        }
    }
}

/// Why `POST /api/devices/quote0` refused, in the words the setup form shows.
/// One case per backend code; the wording is ours, the codes are the contract
/// (inklet-backend docs/api/quote0.md §3).
enum Quote0BindError: LocalizedError, Equatable, Sendable {
    case invalidKey
    case notInAccount
    case alreadyBound
    case rateLimited
    case dotUnavailable
    case unavailable
    case other(String)

    var errorDescription: String? {
        switch self {
        case .invalidKey: "Dot. didn't accept that API key. Create one in the Dot. app under More → API Key and paste it whole."
        case .notInAccount: "That serial number isn't a display in this Dot. account. Check it under the device in the Dot. app."
        case .alreadyBound: "That display is already connected to another inklet account."
        case .rateLimited: "Dot. is rate limiting this key. Wait a moment and try again."
        case .dotUnavailable: "Dot. isn't answering right now. Try again in a minute."
        case .unavailable: "Quote/0 isn't enabled on this inklet server yet."
        case .other(let message): message
        }
    }

    /// The backend's `code` decides; the message is a fallback for a code this
    /// build does not know.
    static func from(status: Int, code: String?, message: String?) -> Quote0BindError {
        switch code {
        case "INVALID_DOT_API_KEY": .invalidKey
        case "DOT_DEVICE_NOT_FOUND": .notInAccount
        case "DEVICE_ALREADY_BOUND": .alreadyBound
        case "DOT_RATE_LIMITED": .rateLimited
        case "DOT_UNAVAILABLE": .dotUnavailable
        case "QUOTE0_UNAVAILABLE": .unavailable
        default: .other(message ?? "The display couldn't be connected (\(status)).")
        }
    }
}

/// The one place that talks to the backend.
///
/// An actor because token refresh has to be serialised: several screens load at
/// once on launch, and without coalescing each 401 would fire its own refresh and
/// the losers would rotate the token out from under the winner.
actor InkletAPI {
    static let shared = InkletAPI()

    private let authBase = URL(string: "https://auth.iminklet.com")!
    private let apiBase = URL(string: "https://dev.iminklet.com")!

    private let session: URLSession
    private var tokens: AuthTokens?
    private var didLoadStoredTokens = false
    private var refreshInFlight: Task<AuthTokens, Error>?

    init() {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        // Presigned S3 URLs are single-use and time-boxed; a cached 200 for one
        // would be served after the signature expired.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    /// Deliberately not done in `init`. This type is a `static let`, so its
    /// initializer runs on whichever thread touches it first — which is the main
    /// thread, via `Session.restore()`. Reading the credential store there means
    /// any blocking prompt behind it freezes the whole app before a window exists.
    /// Inside an actor method the read happens on the actor's executor instead.
    private func loadStoredTokensIfNeeded() {
        guard !didLoadStoredTokens else { return }
        didLoadStoredTokens = true
        tokens = TokenStore.load()
    }

    var hasCredentials: Bool {
        loadStoredTokensIfNeeded()
        return tokens != nil
    }

    // MARK: - Session lifecycle

    func adopt(_ newTokens: AuthTokens) {
        didLoadStoredTokens = true
        tokens = newTokens
        TokenStore.save(newTokens)
    }

    func signOut() async {
        if let tokens {
            var request = URLRequest(url: authBase.appending(path: "auth/logout"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONEncoder().encode(["refreshToken": tokens.refreshToken])
            _ = try? await session.data(for: request)
        }
        tokens = nil
        refreshInFlight?.cancel()
        refreshInFlight = nil
        TokenStore.clear()
    }

    func login(identifier: String, password: String) async throws -> UserDTO {
        let body = ["identifier": identifier, "password": password]
        let response: LoginResponseDTO = try await unauthenticated(
            "auth/login", method: "POST", json: body, treat401AsBadPassword: true)
        adopt(AuthTokens(accessToken: response.accessToken, refreshToken: response.refreshToken))
        return response.user
    }

    /// Fetches the profile, refreshing once if the stored access token is stale.
    /// Returns nil when there is no usable session at all.
    func restore() async -> UserDTO? {
        loadStoredTokensIfNeeded()
        guard tokens != nil else { return nil }
        if let user = try? await me() { return user }
        guard (try? await refreshTokens()) != nil else {
            await signOut()
            return nil
        }
        guard let user = try? await me() else {
            await signOut()
            return nil
        }
        return user
    }

    func me() async throws -> UserDTO {
        try await authed("auth/me", base: authBase)
    }

    // MARK: - Devices

    func devices() async throws -> [DeviceDTO] {
        try await authed("api/devices")
    }

    func device(_ id: String) async throws -> DeviceDTO {
        try await authed("api/devices/\(id)")
    }

    /// `GET /api/app/v1/presentations?displayId=`: everything that has ever
    /// been on this panel — queued, published, confirmed, expired — newest
    /// first. The Free plan sees the last 7 days; `historyWindowStart` says so.
    func displayHistory(displayID: String, limit: Int = 30, cursor: String? = nil) async throws -> PresentationPageDTO {
        var path = "api/app/v1/presentations?displayId=\(displayID)&limit=\(min(max(limit, 1), 50))"
        if let cursor, let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            path += "&cursor=\(encoded)"
        }
        return try await authed(path)
    }

    /// `GET /api/app/v1/displays/{id}/current-presentation`: the Presentation the
    /// panel last confirmed, with a fresh signed image URL. A pure read — the
    /// legacy `/push` route promoted the queue as a side effect.
    func currentPresentation(displayID: String) async throws -> GeneratedPresentationDTO? {
        let response: CurrentPresentationDTO = try await authed("api/app/v1/displays/\(displayID)/current-presentation?format=png")
        return response.presentation
    }

    func setNickname(deviceID: String, nickname: String) async throws {
        try await authedVoid("api/devices/\(deviceID)/nickname", method: "PUT",
                             json: ["nickname": nickname])
    }

    func unbind(deviceID: String) async throws {
        try await authedVoid("api/devices/\(deviceID)/unbind", method: "POST")
    }

    /// `POST /api/devices/quote0`: claim a Dot. Quote/0 with an API key and its
    /// serial number. The key travels once, in this body, and is not kept —
    /// the backend seals it; nothing here logs the request.
    func bindQuote0(apiKey: String, serial: String) async throws -> DeviceDTO {
        let (data, status) = try await authedResponse("api/devices/quote0", method: "POST",
                                                      json: ["apiKey": apiKey, "serial": serial])
        switch status {
        case 200...299:
            guard let response = try? JSONDecoder().decode(Quote0BindResponseDTO.self, from: data) else {
                throw APIError.decoding
            }
            return response.device
        case 401:
            throw APIError.sessionExpired
        default:
            let envelope = serverError(data)
            throw Quote0BindError.from(status: status, code: envelope.code, message: envelope.message)
        }
    }

    /// `POST /api/app/v1/displays/{id}/advance`: show the next queued item.
    /// Returns false on an empty queue, which is not an error. No AI, no quota.
    func advanceDisplay(displayID: String) async throws -> Bool {
        let result: DisplayAdvanceDTO = try await authed("api/app/v1/displays/\(displayID)/advance", method: "POST")
        return result.changed ?? false
    }

    /// `POST /api/app/v1/displays/{id}/current`: put one of this panel's own
    /// rendered Presentations back on screen, including an expired one.
    func setCurrentPresentation(displayID: String, presentationID: String) async throws {
        try await authedVoid("api/app/v1/displays/\(displayID)/current", method: "POST",
                             json: ["presentationId": presentationID])
    }

    // MARK: - Contents (`/api/app/v1`)

    /// One page of the account's Contents, newest first. This is what
    /// Knowledge shows; uploads from every client land here.
    func contents(cursor: String? = nil, limit: Int = 50) async throws -> ContentPageDTO {
        var path = "api/app/v1/contents?limit=\(min(max(limit, 1), 50))"
        if let cursor, let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            path += "&cursor=\(encoded)"
        }
        return try await authed(path)
    }

    /// Downloads a presigned asset. Not routed through the authed helpers — S3
    /// rejects requests that carry an unexpected Authorization header.
    func fetchData(from url: URL) async throws -> Data {
        do {
            let (data, response) = try await session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else { throw APIError.http(status, nil) }
            return data
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.network
        }
    }

    // MARK: - Plumbing

    private func authed<T: Decodable>(_ path: String,
                                      base: URL? = nil,
                                      method: String = "GET",
                                      json: [String: String]? = nil,
                                      jsonObject: [String: Any]? = nil,
                                      headers: [String: String] = [:]) async throws -> T {
        let data = try await authedData(
            path,
            base: base,
            method: method,
            json: json,
            jsonObject: jsonObject,
            headers: headers
        )
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else { throw APIError.decoding }
        return decoded
    }

    private func authedVoid(_ path: String,
                            method: String,
                            json: [String: String]? = nil,
                            headers: [String: String] = [:]) async throws {
        _ = try await authedData(path, method: method, json: json, headers: headers)
    }

    /// Transport for `TargetlessClient` and `VirtualDisplayController`. Errors
    /// keep the backend's `code` and `details`, which the composer branches on
    /// (`no_compatible_display`, `asset_not_uploaded`).
    func virtualDisplayRequest(_ path: String, method: String, body: Data?, headers: [String: String] = [:]) async throws -> Data {
        let object = try body.map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let (data, status) = try await authedResponse(path, method: method, jsonObject: object ?? nil, headers: headers)
        switch status {
        case 200...299: return data
        case 401: throw APIError.sessionExpired
        default:
            let envelope = serverError(data)
            let fallback = status == 404
                ? "This display or presentation is unavailable. Refresh and try again."
                : "The request failed (\(status))."
            throw PresentationHTTPError(status: status, message: envelope.message ?? fallback, code: envelope.code, details: envelope.details)
        }
    }

    private func authedData(_ path: String,
                            base: URL? = nil,
                            method: String,
                            json: [String: String]? = nil,
                            jsonObject: [String: Any]? = nil,
                            headers: [String: String] = [:]) async throws -> Data {
        let (data, status) = try await authedResponse(path, base: base, method: method, json: json, jsonObject: jsonObject, headers: headers)
        return try validate(data, status)
    }

    /// The authenticated round trip with one 401 refresh, returning the raw
    /// status so callers can map errors their own way.
    private func authedResponse(_ path: String,
                                base: URL? = nil,
                                method: String,
                                json: [String: String]? = nil,
                                jsonObject: [String: Any]? = nil,
                                headers: [String: String] = [:]) async throws -> (Data, Int) {
        loadStoredTokensIfNeeded()
        guard let current = tokens else { throw APIError.notAuthenticated }

        let body: Data?
        if let jsonObject {
            body = try JSONSerialization.data(withJSONObject: jsonObject)
        } else if let json {
            body = try JSONEncoder().encode(json)
        } else {
            body = nil
        }

        let (data, status) = try await perform(path, base: base, method: method,
                                               body: body, accessToken: current.accessToken,
                                               headers: headers)
        if status == 401 {
            let refreshed = try await refreshTokens()
            return try await perform(path, base: base, method: method,
                                     body: body, accessToken: refreshed.accessToken,
                                     headers: headers)
        }
        return (data, status)
    }

    private func validate(_ data: Data, _ status: Int) throws -> Data {
        switch status {
        case 200...299: return data
        case 401: throw APIError.sessionExpired
        case 404: throw APIError.noPush
        default: throw APIError.http(status, serverMessage(data))
        }
    }

    private func perform(_ path: String, base: URL?, method: String,
                         body: Data?, accessToken: String,
                         headers: [String: String] = [:]) async throws -> (Data, Int) {
        let root = base ?? apiBase
        guard let url = URL(string: root.absoluteString + "/" + path) else { throw APIError.network }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            if path.hasPrefix("api/app/v1/"), let http {
                if (200...299).contains(http.statusCode), let renewed = http.value(forHTTPHeaderField: "X-Renewed-Token"),
                   !renewed.isEmpty, let current = tokens, current.accessToken == accessToken {
                    adopt(AuthTokens(accessToken: renewed, refreshToken: current.refreshToken))
                }
                if http.statusCode == 429 {
                    throw PresentationHTTPError(status: 429, message: serverMessage(data) ?? "Rendering is busy. Try again shortly.",
                                                retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
                }
            }
            return (data, http?.statusCode ?? 0)
        } catch let error as PresentationHTTPError {
            throw error
        } catch is CancellationError {
            throw APIError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw APIError.cancelled
        } catch {
            throw APIError.network
        }
    }

    /// One refresh at a time; concurrent callers await the same task.
    @discardableResult
    private func refreshTokens() async throws -> AuthTokens {
        if let refreshInFlight { return try await refreshInFlight.value }
        guard let current = tokens else { throw APIError.notAuthenticated }

        let task = Task<AuthTokens, Error> { [session, authBase] in
            var request = URLRequest(url: authBase.appending(path: "auth/refresh"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["refreshToken": current.refreshToken])

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw APIError.network
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status),
                  let fresh = try? JSONDecoder().decode(AuthTokens.self, from: data) else {
                throw APIError.sessionExpired
            }
            return fresh
        }
        refreshInFlight = task

        defer { refreshInFlight = nil }
        let fresh = try await task.value
        adopt(fresh)
        return fresh
    }

    private func unauthenticated<T: Decodable>(_ path: String, method: String,
                                               json: [String: String],
                                               treat401AsBadPassword: Bool = false) async throws -> T {
        var request = URLRequest(url: authBase.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(json)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.network
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            if status == 401 && treat401AsBadPassword { throw APIError.invalidCredentials }
            throw APIError.http(status, serverMessage(data))
        }
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else { throw APIError.decoding }
        return decoded
    }

    /// Supports both the legacy `{"error":"..."}` and SDK-style envelope.
    private struct ServerError { var code: String?; var message: String?; var details: [String: JSONValue]? }

    /// The `/api/sdk/v1` and `/api/app/v1` error envelope, `{ "error": { code, message, details } }`,
    /// with the legacy `{ "error": "…" }` shape as a fallback.
    private func serverError(_ data: Data) -> ServerError {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ServerError() }
        if let nested = object["error"] as? [String: Any] {
            var details: [String: JSONValue]?
            if let raw = nested["details"] as? [String: Any], let encoded = try? JSONSerialization.data(withJSONObject: raw) {
                details = try? JSONDecoder().decode([String: JSONValue].self, from: encoded)
            }
            return ServerError(code: nested["code"] as? String, message: nested["message"] as? String, details: details)
        }
        return ServerError(code: object["code"] as? String, message: (object["error"] as? String) ?? (object["message"] as? String))
    }

    private func serverMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let body = object as? [String: Any] else { return nil }
        if let message = body["error"] as? String, !message.isEmpty { return message }
        if let error = body["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty { return message }
        if let message = body["message"] as? String, !message.isEmpty { return message }
        return nil
    }
}
