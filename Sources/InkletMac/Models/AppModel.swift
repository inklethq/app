import AppKit
import Foundation
import Observation
import InkletPresentationKit
import WidgetKit

@MainActor
@Observable
final class AppModel {
    let virtualDisplays: VirtualDisplayController
    /// The History page's runs and timelines. Its own object: the list pages
    /// and polls on its own clock, and nothing else on this model reads it.
    let history = HistoryModel()
    init() {
        virtualDisplays = VirtualDisplayController { path, method, body, headers in
            try await InkletAPI.shared.virtualDisplayRequest(path, method: method, body: body, headers: headers)
        }
        history.onSessionExpired = { [weak self] in await self?.session?.invalidate() }
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

    /// Where the sidebar should go next, for pages that cannot reach the
    /// selection themselves. The root view takes it and clears it.
    var requestedSidebarItem: SidebarItem?

    /// Opens a run's timeline on the History page, from anywhere.
    func openRun(_ analysisID: String) {
        history.requestOpen(analysisID)
        requestedSidebarItem = .history
    }

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
    private var currentPresentationIDs: [String: String] = [:]
    private var historyFloors: [String: Date] = [:]

    private var session: Session?
    private var accountGeneration = UUID()

    func attach(session: Session) {
        self.session = session
        accountGeneration = UUID()
        history.reset()
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
        AppContext.discardExports()
        composerTarget = nil
        composerVirtualTargetID = nil
        devices = []
        pushes = [:]
        knowledge = []
        activityByDay = [:]
        previews = [:]
        previewTasks = []
        currentPresentationIDs = [:]
        historyFloors = [:]
        runTasks.values.forEach { $0.cancel() }
        runTasks = [:]
        runs = []
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
        async let runs: Void = history.refreshIfLoaded()
        _ = await (devices, knowledge, virtuals, runs)
    }

    private func loadDevices() async {
        do {
            let fetched = try await InkletAPI.shared.devices().map(Device.init(dto:))
            // A display that was online at the last read and is not now.
            if !devices.isEmpty {
                let wasOnline = Set(devices.filter(\.online).map(\.id))
                for device in fetched where !device.online && wasOnline.contains(device.id) {
                    Notifier.shared.post(.offline, title: "\(device.displayName) went offline",
                                         body: "It keeps showing what it has until it checks in again.",
                                         id: "offline-\(device.id)")
                }
            }
            devices = fetched
            loadError = nil
            for device in fetched {
                loadPreview(for: device)
            }
        } catch {
            await handle(error)
        }
    }

    /// Pulls enough pages of Contents to cover the heatmap window. The list
    /// carries titles and Assets, so nothing has to be fetched per row.
    private func loadKnowledge() async {
        let expectedGeneration = accountGeneration
        let window = Calendar.current.date(byAdding: .day, value: -7 * 26, to: .now) ?? .now
        var collected: [KnowledgeItem] = []
        var seenIDs: Set<String> = []
        var cursor: String?

        do {
            while true {
                try Task.checkCancellation()
                let page = try await InkletAPI.shared.contents(cursor: cursor, limit: 50)
                guard accountGeneration == expectedGeneration else { return }
                let fresh = page.items.filter { seenIDs.insert($0.id).inserted }
                // A repeated page must not loop forever or publish an incomplete
                // season. Retain the previous widget snapshot on this failure.
                if !page.items.isEmpty && fresh.isEmpty { throw APIError.decoding }
                collected.append(contentsOf: fresh.map(KnowledgeItem.init(dto:)))
                guard page.hasMore == true, let next = page.nextCursor else { break }
                if let oldest = collected.last?.createdAt, oldest < window { break }
                cursor = next
            }
        } catch {
            guard accountGeneration == expectedGeneration else { return }
            await handle(error)
            return
        }

        guard accountGeneration == expectedGeneration, session?.user != nil else { return }
        knowledge = collected
        rebuildActivity()
    }

    /// One page of Contents matching `query`, straight from the backend, as
    /// Knowledge rows. Not cached: a search is a question about the whole
    /// library, and the heatmap window `knowledge` covers is not the library.
    func searchKnowledge(_ query: String) async throws -> (items: [KnowledgeItem], hasMore: Bool) {
        let page = try await InkletAPI.shared.contents(query: query, limit: 50)
        return (page.items.map(KnowledgeItem.init(dto:)), page.hasMore ?? false)
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

    // MARK: - Device detail

    func history(for device: Device) -> [Push] { pushes[device.id] ?? [] }

    func device(withID id: String) -> Device? { devices.first { $0.id == id } }

    func loadHistory(for device: Device) async {
        do {
            let page = try await InkletAPI.shared.displayHistory(displayID: device.id, limit: 30)
            pushes[device.id] = page.items.map(Push.init(dto:))
            historyFloors[device.id] = page.historyWindowStart.flatMap(InkletTime.parse)
        } catch {
            await handle(error)
        }
    }

    /// When the plan clips this Display's history, the instant it is clipped at.
    func historyFloor(for device: Device) -> Date? { historyFloors[device.id] }

    func preview(for device: Device) -> NSImage? {
        guard let id = currentPresentationIDs[device.id] else { return nil }
        return previews[id]
    }

    /// The Presentation the panel last confirmed, and its image. A pure read:
    /// the legacy `/push` route promoted the queue as a side effect, this does not.
    func loadPreview(for device: Device) {
        guard !previewTasks.contains(device.id) else { return }
        previewTasks.insert(device.id)

        Task { @MainActor in
            defer { previewTasks.remove(device.id) }
            do {
                guard let current = try await InkletAPI.shared.currentPresentation(displayID: device.id) else { return }
                currentPresentationIDs[device.id] = current.id
                guard previews[current.id] == nil, let url = current.image.flatMap({ URL(string: $0.url) }) else { return }
                let data = try await InkletAPI.shared.fetchData(from: url)
                if let image = NSImage(data: data) { previews[current.id] = image }
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

    /// Claims a Quote/0 through the Dot. cloud and puts it in the list. The
    /// list from the backend is newest first, so a fresh row goes on top; a
    /// re-bind of one already listed replaces it in place.
    /// Binds the panel, then names it. Two requests: the bind route takes no
    /// name, and a name that fails to stick is a rename away — the bind is the
    /// part that must not be lost. An empty name leaves the serial number.
    func bindQuote0(apiKey: String, serial: String, nickname: String = "") async throws -> Device {
        let dto: DeviceDTO
        do {
            dto = try await InkletAPI.shared.bindQuote0(apiKey: apiKey, serial: serial)
        } catch {
            // A dead session ends here the way it does everywhere else; the
            // form is left with only the refusals that are about the panel.
            if APIError.endsSession(error) { await session?.invalidate() }
            throw error
        }
        let device = Device(dto: dto)
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.insert(device, at: 0)
        }
        loadPreview(for: device)
        let name = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            await rename(device, to: name)
        }
        return devices.first { $0.id == device.id } ?? device
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

    /// Advances a display to the next queued Presentation and re-reads its
    /// state. Returns false when the queue was empty.
    @discardableResult
    func showNext(_ device: Device) async throws -> Bool {
        let changed = try await InkletAPI.shared.advanceDisplay(displayID: device.id)
        await refreshAfterSwitch(device)
        return changed
    }

    /// Puts one of this panel's earlier Presentations back on screen.
    func show(_ push: Push, on device: Device) async throws {
        try await InkletAPI.shared.setCurrentPresentation(displayID: device.id, presentationID: push.id)
        await refreshAfterSwitch(device)
    }

    /// Both switches land on the panel's pending slot until it confirms, so the
    /// preview is re-read rather than assumed.
    private func refreshAfterSwitch(_ device: Device) async {
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

    /// Where a draft goes. `agent` lets inklet pick compatible Displays.
    enum ComposeTarget: Hashable {
        case agent
        case hardware(String)
        case virtual(UUID)
    }

    /// An Analysis the composer started; Home follows it until it settles.
    struct ComposeRun: Identifiable, Hashable {
        let id: String
        let title: String
        let destination: String
        var state: String
        var latest: String?
        var outcome: String?
        var failure: String?
        let startedAt = Date()

        var isFinished: Bool { state == "completed" || state == "failed" }
        var statusText: String {
            if state == "failed" { return failure ?? "Failed" }
            if state == "completed" { return outcome == "no_change" ? "Nothing new to show" : "On its way to \(destination)" }
            return latest ?? (state == "queued" ? "Waiting for inklet…" : "Working…")
        }
    }

    var runs: [ComposeRun] = []
    private var runTasks: [String: Task<Void, Never>] = [:]

    private var targetlessClient: TargetlessClient {
        TargetlessClient { path, method, body, headers in
            try await InkletAPI.shared.virtualDisplayRequest(path, method: method, body: body, headers: headers)
        }
    }

    /// Upload, then the action the user chose over it. Returns one line for
    /// the composer to show as it closes; an AI run is followed on Home.
    func compose(text: String, attachments: [PresentationAsset], action: ComposeAction,
                 target: ComposeTarget, requestID: UUID) async throws -> String {
        guard session?.user != nil else { throw APIError.notAuthenticated }
        var assets: [PresentationAsset] = []
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { assets.append(.text(body)) }
        assets += attachments

        let spec: AnalysisTargetSpec
        var deviceID: String?
        switch target {
        case .agent: spec = .agent
        case .hardware(let id): spec = .display(id); deviceID = id
        case .virtual: throw VirtualDisplayError.message("Virtual Displays publish their own frame.")
        }

        let outcome = try await targetlessClient.compose(assets: assets, action: action, target: spec, requestID: requestID)
        await loadKnowledge()
        guard action != .upload else { return "Saved to Knowledge" }
        if outcome.refusal != nil { return "Saved — pair a display to show it on" }
        guard let analysis = outcome.analysis else { return "Saved" }

        let destination = deviceID.flatMap { device(withID: $0)?.displayName } ?? "a display inklet picks"
        track(analysis, title: outcome.content.title ?? TargetlessClient.title(for: assets) ?? "Untitled", destination: destination, deviceID: deviceID)
        return action == .asIs ? "Sending to \(destination)" : "inklet is working on it"
    }

    private func track(_ analysis: AnalysisDTO, title: String, destination: String, deviceID: String?) {
        let runID = analysis.id
        runs.removeAll { $0.id == runID }
        runs.insert(ComposeRun(id: runID, title: title, destination: destination, state: analysis.state), at: 0)
        let expected = accountGeneration
        let client = targetlessClient
        runTasks[runID]?.cancel()
        // Built outside the Task so the sink captures `self` weakly on its own,
        // rather than the Task's rebinding of it.
        let sink: TargetlessClient.EventSink = { [weak self] event in
            let line = event.displayText
            Task { @MainActor in
                self?.update(runID, generation: expected) { $0.latest = line; $0.state = "running" }
            }
        }
        runTasks[runID] = Task { @MainActor [weak self] in
            defer { self?.runTasks[runID] = nil }
            do {
                let done = try await client.follow(analysisID: runID, onEvent: sink)
                guard let self, self.accountGeneration == expected else { return }
                update(runID, generation: expected) {
                    $0.state = done.state; $0.outcome = done.outcome; $0.failure = done.failure?.message
                }
                if done.state == "failed" {
                    Notifier.shared.post(.failed, title: "Couldn't send “\(title)”",
                                         body: done.failure?.message ?? "inklet could not finish this one.", id: "run-\(runID)")
                } else if done.outcome == "presentations" {
                    Notifier.shared.post(.delivered, title: "“\(title)” is on its way",
                                         body: "Heading to \(destination). The display picks it up on its next check-in.", id: "run-\(runID)")
                }
                if let deviceID {
                    await reloadDevice(deviceID)
                    if let device = device(withID: deviceID) { await loadHistory(for: device) }
                } else {
                    await loadDevices()
                }
                await loadKnowledge()
                try? await Task.sleep(for: .seconds(15))
                guard accountGeneration == expected else { return }
                runs.removeAll { $0.id == runID && $0.state == "completed" }
            } catch {
                guard let self, self.accountGeneration == expected else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                update(runID, generation: expected) { $0.state = "failed"; $0.failure = message }
                Notifier.shared.post(.failed, title: "Couldn't send “\(title)”", body: message, id: "run-\(runID)")
            }
        }
    }

    private func update(_ id: String, generation: UUID, _ change: (inout ComposeRun) -> Void) {
        guard accountGeneration == generation, let index = runs.firstIndex(where: { $0.id == id }) else { return }
        change(&runs[index])
    }

    func dismissRun(_ id: String) {
        runTasks[id]?.cancel()
        runTasks[id] = nil
        runs.removeAll { $0.id == id }
    }

    /// Virtual Displays publish a frame themselves, so the whole generate →
    /// download → publish chain runs here and the composer waits on it.
    func sendToVirtual(action: ComposeAction, text: String, image: PresentationAsset?, to displayID: UUID,
                       requestID: UUID, baseRevision: Int64) async throws {
        guard session?.user != nil else { throw APIError.notAuthenticated }
        guard let display = virtualDisplays.displays.first(where: { $0.id == displayID }) else {
            throw VirtualDisplayError.message("This display is unavailable.")
        }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let assets: [PresentationAsset]
        let mode: String
        switch action {
        case .asIs, .upload:
            var imageData: Data?
            if case .binary(_, _, let data)? = image { imageData = data }
            let png = try imageData.map { try VirtualDisplayRenderer.image($0, size: display.canvasSize) }
                ?? VirtualDisplayRenderer.text(body, size: display.canvasSize)
            assets = [.binary(filename: "frame.png", contentType: "image/png", data: png)]
            mode = "hardcode"
        case .card, .cardHistory:
            var list: [PresentationAsset] = []
            if !body.isEmpty { list.append(.text(body)) }
            if let image { list.append(image) }
            assets = list
            mode = action == .card ? "auto" : "history"
        }
        guard await virtualDisplays.generateAndPublish(id: displayID, requestID: requestID, frameID: requestID,
            baseRevision: baseRevision, assets: assets, mode: mode,
            text: String(String.UnicodeScalarView(body.unicodeScalars.prefix(1000)))) else {
            throw VirtualDisplayError.message(virtualDisplays.error ?? "Couldn't send to this display. Try again.")
        }
        await loadKnowledge()
    }

    func reloadVirtualDisplay() {
        virtualDisplay = try? widgetStore.presentation()
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
        // The last summon's suggestion is gone, and so are the Photos exports
        // behind it; anything already attached was read into memory.
        AppContext.discardExports()
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
