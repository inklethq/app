import AppKit
import Foundation
import Observation
import InkletPresentationKit
import WidgetKit

@MainActor
@Observable
final class AppModel {
    let virtualDisplays: VirtualDisplayController
    init() {
        virtualDisplays = VirtualDisplayController { path, method, body, headers in
            try await InkletAPI.shared.virtualDisplayRequest(path, method: method, body: body, headers: headers)
        }
    }
    var account = Account(username: "", email: "", plan: "free")
    var devices: [Device] = []
    var pushes: [String: [Push]] = [:]      // deviceID → history, newest first
    var knowledge: [KnowledgeItem] = []
    var activityByDay: [Date: Int] = [:]
    private(set) var virtualDisplay: CachedPresentationSnapshot?
    private var widgetSession: WidgetSession?
    private let widgetStore = WidgetDataStore()

    var composerVirtualTargetID: UUID?
    var composerTarget: Device?             // set when pushing from a device page

    /// What was in front when the composer was summoned. Offered as a grey
    /// suggestion — never written into the field on its own.
    var suggestion: Capture?

    /// Bumped on every summon. The panel's view isn't recreated between
    /// appearances — the window is just ordered out — so `onAppear` fires once
    /// and can't be what puts the caret back in the field.
    private(set) var composerFocusToken = 0

    /// True until the first load settles, so views can tell "empty" from "not
    /// loaded yet" — an empty account and a failed fetch look identical otherwise.
    var isLoading = true
    var loadError: String?
    var isRefreshing = false

    /// Rendered previews, keyed by push id. Presigned URLs expire, the decoded
    /// image doesn't, so the image is what gets cached.
    private(set) var previews: [String: NSImage] = [:]
    private var previewTasks: Set<String> = []

    private var session: Session?
    private var accountGeneration = UUID()
    private var knowledgeDetailTasks: Set<String> = []

    func attach(session: Session) {
        self.session = session
        accountGeneration = UUID()
        if let user = session.user {
            virtualDisplays.activate(accountID: user.id)
            account = Account(dto: user)
            widgetSession = nil
            virtualDisplay = nil
            do {
                widgetSession = try widgetStore.activate(accountID: user.id)
                reloadVirtualDisplay()
                WidgetCenter.shared.reloadAllTimelines()
            } catch {
                loadError = "Couldn't share data with your desktop widgets."
            }
        }
    }

    func reset() {
        virtualDisplays.signOut()
        accountGeneration = UUID()
        widgetSession = nil
        virtualDisplay = nil
        try? widgetStore.signOut()
        // Remove the pre-account-scoped cache left by early development builds.
        if !WidgetStorage.isLocalPreview { try? PresentationCache().clear() }
        WidgetCenter.shared.reloadAllTimelines()
        account = Account(username: "", email: "", plan: "free")
        suggestion = nil
        composerTarget = nil
        composerVirtualTargetID = nil
        devices = []
        pushes = [:]
        knowledge = []
        activityByDay = [:]
        previews = [:]
        previewTasks = []
        knowledgeDetailTasks = []
        loadError = nil
        isLoading = true
    }

    // MARK: - Loading

    func load() async {
        isLoading = true
        loadError = nil
        await loadEverything()
        isLoading = false
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await loadEverything()
    }

    /// Both halves are main-actor bound, so this isn't parallelism — it just
    /// lets the second request go out while the first is waiting on the network.
    private func loadEverything() async {
        async let virtuals: Void = virtualDisplays.refresh()
        async let devices: Void = loadDevices()
        async let knowledge: Void = loadKnowledge()
        _ = await (devices, knowledge, virtuals)
    }

    private func loadDevices() async {
        do {
            let fetched = try await InkletAPI.shared.devices().map(Device.init(dto:))
            devices = fetched
            loadError = nil
            for device in fetched {
                loadPreview(for: device)
            }
        } catch {
            await handle(error)
        }
    }

