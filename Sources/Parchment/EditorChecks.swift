import AppKit
import ParchmentCore

@MainActor enum EditorChecks {
    static func run() -> Never {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        Task { @MainActor in exit(await check()) }
        app.run(); exit(1)
    }
    static func check() async -> Int32 {
        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL") \(label)")
            if !condition { failures += 1 }
        }
        let document = EditorDocument(url: nil, text: "# Start\n")
        document.layout.mode = .split
        let pane = SourcePane(document: document, beginComment: {})
        let coordinator = pane.makeCoordinator()
        let scroll = pane.makeEditor(coordinator: coordinator)
        guard let text = scroll.documentView as? MarkdownTextView else { print("FAIL missing native editor"); return 1 }
        try? await Task.sleep(for: .milliseconds(30))
        expect(text.isEditable && text.isSelectable && !text.isRichText && text.frame.height > 0 && text.frame.width > 0, "raw editor is editable and fills its viewport")
        document.undoManager.groupsByEvent = false
        func edit(_ action: () -> Void) {
            text.breakUndoCoalescing()
            document.undoManager.beginUndoGrouping(); action(); document.undoManager.endUndoGrouping()
            text.breakUndoCoalescing()
        }
        edit { text.insertText("# Updated\n\nA live preview.", replacementRange: NSRange(location: 0, length: (text.string as NSString).length)) }
        expect(document.text == "# Updated\n\nA live preview.", "native edits update the document")
        try? await Task.sleep(for: .milliseconds(260))
        expect(document.renderedSource == document.text && document.rendered.headings.first?.title == "Updated" && document.rendered.html.contains("A live preview."), "split preview updates after a typing pause")
        document.undoManager.undo()
        expect(document.text == "# Start\n", "native undo restores the document")
        document.undoManager.redo()
        expect(document.text == "# Updated\n\nA live preview.", "native redo restores the edit")

        let clipboard = NSPasteboard(name: NSPasteboard.Name("ParchmentChecks-" + UUID().uuidString))
        // NSTextView can advertise the legacy NSStringPboardType. Use its
        // advertised plain-text type, as its native Copy/Paste commands do.
        let plainTextType = text.writablePasteboardTypes.first ?? .string
        clipboard.declareTypes([plainTextType], owner: nil)
        text.setSelectedRange((text.string as NSString).range(of: "live"))
        let copied = text.writeSelection(to: clipboard, types: [plainTextType])
        expect(copied && clipboard.string(forType: plainTextType) == "live", "native copy writes the selected text")
        text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
        edit { _ = text.readSelection(from: clipboard, type: plainTextType) }
        expect(document.text.hasSuffix("preview.live"), "native plain-text paste updates the document")
        edit { text.deleteBackward(nil) }
        expect(document.text.hasSuffix("preview.liv"), "native deletion updates the document")
        clipboard.releaseGlobally()

        edit { text.insertText("one\ntwo\n", replacementRange: NSRange(location: 0, length: (text.string as NSString).length)) }
        text.selectAll(nil)
        edit { text.indentSelection() }
        expect(document.text == "    one\n    two\n", "indent applies to selected lines")
        edit { text.outdentSelection() }
        expect(document.text == "one\ntwo\n", "outdent restores selected lines")
        edit { text.insertText("- task", replacementRange: NSRange(location: 0, length: (text.string as NSString).length)); text.insertNewline(nil) }
        expect(document.text == "- task\n- ", "Enter continues a Markdown list")
        edit { text.insertNewline(nil) }
        expect(document.text == "- task\n", "Enter on an empty list item ends the list")

        edit { text.insertText("# First", replacementRange: NSRange(location: 0, length: (text.string as NSString).length)) }
        edit { text.insertText("# Latest", replacementRange: NSRange(location: 0, length: (text.string as NSString).length)) }
        try? await Task.sleep(for: .milliseconds(260))
        expect(document.renderedSource == "# Latest" && document.rendered.headings.first?.title == "Latest", "rapid edits render the latest revision")
        document.layout.showSinglePane(.rendered); document.layout.showSinglePane(.raw)
        let reusedPane = SourcePane(document: document, beginComment: {})
        let reusedCoordinator = reusedPane.makeCoordinator()
        let reused = reusedPane.makeEditor(coordinator: reusedCoordinator)
        expect(reused.documentView === text && document.undoManager.canUndo, "view switches preserve the editor and undo history")

        for shortcut in EditorShortcut.allCases {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0, windowNumber: 0, context: nil, characters: shortcut.rawValue, charactersIgnoringModifiers: shortcut.rawValue, isARepeat: false, keyCode: 0)!
            expect(EditorShortcut.action(for: event) == shortcut, "Control-\(shortcut.rawValue.uppercased()) routes to \(shortcut)")
        }
        let command = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1)!
        expect(EditorShortcut.action(for: command) == nil, "Command-S remains the normal save shortcut")
        let controlM = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 46)!
        expect(EditorShortcut.action(for: controlM) == .comment, "Control-M control-character events route to comments")
        for (characters, flags, key, expected) in [
            ("[", NSEvent.ModifierFlags.command, UInt16(33), NavigationAction.back),
            ("]", .command, UInt16(30), .forward),
            ("", [.command, .option], UInt16(123), .back),
            ("", [.command, .option], UInt16(124), .forward)
        ] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: key)!
            expect(NavigationAction.action(for: event) == expected, "navigation keyboard shortcut routes to \(expected)")
        }
        for (button, expected) in [(3, NavigationAction.back), (4, .forward)] {
            let event = NSEvent(cgEvent: CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero, mouseButton: CGMouseButton(rawValue: UInt32(button))!)!)!
            expect(NavigationAction.action(for: event) == expected, "mouse button \(button + 1) routes to \(expected)")
        }
        let wordMovement = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 123)!
        expect(NavigationAction.action(for: wordMovement) == nil, "Option-Left remains native word navigation")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parchment-external-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = directory.appendingPathComponent("external.md")
            try "Original text\n".write(to: path, atomically: true, encoding: .utf8)
            let workspace = Workspace(recoveryDirectory: directory.appendingPathComponent("recovery"))
            workspace.open(path)
            let external = workspace.active!
            defer { workspace.documents.forEach { $0.saveTask?.cancel(); $0.renderTask?.cancel(); $0.stopWatching() } }
            let linked = directory.appendingPathComponent("Linked café + #.md")
            try "# Target\n\n## Section\n".write(to: linked, atomically: true, encoding: .utf8)
            var externalLinks: [URL] = []
            let preview = RenderedPane(document: external, themes: workspace.themes,
                openDocument: workspace.openIncomingURL, openExternal: { externalLinks.append($0) }, beginComment: {})
            let navigation = preview.makeCoordinator()
            var target = URLComponents(url: linked, resolvingAgainstBaseURL: false)!
            target.fragment = "section"
            navigation.openLink(target.url!)
            expect(workspace.active?.url == linked && workspace.active?.jump?.range.location == 10, "local preview links open the target file and heading")
            workspace.active!.changed("Local target edits")
            navigation.openLink(linked)
            expect(workspace.active?.text == "Local target edits" && workspace.documents.filter { $0.url == linked }.count == 1, "local links reuse existing tabs and preserve unsaved edits")
            navigation.openLink(try DocumentLink.url(for: path, line: 1))
            expect(workspace.active?.id == external.id, "Parchment links navigate inside the current workspace")
            navigation.openLink(directory)
            expect(external.browserRoot.path == directory.resolvingSymlinksInPath().path && external.layout.showFiles, "folder links navigate the file browser")
            let browser = URL(string: "https://example.com/guide#section")!
            navigation.openLink(browser)
            expect(externalLinks == [browser] && workspace.active?.id == external.id, "external links use the system-browser action without changing tabs")
            navigation.openLink(URL(string: "file://remote-host/tmp/ignored.md")!)
            expect(workspace.active?.id == external.id && externalLinks.count == 1, "remote file URLs do not enter local navigation")
            workspace.backHistory.removeAll(); workspace.forwardHistory.removeAll()
            external.layout.mode = .split; external.layout.sourceScroll = 0.35; external.layout.renderedScroll = 0.4
            external.selection = NSRange(location: 4, length: 2)
            navigation.openLink(target.url!)
            expect(workspace.backHistory.count == 1 && workspace.canGoBack && !workspace.canGoForward, "a file-and-heading link records one navigation step")
            workspace.goBack()
            expect(workspace.active?.id == external.id && external.selection == NSRange(location: 4, length: 2) && external.layout.sourceScroll == 0.35 && external.layout.renderedScroll == 0.4 && external.jump?.restoreScroll == true, "Back restores the previous file, selection, and both scroll positions")
            workspace.goForward()
            expect(workspace.active?.url == linked && workspace.active?.text == "Local target edits", "Forward returns to the live target without replacing unsaved text")
            let destination = workspace.active!
            destination.reveal(NSRange(location: 1, length: 0))
            workspace.goBack()
            expect(workspace.active?.id == destination.id && destination.selection.location != 1, "same-document jumps participate in history")
            workspace.goBack()
            let otherFolder = directory.appendingPathComponent("other", isDirectory: true)
            try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
            workspace.openIncomingURL(otherFolder)
            expect(!workspace.canGoForward, "a new destination after Back clears forward history")
            workspace.open(linked)
            destination.saveTask?.cancel(); destination.isDirty = false
            workspace.open(path)
            workspace.close(destination)
            workspace.goBack()
            expect(workspace.active?.url == linked, "Back reopens a closed saved file")
            workspace.open(path)
            workspace.documents.first(where: { $0.url == linked })?.saveTask?.cancel()
            UserDefaults.standard.removeObject(forKey: "layout:\(linked.path)")
            let externalPane = SourcePane(document: external, beginComment: {})
            let externalCoordinator = externalPane.makeCoordinator()
            _ = externalPane.makeEditor(coordinator: externalCoordinator)
            external.selection = NSRange(location: 0, length: 8)
            external.addComment(body: "Keep this pending review.", pending: true)
            external.changed("Local unsaved text\n")
            try "External replacement\n".write(to: path, atomically: true, encoding: .utf8)
            for _ in 0..<40 where external.externalChange == nil { try? await Task.sleep(for: .milliseconds(25)) }
            expect(external.externalChange?.text == "External replacement\n" && external.text == "Local unsaved text\n", "atomic external replacements prompt without replacing local text")
            external.keepLocalChanges()
            external.changed("Local edits after rejection\n")
            try? await Task.sleep(for: .milliseconds(950))
            expect(try String(contentsOf: path, encoding: .utf8) == "External replacement\n" && external.autosaveSuspended, "rejecting external changes pauses autosave for subsequent edits")
            expect(workspace.persist(), "conflicting local text persists in recovery")
            let restored = Workspace(recoveryDirectory: directory.appendingPathComponent("recovery"))
            expect(restored.active?.text == external.text && restored.active?.autosaveSuspended == true && restored.active?.isDirty == true, "recovery preserves local text and paused autosave")
            restored.documents.forEach { $0.saveTask?.cancel(); $0.renderTask?.cancel(); $0.stopWatching() }
            try "External in-place edit\n".write(to: path, atomically: false, encoding: .utf8)
            for _ in 0..<40 where external.externalChange == nil { try? await Task.sleep(for: .milliseconds(25)) }
            expect(external.externalChange?.text == "External in-place edit\n", "in-place external edits remain observable after atomic replacement")
            external.loadExternalChanges()
            expect(external.text == "External in-place edit\n" && external.sourceTextView?.string == external.text && external.renderedSource == external.text && !external.autosaveSuspended, "accepting external changes updates both panes and resumes autosave")
            expect(external.comments.pendingCount == 1, "reloading Markdown preserves local review drafts")
            try external.save()
            try? await Task.sleep(for: .milliseconds(150))
            expect(external.externalChange == nil, "the app's own saves do not trigger external-change prompts")
            external.changed("Local text before race\n")
            try "External save race\n".write(to: path, atomically: true, encoding: .utf8)
            do { try external.save(); expect(false, "save must detect an external write before watcher delivery") }
            catch DocumentSaveError.externalChange { expect(true, "save detects an external write before watcher delivery") }
            expect(try String(contentsOf: path, encoding: .utf8) == "External save race\n", "automatic save never overwrites an unreviewed external version")
            external.keepLocalChanges()
            try external.save(overwriteExternalChanges: true)
            expect(try String(contentsOf: path, encoding: .utf8) == "Local text before race\n" && !external.autosaveSuspended, "explicit overwrite saves local text and resumes autosave")
            try FileManager.default.removeItem(at: path)
            for _ in 0..<40 where external.externalChange == nil { try? await Task.sleep(for: .milliseconds(25)) }
            expect(external.externalChange != nil && external.externalChange?.text == nil && external.text == "Local text before race\n", "deleting the file preserves local text and pauses autosave")
            external.keepLocalChanges()
            try "Recreated externally\n".write(to: path, atomically: true, encoding: .utf8)
            for _ in 0..<40 where external.externalChange == nil { try? await Task.sleep(for: .milliseconds(25)) }
            expect(external.externalChange?.text == "Recreated externally\n", "watching continues when a deleted file reappears")
            UserDefaults.standard.removeObject(forKey: "layout:\(path.path)")
        } catch { failures += 1; print("FAIL external file checks: \(error)") }
        document.saveTask?.cancel(); document.renderTask?.cancel()
        print("Editor checks: \(failures) failures")
        return failures == 0 ? 0 : 1
    }
}
