import AppKit
import SwiftUI
import ParchmentCore

final class MarkdownTextView: NSTextView {
    var commentAction: (() -> Void)?
    var selectionFinished: (() -> Void)?
    let selectionPopover = SelectionCommentPopover()
    override func mouseDown(with event: NSEvent) {
        selectionPopover.hide()
        super.mouseDown(with: event)
        selectionFinished?()
    }
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
    override func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard types.contains(.string), selectedRange().length > 0 else { return false }
        pasteboard.declareTypes([.string], owner: nil)
        return writeSelection(to: pasteboard, type: .string)
    }
    override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, selectedRange().length > 0 else { return false }
        let content = selectedRanges.map { (string as NSString).substring(with: $0.rangeValue) }.joined(separator: "\n")
        return pasteboard.setString(content, forType: .string)
    }
    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard isEditable, type == .string, let content = pasteboard.string(forType: .string) else { return false }
        // Use the native insertion path so paste participates in undo and live rendering.
        insertText(content, replacementRange: selectedRange())
        return true
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        selectionPopover.hide()
        menu.addItem(.separator())
        let item = NSMenuItem(title: "Add Comment", action: #selector(addComment), keyEquivalent: "")
        item.target = self; item.isEnabled = selectedRange().length > 0; menu.addItem(item)
        return menu
    }
    @objc func addComment() { guard selectedRange().length > 0 else { return }; selectionPopover.hide(); commentAction?() }
    @objc func wrapBold() { wrap("**") }
    @objc func wrapItalic() { wrap("*") }
    @objc func wrapCode() { wrap("`") }
    @objc func indentSelection() { changeIndent(removing: false) }
    @objc func outdentSelection() { changeIndent(removing: true) }
    override func insertTab(_ sender: Any?) {
        if selectedRange().length > 0 { indentSelection() }
        else { insertText("    ", replacementRange: selectedRange()) }
    }
    override func insertBacktab(_ sender: Any?) { outdentSelection() }
    private func changeIndent(removing: Bool) {
        let selection = selectedRange(), ns = string as NSString
        let lines = ns.lineRange(for: NSRange(location: selection.location, length: max(0, selection.length - 1)))
        let parts = ns.substring(with: lines).components(separatedBy: "\n")
        let replacement = parts.enumerated().map { index, line -> String in
            if index == parts.count - 1 && line.isEmpty { return line }
            if !removing { return "    " + line }
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            return String(line.dropFirst(line.prefix(4).prefix(while: { $0 == " " }).count))
        }.joined(separator: "\n")
        insertText(replacement, replacementRange: lines)
        setSelectedRange(NSRange(location: lines.location, length: replacement.utf16.count))
    }
    private func wrap(_ marker: String) {
        let range = selectedRange(), selection = (string as NSString).substring(with: range)
        insertText(marker + selection + marker, replacementRange: range)
        setSelectedRange(NSRange(location: range.location + marker.utf16.count, length: range.length))
    }
    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString, selection = selectedRange()
        let range = ns.lineRange(for: NSRange(location: selection.location, length: 0))
        let before = ns.substring(with: NSRange(location: range.location, length: selection.location - range.location))
        let pattern = #"^(\s*)([-*+] |\d+\. )(\[[ xX]\] )?"#
        guard selection.length == 0, let match = before.range(of: pattern, options: .regularExpression) else { super.insertNewline(sender); return }
        let prefix = String(before[match])
        if before.trimmingCharacters(in: .whitespaces) == prefix.trimmingCharacters(in: .whitespaces) {
            insertText("", replacementRange: NSRange(location: range.location, length: prefix.utf16.count)); return
        }
        var next = prefix.replacingOccurrences(of: "[x]", with: "[ ]").replacingOccurrences(of: "[X]", with: "[ ]")
        if let digits = prefix.range(of: #"\d+(?=\. )"#, options: .regularExpression), let number = Int(prefix[digits]) {
            next.replaceSubrange(digits, with: String(number + 1))
        }
        insertText("\n" + next, replacementRange: selection)
    }
}

final class EditorScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let text = documentView as? NSTextView else { return }
        let viewport = contentSize
        text.minSize = NSSize(width: 0, height: viewport.height)
        let size = NSSize(width: viewport.width, height: max(text.frame.height, viewport.height))
        if text.frame.size != size { text.setFrameSize(size) }
    }
}

