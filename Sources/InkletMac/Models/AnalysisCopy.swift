import Foundation
import InkletPresentationKit

// What an Analysis and its events say about themselves, in English.
//
// A port of the Portal's `analysis-copy.ts` and `analysis-timeline.ts`, so the
// two clients tell the same story about the same run. Everything is dispatched
// on codes and types — `failure.code`, `event.type`, `data.kind` — and the
// backend's prose is the last resort, never the first: `failure.message` is
// written in Chinese, and `summary` changes wording between versions while
// the codes do not. `noChangeReason` is the exception: it is free text the
// agent wrote about this particular run, and nothing could stand in for it.

extension AnalysisDTO {
    /// A heading for the row. `intent` before the generic line because it is
    /// the sentence the user actually typed; six identical "Summary of your
    /// recent notes" rows say nothing about which one to open.
    var historyTitle: String {
        if let title, !title.isEmpty { return AnalysisCopy.truncated(title, 90) }
        if let intent, !intent.isEmpty { return AnalysisCopy.truncated(intent, 90) }
        if mode == "direct" { return "Picture sent straight to a display" }
        if trigger == "scheduled" { return "Daily summary" }
        return context == "history" ? "Summary of your recent notes" : "Card from what you sent"
    }

    var stateLabel: String { AnalysisCopy.stateLabel(state) }

    /// `api` is "you asked for this"; `scheduled` is the nightly run.
    var triggerLabel: String { trigger == "scheduled" ? "Daily automatic" : "You asked" }

    var contextLabel: String {
        guard context == "history" else { return "Only what you sent" }
        guard let scope else { return "Your recent notes" }
        return "Your notes from the \(AnalysisCopy.scopeLabel(scope.since))"
    }

    /// Only `failed`. A `no_change` completion is the agent looking and having
    /// nothing to add, and a red row would say something went wrong.
    var isFailure: Bool { state == "failed" }

    var createdDate: Date? { InkletTime.parse(createdAt) }

    /// The state to show, from whichever of the two sources knows more. The
    /// Analysis wins once terminal — it alone carries the outcome. Before that
    /// the events win, and only ever forward: a run they show moving is never
    /// labelled "Queued" again.
    func liveState(events: [AnalysisEventDTO]) -> String {
        if isTerminal { return state }
        return AnalysisCopy.livePhase(events) == .unstarted ? state : "running"
    }

    /// The one line under the heading: what came of it, or what is happening.
    func resultLine(events: [AnalysisEventDTO] = []) -> String {
        switch liveState(events: events) {
        case "queued":
            // `context: "history"` runs one at a time per user, so this is not
            // the usual second-long queue.
            return context == "history"
                ? "Queued — these run one at a time, so it may wait a while"
                : "Queued"
        case "running":
            // A `direct` run has no agent and nothing to choose.
            return mode == "ai"
                ? "Working — the agent is reading your notes and choosing a card"
                : "Working on it"
        case "failed":
            return AnalysisCopy.failureText(code: failure?.code)
        case "completed":
            if outcome == "no_change" {
                if let noChangeReason, !noChangeReason.isEmpty { return noChangeReason }
                return "Nothing new worth showing"
            }
            let count = presentationIds.count
            if count == 0 { return "Finished" }
            return count == 1 ? "1 card" : "\(count) cards"
        default:
            return stateLabel
        }
    }
}

enum AnalysisCopy {
    static func stateLabel(_ state: String) -> String {
        switch state {
        case "queued": "Queued"
        case "running": "Working"
        case "completed": "Done"
        case "failed": "Failed"
        default: state
        }
    }

    /// `scope.since` is a relative duration such as `24h`, `7d`, `90m`.
    /// Anything unrecognised is echoed as written — it is still the window.
    static func scopeLabel(_ since: String) -> String {
        let trimmed = since.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [Character: (String, String)] = [
            "m": ("minute", "minutes"), "h": ("hour", "hours"), "d": ("day", "days"), "w": ("week", "weeks"),
        ]
        guard let unit = trimmed.last, let names = units[unit],
              let amount = Int(trimmed.dropLast().trimmingCharacters(in: .whitespaces)) else { return since }
        return "last \(amount) \(amount == 1 ? names.0 : names.1)"
    }

