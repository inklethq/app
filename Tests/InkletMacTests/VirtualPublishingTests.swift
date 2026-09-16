import Foundation
import Testing
import ImageIO
@testable import InkletMac
@testable import InkletPresentationKit

private actor PublishingServer {
    let id: UUID
    let image: Data
    let profile: VirtualDisplaySizeProfile
    var generations = 0
    var publishes = 0
    var rejectFirst = true
    init(id: UUID, image: Data, profile: VirtualDisplaySizeProfile = .legacy) { self.id = id; self.image = image; self.profile = profile }
    func request(_ path: String, _ method: String, _ body: Data?, _ headers: [String: String]) throws -> Data {
        if path == "api/app/v1/contents" {
            let body = try #require(body)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["mode"] == nil)
            #expect(json["output"] == nil)
            return Data(#"{"content":{"id":"content","state":"ready","assets":[],"createdAt":"now"},"uploadTickets":[]}"#.utf8)
        }
        if path == "api/app/v1/analyses" {
            generations += 1
            let body = try #require(body)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let target = try #require(json["target"] as? [String: Any])
            let output = try #require(target["output"] as? [String: Any])
            let viewport = try #require(output["viewport"] as? [String: Int])
            #expect(viewport["width"] == profile.width * 2)
            #expect(viewport["height"] == profile.height * 2)
            return Data(#"{"id":"analysis","mode":"ai","state":"queued","outcome":null,"contentIds":["content"],"context":"submitted","presentationIds":[],"createdAt":"now"}"#.utf8)
        }
        if path.hasPrefix("api/app/v1/analyses/analysis/events") {
            return Data(#"{"items":[],"nextAfter":0,"hasMore":false,"state":"completed"}"#.utf8)
        }
        if path == "api/app/v1/analyses/analysis" {
            return Data(#"{"id":"analysis","mode":"ai","state":"completed","outcome":"presentations","contentIds":["content"],"context":"submitted","presentationIds":["presentation"],"createdAt":"now"}"#.utf8)
        }
        if path == "api/app/v1/presentations/presentation" {
            let template = Data(##"{"id":"presentation","analysisId":"analysis","contentIds":[{"id":"content","role":"input"}],"mode":"ai","state":"ready","createdAt":"now","updatedAt":"now","scene":{"mediaType":"application/vnd.inklet.scene+json;version=1","version":1,"data":{"version":1,"viewport":{"width":720,"height":752},"background":"#ffffff","elements":[]}},"renditions":[{"id":"rendition","format":"png","mediaType":"image/png","width":720,"height":752,"state":"ready","url":"https://images.example/frame.png","expiresAt":"later","updatedAt":"now"}]}"##.utf8)
            var json = try #require(JSONSerialization.jsonObject(with: template) as? [String: Any])
            var renditions = try #require(json["renditions"] as? [[String: Any]])
            renditions[0]["width"] = profile.width * 2
            renditions[0]["height"] = profile.height * 2
            json["renditions"] = renditions
            return try JSONSerialization.data(withJSONObject: json)
        }
        #expect(path == "api/virtual-displays/\(id)/frame")
        #expect(method == "PUT")
        publishes += 1
        if rejectFirst { rejectFirst = false; throw PresentationHTTPError(status: 409, message: "Refresh before publishing again.") }
        return try JSONSerialization.data(withJSONObject: ["display": ["id": id.uuidString, "name": "Desk", "width": profile.width, "height": profile.height, "sizeProfile": profile.rawValue,
            "revision": 3, "updatedAt": "now"], "text": "Hello", "imageData": image.base64EncodedString()])
    }
}
@MainActor
@Test func failedPublishKeepsOldFrameAndRetryReusesTheGeneratedPresentation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = VirtualDisplayStore(rootURL: root)
    let session = try store.activate(accountID: "alice")
    let id = UUID(), requestID = UUID(), frameID = UUID()
    let display = VirtualDisplay(id: id, name: "Desk", width: 360, height: 376, revision: 1, frameId: nil, updatedAt: "now")
    let image = try VirtualDisplayRenderer.text("Hello")
    try store.replace([.init(display: display)], session: session)
    try store.save(.init(display: display, imageData: image, text: "Old"), session: session)
    let server = PublishingServer(id: id, image: image)
    let controller = VirtualDisplayController(store: store, transfer: { _ in (image, 200) }, transport: { try await server.request($0, $1, $2, $3) })
    controller.activate(accountID: "alice")
    let failed = await controller.generateAndPublish(id: id, requestID: requestID, frameID: frameID, baseRevision: 1,
                                                     assets: [.text("Hello")], mode: "auto", text: "Hello")
    #expect(!failed)
    #expect(try store.frame(id, session: session)?.text == "Old")
    let retried = await controller.generateAndPublish(id: id, requestID: requestID, frameID: frameID, baseRevision: 2,
                                                      assets: [.text("Hello")], mode: "auto", text: "Hello")
    #expect(retried)
    #expect(await server.generations == 1)
    #expect(await server.publishes == 2)
    #expect(try store.frame(id, session: session)?.presentation?.scene != nil)
    #expect(controller.displays.first?.revision == 3)
}
@MainActor
@Test func signOutDuringDownloadPreventsCloudPublishAndCacheResurrection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = VirtualDisplayStore(rootURL: root), id = UUID()
    let session = try store.activate(accountID: "alice")
    let display = VirtualDisplay(id: id, name: "Desk", width: 360, height: 376, revision: 0, frameId: nil, updatedAt: "now")
    try store.replace([.init(display: display)], session: session)
    let image = try VirtualDisplayRenderer.text("Private")
    let server = PublishingServer(id: id, image: image)
    let controller = VirtualDisplayController(store: store, transfer: { _ in try store.signOut(); return (image, 200) },
                                              transport: { try await server.request($0, $1, $2, $3) })
    controller.activate(accountID: "alice")
    let result = await controller.generateAndPublish(id: id, requestID: UUID(), frameID: UUID(), baseRevision: 0,
                                                     assets: [.text("Private")], mode: "auto", text: "Private")
    #expect(!result)
    #expect(await server.publishes == 0)
    #expect(try store.catalog() == nil)
}

@MainActor
@Test func selectedSizeReachesInitialAIGenerationAndPublishedPNG() async throws {
    for profile in [VirtualDisplaySizeProfile.macLarge, .macExtraLarge] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VirtualDisplayStore(rootURL: root), id = UUID()
        let session = try store.activate(accountID: "alice")
        let display = VirtualDisplay(id: id, name: "Sized", width: profile.width, height: profile.height,
                                     revision: 0, frameId: nil, updatedAt: "now", sizeProfile: profile.rawValue)
        try store.replace([.init(display: display)], session: session)
        let image = try VirtualDisplayRenderer.text("A deliberate layout", size: display.canvasSize)
        let server = PublishingServer(id: id, image: image, profile: profile)
        let controller = VirtualDisplayController(store: store, transfer: { _ in (image, 200) },
                                                  transport: { try await server.request($0, $1, $2, $3) })
        controller.activate(accountID: "alice")
        let request = UUID()
        _ = await controller.generateAndPublish(id: id, requestID: request, frameID: UUID(), baseRevision: 0,
                                               assets: [.text("A deliberate layout")], mode: "auto", text: "A deliberate layout")
        let result = await controller.generateAndPublish(id: id, requestID: request, frameID: UUID(), baseRevision: 2,
                                                        assets: [.text("A deliberate layout")], mode: "auto", text: "A deliberate layout")
        #expect(result)
        let frame = try #require(try store.frame(id, session: session))
        let data = try #require(frame.imageData)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let output = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(output.width == profile.width * 2 && output.height == profile.height * 2)
        #expect(frame.display.isCompatible(with: profile))
        #expect(await server.generations == 1)
    }
}
