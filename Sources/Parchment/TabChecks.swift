import AppKit
import SwiftUI
import ParchmentCore

@MainActor enum TabChecks {
    static func run() -> Never {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        Task { @MainActor in exit(await check()) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { fputs("Tab checks timed out.\n", stderr); exit(1) }
        app.run(); exit(1)
    }

    static func check() async -> Int32 {
        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL") \(label)")
            if !condition { failures += 1 }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parchment-tabs-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func workspace(_ name: String) -> Workspace {
            let result = Workspace(recoveryDirectory: root.appendingPathComponent(name))
            result.close(result.active!)
            return result
        }
        func add(_ text: String, to workspace: Workspace) -> EditorDocument {
            let document = EditorDocument(url: nil, text: text)
            workspace.attach(document)
            return document
        }
        let tabs = workspace("order")
        let a = add("First unsaved draft", to: tabs), b = add("Second unsaved draft", to: tabs)
        let c = add("Third unsaved draft", to: tabs), d = add("Fourth unsaved draft", to: tabs)
        b.layout.mode = .split; b.selection = NSRange(location: 2, length: 3)
        b.layout.renderedScroll = 0.4
        b.addComment(body: "Keep this file comment", fileLevel: true)
        tabs.activeID = b.id
        let history = tabs.backHistory
        expect(tabs.moveTab(a.id, relativeTo: d.id, edge: .after) && tabs.documents.map(\.id) == [b.id, c.id, d.id, a.id],
               "dragging a tab right can place it after the last tab")
        expect(tabs.moveTab(a.id, relativeTo: b.id, edge: .before) && tabs.documents.map(\.id) == [a.id, b.id, c.id, d.id],
               "dragging a tab left can place it before the first tab")
        expect(tabs.moveTab(b.id, relativeTo: d.id, edge: .before) && tabs.documents.map(\.id) == [a.id, c.id, b.id, d.id],
               "dropping before a later tab uses the correct insertion index")
        expect(tabs.moveTab(d.id, relativeTo: a.id, edge: .after) && tabs.documents.map(\.id) == [a.id, d.id, c.id, b.id],
               "dropping after an earlier tab uses the correct insertion index")
        expect(tabs.active === b && tabs.backHistory == history && b.text == "Second unsaved draft" &&
               b.layout.mode == .split && b.selection == NSRange(location: 2, length: 3) &&
               b.layout.renderedScroll == 0.4 && b.comments.threads.count == 1,
               "reordering preserves the active document, unsaved text, layout, comments, and navigation history")
        let order = tabs.documents.map(\.id)
        expect(!tabs.moveTab(b.id, relativeTo: b.id, edge: .before) &&
               !tabs.moveTab(UUID(), relativeTo: a.id, edge: .after) &&
               !tabs.moveTab(a.id, relativeTo: UUID(), edge: .before) &&
               !tabs.moveTab(a.id, relativeTo: d.id, edge: .before) && tabs.documents.map(\.id) == order,
               "self, stale, and unchanged drop positions do not alter the workspace")
        let provider = DocumentTabDrag.provider(for: a.id)
        let data: Data? = await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: DocumentTabDrag.type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
        expect(data.flatMap { String(data: $0, encoding: .utf8) } == a.id.uuidString && tabs.documents.map(\.id) == order,
               "starting a native tab drag supplies its stable ID without changing tab order")
        expect(tabs.persist(), "reordered tabs save to session recovery")
        let restored = Workspace(recoveryDirectory: root.appendingPathComponent("order"))
        expect(restored.documents.map(\.id) == order && restored.activeID == b.id &&
               restored.active?.text == b.text && restored.active?.comments.threads.count == 1,
               "reopening restores tab order, selection, unsaved drafts, and file comments")
        expect(tabs.tabsToClose(.before, relativeTo: c.id).map(\.id) == [a.id, d.id] &&
               tabs.tabsToClose(.after, relativeTo: c.id).map(\.id) == [b.id],
               "close-before and close-after use the clicked tab in its current order")
        expect(tabs.tabsToClose(.before, relativeTo: a.id).isEmpty &&
               tabs.tabsToClose(.after, relativeTo: b.id).isEmpty &&
               tabs.tabsToClose(.after, relativeTo: UUID()).isEmpty,
               "edge tabs and stale targets have no relative close targets")
        var confirmed: [UUID] = []
        expect(!tabs.closeTabs(.before, relativeTo: c.id, confirm: { document in
            confirmed.append(document.id)
            return document === a ? .alertThirdButtonReturn : .alertSecondButtonReturn
        }) && confirmed == [a.id, d.id] && tabs.documents.map(\.id) == [d.id, c.id, b.id],
               "bulk close stops at Cancel and leaves that tab and subsequent targets open")
        expect(tabs.closeTabs(.after, relativeTo: c.id, confirm: { _ in .alertThirdButtonReturn }) &&
               tabs.documents.map(\.id) == [d.id, c.id] && tabs.activeID == c.id,
               "close-after excludes the clicked tab and selects a remaining neighbor if needed")
        let previousActive = tabs.activeID
        expect(tabs.closeTabs(.before, relativeTo: c.id, confirm: { _ in .alertThirdButtonReturn }) &&
               tabs.documents.map(\.id) == [c.id] && tabs.activeID == previousActive,
               "closing background tabs preserves the active tab")
        expect(tabs.closeTabs(.all, confirm: { _ in .alertThirdButtonReturn }) && tabs.documents.isEmpty && tabs.activeID == nil,
               "close-all can close the final tab without creating an extra draft")
        expect(!tabs.close(c, confirm: { _ in .alertThirdButtonReturn }), "closing an already closed tab is harmless")

        let failed = workspace("failed-save")
        let first = add("", to: failed)
        let broken = add("Unsaved work that must remain open", to: failed)
        broken.url = root.appendingPathComponent("missing-parent/document.md"); broken.isDirty = true
        let last = add("", to: failed)
        expect(!failed.closeTabs(.all) && failed.documents.map(\.id) == [broken.id, last.id] &&
               !failed.documents.contains(where: { $0 === first }) && failed.error != nil && broken.isDirty,
               "a save failure stops close-all and preserves unsaved work and remaining tabs")

        let overflow = workspace("overflow")
        let many = (0..<20).map { add("Draft \($0)\n", to: overflow) }
        overflow.activateTab(many[0].id)
        many[0].layout.mode = .raw
        let host = NSHostingView(rootView: WorkspaceView(workspace: overflow))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        func settle() async {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(350))
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        await settle()
        let bar = descendants(host).compactMap { $0 as? NSScrollView }.first {
            $0.frame.height <= 45 && ($0.documentView?.frame.width ?? 0) > $0.contentSize.width
        }
        expect(bar != nil, "many open tabs create a horizontally scrolling tab bar")
        overflow.activateTab(many.last!.id)
        await settle()
        expect((bar?.contentView.bounds.minX ?? 0) > 100, "activating the last tab scrolls it into view")
        bar?.contentView.scroll(to: .zero)
        if let bar { bar.reflectScrolledClipView(bar.contentView) }
        overflow.activateTab(many.last!.id)
        await settle()
        expect((bar?.contentView.bounds.minX ?? 0) > 100, "reselecting the current tab reveals it after manually scrolling away")
        expect(window.firstResponder === many.last?.sourceTextView, "activating a Raw tab focuses its editor")
        overflow.activateTab(many[0].id)
        await settle()
        expect((bar?.contentView.bounds.minX ?? 100) < 1, "switching back to the first tab reveals it")
        overflow.nextTab(-1)
        await settle()
        expect(overflow.activeID == many.last?.id && (bar?.contentView.bounds.minX ?? 0) > 100,
               "keyboard tab switching also reveals and focuses the selected tab")
        overflow.moveTab(many.last!.id, relativeTo: many[0].id, edge: .before)
        await settle()
        expect((bar?.contentView.bounds.minX ?? 100) < 1, "reordering keeps the active tab visible in its new position")
        overflow.activateTab(many[18].id)
        window.setContentSize(NSSize(width: 700, height: 600))
        await settle()
        if let bar, let content = bar.documentView {
            expect(abs(bar.contentView.bounds.maxX - content.bounds.maxX) < 5,
                   "resizing the window keeps the active last tab fully visible")
        }
        expect(overflow.searchTabs("Draft 17").map(\.id) == [many[17].id], "tab search identifies unsaved drafts by their first line")
        expect(overflow.searchTabs("   ").count == many.count && overflow.searchTabs("missing-name").isEmpty,
               "tab search handles empty filters and no matches")
        let namedPath = root.appendingPathComponent("Café notes.md")
        try! "Saved file".write(to: namedPath, atomically: true, encoding: .utf8)
        let named = EditorDocument(url: namedPath, text: "Saved file")
        overflow.attach(named)
        named.layout.mode = .rendered; overflow.activateTab(named.id)
        await settle()
        let preview = descendants(host).compactMap { $0 as? PreviewWebView }.first
        let responder = window.firstResponder as? NSView
        expect(preview != nil && (responder === preview || responder?.isDescendant(of: preview!) == true),
               "activating a Rendered tab focuses its preview")
        expect(overflow.searchTabs("CAFE NOTES").map(\.id) == [named.id] && overflow.searchTabs(root.lastPathComponent).map(\.id) == [named.id],
               "tab search matches names and paths without case or accent differences")
        let shortcut = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40)!
        expect(SearchShortcut.action(for: shortcut) == .tabs, "Command-K routes to tab search")
        overflow.presentTabSearch()
        expect(overflow.showTabSearch, "tab search can be opened for the current workspace")
        overflow.activateTab(many[17].id)
        expect(!overflow.showTabSearch && overflow.activeID == many[17].id && many[17].focusRequest != nil,
               "choosing a tab dismisses the picker and requests document focus")
        for document in overflow.documents { document.saveTask?.cancel(); document.renderTask?.cancel(); document.stopWatching() }
        print("Tab checks: \(failures) failures")
        return failures == 0 ? 0 : 1
    }
}
