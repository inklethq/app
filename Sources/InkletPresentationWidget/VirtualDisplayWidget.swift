// Shared with inklet-ios/portal/portalWidget.
import SwiftUI
import WidgetKit
import AppIntents
#if canImport(InkletPresentationKit)
import InkletPresentationKit
#endif

@available(iOS 17.0, macOS 14.0, *)
private struct VirtualDisplayEntry: TimelineEntry {
    let date: Date
    let id: UUID?
    let name: String?
    let image: Data?
    let message: String
}

@available(iOS 17.0, macOS 14.0, *)
private enum DisplayEntries {
    static func compatible(_ profile: VirtualDisplaySizeProfile) throws -> [VirtualDisplay] {
        (try VirtualDisplayStore().catalog()?.items ?? []).map(\.display).filter { $0.isCompatible(with: profile) }
    }
    static func entry(_ id: UUID?, profile: VirtualDisplaySizeProfile) -> VirtualDisplayEntry {
        let store = VirtualDisplayStore()
        let catalog = try? store.catalog()
        let record = catalog?.items.first { $0.display.id == id }
        let compatible = record?.display.isCompatible(with: profile) == true
        let frame = if let id, let session = catalog?.session, compatible { try? store.frame(id, session: session) } else { nil as VirtualDisplayFrame? }
        let validFrame = frame?.display.isCompatible(with: profile) == true
        let message: String
        if catalog == nil { message = "Open inklet and sign in to set up your display." }
        else if id == nil { message = "Edit this Widget to choose a \(profile.title) display. Create one in inklet → New Display." }
        else if record == nil { message = "This display is unavailable. Edit this Widget to choose another." }
        else if !compatible { message = "This display has a different size. Edit this Widget and select a \(profile.title) display." }
        else { message = "Open inklet to publish to this display." }
        return VirtualDisplayEntry(date: .now, id: compatible ? id : nil, name: compatible ? record?.display.name : profile.title,
                                   image: validFrame ? frame?.imageData : nil, message: message)
    }
    static func timeline(_ id: UUID?, profile: VirtualDisplaySizeProfile) async -> Timeline<VirtualDisplayEntry> {
        // Never fetch or show an incompatible old selection after a resize/upgrade.
        if let id, (try? compatible(profile).contains { $0.id == id }) == true {
            await VirtualDisplayReader.refresh(id: id)
        }
        let current = entry(id, profile: profile)
        return Timeline(entries: [current], policy: .after(current.date.addingTimeInterval(30 * 60)))
    }
}


@available(iOS 17.0, macOS 14.0, *)
struct VirtualDisplayEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Large Virtual Display"
    static let defaultQuery = VirtualDisplayQuery()
    let id: UUID
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}
@available(iOS 17.0, macOS 14.0, *)
struct VirtualDisplayQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [VirtualDisplayEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [VirtualDisplayEntity] {
        try DisplayEntries.compatible(.localLarge).map { VirtualDisplayEntity(id: $0.id, name: $0.name) }
    }
}
@available(iOS 17.0, macOS 14.0, *)
struct SelectVirtualDisplay: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose a Large Display"
    static let description = IntentDescription("Only displays created for this Widget size are available.")
    @Parameter(title: "Display") var display: VirtualDisplayEntity?
}
@available(iOS 17.0, macOS 14.0, *)
private struct VirtualDisplayProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> VirtualDisplayEntry { DisplayEntries.entry(nil, profile: .localLarge) }
    func snapshot(for configuration: SelectVirtualDisplay, in context: Context) async -> VirtualDisplayEntry {
        DisplayEntries.entry(context.family == .systemLarge ? configuration.display?.id : nil, profile: .localLarge)
    }
    func timeline(for configuration: SelectVirtualDisplay, in context: Context) async -> Timeline<VirtualDisplayEntry> {
        await DisplayEntries.timeline(context.family == .systemLarge ? configuration.display?.id : nil, profile: .localLarge)
    }
}


