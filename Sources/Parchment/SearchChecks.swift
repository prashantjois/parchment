import AppKit
import SwiftUI
import WebKit
import ParchmentCore

@MainActor enum SearchChecks {
    static func run() -> Never {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        Task { @MainActor in exit(await check()) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) { fputs("Search checks timed out.\n", stderr); exit(1) }
        app.run(); exit(1)
    }
    static func check() async -> Int32 {
        var failures: Int32 = 0
        func expect(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL") \(label)")
            if !condition { failures += 1 }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parchment-search-" + UUID().uuidString)
        let domain = "parchment-search-preferences-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let workspace = Workspace(recoveryDirectory: directory, searchDefaults: defaults)
        defer {
            for document in workspace.documents { document.saveTask?.cancel(); document.renderTask?.cancel(); document.stopWatching() }
            try? FileManager.default.removeItem(at: directory)
        }
        let first = workspace.active!
        first.changed("# 🌎 Needle\n\n" + String(repeating: "Padding paragraph.\n\n", count: 80) + "Another needle.\n")
        first.layout.mode = .split
        workspace.newDocument()
        let second = workspace.active!
        second.changed("# Another tab\n\nneedle in an unsaved draft.\n")
        workspace.activeID = first.id
        let search = workspace.search
        func waitForSearch() async -> Bool {
            for _ in 0..<300 {
                if !search.isSearching { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }
        search.open(.document); search.query = "needle"
        expect(search.visible && search.results.count == 2 && search.results.allSatisfy { $0.documentID == first.id },
               "document search uses the active tab's live text")
        let firstMatch = search.results[0]
        expect(first.selection == firstMatch.occurrence.range && first.layout.mode == .split,
               "search selects the first match without changing the view mode")
        search.move(-1)
        expect(search.selectedID == search.results.last?.id, "previous match wraps to the last result")
        search.move(1)
        expect(search.selectedID == firstMatch.id, "next match wraps to the first result")

        let host = NSHostingView(rootView: WorkspaceView(workspace: workspace))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func settle() async {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(250))
        }
        await settle()
        guard let web = descendants(host).compactMap({ $0 as? PreviewWebView }).first else {
            print("FAIL search preview did not mount"); return 1
        }
        func javascript(_ script: String) async -> Any? {
            await withCheckedContinuation { continuation in
                web.evaluateJavaScript(script) { result, _ in continuation.resume(returning: result) }
            }
        }
        var previewHighlights = false
        for _ in 0..<80 {
            if await javascript("CSS.highlights?.get('search')?.size === 2 && CSS.highlights?.get('active-search')?.size === 1") as? Bool == true {
                previewHighlights = true; break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        expect(previewHighlights, "the actual preview highlights every occurrence and the current match")
        search.move(1)
        await settle()
        expect(await javascript("scrollY > 100") as? Bool == true,
               "next match scrolls the preview to an occurrence below the viewport")
        let rawColor = first.sourceTextView?.layoutManager?.temporaryAttribute(.backgroundColor,
            atCharacterIndex: firstMatch.occurrence.range.location, effectiveRange: nil)
        expect(rawColor != nil, "Raw mode highlights the same source occurrence")
        expect(descendants(host).contains { ($0 as? NSTextField)?.placeholderString == "Search Markdown…" },
               "the search field mounts in the editor window")
        search.caseSensitive = true
        expect(search.results.count == 1 && first.selection == search.results[0].occurrence.range,
               "match case updates results and the selected occurrence")
        search.caseSensitive = false
        search.open(.allDocuments)
        expect(search.results.count == 3 && Set(search.results.map(\.documentID)).count == 2,
               "all-documents search includes unsaved text from every open tab")
        search.select(search.results.last!)
        expect(workspace.activeID == second.id && second.selection == search.results.last?.occurrence.range,
               "choosing a result switches tabs and reveals its exact source range")
        second.changed("No remaining matches here.")
        expect(search.results.count == 2 && search.results.allSatisfy { $0.documentID == first.id },
               "live edits remove stale results")
        workspace.close(second, confirm: { _ in .alertThirdButtonReturn })
        expect(search.results.count == 2, "closing a tab removes it from the search scope")
        workspace.newDocument()
        let third = workspace.active!
        third.changed("needle in a newly opened tab")
        expect(search.results.count == 3, "new tabs join an active all-documents search")
        search.open(.document)
        expect(search.results.count == 1 && search.results[0].documentID == third.id,
               "document scope follows the selected tab")
        let jumpBeforeEdit = third.jump?.id
        let cursor = NSRange(location: third.text.utf16.count, length: 0)
        third.selection = cursor
        third.changed(third.text + " while search stays open")
        expect(search.results.count == 1 && third.selection == cursor && third.jump?.id == jumpBeforeEdit,
               "live document edits update matches without moving the typing cursor")
        search.query = "absent"
        expect(search.results.isEmpty && search.status == "No matches" && third.searchRanges.isEmpty,
               "no-match queries clear stale highlights")
        third.changed("🌎 CAFÉ cafe\u{301} cafe")
        search.query = "cafe"
        expect(search.results.count == 1, "diacritics match exactly by default")
        search.ignoreDiacritics = true
        expect(search.results.count == 3 && search.results[1].occurrence.range.length == 5,
               "ignoring diacritics finds composed and decomposed accents at original offsets")
        search.caseSensitive = true
        expect(search.results.count == 2, "case matching remains independent of diacritics")
        search.useRegex = true; search.query = "caf[eé]"
        expect(await waitForSearch() && search.results.count == 2 && search.errorMessage == nil,
               "regex combines with case and diacritic options")
        search.query = "("
        expect(await waitForSearch() && search.errorMessage?.contains("Invalid regular expression") == true && search.results.isEmpty && third.searchRanges.isEmpty,
               "invalid regex patterns show an error and clear old highlights")
        search.query = "cafe"
        expect(await waitForSearch() && search.errorMessage == nil && search.results.count == 2,
               "correcting a pattern clears the error and restores results")
        search.caseSensitive = false; search.open(.allDocuments)
        expect(await waitForSearch() && search.results.count == 3, "advanced options also work across all documents")
        search.open(.document)
        third.changed(String(repeating: "a", count: 8000) + "!")
        search.query = "(a+)+$"
        expect(await waitForSearch() && search.errorMessage?.contains("too long") == true,
               "expensive regex patterns stop with an error instead of blocking the editor")
        search.query = "never"; search.query = "!"
        expect(await waitForSearch() && search.results.count == 1 && search.errorMessage == nil,
               "a newer query cancels stale regex work")
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!
        expect(SearchShortcut.action(for: escape) == .close, "Escape routes to close search")
        SearchShortcut.action(for: escape)?.perform(in: workspace)
        expect(!search.visible && workspace.documents.allSatisfy { $0.searchRanges.isEmpty && $0.activeSearchRange == nil },
               "closing search clears highlights in every document")
        search.open(.document)
        expect(search.useRegex && search.ignoreDiacritics && !search.caseSensitive,
               "closing and reopening search preserves checked options")
        search.close()
        search.caseSensitive = true
        let restored = SearchController(defaults: UserDefaults(suiteName: domain)!)
        expect(restored.useRegex && restored.caseSensitive && restored.ignoreDiacritics,
               "a new search controller restores all three saved options")
        restored.useRegex = false; restored.caseSensitive = false; restored.ignoreDiacritics = false
        let unchecked = SearchController(defaults: UserDefaults(suiteName: domain)!)
        expect(!unchecked.useRegex && !unchecked.caseSensitive && !unchecked.ignoreDiacritics,
               "unchecking options also persists across reopen")
        await settle()
        if let editor = third.sourceTextView, let scroll = third.sourceScrollView {
            editor.window?.makeFirstResponder(editor)
            let sender = NSMenuItem(); sender.tag = NSTextFinder.Action.showReplaceInterface.rawValue
            editor.performFindPanelAction(sender)
            await settle()
            expect(scroll.isFindBarVisible, "Find and Replace opens the native editor's find bar")
            SearchShortcut.close.perform(in: workspace)
            expect(!scroll.isFindBarVisible && !search.visible, "Escape dismisses the native find bar even when search is already closed")
        } else {
            expect(false, "native editor is available for Find and Replace")
        }
        for (key, modifiers, expected) in [
            ("f", NSEvent.ModifierFlags.command, SearchShortcut.document),
            ("m", [.command, .shift], .allDocuments),
            ("g", .command, .next),
            ("g", [.command, .shift], .previous)
        ] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: 0)!
            expect(SearchShortcut.action(for: event) == expected, "\(modifiers.rawValue)-\(key) routes to the search command")
        }
        print("Search checks: \(failures) failures")
        return failures
    }
}
