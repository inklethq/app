import Foundation
import Testing
@testable import InkletPresentationKit

// One API host for the app and the widget, overridable per build through the
// Info.plist; anything but a plain https URL falls back to the default.

@Test func withoutAnOverrideTheDefaultHostIsUsed() {
    #expect(InkletServer.defaultAPIBase.absoluteString == "https://dev.iminklet.com")
    // A test process has no InkletAPIBaseURL key.
    #expect(InkletServer.apiBase == InkletServer.defaultAPIBase)
    for raw in [nil, "", "   "] as [String?] {
        #expect(InkletServer.apiBase(from: raw) == InkletServer.defaultAPIBase)
    }
}

@Test func anHTTPSOverrideIsTakenAndJoinsPathsTheSameWay() {
    #expect(InkletServer.apiBase(from: "https://staging.example.com/").absoluteString == "https://staging.example.com")
    let prefixed = InkletServer.apiBase(from: "https://example.com/inklet")
    #expect(prefixed.appending(path: "api/virtual-display-widget/abc").absoluteString
            == "https://example.com/inklet/api/virtual-display-widget/abc")
    #expect(URL(string: prefixed.absoluteString + "/" + "api/devices")?.absoluteString == "https://example.com/inklet/api/devices")
}

@Test func anythingButPlainHTTPSFallsBack() {
    for raw in ["http://staging.example.com", "https://user:secret@example.com", "https://example.com?x=1",
                "https://example.com#top", "staging.example.com", "not a url", "https://"] {
        #expect(InkletServer.apiBase(from: raw) == InkletServer.defaultAPIBase, "\(raw)")
    }
}
