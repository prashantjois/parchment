import AppKit

private final class SelectionCommentPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A nonactivating selection bubble. Highlighting text never moves keyboard
/// focus away from the editor, and clicking Comment preserves the source range.
@MainActor final class SelectionCommentPopover: NSObject {
    private static let instances = NSHashTable<SelectionCommentPopover>.weakObjects()
    static func hideAll() { instances.allObjects.forEach { $0.hide() } }
    private let panel = SelectionCommentPanel(contentRect: NSRect(x: 0, y: 0, width: 174, height: 46), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var pending: DispatchWorkItem?
    private var action: (() -> Void)?
    private var monitor: Any?
    override init() {
        super.init()
        Self.instances.add(self)
        let background = NSVisualEffectView(frame: panel.contentView!.bounds)
        background.material = .popover; background.state = .active
        background.wantsLayer = true; background.layer?.cornerRadius = 8
        let button = NSButton(title: "Comment  ⌃M", target: self, action: #selector(comment))
        button.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Comment")
        button.imagePosition = .imageLeading; button.isBordered = false
        button.frame = background.bounds.insetBy(dx: 12, dy: 6); button.autoresizingMask = [.width, .height]
        button.toolTip = "Add a comment to the selected text"
        background.addSubview(button); panel.contentView = background
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .popUpMenu; panel.hidesOnDeactivate = true; panel.isReleasedWhenClosed = false
    }
    func schedule(in view: NSView, rect: NSRect, action: @escaping () -> Void) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self, weak view] in
            guard let self, let view, let window = view.window, window.isKeyWindow,
                  window.attachedSheet == nil, window.sheetParent == nil, NSEvent.pressedMouseButtons == 0 else { return }
            let anchor = rect.intersection(view.visibleRect)
            guard !anchor.isEmpty else { self.hide(); return }
            let screenRect = window.convertToScreen(view.convert(anchor, to: nil))
            let screen = window.screen?.visibleFrame ?? screenRect.insetBy(dx: -200, dy: -200)
            let size = self.panel.frame.size
            let x = min(max(screenRect.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
            let y = screenRect.maxY + size.height + 6 < screen.maxY ? screenRect.maxY + 6 : screenRect.minY - size.height - 6
            self.action = action
            if self.panel.parent !== window {
                self.panel.parent?.removeChildWindow(self.panel)
                window.addChildWindow(self.panel, ordered: .above)
            }
            self.panel.setFrameOrigin(NSPoint(x: x, y: max(screen.minY + 8, y)))
            self.panel.orderFront(nil)
            if self.monitor == nil {
                self.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
                    if let self, event.window !== self.panel { self.hide() }
                    return event
                }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(180), execute: work)
    }
    func hide() {
        pending?.cancel(); pending = nil
        panel.orderOut(nil); panel.parent?.removeChildWindow(panel); action = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
    @objc private func comment() { let callback = action; hide(); callback?() }
}
