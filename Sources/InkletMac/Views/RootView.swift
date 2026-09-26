import SwiftUI
import InkletPresentationKit

enum SidebarItem: Hashable {
    case home
    case knowledge
    case ask
    case history
    case newDisplay
    case virtualDisplayDetail(UUID)
    case device(String)
    case pair
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var virtuals: VirtualDisplayController
    @Environment(WidgetRouter.self) private var widgetRouter
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: SidebarItem? = .home
    @State private var askPath = NavigationPath()
    @State private var historyPath = NavigationPath()
    @State private var knowledgePath = NavigationPath()

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            Sidebar(selection: Binding(
                get: { selection },
                set: { item in
                    askPath = NavigationPath()
                    historyPath = NavigationPath()
                    knowledgePath = NavigationPath()
                    selection = item
                }
            ))
                .navigationSplitViewColumnWidth(min: 208, ideal: 228, max: 300)
        } detail: {
            detail
                // Keep each sidebar page's navigation column identity separate;
                // SwiftUI cannot compare the different destination value types.
                .id(selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Ink.bg.ignoresSafeArea())
                .toolbar {
                    if selection != .ask && selection != .history && selection != .knowledge {
                        ComposerToolbar()
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let error = model.loadError {
                        ErrorBar(message: error) { Task { await model.refresh() } }
                    }
                }
        }
        .onChange(of: selection) { previous, _ in
            // Preserve an incoming History deep link while dismissing the page
            // being left, including navigation initiated outside the sidebar.
            if previous == .ask { askPath = NavigationPath() }
            if previous == .history { historyPath = NavigationPath() }
            if previous == .knowledge { knowledgePath = NavigationPath() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.virtualDisplays.refresh() } }
        }
        .tint(Ink.text)
        .background(WindowStyler(constrainSize: true).frame(width: 0, height: 0))
        // A display that vanishes (unbound elsewhere, or here) must not leave the
        // detail pane pointed at a dead id.
        .onChange(of: model.devices.map(\.id)) { _, ids in
            if case .device(let id) = selection, !ids.contains(id) { selection = .home }
        }
        .onChange(of: virtuals.displays.map(\.id)) { _, ids in
            if case .virtualDisplayDetail(let id) = selection, !ids.contains(id), !virtuals.busy { selection = .home }
        }
        // Pages that cannot reach this selection ask through the model: a
        // device page sending the user to the run behind a picture.
        .onChange(of: model.requestedSidebarItem) { _, item in
            guard let item else { return }
            selection = item
            model.requestedSidebarItem = nil
        }
        .onChange(of: widgetRouter.pending, initial: true) { _, destination in
            guard let destination else { return }
            widgetRouter.pending = nil
            switch destination {
            case .send: model.startComposing()
            case .activity: selection = .home
            case .display:
                model.reloadVirtualDisplay()
                if let id = widgetRouter.pendingDisplayID {
                    selection = .virtualDisplayDetail(id)
                    widgetRouter.pendingDisplayID = nil
                } else if let display = virtuals.displays.first { selection = .virtualDisplayDetail(display.id) }
                else { selection = .newDisplay }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .home:
            HomeView(selection: $selection)
        case .knowledge:
            KnowledgeView(path: $knowledgePath)
        case .ask:
            AskView(path: $askPath)
        case .history:
            HistoryView(path: $historyPath)
        case .virtualDisplayDetail(let id):
            NavigationStack { VirtualDisplayDetailView(id: id).id(id) }
        case .newDisplay:
            NewDisplayView(selection: $selection)
        case .device(let id):
            if let device = model.device(withID: id) {
                DeviceDetailView(device: device)
                    .id(device.id)
            } else {
                ContentUnavailableView("Display not found", systemImage: "questionmark.square.dashed")
            }
        case .pair:
            VStack(alignment: .leading, spacing: 0) {
                Button { selection = .newDisplay } label: { Label("New Display", systemImage: "chevron.left") }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Ink.secondary)
                    .padding(.horizontal, 28).padding(.top, 18)
                PairDisplayView(selection: $selection)
            }
        case nil:
            ContentUnavailableView("Nothing selected", systemImage: "sidebar.left")
        }
    }
}