struct SourcePane: NSViewRepresentable {
    @ObservedObject var document: EditorDocument
    var beginComment: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        makeEditor(coordinator: context.coordinator)
    }
    func makeEditor(coordinator: Coordinator) -> NSScrollView {
        let scroll = document.sourceScrollView ?? EditorScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let text = document.sourceTextView ?? MarkdownTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        text.isRichText = false; text.isEditable = true; text.isSelectable = true; text.allowsUndo = true
        text.isFieldEditor = false; text.importsGraphics = false
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false; text.isAutomaticLinkDetectionEnabled = false
        text.isContinuousSpellCheckingEnabled = true; text.usesFindBar = true; text.isIncrementalSearchingEnabled = true
        text.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        text.textColor = .textColor; text.backgroundColor = .textBackgroundColor
        text.textContainerInset = NSSize(width: 16, height: 16)
        text.minSize = NSSize(width: 0, height: scroll.contentSize.height); text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        if text.string != document.text { text.string = document.text }
        text.delegate = coordinator; text.commentAction = beginComment
        text.selectionFinished = { [weak coordinator] in coordinator?.showSelectionComment() }
        document.sourceTextView = text; document.sourceScrollView = scroll
        scroll.documentView = text; coordinator.text = text; coordinator.scroll = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        coordinator.observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak coordinator] _ in
            MainActor.assumeIsolated { coordinator?.scrolled() }
        }
        DispatchQueue.main.async {
            let selected = document.selection
            let length = (document.text as NSString).length
            if selected.location <= length && selected.length <= length - selected.location && selected.length > 0 { text.setSelectedRange(selected) }
            else { text.setSelectedRange(NSRange(location: min(document.layout.cursorLocation, length), length: 0)) }
            coordinator.restoreScroll()
            if let window = text.window, window.attachedSheet == nil { window.makeFirstResponder(text) }
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator; c.parent = self
        guard let text = c.text else { return }
        if text.string != document.text {
            let selection = text.selectedRange(); text.string = document.text
            text.setSelectedRange(NSRange(location: min(selection.location, (document.text as NSString).length), length: 0))
        }
        if let jump = document.jump, c.lastJump != jump.id {
            c.lastJump = jump.id
            let length = (text.string as NSString).length
            let range = NSRange(location: min(jump.range.location, length), length: min(jump.range.length, max(0, length - jump.range.location)))
            text.setSelectedRange(range)
            if jump.restoreScroll { c.restoreScroll() } else { text.scrollRangeToVisible(range) }
        } else if document.layout.mode == .split && abs(c.lastScroll - document.layout.sourceScroll) > 0.005 {
            c.restoreScroll()
        }
        text.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: (text.string as NSString).length))
        for thread in document.comments.threads where !thread.isResolved {
            if let range = thread.locate(in: document.text).range {
                text.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(thread.id == document.selectedThread ? 0.4 : 0.18), forCharacterRange: range.nsRange)
            }
        }
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.text?.selectionPopover.hide()
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SourcePane
        weak var text: MarkdownTextView?
        weak var scroll: NSScrollView?
        var observer: NSObjectProtocol?
        var lastJump: UUID?
        var restoring = false
        var lastScroll = -1.0
        init(_ parent: SourcePane) { self.parent = parent }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
        func textDidChange(_ notification: Notification) { if let text { parent.document.changed(text.string) } }
        func undoManager(for view: NSTextView) -> UndoManager? { parent.document.undoManager }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let text else { return }
            parent.document.selection = text.selectedRange(); parent.document.layout.cursorLocation = text.selectedRange().location
            parent.document.onChange?()
            showSelectionComment()
        }
        func showSelectionComment() {
            guard let text else { return }
            let range = text.selectedRange()
            guard range.length > 0, !text.hasMarkedText(), let window = text.window,
                  window.firstResponder === text else { text.selectionPopover.hide(); return }
            guard NSEvent.pressedMouseButtons == 0 else { return }
            let screenRect = text.firstRect(forCharacterRange: range, actualRange: nil)
            let rect = text.convert(window.convertFromScreen(screenRect), from: nil)
            text.selectionPopover.schedule(in: text, rect: rect) { [weak self] in
                guard let self else { return }
                self.parent.document.selection = range
                self.parent.beginComment()
            }
        }
        func scrolled() {
            guard !restoring, let scroll, let text else { return }
            text.selectionPopover.hide()
            let maxY = max(1, text.bounds.height - scroll.contentView.bounds.height)
            let fraction = max(0, min(1, scroll.contentView.bounds.origin.y / maxY))
            lastScroll = fraction; parent.document.layout.sourceScroll = fraction
            if parent.document.layout.mode == .split { parent.document.layout.renderedScroll = fraction }
            parent.document.onChange?()
        }
        func restoreScroll() {
            guard let text, let scroll else { return }
            restoring = true
            text.layoutManager?.ensureLayout(for: text.textContainer!)
            let fraction = parent.document.layout.sourceScroll
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, text.bounds.height - scroll.contentView.bounds.height) * fraction))
            scroll.reflectScrolledClipView(scroll.contentView); lastScroll = fraction
            restoring = false
        }
    }
}
