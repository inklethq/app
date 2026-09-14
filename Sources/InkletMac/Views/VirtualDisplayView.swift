import InkletPresentationWidget
import InkletPresentationKit
import SwiftUI

struct VirtualDisplayView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("On this Mac")
                    Text("Virtual Display")
                        .font(.brand(34))
                    Text("Your latest Presentation, at home on your desktop.")
                        .font(.system(size: 14))
                        .foregroundStyle(Ink.secondary)
                }

                HStack(alignment: .top, spacing: 24) {
                    VirtualDisplayContent(snapshot: model.virtualDisplay)
                        .aspectRatio(360.0 / 376, contentMode: .fit)
                        .frame(maxWidth: 440)
                        .clipShape(.rect(cornerRadius: 22))
                        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(Ink.border) }

                    VStack(alignment: .leading, spacing: 16) {
                        if WidgetStorage.isLocalPreview {
                            Text("Local preview build. Desktop widget syncing is available in the signed app.")
                                .font(.system(size: 12))
                                .foregroundStyle(Ink.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Keep it in view")
                            .font(.system(size: 16, weight: .medium))
                        Text("Control-click your desktop, choose Edit Widgets, then search for inklet and add Virtual Display.")
                            .font(.system(size: 14))
                            .foregroundStyle(Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Quick Send comes in small. Activity comes in medium. Virtual Display comes in large.")
                            .font(.system(size: 13))
                            .foregroundStyle(Ink.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Create Presentation", systemImage: "square.and.pencil") { model.startComposing() }
                            .buttonStyle(.borderedProminent)
                        if let date = model.virtualDisplay?.metadata.cachedAt {
                            Text("Updated \(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 12))
                                .foregroundStyle(Ink.muted)
                        }
                    }
                    .frame(maxWidth: 280, alignment: .leading)
                    .padding(.top, 12)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Ink.text)
        .background(Ink.bg)
        .navigationTitle("Virtual Display")
        .task { model.reloadVirtualDisplay() }
    }
}
