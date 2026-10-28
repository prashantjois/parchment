import AppKit
import SwiftUI

private final class SelectionCommentPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
private final class CommentPopoverBackground: NSVisualEffectView {
    var exited: (() -> Void)?
    override func mouseExited(with event: NSEvent) { exited?() }
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
    private weak var hoverAnchor: NSView?
    private var hoverDismiss: DispatchWorkItem?
    init(fileLevel: Bool = false) {
        super.init()
        Self.instances.add(self)
        if fileLevel { panel.setContentSize(NSSize(width: 194, height: 46)) }
        let background = CommentPopoverBackground(frame: panel.contentView!.bounds)
        background.exited = { [weak self] in self?.dismissHoverIfOutside() }
        background.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: background))
        background.material = .popover; background.state = .active
        background.wantsLayer = true; background.layer?.cornerRadius = 8
        let button = NSButton(title: fileLevel ? "Comment  ⌃⇧M" : "Comment  ⌃M", target: self, action: #selector(comment))
        button.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Comment")
        button.imagePosition = .imageLeading; button.bezelStyle = .recessed
        button.isBordered = true; button.showsBorderOnlyWhileMouseInside = true
        button.frame = background.bounds.insetBy(dx: 12, dy: 6); button.autoresizingMask = [.width, .height]
        button.toolTip = fileLevel ? "Add a comment to this file" : "Add a comment to the selected text"
        background.addSubview(button); panel.contentView = background
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .popUpMenu; panel.hidesOnDeactivate = true; panel.isReleasedWhenClosed = false
    }
    func schedule(in view: NSView, rect: NSRect, followsHover: Bool = false, action: @escaping () -> Void) {
        pending?.cancel()
        hoverDismiss?.cancel()
        hoverAnchor = followsHover ? view : nil
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
        hoverDismiss?.cancel(); hoverDismiss = nil; hoverAnchor = nil
        pending?.cancel(); pending = nil
        panel.orderOut(nil); panel.parent?.removeChildWindow(panel); action = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
    func dismissHoverIfOutside() {
        hoverDismiss?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let view = self.hoverAnchor, let window = view.window else { return }
            let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
            let point = NSEvent.mouseLocation
            if !anchor.insetBy(dx: -6, dy: -6).contains(point) && !self.panel.frame.insetBy(dx: -6, dy: -6).contains(point) { self.hide() }
        }
        hoverDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300), execute: work)
    }
    @objc private func comment() { let callback = action; hide(); callback?() }
}

struct TabCommentHover: NSViewRepresentable {
    var action: () -> Void
    func makeNSView(context: Context) -> TabCommentHoverView { TabCommentHoverView(action: action) }
    func updateNSView(_ view: TabCommentHoverView, context: Context) { view.action = action }
    static func dismantleNSView(_ view: TabCommentHoverView, coordinator: ()) { view.popover.hide() }
}

final class TabCommentHoverView: NSView {
    var action: () -> Void
    let popover = SelectionCommentPopover(fileLevel: true)
    private var area: NSTrackingArea?
    init(action: @escaping () -> Void) { self.action = action; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking); area = tracking
    }
    override func mouseEntered(with event: NSEvent) {
        popover.schedule(in: self, rect: bounds, followsHover: true) { [weak self] in self?.action() }
    }
    override func mouseExited(with event: NSEvent) { popover.dismissHoverIfOutside() }
}