@available(iOS 17.0, macOS 14.0, *)
struct VirtualDisplayExtraLargeEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Extra Large Virtual Display"
    static let defaultQuery = VirtualDisplayExtraLargeQuery()
    let id: UUID
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}
@available(iOS 17.0, macOS 14.0, *)
struct VirtualDisplayExtraLargeQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [VirtualDisplayExtraLargeEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [VirtualDisplayExtraLargeEntity] {
        try DisplayEntries.compatible(.localExtraLarge).map { VirtualDisplayExtraLargeEntity(id: $0.id, name: $0.name) }
    }
}
@available(iOS 17.0, macOS 14.0, *)
struct SelectVirtualDisplayExtraLarge: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose a Extra Large Display"
    static let description = IntentDescription("Only displays created for this Widget size are available.")
    @Parameter(title: "Display") var display: VirtualDisplayExtraLargeEntity?
}
@available(iOS 17.0, macOS 14.0, *)
private struct VirtualDisplayExtraLargeProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> VirtualDisplayEntry { DisplayEntries.entry(nil, profile: .localExtraLarge) }
    func snapshot(for configuration: SelectVirtualDisplayExtraLarge, in context: Context) async -> VirtualDisplayEntry {
        DisplayEntries.entry(context.family == .systemExtraLarge ? configuration.display?.id : nil, profile: .localExtraLarge)
    }
    func timeline(for configuration: SelectVirtualDisplayExtraLarge, in context: Context) async -> Timeline<VirtualDisplayEntry> {
        await DisplayEntries.timeline(context.family == .systemExtraLarge ? configuration.display?.id : nil, profile: .localExtraLarge)
    }
}

/// Letterbox the entire composition on every supported widget size.
@available(iOS 17.0, macOS 14.0, *)
public struct VirtualDisplayCanvas: View {
    let data: Data?
    let name: String
    let message: String
    public init(data: Data?, name: String = "Your virtual inklet display", message: String = "Open inklet to publish text or an image.") {
        self.data = data; self.name = name; self.message = message
    }
    private var image: Image? {
        guard let data else { return nil }
        #if os(macOS)
        return NSImage(data: data).map { Image(nsImage: $0) }
        #else
        return UIImage(data: data).map { Image(uiImage: $0) }
        #endif
    }
    private func brand(_ size: CGFloat) -> Font {
        #if os(macOS)
        WidgetFonts.brand(size)
        #else
        .custom("Newsreader-Regular", size: size)
        #endif
    }
    @ViewBuilder private func fullColor(_ image: Image) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            image.renderingMode(.original).resizable().widgetAccentedRenderingMode(.fullColor)
        } else { image.renderingMode(.original).resizable() }
    }
    public var body: some View {
        Group {
            if let image {
                fullColor(image).scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white).accessibilityLabel(name)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("inklet").font(brand(28))
                    Spacer(minLength: 12)
                    Image(systemName: "rectangle.inset.filled").font(.system(size: 28, weight: .light)).accessibilityHidden(true)
                    Text(name).font(brand(29)).lineLimit(3)
                    Text(message).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .foregroundStyle(Color(red: 0.20, green: 0.18, blue: 0.16))
                .background(Color(red: 0.97, green: 0.96, blue: 0.93))
            }
        }.clipped()
    }
}


@available(iOS 17.0, macOS 14.0, *)
public struct InkletPresentationWidget: Widget {
    public init() {}
    public var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "InkletPresentationWidget", intent: SelectVirtualDisplay.self, provider: VirtualDisplayProvider()) { entry in
            VirtualDisplayCanvas(data: entry.image, name: entry.name ?? "Large display", message: entry.message)
                .containerBackground(.white, for: .widget)
                .widgetURL(VirtualDisplayLinks.url(id: entry.id))
        }
        .configurationDisplayName("Virtual Display · Large")
        .description("Choose a display created for the large Widget canvas.")
        .supportedFamilies([.systemLarge])
        .contentMarginsDisabled()
    }
}


@available(iOS 17.0, macOS 14.0, *)
public struct InkletExtraLargePresentationWidget: Widget {
    public init() {}
    public var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "InkletExtraLargePresentationWidget", intent: SelectVirtualDisplayExtraLarge.self, provider: VirtualDisplayExtraLargeProvider()) { entry in
            VirtualDisplayCanvas(data: entry.image, name: entry.name ?? "Extra Large display", message: entry.message)
                .containerBackground(.white, for: .widget)
                .widgetURL(VirtualDisplayLinks.url(id: entry.id))
        }
        .configurationDisplayName("Virtual Display · Extra Large")
        .description("Choose a display created for the extra large Widget canvas.")
        .supportedFamilies([.systemExtraLarge])
        .contentMarginsDisabled()
    }
}
