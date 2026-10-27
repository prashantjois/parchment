import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ParchmentCore
import ParchmentIntegration

struct JumpRequest { var id = UUID(); var range: NSRange }

@MainActor final class EditorDocument: ObservableObject, @preconcurrency Identifiable {
    @Published var id: UUID
    @Published var url: URL?
    @Published var text: String
    @Published var layout: FileLayout
    @Published var comments: CommentFile
    @Published var rendered: RenderedDocument
    @Published var selection = NSRange(location: 0, length: 0)
    @Published var jump: JumpRequest?
    @Published var selectedThread: UUID?
    @Published var commentDraftAnchor: CommentAnchor?
    @Published var isDirty = false
    @Published var saveMessage = ""
    @Published var loadedRemoteImages: Set<String> = []
    @Published var browserRoot: URL
    @Published var browserExpanded: Set<String> = []
    @Published var integrationAttachment: JSON = .object(["status": .string("unattached")])
    @Published var integrationError: String?
    var disconnectAgent: (() -> Void)?
    var agentTextDelegate: AgentTextDelegate?
    var saveTask: Task<Void, Never>?
    var renderTask: Task<Void, Never>?
    var onChange: (() -> Void)?
    var sourceTextView: MarkdownTextView?
    var sourceScrollView: NSScrollView?
    let undoManager = UndoManager()
    var renderedSource: String

    init(id: UUID? = nil, url: URL?, text: String, layout: FileLayout = FileLayout(), comments: CommentFile? = nil) {
        self.id = id ?? comments?.documentID ?? UUID(); self.url = url; self.text = text; self.layout = layout
        self.comments = comments ?? CommentFile(document: url?.lastPathComponent ?? "Untitled.md")
        renderedSource = text
        rendered = MarkdownRenderer.render(text, baseURL: url?.deletingLastPathComponent())
        browserRoot = url?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
        self.comments.documentID = self.id
    }
    var title: String { url?.lastPathComponent ?? "Untitled" }
    func changed(_ value: String) {
        text = value; isDirty = true
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            self.renderedSource = self.text
            self.rendered = MarkdownRenderer.render(self.text, baseURL: self.url?.deletingLastPathComponent())
        }
        scheduleSave()
    }
    func scheduleSave() {
        onChange?()
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            if self.url != nil {
                do { try self.save() } catch { self.saveMessage = error.localizedDescription }
            }
            self.onChange?()
        }
    }
    func save(to destination: URL? = nil) throws {
        guard let destination = destination ?? url else { return }
        let newID = url != nil && url?.standardizedFileURL != destination.standardizedFileURL ? UUID() : id
        var companion = comments; companion.documentID = newID
        // Do not change the active path until both writes succeed.
        try text.write(to: destination, atomically: true, encoding: .utf8)
        try companion.write(for: destination)
        if url != destination { browserRoot = destination.deletingLastPathComponent() }
        id = newID; comments = companion
        url = destination; comments.document = destination.lastPathComponent
        isDirty = false; saveMessage = "Saved"; onChange?()
    }
    func reveal(_ range: NSRange) {
        jump = JumpRequest(range: range)
        selection = range
    }
    func addComment(body: String, pending: Bool = false) {
        let range = TextSpan(location: selection.location, length: selection.length)
        guard range.isValid(in: text), !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let reviewID = pending ? comments.startReview(author: NSFullUserName()) : nil
        let thread = CommentThread(anchor: CommentAnchor(text: text, range: range), body: body, author: NSFullUserName(), reviewID: reviewID)
        comments.threads.append(thread); selectedThread = thread.id
        layout.showRight = true; layout.rightPanel = .comments
        isDirty = true; scheduleSave()
    }
    func startReview() { comments.startReview(author: NSFullUserName()); isDirty = true; scheduleSave() }
    func submitReview(summary: String) {
        if comments.submitReview(summary: summary) { isDirty = true; scheduleSave() }
    }
    func discardReview() { comments.discardReview(); isDirty = true; scheduleSave() }
    func addReply(_ body: String, to threadID: UUID, pending: Bool) {
        guard let thread = comments.threads.first(where: { $0.id == threadID }), !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let reviewID = thread.isPending ? thread.reviewID : (pending ? comments.startReview(author: NSFullUserName()) : nil)
        append(CommentEvent(kind: .reply, author: NSFullUserName(), body: body, reviewID: reviewID), to: threadID)
    }
    func editPendingMessage(_ messageID: UUID, in threadID: UUID, body: String) {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let threadIndex = comments.threads.firstIndex(where: { $0.id == threadID }),
              let messageIndex = comments.threads[threadIndex].events.firstIndex(where: { $0.id == messageID && $0.isPending }) else { return }
        comments.threads[threadIndex].events[messageIndex].body = body
        isDirty = true; scheduleSave()
    }
    func removePendingMessage(_ messageID: UUID, in threadID: UUID) {
        guard let index = comments.threads.firstIndex(where: { $0.id == threadID }),
              let event = comments.threads[index].events.first(where: { $0.id == messageID && $0.isPending }) else { return }
        if event.kind == .comment && comments.threads[index].isPending { comments.threads.remove(at: index) }
        else { comments.threads[index].events.removeAll { $0.id == messageID } }
        isDirty = true; scheduleSave()
    }
    func append(_ event: CommentEvent, to thread: UUID) {
        guard let index = comments.threads.firstIndex(where: { $0.id == thread }) else { return }
        comments.threads[index].events.append(event); isDirty = true; scheduleSave()
    }
    func selectThread(_ thread: CommentThread) {
        selectedThread = thread.id; layout.showRight = true; layout.rightPanel = .comments
        if let range = thread.anchor.locate(in: text).range { reveal(range.nsRange) }
        onChange?()
    }
}

