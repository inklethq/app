import Foundation
import Observation
import InkletPresentationKit

/// Ask inklet: a conversation with the knowledge base.
///
/// Every message the user sends starts one round. The backend answers with an
/// assistant message whose text arrives on the round's Analysis event stream
/// (`assistant.delta`), so the reply is drawn as it is written; once the round
/// ends the conversation is re-read and the settled message — text, the notes
/// it drew on, what the agent did — replaces what was streamed.
@MainActor
@Observable
final class AskModel {
    /// What the page knows about the round in flight, on top of the messages.
    struct LiveReply: Equatable {
        let messageID: String
        let analysisID: String
        var text = ""
        /// The agent's latest step, for the line under the growing text.
        var activity: String?
        var citations: [MessageCitationDTO] = []
        var actions: [MessageActionDTO] = []
    }

    var conversations: [ConversationDTO] = []
    var isLoadingList = false
    private(set) var selectedID: String?
    var messages: [ConversationMessageDTO] = []
    var isLoadingThread = false
    var draft = ""
    var isSending = false
    var live: LiveReply?
    var error: String?

    private var followTask: Task<Void, Never>?
    private var generation = UUID()

    /// One `Idempotency-Key` per attempt to send the current draft, so a retry
    /// after a dropped connection does not start a second round.
    private var pendingRequestID = UUID()

    var isReplying: Bool { live != nil }

    func reset() {
        generation = UUID()
        followTask?.cancel()
        followTask = nil
        conversations = []
        selectedID = nil
        messages = []
        draft = ""
        live = nil
        error = nil
        isLoadingList = false
        isLoadingThread = false
        isSending = false
    }

    func load() async {
        let expected = generation
        isLoadingList = true
        defer { if generation == expected { isLoadingList = false } }
        do {
            let page = try await InkletAPI.shared.conversations(limit: 50)
            guard generation == expected else { return }
            conversations = page.items
            error = nil
        } catch is CancellationError {
        } catch {
            guard generation == expected else { return }
            self.error = describe(error)
        }
    }

    /// Opens a conversation; `nil` is the empty "new conversation" state. A
    /// round that was still running when it was opened is picked up where it is.
    func select(_ id: String?) async {
        followTask?.cancel()
        followTask = nil
        live = nil
        selectedID = id
        messages = []
        guard let id else { return }
        let expected = generation
        isLoadingThread = true
        defer { if generation == expected { isLoadingThread = false } }
        do {
            let detail = try await InkletAPI.shared.conversation(id: id)
            guard generation == expected, selectedID == id else { return }
            messages = detail.messages
            error = nil
            if let open = detail.messages.last(where: \.isOpen), let analysisID = open.analysisId {
                follow(conversationID: id, replyID: open.id, analysisID: analysisID)
            }
        } catch is CancellationError {
        } catch {
            guard generation == expected else { return }
            self.error = describe(error)
        }
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, live == nil else { return }
        guard text.count <= 4000 else { error = "Keep it under 4000 characters."; return }
        let expected = generation
        isSending = true
        defer { if generation == expected { isSending = false } }
        do {
            var id = selectedID
            if id == nil {
                let created = try await InkletAPI.shared.createConversation()
                guard generation == expected else { return }
                conversations.insert(created, at: 0)
                selectedID = created.id
                id = created.id
            }
            guard let id else { return }
            let sent = try await InkletAPI.shared.sendMessage(conversationID: id, text: text, requestID: pendingRequestID)
            guard generation == expected, selectedID == id else { return }
            pendingRequestID = UUID()
            draft = ""
            error = nil
            messages.append(sent.message)
            messages.append(ConversationMessageDTO(
                id: sent.reply.id, conversationId: id, role: "assistant", state: sent.reply.state, text: "",
                analysisId: sent.reply.analysisId, citations: [], actions: [], failure: nil,
                createdAt: sent.message.createdAt, completedAt: nil))
            follow(conversationID: id, replyID: sent.reply.id, analysisID: sent.reply.analysisId)
        } catch is CancellationError {
        } catch {
            guard generation == expected else { return }
            self.error = describe(error)
        }
    }

    func delete(_ id: String) async {
        let expected = generation
        do {
            try await InkletAPI.shared.deleteConversation(id: id)
            guard generation == expected else { return }
            conversations.removeAll { $0.id == id }
            if selectedID == id { await select(nil) }
        } catch {
            guard generation == expected else { return }
            self.error = describe(error)
        }
    }

    /// Polls the round's public events until it settles, growing the reply as
    /// deltas arrive, then re-reads the conversation for the settled message.
    private func follow(conversationID: String, replyID: String, analysisID: String) {
        followTask?.cancel()
        live = LiveReply(messageID: replyID, analysisID: analysisID)
        let expected = generation
        followTask = Task { @MainActor [weak self] in
            var after = 0
            var settled = false
            for _ in 0..<900 {
                guard !Task.isCancelled, let self, self.generation == expected else { return }
                do {
                    var hasMore = true
                    var state: String?
                    while hasMore {
                        let page = try await InkletAPI.shared.analysisEvents(id: analysisID, after: after)
                        guard !Task.isCancelled, self.generation == expected else { return }
                        for event in page.items {
                            self.apply(event)
                            after = max(after, event.seq)
                        }
                        if let next = page.nextAfter { after = max(after, next) }
                        hasMore = (page.hasMore ?? false) && !page.items.isEmpty
                        state = page.state ?? state
                    }
                    if state == "completed" || state == "failed" { settled = true; break }
                } catch is CancellationError {
                    return
                } catch {
                    // A dropped poll is not the end of the round; the next one resumes from `after`.
                }
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled, let self, self.generation == expected else { return }
            if settled, self.selectedID == conversationID,
               let detail = try? await InkletAPI.shared.conversation(id: conversationID),
               self.generation == expected, self.selectedID == conversationID {
                self.messages = detail.messages
            }
            self.live = nil
            await self.load()
        }
    }

    private func apply(_ event: AnalysisEventDTO) {
        guard var current = live else { return }
        switch event.type {
        case "assistant.delta":
            current.text += event.data?["text"]?.stringValue ?? ""
        case "agent.activity":
            current.activity = event.displayText
        case "assistant.citation":
            if let contentID = event.data?["contentId"]?.stringValue, !current.citations.contains(where: { $0.contentId == contentID }) {
                current.citations.append(MessageCitationDTO(contentId: contentID, title: event.data?["title"]?.stringValue ?? ""))
            }
        case "action.card_created":
            current.actions.append(MessageActionDTO(kind: "card_created", analysisId: event.data?["analysisId"]?.stringValue,
                                                    displayId: event.data?["displayId"]?.stringValue, presentationId: nil))
        case "action.display_switched":
            current.actions.append(MessageActionDTO(kind: "display_switched", analysisId: nil,
                                                    displayId: event.data?["displayId"]?.stringValue,
                                                    presentationId: event.data?["presentationId"]?.stringValue))
        default:
            break
        }
        live = current
    }

    private func describe(_ error: Error) -> String {
        if let http = error as? PresentationHTTPError {
            switch http.code {
            case "reply_in_progress": return "inklet is still answering the last question."
            case "plan_upgrade_required": return "Ask inklet is part of Pro. Upgrade from the web Portal to use it."
            default: return http.message
            }
        }
        return (error as? APIError)?.errorDescription ?? error.localizedDescription
    }
}
