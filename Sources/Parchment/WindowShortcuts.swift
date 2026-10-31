import AppKit
import SwiftUI

enum SearchShortcut {
    case document, allDocuments, next, previous, close
    static func action(for event: NSEvent) -> SearchShortcut? {
        guard event.type == .keyDown else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if modifiers.isEmpty && event.keyCode == 53 { return .close }
        if modifiers == .command && key == "f" { return .document }
        if modifiers == [.command, .shift] && key == "m" { return .allDocuments }
        if modifiers == .command && key == "g" { return .next }
        if modifiers == [.command, .shift] && key == "g" { return .previous }
        return nil
    }
    @MainActor func perform(in workspace: Workspace) {
        switch self {
        case .document: workspace.search.open(.document)
        case .allDocuments: workspace.search.open(.allDocuments)
        case .next: workspace.search.move(1)
        case .previous: workspace.search.move(-1)
        case .close: workspace.search.close()
        }
    }
}

enum EditorShortcut: String, CaseIterable {
    case comment = "m", fileComment = "M", split = "s", rendered = "r", raw = "e", files = "n", contents = "t"
    static func action(for event: NSEvent) -> EditorShortcut? {
        guard event.type == .keyDown, let characters = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == [.control, .shift], characters == "m" || characters == "\r" { return .fileComment }
        guard modifiers == .control else { return nil }
        if let action = Self(rawValue: characters) { return action }
        // Some keyboard layouts report a control character instead of its letter.
        if characters.unicodeScalars.count == 1, let value = characters.unicodeScalars.first?.value, (1...26).contains(value) {
            return Self(rawValue: String(UnicodeScalar(value + 96)!))
        }
        return nil
    }
    @MainActor func perform(in workspace: Workspace) {
        switch self {
        case .comment: workspace.beginComment()
        case .fileComment: workspace.beginFileComment()
        case .split: workspace.toggleSplit()
        case .rendered: workspace.showSinglePane(.rendered)
        case .raw: workspace.showSinglePane(.raw)
        case .files: workspace.toggleFiles()
        case .contents: workspace.toggleRight(.contents)
        }
    }
}

/// Handle control shortcuts before AppKit's Emacs bindings or WebKit consume
/// them. Scope the monitor to this editor window; sheets keep normal editing.
struct WindowShortcutBridge: NSViewRepresentable {
    var workspace: Workspace
    func makeNSView(context: Context) -> ShortcutHostView { ShortcutHostView(workspace: workspace) }
    func updateNSView(_ view: ShortcutHostView, context: Context) { view.workspace = workspace }
    static func dismantleNSView(_ view: ShortcutHostView, coordinator: ()) { view.stopMonitoring() }
}

@MainActor final class ShortcutHostView: NSView {
    weak var workspace: Workspace?
    private var monitor: Any?
    init(workspace: Workspace) { self.workspace = workspace; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown, .otherMouseUp, .swipe]) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  window.attachedSheet == nil, window.sheetParent == nil, NSApp.modalWindow == nil,
                  let workspace = self.workspace else { return event }
            if let action = NavigationAction.action(for: event) { action.perform(in: workspace); return nil }
            if let action = SearchShortcut.action(for: event),
               action != .close || workspace.search.visible || workspace.active?.sourceScrollView?.isFindBarVisible == true {
                action.perform(in: workspace); return nil
            }
            if event.type == .otherMouseUp && [3, 4].contains(event.buttonNumber) { return nil }
            guard let action = EditorShortcut.action(for: event) else { return event }
            action.perform(in: workspace)
            return nil
        }
    }
    func stopMonitoring() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil } }
}
