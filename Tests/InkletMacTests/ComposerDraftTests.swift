import Foundation
import InkletPresentationKit
import Testing
@testable import InkletMac

// What a draft sends. A link on its own is a whole draft: it used to reach a
// Virtual Display as nothing at all, because only the one picture was passed
// on, and the generator refused an empty Content.

@Test func aLinkOnItsOwnIsAWholeDraft() {
    let assets = AppModel.draftAssets(text: "  \n", attachments: [.link("https://example.com/a")])
    #expect(assets.count == 1)
    guard case .link(let url)? = assets.first else {
        Issue.record("expected the link, got \(assets)")
        return
    }
    #expect(url == "https://example.com/a")
}

@Test func theNoteComesFirstThenEveryAttachmentInOrder() {
    let png = PresentationAsset.binary(filename: "a.png", contentType: "image/png", data: Data([1]))
    let assets = AppModel.draftAssets(text: " Read this ", attachments: [.link("https://example.com"), png])
    #expect(assets.count == 3)
    if case .text(let body) = assets[0] { #expect(body == "Read this") } else { Issue.record("note first") }
    if case .link = assets[1] {} else { Issue.record("then the link") }
    #expect(assets[2].isImage)
}

// The composer only adds links the backend takes: http or https with a real
// host. Anything else was refused after upload as `invalid_asset`.

@Test func webLinksPassAndBareDomainsReadAsHTTPS() {
    #expect(AttachmentRules.link(from: "https://example.com/a?b=c") == "https://example.com/a?b=c")
    #expect(AttachmentRules.link(from: "http://news.ycombinator.com") == "http://news.ycombinator.com")
    #expect(AttachmentRules.link(from: "  example.com/page  ") == "https://example.com/page")
    #expect(AttachmentRules.link(from: "sub.example.co.uk") == "https://sub.example.co.uk")
}

@Test func whatTheBackendWouldRefuseIsNotALink() {
    for raw in ["", "   ", "mailto:a@example.com", "ftp://example.com", "localhost:3000",
                "https://localhost", "not a link", "example", "https://.example.com", "file:///tmp/a"] {
        #expect(AttachmentRules.link(from: raw) == nil, "\(raw)")
    }
}
