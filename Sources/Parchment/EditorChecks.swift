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
        document.saveTask?.cancel(); document.renderTask?.cancel()
        print("Editor checks: \(failures) failures")
        return failures == 0 ? 0 : 1
    }
}
