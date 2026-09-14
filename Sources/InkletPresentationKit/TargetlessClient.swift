import Foundation

nonisolated public struct PresentationHTTPError: LocalizedError, Sendable {
    public let status: Int
    public let message: String
    public let retryAfter: Double?
    public init(status: Int, message: String, retryAfter: Double? = nil) {
        self.status = status; self.message = message; self.retryAfter = retryAfter
    }
    public var errorDescription: String? { message }
}
nonisolated public enum PresentationAsset: Sendable {
    case text(String), link(String)
    case binary(filename: String, contentType: String, data: Data)
}

/// Shared host-only orchestration. Account credentials stay in the supplied transport;
/// pre-signed uploads/downloads use an unauthenticated request.
nonisolated public struct TargetlessClient: Sendable {
    public typealias Transport = @Sendable (String, String, Data?, [String: String]) async throws -> Data
    public typealias Transfer = @Sendable (URLRequest) async throws -> (Data, Int)
    private let transport: Transport
    private let transfer: Transfer
    private let pause: @Sendable () async throws -> Void
    private let polls: Int
    public static func transferRequest(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    public init(transport: @escaping Transport,
                transfer: @escaping Transfer = TargetlessClient.transferRequest, polls: Int = 120, pause: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) {
        self.transport = transport; self.transfer = transfer; self.polls = polls; self.pause = pause
    }
    private struct Content: Decodable {
        let id: String; let state: String; let presentationIds: [String]
        let upload: Upload?
        let processing: Processing?
        struct Upload: Decodable { let status: String; let failedAssetIndexes: [Int] }
        struct Processing: Decodable { let error: PresentationProblemDTO? }
    }
    private struct Created: Decodable { let content: Content; let uploadTickets: [Ticket] }
    private struct Ticket: Decodable { let assetIndex: Int; let url: String; let fields: [String: String] }
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
    public func generate(assets: [PresentationAsset], mode: String = "auto", requestID: UUID,
                         width: Int = 720, height: Int = 752) async throws -> GeneratedPresentationDTO {
        guard !assets.isEmpty, ["auto", "hardcode"].contains(mode), width > 0, height > 0,
              width <= 8192, height <= 8192, Int64(width) * Int64(height) <= 4_000_000 else {
            throw VirtualDisplayError.message("Invalid presentation content or output size.")
        }
        if mode == "hardcode" {
            guard assets.count == 1, case .binary(_, let type, _) = assets[0], ["image/png", "image/jpeg"].contains(type) else {
                throw VirtualDisplayError.message("Image mode needs exactly one PNG or JPEG.")
            }
        }
        let wire: [[String: Any]] = assets.map {
            switch $0 {
            case .text(let text): return ["type": "text", "text": text]
            case .link(let url): return ["type": "link", "url": url]
            case .binary(let filename, let type, let data):
                return ["type": type.hasPrefix("image/") ? "image" : "file", "filename": filename, "contentType": type, "sizeBytes": data.count]
            }
        }
        let body = try JSONSerialization.data(withJSONObject: ["mode": mode, "intent": "Create a calm, glanceable inklet presentation", "assets": wire,
            "output": ["formats": ["scene", "png"], "viewport": ["width": width, "height": height], "colorMode": "color"]], options: [.sortedKeys])
        let created = try await json(Created.self, path: "contents", method: "POST", body: body, key: "native-\(requestID.uuidString.lowercased())")
        var content = created.content
        if content.state == "pending" {
            try await upload(created.uploadTickets, assets: assets)
            content = try await json(Content.self, path: "contents/\(content.id)/confirm", method: "POST")
            if content.upload?.status == "partial", let missing = content.upload?.failedAssetIndexes, !missing.isEmpty {
                let retry = try await json(Created.self, path: "contents/\(content.id)/upload-tickets", method: "POST", body: JSONEncoder().encode(["assetIndexes": missing]))
                try await upload(retry.uploadTickets, assets: assets)
                content = try await json(Content.self, path: "contents/\(content.id)/confirm", method: "POST")
            }
        }
        for _ in 0..<polls {
            try Task.checkCancellation()
            if content.state == "ready" { break }
            if content.state == "failed" { throw VirtualDisplayError.message(content.processing?.error?.message ?? "Presentation generation failed.") }
            guard ["pending", "processing"].contains(content.state), content.upload?.status != "partial" else {
                throw VirtualDisplayError.message("The upload is incomplete. Try again with the same draft.")
            }
            try await pause()
            content = try await json(Content.self, path: "contents/\(content.id)")
        }
        guard content.state == "ready", let id = content.presentationIds.first, content.presentationIds.count == 1 else {
            throw VirtualDisplayError.message("Generation is still processing. Retry this draft to resume without starting another generation.")
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
    private func upload(_ tickets: [Ticket], assets: [PresentationAsset]) async throws {
        for ticket in tickets {
            guard assets.indices.contains(ticket.assetIndex), case .binary(let filename, _, let data) = assets[ticket.assetIndex],
                  let url = URL(string: ticket.url), url.scheme == "https", url.user == nil, url.password == nil else {
                throw VirtualDisplayError.message("Invalid image upload ticket.")
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
            guard (200...299).contains(code) else { throw VirtualDisplayError.message("Image upload failed (\(code)). Retry this draft.") }
        }
    }
}