    /// Pulls enough pages to cover the heatmap window, then fills in titles for
    /// the rows the list actually shows.
    private func loadKnowledge() async {
        let expectedGeneration = accountGeneration
        let window = Calendar.current.date(byAdding: .day, value: -7 * 26, to: .now) ?? .now
        var collected: [KnowledgeItem] = []
        var seenIDs: Set<String> = []
        var page = 1

        do {
            while true {
                try Task.checkCancellation()
                let result = try await InkletAPI.shared.rawItems(page: page, limit: 50)
                guard accountGeneration == expectedGeneration else { return }
                let newItems = result.items.filter { seenIDs.insert($0.id).inserted }
                // A repeated page must not loop forever or publish an incomplete
                // season. Retain the previous widget snapshot on this failure.
                if !result.items.isEmpty && newItems.isEmpty { throw APIError.decoding }
                collected.append(contentsOf: newItems.map(KnowledgeItem.init(dto:)))
                if result.items.count < 50 { break }
                if let total = result.total, collected.count >= total { break }
                if let oldest = collected.last?.createdAt, oldest < window { break }
                page += 1
            }
        } catch {
            guard accountGeneration == expectedGeneration else { return }
            await handle(error)
            return
        }

        guard accountGeneration == expectedGeneration, session?.user != nil else { return }
        // Keep whatever titles a previous pass already resolved.
        let existing = Dictionary(knowledge.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        knowledge = collected.map { item in
            guard let known = existing[item.id], known.title != nil else { return item }
            var merged = item
            merged.title = known.title
            merged.detail = known.detail
            merged.kind = known.kind
            return merged
        }

        rebuildActivity()
        hydrateTitles(limit: 40)
    }

    private func rebuildActivity() {
        let calendar = Calendar.current
        var counts: [Date: Int] = [:]
        for item in knowledge {
            let day = calendar.startOfDay(for: item.createdAt)
            counts[day, default: 0] += 1
        }
        activityByDay = counts
        if let widgetSession {
            do {
                try widgetStore.storeActivity(ActivitySnapshot(counts: counts), for: widgetSession)
                WidgetCenter.shared.reloadTimelines(ofKind: inkletActivityWidgetKind)
            } catch {
                loadError = "Couldn't update the Activity widget."
            }
        }
    }

    /// The list endpoint selects columns and leaves `content` out, so a title
    /// needs a per-item fetch. Bounded and de-duplicated: only the rows near the
    /// top of the list, only once each.
    private func hydrateTitles(limit: Int) {
        let pending = knowledge.prefix(limit).filter { $0.title == nil && !knowledgeDetailTasks.contains($0.id) }
        guard !pending.isEmpty else { return }
        pending.forEach { knowledgeDetailTasks.insert($0.id) }

        Task { @MainActor in
            await withTaskGroup(of: (String, BundleContentDTO?).self) { group in
                var iterator = pending.makeIterator()

                func addNext() {
                    guard let item = iterator.next() else { return }
                    group.addTask {
                        guard let dto = try? await InkletAPI.shared.rawItem(item.id),
                              let raw = dto.content?.data(using: .utf8),
                              let content = try? JSONDecoder().decode(BundleContentDTO.self, from: raw)
                        else { return (item.id, nil) }
                        return (item.id, content)
                    }
                }

                // Six in flight at a time: fills the visible list quickly without
                // opening forty sockets at launch. Each completion starts one more.
                for _ in 0..<min(6, pending.count) { addNext() }

                while let (id, content) = await group.next() {
                    if let content, let index = knowledge.firstIndex(where: { $0.id == id }) {
                        knowledge[index].apply(content: content)
                    }
                    addNext()
                }
            }
        }
    }

    func loadMoreKnowledgeTitles() {
        hydrateTitles(limit: knowledge.count)
    }

    // MARK: - Device detail

    func history(for device: Device) -> [Push] { pushes[device.id] ?? [] }

    func device(withID id: String) -> Device? { devices.first { $0.id == id } }

    func loadHistory(for device: Device) async {
        do {
            let page = try await InkletAPI.shared.pushes(deviceID: device.id, limit: 30)
            pushes[device.id] = page.items.map(Push.init(dto:))
        } catch APIError.noPush {
            pushes[device.id] = []
        } catch {
            await handle(error)
        }
    }

    func preview(for device: Device) -> NSImage? {
        guard let pushID = device.latestPushID else { return nil }
        return previews[pushID]
    }

    /// Fetches the presigned PNG for whatever the display is currently showing.
    /// Uses the by-id endpoint, which is a pure read — the plain `/push` route
    /// promotes the next queued item as a side effect.
    func loadPreview(for device: Device) {
        guard let pushID = device.latestPushID,
              previews[pushID] == nil,
              !previewTasks.contains(pushID) else { return }
        previewTasks.insert(pushID)

        Task { @MainActor in
            defer { previewTasks.remove(pushID) }
            do {
                let info = try await InkletAPI.shared.pushImage(deviceID: device.id, pushID: pushID)
                guard let url = URL(string: info.url) else { return }
                let data = try await InkletAPI.shared.fetchData(from: url)
                if let image = NSImage(data: data) { previews[pushID] = image }
            } catch {
                // A missing preview is not worth an error banner — the frame
                // falls back to its empty state.
            }
        }
    }

    // MARK: - Mutations

    func rename(_ device: Device, to nickname: String) async {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        let previous = devices[index].nickname
        devices[index].nickname = trimmed.isEmpty ? nil : trimmed

        do {
            try await InkletAPI.shared.setNickname(deviceID: device.id, nickname: trimmed)
        } catch {
            devices[index].nickname = previous
            await handle(error)
        }
    }

    func unbind(_ device: Device) async {
        do {
            try await InkletAPI.shared.unbind(deviceID: device.id)
            devices.removeAll { $0.id == device.id }
            pushes[device.id] = nil
        } catch {
            await handle(error)
        }
    }

    /// Advances a display to the next queued push and re-reads its state.
    func showNext(_ device: Device) async throws {
        _ = try await InkletAPI.shared.advanceQueue(deviceID: device.id)
        await reloadDevice(device.id)
        if let updated = self.device(withID: device.id) {
            await loadHistory(for: updated)
        }
    }

    func reloadDevice(_ id: String) async {
        guard let dto = try? await InkletAPI.shared.device(id) else { return }
        let device = Device(dto: dto)
        if let index = devices.firstIndex(where: { $0.id == id }) {
            devices[index] = device
        }
        loadPreview(for: device)
    }

    // MARK: - Sending

    /// Auto lets the existing pipeline decide where the content lands.
    func send(text: String, files: [InkletAPI.Attachment], links: [String]) async throws {
        try await InkletAPI.shared.uploadBundle(mainText: text, files: files, links: links)
        await loadKnowledge()
    }

    func sendDirect(text: String, image: Data?, to displayID: UUID, requestID: UUID, baseRevision: Int64) async throws {
        guard session?.user != nil else { throw APIError.notAuthenticated }
        guard let display = virtualDisplays.displays.first(where: { $0.id == displayID }) else {
            throw VirtualDisplayError.message("This display is unavailable.")
        }
        let png = try image.map { try VirtualDisplayRenderer.image($0, size: display.canvasSize) }
            ?? VirtualDisplayRenderer.text(text, size: display.canvasSize)
        guard await virtualDisplays.generateAndPublish(id: displayID, requestID: requestID, frameID: requestID,
            baseRevision: baseRevision, assets: [.binary(filename: "frame.png", contentType: "image/png", data: png)],
            mode: "hardcode", text: String(String.UnicodeScalarView(text.unicodeScalars.prefix(1000)))) else {
            throw VirtualDisplayError.message(virtualDisplays.error ?? "Couldn't send to this display. Try again.")
        }
        await loadKnowledge()
    }

    func reloadVirtualDisplay() {
        virtualDisplay = try? widgetStore.presentation()
    }

    /// Manual: put one image straight on a chosen display. The backend's
    /// custom-push route accepts images only.
    func sendDirect(image: InkletAPI.Attachment, to device: Device, title: String) async throws {
        _ = try await InkletAPI.shared.customPush(deviceID: device.id, image: image, title: title)
        await reloadDevice(device.id)
        await loadHistory(for: device)
    }

    // MARK: - Errors

    private func handle(_ error: Error) async {
        switch error {
        case APIError.cancelled:
            return
        case APIError.sessionExpired, APIError.notAuthenticated:
            await session?.invalidate()
        default:
            loadError = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}

extension AppModel {
    func startComposing(target: Device? = nil) {
        composerTarget = target
        composerVirtualTargetID = nil
        captureContext()
        present()
    }

    func startComposing(virtualDisplayID: UUID) {
        composerTarget = nil
        composerVirtualTargetID = virtualDisplayID
        captureContext()
        present()
    }

    /// What the global shortcut calls: a second press puts the panel away.
    func toggleComposer() {
        if ComposerPanelController.shared.isVisible {
            ComposerPanelController.shared.hide()
            return
        }
        composerTarget = nil
        composerVirtualTargetID = nil
        captureContext()
        present()
    }

    private func present() {
        composerFocusToken += 1
        ComposerPanelController.shared.show(model: self)
    }

    /// Reads the frontmost app *first* — synchronously, before the panel steals
    /// focus — then goes to fetch its contents in the background.
    private func captureContext() {
        suggestion = nil
        guard let source = AppContext.frontmost(), source.bundleID != Bundle.main.bundleIdentifier
        else { return }

        Task { [weak self] in
            let captured = await AppContext.capture(from: source)
            guard !captured.isEmpty else { return }
            guard let self, ComposerPanelController.shared.isVisible else { return }
            suggestion = captured
        }
    }

    /// Entry point for the Services menu: the payload is already in hand, so the
    /// panel opens with it pre-offered rather than going looking for context.
    func presentComposer(with context: Capture) {
        composerTarget = nil
        composerVirtualTargetID = nil
        suggestion = context
        present()
    }
}
