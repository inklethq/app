import Foundation

nonisolated public struct PresentationHTTPError: LocalizedError, Sendable {
    public let status: Int
    public let message: String
    public let retryAfter: Double?
    /// The backend's stable error code (`no_compatible_display`, …), when the
    /// response carried the standard envelope.
    public let code: String?
    public let details: [String: JSONValue]?
    public init(status: Int, message: String, retryAfter: Double? = nil, code: String? = nil, details: [String: JSONValue]? = nil) {
        self.status = status; self.message = message; self.retryAfter = retryAfter; self.code = code; self.details = details
    }
    public var errorDescription: String? { message }
}
nonisolated public enum PresentationAsset: Sendable {
    case text(String), link(String)
    case binary(filename: String, contentType: String, data: Data)

    public var isImage: Bool {
        if case .binary(_, let type, _) = self { return type.hasPrefix("image/") }
        return false
    }
}

/// The two-call flow behind every send: a Content, then an Analysis over it.
nonisolated public struct ComposeOutcome: Sendable {
    public let content: ContentDTO
    /// `nil` for `action: .upload`, and when the card was refused before a run existed.
    public let analysis: AnalysisDTO?
    /// `no_compatible_display`: the Content is saved, only the card was refused.
    public let refusal: String?
}

/// Shared host-only orchestration over `/api/app/v1`. Account credentials stay
/// in the supplied transport; pre-signed uploads/downloads use an
/// unauthenticated request.
///
/// Content → Analysis → Presentation. Uploading never runs AI; an Analysis
/// names the Contents and a target, and the backend produces Presentations.
nonisolated public struct TargetlessClient: Sendable {
    public typealias Transport = @Sendable (String, String, Data?, [String: String]) async throws -> Data
    public typealias Transfer = @Sendable (URLRequest) async throws -> (Data, Int)
    public typealias EventSink = @Sendable (AnalysisEventDTO) -> Void
    private let transport: Transport
    private let transfer: Transfer
    private let pause: @Sendable () async throws -> Void
    private let polls: Int
    private let followPolls: Int
    public static func transferRequest(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    /// `polls` bounds waits on renders; `followPolls` bounds waiting on an
    /// agent run, which can take minutes.
    public init(transport: @escaping Transport,
                transfer: @escaping Transfer = TargetlessClient.transferRequest, polls: Int = 120, followPolls: Int = 900,
                pause: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) {
        self.transport = transport; self.transfer = transfer; self.polls = polls; self.followPolls = followPolls; self.pause = pause
    }

    private func json<T: Decodable>(_ type: T.Type, path: String, method: String = "GET", body: Data? = nil, key: String? = nil) async throws -> T {
        let headers = key.map { ["Idempotency-Key": $0] } ?? [:]
        for attempt in 0..<4 {
            try Task.checkCancellation()
            do { return try JSONDecoder().decode(T.self, from: await transport("api/app/v1/" + path, method, body, headers)) }
            catch let error as PresentationHTTPError where error.status == 429 && attempt < 3 {
                guard (error.retryAfter ?? 1) <= 30 else { throw error }
                if let delay = error.retryAfter { try await Task.sleep(for: .seconds(max(1, delay))) }
                else { try await pause() }
            }
        }
        throw VirtualDisplayError.message("The rendering service is busy. Try again shortly.")
    }

    // MARK: - Content

    /// A title for a note the user did not title: the first non-empty line of
    /// the first text asset, cut to sixty characters. Pictures and bare links
    /// keep `nil`; the backend has better fallbacks than a filename.
    public static func title(for assets: [PresentationAsset]) -> String? {
        for case .text(let text) in assets {
            for line in text.split(whereSeparator: \.isNewline) {
                let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if collapsed.isEmpty { continue }
                if collapsed.count <= 60 { return collapsed }
                return String(collapsed.prefix(59)).trimmingCharacters(in: .whitespaces) + "…"
            }
        }
        return nil
    }

    /// `POST /contents`, then the binaries straight to storage. Nothing is
    /// analyzed; the Content is `pending` until storage reports the uploads,
    /// and `analyze` verifies them lazily if that has not happened yet.
    public func upload(assets: [PresentationAsset], title: String?, requestID: UUID) async throws -> ContentDTO {
        guard !assets.isEmpty, assets.count <= 50 else { throw VirtualDisplayError.message("Add something to send first.") }
        let wire: [[String: Any]] = assets.map {
            switch $0 {
            case .text(let text): return ["type": "text", "text": text]
            case .link(let url): return ["type": "link", "url": url]
            case .binary(let filename, let type, let data):
                return ["type": type.hasPrefix("image/") ? "image" : "file", "filename": filename, "contentType": type, "sizeBytes": data.count]
            }
        }
        let named = title ?? Self.title(for: assets)
        let body = try JSONSerialization.data(withJSONObject: ["title": named as Any? ?? NSNull(), "assets": wire], options: [.sortedKeys])
        let created = try await json(CreatedContentDTO.self, path: "contents", method: "POST", body: body, key: Self.key(requestID))
        let failed = try await upload(created.uploadTickets, assets: assets)
        if !failed.isEmpty {
            try await reupload(contentID: created.content.id, indexes: failed, assets: assets)
        }
        return created.content
    }

    private func reupload(contentID: String, indexes: [Int], assets: [PresentationAsset]) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["assetIndexes": indexes], options: [.sortedKeys])
        let refreshed = try await json(CreatedContentDTO.self, path: "contents/\(contentID)/upload-tickets", method: "POST", body: body)
        let stillFailing = try await upload(refreshed.uploadTickets, assets: assets)
        guard stillFailing.isEmpty else { throw VirtualDisplayError.message("Some attachments could not be uploaded. Retry this draft.") }
    }

    // MARK: - Analysis

    /// `POST /analyses` for one action over one Content.
    public func analyze(contentID: String, action: ComposeAction, target: AnalysisTargetSpec,
                        intent: String? = nil, title: String? = nil, requestID: UUID) async throws -> AnalysisDTO {
        guard action != .upload else { throw VirtualDisplayError.message("Nothing to analyze for an upload-only send.") }
        var body: [String: Any] = [
            "mode": action == .asIs ? "direct" : "ai",
            "contentIds": [contentID],
            "context": action == .cardHistory ? "history" : "submitted",
            "scope": action == .cardHistory ? ["since": ComposeAction.recentNotesWindow] : NSNull(),
            "intent": intent as Any? ?? NSNull(),
            "title": title as Any? ?? NSNull(),
        ]
        switch target {
        case .agent:
            guard action != .asIs else { throw VirtualDisplayError.message("Pick a display to show it as-is.") }
            body["target"] = NSNull()
        case .display(let id):
            body["target"] = ["displayId": id]
        case .output(let width, let height):
            guard width > 0, height > 0, width <= 8192, height <= 8192, Int64(width) * Int64(height) <= 4_000_000 else {
                throw VirtualDisplayError.message("Invalid output size.")
            }
            body["target"] = ["output": ["formats": ["scene", "png"], "viewport": ["width": width, "height": height], "colorMode": "color"]]
        }
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return try await json(AnalysisDTO.self, path: "analyses", method: "POST", body: data, key: Self.key(requestID))
    }

    /// Upload, then the run the user asked for. A `409 asset_not_uploaded` on
    /// the Analysis re-uploads exactly the missing assets and retries with the
    /// same idempotency key, so no second run is queued. A
    /// `422 no_compatible_display` comes back as `refusal`, not as an error:
    /// the Content is saved and only the card was refused.
    public func compose(assets: [PresentationAsset], title: String? = nil, action: ComposeAction,
                        target: AnalysisTargetSpec, intent: String? = nil, requestID: UUID) async throws -> ComposeOutcome {
        let named = title ?? Self.title(for: assets)
        let content = try await upload(assets: assets, title: named, requestID: requestID)
        guard action != .upload else { return ComposeOutcome(content: content, analysis: nil, refusal: nil) }

        func ask() async throws -> ComposeOutcome {
            do {
                let analysis = try await analyze(contentID: content.id, action: action, target: target, intent: intent, title: named, requestID: requestID)
                return ComposeOutcome(content: content, analysis: analysis, refusal: nil)
            } catch let error as PresentationHTTPError where error.status == 422 && error.code == "no_compatible_display" {
                return ComposeOutcome(content: content, analysis: nil, refusal: error.code)
            }
        }
        do { return try await ask() }
        catch let error as PresentationHTTPError where error.status == 409 && error.code == "asset_not_uploaded" {
            let missing = Self.failedAssetIndexes(in: error.details, contentID: content.id)
            guard !missing.isEmpty else { throw error }
            try await reupload(contentID: content.id, indexes: missing, assets: assets)
            return try await ask()
        }
    }

    static func failedAssetIndexes(in details: [String: JSONValue]?, contentID: String) -> [Int] {
        guard case .array(let failed)? = details?["failedAssets"] else { return [] }
        return failed.compactMap { entry -> Int? in
            guard case .object(let object) = entry, object["contentId"]?.stringValue == contentID,
                  case .number(let index)? = object["assetIndex"] else { return nil }
            return Int(index)
        }.sorted()
    }

    /// Poll the Analysis until it settles, forwarding every public event as it
    /// lands. The events page carries the state read at the same instant, so a
    /// run that finishes between polls is still seen with its last events.
    public func follow(analysisID: String, onEvent: EventSink? = nil) async throws -> AnalysisDTO {
        var after = 0
        for _ in 0..<followPolls {
            try Task.checkCancellation()
            var state: String? = nil
            var hasMore = true
            while hasMore {
                let page = try await json(AnalysisEventPageDTO.self, path: "analyses/\(analysisID)/events?after=\(after)&limit=200")
                for event in page.items { onEvent?(event); after = max(after, event.seq) }
                if let next = page.nextAfter { after = max(after, next) }
                hasMore = (page.hasMore ?? false) && !page.items.isEmpty
                state = page.state ?? state
            }
            if state == "completed" || state == "failed" {
                return try await json(AnalysisDTO.self, path: "analyses/\(analysisID)")
            }
            try await pause()
        }
        throw VirtualDisplayError.message("inklet is still working on this. Check the Home page for progress.")
    }

    // MARK: - Software-only generation (widgets, Virtual Displays)

    /// Upload, run, wait, and return the Presentation with a PNG at exactly
    /// this viewport. `mode` is `auto` (AI), `history` (AI over the last week
    /// too) or `hardcode` (one image, no AI).
    public func generate(assets: [PresentationAsset], mode: String = "auto", requestID: UUID,
                         width: Int = 720, height: Int = 752, onEvent: EventSink? = nil) async throws -> GeneratedPresentationDTO {
        let action: ComposeAction
        switch mode {
        case "auto", "card": action = .card
        case "history", "card_history": action = .cardHistory
        case "hardcode", "as_is": action = .asIs
        default: throw VirtualDisplayError.message("Invalid presentation content or output size.")
        }
        guard !assets.isEmpty, width > 0, height > 0, width <= 8192, height <= 8192, Int64(width) * Int64(height) <= 4_000_000 else {
            throw VirtualDisplayError.message("Invalid presentation content or output size.")
        }
        if action == .asIs {
            guard assets.count == 1, case .binary(_, let type, _) = assets[0], ["image/png", "image/jpeg"].contains(type) else {
                throw VirtualDisplayError.message("Image mode needs exactly one PNG or JPEG.")
            }
        }
        let outcome = try await compose(assets: assets, action: action, target: .output(width: width, height: height),
                                        intent: action == .asIs ? nil : "Create a calm, glanceable inklet presentation", requestID: requestID)
        guard let analysis = outcome.analysis else {
            throw VirtualDisplayError.message("inklet couldn't start generating this presentation.")
        }
        let done = try await follow(analysisID: analysis.id, onEvent: onEvent)
        if done.state == "failed" {
            throw VirtualDisplayError.message(done.failure?.message ?? "Presentation generation failed.")
        }
        guard done.outcome != "no_change" else {
            throw VirtualDisplayError.message(done.noChangeReason ?? "inklet found nothing new to show.")
        }
        guard let id = done.presentationIds.first else {
            throw VirtualDisplayError.message("Generation finished without a presentation. Retry this draft.")
        }
        return try await rendered(id: id, width: width, height: height)
    }

    public func rendered(id: String, width: Int, height: Int) async throws -> GeneratedPresentationDTO {
        var requested = false
        for _ in 0..<polls {
            let presentation = try await json(GeneratedPresentationDTO.self, path: "presentations/\(id)")
            if presentation.state == "failed" { throw VirtualDisplayError.message(presentation.failure?.message ?? "Scene generation failed.") }
            if let matching = presentation.renditions.first(where: { $0.format == "png" && $0.width == width && $0.height == height && ($0.colorMode == nil || $0.colorMode == "color") }) {
                if matching.state == "failed" { throw VirtualDisplayError.message(matching.failure?.message ?? "The PNG could not be rendered. Your existing display frame has been kept.") }
                if matching.isReady { return presentation }
            } else if presentation.state == "ready", !requested {
                // Reuse a stored Scene for a Retina or different-size output, without another AI call.
                let body = try JSONSerialization.data(withJSONObject: ["formats": ["png"], "viewport": ["width": width, "height": height], "colorMode": "color"], options: [.sortedKeys])
                _ = try await json(PresentationRenditionDTO.self, path: "presentations/\(id)/renditions", method: "POST", body: body,
                                   key: "native-render-\(id)-\(width)-\(height)")
                requested = true
            }
            try await pause()
        }
        throw VirtualDisplayError.message("The PNG is still rendering. Retry to resume this presentation.")
    }
    public func download(_ presentation: GeneratedPresentationDTO, width: Int, height: Int) async throws -> (GeneratedPresentationDTO, Data) {
        var current = presentation
        for attempt in 0..<2 {
            guard let rendition = current.renditions.first(where: { $0.isReady && $0.width == width && $0.height == height && ($0.colorMode == nil || $0.colorMode == "color") }),
                  let url = rendition.url.flatMap(URL.init(string:)), url.scheme == "https", url.user == nil, url.password == nil else {
                throw VirtualDisplayError.message("No completed PNG is available for this display.")
            }
            var request = URLRequest(url: url); request.timeoutInterval = 30
            let (data, status) = try await transfer(request)
            if status == 200 { return (current, data) }
            if [401, 403].contains(status), attempt == 0 {
                current = try await rendered(id: current.id, width: width, height: height)
                continue
            }
            throw VirtualDisplayError.message("Couldn't download the generated frame (\(status)). Try again.")
        }
        throw VirtualDisplayError.message("The generated image URL expired. Try again.")
    }

    // MARK: - Storage

    private static func key(_ requestID: UUID) -> String { "native-\(requestID.uuidString.lowercased())" }

    /// Returns the indexes whose upload storage did not accept.
    private func upload(_ tickets: [ContentUploadTicketDTO], assets: [PresentationAsset]) async throws -> [Int] {
        var failed: [Int] = []
        for ticket in tickets {
            try Task.checkCancellation()
            guard assets.indices.contains(ticket.assetIndex), case .binary(let filename, _, let data) = assets[ticket.assetIndex],
                  let url = URL(string: ticket.url), url.scheme == "https", url.user == nil, url.password == nil else {
                throw VirtualDisplayError.message("Invalid upload ticket.")
            }
            let boundary = "inklet-\(UUID())"
            var body = Data()
            func append(_ string: String) { body.append(Data(string.utf8)) }
            func safe(_ value: String) -> String { value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\"", with: "_") }
            for (key, value) in ticket.fields.sorted(by: { $0.key < $1.key }) {
                append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(safe(key))\"\r\n\r\n\(value)\r\n")
            }
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safe(filename))\"\r\nContent-Type: application/octet-stream\r\n\r\n")
            body.append(data); append("\r\n--\(boundary)--\r\n")
            var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 60
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            let (_, code) = try await transfer(request)
            if !(200...299).contains(code) { failed.append(ticket.assetIndex) }
        }
        return failed
    }
}
