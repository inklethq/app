import AppKit

/// Everything the composer could find about what was in front of you.
///
/// A set rather than a single value: the same moment can legitimately carry a
/// page address, a paragraph you highlighted on it, and the file you had picked
/// in Finder before that. Making the capture pick one would force the user to
/// think about which kind of thing they were sending, which is exactly the
/// distinction they shouldn't have to make.
struct Capture: Sendable, Equatable {
    struct Link: Sendable, Equatable {
        var url: String
        var title: String?
    }

    /// Highlighted text, from the accessibility tree or a synthesized copy.
    var text: String?
    /// The frontmost browser tab.
    var link: Link?
    /// Finder selection, the open Preview document, exported Photos items.
    var files: [URL] = []
    /// Free — no permission needed.
    var appName: String?
    /// Needs Accessibility permission, so it may be absent even when appName isn't.
    var windowTitle: String?

    var isEmpty: Bool {
        text == nil && link == nil && files.isEmpty && windowTitle == nil
    }

    /// How many distinct things this would attach. Drives the "+N" hint.
    var itemCount: Int {
        var count = 0
        if text != nil { count += 1 }
        if link != nil { count += 1 }
        count += files.count
        return count
    }

    /// The line shown in grey. Ranked by how specific the signal is: something
    /// you highlighted beats the page it was on, which beats the window's name.
    var summary: String {
        if let text {
            return text.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let link {
            let host = URL(string: link.url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? link.url
            guard let title = link.title, !title.isEmpty else { return host }
            return "\(title) — \(host)"
        }
        if let first = files.first {
            return files.count == 1
                ? first.lastPathComponent
                : "\(first.lastPathComponent) + \(files.count - 1) more"
        }
        if let windowTitle { return windowTitle }
        return appName ?? ""
    }

    var symbol: String {
        if text != nil { return "text.alignleft" }
        if link != nil { return "link" }
        if let first = files.first, files.count == 1 { return first.isImageFile ? "photo" : "doc" }
        if !files.isEmpty { return "doc.on.doc" }
        return "macwindow"
    }
}

private extension URL {
    var isImageFile: Bool {
        ["png", "jpg", "jpeg", "heic", "gif", "tiff", "webp"].contains(pathExtension.lowercased())
    }
}

/// Reads context out of whichever app was frontmost.
///
/// Two hard constraints shape this:
///
/// 1. It has to run *before* the app activates. Once inklet is frontmost the
///    previous app is gone, so the bundle id and pid are captured on the hot-key
///    thread and the slow, permission-gated work happens afterwards.
/// 2. `NSAppleScript` blocks, and the first call per target app raises an
///    automation prompt. Both belong off the main thread.
enum AppContext {
    struct Source: Sendable {
        var bundleID: String
        var pid: pid_t
        var name: String
    }

    /// Call this the moment the shortcut fires, before anything steals focus.
    @MainActor
    static func frontmost() -> Source? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let id = app.bundleIdentifier else { return nil }
        return Source(bundleID: id, pid: app.processIdentifier, name: app.localizedName ?? id)
    }

    /// All sources at once. They're independent and each one is dominated by its
    /// own latency — a serial pass would add them up for no reason.
    static func capture(from source: Source) async -> Capture {
        async let selectedText = SelectionContext.selectedText(pid: source.pid)
        async let payload = appSpecific(source)
        async let title = windowTitle(pid: source.pid)

        var capture = Capture(appName: source.name)
        capture.text = await selectedText
        capture.windowTitle = await title

        switch await payload {
        case .link(let url, let linkTitle):
            capture.link = .init(url: url, title: linkTitle)
        case .files(let urls):
            capture.files = urls
        case .none:
            break
        }
        return capture
    }

    // MARK: - Per-app payloads

    private enum Payload {
        case link(url: String, title: String?)
        case files([URL])
    }

    private static func appSpecific(_ source: Source) async -> Payload? {
        if browsers[source.bundleID] != nil {
            return await browserPage(source.bundleID)
        }
        switch source.bundleID {
        case "com.apple.finder": return await finderSelection()
        case "com.apple.Preview": return await previewDocument()
        case "com.apple.Photos": return await photosSelection()
        default: return nil
        }
    }

    // MARK: - Window title

    /// The cheapest fallback there is — "what am I even looking at" — but the
    /// title lives in the accessibility tree, so it needs the same permission the
    /// selected-text path does.
    private static func windowTitle(pid: pid_t) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            guard AXIsProcessTrusted() else { return nil }
            let app = AXUIElementCreateApplication(pid)

            var window: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
                  CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }

            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(unsafeBitCast(window, to: AXUIElement.self),
                                                kAXTitleAttribute as CFString, &title) == .success,
                  let value = title as? String else { return nil }

            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.value
    }

    // MARK: - Browsers

    private struct Browser {
        var name: String
        /// Safari says `current tab`; every Chromium fork says `active tab`.
        var tabExpression: String
        var titleProperty: String
    }

    private static let browsers: [String: Browser] = [
        "com.apple.Safari": .init(name: "Safari", tabExpression: "current tab of front window", titleProperty: "name"),
        "com.apple.SafariTechnologyPreview": .init(name: "Safari Technology Preview", tabExpression: "current tab of front window", titleProperty: "name"),
        "com.google.Chrome": .init(name: "Google Chrome", tabExpression: "active tab of front window", titleProperty: "title"),
        "com.google.Chrome.canary": .init(name: "Google Chrome Canary", tabExpression: "active tab of front window", titleProperty: "title"),
        "com.microsoft.edgemac": .init(name: "Microsoft Edge", tabExpression: "active tab of front window", titleProperty: "title"),
        "com.brave.Browser": .init(name: "Brave Browser", tabExpression: "active tab of front window", titleProperty: "title"),
        "company.thebrowser.Browser": .init(name: "Arc", tabExpression: "active tab of front window", titleProperty: "title"),
        "com.vivaldi.Vivaldi": .init(name: "Vivaldi", tabExpression: "active tab of front window", titleProperty: "title"),
        "com.operasoftware.Opera": .init(name: "Opera", tabExpression: "active tab of front window", titleProperty: "title"),
    ]

    /// Firefox is absent by design: no scripting dictionary for tabs, and the
    /// GUI-scripting workaround needs Accessibility permission just to read a URL.
    private static func browserPage(_ bundleID: String) async -> Payload? {
        guard let browser = browsers[bundleID] else { return nil }
        // URL and title in one round trip: two scripts would mean two permission
        // checks and a chance of catching the tab mid-navigation.
        let source = """
        tell application "\(browser.name)"
            if (count of windows) is 0 then return ""
            set theTab to \(browser.tabExpression)
            return (URL of theTab) & "\\n" & (\(browser.titleProperty) of theTab)
        end tell
        """
        guard let output = await run(source) else { return nil }

        let parts = output.components(separatedBy: "\n")
        guard let raw = parts.first, !raw.isEmpty,
              let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else { return nil }
        let title = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil
        return .link(url: raw, title: title?.isEmpty == false ? title : nil)
    }

    // MARK: - Finder / Preview / Photos

    private static func finderSelection() async -> Payload? {
        let source = """
        tell application "Finder"
            set sel to selection
            if (count of sel) is 0 then return ""
            set out to ""
            repeat with f in sel
                set out to out & (POSIX path of (f as alias)) & linefeed
            end repeat
            return out
        end tell
        """
        guard let output = await run(source) else { return nil }
        let urls = paths(from: output)
        return urls.isEmpty ? nil : .files(urls)
    }

    private static func previewDocument() async -> Payload? {
        let source = """
        tell application "Preview"
            if (count of documents) is 0 then return ""
            return path of front document
        end tell
        """
        guard let output = await run(source) else { return nil }
        let urls = paths(from: output)
        return urls.isEmpty ? nil : .files(urls)
    }

    /// Photos keeps its library in an opaque bundle, so the selection has to be
    /// exported before it's a file anyone else can read. Exports land in a fresh
    /// temp directory so listing it afterwards is unambiguous.
    private static func photosSelection() async -> Payload? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inklet-photos-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil
        else { return nil }

        let source = """
        tell application "Photos"
            set sel to selection
            if (count of sel) is 0 then return ""
            export sel to POSIX file "\(directory.path)"
            return "ok"
        end tell
        """
        // Exporting a burst or a long video takes real time, so this one gets a
        // longer leash than a property read.
        guard await run(source, timeout: .seconds(15)) == "ok" else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }

        let exported = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                    includingPropertiesForKeys: nil))?
            .filter { !$0.lastPathComponent.hasPrefix(".") } ?? []
        guard !exported.isEmpty else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        return .files(exported.sorted { $0.lastPathComponent < $1.lastPathComponent })
    }

    // MARK: - Plumbing

    private static func paths(from output: String) -> [URL] {
        output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Bounded, because an Apple Event has no ceiling of its own. A target app
    /// that's busy — or an automation prompt nobody has clicked yet — otherwise
    /// leaves this awaiting forever, and the suggestion would arrive minutes
    /// later attached to a composer the user has long since moved on from.
    ///
    /// `NSAppleScript` can't be cancelled, so the losing task is abandoned rather
    /// than stopped; what matters is that the caller stops waiting.
    private static func run(_ source: String, timeout: Duration = .seconds(2)) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask(priority: .userInitiated) {
                var error: NSDictionary?
                guard let script = NSAppleScript(source: source) else { return nil }
                let result = script.executeAndReturnError(&error)
                guard error == nil, let value = result.stringValue, !value.isEmpty else { return nil }
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }

            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
