import SwiftUI

struct DeviceDetailView: View {
    @Environment(AppModel.self) private var model
    let device: Device

    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var confirmUnbind = false
    @State private var queueNotice: String?
    @State private var isAdvancing = false

    private var history: [Push] { model.history(for: device) }

    var body: some View {
        DisplayDetailLayout {
            currentlyShowing
        } information: {
            specs
        } history: {
            historySection
        }
        .navigationTitle(device.displayName)
        .navigationSubtitle(device.identifier)
        .task(id: device.id) {
            await model.loadHistory(for: device)
            model.loadPreview(for: device)
        }
        .toolbar {
            // Splits this page's device actions off the window-level Push button
            // into their own glass group, so the grouping matches the scope.
            // macOS 26 only; on 15 the groups just sit side by side.
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button("Show Next", systemImage: "forward.end") { showNext() }
                    .help("Advance this display to the next item in its queue")
                    .disabled(isAdvancing)
                Menu("Actions", systemImage: "ellipsis.circle") {
                    Button("Push Here…") { model.startComposing(target: device) }
                    Button("Rename…") {
                        draftName = device.nickname ?? ""
                        isRenaming = true
                    }
                    Button("Refresh") {
                        Task {
                            await model.reloadDevice(device.id)
                            await model.loadHistory(for: device)
                        }
                    }
                    Divider()
                    Button("Unbind Display…", role: .destructive) { confirmUnbind = true }
                }
            }
        }
        .sheet(isPresented: $isRenaming) { renameSheet }
        .confirmationDialog("Unbind \(device.displayName)?",
                            isPresented: $confirmUnbind, titleVisibility: .visible) {
            Button("Unbind", role: .destructive) { Task { await model.unbind(device) } }
        } message: {
            Text(device.kind == .quote0
                 ? "inklet forgets the Dot. API key and stops sending to this panel. It keeps showing what it has, and the Dot. app is unaffected."
                 : "The display stops receiving your content and can be claimed by another account.")
        }
    }

    private var currentlyShowing: some View {
        DisplayPreviewCard {
            statusHeader
        } preview: {
            DisplayFrame(image: model.preview(for: device), title: history.first?.title,
                         subtitle: history.first?.summary, offline: !device.online, kind: device.kind)
        } caption: {
            // A Quote/0 has no confirm to go missing, only Dot.'s answer — and
            // when that was a refusal it is the one thing worth saying here.
            if queueNotice == nil, let problem = device.cloudDeliveryError {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Ink.danger)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(queueNotice ?? history.first.map { "Pushed \(relativeTime($0.createdAt))" } ?? "Nothing on screen yet")
            }
        }
    }

    /// What "sent" means on this panel: an inklet display fetches on its next
    /// check-in; a Quote/0 gets the picture from Dot. on its next refresh.
    private var sentNotice: String {
        device.kind == .quote0
            ? "Sent — Dot. shows it on the panel's next refresh"
            : "Sent — the display refreshes on its next check-in"
    }

    private var statusHeader: some View {
        HStack(spacing: 7) {
            StatusDot(online: device.online, size: 7)
            Text(device.online ? "Online" : "Offline")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ink.secondary)

            Spacer(minLength: 8)

            if device.charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.secondary)
            }
            BatteryLabel(level: device.battery, iconOnly: true)
                .font(.system(size: 12))
        }
    }

    /// The next item the display will rotate to when it refreshes.
    private var upNext: Push? {
        history.first { $0.status == .queued || $0.status == .preparing }
    }

    private var specs: some View {
        InkCard(stretches: true) {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel("Up next")
                    .padding(.bottom, 8)

                // Fixed height so an empty queue and a queued item leave the card
                // exactly as tall — otherwise it stops matching the preview card.
                Group {
                    if let upNext {
                        HStack(spacing: 10) {
                            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                                .font(.system(size: 13))
                                .foregroundStyle(Ink.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(upNext.title)
                                    .font(.system(size: 14))
                                    .foregroundStyle(Ink.text)
                                    .lineLimit(1)
                                Text("Added \(relativeTime(upNext.createdAt))")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Ink.muted)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                        }
                    } else {
                        Text("Queue is empty — this display keeps what it has.")
                            .font(.system(size: 13))
                            .foregroundStyle(Ink.muted)
                            .lineLimit(2)
                    }
                }
                .frame(height: 38, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)

                Rectangle().fill(Ink.cardRule).frame(height: 1)

                SectionLabel("Device")
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                SpecRow(label: "Model") { Text(device.modelName) }
                SpecRow(label: device.identifierLabel) {
                    // Truncated in the middle so both ends stay recognisable;
                    // selectable and hoverable for the full value.
                    Text(device.identifier)
                        .monospaced()
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(device.identifier)
                }
                SpecRow(label: "Firmware") {
                    Text(device.firmware ?? "—")
                        .truncationMode(.middle)
                        .help(device.firmware ?? "")
                }
                SpecRow(label: device.kind == .quote0 ? "Dot. cloud" : "Network") {
                    Text(device.online ? (device.kind == .quote0 ? "Reachable" : "Online") : (device.kind == .quote0 ? "Unreachable" : "Offline"))
                }
                SpecRow(label: "Last seen") { Text(relativeTime(device.lastSeenAt)) }
                SpecRow(label: "Battery", showsDivider: false, isLast: true) {
                    // While charging the cell sits at its charge voltage, so the
                    // reported percentage isn't meaningful — say so instead.
                    if device.charging {
                        Label("Charging", systemImage: "bolt.fill")
                            .foregroundStyle(Ink.secondary)
                    } else {
                        BatteryGauge(level: device.battery)
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }

    private var historySection: some View {
        InkCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel("Queue & history")
                    Spacer()
                    Text("\(history.count) items")
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.muted)
                }
                .padding(.bottom, 10)

                if history.isEmpty {
                    Text("Anything you push to this display shows up here.")
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.muted)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 28)
                } else {
                    ForEach(Array(history.enumerated()), id: \.element.id) { index, push in
                        HistoryRow(push: push, showsDivider: index < history.count - 1,
                                   canShow: push.canShowAgain && !isAdvancing,
                                   onShow: { show(push) },
                                   onOpenRun: push.analysisID.map { id in { model.openRun(id) } })
                    }
                    if let floor = model.historyFloor(for: device) {
                        Text("Your plan shows history since \(floor.formatted(date: .abbreviated, time: .omitted)). Upgrade to see all of it.")
                            .font(.system(size: 12))
                            .foregroundStyle(Ink.muted)
                            .padding(.top, 10)
                    }
                }
            }
        }
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename display")
                .font(.brand(22))
                .foregroundStyle(Ink.text)
            TextField("Name", text: $draftName, prompt: Text(device.identifier))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))
            Text(device.kind == .quote0 ? "Leave empty to fall back to the serial number." : "Leave empty to fall back to the hardware ID.")
                .font(.system(size: 12))
                .foregroundStyle(Ink.muted)
            HStack {
                Spacer()
                Button("Cancel") { isRenaming = false }
                Button("Save") {
                    let name = draftName
                    isRenaming = false
                    Task { await model.rename(device, to: name) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 360)
        .background(Ink.bg)
    }

    private func show(_ push: Push) {
        guard !isAdvancing else { return }
        isAdvancing = true
        withAnimation { queueNotice = "Showing “\(push.title)”…" }

        Task {
            defer { isAdvancing = false }
            do {
                try await model.show(push, on: device)
                withAnimation { queueNotice = sentNotice }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                withAnimation { queueNotice = message }
            }
            try? await Task.sleep(for: .seconds(3))
            withAnimation { queueNotice = nil }
        }
    }

    private func showNext() {
        guard !isAdvancing else { return }
        isAdvancing = true
        withAnimation { queueNotice = "Advancing to the next item…" }

        Task {
            defer { isAdvancing = false }
            do {
                let changed = try await model.showNext(device)
                withAnimation {
                    queueNotice = changed ? sentNotice : "Nothing queued to advance to"
                }
            } catch {
                let message = (error as? APIError)?.errorDescription ?? error.localizedDescription
                withAnimation { queueNotice = message }
            }
            try? await Task.sleep(for: .seconds(3))
            withAnimation { queueNotice = nil }
        }
    }
}

