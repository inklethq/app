import SwiftUI
import InkletPresentationKit

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var virtuals: VirtualDisplayController
    @Binding var selection: SidebarItem?

    /// Measured on the scroll view itself rather than with a GeometryReader wrapped
    /// around it, which would clamp the scroll view to the safe area. Driving the
    /// column count from window width (not content width) keeps a scrollbar from
    /// re-flowing the grid mid-scroll.
    @State private var width: CGFloat = 900

    private var columns: Int { max(1, Int((width - 56 + 16) / 272)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                greeting
                quickSend
                if !model.runs.isEmpty { runs }
                activity
                displays(columns: columns)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .scrollIndicators(.never)
        .background(Ink.bg)
        .navigationTitle("Home")
    }

    /// Off until the user turns it on in Settings, which is where location
    /// access is asked for. A stored choice from an earlier build still stands.
    @AppStorage(SystemSettings.showWeatherKey) private var showWeather = false
    private let weather = WeatherService.shared

    private var greeting: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                    .font(.system(size: 13, weight: .medium))
                    .tracking(1.6)
                    .foregroundStyle(Ink.muted)
                Text("Hi, \(model.account.username)!")
                    .font(.brand(40))
                    .foregroundStyle(Ink.text)
            }
            Spacer(minLength: 12)
            if showWeather { weatherChip }
        }
        .task(id: showWeather) { if showWeather { weather.refreshIfStale() } }
    }

    /// Current conditions for wherever the Mac is. Silent when there is nothing
    /// to say yet; the reason lives under Settings → General.
    @ViewBuilder
    private var weatherChip: some View {
        if let current = weather.current {
            HStack(spacing: 8) {
                Image(systemName: current.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(Ink.secondary)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(current.temperature)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Ink.text)
                    Text(current.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.muted)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Ink.card, in: .rect(cornerRadius: Ink.controlCorner))
            .overlay { RoundedRectangle(cornerRadius: Ink.controlCorner).strokeBorder(Ink.border) }
            .help("\(current.summary) · updated \(current.fetchedAt.formatted(date: .omitted, time: .shortened))")
            .onTapGesture { weather.refresh() }
        } else if weather.isLoading {
            ProgressView().controlSize(.small).padding(.top, 10)
        }
    }

    /// What the composer sent and is still being worked on. Each row is one
    /// Analysis: its title, where it is going, and the agent's latest step.
    /// Finished rows linger for a moment, then leave on their own.
    private var runs: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.runs) { run in
                HStack(spacing: 12) {
                    if run.isFinished {
                        Image(systemName: run.state == "failed" ? "exclamationmark.triangle" : "checkmark.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(run.state == "failed" ? Ink.danger : Ink.online)
                            .frame(width: 16)
                    } else {
                        ProgressView().controlSize(.small).frame(width: 16)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(run.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Ink.text)
                            .lineLimit(1)
                        Text(run.statusText)
                            .font(.system(size: 12))
                            .foregroundStyle(run.state == "failed" ? Ink.danger : Ink.secondary)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                    }
                    Spacer(minLength: 8)
                    Button {
                        model.dismissRun(run.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Ink.muted)
                    }
                    .buttonStyle(.plain)
                    .help("Stop following this")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Ink.card, in: .rect(cornerRadius: Ink.controlCorner))
                .overlay { RoundedRectangle(cornerRadius: Ink.controlCorner).strokeBorder(Ink.border) }
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.runs)
    }

    /// Ink-black CTA, tappable edge to edge — same shape as the iOS quick send card.
    private var quickSend: some View {
        Button {
            model.startComposing()
        } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Create a Presentation")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Ink.bg)
                    Text("Text, links, images or files — or press \(ShortcutStore.shared.shortcut.display) from any app")
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.bg.opacity(0.62))
                }
                Spacer(minLength: 12)
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Ink.bg)
                    .frame(width: 34, height: 34)
                    .background(Ink.bg.opacity(0.14), in: .circle)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.text, in: .rect(cornerRadius: Ink.cardCorner))
            .contentShape(.rect(cornerRadius: Ink.cardCorner))
        }
        .buttonStyle(.plain)
    }

    /// No card here — the grid is its own shape, and a background box around it
    /// only competes with the display cards below.
    private var activity: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Building your second brain")
                Spacer()
                Text("\(total) items · \(streak) day streak")
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.secondary)
            }
            HeatmapView(counts: model.activityByDay)
        }
    }

    private func displays(columns: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Your displays")
                Spacer()
                if !model.devices.isEmpty {
                    Text("\(model.devices.filter(\.online).count) of \(model.devices.count) online")
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.secondary)
                }
            }

            if model.devices.isEmpty && virtuals.displays.isEmpty {
                emptyDisplays
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: columns), spacing: 16) {
                    ForEach(model.devices) { device in
                        Button {
                            selection = .device(device.id)
                        } label: {
                            DisplayCard(device: device, preview: model.preview(for: device))
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(virtuals.displays) { display in
                        Button { selection = .virtualDisplayDetail(display.id) } label: {
                            InkCard(padding: 14) {
                                VStack(alignment: .leading, spacing: 12) {
                                    VirtualFramePreview(data: virtuals.frames[display.id]?.imageData)
                                        .frame(height: 170).frame(maxWidth: .infinity)
                                        .background(Ink.paperWhite, in: .rect(cornerRadius: Ink.screenCorner))
                                    Label(display.name, systemImage: "macwindow")
                                        .font(.system(size: 14, weight: .medium)).foregroundStyle(Ink.text)
                                    Text(display.profile?.title ?? "Virtual Display")
                                        .font(.system(size: 12)).foregroundStyle(Ink.muted)
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyDisplays: some View {
        InkCard(padding: 22) {
            HStack(spacing: 14) {
                Image(systemName: model.isLoading ? "arrow.triangle.2.circlepath" : "rectangle.inset.filled")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Ink.muted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.isLoading || virtuals.busy ? "Loading your displays…" : "No displays yet")
                        .font(.system(size: 14))
                        .foregroundStyle(Ink.text)
                    Text(model.isLoading
                         ? "One moment."
                         : "Connect a hardware display or create a Virtual Display for your Widget.")
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.muted)
                }
                Spacer(minLength: 8)
                if !model.isLoading {
                    Button("New Display") { selection = .newDisplay }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Ink.text)
                }
            }
        }
    }

    private var total: Int { model.activityByDay.values.reduce(0, +) }

    /// Consecutive days with at least one push, allowing today to be empty.
    private var streak: Int {
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: .now)
        if model.activityByDay[day] == nil {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var count = 0
        while let value = model.activityByDay[day], value > 0 {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }
}

private struct DisplayCard: View {
    let device: Device
    let preview: NSImage?

    var body: some View {
        InkCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                DisplayFrame(image: preview, offline: !device.online, kind: device.kind)
                HStack(spacing: 7) {
                    StatusDot(online: device.online)
                    Text(device.displayName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Ink.text)
                    if device.kind == .quote0 {
                        Image(systemName: "cloud")
                            .font(.system(size: 11))
                            .foregroundStyle(Ink.muted)
                            .help("Quote/0, through the Dot. cloud")
                    }
                    Spacer()
                    if device.charging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Ink.secondary)
                    }
                    BatteryLabel(level: device.battery, iconOnly: true)
                        .font(.system(size: 13))
                }
                if let problem = device.cloudDeliveryError {
                    Text(problem)
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.danger)
                        .lineLimit(2)
                        .help(problem)
                } else {
                    Text(device.online
                         ? "Pushed \(relativeTime(device.latestPushAt))"
                         : "Last seen \(relativeTime(device.lastSeenAt))")
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.muted)
                }
            }
        }
        .contentShape(.rect)
    }
}
