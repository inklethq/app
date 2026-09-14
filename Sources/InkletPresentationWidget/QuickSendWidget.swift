import InkletPresentationKit
import SwiftUI
import WidgetKit

struct QuickSendEntry: TimelineEntry {
    let date: Date
    let prompt: String
}

enum QuickSendPrompt {
    static let placeholder = "What's on your mind?"
    static let phrases = [
        "Start building your ambient life", "What's on your mind?",
        "Let your wisdom find you", "Capture the thought before it fades",
        "Send a signal to your future self", "Turn the spark into memory",
        "Leave something worth returning to"
    ]
}

private struct QuickSendProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickSendEntry {
        QuickSendEntry(date: .now, prompt: QuickSendPrompt.placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickSendEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickSendEntry>) -> Void) {
        let date = Date()
        let entry = QuickSendEntry(date: date, prompt: QuickSendPrompt.phrases.randomElement() ?? QuickSendPrompt.placeholder)
        completion(Timeline(entries: [entry], policy: .after(date.addingTimeInterval(6 * 3600))))
    }
}

/// Matches the iOS Quick Send widget, including its seven rotating prompts.
public struct QuickSendWidgetContent: View {
    let prompt: String

    public init(prompt: String = "What's on your mind?") { self.prompt = prompt }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("inklet")
                    .font(WidgetFonts.brand(25))
                    .lineLimit(1)
                    .frame(height: 30)
                    .offset(y: 2)
                Spacer()
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(WidgetPalette.background)
                    .frame(width: 30, height: 30)
                    .background(WidgetPalette.foreground, in: .circle)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
            Text(prompt)
                .font(WidgetFonts.body(14))
                .foregroundStyle(WidgetPalette.foreground.opacity(0.55))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(WidgetPalette.foreground)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Quick Send. \(prompt)")
        .accessibilityHint("Opens the inklet composer")
    }
}

public struct QuickSendWidget: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: inkletQuickSendWidgetKind, provider: QuickSendProvider()) { entry in
            QuickSendWidgetContent(prompt: entry.prompt)
                .widgetURL(WidgetDestination.send.url)
                .containerBackground(WidgetPalette.background, for: .widget)
        }
        .configurationDisplayName("Quick Send")
        .description("Capture a thought, link, image or file with inklet.")
        .supportedFamilies([.systemSmall])
    }
}
