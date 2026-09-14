import Foundation
import ImageIO
import Testing
@testable import InkletPresentationKit

private func display(_ id: UUID = UUID(), revision: Int64 = 0) -> VirtualDisplay {
    VirtualDisplay(id: id, name: "Desk", width: 360, height: 376, revision: revision, frameId: nil, updatedAt: "2026-09-11T00:00:00Z")
}
@Test func virtualDisplaysAreIndependentAndDoNotFallbackAfterDeletion() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = VirtualDisplayStore(rootURL: root), first = display(), second = display()
    let session = try store.activate(accountID: "alice")
    try store.replace([.init(display: first), .init(display: second)], session: session)
    try store.save(.init(display: first, imageData: Data([1]), text: "One"), session: session)
    try store.save(.init(display: second, imageData: Data([2]), text: "Two"), session: session)
    #expect(try store.frame(first.id, session: session)?.text == "One")
    try store.remove(first.id, session: session)
    #expect(try store.frame(first.id, session: session) == nil)
    #expect(try store.frame(second.id, session: session)?.text == "Two")
    #expect(try !store.save(.init(display: first, imageData: Data([1]), text: "Late"), session: session))
}
@Test func virtualAccountSwitchRejectsLateFramesCatalogsAndDeletes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = VirtualDisplayStore(rootURL: root), item = display()
    let alice = try store.activate(accountID: "alice")
    try store.replace([.init(display: item)], session: alice)
    #expect(try VirtualDisplayStore(rootURL: root).activate(accountID: "alice") == alice)
    let bob = try store.activate(accountID: "bob")
    #expect(try !store.replace([.init(display: item)], session: alice))
    #expect(try !store.save(.init(display: item, imageData: Data([1]), text: "Private"), session: alice))
    #expect(try !store.remove(item.id, session: alice))
    #expect(try store.catalog()?.items.isEmpty == true)
    try store.signOut()
    #expect(try store.catalog() == nil)
    #expect(try !store.replace([.init(display: item)], session: bob))
    #expect(try store.activate(accountID: "bob") != bob)
}
@Test func delayedWidgetFetchCannotRollBackANewerPublishedFrame() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = VirtualDisplayStore(rootURL: root), id = UUID()
    let session = try store.activate(accountID: "alice")
    try store.replace([.init(display: display(id))], session: session)
    try store.save(.init(display: display(id, revision: 2), imageData: Data([2]), text: "New"), session: session)
    #expect(try !store.save(.init(display: display(id, revision: 1), imageData: Data([1]), text: "Old"), session: session))
    #expect(try store.frame(id, session: session)?.text == "New")
}
@Test func virtualDisplayLinksValidateIDsAndRejectCredentialsOrQueries() {
    let id = UUID()
    #expect(VirtualDisplayLinks.displayID(VirtualDisplayLinks.url(id: id)) == id)
    for url in ["https://display/\(id)", "inklet://user@display/\(id)", "inklet://display/\(id)?token=bad", "inklet://display/no-id", "inklet://display/\(id)/extra"] {
        #expect(VirtualDisplayLinks.displayID(URL(string: url)!) == nil)
    }
}
@Test func textRendererKeepsCanonicalSizeAndRejectsOverflow() throws {
    for text in ["Make room for what matters.", "慢慢来，比较快。\n给重要的事情留一点空间。", String(repeating: "字", count: 1000)] {
        let data = try VirtualDisplayRenderer.text(text)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 720 && image.height == 752)
        #expect(data.count < 2 * 1024 * 1024)
        let normalized = try VirtualDisplayRenderer.image(data)
        #expect(!normalized.isEmpty)
    }
    #expect(throws: VirtualDisplayError.self) { try VirtualDisplayRenderer.text(" ") }
    #expect(throws: VirtualDisplayError.self) { try VirtualDisplayRenderer.text(String(repeating: "a", count: 1001)) }
    #expect(throws: VirtualDisplayError.self) { try VirtualDisplayRenderer.text(String(repeating: "a\n", count: 200)) }
    #expect(throws: VirtualDisplayError.self) { try VirtualDisplayRenderer.image(Data([1, 2, 3])) }
}

@Test func fixedProfilesRejectOtherSizesPlatformsAndLegacyRecords() throws {
    for profile in VirtualDisplaySizeProfile.available {
        let item = VirtualDisplay(id: UUID(), name: "Desk", width: profile.width, height: profile.height,
                                  revision: 0, frameId: nil, updatedAt: "now", sizeProfile: profile.rawValue)
        for candidate in VirtualDisplaySizeProfile.allCases {
            #expect(item.isCompatible(with: candidate) == (profile == candidate))
        }
        let decoded = try JSONDecoder().decode(VirtualDisplay.self, from: JSONEncoder().encode(item))
        #expect(decoded.isCompatible(with: profile))
        let wrongDimensions = VirtualDisplay(id: UUID(), name: "Wrong", width: 1, height: 1,
                                             revision: 0, frameId: nil, updatedAt: "now", sizeProfile: profile.rawValue)
        #expect(!wrongDimensions.isCompatible(with: profile))
    }
    let original = display()
    #expect(original.profile == .legacy)
    #expect(!VirtualDisplaySizeProfile.available.contains { original.isCompatible(with: $0) })
}
@Test func fixedCanvasesRenderAtTheirOwnAspectRatio() throws {
    for profile in VirtualDisplaySizeProfile.available {
        let size = CGSize(width: profile.width * 2, height: profile.height * 2)
        let png = try VirtualDisplayRenderer.text("布局属于这块画布。 A canvas of its own.", size: size)
        for imageData in [png, try VirtualDisplayRenderer.image(png, size: size)] {
            let source = try #require(CGImageSourceCreateWithData(imageData as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == profile.width * 2)
            #expect(image.height == profile.height * 2)
        }
    }
}

@Test func frameWithoutProfileUsesOnlyMatchingCatalogCanvas() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = VirtualDisplayStore(rootURL: root)
    let session = try store.activate(accountID: "alice")
    let descriptor = VirtualDisplay(id: UUID(), name: "XL", width: 752, height: 360,
        revision: 2, frameId: nil, updatedAt: "now", sizeProfile: "macos_extra_large")
    try store.replace([.init(display: descriptor)], session: session)
    var omitted = descriptor
    omitted.sizeProfile = nil
    try store.save(.init(display: omitted, imageData: Data([1]), text: "test2"), session: session)
    let restored = try store.frame(descriptor.id, session: session)
    #expect(restored?.display.isCompatible(with: .macExtraLarge) == true)
    #expect(restored?.display.isCompatible(with: .ipadExtraLarge) == false)
    #expect(restored?.text == "test2")
    var explicitOther = descriptor
    explicitOther.sizeProfile = "ipados_extra_large"
    try store.save(.init(display: explicitOther, imageData: Data([2]), text: "other"), session: session)
    #expect(try store.frame(descriptor.id, session: session)?.display.isCompatible(with: .macExtraLarge) == false)
    let wrongSize = VirtualDisplay(id: descriptor.id, name: "XL", width: 360, height: 360,
        revision: 3, frameId: nil, updatedAt: "now")
    try store.save(.init(display: wrongSize, imageData: Data([3]), text: "wrong"), session: session)
    #expect(try store.frame(descriptor.id, session: session)?.display.sizeProfile == nil)
}
