import AppKit
import SwiftUI
import ParchmentCore

@MainActor enum PaneLayoutChecks {
    static func run() -> Never {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        Task { @MainActor in exit(await check()) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) { fputs("Pane checks timed out.\n", stderr); exit(1) }
        app.run(); exit(1)
    }
    static func check() async -> Int32 {
        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL") \(label)")
            if !condition { failures += 1 }
        }
        var valid = true
        for width: CGFloat in [180, 620, 1240, 1800, 2400] {
            for fraction in [0.0, 0.2, 0.5, 0.8, 1.0] {
                let layout = EditorPaneLayout(viewportWidth: width, mode: .split, splitFraction: fraction)
                valid = valid && layout.rawWidth > 0 && layout.renderedWidth > 0 &&
                    abs(layout.width - width) < 0.001 && abs(layout.rawWidth + layout.renderedWidth + 8 - width) < 0.001
            }
        }
        expect(valid, "split view keeps both pane viewports inside the window across divider ratios")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parchment-pane-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = Workspace(recoveryDirectory: directory)
        let document = workspace.active!
        let longWord = String(repeating: "UnbrokenColumnValue", count: 12)
        document.changed("# Layout\n\n```swift\nlet text = \"" + String(repeating: "wide ", count: 80) +
                         "\"\n```\n\n| First | Second |\n| --- | --- |\n| " + longWord + " | " + longWord + " |\n")
        try? await Task.sleep(for: .milliseconds(250))
        document.layout.mode = .split; document.layout.showFiles = false; document.layout.showRight = false
        let host = NSHostingView(rootView: WorkspaceView(workspace: workspace))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 560),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        func settle() async {
            for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(30)) }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func renderedViewport() -> EditorViewportScrollView? { descendants(host).compactMap { $0 as? EditorViewportScrollView }.first }
        func visibleBar(_ scroll: NSScrollView) -> Bool {
            guard let bar = scroll.horizontalScroller, !bar.isHiddenOrHasHiddenAncestor,
                  bar.alphaValue > 0.9, bar.frame.height > 10 else { return false }
            let rect = bar.convert(bar.bounds, to: host), visible = rect.intersection(host.visibleRect)
            let point = bar.convert(NSPoint(x: bar.bounds.midX, y: bar.bounds.midY), to: host.superview)
            let hit = host.hitTest(point)
            return visible.width >= rect.width - 1 && visible.height >= rect.height - 1 &&
                (hit === bar || hit?.isDescendant(of: bar) == true)
        }
        await settle()
        guard let viewport = renderedViewport(), let source = document.sourceScrollView as? EditorScrollView,
              let text = document.sourceTextView,
              let rendered = descendants(viewport).compactMap({ $0 as? PreviewWebView }).first else {
            print("FAIL editor panes did not mount"); return 1
        }
        expect(visibleBar(source) && visibleBar(viewport),
               "Raw and Rendered each have an on-screen horizontal scrollbar that receives pointer events")
        let beforeComposition = document.text
        text.setSelectedRange(NSRange(location: 0, length: 0))
        text.setMarkedText("入力", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
        document.saveMessage = "Composition refresh check"
        await settle()
        expect(text.hasMarkedText() && text.string.hasPrefix("入力") && document.text == beforeComposition,
               "a SwiftUI refresh preserves marked text without publishing an unfinished input composition")
        text.insertText("Committed ", replacementRange: text.markedRange())
        await settle()
        expect(!text.hasMarkedText() && document.text == text.string && document.text.hasPrefix("Committed "),
               "committing composed text updates the document without replacing native input")
        document.changed(beforeComposition)
        await settle()
        let rawBar = source.horizontalScroller!.convert(source.horizontalScroller!.bounds, to: host)
        let renderedBar = viewport.horizontalScroller!.convert(viewport.horizontalScroller!.bounds, to: host)
        expect(rawBar.maxX < renderedBar.minX && abs(rawBar.minY - renderedBar.minY) < 1,
               "the independent scrollbars sit side by side at the bottom of their panes")
        expect(text.frame.width > source.contentSize.width && text.frame.width >= 600 && rendered.frame.width >= 720,
               "long Raw lines and the Rendered minimum width create real horizontal overflow")
        let longLine = (text.string as NSString).range(of: "let text = \"" + String(repeating: "wide ", count: 80) + "\"")
        let glyphs = text.layoutManager!.glyphRange(forCharacterRange: longLine, actualCharacterRange: nil)
        var fragments = 0
        text.layoutManager!.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, _, _ in fragments += 1 }
        expect(fragments == 1, "Raw keeps a long source line on one line instead of wrapping it to hide overflow")
        let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -40, wheel3: 0)!
        wheel.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        text.scrollWheel(with: NSEvent(cgEvent: wheel)!)
        await settle()
        expect(source.contentView.bounds.origin.x > 0 && viewport.contentView.bounds.origin.x == 0,
               "wheel events over Raw scroll Raw without moving Rendered")
        func javascript(_ script: String) async -> Any? {
            await withCheckedContinuation { continuation in
                rendered.evaluateJavaScript(script) { result, _ in continuation.resume(returning: result) }
            }
        }
        for _ in 0..<20 {
            if await javascript("window.parchmentOuterHorizontalScrolling === true") as? Bool == true { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        func webWheel(_ properties: String, selector: String = "h1") async -> Any? {
            await javascript("""
            (() => {
              const target = document.querySelector('\(selector)'), rect = target.getBoundingClientRect();
              return target.dispatchEvent(new WheelEvent('wheel', {bubbles:true, cancelable:true,
                clientX:rect.left + 20, clientY:rect.top + 10, \(properties)}));
            })()
            """)
        }
        let sourceX = source.contentView.bounds.origin.x
        let webHandled = await webWheel("deltaX:40")
        await settle()
        expect(webHandled as? Bool == false && viewport.contentView.bounds.origin.x > 0 && source.contentView.bounds.origin.x == sourceX,
               "wheel events inside WebKit scroll Rendered without moving Raw")
        let renderedX = viewport.contentView.bounds.origin.x
        let verticalHandled = await webWheel("deltaY:40")
        await settle()
        expect(verticalHandled as? Bool == true && viewport.contentView.bounds.origin.x == renderedX,
               "vertical page scrolling preserves the horizontal offset")
        let shifted = await webWheel("deltaY:40, shiftKey:true")
        await settle()
        expect(shifted as? Bool == false && viewport.contentView.bounds.origin.x > renderedX,
               "Shift-wheel events inside WebKit move the Rendered viewport")
        expect((await javascript("document.querySelector('.table-scroll').scrollWidth > document.querySelector('.table-scroll').clientWidth") as? Bool) == true,
               "wide tables overflow instead of breaking column values to fit")
        let tableChrome = await javascript("""
        (() => {
          const table = document.querySelector('.table-scroll');
          return getComputedStyle(table, '::-webkit-scrollbar').height === '12px' &&
                 getComputedStyle(table, '::-webkit-scrollbar-thumb').backgroundColor !== 'rgba(0, 0, 0, 0)';
        })()
        """)
        expect(tableChrome as? Bool == true, "overflowing Rendered blocks have an explicit visible scrollbar track and thumb")
        for selector in ["pre", ".table-scroll"] {
            viewport.scrollHorizontally(by: -10000)
            _ = await javascript("document.querySelector('\(selector)').scrollLeft = 0")
            let inner = await webWheel("deltaX:40", selector: selector)
            await settle()
            expect(inner as? Bool == true && viewport.contentView.bounds.origin.x == 0,
                   "\(selector) keeps its own horizontal wheel events before its edge")
            _ = await javascript("document.querySelector('\(selector)').scrollLeft = 100000")
            let edge = await webWheel("deltaX:40", selector: selector)
            await settle()
            expect(edge as? Bool == false && viewport.contentView.bounds.origin.x > 0,
                   "\(selector) hands wheel events to Rendered at its edge")
        }
        func dragKnob(_ scroll: NSScrollView) -> Bool {
            guard let bar = scroll.horizontalScroller, bar.isEnabled else { return false }
            let knob = bar.rect(for: .knob)
            let start = bar.convert(NSPoint(x: knob.midX, y: knob.midY), to: nil)
            let end = NSPoint(x: start.x + 25, y: start.y)
            func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            let before = scroll.contentView.bounds.origin.x
            NSApp.postEvent(event(.leftMouseDragged, end), atStart: false)
            NSApp.postEvent(event(.leftMouseUp, end), atStart: false)
            bar.mouseDown(with: event(.leftMouseDown, start))
            return scroll.contentView.bounds.origin.x != before
        }
        expect(dragKnob(source), "dragging the Raw scrollbar thumb moves the actual text viewport")
        expect(dragKnob(viewport), "dragging the Rendered scrollbar thumb moves the actual preview viewport")
        let horizontalBeforeSync = source.contentView.bounds.origin.x
        document.changed(document.text + String(repeating: "\nShort line", count: 80))
        await settle()
        document.layout.sourceScroll = 0.5
        document.layout.renderedScroll = 0.5
        await settle()
        expect(source.contentView.bounds.origin.y > 0 && source.contentView.bounds.origin.x == horizontalBeforeSync,
               "synchronized vertical scrolling does not reset Raw horizontal scrolling")
        let sourceFrame = source.convert(source.bounds, to: host)
        let previewFrame = viewport.convert(viewport.bounds, to: host)
        let beforeTyping = document.text
        let insertion = text.characterIndexForInsertion(at: NSPoint(x: source.contentView.bounds.minX + 30,
                                                                    y: source.contentView.bounds.minY + 80))
        text.setSelectedRange(NSRange(location: insertion, length: 0))
        var stableEditing = true
        for _ in 0..<12 {
            let location = text.selectedRange().location
            text.insertText("a", replacementRange: text.selectedRange())
            await settle()
            stableEditing = stableEditing && text.string == document.text &&
                text.selectedRange().location == location + 1 &&
                source.convert(source.bounds, to: host) == sourceFrame &&
                viewport.convert(viewport.bounds, to: host) == previewFrame &&
                renderedViewport() === viewport &&
                document.layout.sourceScroll > 0.1 && document.layout.renderedScroll > 0.1
        }
        expect(stableEditing, "repeated native typing and preview refresh preserve text, selection, pane frames, and scroll position")
        document.changed(beforeTyping)
        await settle()
        document.layout.showFiles = true; document.layout.showRight = true
        window.setContentSize(NSSize(width: 900, height: 560))
        await settle()
        expect(visibleBar(source) && visibleBar(viewport) && text.frame.width >= 600 && rendered.frame.width >= 720,
               "both scrollbars stay visible and reachable when sidebars narrow the editor")
        for fraction in [0.2, 0.8] {
            document.layout.splitFraction = fraction
            await settle()
            expect(visibleBar(source) && visibleBar(viewport) && text.frame.width >= 600 && rendered.frame.width >= 720,
                   "both controls stay inside their panes at split fraction \(fraction)")
        }
        for mode: ViewMode in [.raw, .rendered, .split] {
            document.layout.mode = mode
            await settle()
            expect((mode == .rendered || visibleBar(source)) && (mode == .raw || renderedViewport().map(visibleBar) == true),
                   "\(mode.rawValue) mode retains the appropriate horizontal scrollbars")
        }
        document.layout.showFiles = false; document.layout.showRight = false; document.layout.mode = .raw
        document.changed("# Short\n")
        window.setContentSize(NSSize(width: 1800, height: 560))
        await settle()
        expect(visibleBar(source) && abs(text.frame.width - source.contentSize.width) < 1 && source.contentView.bounds.origin.x == 0,
               "removing a long line shrinks Raw content and clears overflow while keeping the scrollbar visible")
        document.undoManager.removeAllActions(); document.undoManager.groupsByEvent = false
        document.undoManager.beginUndoGrouping()
        text.insertText(String(repeating: "x", count: 400), replacementRange: NSRange(location: 0, length: 0))
        document.undoManager.endUndoGrouping()
        await settle()
        expect(text.frame.width > source.contentSize.width && source.horizontalScroller?.isEnabled == true,
               "a native insertion of a long line immediately enables Raw horizontal scrolling")
        document.undoManager.undo()
        await settle()
        expect(text.string == "# Short\n" && abs(text.frame.width - source.contentSize.width) < 1,
               "native undo removes the long-line overflow without leaving a stale canvas")
        document.layout.mode = .rendered
        await settle()
        if let current = renderedViewport() {
            expect(visibleBar(current) && !current.hasHorizontalOverflow && current.contentView.bounds.origin.x == 0,
                   "a wide Rendered pane keeps its scrollbar visible even when the content fits")
        } else { expect(false, "Rendered viewport remounts") }
        if let path = ProcessInfo.processInfo.environment["PARCHMENT_PANE_SNAPSHOT"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        print("Pane checks: \(failures) failures")
        return failures == 0 ? 0 : 1
    }
}