/// Shared by the window's pages and each native navigation destination.
/// A pushed destination owns its toolbar, so it must also supply Create.
struct ComposerToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    var newConversation: (() -> Void)? = nil

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
        }
        if let newConversation {
            ToolbarItem(placement: .primaryAction) {
                Button("New conversation", systemImage: "plus", action: newConversation)
                    .help("New conversation")
                    .disabled(model.ask.isSending)
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Create", systemImage: "square.and.pencil") { model.startComposing() }
                .help("Create an inklet Presentation (\(ShortcutStore.shared.shortcut.display))")
        }
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var virtuals: VirtualDisplayController
    @Binding var selection: SidebarItem?

    var body: some View {
        // Flat rows rather than Sections: AppKit gives a sidebar Section's header
        // its own leading inset that listRowInsets can't take back, which left the
        // group titles indented past the row icons.
        List {
            Group {
                GroupLabel("Workspace", topPadding: 4)
                SidebarRow(icon: "house", title: "Home", item: .home, selection: $selection)
                SidebarRow(icon: "books.vertical", title: "Knowledge", item: .knowledge, selection: $selection)
                SidebarRow(icon: "bubble.left.and.text.bubble.right", title: "Ask", item: .ask, selection: $selection)
                SidebarRow(icon: "clock.arrow.circlepath", title: "History", item: .history, selection: $selection)

                GroupLabel("Displays", topPadding: 18)
                ForEach(model.devices) { device in
                    // `display` draws a monitor on a stand, so its panel is small
                    // and sits high. This one is a bare 4:3 frame — much closer to
                    // the real thing, which is a flat panel with no base.
                    SidebarRow(icon: device.icon, title: device.displayName,
                               item: .device(device.id), selection: $selection) {
                        StatusDot(online: device.online, size: 7)
                    }
                    .contextMenu {
                        Button("Push Here…") { model.startComposing(target: device) }
                        Button("Show Next") { Task { try? await model.showNext(device) } }
                        Divider()
                        Button("Unbind…", role: .destructive) {
                            Task { await model.unbind(device) }
                        }
                    }
                }
                ForEach(virtuals.displays) { display in
                    SidebarRow(icon: "macwindow", title: display.name,
                               item: .virtualDisplayDetail(display.id), selection: $selection)
                        .help(display.profile?.title ?? "Virtual Display")
                }
                if model.devices.isEmpty && virtuals.displays.isEmpty && !model.isLoading && !virtuals.busy {
                    Text("No displays yet")
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.muted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                SidebarRow(icon: "plus", title: "New Display",
                           item: .newDisplay, selection: $selection, dim: true)
            }
            .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
            .listRowSeparator(.hidden)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Ink.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { AccountBar() }
    }
}

/// Group heading that shares the rows' left edge exactly.
private struct GroupLabel: View {
    let title: String
    var topPadding: CGFloat

    init(_ title: String, topPadding: CGFloat = 4) {
        self.title = title
        self.topPadding = topPadding
    }

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Ink.secondary)
            .padding(.leading, 10)
            .padding(.top, topPadding)
            .padding(.bottom, 3)
    }
}

/// Selection is drawn by hand: macOS paints List selection with the system accent
/// color, and an app-level accent needs an asset catalog we can't build without Xcode.
private struct SidebarRow<Accessory: View>: View {
    let icon: Image
    let title: String
    let item: SidebarItem
    @Binding var selection: SidebarItem?
    var dim = false
    @ViewBuilder var accessory: Accessory

    @State private var isHovering = false

    private var isSelected: Bool { selection == item }

