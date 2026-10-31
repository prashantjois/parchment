import AppKit
import SwiftUI
import WebKit
import ParchmentCore

@MainActor enum MermaidChecks {
    static func run() -> Never {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        Task { @MainActor in exit(await check()) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { fputs("Mermaid checks timed out.\n", stderr); exit(1) }
        app.run(); exit(1)
    }
    static func check() async -> Int32 {
        var failures: Int32 = 0
        func expect(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL") \(label)")
            if !condition { failures += 1 }
        }
        let source = """
        # Diagrams 🌎

        ```mermaid
        flowchart LR
          A[Write] --> B[Review]
        ```

        ```mermaid
        this is invalid Mermaid
        ```

        ```mermaid
        sequenceDiagram
          Alice->>Bob: Hello
        ```

        ```swift
        let value = 42
        ```
        """
        let document = EditorDocument(url: nil, text: source)
        defer { document.saveTask?.cancel(); document.renderTask?.cancel() }
        let domain = "parchment-mermaid-check-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        let originalAppearance = NSApp.appearance
        defer { defaults.removePersistentDomain(forName: domain); NSApp.appearance = originalAppearance }
        let themes = ThemeLibrary(defaults: defaults)
        themes.appearance = "light"
        let host = NSHostingView(rootView: RenderedPane(document: document, themes: themes, beginComment: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        host.layoutSubtreeIfNeeded()
        guard let web = descendants(host).compactMap({ $0 as? PreviewWebView }).first else {
            print("FAIL preview did not mount"); return 1
        }
        func javascript(_ script: String) async -> Any? {
            await withCheckedContinuation { continuation in
                web.evaluateJavaScript(script) { result, error in
                    if let error { print("JavaScript: \(error.localizedDescription)") }
                    continuation.resume(returning: result)
                }
            }
        }
        func waitForDiagrams(_ count: Int, appearance: String) async -> Bool {
            for _ in 0..<150 {
                if await javascript("document.querySelector('.markdown-doc')?.dataset.appearance === '\(appearance)' && document.querySelectorAll('[data-mermaid-state]').length === \(count)") as? Bool == true { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return false
        }
        expect(await waitForDiagrams(3, appearance: "light"), "diagrams settle in the real preview under its content security policy")
        expect(await javascript("document.querySelectorAll('.mermaid-output svg').length === 2 && document.querySelectorAll('[data-mermaid-state=error]').length === 1") as? Bool == true,
               "flowchart and sequence render even with an invalid block between them")
        expect(await javascript("document.querySelector('.mermaid-error')?.textContent.includes('Mermaid diagram:') && document.querySelector('[data-mermaid-state=error] pre')?.textContent.includes('this is invalid')") as? Bool == true,
               "invalid diagrams keep their source and show a readable error")
        expect(await javascript("document.querySelector('code[data-language=swift]')?.textContent.includes('let value = 42')") as? Bool == true,
               "ordinary code fences remain code")
        let start = (source as NSString).range(of: "```mermaid").location
        expect(await javascript("+document.querySelector('.mermaid-output').dataset.start === \(start) && document.querySelector('.mermaid-output').dataset.precise === '0'") as? Bool == true,
               "diagram selections map to the original fenced block after Unicode text")
        expect(await javascript("(() => { const output = document.querySelector('.mermaid-output'); const range = document.createRange(); range.selectNodeContents(output); getSelection().removeAllRanges(); getSelection().addRange(range); const selected = selectedSource(); getSelection().removeAllRanges(); return selected?.start === +output.dataset.start && selected?.end === +output.dataset.end; })()") as? Bool == true,
               "selecting diagram labels gives comments the complete source block")
        expect(await javascript("mermaid.mermaidAPI.getConfig().securityLevel === 'strict' && mermaid.mermaidAPI.getConfig().htmlLabels === false && document.querySelectorAll('.mermaid-output foreignObject, .mermaid-output image').length === 0") as? Bool == true,
               "diagrams use strict security and SVG text labels")
        let colorScript = "getComputedStyle(document.querySelector('.mermaid-output .node rect')).fill"
        let light = await javascript(colorScript) as? String
        themes.appearance = "dark"
        expect(await waitForDiagrams(3, appearance: "dark"), "appearance changes rerender diagrams")
        let dark = await javascript(colorScript) as? String
        expect(light != nil && dark != nil && light != dark, "light and dark appearances use different diagram colors")
        document.changed("```mermaid\nflowchart TD\n  Changed --> Preview\n```\n")
        expect(await waitForDiagrams(1, appearance: "dark"), "editing the source refreshes diagrams")
        expect(await javascript("document.querySelector('.mermaid-output')?.textContent.includes('Changed') && document.querySelectorAll('.mermaid-error').length === 0") as? Bool == true,
               "the refreshed diagram shows the latest source without stale errors")
        document.changed("""
        ```mermaid
        %%{init: {"securityLevel": "loose", "htmlLabels": true, "themeCSS": "body { display: none }"}}%%
        flowchart LR
          A["<script>window.mermaidUnsafe = true</script>"] --> B[Safe]
        ```
        """)
        expect(await waitForDiagrams(1, appearance: "dark"), "diagram configuration directives finish safely")
        expect(await javascript("!window.mermaidUnsafe && mermaid.mermaidAPI.getConfig().securityLevel === 'strict' && mermaid.mermaidAPI.getConfig().htmlLabels === false && !mermaid.mermaidAPI.getConfig().themeCSS") as? Bool == true,
               "document directives cannot weaken diagram security or inject custom CSS")
        print("Mermaid checks: \(failures) failures")
        return failures
    }
}
