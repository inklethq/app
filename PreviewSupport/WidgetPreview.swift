import AppKit
import Foundation
import InkletPresentationKit
import InkletPresentationWidget
import SwiftUI

/// Offline visual QA using the same SwiftUI content views as the extension.
/// Writes sample renders only; never touches the App Group or a user account.
@main
struct WidgetPreview {
    @MainActor
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/inklet-widget-previews")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let displayImage = try render(SamplePresentation().frame(width: 360, height: 376))
        try displayImage.write(to: output.appending(path: "sample-presentation.png"))
        let presentation = try JSONDecoder().decode(GeneratedPresentationDTO.self, from: Data("""
            {"id":"preview","contentIds":[],"mode":"auto","state":"ready","renditions":[],
             "createdAt":"2026-09-05T00:00:00Z","updatedAt":"2026-09-05T00:00:00Z"}
            """.utf8))
        let snapshot = CachedPresentationSnapshot(metadata: .init(presentation: presentation, imageFilename: nil),
                                                   imageData: displayImage)
        let date = Date(timeIntervalSince1970: 1_788_566_400)
        let today = Calendar.current.startOfDay(for: date)
        var counts: [Date: Int] = [:]
        for i in 0..<140 {
            let day = Calendar.current.date(byAdding: .day, value: -i, to: today)!
            counts[day] = (i * 3 + i / 5) % 7
        }

        for scheme in [ColorScheme.light, .dark] {
            let name = scheme == .light ? "light" : "dark"
            let sheet = PreviewSheet(snapshot: snapshot, counts: counts, date: date, scheme: scheme)
                .environment(\.colorScheme, scheme)
            let image = try render(sheet)
            try image.write(to: output.appending(path: "widgets-\(name).png"))
        }
        for profile in [VirtualDisplaySizeProfile.macLarge, .macExtraLarge] {
            let size = CGSize(width: profile.width * 2, height: profile.height * 2)
            let data = try VirtualDisplayRenderer.text("慢慢来，比较快。\n\n给重要的事情留一点空间。", size: size)
            let canvas = VirtualDisplayCanvas(data: data, name: profile.title)
                .frame(width: CGFloat(profile.width), height: CGFloat(profile.height))
            try render(canvas).write(to: output.appending(path: "virtual-\(profile.rawValue).png"))
        }
        print("Widget previews: \(output.path)")
    }

    @MainActor
    private static func render<Content: View>(_ content: Content) throws -> Data {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }
}

private struct PreviewSheet: View {
    let snapshot: CachedPresentationSnapshot
    let counts: [Date: Int]
    let date: Date
    let scheme: ColorScheme

    private var paper: Color {
        scheme == .light ? Color(red: 245/255, green: 243/255, blue: 237/255) : Color(white: 26/255)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("inklet · macOS Widgets")
                .font(.system(size: 25, weight: .medium))
            Text("Small and medium follow iOS. Large is a virtual inklet display. · Sample content")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    label("SMALL · QUICK SEND")
                    QuickSendWidgetContent()
                        .padding(16).frame(width: 170, height: 170)
                        .background(paper, in: .rect(cornerRadius: 22))
                    label("MEDIUM · ACTIVITY")
                        .padding(.top, 24)
                    ActivityWidgetContent(counts: counts, date: date)
                        .padding(16).frame(width: 360, height: 170)
                        .background(paper, in: .rect(cornerRadius: 22))
                }
                VStack(alignment: .leading, spacing: 12) {
                    label("LARGE · VIRTUAL DISPLAY")
                    VirtualDisplayCanvas(data: snapshot.imageData, name: "Desk")
                        .frame(width: 360, height: 376)
                        .clipShape(.rect(cornerRadius: 22))
                }
                VStack(alignment: .leading, spacing: 12) {
                    label("LARGE · EMPTY STATE")
                    VirtualDisplayCanvas(data: nil, message: "Edit this widget to choose a Virtual Display. Create one in inklet → New Display.")
                        .frame(width: 360, height: 376)
                        .clipShape(.rect(cornerRadius: 22))
                }
            }
        }
        .padding(36)
        .background(scheme == .light ? Color(white: 0.89) : Color(white: 0.09))
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .medium)).tracking(1.3).foregroundStyle(.secondary)
    }
}

private struct SamplePresentation: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A NOTE FOR TODAY")
                .font(.system(size: 10, weight: .medium)).tracking(2)
            Spacer()
            Text("Make room\nfor the things\nthat matter.")
                .font(.system(size: 34, weight: .regular, design: .serif))
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
            Rectangle().frame(width: 42, height: 1).padding(.vertical, 5)
            Text("One thought. A little space.\nSomething worth returning to.")
                .font(.system(size: 13)).lineSpacing(5)
                .foregroundStyle(.black.opacity(0.6))
            Spacer()
            HStack {
                Text("inklet").font(.system(size: 17, design: .serif))
                Spacer()
                Text("05 SEP").font(.system(size: 9)).tracking(1.5)
            }
        }
        .padding(30)
        .foregroundStyle(.black)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color(red: 253/255, green: 252/255, blue: 249/255))
    }
}
