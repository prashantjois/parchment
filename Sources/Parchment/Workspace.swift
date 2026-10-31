import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ParchmentCore
import ParchmentIntegration

struct JumpRequest { var id = UUID(); var range: NSRange; var restoreScroll = false }
struct ExternalFileChange {
    var text: String?
    var message: String
}
enum DocumentSaveError: LocalizedError {
    case externalChange
    var errorDescription: String? { "Autosave is paused because the file changed outside Parchment. Load the external changes or save explicitly." }
}

@MainActor final class EditorDocument: ObservableObject, @preconcurrency Identifiable {
    @Published var id: UUID { didSet { if id != oldValue { loadCommentReadState() } } }
    @Published var url: URL?
    @Published var text: String
    @Published var layout: FileLayout
    @Published var comments: CommentFile
    @Published var commentReadState = CommentReadState()
    @Published var rendered: RenderedDocument
    @Published var selection = NSRange(location: 0, length: 0)
    @Published var searchRanges: [NSRange] = []
    @Published var activeSearchRange: NSRange?
    @Published var jump: JumpRequest?
    @Published var selectedThread: UUID?
    @Published var commentDraftAnchor: CommentAnchor?
    @Published var commentDraftIsFileLevel = false
    @Published var isDirty = false
    @Published var saveMessage = ""
    @Published var loadedRemoteImages: Set<String> = []
    @Published var externalChange: ExternalFileChange?
    @Published var autosaveSuspended = false
    @Published var browserRoot: URL { willSet { if newValue != browserRoot { onNavigate?() } } }
    @Published var browserExpanded: Set<String> = []
    @Published var integrationAttachment: JSON = .object(["status": .string("unattached")])
    @Published var integrationSessions: [JSON] = []
    @Published var integrationRequests: [JSON] = []
    var requestAgentAttachment: ((String) -> Void)?
    var setAgentSessionAttached: ((String, Bool) -> Void)?
    @Published var integrationError: String?
    var disconnectAgent: (() -> Void)?
    var agentTextDelegate: AgentTextDelegate?
    var saveTask: Task<Void, Never>?
    var renderTask: Task<Void, Never>?
    var onChange: (() -> Void)?
    var onNavigate: (() -> Void)?
    var sourceTextView: MarkdownTextView?
    var sourceScrollView: NSScrollView?
    let undoManager = UndoManager()
    var renderedSource: String
    private var lastDiskText: String?
    private var fileWatcher: FileWatcher?