private struct HistoryRow: View {
    let push: Push
    let showsDivider: Bool
    var canShow = false
    var onShow: () -> Void = {}
    /// Opens the run behind the picture on the History page. Nil for a
    /// picture with no run on record (older pushes).
    var onOpenRun: (() -> Void)? = nil
    @State private var isHovering = false

    private var subtitle: String {
        if let summary = push.summary { return summary }
        return push.mode == "direct" ? "Shown as-is" : "Laid out by inklet"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(push.title)
                        .font(.system(size: 14))
                        .foregroundStyle(Ink.text)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(push.status == .failed ? Ink.danger : Ink.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let onOpenRun {
                    Button("Run", systemImage: "clock.arrow.circlepath") { onOpenRun() }
                        .labelStyle(.titleOnly)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .opacity(isHovering ? 1 : 0)
                        .help("See how this was made, on the History page")
                }
                if canShow {
                    Button("Show", systemImage: "arrow.uturn.backward") { onShow() }
                        .labelStyle(.titleOnly)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .opacity(isHovering ? 1 : 0)
                        .help("Put this back on the display")
                }
                Text(push.status.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(push.status.isTerminal ? Ink.muted : Ink.text)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Ink.input, in: .rect(cornerRadius: 5))
                Text(relativeTime(push.createdAt))
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.muted)
                    .frame(width: 62, alignment: .trailing)
            }
            .frame(height: 46)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            // The row itself opens the run; the buttons are for what else it
            // can do, and for saying so on hover.
            .onTapGesture { onOpenRun?() }
            .contextMenu {
                if let onOpenRun { Button("View Run") { onOpenRun() } }
                if canShow { Button("Show on Display") { onShow() } }
            }
            if showsDivider {
                Rectangle().fill(Ink.cardRule).frame(height: 1)
            }
        }
    }
}
