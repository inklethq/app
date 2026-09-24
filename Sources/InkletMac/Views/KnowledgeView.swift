import SwiftUI

struct KnowledgeView: View {
    @Environment(AppModel.self) private var model

    enum Filter: String, CaseIterable, Identifiable {
        case organized = "Organized"
        case pending = "Pending"
        var id: Self { self }
    }

    @State private var filter: Filter = .organized
    @State private var query = ""
    /// Server results for the settled query; nil while the box is empty.
    @State private var results: [KnowledgeItem]?
    @State private var resultsTruncated = false
    @State private var isSearching = false
    @State private var searchError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            masthead
            list
        }
        .background(Ink.bg)
        .navigationTitle("Knowledge")
        // Settle for a moment, then ask the backend: it searches the whole
        // library — titles, note text, links, filenames, and what the ingest
        // worker read out of images and files — not just what is loaded here.
        .task(id: query.trimmingCharacters(in: .whitespacesAndNewlines)) {
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { results = nil; resultsTruncated = false; searchError = nil; isSearching = false; return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            isSearching = true
            defer { isSearching = false }
            do {
                let found = try await model.searchKnowledge(needle)
                guard !Task.isCancelled else { return }
                results = found.items
                resultsTruncated = found.hasMore
                searchError = nil
            } catch is CancellationError {
            } catch {
                searchError = (error as? APIError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private var masthead: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Your second brain")
                Text("Knowledge")
                    .font(.brand(34))
                    .foregroundStyle(Ink.text)
            }
            Spacer(minLength: 20)
            HStack(spacing: 22) {
                stat("\(model.knowledge.count)", "items")
                stat("\(organizedCount)", "organized")
                stat("\(model.knowledge.count - organizedCount)", "pending")
            }
            .padding(.bottom, 4)
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 20)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value)
                .font(.brand(19))
                .foregroundStyle(Ink.text)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Ink.muted)
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Back to the tinted SwiftUI picker: the AppKit control keeps its
                // glass but paints the selection with the system accent, and blue
                // is worse here than losing the material.
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer()

                InkSearchField(text: $query, placeholder: "Search knowledge")
                    .frame(width: 240)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 14)

            if let searchError {
                Spacer()
                Text(searchError)
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.danger)
                Spacer()
            } else if items.isEmpty {
                Spacer()
                Text(emptyMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.muted)
                Spacer()
            } else {
                ScrollView {
                    InkCard(padding: 0) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                KnowledgeRow(item: item, showsDivider: index < items.count - 1)
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, resultsTruncated ? 8 : 24)
                    if resultsTruncated {
                        Text("Showing the first 50 matches. Narrow the search to see the rest.")
                            .font(.system(size: 12))
                            .foregroundStyle(Ink.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 24)
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var organizedCount: Int {
        model.knowledge.filter { $0.processStatus == .ready }.count
    }

    private var emptyMessage: String {
        if isSearching || (results == nil && !query.trimmingCharacters(in: .whitespaces).isEmpty) { return "Searching…" }
        if model.isLoading { return "Loading…" }
        if !query.isEmpty { return "Nothing matches “\(query.trimmingCharacters(in: .whitespaces))”." }
        return filter == .organized
            ? "Nothing organized yet — new items land in Pending first."
            : "Nothing pending. Everything you've sent has been processed."
    }

    private var items: [KnowledgeItem] {
        (results ?? model.knowledge)
            .filter { filter == .organized ? $0.processStatus == .ready : $0.processStatus != .ready }
            .sorted { $0.createdAt > $1.createdAt }
    }
}

/// Fixed-height row so the list keeps an even rhythm regardless of subtitle.
private struct KnowledgeRow: View {
    let item: KnowledgeItem
    let showsDivider: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: item.kind?.symbol ?? "square.stack")
                    .font(.system(size: 14))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    // The title arrives with a second request, so an unresolved
                    // row shows a placeholder rather than collapsing in height.
                    Text(item.title ?? "Loading…")
                        .font(.system(size: 14))
                        .foregroundStyle(item.title == nil ? Ink.muted : Ink.text)
                        .lineLimit(1)
                    Text(item.detail ?? item.kind?.rawValue ?? " ")
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(item.processStatus.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(item.processStatus == .ready ? Ink.muted : Ink.text)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Ink.input, in: .rect(cornerRadius: 5))

                Text(relativeTime(item.createdAt))
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.muted)
                    .frame(width: 62, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .frame(height: 58)
            .contentShape(.rect)

            if showsDivider {
                Rectangle().fill(Ink.cardRule).frame(height: 1)
            }
        }
    }
}
