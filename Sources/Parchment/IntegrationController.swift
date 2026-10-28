import AppKit
import ParchmentCore
import ParchmentIntegration

@MainActor final class AgentTextDelegate: NSObject, NSTextViewDelegate {
    weak var document: EditorDocument?
    init(_ document: EditorDocument) { self.document = document }
    func undoManager(for view: NSTextView) -> UndoManager? { document?.undoManager }
    func textDidChange(_ notification: Notification) {
        if let document, let view = document.sourceTextView { document.changed(view.string) }
    }
}

@MainActor final class IntegrationController {
    let registry: IntegrationRegistry
    private let server: LocalAPIServer
    private weak var workspace: Workspace?
    private let headless: Bool
    private var timer: Task<Void, Never>?
    private var dispatcherTask: Task<Void, Never>?
    private var publishedHashes: [UUID: String] = [:]
    init(workspace: Workspace, directory: URL, headless: Bool = false, server: LocalAPIServer? = nil) throws {
        self.workspace = workspace; self.headless = headless
        self.server = server ?? LocalAPIServer(directory: directory)
        try self.server.claim()
        registry = try IntegrationRegistry(directory: directory)
        for document in workspace.documents { try register(document) }
        try self.server.start { [weak self] request in
            guard let controller = self else { return .object(["ok": .bool(false), "error": BridgeError("APP_UNAVAILABLE", "The app is closing.").json]) }
            return await MainActor.run {
                do { return .object(["ok": .bool(true), "result": try controller.handle(request)]) }
                catch { return .object(["ok": .bool(false), "error": BridgeError.wrap(error).json]) }
            }
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                self.refreshAttachments()
            }
        }
        syncFeedback()
        let dispatcher = FeedbackDispatcher(registry: registry)
        dispatcherTask = Task.detached { await dispatcher.run() }
    }
    func stop() { timer?.cancel(); dispatcherTask?.cancel(); server.stop() }
    func canonicalID(for url: URL, comments: CommentFile) throws -> UUID {
        let id = try registry.registerDocument(path: url.path, preferredID: comments.documentID ?? UUID(), title: url.lastPathComponent)
        return UUID(uuidString: id)!
    }
    func register(_ document: EditorDocument) throws {
        let oldID = document.id
        let registered = try registry.registerDocument(path: document.url?.path, preferredID: document.id, title: document.title)
        document.id = UUID(uuidString: registered)!
        document.comments.documentID = document.id
        if workspace?.activeID == oldID { workspace?.activeID = document.id }
        document.disconnectAgent = { [weak self, weak document] in
            guard let self, let document else { return }
            do { try self.registry.releaseDocument(document.id.uuidString); self.refreshAttachments() }
            catch { self.workspace?.error = error.localizedDescription }
        }
        document.integrationAttachment = try registry.attachment(document.id.uuidString)
    }
    func syncFeedback() {
        guard let workspace else { return }
        for document in workspace.documents {
            do {
                try register(document)
                let hash = sourceHash(String(decoding: try CommentFile.encoder.encode(document.comments), as: UTF8.self))
                if publishedHashes[document.id] != hash {
                    try FeedbackPublication.sync(documentID: document.id.uuidString, text: document.text, comments: document.comments, registry: registry)
                    publishedHashes[document.id] = hash
                }
                document.integrationError = nil
            } catch { document.integrationError = error.localizedDescription }
        }
        refreshAttachments()
    }
    func refreshAttachments() {
        for document in workspace?.documents ?? [] {
            if let attachment = try? registry.attachment(document.id.uuidString), attachment != document.integrationAttachment { document.integrationAttachment = attachment }
        }
    }
    private func document(_ args: JSON) throws -> EditorDocument {
        guard let workspace else { throw BridgeError("APP_UNAVAILABLE", "The editor is closing.") }
        if let id = args["document_id"].string {
            if let found = workspace.documents.first(where: { $0.id.uuidString == id }) { return found }
            let record = try registry.document(id)
            guard let path = record["path"].string else { throw BridgeError("DOCUMENT_NOT_OPEN", "This unsaved document is no longer open.") }
            return try openDocument(path)
        }
        if let path = args["path"].string { return try openDocument(path) }
        throw BridgeError("INVALID_ARGUMENT", "Supply document_id or an absolute Markdown file path.")
    }
    private func openDocument(_ path: String) throws -> EditorDocument {
        guard let workspace else { throw BridgeError("APP_UNAVAILABLE", "The editor is closing.") }
        guard path.hasPrefix("/") || path.hasPrefix("~/") else { throw BridgeError("INVALID_PATH", "Use an absolute path or a path beginning with ~/.") }
        let url = URL(fileURLWithPath: IntegrationRegistry.canonicalPath(path))
        guard ["md", "markdown", "mdown", "txt"].contains(url.pathExtension.lowercased()) else { throw BridgeError("UNSUPPORTED_FILE", "Open a Markdown or plain-text file.") }
        if let document = workspace.documents.first(where: { $0.url == url }) {
            workspace.activeID = document.id; workspace.recentDocuments.note(url); return document
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw BridgeError("FILE_NOT_READABLE", "The requested file does not exist or cannot be read.") }
        // Preflight avoids an interactive alert in the tool path.
        _ = try String(contentsOf: url, encoding: .utf8); _ = try CommentFile.read(for: url)
        workspace.open(url)
        guard let document = workspace.documents.first(where: { $0.url == url }) else { throw BridgeError("OPEN_FAILED", workspace.error ?? "The document could not be opened.") }
        try register(document)
        return document
    }
    private func metadata(_ document: EditorDocument) throws -> JSON {
        .object(["document_id": .string(document.id.uuidString), "title": .string(document.title), "path": document.url.map { .string($0.path) } ?? .null, "open_url": (try? document.url.map { try DocumentLink.url(for: $0).absoluteString }).map(JSON.string) ?? .null, "has_unsaved_changes": .bool(document.isDirty), "view_mode": .string(document.layout.mode.rawValue), "attachment": try registry.attachment(document.id.uuidString)])
    }
    private func save(_ document: EditorDocument) throws {
        guard let workspace else { throw BridgeError("APP_UNAVAILABLE", "The editor is closing.") }
        if document.url != nil { try document.save() }
        guard workspace.persist() else { throw BridgeError("SAVE_FAILED", workspace.error ?? "Could not save the document recovery data.") }
        syncFeedback()
    }
    private func applyText(_ value: String, to document: EditorDocument, label: String) throws {
        guard document.sourceTextView?.hasMarkedText() != true else { throw BridgeError("DOCUMENT_BUSY", "Text composition is in progress. Retry after it finishes.") }
        if value == document.text { return }
        let text: MarkdownTextView
        if let existing = document.sourceTextView { text = existing }
        else {
            let pane = SourcePane(document: document, beginComment: {})
            let coordinator = pane.makeCoordinator()
            _ = pane.makeEditor(coordinator: coordinator)
            text = document.sourceTextView!
            text.delegate = nil
        }
        if text.delegate == nil {
            let delegate = AgentTextDelegate(document); document.agentTextDelegate = delegate; text.delegate = delegate
        }
        let selected = text.selectedRange()
        text.selectionPopover.hide(); text.breakUndoCoalescing()
        // Socket requests can arrive without an AppKit event boundary. Close the
        // typing group and use an explicit group so each agent patch is one undo.
        let undo = document.undoManager, groupedByEvent = document.undoManager.groupsByEvent
        undo.groupsByEvent = false
        for _ in 0..<undo.groupingLevel { undo.endUndoGrouping() }
        undo.beginUndoGrouping()
        text.insertText(value, replacementRange: NSRange(location: 0, length: (text.string as NSString).length))
        undo.setActionName(label); undo.endUndoGrouping()
        undo.groupsByEvent = groupedByEvent
        text.breakUndoCoalescing()
        if document.text != value { document.changed(value) }
        let length = (value as NSString).length
        text.setSelectedRange(NSRange(location: min(selected.location, length), length: 0))
    }
    private func mutate(_ method: String, _ args: JSON) throws -> JSON {
        let binding = try registry.validateBinding(args)
        let document = try self.document(.object(["document_id": binding["document_id"]]))
        let id = try args.require("operation_id")
        guard id.count <= 128 else { throw BridgeError("INVALID_ARGUMENT", "operation_id is too long.") }
        let fingerprint = sourceHash(JSON.object(["method": .string(method), "arguments": args]).text())
        if let prior = try registry.operation(id, fingerprint: fingerprint, binding: binding) {
            let completed = prior["state"].string == "complete"
            let patchApplied = method == "apply_patch" && prior["after_revision"].string == sourceHash(document.text)
            let commentApplied = document.comments.threads.contains { $0.events.contains { $0.operationID == id } }
            if completed || patchApplied || commentApplied {
                if !completed { try save(document); try registry.finishOperation(id) }
                var result = try JSON.parse(Data(prior.require("result").utf8)).object
                result["replayed"] = .bool(true); return .object(result)
            }
            if method == "apply_patch", prior["before_revision"].string != sourceHash(document.text) {
                throw BridgeError("OPERATION_INDETERMINATE", "An interrupted operation cannot be safely replayed against the current revision. Read the document and inspect the result before issuing a new operation.")
            }
            try registry.discardPreparedOperation(id)
        }
        let before = sourceHash(document.text)
        let session = try registry.session(args.require("session_token"))
        let author = "🤖 \(session["client"].string ?? "Agent") · \(session["conversation_label"].string ?? "Agent session")"
        if method == "apply_patch" {
            let updated = try DocumentPatch.apply(args, to: document.text), after = sourceHash(updated)
            let result: JSON = .object(["document_id": .string(document.id.uuidString), "operation_id": .string(id), "previous_revision": .string(before), "revision": .string(after), "changed": .bool(updated != document.text), "replayed": .bool(false)])
            guard document.sourceTextView?.hasMarkedText() != true else { throw BridgeError("DOCUMENT_BUSY", "Text composition is in progress. Retry after it finishes.") }
            try registry.prepareOperation(id: id, fingerprint: fingerprint, binding: binding, before: before, after: after, result: result)
            try applyText(updated, to: document, label: "AI: \(session["conversation_label"].string ?? "Document edit")")
            try save(document); try registry.finishOperation(id)
            return result
        }
        let threadID = try args.require("thread_id")
        guard let index = document.comments.threads.firstIndex(where: { $0.id.uuidString == threadID && !$0.isPending }) else { throw BridgeError("THREAD_NOT_FOUND", "No published thread has that ID in this document.") }
        var event: CommentEvent
        if method == "reply_to_thread" {
            let body = try args.require("body")
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.utf8.count <= 100_000 else { throw BridgeError("INVALID_ARGUMENT", "Reply text must be nonempty and at most 100 KB.") }
            event = CommentEvent(kind: .reply, author: author, body: body)
        } else { event = CommentEvent(kind: .resolve, author: author) }
        event.origin = "agent"; event.operationID = id
        let result: JSON = .object(["document_id": .string(document.id.uuidString), "thread_id": .string(threadID), "event_id": .string(event.id.uuidString), "operation_id": .string(id), "replayed": .bool(false)])
        try registry.prepareOperation(id: id, fingerprint: fingerprint, binding: binding, before: nil, after: nil, result: result)
        document.comments.threads[index].events.append(event); document.isDirty = true
        try save(document); try registry.finishOperation(id)
        return result
    }
    func handle(_ request: JSON) throws -> JSON {
        let method = try request.require("method"), args = request["params"]
        guard let workspace else { throw BridgeError("APP_UNAVAILABLE", "The editor is closing.") }
        defer { refreshAttachments() }
        switch method {
        case "ping": return .object(["app": .string("Parchment"), "api_version": .integer(1), "agent_delivery_version": .integer(1), "pid": .integer(Int(getpid()))])
        case "activate":
            if !headless { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first(where: { $0.title == "Parchment" })?.makeKeyAndOrderFront(nil) }
            return .object(["running": .bool(true)])
        case "open_url":
            guard let url = URL(string: try args.require("url")) else { throw BridgeError("INVALID_ARGUMENT", "Invalid document URL.") }
            let file = try url.isFileURL ? url : DocumentLink(url: url).fileURL
            _ = try openDocument(file.path)
            workspace.openIncomingURL(url)
            if !headless { NSApp.activate(ignoringOtherApps: true) }
            return .object(["opened": .bool(true)])
        case "list_documents":
            return .object(["active_document_id": workspace.activeID.map { .string($0.uuidString) } ?? .null, "documents": .array(try workspace.documents.map(metadata))])
        case "open_document":
            let document = try openDocument(args.require("path"))
            var result = try metadata(document).object
            if args["attach"].bool == true {
                if let url = document.url { try document.comments.write(for: url) }
                do {
                    result["binding"] = try registry.attach(documentID: document.id.uuidString, sessionToken: args.require("session_token"))
                    result["attachment"] = try registry.attachment(document.id.uuidString)
                }
                catch let conflict as BridgeError { throw BridgeError(conflict.code, conflict.message, details: .object(["opened": .bool(true), "document_id": .string(document.id.uuidString), "owner": conflict.details])) }
            }
            if !headless && args["activate"].bool != false { NSApp.activate(ignoringOtherApps: true) }
            syncFeedback(); return .object(result)
        case "attach_document":
            let document = try self.document(args)
            try register(document)
            if let url = document.url { try document.comments.write(for: url) }
            let binding = try registry.attach(documentID: document.id.uuidString, sessionToken: args.require("session_token"))
            syncFeedback(); return binding
        case "get_document":
            let document = try self.document(args)
            var result = try metadata(document).object
            result["revision"] = .string(sourceHash(document.text)); result["text"] = .string(document.text)
            result["comments"] = try JSON.parse(document.comments.export(text: document.text, path: document.url?.path ?? document.title, includeResolved: args["include_resolved"].bool ?? false))
            result["offset_encoding"] = .string("UTF-16 code units; zero-based offsets")
            return .object(result)
        case "handoff_document": return try registry.handoff(args)
        case "detach_document": return try registry.detach(args)
        case "apply_patch", "reply_to_thread", "resolve_thread": return try mutate(method, args)
        case "sync_feedback":
            guard workspace.persist() else { throw BridgeError("SAVE_FAILED", workspace.error ?? "Recovery save failed.") }
            syncFeedback(); return .object(["synced": .bool(true)])
        default:
            if headless { return try testOperation(method, args) }
            throw BridgeError("METHOD_NOT_FOUND", "Unknown local API method.")
        }
    }
    private func testOperation(_ method: String, _ args: JSON) throws -> JSON {
        if method == "test_shutdown" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exit(0) }; return .bool(true) }
        let document = try self.document(args)
        switch method {
        case "test_file_comment": document.addComment(body: try args.require("body"), pending: args["pending"].bool ?? false, fileLevel: true)
        case "test_comment":
            let quote = try args.require("quote"), range = (document.text as NSString).range(of: quote)
            guard range.location != NSNotFound else { throw BridgeError("INVALID_ARGUMENT", "Test quote not found.") }
            document.selection = range; document.addComment(body: try args.require("body"), pending: args["pending"].bool ?? false)
        case "test_submit_review": document.submitReview(summary: args["summary"].string ?? "")
        case "test_discard_review": document.discardReview()
        case "test_reply":
            guard let id = UUID(uuidString: try args.require("thread_id")) else { throw BridgeError("INVALID_ARGUMENT", "Invalid thread ID.") }
            document.addReply(try args.require("body"), to: id, pending: args["pending"].bool ?? false)
        case "test_user_edit": try applyText(args.require("text"), to: document, label: "User edit")
        case "test_undo": document.undoManager.undo()
        case "test_close": workspace?.close(document); return .bool(true)
        default: throw BridgeError("METHOD_NOT_FOUND", "Unknown test API method.")
        }
        try save(document)
        return .object(["revision": .string(sourceHash(document.text)), "threads": try JSON.encode(document.comments.threads)])
    }
    static func runTestServer(directory: URL) -> Never {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let workspace = Workspace(recoveryDirectory: directory)
        workspace.startIntegration(headless: true)
        guard workspace.integration != nil else { fputs("\(workspace.error ?? "Integration failed")\n", stderr); exit(1) }
        print("Parchment integration test server ready"); fflush(stdout)
        withExtendedLifetime(workspace) { app.run() }; exit(0)
    }
}
