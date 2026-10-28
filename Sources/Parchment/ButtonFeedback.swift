import AppKit
import SwiftUI

/// A native tooltip and hover overlay that leaves button actions and focus intact.
struct ButtonFeedback: NSViewRepresentable {
    var tooltip: String
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> ButtonFeedbackView { ButtonFeedbackView() }
    func updateNSView(_ view: ButtonFeedbackView, context: Context) {
        view.toolTip = tooltip
        view.enabled = isEnabled
    }
}

final class ButtonFeedbackView: NSView {
    var enabled = true { didSet { updateHighlight() } }
    private var hovered = false
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 5
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateHighlight() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateHighlight() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hovered = false; updateHighlight() }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHighlight()
    }
    private func updateHighlight() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let visible = enabled && hovered
            let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            layer?.backgroundColor = visible ? NSColor.controlAccentColor.withAlphaComponent(contrast ? 0.22 : 0.12).cgColor : nil
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(contrast ? 0.5 : 0.18).cgColor
            layer?.borderWidth = visible ? 1 : 0
        }
    }
}

extension View {
    func buttonFeedback(_ tooltip: String) -> some View {
        overlay(ButtonFeedback(tooltip: tooltip).accessibilityHidden(true))
            .help(tooltip)
    }
}
