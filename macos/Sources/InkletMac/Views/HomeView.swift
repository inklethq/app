import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
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

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                .font(.system(size: 13, weight: .medium))
                .tracking(1.6)
                .foregroundStyle(Ink.muted)
            Text("Hi, \(model.account.username)!")
                .font(.brand(40))
                .foregroundStyle(Ink.text)
        }
    }

    /// Ink-black CTA, tappable edge to edge — same shape as the iOS quick send card.
    private var quickSend: some View {
        Button {
            model.startComposing()
        } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Push something")
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

            if model.devices.isEmpty {
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
                    Text(model.isLoading ? "Loading your displays…" : "No displays paired yet")
                        .font(.system(size: 14))
                        .foregroundStyle(Ink.text)
                    Text(model.isLoading
                         ? "One moment."
                         : "Tap your display's NFC tag with your iPhone to pair it.")
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.muted)
                }
                Spacer(minLength: 8)
                if !model.isLoading {
                    Button("How to pair") { selection = .pair }
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
                DisplayFrame(image: preview, offline: !device.online)
                HStack(spacing: 7) {
                    StatusDot(online: device.online)
                    Text(device.displayName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Ink.text)
                    Spacer()
                    if device.charging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Ink.secondary)
                    }
                    BatteryLabel(level: device.battery, iconOnly: true)
                        .font(.system(size: 13))
                }
                Text(device.online
                     ? "Pushed \(relativeTime(device.latestPushAt))"
                     : "Last seen \(relativeTime(device.lastSeenAt))")
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.muted)
            }
        }
        .contentShape(.rect)
    }
}
