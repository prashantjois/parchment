import AppKit
import SwiftUI
import ParchmentCore

struct EditorPaneLayout {
    static let rawMinimum: CGFloat = 600
    static let renderedMinimum: CGFloat = 720
    static let dividerWidth: CGFloat = 8
    let width: CGFloat
    let rawWidth: CGFloat
    let renderedWidth: CGFloat
    let splitLimits: ClosedRange<Double>
    var paneWidth: CGFloat { rawWidth + renderedWidth }

    init(viewportWidth: CGFloat, mode: ViewMode, splitFraction: Double) {
        switch mode {
        case .raw:
            width = max(0, viewportWidth)
            rawWidth = width; renderedWidth = 0; splitLimits = 0...1
        case .rendered:
            width = max(0, viewportWidth)
            rawWidth = 0; renderedWidth = width; splitLimits = 0...1
        case .split:
            let available = max(0, viewportWidth - Self.dividerWidth)
            splitLimits = 0.2...0.8
            let fraction = min(splitLimits.upperBound, max(splitLimits.lowerBound, splitFraction))
            rawWidth = available * fraction
            renderedWidth = available - rawWidth
            width = available + Self.dividerWidth
        }
    }
}

/// The native clip size accounts for both overlay and always-visible scrollbars.
final class EditorViewportScrollView: NSScrollView {
    var minimumContentWidth: CGFloat = 0 { didSet { tile() } }
    var hasHorizontalOverflow: Bool { (documentView?.frame.width ?? 0) > contentSize.width + 0.5 }

    static func containing(_ view: NSView) -> EditorViewportScrollView? {
        var ancestor = view.superview
        while let current = ancestor {
            if let viewport = current as? EditorViewportScrollView { return viewport }
            ancestor = current.superview
        }
        return nil
    }
    static func horizontalDelta(for event: NSEvent) -> CGFloat? {
        let delta: CGFloat
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) { delta = -event.scrollingDeltaX }
        else if event.modifierFlags.contains(.shift) { delta = -event.scrollingDeltaY }
        else { return nil }
        return delta * (event.hasPreciseScrollingDeltas ? 1 : 10)
    }
    func scrollHorizontally(by delta: CGFloat) {
        let maximum = max(0, (documentView?.frame.width ?? 0) - contentSize.width)
        let x = min(maximum, max(0, contentView.bounds.origin.x + delta))
        contentView.scroll(to: NSPoint(x: x, y: 0))
        reflectScrolledClipView(contentView)
    }

    override func tile() {
        super.tile()
        guard let documentView else { return }
        let size = NSSize(width: max(minimumContentWidth, contentSize.width), height: max(0, contentSize.height))
        if documentView.frame.size != size { documentView.setFrameSize(size) }
        reflectScrolledClipView(contentView)
        func updatePreview(_ view: NSView) {
            if let web = view as? PreviewWebView { web.updateHorizontalScrolling(); return }
            view.subviews.forEach(updatePreview)
        }
        updatePreview(documentView)
        let x = min(max(0, contentView.bounds.origin.x), max(0, size.width - contentSize.width))
        if contentView.bounds.origin != NSPoint(x: x, y: 0) {
            contentView.scroll(to: NSPoint(x: x, y: 0))
            reflectScrolledClipView(contentView)
        }
    }
}

struct EditorViewport<Content: View>: NSViewRepresentable {
    var contentWidth: CGFloat
    var content: Content

    init(contentWidth: CGFloat, @ViewBuilder content: () -> Content) {
        self.contentWidth = contentWidth
        self.content = content()
    }
    func makeNSView(context: Context) -> EditorViewportScrollView {
        let scroll = EditorViewportScrollView()
        // Keep the overflow control visible even with the system's overlay preference.
        scroll.scrollerStyle = .legacy
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = false; scroll.drawsBackground = true
        scroll.borderType = .noBorder
        scroll.horizontalScrollElasticity = .none; scroll.verticalScrollElasticity = .none
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        scroll.documentView = host
        scroll.minimumContentWidth = contentWidth
        return scroll
    }
    func updateNSView(_ scroll: EditorViewportScrollView, context: Context) {
        (scroll.documentView as? NSHostingView<Content>)?.rootView = content
        scroll.minimumContentWidth = contentWidth
    }
}
