import SwiftUI
import InkletPresentationKit

/// Every run inklet has made for the account — the ones the user asked for and
/// the daily ones they did not — and, for any one of them, what happened.
///
/// The same page as the web Portal's Analyses, in two levels: the list, and a
/// run's timeline in a native navigation stack. The list retains its filters
/// while the system supplies the toolbar-level back navigation.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Binding var path: NavigationPath

    var body: some View {
        @Bindable var history = model.history
        NavigationStack(path: $path) {
            VStack(alignment: .leading, spacing: 0) {
                masthead
                filters($history)
                list(history)
            }
            .background(Ink.bg)
            .navigationTitle("History")
            .toolbar { ComposerToolbar() }
            .navigationDestination(for: String.self) { id in
                Group {
                    if let analysis = history.analysis(id) {
                        HistoryDetail(analysis: analysis, history: history, displayNames: displayNames)
                    } else {
                        opening(history)
                    }
                }
                .background(Ink.bg)
                .navigationTitle(history.analysis(id)?.historyTitle ?? "Activity")
                .toolbar { ComposerToolbar() }
                .toolbarBackground(.hidden, for: .windowToolbar)
                .task(id: id) { await history.ensure(id) }
            }
        }
        .task { await model.history.loadIfNeeded() }
        .onChange(of: history.requestedOpenID, initial: true) { _, id in
            guard let id else { return }
            path = NavigationPath([id])
            model.history.requestedOpenID = nil
        }
        .onChange(of: history.stateFilter) { _, _ in Task { await model.history.load() } }
        .onChange(of: history.triggerFilter) { _, _ in Task { await model.history.load() } }
    }

    /// The detail's frame while the run it was asked for is still being read.
    private func opening(_ history: HistoryModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(history.openError ?? "Loading…")
                .font(.system(size: 13))
                .foregroundStyle(history.openError == nil ? Ink.muted : Ink.danger)
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
    }

    /// The delivery rows name the panel the user named, when the account's
    /// displays are loaded. Until then they say "the display", which is true.
    private var displayNames: [String: String] {
        Dictionary(model.devices.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("History")
                .font(.brand(34))
                .foregroundStyle(Ink.text)
            Text("Review your creations and display updates.")
                .font(.system(size: 13))
                .foregroundStyle(Ink.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 20)
    }

    private func filters(_ history: Bindable<HistoryModel>) -> some View {
        HStack(spacing: 16) {
            filterControls(history)

            Spacer(minLength: 0)

            if history.wrappedValue.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await model.history.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Ink.secondary)
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private func filterControls(_ history: Bindable<HistoryModel>) -> some View {
        InkSegmentedPicker(title: "State", selection: history.stateFilter, showsLabel: true) {
            ForEach(HistoryModel.StateFilter.allCases) { Text($0.label).tag($0) }
        }
        InkSegmentedPicker(title: "Started by", selection: history.triggerFilter, showsLabel: true) {
            ForEach(HistoryModel.TriggerFilter.allCases) { Text($0.label).tag($0) }
        }
    }

    @ViewBuilder
    private func list(_ history: HistoryModel) -> some View {
        if history.items.isEmpty {
            Spacer()
            Text(emptyMessage(history))
                .font(.system(size: 13))
                .foregroundStyle(history.error == nil ? Ink.muted : Ink.danger)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
            Spacer()
        } else {
            ScrollView {
                VStack(spacing: 14) {
                    InkItemList(items: history.items) { analysis in
                        HistoryRow(analysis: analysis) { path.append(analysis.id) }
                    }
                    if history.hasMore {
                        Button {
                            Task { await model.history.loadMore() }
                        } label: {
                            if history.isLoadingMore {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Load more")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(history.isLoadingMore)
                    }
                    if let error = history.error {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(Ink.danger)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.never)
        }
    }

    private func emptyMessage(_ history: HistoryModel) -> String {
        if let error = history.error { return error }
        if history.isLoading || !history.hasLoaded { return "Loading…" }
        if history.stateFilter != .all || history.triggerFilter != .all { return "No runs match these filters." }
        return "No runs yet. Send something with Push to device and it will show up here."
    }
}

private struct HistoryRow: View {
    let analysis: AnalysisDTO
    let open: () -> Void

    var body: some View {
        InkListRow(
            title: analysis.historyTitle,
            subtitle: analysis.resultLine(),
            subtitleColor: analysis.isFailure ? Ink.danger : Ink.muted,
            action: open
        ) {
            StateMark(state: analysis.state)
        } metadata: {
            Text(analysis.stateLabel)
                .foregroundStyle(analysis.isTerminal ? Ink.secondary : Ink.text)
            Text(historyWhen(analysis.createdDate))
                .frame(width: 96, alignment: .trailing)
        }
    }
}

/// The dot beside a row. `completed` is one colour whatever the outcome: a
/// `no_change` run finished exactly as it was meant to, and marking it like a
/// failure would be a lie told in colour. Queued is hollow.
private struct StateMark: View {
    let state: String

    var body: some View {
        Group {
            switch state {
            case "failed": Circle().fill(Ink.danger)
            case "completed": Circle().fill(Ink.online)
            case "running": Circle().fill(Ink.working)
            default: Circle().strokeBorder(Ink.muted, lineWidth: 1.5)
            }
        }
        .frame(width: 8, height: 8)
        .accessibilityLabel(AnalysisCopy.stateLabel(state))
    }
}

// MARK: - Detail

private struct HistoryDetail: View {
    let analysis: AnalysisDTO
    let history: HistoryModel
    let displayNames: [String: String]
    @State private var showDetails = false

    private var events: [AnalysisEventDTO] { history.events[analysis.id] ?? [] }
    private var attempts: [TimelineAttempt] { AnalysisTimeline.build(events, displayNames: displayNames) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    timeline
                }
                .padding(.horizontal, 28)
                .padding(.top, 26)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.never)
        }
        // Cancelled when the detail goes away, which is what stops the polling.
        .task(id: analysis.id) { await history.watch(analysis.id) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StateMark(state: analysis.liveState(events: events))
                Text(AnalysisCopy.stateLabel(analysis.liveState(events: events))).font(.system(size: 13)).foregroundStyle(Ink.secondary)
            }
            Text(analysis.historyTitle)
                .font(.brand(28))
                .foregroundStyle(Ink.text)
                .lineLimit(2)
            Text(analysis.resultLine(events: events))
                .font(.system(size: 13))
                .foregroundStyle(analysis.isFailure ? Ink.danger : Ink.secondary)
            HStack(spacing: 18) {
                meta("Started by", analysis.triggerLabel)
                meta("Looked at", analysis.contextLabel)
                meta("When", historyWhen(analysis.createdDate))
            }
            .padding(.top, 12)
        }
    }

    private func meta(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 12)).foregroundStyle(Ink.secondary)
            Text(value).font(.system(size: 13)).foregroundStyle(Ink.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timeline: some View {
        InkCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SectionLabel("Timeline")
                    Spacer()
                    statusLine
                    Toggle("Show details", isOn: $showDetails)
                        .toggleStyle(.checkbox).font(.system(size: 12))
                        .padding(.leading, 12)
                }
                .padding(.bottom, 6)

                if attempts.isEmpty {
                    Text(history.timelineErrors[analysis.id] ?? "Loading…")
                        .font(.system(size: 13))
                        .foregroundStyle(history.timelineErrors[analysis.id] == nil ? Ink.muted : Ink.danger)
                        .padding(.vertical, 8)
                } else {
                    ForEach(attempts) { attempt in
                        if attempts.count > 1 {
                            attemptDivider(attempt.attempt)
                        }
                        ForEach(attempt.rows) { row in
                            TimelineRowView(row: row, showDetails: showDetails)
                        }
                    }
                    if let error = history.timelineErrors[analysis.id] {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(Ink.danger)
                            .padding(.top, 8)
                    }
                }
            }
        }
    }

    /// What the page is doing about new events, in the user's words.
    @ViewBuilder
    private var statusLine: some View {
        let live = analysis.liveState(events: events)
        HStack(spacing: 6) {
            if history.watching == analysis.id && !analysis.isTerminal {
                Circle().fill(Ink.online).frame(width: 6, height: 6)
                Text("Live")
            } else if history.watching == analysis.id {
                // `analysis.completed` has arrived and the timeline is not done:
                // rendering and delivery happen after the run is terminal.
                Text("Finishing up — rendering and sending to the display")
            } else if live == "queued" || live == "running" {
                Text("Checking every few seconds")
            } else {
                Text("Up to date")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Ink.muted)
    }

    private func attemptDivider(_ attempt: Int) -> some View {
        HStack(spacing: 8) {
            Text("Attempt \(attempt)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Ink.muted)
            Rectangle().fill(Ink.cardRule).frame(height: 1)
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

private struct TimelineRowView: View {
    let row: TimelineRow
    var showDetails = false

    private var color: Color {
        switch row.tone {
        case .info: Ink.text
        case .warn: Ink.warn
        case .error: Ink.danger
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: row.icon.rawValue)
                .font(.system(size: 12))
                .foregroundStyle(color)
                .frame(width: 16)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.text)
                        .font(.system(size: 14))
                        .foregroundStyle(color)
                    if row.live {
                        Circle().fill(Ink.online).frame(width: 6, height: 6)
                    }
                }
                if let note = row.note, showDetails || row.tone != .info {
                    Text(note)
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.muted)
                }
                if row.transient {
                    // Two of these followed by another lease means "retried
                    // twice, still going" — not "this run is over".
                    Text("This attempt stopped here; the run starts again by itself.")
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.muted)
                }
                if showDetails && !row.facts.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(row.facts, id: \.label) { fact in
                            (Text("\(fact.label): ").foregroundStyle(factColor(fact.tone))
                             + Text(fact.value).foregroundStyle(Ink.secondary))
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .textSelection(.enabled)

            Spacer(minLength: 8)

            Text(historyClock(row.at))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Ink.muted)
                .help(historyInstant(row.at))
                .padding(.top, 1)
        }
        .padding(.vertical, 7)
    }

    private func factColor(_ tone: TimelineTone?) -> Color {
        switch tone {
        case .warn: Ink.warn
        case .error: Ink.danger
        default: Ink.muted
        }
    }
}

// MARK: - Time

/// "Sep 20, 10:42" — day and clock, for a list.
func historyWhen(_ date: Date?) -> String {
    guard let date else { return "—" }
    return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
}

/// "10:42:03" — the row itself only has room for a clock.
func historyClock(_ date: Date?) -> String {
    guard let date else { return "" }
    return date.formatted(.dateTime.hour().minute().second())
}

/// The whole instant, for the hover.
func historyInstant(_ date: Date?) -> String {
    guard let date else { return "" }
    return date.formatted(date: .abbreviated, time: .standard)
}
