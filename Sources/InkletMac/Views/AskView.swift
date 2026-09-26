import SwiftUI
import InkletPresentationKit

/// A shelf of conversations, with native navigation into a focused reading view.
struct AskView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("ask.pinnedConversations") private var storedPins = "[]"
    @Binding var path: NavigationPath
    @State private var search = ""
    @State private var renamingConversation: ConversationDTO?

    private var pins: Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: Data(storedPins.utf8))) ?? [])
    }

    private var matching: [ConversationDTO] {
        model.ask.conversations.filter {
            search.isEmpty || ($0.title ?? "New conversation").localizedStandardContains(search)
        }
    }

    var body: some View {
        @Bindable var ask = model.ask
        NavigationStack(path: $path) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Ask").font(.brand(34)).foregroundStyle(Ink.text)
                        Text("Ask questions about the things you’ve saved.")
                            .font(.system(size: 13)).foregroundStyle(Ink.secondary)
                    }
                    Spacer(minLength: 16)
                    Button("New conversation", systemImage: "plus") { newConversation() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 28)
                .padding(.top, 26)
                .padding(.bottom, 20)

                HStack {
                    Spacer()
                    InkSearchField(text: $search, placeholder: "Find a conversation")
                        .frame(width: 240)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 14)

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if model.ask.isLoadingList && model.ask.conversations.isEmpty {
                            ProgressView("Opening your conversations…").controlSize(.small)
                        } else if model.ask.conversations.isEmpty {
                            InkCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Start with a thought.").font(.brand(26))
                                    Text("Ask about something you saved, connect a few ideas, or bring a thought into view.")
                                        .font(.system(size: 13)).foregroundStyle(Ink.secondary)
                                    Button("Ask inklet", systemImage: "arrow.up.right") { newConversation() }
                                        .buttonStyle(.bordered)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else {
                            if !matching.filter({ pins.contains($0.id) }).isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    SectionLabel("Pinned")
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], spacing: 14) {
                                        ForEach(matching.filter { pins.contains($0.id) }) { conversation in
                                            pinnedCard(conversation)
                                        }
                                    }
                                }
                            }
                            VStack(alignment: .leading, spacing: 12) {
                                SectionLabel("Conversations")
                                if matching.isEmpty {
                                    Text("No conversations match your search.")
                                        .font(.system(size: 13)).foregroundStyle(Ink.secondary).padding(.vertical, 20)
                                } else {
                                    InkItemList(items: matching) { conversation in
                                        conversationRow(conversation)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 28).padding(.bottom, 28)
                }
            }
            .background(Ink.bg)
            .navigationTitle("Ask")
            .toolbar { ComposerToolbar(newConversation: newConversation) }
            .navigationDestination(for: AskDestination.self) { destination in
                AskThreadView(destination: destination, newConversation: newConversation)
                    .id(destination)
            }
        }
        .task { await model.ask.load() }
        .sheet(item: $renamingConversation) { conversation in
            AskRenameSheet(conversationID: conversation.id, initialTitle: conversation.title ?? "")
        }
        .alert("Ask inklet", isPresented: Binding(get: { ask.error != nil }, set: { if !$0 { ask.error = nil } })) {
            Button("OK") { ask.error = nil }
        } message: { Text(ask.error ?? "") }
    }

    private func newConversation() {
        model.ask.draft = ""
        path = NavigationPath([AskDestination.new(UUID())])
    }

    private func togglePin(_ id: String) {
        var updated = pins
        if updated.contains(id) { updated.remove(id) } else { updated.insert(id) }
        if let data = try? JSONEncoder().encode(updated.sorted()), let value = String(data: data, encoding: .utf8) {
            storedPins = value
        }
    }

    private func pinnedCard(_ conversation: ConversationDTO) -> some View {
        InkCard(padding: 0) {
            Button { path.append(AskDestination.conversation(conversation.id)) } label: {
                VStack(alignment: .leading, spacing: 14) {
                    Text(conversation.title ?? "New conversation")
                        .font(.brand(25)).foregroundStyle(Ink.text).lineLimit(2)
                    HStack {
                        Text(Self.relative(conversation.lastMessageAt ?? conversation.createdAt))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                    .font(InkType.metadata).foregroundStyle(Ink.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .contentShape(.rect)
            }
            .buttonStyle(InkListRowButtonStyle())
            .contextMenu { conversationMenu(conversation) }
        }
    }

    private func conversationRow(_ conversation: ConversationDTO) -> some View {
        InkListRow(title: conversation.title ?? "New conversation") {
            path.append(AskDestination.conversation(conversation.id))
        } leading: {
            Image(systemName: "text.alignleft")
        } metadata: {
            Text(Self.relative(conversation.lastMessageAt ?? conversation.createdAt))
                .frame(width: 96, alignment: .trailing)
        }
        .contextMenu { conversationMenu(conversation) }
    }

    @ViewBuilder
    private func conversationMenu(_ conversation: ConversationDTO) -> some View {
        Button(pins.contains(conversation.id) ? "Unpin" : "Pin",
               systemImage: pins.contains(conversation.id) ? "pin.slash" : "pin") {
            togglePin(conversation.id)
        }
        Button("Rename…", systemImage: "pencil") { renamingConversation = conversation }
        Button("Delete", role: .destructive) { Task { await model.ask.delete(conversation.id) } }
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

enum AskDestination: Hashable {
    case new(UUID)
    case conversation(String)

    var conversationID: String? {
        if case .conversation(let id) = self { return id }
        return nil
    }
}

private struct AskThreadView: View {
    @Environment(AppModel.self) private var model
    let destination: AskDestination
    let newConversation: () -> Void
    @State private var materialsExpanded = false
    @State private var opened = false
    @State private var visible = false
    @State private var showingRename = false
    @FocusState private var composerFocused: Bool

    private var title: String {
        model.ask.conversations.first { $0.id == model.ask.selectedID }?.title ?? "New conversation"
    }

    private var citations: [MessageCitationDTO] {
        var seen = Set<String>()
        return (model.ask.messages.flatMap { $0.citations ?? [] } + (model.ask.live?.citations ?? []))
            .filter { seen.insert($0.contentId).inserted }
    }

    private var actions: [MessageActionDTO] {
        var result: [MessageActionDTO] = []
        for action in model.ask.messages.flatMap({ $0.actions ?? [] }) + (model.ask.live?.actions ?? []) {
            if !result.contains(action) { result.append(action) }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        header
                        if !opened || model.ask.isLoadingThread {
                            ProgressView("Opening…").controlSize(.small)
                        } else {
                            ForEach(model.ask.messages) { message in
                                AskMessageRow(message: message, live: model.ask.live)
                                    .id(message.id)
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 12)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: model.ask.messages.count) { _, _ in
                    if opened { proxy.scrollTo("end", anchor: .bottom) }
                }
                .onChange(of: model.ask.live?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            if opened && !model.ask.isLoadingThread && model.ask.messages.isEmpty {
                emptyThread
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 28)
                    .frame(maxWidth: .infinity)
            }
            composer
        }
        .background(Ink.bg)
        .navigationTitle(opened ? title : "Conversation")
        .toolbar { ComposerToolbar(newConversation: newConversation) }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onChange(of: model.ask.isSending) { wasSending, isSending in
            if isSending {
                composerFocused = false
            } else if wasSending {
                Task { @MainActor in
                    await Task.yield()
                    if visible && !showingRename { composerFocused = true }
                }
            }
        }
        .sheet(isPresented: $showingRename) {
            if let id = model.ask.selectedID {
                AskRenameSheet(conversationID: id, initialTitle: title)
            }
        }
        .task {
            await model.ask.select(destination.conversationID)
            opened = true
            if destination.conversationID == nil { composerFocused = true }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { showingRename = true } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(opened ? title : "Conversation")
                        .font(.brand(34)).foregroundStyle(Ink.text)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if opened && model.ask.selectedID != nil {
                        Image(systemName: "pencil").font(.system(size: 13)).foregroundStyle(Ink.muted)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!opened || model.ask.selectedID == nil)
            .accessibilityLabel("Rename conversation: \(title)")
            .help("Rename conversation")
            if opened && !model.ask.messages.isEmpty {
                DisclosureGroup(isExpanded: $materialsExpanded) {
                    VStack(alignment: .leading, spacing: 16) {
                        if citations.isEmpty && actions.isEmpty {
                            Text("Sources and results will appear here when inklet uses your notes or takes an action.")
                                .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                        }
                        if !citations.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionLabel("Sources")
                                ForEach(citations) { citation in
                                    Label(citation.title.isEmpty ? "Untitled note" : citation.title, systemImage: "doc.text")
                                        .font(.system(size: 13)).foregroundStyle(Ink.text)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        if !actions.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionLabel("Results")
                                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Label(action.displayText, systemImage: "rectangle.on.rectangle")
                                            .font(.system(size: 13)).foregroundStyle(Ink.text)
                                        if let id = action.analysisId {
                                            Button("View activity", systemImage: "arrow.up.right") { model.openRun(id) }
                                                .buttonStyle(.link).font(.system(size: 12))
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16).background(Ink.card, in: .rect(cornerRadius: Ink.cardCorner))
                    .padding(.top, 10)
                } label: {
                    HStack(spacing: 8) {
                        Text("Materials & results")
                        if !citations.isEmpty || !actions.isEmpty {
                            Text("\(citations.count) sources").foregroundStyle(Ink.secondary)
                            Text("\(actions.count) results").foregroundStyle(Ink.secondary).padding(.leading, 8)
                        }
                    }
                    .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                }
                .disclosureGroupStyle(AskMaterialsDisclosureStyle())
            }
        }
    }

    private var emptyThread: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What would you like to explore?")
                .font(.brand(28)).foregroundStyle(Ink.text)
            Text("Find an answer in your notes, or make connections between them.")
                .font(.system(size: 14)).foregroundStyle(Ink.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { suggestions }
                VStack(alignment: .leading, spacing: 10) { suggestions }
            }
        }
        .padding(.top, 24).padding(.bottom, 8)
    }

    @ViewBuilder private var suggestions: some View {
        Button("Connect a few ideas") {
            model.ask.draft = "Help me connect ideas from my recent notes."
            composerFocused = true
        }
        Button("Bring a thought into view") {
            model.ask.draft = "Help me find something worth keeping on my desk display."
            composerFocused = true
        }
    }

    private var composer: some View {
        @Bindable var ask = model.ask
        return VStack(alignment: .leading, spacing: 12) {
            TextField("Ask…", text: $ask.draft, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(2...6).font(.system(size: 14))
                .focused($composerFocused)
                .disabled(!opened || ask.isSending || ask.isLoadingThread)
                .onSubmit { Task { await ask.send() } }
            HStack {
                Spacer()
                Button { Task { await ask.send() } } label: {
                    if ask.isSending {
                        ProgressView().controlSize(.small).frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "arrow.up")
                            .resizable()
                            .scaledToFit()
                            .fontWeight(.semibold)
                            .frame(width: 16, height: 16, alignment: .center)
                    }
                }
                .buttonStyle(AskSendButtonStyle())
                .accessibilityLabel("Send question").help("Send question (⌘Return)")
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!opened || ask.isLoadingThread || ask.isSending || ask.isReplying || ask.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16).background(Ink.card, in: .rect(cornerRadius: Ink.cardCorner))
        .frame(maxWidth: 720).padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 22)
        .frame(maxWidth: .infinity)
    }
}

private struct AskMessageRow: View {
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
        let working = streaming != nil || message.isOpen
        return VStack(alignment: .leading, spacing: 14) {
            if message.state == "failed" {
                Text(message.failure?.message ?? "inklet could not answer this one. Try asking again.")
                    .font(.system(size: 14)).foregroundStyle(Ink.danger)
            } else {
                if !text.isEmpty {
                    Text(Self.formatted(text))
                        .font(.system(size: 14)).lineSpacing(6).foregroundStyle(Ink.text)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                if working {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(streaming?.activity ?? (text.isEmpty ? "Thinking…" : "Writing…"))
                            .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                    }
                }
            }
            if !citations.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(citations) { citation in
                        Label(citation.title.isEmpty ? "Untitled note" : citation.title, systemImage: "doc.text")
                            .font(.system(size: 11)).foregroundStyle(Ink.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(Ink.card, in: .rect(cornerRadius: Ink.controlCorner))
                    }
                }
            }
            ForEach(Array((streaming?.actions ?? message.actions ?? []).enumerated()), id: \.offset) { _, action in
                Label(action.displayText, systemImage: "rectangle.on.rectangle")
                    .font(.system(size: 12)).foregroundStyle(Ink.secondary)
            }
        }
        .padding(.trailing, 80)
    }

    private static func formatted(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

private struct AskSendButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 32, height: 32, alignment: .center)
            .foregroundStyle(Ink.bg)
            .background(
                Ink.text.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.25),
                in: .rect(cornerRadius: Ink.controlCorner)
            )
            .contentShape(.rect(cornerRadius: Ink.controlCorner))
    }
}

