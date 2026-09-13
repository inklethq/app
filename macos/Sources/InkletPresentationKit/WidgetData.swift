import Foundation

public let inkletQuickSendWidgetKind = "QuickSendWidget"
public let inkletActivityWidgetKind = "HeatmapWidget"

/// A Mac-specific scheme avoids competing with the retired Electron client.
public enum WidgetDestination: String, CaseIterable, Sendable {
    case send, activity, display

    public var url: URL { URL(string: "inklet-mac://\(rawValue)")! }

    public init?(url: URL) {
        guard ["inklet-mac", "inklet"].contains(url.scheme?.lowercased()),
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { return nil }
        if url.host == "presentations", url.path == "/latest" {
            self = .display
        } else if url.path.isEmpty || url.path == "/",
                  let value = Self(rawValue: url.host ?? "") {
            self = value
        } else {
            return nil
        }
    }
}

public struct WidgetSession: Codable, Equatable, Sendable {
    public let accountID: String?
    public let generation: UUID

    public var isSignedIn: Bool { accountID != nil }
}

public struct ActivitySnapshot: Codable, Sendable {
    public let counts: [String: Int]
    public let updatedAt: Date

    public init(counts: [Date: Int], updatedAt: Date = .now, calendar: Calendar = .current) {
        let formatter = Self.formatter(calendar: calendar)
        self.counts = counts.reduce(into: [:]) { result, entry in
            result[formatter.string(from: entry.key), default: 0] += max(0, entry.value)
        }
        self.updatedAt = updatedAt
    }

    public func datedCounts(calendar: Calendar = .current) -> [Date: Int] {
        let formatter = Self.formatter(calendar: calendar)
        return counts.reduce(into: [:]) { result, entry in
            if let day = formatter.date(from: entry.key) {
                result[calendar.startOfDay(for: day)] = max(0, entry.value)
            }
        }
    }

    private static func formatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

/// Host writes; extensions only read. Every payload is tied to a login
/// generation, so a late network response cannot expose the previous account.
public struct WidgetDataStore: Sendable {
    private struct Envelope<Value: Codable>: Codable {
        let generation: UUID
        let value: Value
    }

    private let root: URL

    public init(rootURL: URL? = nil) {
        root = rootURL ?? WidgetStorage.rootURL
    }

    public func session() throws -> WidgetSession? { try read("session.json") }

    @discardableResult
    public func activate(accountID: String) throws -> WidgetSession {
        if let current = try session(), current.accountID == accountID { return current }
        let current = WidgetSession(accountID: accountID, generation: UUID())
        try write(current, to: "session.json")
        try removePayloads()
        return current
    }

    public func signOut() throws {
        // Invalidate first, even if removing a payload subsequently fails.
        try write(WidgetSession(accountID: nil, generation: UUID()), to: "session.json")
        try removePayloads()
    }

    public func storeActivity(_ activity: ActivitySnapshot, for session: WidgetSession) throws {
        try store(activity, named: "activity.json", for: session)
    }

    public func activity() throws -> ActivitySnapshot? { try load("activity.json") }

    public func storePresentation(_ presentation: CachedPresentationSnapshot, for session: WidgetSession) throws {
        try store(presentation, named: "display.json", for: session)
    }

    public func presentation() throws -> CachedPresentationSnapshot? { try load("display.json") }

    private func store<Value: Codable>(_ value: Value, named name: String, for expected: WidgetSession) throws {
        guard expected.isSignedIn, try session() == expected else { throw WidgetDataError.sessionChanged }
        try write(Envelope(generation: expected.generation, value: value), to: name)
    }

    private func load<Value: Codable>(_ name: String) throws -> Value? {
        guard let current = try session(), current.isSignedIn,
              let envelope: Envelope<Value> = try read(name),
              envelope.generation == current.generation else { return nil }
        return envelope.value
    }

    private func read<Value: Decodable>(_ name: String) throws -> Value? {
        let url = root.appending(path: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
    }

    private func write<Value: Encodable>(_ value: Value, to name: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: root.appending(path: name), options: .atomic)
    }

    private func removePayloads() throws {
        for name in ["activity.json", "display.json"] {
            let url = root.appending(path: name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
}

public enum WidgetDataError: Error { case sessionChanged }

public enum WidgetStorage {
    public static var isLocalPreview: Bool {
        Bundle.main.object(forInfoDictionaryKey: "InkletWidgetStorageMode") as? String == "local"
    }

    public static var rootURL: URL {
        // Ad-hoc previews cannot authorize a shared container. Each process
        // stays in its own Application Support directory in that build mode.
        let group = isLocalPreview ? nil : FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: inkletPresentationAppGroup)
        let base = group ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "inklet")
        return base.appending(path: "MacWidgets", directoryHint: .isDirectory)
    }
}
