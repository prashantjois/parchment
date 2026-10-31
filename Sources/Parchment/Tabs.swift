import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ParchmentIntegration

enum TabCloseScope { case before, after, all }
enum TabDropEdge { case before, after }

@MainActor extension Workspace {
    func activateTab(_ id: UUID) {
        guard documents.contains(where: { $0.id == id }) else { return }
        activeID = id; showTabSearch = false
        focusActiveDocument(); scheduleRecovery()
    }
    func focusActiveDocument() {
        active?.focusRequest = UUID()
        activeTabRevealRequest = UUID()
    }
    func presentTabSearch() {
        guard !documents.isEmpty, !showThemes, !composeComment else { return }
        showTabSearch = true
    }
    func searchTabs(_ query: String) -> [EditorDocument] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return documents.filter { document in
            let draftTitle = document.url == nil ? String(document.text.prefix(while: { !$0.isNewline })) : ""
            let searchable = document.title + " " + (document.url?.path ?? draftTitle)
            return terms.allSatisfy { searchable.localizedStandardContains($0) }
        }
    }
    @discardableResult func moveTab(_ id: UUID, relativeTo target: UUID, edge: TabDropEdge) -> Bool {
        guard id != target, let source = documents.firstIndex(where: { $0.id == id }),
              documents.contains(where: { $0.id == target }) else { return false }
        var reordered = documents
        let document = reordered.remove(at: source)
        guard let destination = reordered.firstIndex(where: { $0.id == target }) else { return false }
        reordered.insert(document, at: destination + (edge == .after ? 1 : 0))
        guard reordered.map(\.id) != documents.map(\.id) else { return false }
        documents = reordered
        scheduleRecovery()
        return true
    }

    func tabsToClose(_ scope: TabCloseScope, relativeTo id: UUID? = nil) -> [EditorDocument] {
        if scope == .all { return documents }
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return [] }
        return scope == .before ? Array(documents.prefix(index)) : Array(documents.suffix(from: index + 1))
    }

    @discardableResult func closeTabs(_ scope: TabCloseScope, relativeTo id: UUID? = nil,
                                     confirm: @MainActor (EditorDocument) -> NSApplication.ModalResponse = Workspace.confirmClose) -> Bool {
        // Snapshot the targets: closing the active tab can select a different tab.
        for document in tabsToClose(scope, relativeTo: id) {
            guard close(document, confirm: confirm) else { return false }
        }
        return true
    }
}

enum DocumentTabDrag {
    static let type = UTType(exportedAs: "local.parchment.document-tab", conformingTo: .data)
    static func provider(for id: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(Data(id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }
}

struct DocumentTab: View {
    @ObservedObject var document: EditorDocument
    @ObservedObject var workspace: Workspace
    @ViewState private var width: CGFloat = 130
    @ViewState private var dropEdge: TabDropEdge?
    private var selected: Bool { workspace.activeID == document.id }
    private func comment() { workspace.beginFileComment(document) }

    private func attachmentStatus(_ session: JSON, _ request: JSON?) -> String {
        if let request {
            if request["last_error"].string != nil { return " — delivery failed; retrying" }
            if session["receiver_registered"].int != 1 { return " — queued; waiting for agent" }
            return request["accepted_at"] == .null ? " — request pending" : " — queued; awaiting attachment"
        }
        return session["receiver_registered"].int == 1 ? "" : " — automatic wake-up off"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text").font(.caption).foregroundStyle(.secondary)
            Text(document.title).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
                .background(TabCommentHover(action: comment).frame(height: 38))
                .help(document.url?.path ?? "Unsaved document")
            if document.isDirty { Circle().fill(.secondary).frame(width: 5, height: 5) }
            Button(action: comment) { Image(systemName: "text.bubble").font(.system(size: 11)).padding(3) }
                .buttonStyle(.plain).buttonFeedback("Add File Comment (⌃⇧M)").accessibilityLabel("Add a comment to \(document.title)")
            Button { workspace.close(document) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).padding(4)
            }.buttonStyle(.plain).buttonFeedback("Close Tab (⌘W)")
        }.padding(.horizontal, 14).frame(height: 38).frame(minWidth: 130, maxWidth: 240)
            .background(selected ? Color(nsColor: .controlBackgroundColor) : .clear)
            .overlay(alignment: .bottom) { if selected { Rectangle().fill(Color.accentColor).frame(height: 2) } }
            .overlay(alignment: dropEdge == .after ? .trailing : .leading) {
                if dropEdge != nil { Rectangle().fill(Color.accentColor).frame(width: 3) }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
            .contentShape(Rectangle())
            .onTapGesture { workspace.activateTab(document.id) }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .onDrag {
                SelectionCommentPopover.hideAll()
                return DocumentTabDrag.provider(for: document.id)
            }
            .onDrop(of: [DocumentTabDrag.type], delegate: DocumentTabDrop(workspace: workspace, target: document.id,
                                                                       width: width, edge: $dropEdge))
            .contextMenu {
                Button("Add File Comment", action: comment)
                Menu("Sessions") {
                    if document.integrationSessions.isEmpty { Text("No active sessions") }
                    ForEach(document.integrationSessions.indices, id: \.self) { index in
                        let session = document.integrationSessions[index]
                        let attached = document.integrationAttachment["session_id"] == session["session_id"]
                        let request = document.integrationRequests.first { $0["session_id"] == session["session_id"] }
                        Toggle(isOn: Binding(get: {
                            document.integrationAttachment["session_id"] == session["session_id"]
                        }, set: { enabled in
                            if let id = session["session_id"].string { document.setAgentSessionAttached?(id, enabled) }
                        })) {
                            Text(IntegrationRegistry.sessionDisplayName(session, includeIdentifier: false) + attachmentStatus(session, request))
                        }
                        .help(request != nil ? "Cancel this attachment request" : attached ? "Detach this session from the file" : "Attach the file to this session")
                    }
                }
                Divider()
                Button("Close Tab") { workspace.close(document) }
                Button("Close Tabs Before") { workspace.closeTabs(.before, relativeTo: document.id) }
                    .disabled(workspace.tabsToClose(.before, relativeTo: document.id).isEmpty)
                Button("Close Tabs After") { workspace.closeTabs(.after, relativeTo: document.id) }
                    .disabled(workspace.tabsToClose(.after, relativeTo: document.id).isEmpty)
                Button("Close All Tabs") { workspace.closeTabs(.all) }
                Divider()
                FileLocationMenu(name: document.title, url: document.url)
            }
    }
}

struct DocumentTabBar: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(workspace.documents) { document in
                            DocumentTab(document: document, workspace: workspace).id(document.id)
                        }
                    }
                }
                .onAppear { revealActive(using: proxy) }
                .onChange(of: workspace.activeID) { _, _ in revealActive(using: proxy) }
                .onChange(of: workspace.activeTabRevealRequest) { _, _ in revealActive(using: proxy) }
                .onChange(of: workspace.documents.map(\.id)) { _, _ in revealActive(using: proxy) }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { _ in revealActive(using: proxy) }
            }
            Button { workspace.presentTabSearch() } label: {
                Image(systemName: "list.bullet.rectangle").frame(width: 38, height: 38)
            }.buttonStyle(.plain).buttonFeedback("Search Tabs (⌘K)").accessibilityLabel("Search tabs")
        }.frame(height: 38).background(.bar)
    }
    private func revealActive(using proxy: ScrollViewProxy) {
        guard let id = workspace.activeID else { return }
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
    }
}

