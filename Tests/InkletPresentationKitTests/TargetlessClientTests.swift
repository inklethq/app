import Foundation
import Testing
@testable import InkletPresentationKit

private func fixturePresentation(state: String = "ready", rendition: String = "ready", width: Int = 720, url: String? = "https://images.example/frame.png") -> Data {
    let image: [String: Any] = ["id": "render", "format": "png", "mediaType": "image/png", "width": width, "height": 752,
        "state": rendition, "colorMode": "color", "url": url as Any? ?? NSNull(), "expiresAt": url == nil ? NSNull() : "2026-09-11T02:00:00Z",
        "failure": rendition == "failed" ? ["code": "render_failed", "message": "Render rejected", "retryable": false] : NSNull(), "updatedAt": "now"]
    return try! JSONSerialization.data(withJSONObject: ["id": "presentation", "displayId": NSNull(), "analysisId": "analysis",
        "contentIds": [["id": "content", "role": "input"]], "mode": "ai", "state": state, "title": "Hello",
        "renditions": [image], "createdAt": "now", "updatedAt": "now"])
}
private actor ScriptedAPI {
    struct Step: Sendable { let path: String; let method: String; let data: Data; let error: PresentationHTTPError?
        init(path: String, method: String, data: Data = Data(), error: PresentationHTTPError? = nil) { self.path = path; self.method = method; self.data = data; self.error = error }
    }
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
        if let error = step.error { throw error }
        return step.data
    }
    func finished() -> Bool { steps.isEmpty }
}
private func created(_ state: String = "ready", tickets: String = "[]") -> Data {
    Data("""
    {"content":{"id":"content","title":"Hello","state":"\(state)","assets":[],"createdAt":"now"},"uploadTickets":\(tickets)}
    """.utf8)
}
private func analysis(_ state: String, outcome: String? = "presentations", presentations: [String] = ["presentation"], failure: String? = nil) -> Data {
    let object: [String: Any] = ["id": "analysis", "mode": "ai", "trigger": "api", "state": state, "outcome": outcome as Any? ?? NSNull(),
        "noChangeReason": NSNull(), "contentIds": ["content"], "context": "submitted", "presentationIds": presentations,
        "failure": failure.map { ["code": "internal_error", "message": $0, "retryable": false] } as Any? ?? NSNull(), "createdAt": "now"]
    return try! JSONSerialization.data(withJSONObject: object)
}
private func events(_ state: String, items: [[String: Any]] = [], nextAfter: Int = 0) -> Data {
    try! JSONSerialization.data(withJSONObject: ["items": items, "nextAfter": nextAfter, "hasMore": false, "state": state])
}
private func activity(seq: Int, kind: String, state: String) -> [String: Any] {
    ["seq": seq, "at": "now", "attempt": 1, "source": "agent", "type": "agent.activity", "level": "info", "visibility": "public",
     "data": ["activityId": "a1", "kind": kind, "state": state]]
}

