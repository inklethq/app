import SwiftUI

/// Search box drawn in the ink palette.
///
/// `NSSearchField` is the native choice, but its fill comes from the system's
/// cool `textBackgroundColor`, which reads blue-black against warm paper. This
/// keeps the same anatomy — magnifier, prompt, clear button, focus ring — in the
/// app's own tones.
struct InkSearchField: View {
    @Binding var text: String
    var placeholder = "Search"

    @FocusState private var isFocused: Bool

    private let corner: CGFloat = 8

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ink.muted)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Ink.text)
                .focused($isFocused)

            if !text.isEmpty {
                Button {
                    text = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.muted)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Ink.input, in: .rect(cornerRadius: corner))
        .overlay {
            RoundedRectangle(cornerRadius: corner)
                .strokeBorder(isFocused ? Ink.text.opacity(0.5) : Ink.border,
                              lineWidth: isFocused ? 1.5 : 1)
        }
        .contentShape(.rect(cornerRadius: corner))
        .onTapGesture { isFocused = true }
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}