struct SessionDocument: Codable {
    var id: UUID
    var path: String?
    var text: String
    var layout: FileLayout
    var comments: CommentFile
    var dirty: Bool
}
struct SessionSnapshot: Codable { var active: UUID?; var documents: [SessionDocument] }

@MainActor final class Workspace: ObservableObject {
    @Published var documents: [EditorDocument] = []
    @Published var activeID: UUID?
    @Published var error: String?
    @Published var showThemes = false
    @Published var composeComment = false
    @Published var themes = ThemeLibrary()
    var integration: IntegrationController?
    private var recoveryTask: Task<Void, Never>?
    private var canPersistRecovery = true
    private let support: URL
    private let recordsRecentDocuments: Bool
    var active: EditorDocument? { documents.first { $0.id == activeID } }

    init(recoveryDirectory: URL? = nil) {
        recordsRecentDocuments = recoveryDirectory == nil
        support = recoveryDirectory ?? IntegrationPaths.directory
        do { try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true) }
        catch { self.error = "Cannot create the recovery folder: \(error.localizedDescription)" }
        restore()
        if documents.isEmpty { newDocument() }
    }
    func attach(_ document: EditorDocument) {
        do { try integration?.register(document) } catch { document.integrationError = error.localizedDescription }
        document.onChange = { [weak self] in self?.scheduleRecovery() }
        documents.append(document); activeID = document.id
    }
    @discardableResult func startIntegration(headless: Bool = false, server: LocalAPIServer? = nil) -> Bool {
        do { integration = try IntegrationController(workspace: self, directory: support, headless: headless, server: server); return true }
        catch { self.error = "MCP integration could not start: \(error.localizedDescription)"; return false }
    }
    func newDocument() { attach(EditorDocument(url: nil, text: "")); scheduleRecovery() }
    func openPanel() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.plainText, .text, UTType(filenameExtension: "md") ?? .text]
        if panel.runModal() == .OK { panel.urls.forEach(open) }
    }
    func open(_ url: URL) {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        if let document = documents.first(where: { $0.url == url }) { activeID = document.id; return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let comments = try CommentFile.read(for: url)
            var layout = FileLayout()
            if let data = UserDefaults.standard.data(forKey: "layout:\(url.path)"), let saved = try? JSONDecoder().decode(FileLayout.self, from: data) { layout = saved }
            let id = try integration?.canonicalID(for: url, comments: comments)
            attach(EditorDocument(id: id, url: url, text: text, layout: layout, comments: comments))
            if recordsRecentDocuments { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
            scheduleRecovery()
        } catch { self.error = "Cannot open \(url.lastPathComponent): \(error.localizedDescription)" }
    }
    func openIncomingURL(_ url: URL) {
        if url.isFileURL { open(url); return }
        do {
            let link = try DocumentLink(url: url)
            open(link.fileURL)
            let canonical = link.fileURL.resolvingSymlinksInPath()
            guard let document = documents.first(where: { $0.url == canonical }) else { return }
            if let offset = link.location(in: document.text) {
                document.layout.cursorLocation = offset
                document.reveal(NSRange(location: offset, length: 0))
            }
            scheduleRecovery()
        } catch { self.error = "Cannot open Parchment link: \(error.localizedDescription)" }
    }
    func save(_ document: EditorDocument, saveAs: Bool = false) {
        var destination = document.url
        if destination == nil || saveAs {
            let panel = NSSavePanel(); panel.nameFieldStringValue = document.url?.lastPathComponent ?? "Untitled.md"
            guard panel.runModal() == .OK, let url = panel.url else { return }; destination = url
            if documents.contains(where: { $0.id != document.id && $0.url?.standardizedFileURL == url.standardizedFileURL }) {
                error = "That file is already open in another tab."; return
            }
            // A companion file is independent user data. Do not replace one during Save As.
            if destination != document.url && FileManager.default.fileExists(atPath: CommentFile.companionURL(for: url).path) {
                error = "The destination already has a comment file. Choose another filename."; return
            }
        }
        do {
            let oldID = document.id
            try document.save(to: destination)
            if activeID == oldID { activeID = document.id }
            scheduleRecovery()
        }
        catch { self.error = "Cannot save: \(error.localizedDescription)" }
    }
    func close(_ document: EditorDocument) {
        if document.url == nil && (!document.text.isEmpty || !document.comments.threads.isEmpty) {
            let alert = NSAlert(); alert.messageText = "Save \(document.title) before closing?"
            alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Discard")
            let response = alert.runModal()
            if response == .alertSecondButtonReturn { return }
            if response == .alertFirstButtonReturn { save(document); if document.url == nil || document.isDirty { return } }
        } else if document.isDirty {
            do { try document.save() } catch { self.error = error.localizedDescription; return }
        }
        persistLayout(document)
        let index = documents.firstIndex(where: { $0.id == document.id }) ?? 0
        documents.removeAll { $0.id == document.id }
        if activeID == document.id { activeID = documents.isEmpty ? nil : documents[min(index, documents.count - 1)].id }
        scheduleRecovery()
    }
    func toggleFiles() { guard let active else { return }; active.layout.showFiles.toggle(); scheduleRecovery() }
    func toggleSplit() { objectWillChange.send(); active?.layout.toggleSplit(); scheduleRecovery() }
    func toggleRendered() { objectWillChange.send(); active?.layout.toggleRendered(); scheduleRecovery() }
    func showSinglePane(_ mode: ViewMode) { objectWillChange.send(); active?.layout.showSinglePane(mode); scheduleRecovery() }
    func toggleRight(_ panel: RightPanel) {
        guard let active else { return }
        if active.layout.showRight && active.layout.rightPanel == panel { active.layout.showRight = false }
        else { active.layout.rightPanel = panel; active.layout.showRight = true }
        scheduleRecovery()
    }
    func beginComment() {
        guard let active else { return }
        let range = TextSpan(location: active.selection.location, length: active.selection.length)
        guard range.isValid(in: active.text) else { return }
        active.commentDraftAnchor = CommentAnchor(text: active.text, range: range)
        SelectionCommentPopover.hideAll()
        composeComment = true
    }
    func nextTab(_ delta: Int) {
        guard !documents.isEmpty else { return }
        let current = documents.firstIndex(where: { $0.id == activeID }) ?? 0
        activeID = documents[(current + delta + documents.count) % documents.count].id
    }
    func exportComments() {
        guard let active else { return }
        do {
            let data = try active.comments.export(text: active.text, path: active.url?.path ?? active.title, includeResolved: false)
            let panel = NSSavePanel(); panel.nameFieldStringValue = active.title + ".review.json"
            if panel.runModal() == .OK, let url = panel.url { try data.write(to: url, options: .atomic) }
        } catch { self.error = error.localizedDescription }
    }
    func persistLayout(_ document: EditorDocument) {
        if let url = document.url, let data = try? JSONEncoder().encode(document.layout) { UserDefaults.standard.set(data, forKey: "layout:\(url.path)") }
    }
    func scheduleRecovery() {
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }; self?.persist()
        }
    }
    @discardableResult func persist() -> Bool {
        guard canPersistRecovery else { return false }
        documents.forEach(persistLayout)
        let snapshot = SessionSnapshot(active: activeID, documents: documents.map {
            SessionDocument(id: $0.id, path: $0.url?.path, text: $0.text, layout: $0.layout, comments: $0.comments, dirty: $0.isDirty)
        })
        do {
            try CommentFile.encoder.encode(snapshot).write(to: support.appendingPathComponent("session.json"), options: .atomic)
            integration?.syncFeedback()
            return true
        } catch { self.error = "Cannot save recovery data: \(error.localizedDescription)"; return false }
    }
    private func restore() {
        let url = support.appendingPathComponent("session.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let snapshot = try CommentFile.decoder.decode(SessionSnapshot.self, from: Data(contentsOf: url))
            var recoveryWarnings: [String] = []
            for item in snapshot.documents {
                var path = item.path.map { URL(fileURLWithPath: $0) }
                // Recovery is authoritative only for unsaved edits. Clean tabs read their files again.
                var text = item.text, comments = item.comments, dirty = item.dirty
                if !dirty, let savedPath = path {
                    do {
                        text = try String(contentsOf: savedPath, encoding: .utf8)
                        comments = try CommentFile.read(for: savedPath)
                    } catch {
                        // Preserve the snapshot as a draft; do not overwrite an unreadable original.
                        path = nil; dirty = true
                        recoveryWarnings.append("\(savedPath.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                let document = EditorDocument(id: item.id, url: path, text: text, layout: item.layout, comments: comments)
                document.isDirty = dirty; attach(document)
            }
            activeID = documents.contains(where: { $0.id == snapshot.active }) ? snapshot.active : documents.first?.id
            if !recoveryWarnings.isEmpty { self.error = "Some files could not be reopened. Their recovered content is available in unsaved tabs.\n" + recoveryWarnings.joined(separator: "\n") }
        } catch {
            let backup = support.appendingPathComponent("unreadable-session-\(UUID().uuidString).json")
            do {
                try FileManager.default.copyItem(at: url, to: backup)
                self.error = "The previous session could not be read. Its original data is preserved at \(backup.path)."
            } catch {
                canPersistRecovery = false
                self.error = "The previous session cannot be read or copied. Recovery writes are paused to preserve it: \(url.path)"
            }
        }
    }
}
