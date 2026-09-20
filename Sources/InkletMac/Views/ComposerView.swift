import InkletPresentationKit
import SwiftUI
import UniformTypeIdentifiers

/// Contents of the HUD panel. Lives in `ComposerPanelController`'s window rather
/// than a popover, so the file chooser and app switches don't dismiss it.
///
/// A draft is sent with an *action* (what to do with it) to a *target* (where
/// it goes), the same two choices the web Portal's composer offers:
///
/// - Just upload: save the material, no AI run.
/// - Make a card: one AI run over this note.
/// - Make a card using my recent notes: this note plus the last week.
/// - Show it as-is: one picture straight to a display, no AI.
struct ComposerView: View {
    @Environment(AppModel.self) private var model

    @State private var text = ""
    @State private var action: ComposeAction = .upload
    @State private var destination: AppModel.ComposeTarget = .agent
    @State private var generationID = UUID()
    @State private var virtualBaseRevision: Int64?
    @State private var attachments: [Attachment] = []
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
            attachments.append(Attachment(
                filename: link.title ?? (URL(string: link.url)?.host() ?? link.url),
                contentType: "text/uri-list",
                data: Data(),
                link: link.url))
        }

        capture.files.forEach { attach(url: $0) }
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
        switch action {
        case .upload: ("Just upload", "no card, no AI run")
        case .card: ("Make a card", "from this note · 1 AI run")
        case .cardHistory: ("Make a card using my recent notes", "this + last 7 days · 1 AI run")
        case .asIs: ("Show it as-is", "no AI, straight to the display")
        }
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

    /// The face names the action; the menu lists the rest. Pressing the face
    /// sends. Return does the same.
    private var sendButton: some View {
        Menu {
            ForEach(actions) { candidate in
                let labels = label(for: candidate)
                Button {
                    action = candidate
                } label: {
                    if candidate == action {
                        Label("\(labels.title) — \(labels.sub)", systemImage: "checkmark")
                    } else {
                        Text("\(labels.title) — \(labels.sub)")
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if isSending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: action == .upload ? "tray.and.arrow.down" : "arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(label(for: action).title)
                    .lineLimit(1)
            }
        } primaryAction: {
            send()
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .fixedSize()
        .keyboardShortcut(.defaultAction)
        .disabled(!hasContent || isSending || blocker != nil)
        .help(label(for: action).sub)
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
        attachments.append(Attachment(filename: url.host() ?? trimmed,
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
            if picker.runModal() == .OK { picker.urls.forEach { attach(url: $0) } }
            return
        }
        picker.beginSheetModal(for: host) { response in
            guard response == .OK else { return }
            picker.urls.forEach { attach(url: $0) }
        }
    }

    private func attach(url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            error = "Couldn't read \(url.lastPathComponent)"
            return
        }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        attachments.append(Attachment(filename: url.lastPathComponent, contentType: type, data: data))
    }

    /// Images come in as bytes, file promises as URLs, everything else as text.
    private func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            for url in urls where url.isFileURL { attach(url: url) }
            for url in urls where !url.isFileURL {
                attachments.append(Attachment(filename: url.host() ?? url.absoluteString,
                                              contentType: "text/uri-list",
                                              data: Data(),
                                              link: url.absoluteString))
            }
            return
        }

        if let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            attachments.append(Attachment(filename: "Pasted image.png", contentType: "image/png", data: png))
            return
        }

        if let string = pasteboard.string(forType: .string) {
            text += text.isEmpty ? string : "\n\(string)"
        }
    }

    private func send() {
        guard hasContent, blocker == nil, !isSending else { return }
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
                ForEach(devices) { Label($0.displayName, systemImage: $0.kind == .quote0 ? "cloud" : "rectangle.on.rectangle").tag(AppModel.ComposeTarget.hardware($0.id)) }
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
