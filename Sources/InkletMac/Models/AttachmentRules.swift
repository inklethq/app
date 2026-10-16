import Foundation
import UniformTypeIdentifiers

/// What one send may carry, from the Content contract: at most 50 Assets, and
/// binary ones no larger than 10 MiB and of a fixed set of types
/// (inklet-backend `internal/sdk/assets.go`, inklet-sdk `src/assets.ts`).
/// Checked when a file is attached, so the composer can name the file that is
/// the problem before anything uploads, instead of relaying a 400 or 413 after.
enum AttachmentRules {
    static let maxBytes = 10 * 1024 * 1024
    /// The note travels as an Asset of its own, so attachments get one fewer.
    static let maxAttachments = 50 - 1

    /// The backend's allow-list, exactly. Anything else is refused there as
    /// `invalid_asset`.
    static let acceptedTypes: Set<String> = [
        "image/png", "image/jpeg", "image/gif", "image/webp", "image/svg+xml",
        "application/pdf", "text/plain", "text/markdown", "application/json",
    ]

    static let tooMany = "One send carries up to \(maxAttachments) attachments."

    /// Why this file can't go, in the words the composer shows; nil if it can.
    static func problem(filename: String, contentType: String, byteCount: Int) -> String? {
        if !acceptedTypes.contains(contentType) {
            return "\(filename) can't be sent. inklet takes PNG, JPEG, GIF, WebP and SVG images, PDFs, and text, Markdown or JSON files."
        }
        if byteCount == 0 { return "\(filename) is empty." }
        if byteCount > maxBytes { return "\(filename) is larger than 10 MB, the most inklet takes for one file." }
        return nil
    }

    /// A link the backend takes: http or https with a host that has a dot in
    /// it (`assets.go` refuses any other scheme, and a URL without a host, as
    /// `invalid_asset`). What people type is often a bare `example.com/page`,
    /// so a missing scheme is read as https. Nil when it isn't a link at all.
    static func link(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        // No credentials either: a web link has none, and with https:// put in
        // front, `mailto:a@example.com` would otherwise read as user "mailto"
        // at example.com.
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.user() == nil, url.password() == nil,
              let host = url.host(), host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".")
        else { return nil }
        return url.absoluteString
    }

    static func contentType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    enum Loaded: Sendable {
        case file(filename: String, contentType: String, data: Data)
        case refused(String)
    }

    /// Reads a file off the main actor — a large file, or one on a slow or
    /// network volume, used to stall the composer mid-keystroke — and checks
    /// its type and size before reading a byte of it.
    static func load(_ url: URL) async -> Loaded {
        await Task.detached(priority: .userInitiated) { read(url) }.value
    }

    private static func read(_ url: URL) -> Loaded {
        let filename = url.lastPathComponent
        let type = contentType(for: url)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        if let size, let problem = problem(filename: filename, contentType: type, byteCount: size) {
            return .refused(problem)
        }
        guard let data = try? Data(contentsOf: url) else { return .refused("Couldn't read \(filename)") }
        // The size on disk was a promise; the bytes read are what uploads.
        if let problem = problem(filename: filename, contentType: type, byteCount: data.count) {
            return .refused(problem)
        }
        return .file(filename: filename, contentType: type, data: data)
    }
}
