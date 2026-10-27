import AppKit
import ParchmentCore

struct NavigationLocation: Equatable {
    var documentID: UUID
    var url: URL?
    var selection: NSRange
    var layout: FileLayout
    var browserRoot: URL
    var selectedThread: UUID?
}

@MainActor extension Workspace {
    var canGoBack: Bool { !backHistory.isEmpty }
    var canGoForward: Bool { !forwardHistory.isEmpty }
    func location(of document: EditorDocument) -> NavigationLocation {
        NavigationLocation(documentID: document.id, url: document.url, selection: document.selection,
                           layout: document.layout, browserRoot: document.browserRoot, selectedThread: document.selectedThread)
    }
    func recordNavigation(_ location: NavigationLocation) {
        guard recordsNavigation, navigationDepth == 0 else { return }
        if backHistory.last != location { backHistory.append(location) }
        if backHistory.count > 200 { backHistory.removeFirst(backHistory.count - 200) }
        forwardHistory.removeAll()
    }
    func recordCurrentLocation() { if let active { recordNavigation(location(of: active)) } }
    func navigatedFromTab(_ id: UUID?) {
        guard let id, id != activeID, let document = documents.first(where: { $0.id == id }) else { return }
        recordNavigation(location(of: document))
    }
    func navigate(_ action: () -> Void) {
        let before = active.map(location)
        navigationDepth += 1
        action()
        navigationDepth -= 1
        if let before, before != active.map(location) { recordNavigation(before) }
    }
    func goBack() { traverseHistory(backward: true) }
    func goForward() { traverseHistory(backward: false) }
    private func traverseHistory(backward: Bool) {
        let current = active.map(location)
        navigationDepth += 1
        defer { navigationDepth -= 1; scheduleRecovery() }
        while let target = backward ? backHistory.popLast() : forwardHistory.popLast() {
            var document = documents.first { $0.id == target.documentID || (target.url != nil && $0.url == target.url) }
            if document == nil, let url = target.url {
                open(url)
                document = documents.first { $0.url == url }
            }
            guard let document else { continue }
            if let current {
                if backward { forwardHistory.append(current) } else { backHistory.append(current) }
            }
            activeID = document.id
            document.layout = target.layout; document.browserRoot = target.browserRoot
            document.selectedThread = target.selectedThread
            let length = document.text.utf16.count
            let start = min(target.selection.location, length)
            document.reveal(NSRange(location: start, length: min(target.selection.length, length - start)), restoreScroll: true)
            return
        }
    }
}

enum NavigationAction: Equatable {
    case back, forward
    static func action(for event: NSEvent) -> NavigationAction? {
        if event.type == .otherMouseDown {
            return event.buttonNumber == 3 ? .back : event.buttonNumber == 4 ? .forward : nil
        }
        if event.type == .swipe, abs(event.deltaX) > abs(event.deltaY), event.deltaX != 0 {
            return event.deltaX > 0 ? .back : .forward
        }
        guard event.type == .keyDown else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command {
            if event.charactersIgnoringModifiers == "[" { return .back }
            if event.charactersIgnoringModifiers == "]" { return .forward }
        }
        if modifiers == [.command, .option] {
            if event.keyCode == 123 { return .back }
            if event.keyCode == 124 { return .forward }
        }
        return nil
    }
    @MainActor func perform(in workspace: Workspace) {
        switch self { case .back: workspace.goBack(); case .forward: workspace.goForward() }
    }
}
