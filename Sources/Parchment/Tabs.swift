import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ParchmentIntegration

enum TabCloseScope { case before, after, all }
enum TabDropEdge { case before, after }

@MainActor extension Workspace {
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
            return request["accepted_at"] == .null ? " — request pending" : " — queued; awaiting attachment"
        }
        return session["receiver_registered"].int == 1 ? "" : " — receiver unavailable"
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
            .onTapGesture { workspace.activeID = document.id; workspace.scheduleRecovery() }
            .onDrag {
                SelectionCommentPopover.hideAll()
                return DocumentTabDrag.provider(for: document.id)
            }
            .onDrop(of: [DocumentTabDrag.type], delegate: DocumentTabDrop(workspace: workspace, target: document.id,
                                                                       width: width, edge: $dropEdge))
            .contextMenu {
                Button("Add File Comment", action: comment)
                Menu("Sessions") {
                    if document.integrationSessions.isEmpty { Text("No registered sessions") }
                    ForEach(document.integrationSessions.indices, id: \.self) { index in
                        let session = document.integrationSessions[index]
                        let attached = document.integrationAttachment["session_id"] == session["session_id"]
                        let request = document.integrationRequests.first { $0["session_id"] == session["session_id"] }
                        Toggle(isOn: Binding(get: {
                            document.integrationAttachment["session_id"] == session["session_id"]
                        }, set: { enabled in
                            if let id = session["session_id"].string { document.setAgentSessionAttached?(id, enabled) }
                        })) {
                            Text((session["display_name"].string ?? "Agent session") + attachmentStatus(session, request))
                        }
                        .disabled(!attached && request == nil && session["receiver_registered"].int != 1)
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
