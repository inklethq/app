// Shared with inklet-ios/portal/Shared. Keep the wire format and cache behavior identical.
import Foundation
import CoreGraphics
import Darwin

nonisolated public struct VirtualDisplay: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public let width: Int
    public let height: Int
    public let revision: Int64
    public let frameId: UUID?
    public let updatedAt: String
    public var sizeProfile: String? = nil
    public var profile: VirtualDisplaySizeProfile? { VirtualDisplaySizeProfile(rawValue: sizeProfile ?? "legacy") }
    public var canvasSize: CGSize { CGSize(width: width * 2, height: height * 2) }
    public func isCompatible(with profile: VirtualDisplaySizeProfile) -> Bool {
        self.profile == profile && profile != .legacy && width == profile.width && height == profile.height
    }
}

/// Stable layout canvases, independent of a device's physical screen scale.
nonisolated public enum VirtualDisplaySizeProfile: String, CaseIterable, Codable, Identifiable, Sendable {
    case macLarge = "macos_large"
    case macExtraLarge = "macos_extra_large"
    case iosLarge = "ios_large"
    case ipadExtraLarge = "ipados_extra_large"
    case legacy
    public var id: String { rawValue }
    public var width: Int { switch self { case .macExtraLarge, .ipadExtraLarge: 752; default: 360 } }
    public var height: Int { switch self { case .iosLarge, .legacy: 376; default: 360 } }
    public var title: String {
        switch self {
        case .macLarge: "Mac · Large"
        case .macExtraLarge: "Mac · Extra Large"
        case .iosLarge: "iPhone / iPad · Large"
        case .ipadExtraLarge: "iPad · Extra Large"
        case .legacy: "Original display"
        }
    }
    public var widgetTitle: String {
        switch self { case .macExtraLarge, .ipadExtraLarge: "Virtual Display · Extra Large"; default: "Virtual Display · Large" }
    }
    public var aspectRatio: CGFloat { CGFloat(width) / CGFloat(height) }
    public static var available: [Self] { allCases.filter { $0 != .legacy } }
    public static var localLarge: Self {
        #if os(macOS)
        .macLarge
        #else
        .iosLarge
        #endif
    }
    public static var localExtraLarge: Self {
        #if os(macOS)
        .macExtraLarge
        #else
        .ipadExtraLarge
        #endif
    }
}

nonisolated public struct VirtualDisplayFrame: Codable, Sendable {
    public var display: VirtualDisplay
    public let imageData: Data?
    public let text: String
    public var presentation: GeneratedPresentationDTO? = nil
    // Opaque server validator; do not derive this from the frame revision.
    public var etag: String? = nil
}
nonisolated public struct VirtualDisplayAccess: Codable, Sendable {
    public let token: String
    public let expiresAt: String
}
nonisolated public struct VirtualDisplayRecord: Codable, Sendable {
    public var display: VirtualDisplay
    public var access: VirtualDisplayAccess?
    public init(display: VirtualDisplay, access: VirtualDisplayAccess? = nil) {
        self.display = display; self.access = access
    }
}
nonisolated public struct VirtualDisplaySession: Codable, Equatable, Sendable {
    public let accountID: String
    public let generation: UUID
}
nonisolated public struct VirtualDisplayCatalog: Codable, Sendable {
    public let session: VirtualDisplaySession
    public var items: [VirtualDisplayRecord]
}
nonisolated public enum VirtualDisplayError: LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}

