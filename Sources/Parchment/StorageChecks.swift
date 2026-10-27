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
            workspace.open(second); let secondDocument = workspace.active!
            check(secondDocument.layout.mode == .raw && !secondDocument.layout.showFiles, "tabs have independent layouts")
            let count = workspace.documents.count
            workspace.open(first)
            check(workspace.active?.id == firstDocument.id && workspace.documents.count == count, "opening an existing file reuses its tab")
            check(workspace.persist(), "session persists")
            let restored = Workspace(recoveryDirectory: recovery)
            check(restored.active?.layout.rightWidth == 333 && restored.active?.layout.mode == .split, "session restores active tab and layout")
            check(restored.active?.comments.threads.first?.events.count == 3, "session restores reply and resolution history")
            workspace.openIncomingURL(try DocumentLink.url(for: second, line: 2))
            check(workspace.active?.id == secondDocument.id && workspace.documents.count == count && secondDocument.jump?.range.location == 9, "document links reuse tabs and navigate to a line")
            secondDocument.changed("# Unsaved changes\n")
            workspace.openIncomingURL(try DocumentLink.url(for: second))
            check(secondDocument.text == "# Unsaved changes\n" && secondDocument.isDirty, "document links preserve live unsaved edits")
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
            workspace.newDocument(); workspace.active!.changed("An unsaved draft"); _ = workspace.persist()
            let draftRestored = Workspace(recoveryDirectory: recovery)
            check(draftRestored.active?.text == "An unsaved draft" && draftRestored.active?.url == nil, "unsaved draft survives restoration")
            try FileManager.default.removeItem(at: first)
            let missing = Workspace(recoveryDirectory: recovery)
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
            try FileManager.default.removeItem(at: directory)
        } catch { failures += 1; print("FAIL storage checks: \(error)") }
        print("Storage checks: \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
