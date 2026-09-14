import SwiftUI

/// All display integrations share this page. Adapters supply the preview,
/// available device information and history without redefining the layout.
struct DisplayDetailLayout<Preview: View, Information: View, History: View>: View {
    @ViewBuilder var preview: Preview
    @ViewBuilder var information: Information
    @ViewBuilder var history: History
    @State private var width: CGFloat = 900

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if width > 820 {
                    HStack(alignment: .top, spacing: 20) {
                        preview.frame(maxWidth: width * 0.52)
                        information
                    }.fixedSize(horizontal: false, vertical: true)
                } else {
                    preview
                    information
                }
                history
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .scrollIndicators(.never)
        .background(Ink.bg)
    }
}

struct DisplayPreviewCard<Status: View, Preview: View, Caption: View>: View {
    @ViewBuilder var status: Status
    @ViewBuilder var preview: Preview
    @ViewBuilder var caption: Caption
    var body: some View {
        InkCard(padding: 16, stretches: true) {
            VStack(spacing: 0) {
                status
                Spacer(minLength: 14)
                VStack(spacing: 12) {
                    preview
                    caption.font(.system(size: 12)).foregroundStyle(Ink.muted)
                }
                Spacer(minLength: 0)
            }
        }
    }
}
