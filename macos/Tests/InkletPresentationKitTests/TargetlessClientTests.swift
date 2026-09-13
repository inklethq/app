import Foundation
import Testing
@testable import InkletPresentationKit

private func fixturePresentation(state: String = "ready", rendition: String = "ready", width: Int = 720, url: String? = "https://images.example/frame.png") -> Data {
    let image: [String: Any] = ["id": "render", "format": "png", "mediaType": "image/png", "width": width, "height": 752,
        "state": rendition, "colorMode": "color", "url": url as Any? ?? NSNull(), "expiresAt": url == nil ? NSNull() : "2026-09-11T02:00:00Z",
        "failure": rendition == "failed" ? ["code": "render_failed", "message": "Render rejected", "retryable": false] : NSNull(), "updatedAt": "now"]
    return try! JSONSerialization.data(withJSONObject: ["id": "presentation", "displayId": NSNull(), "contentIds": ["content"], "mode": "auto", "state": state,
        "renditions": [image], "createdAt": "now", "updatedAt": "now"])
}
private actor ScriptedAPI {
    struct Step: Sendable { let path: String; let method: String; let data: Data }
    var steps: [Step]
    var bodies: [Data] = []
    var keys: [String] = []
    init(_ steps: [Step]) { self.steps = steps }
    func request(_ path: String, _ method: String, _ body: Data?, _ headers: [String: String]) throws -> Data {
        let step = try #require(steps.first)
        steps.removeFirst()
        #expect(path == "api/app/v1/" + step.path)
        #expect(method == step.method)
        if let body { bodies.append(body) }
        if let key = headers["Idempotency-Key"] { keys.append(key) }
        return step.data
    }
    func finished() -> Bool { steps.isEmpty }
}
private func created(_ state: String = "pending", tickets: String = "[]") -> Data {
    Data("""
    {"content":{"id":"content","state":"\(state)","presentationIds":["presentation"]},"uploadTickets":\(tickets)}
    """.utf8)
}
private let readyContent = Data(#"{"id":"content","state":"ready","presentationIds":["presentation"]}"#.utf8)

@Test func preparingAndFailedRenditionsDecodeNullURLs() throws {
    for state in ["preparing", "failed"] {
        let p = try JSONDecoder().decode(GeneratedPresentationDTO.self, from: fixturePresentation(rendition: state, url: nil))
        #expect(p.renditions[0].url == nil)
        #expect(!p.renditions[0].isReady)
    }
}
@Test func generationWaitsForThePNGAfterContentIsReady() async throws {
    let api = ScriptedAPI([
        .init(path: "contents", method: "POST", data: created()),
        .init(path: "contents/content/confirm", method: "POST", data: readyContent),
        .init(path: "presentations/presentation", method: "GET", data: fixturePresentation(state: "preparing", rendition: "preparing", url: nil)),
        .init(path: "presentations/presentation", method: "GET", data: fixturePresentation())
    ])
    let client = TargetlessClient(transport: { try await api.request($0, $1, $2, $3) }, pause: {})
    let requestID = UUID()
    let result = try await client.generate(assets: [.text("Hello")], requestID: requestID)
    #expect(result.renditions[0].isReady)
    #expect(await api.finished())
    let keys = await api.keys
    #expect(keys == ["native-\(requestID.uuidString.lowercased())"])
    let body = try JSONSerialization.jsonObject(with: #require(await api.bodies.first)) as! [String: Any]
    #expect(body["displayId"] == nil)
    #expect((body["output"] as? [String: Any])?["viewport"] != nil)
}
@Test func aggregateReadyDoesNotHidePNGFailure() async throws {
    let api = ScriptedAPI([.init(path: "presentations/presentation", method: "GET", data: fixturePresentation(rendition: "failed", url: nil))])
    let client = TargetlessClient(transport: { try await api.request($0, $1, $2, $3) }, pause: {})
    await #expect(throws: VirtualDisplayError.self) { try await client.rendered(id: "presentation", width: 720, height: 752) }
    #expect(await api.finished())
}
@Test func missingSizeAppendsRenditionWithoutAnotherAIContent() async throws {
    let pending = Data(#"{"id":"render","format":"png","mediaType":"image/png","width":720,"height":752,"state":"preparing","url":null,"expiresAt":null,"updatedAt":"now"}"#.utf8)
    let api = ScriptedAPI([
        .init(path: "presentations/presentation", method: "GET", data: fixturePresentation(width: 360)),
        .init(path: "presentations/presentation/renditions", method: "POST", data: pending),
        .init(path: "presentations/presentation", method: "GET", data: fixturePresentation())
    ])
    let client = TargetlessClient(transport: { try await api.request($0, $1, $2, $3) }, pause: {})
    _ = try await client.rendered(id: "presentation", width: 720, height: 752)
    #expect(await api.finished())
}
private actor Transfers {
    var codes: [Int]
    var requests: [URLRequest] = []
    init(_ codes: [Int]) { self.codes = codes }
    func send(_ request: URLRequest) throws -> (Data, Int) {
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        requests.append(request)
        return (Data([1, 2, 3]), try #require(codes.isEmpty ? nil : codes.removeFirst()))
    }
}
@Test func expiredURLIsRenewedWithoutRegeneration() async throws {
    let initial = try JSONDecoder().decode(GeneratedPresentationDTO.self, from: fixturePresentation())
    let api = ScriptedAPI([.init(path: "presentations/presentation", method: "GET", data: fixturePresentation(url: "https://images.example/renewed.png"))])
    let transfers = Transfers([403, 200])
    let client = TargetlessClient(transport: { try await api.request($0, $1, $2, $3) }, transfer: { try await transfers.send($0) }, pause: {})
    let (_, data) = try await client.download(initial, width: 720, height: 752)
    #expect(data == Data([1, 2, 3]))
    #expect(await transfers.requests.last?.url?.path == "/renewed.png")
    #expect(await api.finished())
}
@Test func hardcodeUploadsBeforeConfirmationAndOmitsAccountHeaders() async throws {
    let tickets = #"[{"assetIndex":0,"url":"https://uploads.example/","fields":{"key":"frame","policy":"signed"}}]"#
    let api = ScriptedAPI([
        .init(path: "contents", method: "POST", data: created(tickets: tickets)),
        .init(path: "contents/content/confirm", method: "POST", data: readyContent),
        .init(path: "presentations/presentation", method: "GET", data: fixturePresentation())
    ])
    let transfers = Transfers([204])
    let client = TargetlessClient(transport: { try await api.request($0, $1, $2, $3) }, transfer: { try await transfers.send($0) }, pause: {})
    _ = try await client.generate(assets: [.binary(filename: "frame.png", contentType: "image/png", data: Data([4]))], mode: "hardcode", requestID: UUID())
    #expect(await transfers.requests.count == 1)
    #expect(await api.finished())
}
@Test func cancelledGenerationDoesNotSendANewRequest() async {
    let client = TargetlessClient(transport: { _, _, _, _ in Issue.record("Unexpected request after cancellation"); throw CancellationError() })
    let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await client.generate(assets: [.text("hi")], requestID: UUID()) }
    await #expect(throws: CancellationError.self) { try await task.value }
}
