import SwiftUI

struct StatusDot: View {
    let online: Bool
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(online ? Ink.online : Ink.muted)
            .frame(width: size, height: size)
            .accessibilityLabel(online ? "Online" : "Offline")
    }
}

/// `Image(name:bundle:)` only resolves asset-catalog names; this PNG ships as a
/// plain resource, so load it by URL once and reuse the NSImage.
enum BezelImage {
    static let image: NSImage? = {
        guard let url = AppResources.url("front_frame", extension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()
}

/// The real D1 bezel with the pushed content sitting inside its screen cutout.
/// Cutout geometry matches the web client: 4.8% side margins, 6.6% top, 18.6% bottom.
///
/// `image` is the rendered push as the panel actually shows it. Until it arrives
/// the frame falls back to a typeset stand-in built from the push's title, so a
/// slow preview doesn't leave a blank rectangle.
struct DisplayFrame: View {
    var image: NSImage?
    var title: String?
    var subtitle: String?
    var offline = false
    /// Which panel to draw. The D1 gets its bezel; a Quote/0 is a bare
    /// 296×152 panel in a thin frame — there is no bezel art for it, and a
    /// D1 bezel around a 2:1 picture would just lie about the hardware.
    var kind: Device.Kind = .inklet

    private let aspect: CGFloat = 2303.0 / 1664.0
    private let screenInsetX: CGFloat = 0.048
    private let screenInsetTop: CGFloat = 0.066
    private let screenInsetBottom: CGFloat = 0.186

    private let quote0Aspect: CGFloat = 296.0 / 152.0

    var body: some View {
        switch kind {
        case .inklet: bezelled
        case .quote0: bare
        }
    }

    /// The Quote/0: the picture at the panel's own aspect, a hairline frame,
    /// the same paper white behind it.
    private var bare: some View {
        GeometryReader { geo in
            screen(width: geo.size.width)
        }
        .aspectRatio(quote0Aspect, contentMode: .fit)
        .clipShape(.rect(cornerRadius: Ink.screenCorner))
        .overlay { RoundedRectangle(cornerRadius: Ink.screenCorner).strokeBorder(Ink.border, lineWidth: 1) }
        .padding(6)
        .background(Ink.card, in: .rect(cornerRadius: Ink.screenCorner + 6))
        .overlay { RoundedRectangle(cornerRadius: Ink.screenCorner + 6).strokeBorder(Ink.border, lineWidth: 1) }
        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 5)
        .opacity(offline ? 0.6 : 1)
        .accessibilityElement()
        .accessibilityLabel(title.map { "Showing \($0)" } ?? "Nothing on screen yet")
    }

    private var bezelled: some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .background {
                // Shadow is cast by the bezel silhouette alone, underneath everything,
                // so nothing darkens the screen area inside it.
                if let bezel = BezelImage.image {
                    Image(nsImage: bezel)
                        .resizable()
                        .scaledToFit()
                        .shadow(color: .black.opacity(0.20), radius: 16, x: 0, y: 8)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                GeometryReader { geo in
                    let size = geo.size
                    // 1% overscan: the screen fill must not leave a hairline gap at
                    // the cutout edge, or the shadow shows through it.
                    let screenWidth = size.width * (1 - screenInsetX * 2) * 1.01
                    let screenHeight = size.height * (1 - screenInsetTop - screenInsetBottom) * 1.01
                    let centerY = size.height * (screenInsetTop + (1 - screenInsetTop - screenInsetBottom) / 2)

                    screen(width: screenWidth)
                        .frame(width: screenWidth, height: screenHeight)
                        .clipShape(.rect(cornerRadius: Ink.screenCorner))
                        .position(x: size.width / 2, y: centerY)
                }
            }
            .overlay {
                if let bezel = BezelImage.image {
                    Image(nsImage: bezel)
                        .resizable()
                        .scaledToFit()
                        .allowsHitTesting(false)
                } else {
                    RoundedRectangle(cornerRadius: Ink.screenCorner)
                        .strokeBorder(Ink.border, lineWidth: 1)
                }
            }
            .opacity(offline ? 0.6 : 1)
            .accessibilityElement()
            .accessibilityLabel(title.map { "Showing \($0)" } ?? "Nothing on screen yet")
    }

    @ViewBuilder
    private func screen(width: CGFloat) -> some View {
        ZStack {
            Ink.paperWhite
            if let image {
                // The panel is greyscale and the render already matches its
                // aspect; fill so the cutout is fully covered either way.
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let title {
                VStack(spacing: width * 0.035) {
                    if let subtitle {
                        Text(subtitle.uppercased())
                            .font(.system(size: max(7, width * 0.026), weight: .medium))
                            .tracking(1.2)
                            .foregroundStyle(.black.opacity(0.42))
                            .lineLimit(1)
                    }
                    Text(title)
                        .font(.brand(max(13, width * 0.085)))
                        .foregroundStyle(.black.opacity(0.86))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    Rectangle()
                        .fill(.black.opacity(0.28))
                        .frame(width: width * 0.1, height: 1)
                }
                .padding(.horizontal, width * 0.09)
            } else {
                Text("Nothing on screen yet")
                    .font(.system(size: max(9, width * 0.032)))
                    .foregroundStyle(.black.opacity(0.3))
            }
        }
    }
}

/// GitHub-style activity grid, Sunday-aligned columns, newest on the right.
/// Rather than scrolling, it drops the oldest columns until the grid fits, then
/// centers what remains.
struct HeatmapView: View {
    let counts: [Date: Int]
    var maxWeeks = 26
    var cell: CGFloat = 13

    @State private var available: CGFloat = 0

    private var gap: CGFloat { max(3, cell * 0.24) }

    private var weeks: Int {
        guard available > 0 else { return maxWeeks }
        return max(4, min(maxWeeks, Int((available + gap) / (cell + gap))))
    }

    var body: some View {
        HStack(spacing: gap) {
            ForEach(days(), id: \.first) { week in
                VStack(spacing: gap) {
                    ForEach(week, id: \.self) { day in
                        RoundedRectangle(cornerRadius: cell * 0.24)
                            .fill(Ink.text.opacity(opacity(for: counts[day] ?? 0)))
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
        .accessibilityLabel("Activity over the last \(weeks) weeks")
    }

    private func opacity(for count: Int) -> Double {
        switch count {
        case 0: 0.07
        case 1...2: 0.24
        case 3...4: 0.45
        case 5...6: 0.7
        default: 0.92
        }
    }

    private func days() -> [[Date]] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let weekday = calendar.component(.weekday, from: today)   // 1 = Sunday
        guard let thisSunday = calendar.date(byAdding: .day, value: -(weekday - 1), to: today),
              let start = calendar.date(byAdding: .day, value: -7 * (weeks - 1), to: thisSunday)
        else { return [] }

        return (0..<weeks).map { week in
            (0..<7).compactMap { day in
                calendar.date(byAdding: .day, value: week * 7 + day, to: start)
            }
        }
    }
}

struct BatteryLabel: View {
    let level: Int?
    var iconOnly = false

    var body: some View {
        if let level {
            let tint = level <= 15 ? Ink.danger : Ink.secondary
            if iconOnly {
                Label("\(level)%", systemImage: symbol(level))
                    .labelStyle(.iconOnly)
                    .foregroundStyle(tint)
            } else {
                Label("\(level)%", systemImage: symbol(level))
                    .foregroundStyle(tint)
            }
        } else {
            Text("—").foregroundStyle(Ink.muted)
        }
    }

    private func symbol(_ level: Int) -> String {
        switch level {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

/// Battery as a small bar plus its number — reads at a glance in a spec sheet.
struct BatteryGauge: View {
    let level: Int?

    var body: some View {
        HStack(spacing: 8) {
            if let level {
                Capsule()
                    .fill(Ink.cardRule)
                    .frame(width: 46, height: 6)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(level <= 15 ? Ink.danger : Ink.text)
                            .frame(width: 46 * CGFloat(max(4, level)) / 100, height: 6)
                    }
                Text("\(level)%")
            } else {
                Text("—").foregroundStyle(Ink.muted)
            }
        }
    }
}

/// One row of the device spec sheet — kept identical everywhere so the rhythm holds.
struct SpecRow<Value: View>: View {
    let label: String
    var showsDivider = true
    /// Last row in a card: drops the trailing inset so the row sits the same
    /// distance from the card's bottom edge as the first row does from its top,
    /// rather than stacking 9pt on top of the card's own padding.
    var isLast = false
    @ViewBuilder var value: Value

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 12)
                // Never wrap. A long value (a 32-char hardware id) that wraps
                // makes this card taller than the preview card beside it, which
                // then stretches the preview card and leaves a gap under it.
                // Truncating keeps the row height — and both cards — stable.
                value
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.text)
                    .lineLimit(1)
            }
            .padding(.top, 9)
            .padding(.bottom, isLast ? 0 : 9)
            if showsDivider {
                Rectangle().fill(Ink.cardRule).frame(height: 1)
            }
        }
    }
}

/// "2m ago" / "Just now" — same phrasing as the other clients.
func relativeTime(_ date: Date?) -> String {
    guard let date else { return "—" }
    let seconds = Date.now.timeIntervalSince(date)
    if seconds < 60 { return "Just now" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: .now)
}
