import Foundation
import Observation
import InkletPresentationKit

/// The History page's data: the account's runs, newest first, and the event
/// timeline of whichever one is open.
///
/// Its own object rather than more fields on `AppModel`: the list pages on a
/// cursor the rest of the app has no use for, and an open run polls on its
/// own clock until it settles.
@MainActor
@Observable
final class HistoryModel {
    enum StateFilter: String, CaseIterable, Identifiable {
        case all, queued, running, completed, failed
        var id: Self { self }
        var label: String {
            switch self {
            case .all: "All"
            case .queued: "Queued"
            case .running: "Working"
            case .completed: "Done"
            case .failed: "Failed"
            }
        }
        var query: String? { self == .all ? nil : rawValue }
    }

    /// The only way a scheduled run is visible to the user. A daily summary
    /// used to appear on a screen with nothing anywhere to say where it came from.
    enum TriggerFilter: String, CaseIterable, Identifiable {
        case all, api, scheduled
        var id: Self { self }
        var label: String {
            switch self {
            case .all: "All"
            case .api: "You asked"
            case .scheduled: "Daily"
            }
        }
        var query: String? { self == .all ? nil : rawValue }
    }

    static let pageSize = 20

    var items: [AnalysisDTO] = []
    var stateFilter: StateFilter = .all
    var triggerFilter: TriggerFilter = .all
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasMore = false
    private(set) var error: String?
    private(set) var hasLoaded = false
    private var cursor: String?
    /// Bumped by every fresh load, so a slow page from before a filter change
    /// cannot land on top of the list that replaced it.
    private var generation = 0

    /// Events by run id, `seq` ascending, no duplicates.
    private(set) var events: [String: [AnalysisEventDTO]] = [:]
    private(set) var timelineErrors: [String: String] = [:]
    /// The run whose timeline is being polled right now, if any.
    private(set) var watching: String?

    /// A new account: nothing from the last one may show.
    func reset() {
        generation += 1
        items = []
        cursor = nil
        hasMore = false
        hasLoaded = false
        isLoading = false
        isLoadingMore = false
        error = nil
        events = [:]
        timelineErrors = [:]
    }

    func loadIfNeeded() async {
        guard !hasLoaded, !isLoading else { return }
        await load()
    }

    /// Part of the app-wide refresh — but only once the page has been opened,
    /// so an account that never looks at History never pays for it.
    func refreshIfLoaded() async {
        guard hasLoaded else { return }
        await load()
    }

    func load() async {
        generation += 1
        let expected = generation
        isLoading = true
        error = nil
        defer { if generation == expected { isLoading = false } }
        do {
            let page = try await InkletAPI.shared.analyses(
                state: stateFilter.query, trigger: triggerFilter.query, limit: Self.pageSize)
            guard generation == expected else { return }
            items = page.items
            cursor = page.nextCursor
            hasMore = page.hasMore ?? false
            hasLoaded = true
        } catch {
            guard generation == expected, !(error is CancellationError) else { return }
            self.error = Self.message(for: error)
        }
    }

    func loadMore() async {
        guard hasMore, let cursor, !isLoadingMore, !isLoading else { return }
        let expected = generation
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await InkletAPI.shared.analyses(
                state: stateFilter.query, trigger: triggerFilter.query, cursor: cursor, limit: Self.pageSize)
            guard generation == expected else { return }
            let known = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !known.contains($0.id) })
            self.cursor = page.nextCursor
            hasMore = (page.hasMore ?? false) && page.nextCursor != nil
        } catch {
            guard generation == expected, !(error is CancellationError) else { return }
            self.error = Self.message(for: error)
        }
    }

    func analysis(_ id: String) -> AnalysisDTO? {
        items.first { $0.id == id }
    }

    private func replace(_ analysis: AnalysisDTO) {
        if let index = items.firstIndex(where: { $0.id == analysis.id }) {
            items[index] = analysis
        }
    }

    private func append(_ fresh: [AnalysisEventDTO], to id: String) {
        var known = Set(events[id, default: []].map(\.seq))
        let new = fresh.filter { known.insert($0.seq).inserted }
        guard !new.isEmpty else { return }
        events[id] = (events[id, default: []] + new).sorted { $0.seq < $1.seq }
    }

    /// How long to keep watching after the run ends: render and delivery
    /// happen after the terminal state and never come with it. A run that is
    /// live when opened gets the longer window; one that had already finished
    /// still has a render that completed a moment ago to catch.
    private static let liveSettle: TimeInterval = 90
    private static let settledSettle: TimeInterval = 15

    /// Pages the run's events, then keeps polling while it is going and for a
    /// while after. Returns when the view goes away (cancellation) or when
    /// there is nothing more to wait for.
    func watch(_ id: String) async {
        watching = id
        defer { if watching == id { watching = nil } }

        let openedTerminal = analysis(id)?.isTerminal ?? false
        var after = events[id]?.last?.seq ?? 0
        var settleUntil: Date?
        var headerRefreshedAt = Date.now

        while !Task.isCancelled {
            var terminal = false
            do {
                var state: String?
                var hasMore = true
                var fresh: [AnalysisEventDTO] = []
                while hasMore {
                    let page = try await InkletAPI.shared.analysisEvents(id: id, after: after, limit: 200)
                    fresh.append(contentsOf: page.items)
                    for event in page.items { after = max(after, event.seq) }
                    if let next = page.nextAfter { after = max(after, next) }
                    hasMore = (page.hasMore ?? false) && !page.items.isEmpty
                    state = page.state ?? state
                }
                if Task.isCancelled { return }
                append(fresh, to: id)
                timelineErrors[id] = nil

                terminal = state == "completed" || state == "failed"
                let current = analysis(id)
                // The events say the run ended; the outcome lives on the
                // Analysis and nowhere else, so read it once more. And a run
                // still going gets its header re-read now and then, for the
                // state change that happened before the page opened.
                let stale = terminal ? (current.map { !$0.isTerminal } ?? false)
                                     : Date.now.timeIntervalSince(headerRefreshedAt) > 15
                if stale, let dto = try? await InkletAPI.shared.analysis(id: id) {
                    replace(dto)
                    headerRefreshedAt = .now
                }

                if terminal {
                    // Delivery is the last word; once the panel has answered
                    // there is nothing left to wait for.
                    if let last = fresh.last ?? events[id]?.last,
                       last.type == "delivery.confirmed" || last.type == "delivery.failed" || last.type == "render.failed" {
                        return
                    }
                    if settleUntil == nil {
                        settleUntil = .now + (openedTerminal ? Self.settledSettle : Self.liveSettle)
                    }
                    if let settleUntil, Date.now >= settleUntil { return }
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                timelineErrors[id] = Self.message(for: error)
            }
            do {
                try await Task.sleep(for: .seconds(terminal ? 5 : 2))
            } catch {
                return
            }
        }
    }

    private static func message(for error: Error) -> String {
        (error as? APIError)?.errorDescription ?? error.localizedDescription
    }
}
