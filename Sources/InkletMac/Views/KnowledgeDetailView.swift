import SwiftUI
import InkletPresentationKit

struct ContentAssetReading: Decodable, Sendable {
    let assetIndex: Int
    let text: String
    let summary: String?
    let status: String
    let nextOffset: Int?
    let downloadUrl: String?
}

/// A reading surface for saved material. It loads only the selected item.
struct KnowledgeDetailView: View {
    @Environment(AppModel.self) private var model
    let item: KnowledgeItem
    @State private var content: ContentDTO?
    @State private var loading = true
    @State private var error: String?

    private var title: String { content.map { KnowledgeItem(dto: $0).title ?? "Untitled" } ?? item.title ?? "Untitled" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(title).font(InkType.title).foregroundStyle(Ink.text).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    HStack(spacing: 20) {
                        Label(item.kind?.rawValue ?? "Saved item", systemImage: item.kind?.symbol ?? "doc")
                        Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    .font(.system(size: 13)).foregroundStyle(Ink.secondary)
                }
                if loading {
                    ProgressView("Opening item…").controlSize(.small)
                } else if let error {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(error).font(InkType.body).foregroundStyle(Ink.secondary)
                        Button("Try again") { Task { await load() } }
                    }
                } else if let content {
                    if let failure = content.failure {
                        Label(failure.message, systemImage: "exclamationmark.circle")
                            .font(.system(size: 14)).foregroundStyle(Ink.danger)
                    }
                    if content.assets.isEmpty {
                        Text("No content was saved in this item.").foregroundStyle(Ink.secondary)
                    }
                    ForEach(content.assets, id: \.assetIndex) { asset in
                        KnowledgeAssetView(contentID: content.id, asset: asset, showHeading: content.assets.count > 1)
                        if asset.assetIndex != content.assets.last?.assetIndex {
                            Rectangle().fill(Ink.cardRule).frame(height: 1)
                        }
                    }
                    if let ids = content.analysisIds, !ids.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionLabel("Related activity")
                            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                                Button("View activity \(index + 1)", systemImage: "arrow.up.right") { model.openRun(id) }
                                    .buttonStyle(.link).font(.system(size: 13))
                            }
                        }
                        .padding(.top, 8)
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 32).padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Ink.bg)
        .navigationTitle(title)
        .toolbar { ComposerToolbar() }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .task { await load() }
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let result = try await InkletAPI.shared.content(id: item.id)
            try Task.checkCancellation()
            content = result
        } catch is CancellationError {
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct KnowledgeAssetView: View {
    let contentID: String
    let asset: ContentAssetDTO
    let showHeading: Bool
    @State private var reading: ContentAssetReading?
    @State private var text = ""
    @State private var nextOffset: Int?
    @State private var loading = false
    @State private var failed = false

    private var source: URL? { Self.webURL(asset.url) }
    private var download: URL? { Self.webURL(reading?.downloadUrl) }
    private var bodyText: String { asset.type == "text" ? (asset.text ?? "") : text }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if showHeading {
                SectionLabel(asset.filename ?? (asset.type == "text" ? "Note" : asset.type.capitalized))
            }
            if asset.type == "link", let source {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "link").foregroundStyle(Ink.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(source.absoluteString).font(.system(size: 13)).foregroundStyle(Ink.secondary)
                            .textSelection(.enabled).lineLimit(3)
                        Link("Open original", destination: source).font(.system(size: 13, weight: .medium))
                    }
                    Spacer(minLength: 0)
                }
            }
            if asset.type == "image", let download {
                AsyncImage(url: download) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFit().frame(maxHeight: 480)
                    case .failure: Label("Image preview unavailable", systemImage: "photo").foregroundStyle(Ink.secondary)
                    default: ProgressView().frame(height: 120)
                    }
                }
                .frame(maxWidth: .infinity)
                .clipShape(.rect(cornerRadius: 8))
            }
            if asset.type == "file" || asset.type == "image" {
                HStack(spacing: 12) {
                    Image(systemName: asset.type == "image" ? "photo" : "doc")
                        .font(.system(size: 22)).foregroundStyle(Ink.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(asset.filename ?? "Attachment").font(.system(size: 14, weight: .medium))
                        if let size = asset.sizeBytes {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                        }
                    }
                    Spacer()
                    if let download { Link("Open original", destination: download).font(.system(size: 13)) }
                }
                .padding(16).background(Ink.card, in: .rect(cornerRadius: Ink.cardCorner))
            }
            if let summary = reading?.summary, !summary.isEmpty, asset.type != "text" {
                DisclosureGroup("Summary") {
                    Text(summary).font(.system(size: 14)).lineSpacing(5)
                        .textSelection(.enabled).padding(.top, 10)
                }
                .font(.system(size: 13)).foregroundStyle(Ink.secondary)
            }
            if !bodyText.isEmpty {
                Text(Self.formatted(bodyText)).font(InkType.body).lineSpacing(7)
                    .foregroundStyle(Ink.text).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if loading {
                ProgressView("Loading content…").controlSize(.small)
            } else if failed {
                HStack(spacing: 12) {
                    Text("Preview unavailable.").foregroundStyle(Ink.secondary)
                    Button("Try again") { Task { await load(offset: nextOffset ?? 0) } }
                }
                .font(.system(size: 13))
            } else if let offset = nextOffset {
                Button("Read more") { Task { await load(offset: offset) } }.font(.system(size: 13))
            } else if bodyText.isEmpty && reading != nil {
                Text(reading?.status == "pending" ? "The text is still being prepared." : "No readable text was found in this item.")
                    .font(.system(size: 14)).foregroundStyle(Ink.secondary)
            }
        }
        .task { if asset.type != "text" { await load(offset: 0) } }
    }

    private func load(offset: Int) async {
        loading = true
        failed = false
        defer { loading = false }
        do {
            let result = try await InkletAPI.shared.readContentAsset(contentID: contentID, index: asset.assetIndex, offset: offset)
            try Task.checkCancellation()
            if offset == 0 { reading = result; text = result.text } else { text += result.text }
            nextOffset = result.nextOffset
        } catch is CancellationError {
        } catch { failed = true }
    }

    private static func webURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host() != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    private static func formatted(_ value: String) -> AttributedString {
        (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value)
    }
}
