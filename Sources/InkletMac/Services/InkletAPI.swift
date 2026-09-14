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

    /// Preview image for one specific push. Unlike `GET .../push`, this is a pure
    /// read — the unqualified endpoint promotes the top queued push to PUBLISHED
    /// as a side effect, which is right for the firmware and wrong for a preview.
    func pushImage(deviceID: String, pushID: String) async throws -> PushImageDTO {
        try await authed("api/devices/\(deviceID)/push/\(pushID)?format=png")
    }

    func pushes(deviceID: String, limit: Int = 30, cursor: String? = nil) async throws -> PushPageDTO {
        var path = "api/devices/\(deviceID)/pushes?limit=\(min(max(limit, 1), 50))"
        if let cursor, !cursor.isEmpty {
            let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? cursor
            path += "&cursor=\(encoded)"
        }
        return try await authed(path)
    }

    func setNickname(deviceID: String, nickname: String) async throws {
        try await authedVoid("api/devices/\(deviceID)/nickname", method: "PUT",
                             json: ["nickname": nickname])
    }

    func unbind(deviceID: String) async throws {
        try await authedVoid("api/devices/\(deviceID)/unbind", method: "POST")
    }

    /// Advances the display to the next queued push. This is the write twin of
    /// the read-only preview above, so it only runs on an explicit "Show Next".
    @discardableResult
    func advanceQueue(deviceID: String) async throws -> PushImageDTO {
        try await authed("api/devices/\(deviceID)/push/refresh", method: "POST")
    }

    func setCurrentPush(deviceID: String, pushID: String) async throws {
        try await authedVoid("api/devices/\(deviceID)/current-push", method: "POST",
                             json: ["pushId": pushID])
    }

    // MARK: - Raw items

    func rawItems(page: Int = 1, limit: Int = 50) async throws -> RawItemsPageDTO {
        try await authed("api/raw-items?page=\(page)&limit=\(min(max(limit, 1), 50))")
    }

    func rawItem(_ id: String) async throws -> RawItemDTO {
        try await authed("api/raw-items/\(id)")
    }

    // MARK: - Upload

    struct Attachment: Sendable {
        var filename: String
        var contentType: String
        var data: Data

        var isImage: Bool { contentType.hasPrefix("image/") }
    }

    /// The three-step bundle upload: reserve the item and get presigned slots,
    /// PUT the bytes to S3, then confirm so the backend starts processing.
    @discardableResult
    func uploadBundle(mainText: String,
                      files: [Attachment] = [],
                      links: [String] = []) async throws -> ConfirmResponseDTO {
        var attachments: [[String: Any]] = files.map {
            ["filename": $0.filename, "contentType": $0.contentType, "sizeBytes": $0.data.count]
        }
        attachments.append(contentsOf: links.map { ["type": "link", "url": $0] })

        let body: [String: Any] = [
            "type": "PORTAL_UPLOAD_BUNDLE",
            "mainText": mainText,
            "attachments": attachments,
        ]
        let reserved: UploadResponseDTO = try await authed(
            "api/raw-items/upload", method: "POST", jsonObject: body)

        for ticket in reserved.attachments ?? [] {
            guard ticket.index < files.count else { continue }
            let file = files[ticket.index]
            try await postToStorage(url: ticket.url, fields: ticket.fields,
                                    filename: file.filename, data: file.data)
        }

        let confirmed: ConfirmResponseDTO = try await authed(
            "api/raw-items/\(reserved.itemId)/confirm", method: "POST")
        if let failed = confirmed.failed, !failed.isEmpty {
            throw APIError.http(422, "Attachment \(failed.map { String($0 + 1) }.joined(separator: ", ")) didn't upload")
        }
        return confirmed
    }

    /// Generates a software-only Presentation. The host model downloads and
    /// publishes the image only if the initiating account is still signed in.
    ///
    /// This mirrors `@inklethq/sdk` through the JWT-authenticated `/api/app/v1`
    /// mount. No registered Display is required and no device queue is touched.
    @discardableResult
    func generatePresentation(
        mainText: String,
        files: [Attachment] = [],
        links: [String] = [],
        preset: String = "macos-widget-large"
    ) async throws -> GeneratedPresentationDTO {
        var assets: [PresentationAsset] = []
        if !mainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { assets.append(.text(mainText)) }
        assets += files.map { .binary(filename: $0.filename, contentType: $0.contentType, data: $0.data) }
        assets += links.map { .link($0) }
        let client = TargetlessClient { [self] path, method, body, headers in
            try await virtualDisplayRequest(path, method: method, body: body, headers: headers)
        }
        let size: (Int, Int)
        switch preset {
        case "macos-widget-small": size = (340, 340)
        case "macos-widget-medium": size = (720, 340)
        default: size = (720, 752)
        }
        return try await client.generate(assets: assets, requestID: UUID(), width: size.0, height: size.1)
    }

    /// Sends one image straight to a display, bypassing the knowledge pipeline.
    /// The backend's custom-push route only accepts `image/*`.
    @discardableResult
    func customPush(deviceID: String, image: Attachment, title: String) async throws -> String {
        let ticket: CustomPushTicketDTO = try await authed(
            "api/devices/\(deviceID)/custom-push/upload", method: "POST",
            jsonObject: ["contentType": image.contentType, "sizeBytes": image.data.count])

        try await postToStorage(url: ticket.url, fields: ticket.fields,
                                filename: image.filename, data: image.data)

        let confirmed: CustomPushConfirmDTO = try await authed(
            "api/devices/\(deviceID)/custom-push/confirm", method: "POST",
            jsonObject: ["fileId": ticket.fileId, "title": title])
        return confirmed.pushId
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

    private func postToStorage(url: String, fields: [String: String],
                               filename: String, data: Data) async throws {
        guard let endpoint = URL(string: url) else { throw APIError.network }

        let boundary = "inklet-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        for (key, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let status: Int
        do {
            let (_, response) = try await session.data(for: request)
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            throw APIError.network
        }
        guard (200...299).contains(status) else {
            throw APIError.http(status, "Upload rejected by storage")
        }
    }

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

    func virtualDisplayRequest(_ path: String, method: String, body: Data?, headers: [String: String] = [:]) async throws -> Data {
        let object = try body.map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        do { return try await authedData(path, method: method, jsonObject: object ?? nil, headers: headers) }
        catch APIError.noPush { throw PresentationHTTPError(status: 404, message: "This display or presentation is unavailable. Refresh and try again.") }
        catch APIError.http(let code, let message) { throw PresentationHTTPError(status: code, message: message ?? "The request failed (\(code)).") }
    }

    private func authedData(_ path: String,
                            base: URL? = nil,
                            method: String,
                            json: [String: String]? = nil,
                            jsonObject: [String: Any]? = nil,
                            headers: [String: String] = [:]) async throws -> Data {
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
            let (retryData, retryStatus) = try await perform(path, base: base, method: method,
                                                             body: body, accessToken: refreshed.accessToken,
                                                             headers: headers)
            return try validate(retryData, retryStatus)
        }
        return try validate(data, status)
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