private struct AskMaterialsDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                    configuration.label
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Ink.secondary)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded { configuration.content }
        }
    }
}

private struct AskRenameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let conversationID: String
    @State private var title: String
    @State private var saving = false
    @State private var error: String?
    @FocusState private var titleFocused: Bool

    init(conversationID: String, initialTitle: String) {
        self.conversationID = conversationID
        _title = State(initialValue: initialTitle)
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool { !trimmedTitle.isEmpty && trimmedTitle.unicodeScalars.count <= 200 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename conversation").font(.brand(25)).foregroundStyle(Ink.text)
            TextField("Conversation title", text: $title)
                .textFieldStyle(.roundedBorder).focused($titleFocused)
                .disabled(saving)
                .onSubmit { if valid && !saving { save() } }
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(Ink.danger)
            } else if trimmedTitle.unicodeScalars.count > 200 {
                Text("Keep the title under 200 characters.").font(.system(size: 12)).foregroundStyle(Ink.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(saving ? "Saving…" : "Save", action: save)
                    .keyboardShortcut(.defaultAction).disabled(!valid || saving)
            }
        }
        .padding(24).frame(width: 400).background(Ink.bg)
        .interactiveDismissDisabled(saving)
        .onAppear { titleFocused = true }
    }

    private func save() {
        guard valid && !saving else { return }
        saving = true
        error = nil
        Task {
            do {
                try await model.ask.rename(conversationID, title: trimmedTitle)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                saving = false
            }
        }
    }
}
