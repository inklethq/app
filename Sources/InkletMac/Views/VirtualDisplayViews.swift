import SwiftUI
import InkletPresentationKit

struct VirtualDisplayDetailView: View {
    let id: UUID
    @EnvironmentObject private var virtuals: VirtualDisplayController
    @Environment(AppModel.self) private var model
    @State private var renaming = false
    @State private var draftName = ""
    @State private var confirmingDelete = false
    private var display: VirtualDisplay? { virtuals.displays.first { $0.id == id } }
    private var frame: VirtualDisplayFrame? { virtuals.frames[id] }

    var body: some View {
        Group {
            if let display {
                DisplayDetailLayout {
                    DisplayPreviewCard {
                        HStack(spacing: 7) {
                            Image(systemName: "macwindow").font(.system(size: 12))
                            Text("Virtual Display").font(.system(size: 12, weight: .medium))
                            Spacer()
                        }.foregroundStyle(Ink.secondary)
                    } preview: {
                        VirtualFramePreview(data: frame?.imageData)
                            .aspectRatio(CGFloat(display.width) / CGFloat(display.height), contentMode: .fit)
                    } caption: {
                        Text(display.revision > 0 ? "Published revision \(display.revision)" : "Nothing on screen yet")
                    }
                } information: {
                    InkCard(stretches: true) {
                        VStack(alignment: .leading, spacing: 0) {
                            SectionLabel("Up next").padding(.bottom, 8)
                            Text("This display keeps its latest publication.")
                                .font(.system(size: 13)).foregroundStyle(Ink.muted)
                                .frame(height: 38, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.bottom, 12)
                            Rectangle().fill(Ink.cardRule).frame(height: 1)
                            SectionLabel("Device").padding(.top, 14).padding(.bottom, 4)
                            SpecRow(label: "Model") { Text("Virtual Display") }
                            SpecRow(label: "Display ID") {
                                Text(id.uuidString.lowercased()).monospaced().truncationMode(.middle)
                                    .textSelection(.enabled).help(id.uuidString.lowercased())
                            }
                            SpecRow(label: "Canvas") { Text(display.profile?.title ?? "Original display") }
                            SpecRow(label: "Resolution") { Text("\(display.width * 2) × \(display.height * 2)") }
                            SpecRow(label: "Revision", showsDivider: false, isLast: true) { Text("\(display.revision)") }
                            Spacer(minLength: 0)
                        }
                    }
                } history: {
                    InkCard {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                SectionLabel("Queue & history")
                                Spacer()
                                Text(display.revision > 0 ? "Latest publication" : "0 items")
                                    .font(.system(size: 12)).foregroundStyle(Ink.muted)
                            }.padding(.bottom, 10)
                            if display.revision > 0 {
                                HStack(spacing: 12) {
                                    Text(frame?.text.isEmpty == false ? (frame?.text ?? "") : "Image presentation")
                                        .font(.system(size: 14)).lineLimit(2)
                                    Spacer()
                                    Text("Published").font(.system(size: 11, weight: .medium))
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(Ink.input, in: .rect(cornerRadius: 5))
                                }.foregroundStyle(Ink.text).frame(minHeight: 46)
                            } else {
                                Text("Anything you push to this display shows up here.")
                                    .font(.system(size: 13)).foregroundStyle(Ink.muted)
                                    .frame(maxWidth: .infinity).padding(.vertical, 28)
                            }
                        }
                    }
                }
                .navigationTitle(display.name)
                .navigationSubtitle(id.uuidString.lowercased())
                .toolbar {
                    if #available(macOS 26.0, *) {
                        ToolbarSpacer(.fixed, placement: .primaryAction)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu("Actions", systemImage: "ellipsis.circle") {
                            Button("Push Here…") { model.startComposing(virtualDisplayID: id) }
                            Button("Rename…") { draftName = display.name; renaming = true }
                            Button("Refresh") { Task { await virtuals.refresh() } }
                            Divider()
                            Button("Delete Display…", role: .destructive) { confirmingDelete = true }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Display not found", systemImage: "questionmark.square.dashed")
            }
        }
        .task(id: id) { await virtuals.refresh() }
        .sheet(isPresented: $renaming) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Rename display").font(.brand(22))
                TextField("Name", text: $draftName).textFieldStyle(.roundedBorder)
                if let error = virtuals.error { Text(error).foregroundStyle(Ink.danger).font(.system(size: 12)) }
                HStack {
                    Spacer()
                    Button("Cancel") { renaming = false }
                    Button("Save") { Task {
                        if await virtuals.rename(id: id, name: draftName.trimmingCharacters(in: .whitespacesAndNewlines)) { renaming = false }
                    } }.keyboardShortcut(.defaultAction)
                        .disabled(virtuals.busy || draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draftName.unicodeScalars.count > 80)
                }
            }.padding(24).frame(width: 360).background(Ink.bg)
        }
        .confirmationDialog("Delete this display?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Display", role: .destructive) { Task { _ = await virtuals.delete(id: id) } }
        } message: { Text("Its current frame will be deleted. Widgets using it will need another display.") }
    }
}

struct VirtualFramePreview: View {
    let data: Data?
    private var image: Image? {
        guard let data else { return nil }
        #if os(macOS)
        return NSImage(data: data).map { Image(nsImage: $0) }
        #else
        return UIImage(data: data).map { Image(uiImage: $0) }
        #endif
    }
    var body: some View {
        Group {
            if let image { image.resizable().scaledToFit() }
            else { VStack(spacing: 12) { Image(systemName: "rectangle.inset.filled").font(.largeTitle); Text("Your next thought goes here").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.background(.white).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
