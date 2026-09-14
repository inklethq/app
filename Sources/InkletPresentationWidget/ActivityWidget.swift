import InkletPresentationKit
import SwiftUI
import WidgetKit

struct ActivityEntry: TimelineEntry {
    let date: Date
    let counts: [Date: Int]
    let isSignedIn: Bool
}

private struct ActivityProvider: TimelineProvider {
    private let store = WidgetDataStore()

    func placeholder(in context: Context) -> ActivityEntry { sample() }

    func getSnapshot(in context: Context, completion: @escaping (ActivityEntry) -> Void) {
        completion(context.isPreview ? sample() : current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ActivityEntry>) -> Void) {
        let entry = current()
        let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: entry.date))!
        let refresh = min(midnight, entry.date.addingTimeInterval(6 * 3600))
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private func current() -> ActivityEntry {
        ActivityEntry(date: .now, counts: (try? store.activity()?.datedCounts()) ?? [:],
                      isSignedIn: (try? store.session()?.isSignedIn) == true)
    }

    private func sample() -> ActivityEntry {
        let date = Date()
        let today = Calendar.current.startOfDay(for: date)
        var counts: [Date: Int] = [:]
        for offset in 0..<140 {
            if let day = Calendar.current.date(byAdding: .day, value: -offset, to: today) {
                counts[day] = (offset * 3 + offset / 5) % 7
            }
        }
        return ActivityEntry(date: date, counts: counts, isSignedIn: true)
    }
}

public struct ActivityWidgetContent: View {
    let counts: [Date: Int]
    let date: Date
    let isSignedIn: Bool
    private let gap: CGFloat = 2.5

    public init(counts: [Date: Int], date: Date = .now, isSignedIn: Bool = true) {
        self.counts = counts
        self.date = date
        self.isSignedIn = isSignedIn
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Building your second brain")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            GeometryReader { geometry in
                let columns = ActivityGrid.columns(counts: counts, date: date)
                let cell = max(1, min(15, (geometry.size.height - 6 * gap) / 7,
                                      (geometry.size.width - 25 * gap) / 26))
                HStack(spacing: gap) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                        VStack(spacing: gap) {
                            ForEach(Array(column.enumerated()), id: \.offset) { _, value in
                                RoundedRectangle(cornerRadius: min(2, cell / 3))
                                    .fill(value.map(color) ?? .clear)
                                    .frame(width: cell, height: cell)
                            }
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .trailing)
            }
            .accessibilityHidden(true)
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(WidgetPalette.foreground.opacity(0.6))
                .lineLimit(1)
        }
        .foregroundStyle(WidgetPalette.foreground)
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Activity over the last 26 weeks. \(caption)")
    }

    private var caption: String {
        guard isSignedIn else { return "Sign in to see your activity" }
        let total = ActivityGrid.total(counts: counts, date: date)
        if total == 0 { return "Push a note to start your streak" }
        return "\(total) item\(total == 1 ? "" : "s") this season"
    }

    private func color(_ count: Int) -> Color {
        switch count {
        case 0: WidgetPalette.cellEmpty
        case 1: WidgetPalette.foreground.opacity(0.22)
        case 2...3: WidgetPalette.foreground.opacity(0.45)
        case 4...6: WidgetPalette.foreground.opacity(0.70)
        default: WidgetPalette.foreground
        }
    }
}

public struct ActivityWidget: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: inkletActivityWidgetKind, provider: ActivityProvider()) { entry in
            ActivityWidgetContent(counts: entry.counts, date: entry.date, isSignedIn: entry.isSignedIn)
                .widgetURL(WidgetDestination.activity.url)
                .containerBackground(WidgetPalette.background, for: .widget)
        }
        .configurationDisplayName("Activity")
        .description("Your inklet activity over the last 26 weeks.")
        .supportedFamilies([.systemMedium])
    }
}
