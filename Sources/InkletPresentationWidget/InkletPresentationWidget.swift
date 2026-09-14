import AppKit
import InkletPresentationKit
import SwiftUI
import WidgetKit

/// Preserve the whole rendered composition instead of cropping an inklet frame.
public struct VirtualDisplayContent: View {
    let snapshot: CachedPresentationSnapshot?
    let isSignedIn: Bool

    public init(snapshot: CachedPresentationSnapshot?, isSignedIn: Bool = true) {
        self.snapshot = snapshot
        self.isSignedIn = isSignedIn
    }

    public var body: some View {
        Group {
            if let data = snapshot?.imageData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .renderingMode(.original)
                    .resizable()
                    .widgetAccentedRenderingMode(.fullColor)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white)
                    .accessibilityLabel("Your virtual inklet display")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("inklet").font(WidgetFonts.brand(27))
                    Spacer(minLength: 12)
                    Image(systemName: "rectangle.inset.filled")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(WidgetPalette.foreground.opacity(0.45))
                        .accessibilityHidden(true)
                    Text("Your virtual\ninklet display")
                        .font(WidgetFonts.brand(29))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(isSignedIn
                         ? "A quiet place for your next thought. Create a Presentation to put it here."
                         : "Sign in to inklet to bring your content to the desktop.")
                        .font(WidgetFonts.body(13))
                        .foregroundStyle(WidgetPalette.foreground.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(WidgetPalette.foreground)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(WidgetPalette.background)
            }
        }
        .clipped()
    }
}