struct TabSearchPicker: View {
    @ObservedObject var workspace: Workspace
    @ViewState private var query = ""
    @ViewState private var selectedID: UUID?
    @FocusState private var focused: Bool
    private var matches: [EditorDocument] { workspace.searchTabs(query) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search tabs by name or path…", text: $query)
                    .textFieldStyle(.plain).focused($focused)
                    .onKeyPress(keys: [.upArrow, .downArrow], phases: .down) { press in
                        move(press.key == .downArrow ? 1 : -1); return .handled
                    }
                    .onSubmit(choose)
                Button("Cancel") { workspace.showTabSearch = false }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            if matches.isEmpty {
                Text("No matching tabs").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(matches) { document in
                                Button { workspace.activateTab(document.id) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: document.id == workspace.activeID ? "checkmark" : "doc.text")
                                            .foregroundStyle(.secondary).frame(width: 18)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(document.title).fontWeight(.medium).lineLimit(1)
                                            Text(document.url?.path ?? (document.text.isEmpty ? "Unsaved document" : String(document.text.prefix(while: { !$0.isNewline }))))
                                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        }
                                        Spacer()
                                        if document.isDirty { Circle().fill(.secondary).frame(width: 5, height: 5) }
                                    }.padding(10).contentShape(Rectangle())
                                        .background(document.id == selectedID ? Color.accentColor.opacity(0.15) : .clear)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }.buttonStyle(.plain).id(document.id)
                            }
                        }.padding(8)
                    }.onChange(of: selectedID) { _, id in if let id { proxy.scrollTo(id) } }
                        .onAppear { if let id = selectedID { proxy.scrollTo(id) } }
                }
            }
            Divider()
            HStack {
                Text("\(matches.count) of \(workspace.documents.count) tabs")
                Spacer()
                Text("↑↓ to select · Return to open · Escape to close")
            }.font(.caption).foregroundStyle(.secondary).padding(12)
        }.frame(width: 620, height: 420)
            .onAppear { selectedID = workspace.activeID; focused = true }
            .onChange(of: query) { _, _ in selectedID = matches.first?.id }
            .onChange(of: workspace.documents.map(\.id)) { _, _ in
                if !matches.contains(where: { $0.id == selectedID }) { selectedID = matches.first?.id }
            }
            .onExitCommand { workspace.showTabSearch = false }
    }
    private func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        let current = matches.firstIndex { $0.id == selectedID }
        let index = current.map { ($0 + delta + matches.count) % matches.count } ?? 0
        selectedID = matches[index].id
    }
    private func choose() {
        if let id = selectedID ?? matches.first?.id { workspace.activateTab(id) }
    }
}

struct DocumentTabDrop: DropDelegate {
    var workspace: Workspace
    var target: UUID
    var width: CGFloat
    @Binding var edge: TabDropEdge?

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [DocumentTabDrag.type]) }
    private func placement(_ info: DropInfo) -> TabDropEdge { info.location.x < width / 2 ? .before : .after }
    func dropEntered(info: DropInfo) { edge = placement(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        edge = placement(info)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { edge = nil }
    func performDrop(info: DropInfo) -> Bool {
        let destination = placement(info)
        edge = nil
        guard let provider = info.itemProviders(for: [DocumentTabDrag.type]).first else { return false }
        _ = provider.loadDataRepresentation(forTypeIdentifier: DocumentTabDrag.type.identifier) { data, _ in
            guard let data, let value = String(data: data, encoding: .utf8), let id = UUID(uuidString: value) else { return }
            DispatchQueue.main.async { workspace.moveTab(id, relativeTo: target, edge: destination) }
        }
        return true
    }
}
