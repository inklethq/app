import Foundation
import Testing
import InkletPresentationKit
@testable import InkletMac

// The copy and timeline derivation the History page runs on. Decoded from
// JSON rather than built by hand: the DTOs have no public initialisers, and
// the wire shape is what the page actually gets.

private func analysis(_ overrides: [String: Any] = [:]) -> AnalysisDTO {
    var object: [String: Any] = [
        "id": "a1", "mode": "ai", "trigger": "api", "state": "completed", "contentIds": ["c1"],
        "context": "submitted", "presentationIds": ["p1"], "createdAt": "2026-09-20T10:42:03Z",
    ]
    object.merge(overrides) { _, override in override }
    let data = try! JSONSerialization.data(withJSONObject: object)
    return try! JSONDecoder().decode(AnalysisDTO.self, from: data)
}

private func events(_ json: String) -> [AnalysisEventDTO] {
    try! JSONDecoder().decode([AnalysisEventDTO].self, from: Data(json.utf8))
}

@Test func historyTitlePrefersWhatTheUserTyped() {
    #expect(analysis(["title": "  Groceries   list "]).historyTitle == "Groceries list")
    #expect(analysis(["intent": "make a reminder"]).historyTitle == "make a reminder")
    #expect(analysis(["mode": "direct"]).historyTitle == "Picture sent straight to a display")
    #expect(analysis(["trigger": "scheduled"]).historyTitle == "Daily summary")
    #expect(analysis(["context": "history"]).historyTitle == "Summary of your recent notes")
    #expect(analysis().historyTitle == "Card from what you sent")
}

@Test func resultLineSaysWhatCameOfIt() {
    #expect(analysis().resultLine() == "1 card")
    #expect(analysis(["presentationIds": ["p1", "p2"]]).resultLine() == "2 cards")
    // A no_change completion is a normal result and its reason is the row.
    #expect(analysis(["outcome": "no_change", "noChangeReason": "Nothing new since yesterday"]).resultLine()
            == "Nothing new since yesterday")
    #expect(!analysis(["outcome": "no_change"]).isFailure)
    #expect(analysis(["state": "failed", "failure": ["code": "no_ai_quota", "message": "额度不足", "retryable": false]]).resultLine()
            == "This run needed an AI summary you no longer have allowance for.")
    #expect(analysis(["state": "failed"]).resultLine() == "This run could not be finished.")
    #expect(analysis(["state": "queued", "context": "history"]).resultLine().hasPrefix("Queued — these run one at a time"))
}