nonisolated public enum VirtualDisplayLinks {
    public static func url(id: UUID? = nil) -> URL {
        #if os(macOS)
        let scheme = "inklet-mac"
        #else
        let scheme = "inklet"
        #endif
        return URL(string: "\(scheme)://display" + (id.map { "/\($0.uuidString.lowercased())" } ?? ""))!
    }
    public static func displayID(_ url: URL) -> UUID? {
        guard ["inklet", "inklet-mac"].contains(url.scheme?.lowercased()), url.host == "display",
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              url.pathComponents.count == 2 else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
}

/// A process-shared lock protects account switches, catalog edits, and frame revisions.
/// No account access/refresh token is ever persisted here: only per-display read access.
nonisolated public struct VirtualDisplayStore: Sendable {
    private let root: URL?
    private struct Cached: Codable { let session: VirtualDisplaySession; let frame: VirtualDisplayFrame }
    public init(rootURL: URL? = nil) {
        if let rootURL { root = rootURL; return }
        #if os(macOS)
        if Bundle.main.object(forInfoDictionaryKey: "InkletWidgetStorageMode") as? String == "local" {
            root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("inklet/VirtualDisplays", isDirectory: true)
            return
        }
        #endif
        let group = Bundle.main.object(forInfoDictionaryKey: "InkletAppGroupIdentifier") as? String ?? "group.com.iminklet.portal"
        root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("VirtualDisplays", isDirectory: true)
    }
    private func locked<T>(_ action: (URL) throws -> T) throws -> T {
        guard let root else { throw VirtualDisplayError.message("Widget storage is unavailable. Use a signed inklet app with App Groups enabled.") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw VirtualDisplayError.message("Couldn't open widget storage.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw VirtualDisplayError.message("Couldn't lock widget storage.") }
        defer { flock(fd, LOCK_UN) }
        return try action(root)
    }
    private func read<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    private func write<T: Encodable>(_ value: T, _ url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func catalog(_ root: URL) throws -> VirtualDisplayCatalog? {
        try read(VirtualDisplayCatalog.self, root.appendingPathComponent("catalog.json"))
    }
    private func clear(_ root: URL) throws {
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where file.lastPathComponent != ".lock" {
            try FileManager.default.removeItem(at: file)
        }
    }
    public func activate(accountID: String) throws -> VirtualDisplaySession {
        try locked { root in
            if let old = try catalog(root), old.session.accountID == accountID { return old.session }
            try clear(root)
            let session = VirtualDisplaySession(accountID: accountID, generation: UUID())
            try write(VirtualDisplayCatalog(session: session, items: []), root.appendingPathComponent("catalog.json"))
            return session
        }
    }
    public func signOut() throws { try locked { try clear($0) } }
    public func catalog() throws -> VirtualDisplayCatalog? { try locked { try catalog($0) } }
    @discardableResult public func replace(_ items: [VirtualDisplayRecord], session: VirtualDisplaySession) throws -> Bool {
        try locked { root in
            guard let current = try catalog(root), current.session == session else { return false }
            let ids = Set(items.map { $0.display.id })
            for old in current.items where !ids.contains(old.display.id) {
                try? FileManager.default.removeItem(at: root.appendingPathComponent("\(old.display.id).json"))
            }
            try write(VirtualDisplayCatalog(session: session, items: items), root.appendingPathComponent("catalog.json"))
            return true
        }
    }
    @discardableResult public func remove(_ id: UUID, session: VirtualDisplaySession) throws -> Bool {
        try locked { root in
            guard var current = try catalog(root), current.session == session else { return false }
            current.items.removeAll { $0.display.id == id }
            try write(current, root.appendingPathComponent("catalog.json"))
            try? FileManager.default.removeItem(at: root.appendingPathComponent("\(id).json"))
            return true
        }
    }
    public func frame(_ id: UUID, session: VirtualDisplaySession) throws -> VirtualDisplayFrame? {
        try locked { root in
            guard let current = try catalog(root), current.session == session,
                  current.items.contains(where: { $0.display.id == id }),
                  let cached = try read(Cached.self, root.appendingPathComponent("\(id).json")), cached.session == session else { return nil }
            var frame = cached.frame
            // Older frame responses omit the immutable profile. Recover it only
            // from the same authenticated catalog entry and exact dimensions.
            if frame.display.sizeProfile == nil,
               let descriptor = current.items.first(where: { $0.display.id == id })?.display,
               frame.display.id == id,
               frame.display.width == descriptor.width, frame.display.height == descriptor.height {
                frame.display.sizeProfile = descriptor.sizeProfile
            }
            return frame
        }
    }
    @discardableResult public func save(_ frame: VirtualDisplayFrame, session: VirtualDisplaySession) throws -> Bool {
        try locked { root in
            guard let current = try catalog(root), current.session == session,
                  current.items.contains(where: { $0.display.id == frame.display.id }) else { return false }
            let file = root.appendingPathComponent("\(frame.display.id).json")
            if let old = try read(Cached.self, file), old.session == session,
               old.frame.display.revision > frame.display.revision { return false }
            var saved = frame
            if saved.presentation == nil, let old = try read(Cached.self, file), old.session == session,
               old.frame.display.revision == frame.display.revision { saved.presentation = old.frame.presentation }
            try write(Cached(session: session, frame: saved), file)
            return true
        }
    }
}

nonisolated public enum VirtualDisplayReader {
    /// WidgetKit schedules this opportunistically; a failed fetch keeps the last good frame.
    public static func refresh(id: UUID, store: VirtualDisplayStore = .init()) async {
        guard let catalog = try? store.catalog(), let record = catalog.items.first(where: { $0.display.id == id }),
              let access = record.access else { return }
        var request = URLRequest(url: InkletServer.apiBase.appending(path: "api/virtual-display-widget/\(id.uuidString.lowercased())"))
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(access.token)", forHTTPHeaderField: "Authorization")
        if let cached = try? store.frame(id, session: catalog.session), let etag = cached.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode
            if code == 404 { try store.remove(id, session: catalog.session); return }
            guard code == 200, data.count < 3 * 1024 * 1024 else { return }
            var frame = try JSONDecoder().decode(VirtualDisplayFrame.self, from: data)
            guard frame.display.id == id else { return }
            frame.etag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
            try store.save(frame, session: catalog.session)
        } catch { /* Offline widgets retain their last successfully published frame. */ }
    }
}
