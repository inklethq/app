import InkletPresentationKit
import SwiftUI

/// Contents of the HUD panel. Lives in `ComposerPanelController`'s window rather
/// than a popover, so the file chooser and app switches don't dismiss it.
///
/// A draft is sent with an *action* (what to do with it) to a *target* (where
/// it goes), the same two choices the web Portal's composer offers:
///
/// - Just upload (⌥1): save the material, no AI run.
/// - Push to device (⌥2): one AI run over this note.
/// - Recent summary (⌥3): this note plus the last week.
/// - Show as-is (⌥4): one picture straight to a display, no AI.
///
/// ⌘↩ sends. Plain Return is a newline in the field, which is what a text
/// field owes the person typing into it.
struct ComposerView: View {
    @Environment(AppModel.self) private var model

    @State private var text = ""
    @State private var action: ComposeAction = .upload
    @State private var destination: AppModel.ComposeTarget = .agent
    @State private var generationID = UUID()
    @State private var virtualBaseRevision: Int64?
    @State private var attachments: [Attachment] = []
    /// Batches of files still being read. Sending waits for them, or a send
    /// could go out without the file the user just picked.
    @State private var pendingReads = 0
    @State private var isSending = false
    @State private var progress: String?
    @State private var error: String?
    @State private var isAddingLink = false
    @State private var linkDraft = ""
    @FocusState private var isEditorFocused: Bool

    struct Attachment: Identifiable {
        let id = UUID()
        var filename: String
        var contentType: String
        var data: Data
        var link: String?

        var isLink: Bool { link != nil }
        var isImage: Bool { contentType.hasPrefix("image/") }

        var symbol: String {
            if isLink { return "link" }
            return isImage ? "photo" : "doc"
        }

        var asset: PresentationAsset {
            if let link { return .link(link) }
            return .binary(filename: filename, contentType: contentType, data: data)
        }
    }

    /// Tahoe rounds panels at roughly 22pt; inset by 12 leaves 10 here.
    private let editorCorner: CGFloat = 10

    private var target: Device? {
        guard case .hardware(let id) = destination else { return nil }
        return model.devices.first { $0.id == id }
    }
    private var virtualTargetID: UUID? {
        guard case .virtual(let id) = destination else { return nil }
        return id
    }
    private var virtualTarget: VirtualDisplay? {
        guard let virtualTargetID else { return nil }
        return model.virtualDisplays.displays.first { $0.id == virtualTargetID }
    }

    /// Only offered while the field is untouched — once you start typing, the
    /// suggestion is no longer what you meant.
    private var ghost: Capture? {
        guard text.isEmpty, attachments.isEmpty,
              let suggestion = model.suggestion, !suggestion.isEmpty else { return nil }
        return suggestion
    }

