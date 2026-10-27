import AppKit
import SwiftUI

enum EditorShortcut: String, CaseIterable {
    case comment = "m", split = "s", rendered = "r", raw = "e", files = "n", contents = "t"
    static func action(for event: NSEvent) -> EditorShortcut? {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .control, .option, .shift]) == .control,
              let characters = event.charactersIgnoringModifiers?.lowercased() else { return nil }
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
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  window.attachedSheet == nil, window.sheetParent == nil, NSApp.modalWindow == nil,
                  let action = EditorShortcut.action(for: event), let workspace = self.workspace else { return event }
            action.perform(in: workspace)
            return nil
        }
    }
    func stopMonitoring() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil } }
}