    /// Why a run failed, dispatched on the contract's closed set of codes.
    static func failureText(code: String?) -> String {
        switch code {
        case "no_compatible_display": "Connect a display first — there is nowhere to put this yet."
        case "display_incompatible": "That display cannot show what this produced."
        case "processing_unavailable": "Processing was not available. Nothing was lost — you can try again."
        case "invalid_asset": "One of the attachments could not be read."
        case "no_presentable_content": "There was nothing here that could go on a screen."
        case "upload_expired": "The upload window closed before the files arrived."
        case "no_ai_quota": "This run needed an AI summary you no longer have allowance for."
        default: "This run could not be finished."
        }
    }

    enum LivePhase: Equatable { case unstarted, working, ended }

    /// How far along the run is, according to its events. `analysis.leased`
    /// is a worker taking the run; anything the agent itself wrote is proof it
    /// is already past that — a late join replays the agent's work without
    /// replaying the lease, which is why this tests the source, not a type.
    static func livePhase(_ events: [AnalysisEventDTO]) -> LivePhase {
        var phase = LivePhase.unstarted
        for event in events {
            if event.type == "analysis.completed" || event.type == "analysis.failed" { return .ended }
            if event.type == "analysis.leased" || event.source == "agent" { phase = .working }
        }
        return phase
    }

    static func truncated(_ value: String, _ max: Int) -> String {
        let collapsed = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count <= max ? collapsed : String(collapsed.prefix(max - 1)) + "…"
    }

    static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}

// MARK: - Timeline

enum TimelineTone: Equatable { case info, warn, error }

/// Which glyph the row leads with — the same small set the Portal draws with.
enum TimelineIcon: String, Equatable {
    case alert = "exclamationmark.circle"
    case warn = "exclamationmark.triangle"
    case plan = "checkmark.circle"
    case render = "photo"
    case layout = "rectangle.3.group"
    case display = "display"
    case read = "doc.text"
    case agent = "cpu"
}

struct TimelineFact: Equatable {
    let label: String
    let value: String
    var tone: TimelineTone? = nil
}

struct TimelineRow: Identifiable, Equatable {
    /// Stable across an activity's updates, so the row changes rather than moves.
    let id: String
    let seq: Int
    let at: Date?
    /// The line the row leads with.
    let text: String
    /// The backend's own sentence, when it adds to the line above it.
    let note: String?
    let tone: TimelineTone
    let icon: TimelineIcon
    /// An activity that is still running: the row carries the live dot.
    let live: Bool
    /// `analysis.lease_expired` reads like the end and is not: the run starts
    /// again by itself.
    let transient: Bool
    let facts: [TimelineFact]
}

struct TimelineAttempt: Identifiable, Equatable {
    let attempt: Int
    var rows: [TimelineRow]
    var id: Int { attempt }
}

/// Turning the public event stream into something a person can read.
///
/// Two shapes of noise, and one thing done about each. **Repetition**: one
/// activity reports itself many times under a single `activityId` — throttled
/// `active` updates, then `done` or `failed`. It is one row that changes in
/// place, which `mergeActivities` does first. **Retries**: an attempt restarts
/// the whole agent loop, so the same activities appear again; without a
/// divider the timeline reads as if the agent were going in circles, so rows
/// are grouped by attempt.
///
/// `type` is closed by contract and read as if it were open: everything
/// degrades to `summary` and `level`, which every event carries, so a type
/// this build has never heard of renders as an ordinary row.
enum AnalysisTimeline {
    static func build(_ events: [AnalysisEventDTO], displayNames: [String: String] = [:]) -> [TimelineAttempt] {
        // `seq` is the identity: a reconnect replays events the page already
        // has, and a settling poll overlaps the last one by design.
        var seen = Set<Int>()
        let ordered = events.filter { seen.insert($0.seq).inserted }.sorted { $0.seq < $1.seq }
        var attempts: [TimelineAttempt] = []
        for event in mergeActivities(ordered) {
            let attempt = event.attempt ?? 1
            let row = toRow(event, displayNames: displayNames)
            if let last = attempts.indices.last, attempts[last].attempt == attempt {
                attempts[last].rows.append(row)
            } else {
                attempts.append(TimelineAttempt(attempt: attempt, rows: [row]))
            }
        }
        return attempts
    }