    /// Shows the strongest signal, with a count for whatever else came with it.
    private func ghostRow(_ capture: Capture) -> some View {
        HStack(spacing: 7) {
            Image(systemName: capture.symbol)
                .font(.system(size: 11))
                .foregroundStyle(Ink.muted)

            Text(capture.summary)
                .font(.system(size: 14))
                .foregroundStyle(Ink.muted)
                .lineLimit(1)
                .truncationMode(.middle)

            if capture.itemCount > 1 {
                Text("+\(capture.itemCount - 1)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Ink.muted)
            }

            Text("tab")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Ink.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Ink.card, in: .rect(cornerRadius: 4))
                .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Ink.border) }
        }
    }

    /// A pinned target arrives from a display page and pre-selects a card; a
    /// plain summon starts on "just upload" every time, so the expensive
    /// actions are never fired by a remembered preference.
    private func syncTarget() {
        if let target = model.composerTarget {
            destination = .hardware(target.id)
            action = .card
        } else if let id = model.composerVirtualTargetID {
            destination = .virtual(id)
            action = .card
        } else {
            destination = .agent
            action = .upload
        }
    }

    /// Takes everything that was captured, not just the headline. Text lands in
    /// the field so it can be edited before sending; links and files become
    /// attachments, because there's nothing to edit about them.
    private func acceptGhost() {
        guard let capture = model.suggestion else { return }

        if let value = capture.text { text = value }

        if let link = capture.link {
            add(Attachment(
                filename: link.title ?? (URL(string: link.url)?.host() ?? link.url),
                contentType: "text/uri-list",
                data: Data(),
                link: link.url))
        }

        attach(capture.files)
        model.suggestion = nil
    }

    private var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    /// The one picture "Show it as-is" would put on a panel.
    private var singleImage: Attachment? {
        guard attachments.count == 1, let only = attachments.first, only.isImage else { return nil }
        return only
    }

    /// `mode = direct` puts the uploaded picture on a panel untouched, so it
    /// only makes sense when the picture is the whole upload. A Virtual Display
    /// also accepts plain text, which the app renders locally.
    private var asIsEligible: Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if virtualTargetID != nil {
            if singleImage != nil { return body.isEmpty }
            return attachments.isEmpty && !body.isEmpty && body.unicodeScalars.count <= 1000
        }
        return body.isEmpty && singleImage != nil
    }

    private var actions: [ComposeAction] {
        ComposeAction.allCases.filter { $0 != .asIs || asIsEligible }
    }

    private func label(for action: ComposeAction) -> (title: String, sub: String) {
        (action.menuTitle, action.menuHint)
    }

    private var blocker: String? {
        guard action != .upload else { return nil }
        if case .agent = destination {
            if action == .asIs { return "Pick a display to show it as-is." }
            if model.devices.isEmpty { return "Pair a display first, or pick a Virtual Display." }
        }
        if case .hardware = destination, target == nil { return "Pick a display to send to." }
        if case .virtual = destination, virtualTarget == nil { return "This Virtual Display is unavailable." }
        if action == .asIs, !asIsEligible {
            return virtualTargetID != nil
                ? "As-is takes one image, or up to 1,000 characters of text."
                : "As-is takes a single image with nothing else."
        }
        return nil
    }

    var body: some View {
        composerBody
            .onChange(of: text) { _, _ in generationID = UUID(); virtualBaseRevision = nil }
            .onChange(of: attachments.map { $0.id }) { _, _ in
                generationID = UUID(); virtualBaseRevision = nil
                if action == .asIs, !asIsEligible { action = .card }
            }
            .onChange(of: destination) { _, _ in
                generationID = UUID(); virtualBaseRevision = nil; error = nil
                if action == .asIs, !asIsEligible { action = .card }
            }
            .onChange(of: action) { _, _ in error = nil }
    }
    private var composerBody: some View {
        // The toolbar sits directly under the editor and nothing grows above it,
        // so the buttons never move. Attachments and notices push the panel's
        // bottom edge down instead of shifting what's under the pointer.
        VStack(spacing: 0) {
            header

            VStack(spacing: 12) {
                editor
                toolbar
                if !attachments.isEmpty { attachmentStrip }
                if let message = error ?? progress ?? blocker { notice(message) }
            }
        }
        // No top inset — the header owns that band and sets its own height.
        .padding(EdgeInsets(top: 0, leading: 12, bottom: 12, trailing: 12))
        .frame(width: 560)
        .background(Ink.bg)
        // The panel no longer sizes itself, so the content reports its own height
        // — attachments and notices grow the window downwards.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            ComposerPanelController.shared.resize(to: size)
        }
        .onAppear {
            syncTarget()
            isEditorFocused = true
        }
        // Every summon, not just the first: the panel is reused, so the caret has
        // to be put back explicitly each time it's ordered front.
        .onChange(of: model.composerFocusToken) { _, _ in
            syncTarget()
            isEditorFocused = true
        }
        .onChange(of: model.virtualDisplays.progress) { _, value in
            if isSending, virtualTargetID != nil, let value { progress = value }
        }
        .popover(isPresented: $isAddingLink, arrowEdge: .bottom) { linkSheet }
    }

    /// Just the wordmark, centred, sharing the strip with the real traffic
    /// lights. The 32pt height is fixed by geometry: a traffic light's centre
    /// sits 16pt below the window edge, so the band is exactly twice that.
    private var header: some View {
        Wordmark(size: 19)
            .offset(y: 2)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
    }

    /// A vertical TextField owns its own prompt, so the placeholder and the caret
    /// can never drift apart the way a hand-placed overlay does.
    private var editor: some View {
        TextField("Message", text: $text,
                  prompt: ghost == nil ? Text("What's on your mind?") : Text(""),
                  axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .lineLimit(5...5)
            .labelsHidden()
            .focused($isEditorFocused)
            .overlay(alignment: .topLeading) {
                if let ghost {
                    ghostRow(ghost)
                        .allowsHitTesting(false)
                }
            }
            .onKeyPress(.tab) {
                guard ghost != nil else { return .ignored }
                acceptGhost()
                return .handled
            }
            .onKeyPress(.rightArrow) {
                guard ghost != nil, text.isEmpty else { return .ignored }
                acceptGhost()
                return .handled
            }
            .onKeyPress(.escape) {
                // Esc drops the suggestion first; a second press closes the panel.
                guard ghost != nil else { return .ignored }
                model.suggestion = nil
                return .handled
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Ink.input, in: .rect(cornerRadius: editorCorner))
            .overlay {
                RoundedRectangle(cornerRadius: editorCorner).strokeBorder(Ink.border)
            }
            .disabled(isSending)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: attachment.symbol)
                            .font(.system(size: 11))
                            .foregroundStyle(Ink.secondary)
                        Text(attachment.filename)
                            .font(.system(size: 12))
                            .foregroundStyle(Ink.text)
                            .lineLimit(1)
                        Button {
                            attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Ink.muted)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Ink.card, in: .capsule)
                    .overlay { Capsule().strokeBorder(Ink.border) }
                }
            }
            .padding(.horizontal, 1)
        }
        .scrollIndicators(.never)
        .frame(height: 30)
    }

    private func notice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: error != nil ? "exclamationmark.triangle" : (progress != nil ? "sparkles" : "info.circle"))
                .font(.system(size: 11))
            Text(message)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(error == nil ? Ink.muted : Ink.danger)
    }

    /// Target picker and the split send button never move; they sit at the
    /// right edge and the attachment tools at the left.
    private var toolbar: some View {
        HStack(spacing: 8) {
            Button("Attach File", systemImage: "paperclip") { chooseFiles() }
                .labelStyle(.iconOnly)
            Button("Add Link", systemImage: "link") { isAddingLink = true }
                .labelStyle(.iconOnly)
            Button("Paste", systemImage: "doc.on.clipboard") { pasteFromClipboard() }
                .labelStyle(.iconOnly)

            Spacer(minLength: 8)

            ComposerTargetPicker(controller: model.virtualDisplays, devices: model.devices, selection: $destination)
                .frame(maxWidth: 190)
                .disabled(action == .upload)
                .help(action == .upload ? "Just upload saves the note without sending it anywhere." : "Where the card goes.")

            sendButton
        }
        .disabled(isSending)
    }

    private var canSend: Bool { hasContent && !isSending && pendingReads == 0 && blocker == nil }

    /// The face names the action; the menu lists the rest. Pressing the face
    /// sends, and so does ⌘↩. Each item carries ⌥1…⌥4, which work with the
    /// menu closed — a shortcut on the Menu itself would land on every item
    /// (that is how Return used to pick "Just upload" instead of sending).
    private var sendButton: some View {
        Menu {
            ForEach(actions) { candidate in
                Button {
                    action = candidate
                } label: {
                    if candidate == action {
                        Label(candidate.menuTitle, systemImage: "checkmark")
                    } else {
                        Text(candidate.menuTitle)
                    }
                }
                .keyboardShortcut(candidate.shortcutKey, modifiers: .option)
                .help(candidate.menuHint)
            }
        } label: {
            HStack(spacing: 6) {
                if isSending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: action == .upload ? "tray.and.arrow.down" : "arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(action.menuTitle)
                    .lineLimit(1)
            }
        } primaryAction: {
            send()
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .fixedSize()
        .disabled(!canSend)
        .help("\(action.menuHint) · ⌘↩ to send")
        .background { hiddenShortcuts }
    }

    /// The key equivalents, on buttons of their own. ⌘↩ cannot sit on the Menu
    /// — a shortcut there propagates to the items, which is how Return used to
    /// pick "Just upload" — and the items' own ⌥n are only certain to fire
    /// while the menu is open, so each mode gets a closed-menu twin here. The
    /// items keep theirs for the hint the menu draws beside them.
    private var hiddenShortcuts: some View {
        Group {
            Button("Send", action: send)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
            ForEach(actions) { candidate in
                Button(candidate.menuTitle) { action = candidate }
                    .keyboardShortcut(candidate.shortcutKey, modifiers: .option)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private var linkSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a link")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Ink.text)
            InkTextField(text: $linkDraft, placeholder: "https://")
                .frame(width: 300)
                .onSubmit(commitLink)
            HStack {
                Spacer()
                Button("Add", action: commitLink)
                    .buttonStyle(.borderedProminent)
                    .disabled(URL(string: linkDraft)?.scheme == nil)
            }
        }
        .padding(14)
    }

    // MARK: - Actions

    private func commitLink() {
        let trimmed = linkDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else { return }
        add(Attachment(filename: url.host() ?? trimmed,
                       contentType: "text/uri-list",
                       data: Data(),
                       link: trimmed))
        linkDraft = ""
        isAddingLink = false
    }

    /// Presented as a sheet on the composer's own window. Run modally it would
    /// take over the app, and the composer would sit behind it looking abandoned.
    private func chooseFiles() {
        let picker = NSOpenPanel()
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = false
        picker.message = "Choose files to send to inklet"

        guard let host = NSApp.keyWindow else {
            if picker.runModal() == .OK { attach(picker.urls) }
            return
        }
        picker.beginSheetModal(for: host) { response in
            guard response == .OK else { return }
            attach(picker.urls)
        }
    }

    /// Every attachment comes through here, so the Content's Asset ceiling
    /// holds however it arrived.
    private func add(_ attachment: Attachment) {
        guard attachments.count < AttachmentRules.maxAttachments else {
            error = AttachmentRules.tooMany
            return
        }
        attachments.append(attachment)
    }

    /// Reads off the main actor, in the order given; a refused file says why
    /// and the rest still come in.
    private func attach(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pendingReads += 1
        Task {
            defer { pendingReads -= 1 }
            for url in urls {
                guard attachments.count < AttachmentRules.maxAttachments else {
                    error = AttachmentRules.tooMany
                    return
                }
                switch await AttachmentRules.load(url) {
                case .file(let filename, let contentType, let data):
                    add(Attachment(filename: filename, contentType: contentType, data: data))
                case .refused(let message):
                    error = message
                }
            }
        }
    }

    /// Images come in as bytes, file promises as URLs, everything else as text.
    private func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            attach(urls.filter(\.isFileURL))
            for url in urls where !url.isFileURL {
                add(Attachment(filename: url.host() ?? url.absoluteString,
                               contentType: "text/uri-list",
                               data: Data(),
                               link: url.absoluteString))
            }
            return
        }

        if let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let filename = "Pasted image.png"
            if let problem = AttachmentRules.problem(filename: filename, contentType: "image/png", byteCount: png.count) {
                error = problem
            } else {
                add(Attachment(filename: filename, contentType: "image/png", data: png))
            }
            return
        }

        if let string = pasteboard.string(forType: .string) {
            text += text.isEmpty ? string : "\n\(string)"
        }
    }

    private func send() {
        guard hasContent, blocker == nil, !isSending, pendingReads == 0 else { return }
        isSending = true
        error = nil
        progress = action == .upload ? "Saving…" : "Uploading…"

        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = attachments
        let selectedAction = action
        let selectedDestination = destination
        let selectedVirtualID = virtualTargetID
        let requestID = generationID

        Task {
            defer { isSending = false; progress = nil }
            do {
                let summary: String
                if let id = selectedVirtualID, selectedAction != .upload {
                    if virtualBaseRevision == nil { virtualBaseRevision = model.virtualDisplays.displays.first { $0.id == id }?.revision }
                    guard let virtualBaseRevision else { throw VirtualDisplayError.message("This display is unavailable.") }
                    try await model.sendToVirtual(action: selectedAction, text: body, image: singleImage?.asset,
                                                  to: id, requestID: requestID, baseRevision: virtualBaseRevision)
                    summary = "Sent"
                } else {
                    summary = try await model.compose(text: body, attachments: payload.map(\.asset),
                                                      action: selectedAction, target: selectedDestination, requestID: requestID)
                }
                progress = summary
                generationID = UUID()
                text = ""
                attachments = []
                // Whatever Photos exported for this send is uploaded now.
                AppContext.discardExports()
                try? await Task.sleep(for: .milliseconds(650))
                ComposerPanelController.shared.hide()
            } catch {
                self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// "Let inklet choose", then every hardware Display, then every Virtual Display.
private struct ComposerTargetPicker: View {
    @ObservedObject var controller: VirtualDisplayController
    let devices: [Device]
    @Binding var selection: AppModel.ComposeTarget
    private var available: [AppModel.ComposeTarget] {
        [.agent] + devices.map { .hardware($0.id) } + controller.displays.map { .virtual($0.id) }
    }
    var body: some View {
        Picker("Display", selection: $selection) {
            Label("Let inklet choose", systemImage: "sparkles").tag(AppModel.ComposeTarget.agent)
            if !devices.isEmpty {
                Divider()
                ForEach(devices) { device in
                    Label { Text(device.displayName) } icon: { device.icon }
                        .tag(AppModel.ComposeTarget.hardware(device.id))
                }
            }
            if !controller.displays.isEmpty {
                Divider()
                ForEach(controller.displays) { Label($0.name, systemImage: "macwindow").tag(AppModel.ComposeTarget.virtual($0.id)) }
            }
        }
        .labelsHidden()
        .onChange(of: available) { _, values in
            if !values.contains(selection) { selection = .agent }
        }
    }
}

extension ComposeAction {
    /// What the send button and its menu call the action. Short: the face of
    /// a split button is not the place for a sentence.
    var menuTitle: String {
        switch self {
        case .upload: "Just upload"
        case .card: "Push to device"
        case .cardHistory: "Recent summary"
        case .asIs: "Show as-is"
        }
    }

    /// The tooltip. What the label does not say and a first-time user asks.
    var menuHint: String {
        switch self {
        case .upload: "Save to Knowledge without sending it anywhere. No AI run. ⌥1"
        case .card: "Make a card from this note and send it to the display. 1 AI run. ⌥2"
        case .cardHistory: "Make a card from this note and the last 7 days of notes. 1 AI run. ⌥3"
        case .asIs: "Put this one picture on the display untouched. No AI. ⌥4"
        }
    }

    /// The digit under ⌥ that picks it, in menu order.
    var shortcutKey: KeyEquivalent {
        switch self {
        case .upload: "1"
        case .card: "2"
        case .cardHistory: "3"
        case .asIs: "4"
        }
    }
}
