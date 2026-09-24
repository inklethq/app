import SwiftUI
import InkletPresentationKit

/// Ask inklet: a conversation with the knowledge base. Conversations on the
/// left, the thread on the right, a composer at the bottom. The reply is drawn
/// as it is written; the agent's current step sits under it until it is done.
struct AskView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var ask = model.ask

        HStack(spacing: 0) {
            conversationList
                .frame(width: 220)
            Divider()
            thread
        }
        .background(Ink.bg)
        .navigationTitle("Ask")
        .task { await model.ask.load() }
        .alert("Ask inklet", isPresented: Binding(get: { ask.error != nil }, set: { if !$0 { ask.error = nil } })) {
            Button("OK") { ask.error = nil }
        } message: {
            Text(ask.error ?? "")
        }
    }

    // MARK: - Conversations

    private var conversationList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel("Conversations")
                Spacer()
                Button {
                    Task { await model.ask.select(nil) }
                } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Ink.secondary)
                .help("New conversation")
            }
            .padding(.horizontal, 16)
            .padding(.top, 22)
            .padding(.bottom, 8)

            if model.ask.isLoadingList && model.ask.conversations.isEmpty {
                Text("Loading…").font(.system(size: 12)).foregroundStyle(Ink.muted).padding(.horizontal, 16)
            } else if model.ask.conversations.isEmpty {
                Text("Nothing asked yet.").font(.system(size: 12)).foregroundStyle(Ink.muted).padding(.horizontal, 16)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.ask.conversations) { conversation in
                        conversationRow(conversation)
                    }
                }
                .padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
        }
        .background(Ink.sidebar)
    }

    private func conversationRow(_ conversation: ConversationDTO) -> some View {
        let selected = model.ask.selectedID == conversation.id
        return Button {
            Task { await model.ask.select(conversation.id) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title ?? "New conversation")
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(Ink.text)
                    .lineLimit(1)
                Text(Self.relative(conversation.lastMessageAt ?? conversation.createdAt))
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selected ? Ink.card : .clear, in: .rect(cornerRadius: Ink.controlCorner))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete", role: .destructive) { Task { await model.ask.delete(conversation.id) } }
        }
    }

    // MARK: - Thread

    private var thread: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Ask your second brain")
                    Text("Ask")
                        .font(.brand(34))
                        .foregroundStyle(Ink.text)
                }
                Spacer(minLength: 20)
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if model.ask.isLoadingThread {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Opening…").font(.system(size: 12)).foregroundStyle(Ink.muted) }
                        } else if model.ask.messages.isEmpty {
                            emptyThread
                        }
                        ForEach(model.ask.messages) { message in
                            MessageRow(message: message, live: model.ask.live)
                                .id(message.id)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 8)
                }
                .onChange(of: model.ask.messages.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: model.ask.live?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }

            composer
        }
    }

    private var emptyThread: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask about anything you have saved.")
                .font(.system(size: 14))
                .foregroundStyle(Ink.text)
            Text("inklet searches and reads your notes, answers, and can put a card on a display when you say so. Try “When is my next dentist appointment?” or “Put yesterday’s shopping list back on the kitchen display.”")
                .font(.system(size: 13))
                .foregroundStyle(Ink.secondary)
        }
        .padding(.top, 24)
    }

    private var composer: some View {
        @Bindable var ask = model.ask
        return VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask about your notes…", text: $ask.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .font(.system(size: 14))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Ink.input, in: .rect(cornerRadius: Ink.controlCorner))
                    .onSubmit { Task { await model.ask.send() } }
                    .disabled(model.ask.isSending)
                Button {
                    Task { await model.ask.send() }
                } label: {
                    if model.ask.isSending {
                        ProgressView().controlSize(.small).frame(width: 44, height: 20)
                    } else {
                        Text("Ask").font(.system(size: 13, weight: .medium)).frame(width: 44, height: 20)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.ask.isSending || model.ask.isReplying || model.ask.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
        }
    }

    static func relative(_ value: String) -> String {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = plain.date(from: value) ?? fractional.date(from: value) else { return "" }
        let minutes = Int(Date.now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        if minutes < 24 * 60 { return "\(minutes / 60) h ago" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// One message. A user message is a filled bubble on the right; an assistant
/// message is plain text with the notes it drew on and what it did underneath.
private struct MessageRow: View {
    let message: ConversationMessageDTO
    let live: AskModel.LiveReply?

    private var streaming: AskModel.LiveReply? { live?.messageID == message.id ? live : nil }

    var body: some View {
        if message.isAssistant {
            assistant
        } else {
            HStack {
                Spacer(minLength: 80)
                Text(message.text)
                    .font(.system(size: 14))
                    .foregroundStyle(Ink.bg)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Ink.text, in: .rect(cornerRadius: 14))
            }
        }
    }

    private var assistant: some View {
        let text = streaming?.text ?? message.text
        let citations = streaming?.citations ?? message.citations ?? []
        let actions = streaming?.actions ?? message.actions ?? []
        let working = streaming != nil || message.isOpen
        return VStack(alignment: .leading, spacing: 6) {
            if message.state == "failed" {
                Text(message.failure?.message ?? "inklet could not answer this one. Try asking again.")
                    .font(.system(size: 14))
                    .foregroundStyle(Ink.danger)
            } else {
                if !text.isEmpty {
                    Text(text)
                        .font(.system(size: 14))
                        .foregroundStyle(Ink.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if working {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(streaming?.activity ?? (text.isEmpty ? "Thinking…" : "Writing…"))
                            .font(.system(size: 12))
                            .foregroundStyle(Ink.muted)
                            .contentTransition(.opacity)
                    }
                }
            }
            if !citations.isEmpty {
                HStack(spacing: 6) {
                    ForEach(citations) { citation in
                        Text(citation.title.isEmpty ? "a note" : citation.title)
                            .font(.system(size: 11))
                            .foregroundStyle(Ink.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .overlay { Capsule().strokeBorder(Ink.border) }
                    }
                }
            }
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                Text(action.displayText)
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.secondary)
            }
        }
        .padding(.trailing, 80)
    }
}
