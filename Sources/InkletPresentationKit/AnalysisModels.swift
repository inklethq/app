import Foundation

// MARK: - Contents (`/api/app/v1/contents`)

/// One Asset as the backend reports it back on a Content.
nonisolated public struct ContentAssetDTO: Codable, Sendable, Equatable {
    public var assetIndex: Int
    public var type: String
    public var text: String?
    public var url: String?
    public var filename: String?
    public var contentType: String?
    public var sizeBytes: Int?
    public var uploadState: String
}

/// A Content only tracks whether its Assets have arrived: `pending`, `ready`,
/// or `failed`. Processing lives on the Analyses that reference it.
nonisolated public struct ContentDTO: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String?
    public var state: String
    public var assets: [ContentAssetDTO]
    public var failedAssetIndexes: [Int]?
    public var analysisIds: [String]?
    public var presentationIds: [String]?
    public var failure: PresentationProblemDTO?
    public var createdAt: String
    public var updatedAt: String?
}

nonisolated public struct ContentPageDTO: Codable, Sendable {
    public var items: [ContentDTO]
    public var nextCursor: String?
    public var hasMore: Bool?
}

nonisolated public struct ContentUploadTicketDTO: Codable, Sendable, Equatable {
    public var assetIndex: Int
    public var url: String
    public var fields: [String: String]
    public var expiresAt: String?
}

nonisolated public struct CreatedContentDTO: Codable, Sendable {
    public var content: ContentDTO
    public var uploadTickets: [ContentUploadTicketDTO]
}

// MARK: - Analyses (`/api/app/v1/analyses`)

/// What the composer asked for. Mirrors the Portal's menu one to one.
nonisolated public enum ComposeAction: String, Sendable, CaseIterable, Identifiable {
    /// Save the material and stop. No run, no AI allowance spent.
    case upload
    /// One AI run over this note only.
    case card
    /// One AI run over this note plus the last week of uploads.
    case cardHistory = "card_history"
    /// `mode = direct`: the picture goes to the panel untouched, no AI.
    case asIs = "as_is"

    public var id: String { rawValue }

    public var usesAI: Bool { self == .card || self == .cardHistory }
    public var needsDisplay: Bool { self != .upload }

    /// How far back "using my recent notes" looks. Fixed, like the Portal's.
    public static let recentNotesWindow = "7d"
}

/// Where an Analysis should put its result.
nonisolated public enum AnalysisTargetSpec: Sendable, Equatable {
    /// `target: null` — the agent picks compatible Displays.
    case agent
    /// One pinned hardware Display.
    case display(String)
    /// Software-only Scene + PNG at this viewport (widgets, Virtual Displays).
    case output(width: Int, height: Int)
}

nonisolated public struct AnalysisScopeDTO: Codable, Sendable, Equatable {
    public var since: String
    public var sinceAt: String?
}

nonisolated public struct AnalysisDTO: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var mode: String
    public var trigger: String?
    public var state: String
    public var outcome: String?
    public var noChangeReason: String?
    public var contentIds: [String]
    public var context: String
    public var scope: AnalysisScopeDTO?
    public var intent: String?
    public var title: String?
    public var presentationIds: [String]
    public var failure: PresentationProblemDTO?
    public var createdAt: String
    public var updatedAt: String?

    public var isTerminal: Bool { state == "completed" || state == "failed" }
}

/// One public event on an Analysis timeline. `seq` is monotonic with holes;
/// it is a cursor, never a count.
nonisolated public struct AnalysisEventDTO: Codable, Sendable, Equatable, Identifiable {
    public var seq: Int
    public var at: String
    public var attempt: Int?
    public var source: String?
    public var type: String
    public var level: String?
    public var summary: String?
    public var data: [String: JSONValue]?

    public var id: Int { seq }

    /// One line for a status row. Uses the backend's own sentence, and builds
    /// one for `agent.activity`, which has none because its counters move.
    public var displayText: String {
        if let summary, !summary.isEmpty { return summary }
        guard type == "agent.activity", let data else { return type }
        let kind = data["kind"].flatMap(\.stringValue) ?? "working"
        let state = data["state"].flatMap(\.stringValue) ?? "active"
        let verb: String
        switch kind {
        case "reading_notes": verb = state == "done" ? "Read your notes" : "Reading your notes"
        case "checking_display": verb = state == "done" ? "Checked the display" : "Checking the display"
        case "choosing_layout": verb = state == "done" ? "Chose a layout" : "Looking at layouts"
        case "planning": verb = state == "done" ? "Submitted the plan" : "Checking the plan"
        default: verb = state == "done" ? "Worked through the steps" : "Working"
        }
        return state == "failed" ? "\(verb) — failed" : verb
    }
}

nonisolated public struct AnalysisEventPageDTO: Codable, Sendable {
    public var items: [AnalysisEventDTO]
    public var nextAfter: Int?
    public var hasMore: Bool?
    /// The Analysis state at the moment this page was read.
    public var state: String?
}

extension JSONValue {
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}
