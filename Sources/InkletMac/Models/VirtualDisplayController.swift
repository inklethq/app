import Foundation
import Combine
import WidgetKit
#if canImport(InkletPresentationKit)
import InkletPresentationKit
#endif

@MainActor
final class VirtualDisplayController: ObservableObject {
    typealias Transport = TargetlessClient.Transport
    @Published private(set) var displays: [VirtualDisplay] = []
    @Published private(set) var frames: [UUID: VirtualDisplayFrame] = [:]
    @Published private(set) var busy = false
    @Published var error: String?
    @Published private(set) var progress: String?
    private var generatedDrafts: [UUID: GeneratedPresentationDTO] = [:]
    private let transport: Transport
    private let store: VirtualDisplayStore
    private let transfer: TargetlessClient.Transfer
    private var session: VirtualDisplaySession?
    private var operation = UUID()
    init(store: VirtualDisplayStore = .init(), transfer: @escaping TargetlessClient.Transfer = TargetlessClient.transferRequest,
         transport: @escaping Transport) {
        self.store = store; self.transfer = transfer; self.transport = transport
    }

    func activate(accountID: String) {
        operation = UUID(); busy = false; generatedDrafts = [:]; progress = nil; error = nil; displays = []; frames = [:]; session = nil
        do {
            session = try store.activate(accountID: accountID)
            readCache()
        } catch { self.error = error.localizedDescription }
    }
    func signOut() {
        operation = UUID(); busy = false; generatedDrafts = [:]; progress = nil; session = nil; displays = []; frames = [:]; error = nil
        try? store.signOut(); reloadWidgets()
    }
    private func isCurrent(_ expected: VirtualDisplaySession) -> Bool {
        session == expected && (try? store.catalog()?.session) == expected
    }
    private func readCache() {
        guard let session, let catalog = try? store.catalog(), catalog.session == session else { return }
        displays = catalog.items.map(\.display)
        frames = displays.reduce(into: [:]) { result, display in
            result[display.id] = try? store.frame(display.id, session: session)
        }
        // Frame responses can be newer than the descriptor fetched at the start of a sync.
        displays = displays.map { display in
            if let frame = frames[display.id], frame.display.revision > display.revision { return frame.display }
            return display
        }
    }
    private func reloadWidgets() {
        WidgetCenter.shared.reloadTimelines(ofKind: "InkletPresentationWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "InkletExtraLargePresentationWidget")
    }
    private func request<T: Decodable>(_ type: T.Type, _ suffix: String = "", method: String = "GET", body: Data? = nil) async throws -> T {
        let data = try await transport("api/virtual-displays" + suffix, method, body, [:])
        return try JSONDecoder().decode(T.self, from: data)
    }
    func refresh() async {
        guard !busy, let expected = session else { return }
        busy = true; error = nil
        let op = UUID(); operation = op
        defer { if operation == op { busy = false } }
        do {
            struct List: Decodable { let items: [VirtualDisplay] }
            let result = try await request(List.self)
            guard isCurrent(expected) else { return }
            let old = try store.catalog()?.items ?? []
            var records: [VirtualDisplayRecord] = []
            var syncError: String?
            for display in result.items {
                guard isCurrent(expected) else { return }
                var access = old.first(where: { $0.display.id == display.id })?.access
                do { access = try await request(VirtualDisplayAccess.self, "/\(display.id)/widget-access", method: "POST") }
                catch { syncError = error.localizedDescription }
                records.append(.init(display: display, access: access))
            }
            guard isCurrent(expected), try store.replace(records, session: expected) else { return }
            for display in result.items {
                guard isCurrent(expected) else { return }
                do {
                    let frame = try await request(VirtualDisplayFrame.self, "/\(display.id)/frame")
                    guard frame.display.id == display.id else { throw VirtualDisplayError.message("Unexpected display response.") }
                    try store.save(frame, session: expected)
                } catch { syncError = error.localizedDescription }
            }
            guard isCurrent(expected) else { return }
            readCache(); reloadWidgets()
            if let syncError { error = "Some display updates couldn't sync. \(syncError)" }
        } catch {
            if isCurrent(expected) { self.error = error.localizedDescription }
        }
    }
    private func mutate(_ action: (VirtualDisplaySession) async throws -> Void) async -> Bool {
        guard !busy, let expected = session else { return false }
        busy = true; error = nil
        let op = UUID(); operation = op
        defer { if operation == op { busy = false } }
        do {
            try await action(expected)
            guard isCurrent(expected) else { return false }
            readCache(); reloadWidgets(); return true
        } catch {
            if isCurrent(expected) { self.error = error.localizedDescription }
            return false
        }
    }
    // The form retains this id when a timed-out create is retried.
    func create(id: UUID, name: String, profile: VirtualDisplaySizeProfile) async -> Bool {
        await mutate { expected in
            struct Input: Encodable { let id: UUID; let name: String; let sizeProfile: String }
            let display = try await request(VirtualDisplay.self, method: "POST", body: JSONEncoder().encode(Input(id: id, name: name, sizeProfile: profile.rawValue)))
            guard isCurrent(expected), display.id == id else { return }
            guard display.isCompatible(with: profile) else {
                throw VirtualDisplayError.message("The server did not register the selected display size. Refresh and try again.")
            }
            var records = try store.catalog()?.items ?? []
            records.removeAll { $0.display.id == id }; records.append(.init(display: display))
            try store.replace(records, session: expected)
            // Registration succeeds even if this optional credential fetch must be retried.
            if let access = try? await request(VirtualDisplayAccess.self, "/\(id)/widget-access", method: "POST"), isCurrent(expected) {
                records = try store.catalog()?.items ?? []
                if let index = records.firstIndex(where: { $0.display.id == id }) { records[index].access = access }
                try store.replace(records, session: expected)
            }
        }
    }
    func rename(id: UUID, name: String) async -> Bool {
        await mutate { expected in
            let display = try await request(VirtualDisplay.self, "/\(id)", method: "PUT", body: JSONEncoder().encode(["name": name]))
            guard isCurrent(expected), display.id == id else { return }
            var records = try store.catalog()?.items ?? []
            if let index = records.firstIndex(where: { $0.display.id == id }) { records[index].display = display }
            try store.replace(records, session: expected)
        }
    }
    func delete(id: UUID) async -> Bool {
        await mutate { expected in
            _ = try await transport("api/virtual-displays/\(id)", "DELETE", nil, [:])
            try store.remove(id, session: expected)
        }
    }
    private func publishFrame(id: UUID, frameID: UUID, baseRevision: Int64, image: Data, text: String,
                              presentation: GeneratedPresentationDTO?, expected: VirtualDisplaySession) async throws {
        guard isCurrent(expected) else { throw CancellationError() }
        struct Input: Encodable { let id: UUID; let baseRevision: Int64; let imageData: Data; let text: String }
        let input = Input(id: frameID, baseRevision: baseRevision, imageData: image, text: text)
        var frame = try await request(VirtualDisplayFrame.self, "/\(id)/frame", method: "PUT", body: JSONEncoder().encode(input))
        guard isCurrent(expected), frame.display.id == id else { throw CancellationError() }
        frame.presentation = presentation
        try store.save(frame, session: expected)
        var records = try store.catalog()?.items ?? []
        if let index = records.firstIndex(where: { $0.display.id == id }) { records[index].display = frame.display }
        try store.replace(records, session: expected)
    }
    private func generationRequest(_ path: String, method: String, body: Data?, headers: [String: String], expected: VirtualDisplaySession) async throws -> Data {
        guard isCurrent(expected) else { throw CancellationError() }
        let data = try await transport(path, method, body, headers)
        guard isCurrent(expected) else { throw CancellationError() }
        return data
    }
    func generateAndPublish(id: UUID, requestID: UUID, frameID: UUID, baseRevision: Int64,
                            assets: [PresentationAsset], mode: String, text: String) async -> Bool {
        await mutate { expected in
            guard let display = displays.first(where: { $0.id == id }) else {
                throw VirtualDisplayError.message("Choose an available Virtual Display first.")
            }
            let width = display.width * 2, height = display.height * 2
            progress = "Generating and rendering…"
            defer { if isCurrent(expected) { progress = nil } }
            let client = TargetlessClient(transport: { [self] path, method, body, headers in
                try await generationRequest(path, method: method, body: body, headers: headers, expected: expected)
            }, transfer: transfer)
            let generated: GeneratedPresentationDTO
            if let cached = generatedDrafts[requestID] { generated = cached }
            else {
                generated = try await client.generate(assets: assets, mode: mode, requestID: requestID, width: width, height: height)
                guard isCurrent(expected) else { throw CancellationError() }
                if generatedDrafts.count >= 10 { generatedDrafts.removeAll() }
                generatedDrafts[requestID] = generated
            }
            let (presentation, data) = try await client.download(generated, width: width, height: height)
            guard isCurrent(expected) else { throw CancellationError() }
            progress = "Publishing to \(display.name)…"
            // Normalize once to the virtual frame bounds and validate the downloaded image.
            let image = try VirtualDisplayRenderer.image(data, size: display.canvasSize)
            try await publishFrame(id: id, frameID: frameID, baseRevision: baseRevision, image: image, text: text,
                                   presentation: presentation, expected: expected)
            generatedDrafts.removeValue(forKey: requestID)
        }
    }
}