    /// Each activity keeps the place it first appeared and takes its latest
    /// report. Keyed by attempt as well: a retry's "Reading your notes" is a
    /// new row, not an update to the last attempt's.
    static func mergeActivities(_ events: [AnalysisEventDTO]) -> [AnalysisEventDTO] {
        var merged: [AnalysisEventDTO] = []
        var positions: [String: Int] = [:]
        for event in events {
            guard event.type == "agent.activity",
                  let activityID = event.data?["activityId"]?.stringValue, !activityID.isEmpty else {
                merged.append(event)
                continue
            }
            let key = "\(event.attempt ?? 0):\(activityID)"
            if let at = positions[key] {
                merged[at] = event
            } else {
                positions[key] = merged.count
                merged.append(event)
            }
        }
        return merged
    }

    /// The types this build can name. `agent.activity` and `plan.rejected` are
    /// absent on purpose: their line depends on counters, so it is derived.
    private static let typeLabels: [String: String] = [
        "analysis.created": "Analysis created",
        "analysis.dispatched": "Queued for a worker",
        "analysis.leased": "Picked up by a worker",
        "analysis.lease_expired": "The worker lost its lease",
        "analysis.completed": "Finished",
        "analysis.failed": "Failed",
        "context.materialized": "Material gathered",
        "plan.submitted": "Plan submitted",
        "plan.accepted": "Plan accepted",
        "render.finished": "Picture rendered",
        "render.failed": "Rendering failed",
        // Two different facts. Published is the backend's last word: the
        // picture is waiting in the panel's queue. Confirmed is the panel's,
        // and only arrives when it next syncs — hours, or never for a display
        // that is switched off.
        "delivery.published": "Sent to the display — it will show it when it next syncs",
        "delivery.confirmed": "Showing on the display",
        "delivery.failed": "Delivery failed",
    ]

    /// An English name for the event, or nil when this build does not know
    /// the type — then the backend's `summary` becomes the row's own heading.
    static func label(for event: AnalysisEventDTO, displayNames: [String: String]) -> String? {
        if event.type == "delivery.published",
           let displayID = event.data?["displayId"]?.stringValue, let name = displayNames[displayID] {
            return "Sent to \(name) — it will show it when it next syncs"
        }
        return typeLabels[event.type]
    }

    /// Render and delivery summaries are written for a log: "Sent result
    /// 01a0a5f6-… to display fb736fe4-…". The labels above say the same thing
    /// in the user's terms, so the summary is dropped rather than repeated.
    private static func summaryIsInternal(_ event: AnalysisEventDTO) -> Bool {
        event.type.hasPrefix("render.") || event.type.hasPrefix("delivery.")
    }

    // MARK: agent.activity

    /// The whole line for one activity row. `done` is the past tense, and it
    /// is not only `state == "done"` that earns it: a failed activity that
    /// counted a failed step did get that far — "Checked the display · 1 step
    /// failed", not "Checking the display · 1 step failed". The trailing
    /// "— failed" is only there when nothing else on the line has said so.
    static func activityText(_ data: [String: JSONValue]) -> String {
        let stats = data["stats"]?.objectValue ?? [:]
        let failedSteps = Int(stats["failedSteps"]?.numberValue ?? 0)
        let deniedSteps = Int(stats["deniedSteps"]?.numberValue ?? 0)
        var parts: [String] = []
        if failedSteps > 0 { parts.append("\(AnalysisCopy.plural(failedSteps, "step")) failed") }
        if deniedSteps > 0 { parts.append("\(AnalysisCopy.plural(deniedSteps, "step")) blocked") }
        let suffix = parts.isEmpty ? "" : ". " + parts.joined(separator: ", ")

        let state = data["state"]?.stringValue ?? "active"
        let failed = state == "failed"
        let done = state == "done" || (failed && !suffix.isEmpty)
        return activityBase(data, stats: stats, done: done) + suffix + (failed && suffix.isEmpty ? " — failed" : "")
    }

