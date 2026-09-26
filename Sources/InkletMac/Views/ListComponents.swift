import SwiftUI

/// Shared card, separators and interaction style for the three content lists.
struct InkItemList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder var row: (Item) -> Row

    var body: some View {
        InkCard(padding: 0) {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    row(item)
                    if item.id != items.last?.id {
                        Rectangle().fill(Ink.cardRule).frame(height: 1)
                            .padding(.horizontal, 16)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }
}

/// Padding belongs to the button label so every point in the row opens it.
struct InkListRow<Leading: View, Metadata: View>: View {
    let title: String
    var subtitle: String? = nil
    var titleColor: Color = Ink.text
    var subtitleColor: Color = Ink.muted
    let action: () -> Void
    @ViewBuilder var leading: Leading
    @ViewBuilder var metadata: Metadata

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                leading
                    .font(.system(size: 14))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(InkType.metadata)
                            .foregroundStyle(subtitleColor)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                metadata
                    .font(InkType.metadata)
                    .foregroundStyle(Ink.muted)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Ink.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(InkListRowButtonStyle())
    }
}

/// Own the hover on the complete button, not on a text or an inner stack.
struct InkListRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowFeedback(configuration: configuration)
    }

    private struct RowFeedback: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Ink.text.opacity(isEnabled ? (configuration.isPressed ? 0.10 : (isHovering ? 0.05 : 0)) : 0))
                .contentShape(.rect)
                .onHover { isHovering = $0 }
                .onDisappear { isHovering = false }
        }
    }
}

/// Keep native segmented-control behavior and sizing identical across filters.
struct InkSegmentedPicker<Selection: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: Selection
    var showsLabel = false
    @ViewBuilder var options: Options

    var body: some View {
        HStack(spacing: 10) {
            if showsLabel {
                Text(title).font(InkType.metadata).foregroundStyle(Ink.secondary)
                    .fixedSize()
            }
            Picker(title, selection: $selection) { options }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: 28)
    }
}