    init(id: UUID? = nil, url: URL?, text: String, layout: FileLayout = FileLayout(), comments: CommentFile? = nil) {
        self.id = id ?? comments?.documentID ?? UUID(); self.url = url; self.text = text; self.layout = layout
        self.comments = comments ?? CommentFile(document: url?.lastPathComponent ?? "Untitled.md")
        renderedSource = text
        rendered = MarkdownRenderer.render(text, baseURL: url?.deletingLastPathComponent())
        browserRoot = url?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
        self.comments.documentID = self.id
        lastDiskText = url == nil ? nil : text
        loadCommentReadState()
    }
    var title: String { url?.lastPathComponent ?? "Untitled" }
    private var readStateKey: String { "comments.read:\(id.uuidString)" }
    private func loadCommentReadState() {
        commentReadState = UserDefaults.standard.data(forKey: readStateKey)
            .flatMap { try? JSONDecoder().decode(CommentReadState.self, from: $0) } ?? CommentReadState()
    }
    func isUnread(_ thread: CommentThread) -> Bool { commentReadState.isUnread(thread, reader: NSFullUserName()) }
    func isUnread(_ message: CommentEvent, in thread: CommentThread) -> Bool {
        commentReadState.isUnread(message, in: thread, reader: NSFullUserName())
    }
    var unreadThreadCount: Int { comments.threads.filter(isUnread).count }
    func markThreadRead(_ thread: CommentThread) {
        var state = commentReadState; state.markRead(thread); persistReadState(state)
    }
    func markThreadUnread(_ thread: CommentThread) {
        var state = commentReadState; state.markUnread(thread); persistReadState(state)
    }
    private func persistReadState(_ state: CommentReadState) {
        guard state != commentReadState else { return }
        commentReadState = state
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: readStateKey) }
    }
    func visibleCommentThreads(filter: String) -> [CommentThread] {
        comments.threads.enumerated().filter { _, thread in
            switch filter {
            case "Unread": return isUnread(thread)
            case "Pending": return thread.isPending || thread.messages.contains(where: \.isPending)
            case "Resolved": return !thread.isPending && thread.isResolved
            case "Open": return !thread.isPending && (!thread.isResolved || isUnread(thread))
            default: return true
            }
        }.sorted { lhs, rhs in
            let left = isUnread(lhs.element), right = isUnread(rhs.element)
            if left != right { return left }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
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
            if self.url != nil && !self.autosaveSuspended {
                do { try self.save() } catch { self.saveMessage = error.localizedDescription }
            }
            self.onChange?()
        }
    }
    func startWatching() {
        fileWatcher = nil
        guard let url else { return }
        if autosaveSuspended { lastDiskText = try? String(contentsOf: url, encoding: .utf8) }
        fileWatcher = FileWatcher(url: url) { [weak self] in self?.checkForExternalChanges() }
        checkForExternalChanges()
    }
    func stopWatching() { fileWatcher = nil }
    func checkForExternalChanges() {
        guard let url else { return }
        let diskText = try? String(contentsOf: url, encoding: .utf8)
        guard diskText != lastDiskText else { return }
        lastDiskText = diskText
        guard diskText != text else { return }
        saveTask?.cancel()
        autosaveSuspended = true; isDirty = true
        externalChange = ExternalFileChange(text: diskText, message: diskText == nil
            ? "The file was removed or cannot be read. Your local text is still available."
            : "This file changed outside Parchment. Load the external version or keep your local text.")
        saveMessage = "External changes · Autosave paused"
        onChange?()
    }
    func keepLocalChanges() {
        externalChange = nil
        autosaveSuspended = true; isDirty = true
        saveTask?.cancel()
        saveMessage = "Autosave paused · Save to replace external changes"
        onChange?()
    }
    func loadExternalChanges() {
        guard let url else { return }
        do {
            let value = try String(contentsOf: url, encoding: .utf8)
            saveTask?.cancel(); renderTask?.cancel()
            text = value; renderedSource = value
            rendered = MarkdownRenderer.render(value, baseURL: url.deletingLastPathComponent())
            sourceTextView?.string = value
            undoManager.removeAllActions()
            selection = NSRange(location: min(selection.location, value.utf16.count), length: 0)
            reveal(selection)
            lastDiskText = value; externalChange = nil; autosaveSuspended = false
            isDirty = true; saveMessage = "Loaded external changes"
            // Preserve local comments and review drafts through the usual save path.
            scheduleSave()
        } catch {
            externalChange = ExternalFileChange(text: nil, message: "The external version cannot be read: \(error.localizedDescription)")
        }
    }
    func save(to destination: URL? = nil, overwriteExternalChanges: Bool = false) throws {
        guard let destination = destination ?? url else { return }
        let sameFile = destination.standardizedFileURL == url?.standardizedFileURL
        if sameFile {
            checkForExternalChanges()
            if autosaveSuspended && !overwriteExternalChanges { throw DocumentSaveError.externalChange }
        }
        let newID = url != nil && url?.standardizedFileURL != destination.standardizedFileURL ? UUID() : id
        var companion = comments; companion.documentID = newID
        // Do not change the active path until both writes succeed.
        try text.write(to: destination, atomically: true, encoding: .utf8)
        if sameFile { lastDiskText = text }
        try companion.write(for: destination)
        if url != destination { browserRoot = destination.deletingLastPathComponent() }
        id = newID; comments = companion
        url = destination; comments.document = destination.lastPathComponent
        lastDiskText = text; externalChange = nil; autosaveSuspended = false
        if !sameFile { startWatching() }
        isDirty = false; saveMessage = "Saved"; onChange?()
    }
    func reveal(_ range: NSRange, restoreScroll: Bool = false) {
        onNavigate?()
        jump = JumpRequest(range: range, restoreScroll: restoreScroll)
        selection = range
    }
    func addComment(body: String, pending: Bool = false, fileLevel: Bool = false) {
        let range = fileLevel ? TextSpan(location: 0, length: 0) : TextSpan(location: selection.location, length: selection.length)
        guard (fileLevel || range.isValid(in: text)), !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let reviewID = pending ? comments.startReview(author: NSFullUserName()) : nil
        let thread = CommentThread(anchor: CommentAnchor(text: text, range: range), body: body, author: NSFullUserName(), reviewID: reviewID, fileLevel: fileLevel)
        comments.threads.append(thread); selectedThread = thread.id
        comments.formatVersion = comments.encodingVersion
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
        markThreadRead(thread)
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
        if event.origin != "agent", event.author == NSFullUserName() { markThreadRead(comments.threads[index]) }
        comments.threads[index].events.append(event); isDirty = true; scheduleSave()
    }
    func selectThread(_ thread: CommentThread) {
        markThreadRead(thread)
        selectedThread = thread.id; layout.showRight = true; layout.rightPanel = .comments
        if let range = thread.locate(in: text).range { reveal(range.nsRange) }
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
    var autosaveSuspended: Bool?
}
struct SessionSnapshot: Codable { var active: UUID?; var documents: [SessionDocument] }

