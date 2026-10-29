import AppKit
import ParchmentCore

@MainActor enum StorageChecks {
    static func run() -> Never {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parchment-check-" + UUID().uuidString)
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL") \(name)")
            if !condition { failures += 1 }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let first = directory.appendingPathComponent("first.md"), second = directory.appendingPathComponent("second.md")
            let recovery = directory.appendingPathComponent("recovery")
            try "# First\n\nA sentence to review.\n".write(to: first, atomically: true, encoding: .utf8)
            try "# Second\n".write(to: second, atomically: true, encoding: .utf8)
            let workspace = Workspace(recoveryDirectory: recovery)
            workspace.open(first)
            check(workspace.recentDocuments.urls == [first], "opening a file immediately populates Open Recent")
            let firstDocument = workspace.active!
            firstDocument.layout.showFiles = true; firstDocument.layout.mode = .split
            firstDocument.layout.previousSingleMode = .rendered; firstDocument.layout.rightWidth = 333
            firstDocument.selection = (firstDocument.text as NSString).range(of: "A sentence to review.")
            firstDocument.addComment(body: "Make this concrete.")
            try firstDocument.save()
            let thread = firstDocument.comments.threads[0].id
            firstDocument.append(CommentEvent(kind: .reply, author: "Check", body: "A flat reply."), to: thread)
            firstDocument.append(CommentEvent(kind: .resolve, author: "Check"), to: thread)
            try firstDocument.save()
            check(try CommentFile.read(for: first).threads[0].isResolved, "companion saves thread resolution")
            var agentReply = CommentEvent(kind: .reply, author: "🤖 Agent", body: "New information after resolution")
            agentReply.origin = "agent"
            firstDocument.append(agentReply, to: thread)
            try firstDocument.save()
            check(firstDocument.unreadThreadCount == 1 && firstDocument.visibleCommentThreads(filter: "Open").first?.id == thread, "unread replies remain visible even in resolved threads")
            let threadValue = firstDocument.comments.threads[0]
            let eventCount = threadValue.events.count
            firstDocument.selectThread(threadValue)
            check(firstDocument.unreadThreadCount == 0 && !firstDocument.isDirty, "interacting with a thread marks it read without modifying the document")
            firstDocument.markThreadUnread(threadValue)
            let unreadRestored = EditorDocument(id: firstDocument.id, url: first, text: firstDocument.text, comments: firstDocument.comments)
            check(unreadRestored.isUnread(threadValue) && unreadRestored.comments.threads[0].events.count == eventCount, "manual unread state survives reopening without changing discussion history")
            firstDocument.markThreadRead(threadValue)
            let ordering = EditorDocument(url: nil, text: firstDocument.text)
            let incoming = CommentThread(anchor: threadValue.anchor, body: "Unread comment", author: "Another reviewer")
            ordering.comments.threads = [threadValue, incoming]
            ordering.markThreadRead(threadValue)
            check(ordering.visibleCommentThreads(filter: "All").first?.id == incoming.id && ordering.visibleCommentThreads(filter: "Unread").count == 1, "unread threads sort before read threads and have a dedicated filter")
            ordering.markThreadUnread(threadValue)
            check(ordering.visibleCommentThreads(filter: "Unread").count == 2, "mark as unread restores a previously read thread")
            UserDefaults.standard.removeObject(forKey: "comments.read:\(ordering.id.uuidString)")
            workspace.open(second); let secondDocument = workspace.active!
            check(workspace.recentDocuments.urls == [second, first], "Open Recent lists the newest file first")
            check(secondDocument.layout.mode == .rendered && !secondDocument.layout.showFiles, "newly opened files use Rendered mode with independent layouts")
            let count = workspace.documents.count
            workspace.open(first)
            check(workspace.recentDocuments.urls == [first, second], "reopening an existing tab refreshes Open Recent without duplicates")
            check(workspace.active?.id == firstDocument.id && workspace.documents.count == count, "opening an existing file reuses its tab")
            check(workspace.persist(), "session persists")
            let restored = Workspace(recoveryDirectory: recovery)
            check(restored.recentDocuments.urls == [first, second], "recent files survive session restart")
            let storedRecents = recovery.appendingPathComponent("recent-documents.json")
            try FileManager.default.removeItem(at: storedRecents)
            let migrated = Workspace(recoveryDirectory: recovery)
            check(migrated.recentDocuments.urls.first == first && migrated.recentDocuments.urls.contains(second),
                  "existing saved tabs populate Open Recent when upgrading from an older build")
            let app = NSApplication.shared
            let previousMenu = app.mainMenu
            let mainMenu = NSMenu(title: "Main"), fileMenu = NSMenu(title: "File")
            let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
            fileItem.submenu = fileMenu; mainMenu.addItem(fileItem)
            let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
            recentItem.submenu = NSMenu(title: "Open Recent"); recentItem.isEnabled = false; fileMenu.addItem(recentItem)
            app.mainMenu = mainMenu
            var openedRecent: URL?
            let recentController = RecentDocumentsMenuController(recentDocuments: migrated.recentDocuments, open: { openedRecent = $0 })
            migrated.open(second)
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: fileMenu)
            check(recentItem.isEnabled && recentItem.submenu?.items.first?.title == "second.md",
                  "the native Open Recent submenu refreshes and enables itself when File opens")
            recentItem.submenu!.performActionForItem(at: 0)
            check(openedRecent == second, "choosing a native recent-file item opens its file")
            recentItem.submenu!.performActionForItem(at: recentItem.submenu!.items.count - 1)
            check(migrated.recentDocuments.urls.isEmpty, "the native Clear Menu action erases recent files")
            app.mainMenu = previousMenu
            withExtendedLifetime(recentController) {}
            let cleared = Workspace(recoveryDirectory: recovery)
            check(cleared.recentDocuments.urls.isEmpty, "Clear Menu survives restart without reseeding restored tabs")
            workspace.open(second)
            workspace.save(firstDocument)
            check(workspace.recentDocuments.urls.first == first, "an explicit save records the saved document in Open Recent")
            check(restored.active?.layout.rightWidth == 333 && restored.active?.layout.mode == .split, "session restores active tab and layout")
            check(restored.active?.comments.threads.first?.events.count == 4, "session restores reply and resolution history")
            workspace.openIncomingURL(try DocumentLink.url(for: second, line: 2))
            check(workspace.active?.id == secondDocument.id && workspace.documents.count == count &&
                  secondDocument.jump?.range.location == 9 && secondDocument.layout.mode == .rendered,
                  "document links reuse tabs, select Rendered mode, and navigate to a line")
            secondDocument.changed("# Unsaved changes\n")
            secondDocument.layout.showSinglePane(.raw)
            workspace.openIncomingURL(try DocumentLink.url(for: second))
            check(secondDocument.text == "# Unsaved changes\n" && secondDocument.isDirty && secondDocument.layout.mode == .rendered,
                  "links switch an existing Raw tab to Rendered without replacing live unsaved edits")
            workspace.openIncomingURL(URL(string: "parchment://open?path=/tmp/a.md&line=0")!)
            check(workspace.error != nil && workspace.documents.count == count && workspace.active?.id == secondDocument.id, "invalid document links leave tabs unchanged")
            workspace.error = nil
            firstDocument.selection = (firstDocument.text as NSString).range(of: "sentence")
            firstDocument.addComment(body: "Pending review comment", pending: true)
            let draftThread = firstDocument.comments.threads.last!
            firstDocument.editPendingMessage(draftThread.messages[0].id, in: draftThread.id, body: "Edited pending comment")
            try firstDocument.save()
            let pending = try CommentFile.read(for: first)
            check(pending.activeReview != nil && pending.pendingCount == 1 && pending.threads.last?.messages.first?.body == "Edited pending comment", "pending review and draft edits survive companion-file reload")
            let privateExport = String(decoding: try pending.export(text: firstDocument.text, path: first.path, includeResolved: true), as: UTF8.self)
            check(!privateExport.contains("Edited pending comment"), "pending draft stays out of saved-file exports")
            firstDocument.submitReview(summary: "Review complete")
            try firstDocument.save()
            check(try CommentFile.read(for: first).threads.last?.isPending == false, "review submission publishes its saved comments")
            workspace.close(firstDocument)
            workspace.open(first)
            check(workspace.active?.layout.mode == .rendered && workspace.active?.layout.previousSingleMode == .rendered &&
                  workspace.active?.layout.rightWidth == 333 && workspace.active?.layout.showFiles == true,
                  "reopening a closed file overrides its saved Split mode while retaining sidebar settings")
            workspace.active!.layout.showSinglePane(.raw)
            workspace.close(workspace.active!)
            workspace.open(first)
            check(workspace.active?.layout.mode == .rendered, "reopening a closed file overrides its saved Raw mode")
            workspace.newDocument(); workspace.active!.changed("An unsaved draft"); _ = workspace.persist()
            let draftRestored = Workspace(recoveryDirectory: recovery)
            check(draftRestored.active?.text == "An unsaved draft" && draftRestored.active?.url == nil, "unsaved draft survives restoration")
            try FileManager.default.removeItem(at: first)
            let missing = Workspace(recoveryDirectory: recovery)
            check(!missing.recentDocuments.urls.contains(first) && missing.recentDocuments.urls.contains(second),
                  "Open Recent omits missing files without losing available files")
            check(missing.documents.contains(where: { $0.url == nil && $0.text.contains("A sentence to review.") }) && missing.documents.contains(where: { $0.url == second }), "missing file recovers as a draft without losing other tabs")
            let corruptedDirectory = directory.appendingPathComponent("corrupt")
            try FileManager.default.createDirectory(at: corruptedDirectory, withIntermediateDirectories: true)
            let broken = Data("not a JSON session".utf8)
            try broken.write(to: corruptedDirectory.appendingPathComponent("session.json"))
            let corrupted = Workspace(recoveryDirectory: corruptedDirectory)
            _ = corrupted.persist()
            let backup = try FileManager.default.contentsOfDirectory(at: corruptedDirectory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("unreadable-session-") }
            check(backup.flatMap { try? Data(contentsOf: $0) } == broken, "unreadable session is preserved before replacement")
            workspace.documents.forEach { $0.saveTask?.cancel(); $0.renderTask?.cancel() }
            for url in [first, second] { UserDefaults.standard.removeObject(forKey: "layout:\(url.path)") }
            UserDefaults.standard.removeObject(forKey: "comments.read:\(firstDocument.id.uuidString)")
            try FileManager.default.removeItem(at: directory)
        } catch { failures += 1; print("FAIL storage checks: \(error)") }
        print("Storage checks: \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