    /// Most rows are an SF Symbol; a device row brings its own image.
    init(icon symbol: String, title: String, item: SidebarItem,
         selection: Binding<SidebarItem?>, dim: Bool = false, @ViewBuilder accessory: () -> Accessory) {
        self.init(icon: Image(systemName: symbol), title: title, item: item,
                  selection: selection, dim: dim, accessory: accessory)
    }

    init(icon: Image, title: String, item: SidebarItem,
         selection: Binding<SidebarItem?>, dim: Bool = false, @ViewBuilder accessory: () -> Accessory) {
        self.icon = icon
        self.title = title
        self.item = item
        self._selection = selection
        self.dim = dim
        self.accessory = accessory()
    }

    var body: some View {
        Button {
            selection = item
        } label: {
            HStack(spacing: 9) {
                icon
                    .font(.system(size: 13))
                    .frame(width: 17)
                Text(title)
                    .font(.system(size: 14))
                    .lineLimit(1)
                Spacer(minLength: 4)
                accessory
            }
            .foregroundStyle(isSelected ? Ink.bg : (dim ? Ink.muted : Ink.text))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Ink.text : (isHovering ? Ink.border.opacity(0.55) : .clear))
            }
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        // No leading inset: sidebar rows start at the edge instead of sitting in
        // the gutter AppKit reserves for disclosure triangles.
        .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
        .listRowSeparator(.hidden)
    }
}

extension SidebarRow where Accessory == EmptyView {
    init(icon: String, title: String, item: SidebarItem,
         selection: Binding<SidebarItem?>, dim: Bool = false) {
        self.init(icon: icon, title: title, item: item, selection: selection, dim: dim) { EmptyView() }
    }

    init(icon: Image, title: String, item: SidebarItem,
         selection: Binding<SidebarItem?>, dim: Bool = false) {
        self.init(icon: icon, title: title, item: item, selection: selection, dim: dim) { EmptyView() }
    }
}

private struct AccountBar: View {
    @Environment(AppModel.self) private var model
    @Environment(Session.self) private var session
    @Environment(\.openSettings) private var openSettings
    @State private var isHovering = false
    @State private var menu = NativeMenu()

    var body: some View {
        Button {
            menu.present([
                .init(title: "Refresh", symbol: "arrow.clockwise") {
                    Task { await model.refresh() }
                },
                .init(title: "Settings…", symbol: "gearshape") { openSettings() },
                .init(title: "Manage Subscription", symbol: "creditcard") {
                    NSWorkspace.shared.open(URL(string: "https://portal.iminklet.com")!)
                },
                .init(title: "API Tokens", symbol: "key") {
                    NSWorkspace.shared.open(URL(string: "https://portal.iminklet.com/api-tokens")!)
                },
                .separator,
                .init(title: "Sign Out", symbol: "rectangle.portrait.and.arrow.right", isDestructive: true) {
                    Task { await session.signOut() }
                },
            ])
        } label: {
            HStack(spacing: 10) {
                Text(model.account.username.prefix(1).lowercased())
                    .font(.brand(20))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 34, height: 34)
                    .background(Ink.input, in: .circle)
                    .overlay { Circle().strokeBorder(Ink.border) }

                VStack(alignment: .leading, spacing: 1) {
                    Text(model.account.username)
                        .font(.system(size: 14))
                        .foregroundStyle(Ink.text)
                    Text(model.account.plan.capitalized)
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.muted)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.muted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 9)
                    .fill(isHovering ? Ink.border.opacity(0.55) : .clear)
            }
            .contentShape(.rect(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(alignment: .top) {
            Rectangle().fill(Ink.border).frame(height: 1)
        }
    }
}

/// Sits under the content rather than over it: a failed refresh shouldn't hide
/// the data that's still on screen from the last successful one.
private struct ErrorBar: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(Ink.danger)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Ink.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Retry", action: retry)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ink.text)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(Ink.card)
        .background(alignment: .top) {
            Rectangle().fill(Ink.border).frame(height: 1)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
