import SwiftUI

struct KnowledgeView: View {
    @Environment(AppModel.self) private var model
    @Binding var path: NavigationPath

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
        NavigationStack(path: $path) {
            VStack(alignment: .leading, spacing: 0) {
                masthead
                list
            }
            .background(Ink.bg)
            .navigationTitle("Knowledge")
            .toolbar { ComposerToolbar() }
            .toolbarBackground(.hidden, for: .windowToolbar)
            .navigationDestination(for: KnowledgeItem.self) { item in
                KnowledgeDetailView(item: item).id(item.id)
            }
        }
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
        VStack(alignment: .leading, spacing: 6) {
            Text("Knowledge").font(InkType.title).foregroundStyle(Ink.text)
            Text("Browse and read the things you’ve saved.")
                .font(.system(size: 13)).foregroundStyle(Ink.secondary)
        }
        .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 20)
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                InkSegmentedPicker(title: "Filter", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }

                Text("\(model.knowledge.count) saved items")
                    .font(InkType.metadata).foregroundStyle(Ink.muted)
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
                    InkItemList(items: items) { item in
                        KnowledgeRow(item: item) { path.append(item) }
                            .help("Read \(item.title ?? "item")")
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

private struct KnowledgeRow: View {
    let item: KnowledgeItem
    let open: () -> Void

    var body: some View {
        InkListRow(
            title: item.title ?? "Loading…",
            subtitle: item.detail ?? item.kind?.rawValue,
            titleColor: item.title == nil ? Ink.muted : Ink.text,
            action: open
        ) {
            Image(systemName: item.kind?.symbol ?? "square.stack")
        } metadata: {
            if item.processStatus == .failed || item.processStatus == .uploading {
                Text(item.processStatus.label)
                    .foregroundStyle(item.processStatus == .failed ? Ink.danger : Ink.secondary)
            }
            Text(relativeTime(item.createdAt))
                .frame(width: 96, alignment: .trailing)
        }
    }
}