@Test func presentationDecodesContentRefsAndBareIDs() throws {
    let refs = try JSONDecoder().decode(GeneratedPresentationDTO.self, from: fixturePresentation())
    #expect(refs.contentIds == ["content"])
    #expect(refs.analysisId == "analysis")
    #expect(refs.title == "Hello")
    let legacy = Data(#"{"id":"p","contentIds":["c1","c2"],"mode":"auto","state":"ready","renditions":[],"createdAt":"now","updatedAt":"now"}"#.utf8)
    #expect(try JSONDecoder().decode(GeneratedPresentationDTO.self, from: legacy).contentIds == ["c1", "c2"])
}
@Test func preparingAndFailedRenditionsDecodeNullURLs() throws {
    for state in ["preparing", "failed"] {
        let p = try JSONDecoder().decode(GeneratedPresentationDTO.self, from: fixturePresentation(rendition: state, url: nil))
        #expect(p.renditions[0].url == nil)
        #expect(!p.renditions[0].isReady)
    }
}
@Test func generationUploadsAnalyzesFollowsEventsThenWaitsForThePNG() async throws {
    let api = ScriptedAPI([
        .init(path: "contents", method: "POST", data: created()),
        .init(path: "analyses", method: "POST", data: analysis("queued", outcome: nil, presentations: [])),
        .init(path: "analyses/analysis/events?after=0&limit=200", method: "GET",
              data: events("running", items: [activity(seq: 3, kind: "reading_notes", state: "active")], nextAfter: 3)),
        .init(path: "analyses/analysis/events?after=3&limit=200", method: "GET",
              data: events("completed", items: [activity(seq: 9, kind: "planning", state: "done")], nextAfter: 9)),
        .init(path: "analyses/analysis", method: "GET", data: analysis("completed")),
        .init(path: "presentations/presentation", method: "GET", data: fixturePresentation(state: "preparing", rendition: "preparing", url: nil)),
        .init(path: "presentations/presentation", method: "GET", data: fixturePresentation())
    ])
    let client = TargetlessClient(transport: { try await api.request($0, $1, $2, $3) }, pause: {})
    let requestID = UUID()
    let seen = Lines()
    let result = try await client.generate(assets: [.text("Hello world\nmore")], requestID: requestID) { event in
        seen.add(event.displayText)
    }
    #expect(result.renditions[0].isReady)
    #expect(await api.finished())
    let keys = await api.keys
    // One key covers the Content and its Analysis: the backend scopes keys per route.
    #expect(keys == ["native-\(requestID.uuidString.lowercased())", "native-\(requestID.uuidString.lowercased())"])
    let bodies = await api.bodies
    let first = try #require(bodies.first)
    let content = try JSONSerialization.jsonObject(with: first) as! [String: Any]
    #expect(content["mode"] == nil)
    #expect(content["title"] as? String == "Hello world")
    let second = try #require(bodies.dropFirst().first)
    let run = try JSONSerialization.jsonObject(with: second) as! [String: Any]
    #expect(run["mode"] as? String == "ai")
    #expect(run["context"] as? String == "submitted")
    #expect(run["contentIds"] as? [String] == ["content"])
    let output = try #require((run["target"] as? [String: Any])?["output"] as? [String: Any])
    #expect((output["viewport"] as? [String: Int])?["width"] == 720)
    #expect(seen.values == ["Reading your notes", "Submitted the plan"])
}
@Test func recentNotesActionSendsHistoryContextAndWindow() async throws {
    let api = ScriptedAPI([
        .init(path: "contents", method: "POST", data: created()),
        .init(path: "analyses", method: "POST", data: analysis("queued", outcome: nil, presentations: []))
    ])
    let client = TargetlessClient(transport: { try await api.request($0, $1, $2, $3) }, pause: {})
    let outcome = try await client.compose(assets: [.text("Hi")], action: .cardHistory, target: .display("display-1"), requestID: UUID())
    #expect(outcome.analysis?.id == "analysis")
    let last = try #require(await api.bodies.last)
    let run = try JSONSerialization.jsonObject(with: last) as! [String: Any]
    #expect(run["context"] as? String == "history")
    #expect((run["scope"] as? [String: String])?["since"] == "7d")
    #expect((run["target"] as? [String: String])?["displayId"] == "display-1")
}
@Test func uploadOnlyNeverCreatesAnAnalysis() async throws {
    let api = ScriptedAPI([.init(path: "contents", method: "POST", data: created())])
    let client = TargetlessClient(transport: { try await api.request($0, $1, $2, $3) }, pause: {})
    let outcome = try await client.compose(assets: [.text("Keep this")], action: .upload, target: .agent, requestID: UUID())
    #expect(outcome.analysis == nil)
    #expect(outcome.content.id == "content")
    #expect(await api.finished())
}
@Test func noCompatibleDisplayIsARefusalNotAnError() async throws {
    let api = ScriptedAPI([
        .init(path: "contents", method: "POST", data: created()),
        .init(path: "analyses", method: "POST", error: PresentationHTTPError(status: 422, message: "No display", code: "no_compatible_display"))
    ])
    let client = TargetlessClient(transport: { try await api.request($0, $1, $2, $3) }, pause: {})
    let outcome = try await client.compose(assets: [.text("Hi")], action: .card, target: .agent, requestID: UUID())
    #expect(outcome.refusal == "no_compatible_display")
    #expect(outcome.analysis == nil)
}
@Test func missingAssetsAreReuploadedAndTheSameAnalysisRetried() async throws {
    let tickets = #"[{"assetIndex":0,"url":"https://uploads.example/","fields":{"key":"frame","policy":"signed"}}]"#
    let details: [String: JSONValue] = ["failedAssets": .array([.object(["contentId": .string("content"), "assetIndex": .number(0)])])]
    let api = ScriptedAPI([
        .init(path: "contents", method: "POST", data: created("pending", tickets: tickets)),
        .init(path: "analyses", method: "POST", error: PresentationHTTPError(status: 409, message: "missing", code: "asset_not_uploaded", details: details)),
        .init(path: "contents/content/upload-tickets", method: "POST", data: created("pending", tickets: tickets)),
        .init(path: "analyses", method: "POST", data: analysis("queued", outcome: nil, presentations: []))
    ])
    let transfers = Transfers([204, 204])
    let client = TargetlessClient(transport: { try await api.request($0, $1, $2, $3) }, transfer: { try await transfers.send($0) }, pause: {})
    let requestID = UUID()
    let outcome = try await client.compose(assets: [.binary(filename: "frame.png", contentType: "image/png", data: Data([4]))],
                                           action: .asIs, target: .display("d"), requestID: requestID)
    #expect(outcome.analysis?.id == "analysis")
    #expect(await transfers.requests.count == 2)
    #expect(await api.keys == ["native-\(requestID.uuidString.lowercased())", "native-\(requestID.uuidString.lowercased())", "native-\(requestID.uuidString.lowercased())"])
    #expect(await api.finished())
}
@Test func failedAnalysisSurfacesTheBackendMessage() async throws {
    let api = ScriptedAPI([
        .init(path: "contents", method: "POST", data: created()),
        .init(path: "analyses", method: "POST", data: analysis("queued", outcome: nil, presentations: [])),
        .init(path: "analyses/analysis/events?after=0&limit=200", method: "GET", data: events("failed")),
        .init(path: "analyses/analysis", method: "GET", data: analysis("failed", outcome: nil, presentations: [], failure: "The model timed out"))
    ])
    let client = TargetlessClient(transport: { try await api.request($0, $1, $2, $3) }, pause: {})
    await #expect(throws: VirtualDisplayError.self) { try await client.generate(assets: [.text("Hi")], requestID: UUID()) }
    #expect(await api.finished())
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
/// Synchronous so the sink's order of arrival is what the test reads.
private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] { lock.withLock { stored } }
    func add(_ line: String) { lock.withLock { stored.append(line) } }
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
@Test func hardcodeUploadsBeforeAnalyzingAndOmitsAccountHeaders() async throws {
    let tickets = #"[{"assetIndex":0,"url":"https://uploads.example/","fields":{"key":"frame","policy":"signed"}}]"#
    let api = ScriptedAPI([
        .init(path: "contents", method: "POST", data: created("pending", tickets: tickets)),
        .init(path: "analyses", method: "POST", data: analysis("queued", outcome: nil, presentations: [])),
        .init(path: "analyses/analysis/events?after=0&limit=200", method: "GET", data: events("completed")),
        .init(path: "analyses/analysis", method: "GET", data: analysis("completed")),
        .init(path: "presentations/presentation", method: "GET", data: fixturePresentation())
    ])
    let transfers = Transfers([204])
    let client = TargetlessClient(transport: { try await api.request($0, $1, $2, $3) }, transfer: { try await transfers.send($0) }, pause: {})
    _ = try await client.generate(assets: [.binary(filename: "frame.png", contentType: "image/png", data: Data([4]))], mode: "hardcode", requestID: UUID())
    #expect(await transfers.requests.count == 1)
    let last = try #require(await api.bodies.last)
    let run = try JSONSerialization.jsonObject(with: last) as! [String: Any]
    #expect(run["mode"] as? String == "direct")
    #expect(await api.finished())
}
@Test func cancelledGenerationDoesNotSendANewRequest() async {
    let client = TargetlessClient(transport: { _, _, _, _ in Issue.record("Unexpected request after cancellation"); throw CancellationError() })
    let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await client.generate(assets: [.text("hi")], requestID: UUID()) }
    await #expect(throws: CancellationError.self) { try await task.value }
}
