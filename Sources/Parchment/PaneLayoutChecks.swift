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
        for width: CGFloat in [180, 620, 1240, 1328, 1800, 2400] {
            for fraction in [0.0, 0.2, 0.5, 0.8, 1.0] {
                let layout = EditorPaneLayout(viewportWidth: width, mode: .split, splitFraction: fraction)
                valid = valid && layout.rawWidth >= 600 && layout.renderedWidth >= 720 &&
                    layout.width >= width && abs(layout.rawWidth + layout.renderedWidth + 8 - layout.width) < 0.001
            }
        }
        expect(valid, "both split panes retain their minimum widths across narrow windows and extreme divider ratios")
        expect(EditorPaneLayout(viewportWidth: 180, mode: .raw, splitFraction: 0.5).width == 600 &&
               EditorPaneLayout(viewportWidth: 180, mode: .rendered, splitFraction: 0.5).width == 720,
               "single-pane Raw and Rendered modes each retain their own minimum width")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parchment-pane-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = Workspace(recoveryDirectory: directory)
        let document = workspace.active!
        document.changed("# Layout\n\n```swift\nlet text = \"" + String(repeating: "wide ", count: 80) + "\"\n```\n")
        try? await Task.sleep(for: .milliseconds(250))
        document.layout.mode = .split; document.layout.showFiles = false; document.layout.showRight = false
        let host = NSHostingView(rootView: WorkspaceView(workspace: workspace))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 560),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        func settle() async {
            for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(30)) }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        await settle()
        guard let viewport = descendants(host).compactMap({ $0 as? EditorViewportScrollView }).first,
              let source = document.sourceScrollView,
              let rendered = descendants(host).compactMap({ $0 as? PreviewWebView }).first else {
            print("FAIL editor panes did not mount"); return 1
        }
        expect(source.frame.width >= 600 && rendered.frame.width >= 720 &&
               viewport.documentView!.frame.width > viewport.contentSize.width,
               "real Raw and WebKit panes stay readable in a narrow editor with horizontal overflow")
        expect(viewport.horizontalScroller?.isHidden == false && (viewport.horizontalScroller?.knobProportion ?? 1) < 1,
               "the initial narrow layout has a usable horizontal scrollbar before any scroll event")
        expect(viewport.scrollerStyle == .legacy && !viewport.horizontalScroller!.isHidden,
               "overflow keeps a persistent scrollbar even when macOS normally uses overlay scrollbars")
        viewport.contentView.scroll(to: NSPoint(x: 20, y: 0))
        viewport.reflectScrolledClipView(viewport.contentView)
        expect(viewport.contentView.bounds.origin.x > 0, "the editor viewport can scroll sideways")

        let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -40, wheel3: 0)!
        wheel.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        let before = viewport.contentView.bounds.origin.x
        source.documentView!.scrollWheel(with: NSEvent(cgEvent: wheel)!)
        await settle()
        expect(viewport.contentView.bounds.origin.x != before, "horizontal trackpad events over Raw scroll the outer viewport")

        func javascript(_ script: String) async -> Any? {
            await withCheckedContinuation { continuation in
                rendered.evaluateJavaScript(script) { result, _ in continuation.resume(returning: result) }
            }
        }
        for _ in 0..<20 {
            if await javascript("typeof canScrollHorizontallyAtPoint === 'function'") as? Bool == true { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        expect((await javascript("innerWidth") as? Double ?? 0) >= 720,
               "the actual WebKit document retains the Rendered minimum width")
        func webWheel(_ properties: String, selector: String = "h1") async -> Any? {
            await javascript("""
            (() => {
              const target = document.querySelector('\(selector)'), rect = target.getBoundingClientRect();
              return target.dispatchEvent(new WheelEvent('wheel', {bubbles:true, cancelable:true,
                clientX:rect.left + 20, clientY:rect.top + 10, \(properties)}));
            })()
            """)
        }
        viewport.scrollHorizontally(by: -10000)
        let webHandled = await webWheel("deltaX:40")
        await settle()
        expect(webHandled as? Bool == false && viewport.contentView.bounds.origin.x > 0,
               "wheel events inside WebKit's page reach the outer viewport")
        let verticalBefore = viewport.contentView.bounds.origin.x
        let verticalHandled = await webWheel("deltaY:40")
        await settle()
        expect(verticalHandled as? Bool == true && viewport.contentView.bounds.origin.x == verticalBefore,
               "ordinary vertical wheel events stay inside the page")
        let shifted = await webWheel("deltaY:40, shiftKey:true")
        await settle()
        expect(shifted as? Bool == false && viewport.contentView.bounds.origin.x > verticalBefore,
               "Shift-wheel events inside WebKit scroll the outer viewport")
        let ownsScroll = await javascript("""
        (() => {
          const pre = document.querySelector('pre');
          pre.style.width = '100px';
          const rect = pre.getBoundingClientRect(), x = rect.left + 20, y = rect.top + 20;
          pre.scrollLeft = 0;
          const right = canScrollHorizontallyAtPoint(x, y, 40), left = canScrollHorizontallyAtPoint(x, y, -40);
          pre.scrollLeft = pre.scrollWidth;
          const endRight = canScrollHorizontallyAtPoint(x, y, 40), endLeft = canScrollHorizontallyAtPoint(x, y, -40);
          pre.scrollLeft = 0; pre.style.width = '';
          return right && !left && !endRight && endLeft;
        })()
        """)
        expect(ownsScroll as? Bool == true, "Rendered code blocks keep their own horizontal scrolling and hand off at their edges")
        viewport.scrollHorizontally(by: -10000)
        let innerHandled = await webWheel("deltaX:40", selector: "pre")
        await settle()
        expect(innerHandled as? Bool == true && viewport.contentView.bounds.origin.x == 0,
               "the page wheel listener leaves code-block scrolling inside the code block")
        _ = await javascript("document.querySelector('pre').scrollLeft = 100000")
        let edgeHandled = await webWheel("deltaX:40", selector: "pre")
        await settle()
        expect(edgeHandled as? Bool == false && viewport.contentView.bounds.origin.x > 0,
               "the page wheel listener hands off to the viewport at a code-block edge")
        viewport.contentView.scroll(to: NSPoint(x: 20, y: 0))
        let renderedBefore = viewport.contentView.bounds.origin.x
        rendered.scrollWheel(with: NSEvent(cgEvent: wheel)!)
        await settle()
        expect(viewport.contentView.bounds.origin.x != renderedBefore, "horizontal wheel events over Rendered can scroll the outer viewport")

        document.layout.showFiles = true; document.layout.showRight = true
        await settle()
        expect(source.frame.width >= 600 && rendered.frame.width >= 720 && viewport.frame.width < 1240,
               "opening sidebars reduces the viewport without squishing either pane")
        for style: NSScroller.Style in [.legacy, .overlay] {
            viewport.scrollerStyle = style; viewport.tile(); await settle()
            expect(abs(viewport.documentView!.frame.height - viewport.contentSize.height) < 0.01,
                   "\(style == .legacy ? "always-visible" : "overlay") horizontal scrollbar leaves the full editor height usable")
        }
        document.layout.showFiles = false; document.layout.showRight = false
        window.setContentSize(NSSize(width: 1800, height: 500))
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            if abs(viewport.documentView!.frame.width - viewport.contentSize.width) < 0.01 &&
                viewport.contentView.bounds.origin.x == 0 && source.frame.width >= 600 && rendered.frame.width >= 720 { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        expect(abs(viewport.documentView!.frame.width - viewport.contentSize.width) < 0.01 &&
               viewport.contentView.bounds.origin.x == 0 && source.frame.width >= 600 && rendered.frame.width >= 720,
               "widening the window fills the available space and removes horizontal overflow")
        let wideHandled = await webWheel("deltaX:40")
        expect(wideHandled as? Bool == true,
               "the page wheel listener releases horizontal events when there is no outer overflow")
        viewport.scrollerStyle = .legacy
        window.setContentSize(NSSize(width: 900, height: 560))
        document.layout.showFiles = true; document.layout.showRight = true
        await settle()
        expect(viewport.hasHorizontalOverflow && source.frame.width >= 600 && rendered.frame.width >= 720,
               "shrinking the full workspace with both sidebars preserves pane widths and creates overflow")
        expect(viewport.horizontalScroller?.isHidden == false && (viewport.horizontalScroller?.frame.height ?? 0) > 0,
               "overflow provides a visible horizontal scrollbar without a gesture")
        for mode: ViewMode in [.raw, .rendered, .split] {
            document.layout.mode = mode
            await settle()
            guard let current = descendants(host).compactMap({ $0 as? EditorViewportScrollView }).first else {
                expect(false, "viewport survives mode changes"); continue
            }
            let panes = descendants(current)
            let raw = panes.compactMap { $0 as? EditorScrollView }.first
            let preview = panes.compactMap { $0 as? PreviewWebView }.first
            expect((mode == .rendered || (raw?.frame.width ?? 0) >= 600) &&
                   (mode == .raw || (preview?.frame.width ?? 0) >= 720) &&
                   current.hasHorizontalOverflow && current.horizontalScroller?.isHidden == false,
                   "\(mode.rawValue) mode keeps minimum widths and a scrollbar after switching views")
        }
        print("Pane checks: \(failures) failures")
        return failures == 0 ? 0 : 1
    }
}
