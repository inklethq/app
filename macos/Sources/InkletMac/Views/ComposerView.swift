import SwiftUI
import UniformTypeIdentifiers

/// Contents of the HUD panel. Lives in `ComposerPanelController`'s window rather
/// than a popover, so the file chooser and app switches don't dismiss it.
struct ComposerView: View {
    @Environment(AppModel.self) private var model

    @State private var text = ""
    @State private var mode: Mode = .auto
    @State private var targetID: String?
    @State private var attachments: [Attachment] = []
    @State private var isSending = false
    @State private var error: String?
    @State private var isAddingLink = false
    @State private var linkDraft = ""
    @FocusState private var isEditorFocused: Bool

    enum Mode: String, CaseIterable, Identifiable {
        case auto = "Auto", manual = "Manual"
        var id: Self { self }
    }

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
    }

    /// Tahoe rounds panels at roughly 22pt; inset by 12 leaves 10 here.
    private let editorCorner: CGFloat = 10

    private var target: Device? { model.devices.first { $0.id == targetID } }

    /// Only offered while the field is untouched — once you start typing, the
    /// suggestion is no longer what you meant.
    private var ghost: Capture? {
        guard text.isEmpty, attachments.isEmpty,
              let suggestion = model.suggestion, !suggestion.isEmpty else { return nil }
        return suggestion
    }

    /// Shows the strongest signal, with a count for whatever else came with it.
    /// Listing every source inline would turn a one-line hint into a paragraph,
    /// and accepting is all-or-nothing anyway.
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

    private func syncTarget() {
        if let target = model.composerTarget {
            mode = .manual
            targetID = target.id
        } else if targetID == nil {
            targetID = model.devices.first?.id
        }
    }

    /// Takes everything that was captured, not just the headline. Text lands in
    /// the field so it can be edited before sending; links and files become
    /// attachments, because there's nothing to edit about them.
    ///
    /// The window title is deliberately not attached — it's a label for the
    /// suggestion, not content anyone means to send on its own.
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

    /// Manual mode goes through the custom-push route, which the backend only
    /// accepts images on. Anything else has to take the Auto path.
    private var manualImage: Attachment? {
        let images = attachments.filter(\.isImage)
        guard images.count == 1, attachments.count == 1 else { return nil }
        return images.first
    }

    private var manualBlocker: String? {
        guard mode == .manual else { return nil }
        if target == nil { return "Pick a display to send to." }
        if manualImage == nil {
            return "Sending straight to a display works with a single image. Use Auto for text, links and files."
        }
        return nil
    }

    var body: some View {
        // The toolbar sits directly under the editor and nothing grows above it,
        // so the buttons never move. Attachments and notices push the panel's
        // bottom edge down instead of shifting what's under the pointer.
        VStack(spacing: 0) {
            header

            VStack(spacing: 12) {
                editor
                toolbar
                if !attachments.isEmpty { attachmentStrip }
                if let message = error ?? manualBlocker { notice(message) }
            }
        }
        // No top inset — the header owns that band and sets its own height.
        .padding(EdgeInsets(top: 0, leading: 12, bottom: 12, trailing: 12))
        .frame(width: 540)
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
        .popover(isPresented: $isAddingLink, arrowEdge: .bottom) { linkSheet }
    }

    /// Just the wordmark, centred, sharing the strip with the real traffic
    /// lights. Closing is the red button's job — a second, hand-drawn ✕ next to
    /// it was redundant.
    ///
    /// The 32pt height is fixed by geometry, not taste: a traffic light's centre
    /// sits 16pt below the window edge (9pt drop + 7pt radius). For the wordmark
    /// to share that centre line *and* for the band to be evenly padded above and
    /// below, the band has to be exactly twice that.
    private var header: some View {
        Wordmark(size: 19)
            // Optical, not geometric. "inklet PORTAL" has ascenders but no
            // descenders, so the text block's measured middle — which is what
            // `frame` centres — sits above where the eye puts it. Nudged down to
            // land on the traffic lights' line.
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
            // The suggestion sits where the placeholder would, greyed out, and is
            // never written into `text` until it's accepted.
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
            // Concentric with the window, not the app's card radius: a nested
            // shape has to be *less* round than what encloses it, and the panel's
            // own corner is the system window radius minus the 12pt inset.
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
            Image(systemName: "info.circle")
                .font(.system(size: 11))
            Text(message)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(error == nil ? Ink.muted : Ink.danger)
    }

    /// Mode switch and Send never move. Manual's extra picker grows to their left.
    private var toolbar: some View {
        HStack(spacing: 8) {
            Button("Attach File", systemImage: "paperclip") { chooseFiles() }
                .labelStyle(.iconOnly)
            Button("Add Link", systemImage: "link") { isAddingLink = true }
                .labelStyle(.iconOnly)
            Button("Paste", systemImage: "doc.on.clipboard") { pasteFromClipboard() }
                .labelStyle(.iconOnly)

            Spacer(minLength: 8)

            if mode == .manual {
                Picker("Display", selection: $targetID) {
                    ForEach(model.devices) { Text($0.displayName).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(model.devices.isEmpty)
            }

            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Button("Send", systemImage: isSending ? "ellipsis" : "arrow.up") { send() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!hasContent || isSending || manualBlocker != nil)
        }
        .disabled(isSending)
        // No transition on `mode`: animating the display picker in and out slides
        // every other button sideways, which reads as a twitch when you're just
        // toggling Auto/Manual. The row snaps instead.
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
        guard hasContent, manualBlocker == nil else { return }
        isSending = true
        error = nil

        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = attachments

        Task {
            defer { isSending = false }
            do {
                if mode == .manual, let device = target, let image = manualImage {
                    try await model.sendDirect(
                        image: .init(filename: image.filename, contentType: image.contentType, data: image.data),
                        to: device,
                        title: body)
                } else {
                    let files = payload.filter { !$0.isLink }.map {
                        InkletAPI.Attachment(filename: $0.filename, contentType: $0.contentType, data: $0.data)
                    }
                    let links = payload.compactMap(\.link)
                    try await model.send(text: body, files: files, links: links)
                }
                text = ""
                attachments = []
                ComposerPanelController.shared.hide()
            } catch {
                self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
