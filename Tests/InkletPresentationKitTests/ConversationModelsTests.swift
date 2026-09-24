import Foundation
import Testing
@testable import InkletPresentationKit

// The Ask inklet wire shapes (CONVERSATION_CONTRACT §4.4) and the status lines
// the chat kernel's activities turn into.

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

@Test func assistantMessageDecodesWithCitationsAndActions() throws {
    let message = try decode(ConversationMessageDTO.self, """
    {"id":"m1","conversationId":"cv1","role":"assistant","state":"completed",
     "text":"Next Tuesday at three.","analysisId":"an1",
     "citations":[{"contentId":"c1","title":"Dentist"}],
     "actions":[{"kind":"card_created","analysisId":"an2","displayId":"d1"},{"kind":"display_switched","displayId":"d1","presentationId":"p1"}],
     "failure":null,"createdAt":"2026-09-24T01:00:01Z","completedAt":"2026-09-24T01:00:09Z"}
    """)
    #expect(message.isAssistant)
    #expect(!message.isOpen)
    #expect(message.citations?.first?.title == "Dentist")
    #expect(message.actions?.count == 2)
    #expect(message.actions?[0].displayText.hasPrefix("Started a card") == true)
    #expect(message.actions?[1].displayText.hasPrefix("Put an earlier picture") == true)
}

@Test func queuedReplyIsOpenAndAUserMessageIsNot() throws {
    let reply = try decode(ConversationMessageDTO.self, """
    {"id":"m2","conversationId":"cv1","role":"assistant","state":"queued","text":"","analysisId":"an1",
     "citations":[],"actions":[],"failure":null,"createdAt":"2026-09-24T01:00:01Z","completedAt":null}
    """)
    #expect(reply.isOpen)
    let user = try decode(ConversationMessageDTO.self, """
    {"id":"m0","conversationId":"cv1","role":"user","state":"completed","text":"When?","analysisId":null,
     "citations":[],"actions":[],"failure":null,"createdAt":"2026-09-24T01:00:00Z","completedAt":"2026-09-24T01:00:00Z"}
    """)
    #expect(!user.isAssistant)
    #expect(!user.isOpen)
}

@Test func sendResultCarriesTheReplyHandle() throws {
    let sent = try decode(SendMessageResultDTO.self, """
    {"message":{"id":"m0","conversationId":"cv1","role":"user","state":"completed","text":"When?","analysisId":null,
      "citations":[],"actions":[],"failure":null,"createdAt":"2026-09-24T01:00:00Z","completedAt":"2026-09-24T01:00:00Z"},
     "reply":{"id":"m1","state":"queued","analysisId":"an1"}}
    """)
    #expect(sent.reply == ReplyHandleDTO(id: "m1", state: "queued", analysisId: "an1"))
}

@Test func chatActivitiesHaveStatusLines() throws {
    let searching = try decode(AnalysisEventDTO.self, """
    {"seq":2,"at":"now","type":"agent.activity","data":{"activityId":"c1","kind":"searching_notes","state":"done","steps":1,"stats":{"matches":3}}}
    """)
    #expect(searching.displayText == "Found 3 notes")
    let reading = try decode(AnalysisEventDTO.self, """
    {"seq":3,"at":"now","type":"agent.activity","data":{"activityId":"c2","kind":"reading_note","state":"active","steps":1,"stats":{}}}
    """)
    #expect(reading.displayText == "Reading a note")
    let card = try decode(AnalysisEventDTO.self, """
    {"seq":4,"at":"now","type":"agent.activity","data":{"activityId":"c3","kind":"creating_card","state":"failed","steps":1,"stats":{"failedSteps":1}}}
    """)
    #expect(card.displayText == "Starting a card — failed")
}