    private static func activityBase(_ data: [String: JSONValue], stats: [String: JSONValue], done: Bool) -> String {
        let kind = data["kind"]?.stringValue ?? "other"
        let steps = Int(data["steps"]?.numberValue ?? 0)
        switch kind {
        case "reading_brief":
            return done ? "Read the brief" : "Reading the brief"
        case "reading_notes":
            guard let read = stats["notesRead"]?.numberValue.map({ Int($0) }) else {
                return done ? "Read your notes" : "Reading your notes"
            }
            return done ? "Read \(AnalysisCopy.plural(read, "note"))" : "Reading your notes (\(read) read)"
        case "checking_display":
            return done ? "Checked the display" : "Checking the display"
        case "choosing_layout":
            let chosen = stats["chosen"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            guard let seen = stats["layoutsSeen"]?.numberValue.map({ Int($0) }) else {
                if let chosen { return "Chose \(chosen)" }
                return done ? "Looked at the layouts" : "Looking at layouts"
            }
            if done {
                let looked = "Looked at \(AnalysisCopy.plural(seen, "layout"))"
                return chosen.map { "\(looked), chose \($0)" } ?? looked
            }
            // A layout it has settled on outranks the running count: it is the
            // answer the activity exists to produce.
            return chosen.map { "Chose \($0)" } ?? "Looking at layouts (\(seen) so far)"
        case "submitting_plan":
            // "Checking" while it runs, because the backend is validating it
            // and it may yet come back; "Submitted" once it has gone through.
            return done ? "Submitted the plan" : "Checking the plan"
        case "retrying":
            return done ? "Tried another layout" : "Trying another layout"
        default:
            if steps <= 0 { return done ? "Worked through it" : "Working" }
            return done ? "Worked through \(AnalysisCopy.plural(steps, "step"))" : "Working through \(AnalysisCopy.plural(steps, "step"))"
        }
    }

    private static func activityIcon(kind: String) -> TimelineIcon {
        switch kind {
        case "reading_brief", "reading_notes": .read
        case "checking_display": .display
        case "choosing_layout": .layout
        case "submitting_plan": .plan
        // A retry is the one kind that is itself a warning sign.
        case "retrying": .warn
        default: .agent
        }
    }

    // MARK: plan.rejected

    /// Every one of these ends in "trying again" because that is the fact that
    /// matters: a rejected plan is not a failed run.
    static func planRejectedText(_ data: [String: JSONValue]) -> String {
        let reasons = [
            "target": "The plan aimed at the wrong display — trying again",
            "layout_mismatch": "The first layout didn't fit — trying another",
            "content_refs": "The plan missed some of your notes — trying again",
            "schema": "The layout details didn't validate — trying again",
        ]
        let reason = reasons[data["reason"]?.stringValue ?? ""] ?? "The plan was sent back — trying again"
        let problems = Int(data["problems"]?.numberValue ?? 0)
        return problems > 0 ? "\(reason) (\(AnalysisCopy.plural(problems, "problem")))" : reason
    }

    // MARK: Rows

    /// The `data` fields worth putting on screen: the ones that change what
    /// the timeline *means* — where a run is in the queue, what a plan asked
    /// for, why one failed.
    static func facts(for event: AnalysisEventDTO) -> [TimelineFact] {
        guard let data = event.data else { return [] }
        func text(_ key: String) -> String? {
            data[key]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        }
        func number(_ key: String) -> Int? { data[key]?.numberValue.map { Int($0) } }

        var facts: [TimelineFact] = []
        switch event.type {
        case "analysis.dispatched":
            if let position = number("position"), position > 0 { facts.append(.init(label: "In the queue", value: "#\(position)")) }
        case "plan.submitted":
            if let round = number("round") { facts.append(.init(label: "Round", value: String(round))) }
            if let outcome = text("outcome") { facts.append(.init(label: "Outcome", value: outcome)) }
            if let actions = number("actions") { facts.append(.init(label: "Actions", value: String(actions))) }
            if let code = text("code") { facts.append(.init(label: "Refused", value: code, tone: .warn)) }
        case "analysis.failed":
            if let code = text("code") { facts.append(.init(label: "Code", value: code, tone: .error)) }
            if let stage = text("stage") { facts.append(.init(label: "Stage", value: stage)) }
        case "delivery.published":
            // `queue` means it is behind something else, which is the answer
            // to "why has the screen not changed".
            if let placement = text("placement") {
                facts.append(.init(label: "Placement", value: placement == "queue" ? "queued behind what is showing" : "shown now"))
            }
        case "context.materialized":
            if let warnings = number("warnings"), warnings > 0 {
                facts.append(.init(label: "Degraded", value: AnalysisCopy.plural(warnings, "warning"), tone: .warn))
            }
        default:
            break
        }
        return facts
    }

    private static func tone(level: String?) -> TimelineTone {
        switch level {
        case "error": .error
        case "warn": .warn
        default: .info
        }
    }

    private static func icon(for event: AnalysisEventDTO, tone: TimelineTone) -> TimelineIcon {
        if tone == .error { return .alert }
        if event.type == "agent.activity" {
            return tone == .warn ? .warn : activityIcon(kind: event.data?["kind"]?.stringValue ?? "other")
        }
        if tone == .warn { return .warn }
        if event.type.hasPrefix("plan.") { return .plan }
        if event.type.hasPrefix("render.") { return .render }
        if event.type.hasPrefix("delivery.") { return .display }
        if event.type == "context.materialized" { return .read }
        return .agent
    }

    static func toRow(_ event: AnalysisEventDTO, displayNames: [String: String]) -> TimelineRow {
        let at = InkletTime.parse(event.at)
        let level = tone(level: event.level)

        if event.type == "agent.activity", let data = event.data {
            let activityID = data["activityId"]?.stringValue ?? ""
            let kind = data["kind"]?.stringValue ?? "other"
            let state = data["state"]?.stringValue ?? "active"
            // A failed activity, and every retry, wears the warn colour — the
            // backend sets `level` for denied and failed steps but says
            // nothing about either of these.
            let rowTone: TimelineTone = level == .error ? .error : (state == "failed" || kind == "retrying") ? .warn : level
            return TimelineRow(
                // Keyed by the activity, not by `seq`: the row is meant to
                // change in place as the activity reports itself again.
                id: activityID.isEmpty ? "event-\(event.seq)" : "activity-\(event.attempt ?? 0)-\(activityID)",
                seq: event.seq, at: at, text: activityText(data),
                // The backend's own sentence for these says the same thing in
                // different words. One line, not two.
                note: nil, tone: rowTone, icon: icon(for: event, tone: rowTone),
                live: state == "active", transient: false, facts: [])
        }

        if event.type == "plan.rejected", let data = event.data {
            let rowTone: TimelineTone = level == .error ? .error : .warn
            return TimelineRow(id: "event-\(event.seq)", seq: event.seq, at: at, text: planRejectedText(data),
                               note: nil, tone: rowTone, icon: icon(for: event, tone: rowTone),
                               live: false, transient: false, facts: [])
        }

        let label = label(for: event, displayNames: displayNames)
        let summary = event.summary.flatMap { $0.isEmpty ? nil : $0 }
        return TimelineRow(
            id: "event-\(event.seq)", seq: event.seq, at: at,
            // An unknown type has no label, so the summary becomes the heading
            // rather than a second line under nothing.
            text: label ?? summary ?? event.type,
            note: label != nil && !summaryIsInternal(event) ? summary : nil,
            tone: level, icon: icon(for: event, tone: level),
            live: false, transient: event.type == "analysis.lease_expired", facts: facts(for: event))
    }
}
