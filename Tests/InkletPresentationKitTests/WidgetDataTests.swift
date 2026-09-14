import Foundation
import InkletPresentationKit
import Testing

private func temporaryStore() -> (URL, WidgetDataStore) {
    let root = FileManager.default.temporaryDirectory.appending(path: "inklet-widgets-test-\(UUID())")
    return (root, WidgetDataStore(rootURL: root))
}

@Test func widgetDataSurvivesHostRelaunchButNotAccountSwitch() throws {
    let (root, store) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try store.activate(accountID: "alice")
    let activity = ActivitySnapshot(counts: [.now: 3])
    try store.storeActivity(activity, for: session)

    let relaunched = WidgetDataStore(rootURL: root)
    #expect(try relaunched.activate(accountID: "alice") == session)
    #expect(try relaunched.activity()?.counts == activity.counts)

    let other = try relaunched.activate(accountID: "bob")
    #expect(other != session)
    #expect(try relaunched.activity() == nil)
    #expect(throws: WidgetDataError.self) { try store.storeActivity(activity, for: session) }
    #expect(try relaunched.activity() == nil)
}

@Test func signOutHidesTheDisplayAndRejectsLateGeneration() throws {
    let (root, store) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try store.activate(accountID: "alice")
    let presentation = try JSONDecoder().decode(GeneratedPresentationDTO.self, from: Data("""
        {"id":"one","displayId":null,"contentIds":["content"],"mode":"auto","state":"ready",
         "renditions":[],"createdAt":"2026-09-05T00:00:00Z","updatedAt":"2026-09-05T00:00:00Z"}
        """.utf8))
    let snapshot = CachedPresentationSnapshot(metadata: .init(presentation: presentation, imageFilename: nil),
                                               imageData: Data([1, 2, 3]))
    try store.storePresentation(snapshot, for: session)
    #expect(try store.presentation()?.imageData == Data([1, 2, 3]))
    try store.signOut()
    #expect(try store.presentation() == nil)
    #expect(try store.session()?.isSignedIn == false)
    #expect(throws: WidgetDataError.self) { try store.storePresentation(snapshot, for: session) }
    let newSession = try store.activate(accountID: "alice")
    #expect(newSession != session)
    #expect(try store.presentation() == nil)
}

@Test func displayReplacementKeepsMetadataAndPixelsTogether() throws {
    let (root, store) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try store.activate(accountID: "alice")
    for number in 1...3 {
        let presentation = try JSONDecoder().decode(GeneratedPresentationDTO.self, from: Data("""
            {"id":"\(number)","contentIds":[],"mode":"auto","state":"ready",
             "renditions":[],"createdAt":"now","updatedAt":"now"}
            """.utf8))
        let snapshot = CachedPresentationSnapshot(metadata: .init(presentation: presentation, imageFilename: nil),
                                                   imageData: Data([UInt8(number)]))
        try store.storePresentation(snapshot, for: session)
        let read = try #require(try store.presentation())
        #expect(read.metadata.presentation.id == String(number))
        #expect(read.imageData == Data([UInt8(number)]))
    }
}

@Test func activityUsesLocalCalendarDaysAcrossDaylightSaving() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
    let formatter = ISO8601DateFormatter()
    let before = try #require(formatter.date(from: "2026-03-08T07:30:00Z"))
    let after = try #require(formatter.date(from: "2026-03-08T09:30:00Z"))
    let snapshot = ActivitySnapshot(counts: [before: 2, after: 3], calendar: calendar)
    #expect(snapshot.counts == ["2026-03-08": 5])
    let decoded = snapshot.datedCounts(calendar: calendar)
    let columns = ActivityGrid.columns(counts: decoded, date: after, calendar: calendar)
    #expect(columns.count == 26)
    #expect(columns.last?.first == 5)
    #expect(columns.last?.dropFirst().allSatisfy { $0 == nil } == true)
    #expect(ActivityGrid.total(counts: decoded, date: after, calendar: calendar) == 5)
}

@Test func heatmapSeasonExcludesFutureAndOlderActivity() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = Date(timeIntervalSince1970: 1_788_566_400)
    let today = calendar.startOfDay(for: date)
    let old = try #require(calendar.date(byAdding: .day, value: -200, to: today))
    let future = try #require(calendar.date(byAdding: .day, value: 1, to: today))
    let counts = [today: 2, old: 500, future: 200]
    #expect(ActivityGrid.total(counts: counts, date: date, calendar: calendar) == 2)
}

@Test func widgetLinksOnlyNavigateToKnownScreens() throws {
    for destination in WidgetDestination.allCases {
        #expect(WidgetDestination(url: destination.url) == destination)
    }
    #expect(WidgetDestination(url: URL(string: "inklet://presentations/latest")!) == .display)
    for raw in ["https://send", "inklet-mac://auth", "inklet-mac://send/private",
                "inklet-mac://send?text=unrequested", "inklet-mac://user:password@send"] {
        #expect(WidgetDestination(url: URL(string: raw)!) == nil)
    }
}