@Test func theEventsMoveAQueuedRunForwardButNeverBack() {
    let queued = analysis(["state": "queued"])
    let leased = events(#"[{"seq":3,"at":"2026-09-20T10:42:05Z","type":"analysis.leased","attempt":1}]"#)
    #expect(queued.liveState(events: leased) == "running")
    #expect(queued.resultLine(events: leased).hasPrefix("Working"))
    let agentOnly = events(#"[{"seq":9,"at":"2026-09-20T10:42:09Z","type":"agent.activity","attempt":1,"source":"agent","data":{"activityId":"x","kind":"reading_notes","state":"active"}}]"#)
    #expect(queued.liveState(events: agentOnly) == "running")
    // Terminal on the Analysis wins outright.
    #expect(analysis().liveState(events: leased) == "completed")
}

@Test func scopeLabelsReadAsAWindow() {
    #expect(AnalysisCopy.scopeLabel("7d") == "last 7 days")
    #expect(AnalysisCopy.scopeLabel("1h") == "last 1 hour")
    #expect(AnalysisCopy.scopeLabel("weird") == "weird")
}

@Test func anActivityIsOneRowThatChangesInPlace() {
    let stream = events("""
    [{"seq":1,"at":"2026-09-20T10:42:00Z","type":"analysis.created","attempt":1,"level":"info","summary":"Created"},
     {"seq":2,"at":"2026-09-20T10:42:01Z","type":"agent.activity","attempt":1,"source":"agent","level":"info",
      "data":{"activityId":"read","kind":"reading_notes","state":"active","steps":1,"stats":{"notesRead":1}}},
     {"seq":3,"at":"2026-09-20T10:42:02Z","type":"agent.activity","attempt":1,"source":"agent","level":"info",
      "data":{"activityId":"look","kind":"choosing_layout","state":"active","steps":1,"stats":{"layoutsSeen":2}}},
     {"seq":4,"at":"2026-09-20T10:42:03Z","type":"agent.activity","attempt":1,"source":"agent","level":"info",
      "data":{"activityId":"read","kind":"reading_notes","state":"done","steps":3,"stats":{"notesRead":3}}},
     {"seq":4,"at":"2026-09-20T10:42:03Z","type":"agent.activity","attempt":1,"source":"agent","level":"info",
      "data":{"activityId":"read","kind":"reading_notes","state":"done","steps":3,"stats":{"notesRead":3}}}]
    """)
    let attempts = AnalysisTimeline.build(stream)
    #expect(attempts.count == 1)
    let rows = attempts[0].rows
    #expect(rows.map(\.text) == ["Analysis created", "Read 3 notes", "Looking at layouts (2 so far)"])
    #expect(rows[1].id == "activity-1-read")
    #expect(!rows[1].live)
    #expect(rows[2].live)
    #expect(rows[2].icon == .layout)
}

@Test func retriesAreGroupedByAttemptAndWearTheWarnColour() {
    let stream = events("""
    [{"seq":1,"at":"2026-09-20T10:42:00Z","type":"analysis.leased","attempt":1,"level":"info","summary":"Leased"},
     {"seq":2,"at":"2026-09-20T10:43:00Z","type":"analysis.lease_expired","attempt":1,"level":"warn","summary":"Lease expired"},
     {"seq":3,"at":"2026-09-20T10:44:00Z","type":"analysis.leased","attempt":2,"level":"info","summary":"Leased"},
     {"seq":4,"at":"2026-09-20T10:44:10Z","type":"agent.activity","attempt":2,"source":"agent","level":"info",
      "data":{"activityId":"retry","kind":"retrying","state":"active","steps":0,"stats":{}}},
     {"seq":5,"at":"2026-09-20T10:44:20Z","type":"plan.rejected","attempt":2,"level":"info",
      "data":{"reason":"layout_mismatch","problems":2}}]
    """)
    let attempts = AnalysisTimeline.build(stream)
    #expect(attempts.map(\.attempt) == [1, 2])
    #expect(attempts[0].rows[1].transient)
    #expect(attempts[0].rows[1].tone == .warn)
    #expect(attempts[1].rows[1].text == "Trying another layout")
    #expect(attempts[1].rows[1].tone == .warn)
    #expect(attempts[1].rows[2].text == "The first layout didn't fit — trying another (2 problems)")
}

@Test func deliveryRowsNameThePanelAndDropTheLogSummary() {
    let stream = events("""
    [{"seq":7,"at":"2026-09-20T10:45:00Z","type":"delivery.published","attempt":1,"level":"info",
      "summary":"Sent result 01a0 to display fb73","data":{"displayId":"fb73","placement":"queue"}},
     {"seq":8,"at":"2026-09-20T10:46:00Z","type":"analysis.failed","attempt":1,"level":"error",
      "summary":"Failed","data":{"code":"no_ai_quota","stage":"plan"}},
     {"seq":9,"at":"2026-09-20T10:47:00Z","type":"something.new","attempt":1,"level":"info","summary":"A thing happened"}]
    """)
    let rows = AnalysisTimeline.build(stream, displayNames: ["fb73": "Kitchen"])[0].rows
    #expect(rows[0].text == "Sent to Kitchen — it will show it when it next syncs")
    #expect(rows[0].note == nil)
    #expect(rows[0].facts == [TimelineFact(label: "Placement", value: "queued behind what is showing")])
    #expect(rows[1].tone == .error)
    #expect(rows[1].icon == .alert)
    #expect(rows[1].facts.first == TimelineFact(label: "Code", value: "no_ai_quota", tone: .error))
    // An unknown type renders as an ordinary row headed by its summary.
    #expect(rows[2].text == "A thing happened")
    #expect(rows[2].note == nil)
}

@Test func activityCopyPutsFailedStepsInThePastTense() {
    func text(_ data: String) -> String {
        let event = events(#"[{"seq":1,"at":"2026-09-20T10:42:00Z","type":"agent.activity","attempt":1,"data":\#(data)}]"#)[0]
        return AnalysisTimeline.activityText(event.data!)
    }
    #expect(text(#"{"activityId":"a","kind":"checking_display","state":"failed","steps":1,"stats":{"failedSteps":1}}"#)
            == "Checked the display. 1 step failed")
    #expect(text(#"{"activityId":"a","kind":"checking_display","state":"failed","steps":1,"stats":{}}"#)
            == "Checking the display — failed")
    #expect(text(#"{"activityId":"a","kind":"choosing_layout","state":"done","steps":4,"stats":{"layoutsSeen":3,"chosen":"Small Panel Card"}}"#)
            == "Looked at 3 layouts, chose Small Panel Card")
    #expect(text(#"{"activityId":"a","kind":"other","state":"active","steps":2,"stats":{"deniedSteps":1}}"#)
            == "Working through 2 steps. 1 step blocked")
}