@MainActor final class Workspace: ObservableObject {
    @Published var documents: [EditorDocument] = [] { didSet { search.refresh() } }
    @Published var activeID: UUID? { didSet { navigatedFromTab(oldValue); search.refresh() } }
    let search: SearchController
    @Published var backHistory: [NavigationLocation] = []
    @Published var forwardHistory: [NavigationLocation] = []
    var navigationDepth = 0
    var recordsNavigation = false
    @Published var error: String?
    @Published var showThemes = false
    @Published var composeComment = false
    @Published var themes = ThemeLibrary()
    var integration: IntegrationController?
    private var recoveryTask: Task<Void, Never>?
    private var canPersistRecovery = true
    private let support: URL
    let recentDocuments: RecentDocuments
    var active: EditorDocument? { documents.first { $0.id == activeID } }

    init(recoveryDirectory: URL? = nil, searchDefaults: UserDefaults = .standard) {
        search = SearchController(defaults: searchDefaults)
        support = recoveryDirectory ?? IntegrationPaths.directory
        recentDocuments = RecentDocuments(storageURL: support.appendingPathComponent("recent-documents.json"),
                                          recordsSystemRecents: recoveryDirectory == nil)
        do { try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true) }
        catch { self.error = "Cannot create the recovery folder: \(error.localizedDescription)" }
        restore()
        search.workspace = self
        recentDocuments.seedFromSession(([active?.url].compactMap { $0 }) + documents.compactMap(\.url))
        if documents.isEmpty { newDocument() }
        recordsNavigation = true
    }
    func attach(_ document: EditorDocument) {
        do { try integration?.register(document) } catch { document.integrationError = error.localizedDescription }
        document.onChange = { [weak self] in self?.search.refresh(); self?.scheduleRecovery() }
        document.onNavigate = { [weak self, weak document] in
            guard let self, let document, self.activeID == document.id else { return }
            self.recordCurrentLocation()
        }
        document.startWatching()
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
        navigate { openWithoutHistory(url) }
    }
    private func openWithoutHistory(_ url: URL) {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        if let document = documents.first(where: { $0.url == url }) {
            activeID = document.id; recentDocuments.note(url); return
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let comments = try CommentFile.read(for: url)
            var layout = FileLayout()
            if let data = UserDefaults.standard.data(forKey: "layout:\(url.path)"), let saved = try? JSONDecoder().decode(FileLayout.self, from: data) { layout = saved }
            layout.showSinglePane(.rendered)
            let id = try integration?.canonicalID(for: url, comments: comments)
            attach(EditorDocument(id: id, url: url, text: text, layout: layout, comments: comments))
            recentDocuments.note(url)
            scheduleRecovery()
        } catch { self.error = "Cannot open \(url.lastPathComponent): \(error.localizedDescription)" }
    }
    func openIncomingURL(_ url: URL) {
        navigate { openIncomingURLWithoutHistory(url) }
    }
    private func openIncomingURLWithoutHistory(_ url: URL) {
        if url.isFileURL {
            guard [nil, "", "localhost"].contains(url.host) else { error = "Only local file links can open in Parchment."; return }
            let file = URL(fileURLWithPath: url.path).standardizedFileURL.resolvingSymlinksInPath()
            if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if active == nil { newDocument() }
                active?.browserRoot = file; active?.layout.showFiles = true
            } else {
                open(file)
                if let document = documents.first(where: { $0.url == file }) {
                    document.layout.showSinglePane(.rendered)
                    if let fragment = url.fragment,
                       let heading = document.rendered.headings.first(where: { $0.id == (fragment.removingPercentEncoding ?? fragment) }) {
                        document.layout.cursorLocation = heading.location
                        document.reveal(NSRange(location: heading.location, length: 0))
                    }
                }
            }
            scheduleRecovery(); return
        }
        do {
            let link = try DocumentLink(url: url)
            open(link.fileURL)
            let canonical = link.fileURL.resolvingSymlinksInPath()
            guard let document = documents.first(where: { $0.url == canonical }) else { return }
            document.layout.showSinglePane(.rendered)
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
            document.checkForExternalChanges()
            if document.autosaveSuspended && destination == document.url {
                let alert = NSAlert(); alert.messageText = "Replace the external version of \(document.title)?"
                alert.informativeText = "Saving will replace the file on disk with your local text."
                alert.addButton(withTitle: "Replace"); alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            try document.save(to: destination, overwriteExternalChanges: true)
            if let url = document.url { recentDocuments.note(url) }
            if activeID == oldID { activeID = document.id }
            scheduleRecovery()
        }
        catch { self.error = "Cannot save: \(error.localizedDescription)" }
    }
    static func confirmClose(_ document: EditorDocument) -> NSApplication.ModalResponse {
        let alert = NSAlert(); alert.messageText = "Save \(document.title) before closing?"
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Discard")
        return alert.runModal()
    }
    @discardableResult func close(_ document: EditorDocument,
                                  confirm: @MainActor (EditorDocument) -> NSApplication.ModalResponse = Workspace.confirmClose) -> Bool {
        guard documents.contains(where: { $0 === document }) else { return false }
        if (document.url == nil || document.autosaveSuspended) && (!document.text.isEmpty || !document.comments.threads.isEmpty || document.isDirty) {
            let response = confirm(document)
            if response != .alertFirstButtonReturn && response != .alertThirdButtonReturn { return false }
            if response == .alertFirstButtonReturn { save(document); if document.url == nil || document.isDirty { return false } }
        } else if document.isDirty {
            do { try document.save() } catch { self.error = error.localizedDescription; return false }
        }
        document.saveTask?.cancel(); document.renderTask?.cancel()
        persistLayout(document)
        document.stopWatching()
        document.onNavigate = nil
        if document.url == nil {
            backHistory.removeAll { $0.documentID == document.id }
            forwardHistory.removeAll { $0.documentID == document.id }
        }
        let index = documents.firstIndex(where: { $0.id == document.id }) ?? 0
        documents.removeAll { $0.id == document.id }
        if activeID == document.id { activeID = documents.isEmpty ? nil : documents[min(index, documents.count - 1)].id }
        scheduleRecovery()
        return true
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
        active.commentDraftIsFileLevel = false
        SelectionCommentPopover.hideAll()
        composeComment = true
    }
    func beginFileComment(_ document: EditorDocument? = nil) {
        if let document { activeID = document.id }
        guard let active else { return }
        active.commentDraftAnchor = nil; active.commentDraftIsFileLevel = true
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
            SessionDocument(id: $0.id, path: $0.url?.path, text: $0.text, layout: $0.layout, comments: $0.comments, dirty: $0.isDirty, autosaveSuspended: $0.autosaveSuspended)
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
                document.isDirty = dirty; document.autosaveSuspended = item.autosaveSuspended ?? false
                if document.autosaveSuspended { document.saveMessage = "Autosave paused · Save to replace external changes" }
                attach(document)
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
