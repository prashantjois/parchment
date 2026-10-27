import AppKit
import WebKit
import ParchmentCore

/// A headless WebKit integration check. No editor window or session is opened.
@MainActor final class ThemeChecks: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static var active: ThemeChecks?
    let library = ThemeLibrary()
    var index = 0
    var failures = 0
    var appearance = "light"
    var web: WKWebView!
    var messages: [[String: Any]] = []
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let runner = ThemeChecks(); active = runner
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(runner, name: "parchment")
        runner.web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        runner.web.navigationDelegate = runner
        DispatchQueue.main.async { runner.next() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 55) { fputs("Theme checks timed out.\n", stderr); exit(1) }
        app.run()
        exit(1)
    }
    var builtins: [EditorTheme] { library.items.filter { !$0.custom } }
    func next() {
        guard index < builtins.count else {
            print("\(builtins.count * 2) WebKit theme/appearance checks, \(failures) failures")
            exit(failures == 0 ? 0 : 1)
        }
        let theme = builtins[index]
        ThemeCSSValidator.validate(theme.css) { [self] result in
            if case .failure(let error) = result { failures += 1; print("FAIL \(theme.name) validation: \(error.localizedDescription)") }
            let source = "# Heading\n\nA **bold** thought.\n\n## Two\n\n### Three\n\n#### Four\n\n##### Five\n\n###### Six\n\n| A | B |\n| --- | --- |\n| C | D |\n\n```swift\nlet answer = 42\n```"
            let rendered = MarkdownRenderer.render(source + "\n\n![One](http://127.0.0.1:1/one.png)\n\n![Two](http://127.0.0.1:1/two.png)")
            let css = Data((library.baseCSS + "\n" + theme.css + "\n@layer parchment-user { .markdown-doc { --pt-syntax-keyword: #010203; } }").utf8).base64EncodedString()
            let html = """
            <html><head><meta charset="utf-8"></head><body>
            <article class="markdown-doc" data-appearance="\(appearance)">\(rendered.html)</article>
            <script>const style=document.createElement('style');style.textContent=new TextDecoder().decode(Uint8Array.from(atob('\(css)'),c=>c.charCodeAt(0)));document.head.appendChild(style);
            \(RenderedPane.script)
            </script></body></html>
            """
            messages = []; web.loadHTMLString(html, baseURL: nil)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let script = #"""
        (() => {
          const root = document.querySelector('.markdown-doc'), style = getComputedStyle(root);
          const errors = [];
          if (style.backgroundColor === 'rgba(0, 0, 0, 0)') errors.push('Missing background');
          if (parseFloat(style.fontSize) < 14) errors.push('Missing font size');
          if (style.color === style.backgroundColor) errors.push('Invisible body text');
          if (parseFloat(style.paddingLeft) !== 16 || parseFloat(style.paddingRight) !== 16) errors.push('Rendered content must use the full width with 16px margins');
          for (let i=1;i<=6;i++) {
            const heading = getComputedStyle(document.querySelector('h'+i));
            if (parseFloat(heading.fontSize) < parseFloat(style.fontSize)) errors.push('Invalid heading size '+i);
          }
          if (typeof setComments !== 'function' || typeof jumpToSource !== 'function') errors.push('Preview bridge failed to load');
          else {
            const code = document.querySelector('pre code'), keyword = code.querySelector('.token.keyword'), number = code.querySelector('.token.number');
            if (!keyword || !number || code.textContent !== 'let answer = 42\n') errors.push('Code tokenization changed or missed source text');
            else {
              if (getComputedStyle(keyword).color !== 'rgb(1, 2, 3)') errors.push('Theme syntax color override was ignored');
              setComments([{id:'code', start:+number.dataset.start, end:+number.dataset.end, active:true}]);
              if ([...CSS.highlights.get('comments')][0]?.toString() !== '42') errors.push('Highlighted code comment anchor is incorrect');
              const codeRange = document.createRange();
              codeRange.setStart(keyword.firstChild, 0); codeRange.setEnd(number.firstChild, number.textContent.length);
              getSelection().removeAllRanges(); getSelection().addRange(codeRange);
              const mappedCode = selectedSource();
              if (mappedCode?.start !== +keyword.dataset.start || mappedCode?.end !== +number.dataset.end) errors.push('Selection across syntax tokens lost source offsets');
            }
            const images = [...document.querySelectorAll('[data-remote-src]')];
            if (images.length !== 2 || document.querySelector('img')) errors.push('Remote images loaded before permission');
            setRemoteImages({enabled:false, sources:[images[0].dataset.remoteSrc]});
            if (!images[0].querySelector('img') || images[1].querySelector('img')) errors.push('Individual image permission was not isolated');
            if (images[0].querySelector('img')?.referrerPolicy !== 'no-referrer') errors.push('Remote image leaked referrer');
            images[1].dispatchEvent(new MouseEvent('contextmenu', {bubbles:true, cancelable:true, clientX:20, clientY:30}));
            setRemoteImages({enabled:true, sources:[]});
            if (document.querySelectorAll('[data-remote-src] img').length !== 2) errors.push('Automatic image loading missed images');
            setRemoteImages({enabled:false, sources:[]});
            if (document.querySelector('[data-remote-src] img')) errors.push('Disabling automatic image loading kept images');
            const leaf = [...document.querySelectorAll('[data-leaf]')].find(e=>e.textContent==='bold');
            setComments([{id:'test',start:+leaf.dataset.start,end:+leaf.dataset.end,active:true}]);
            if (!CSS.highlights.get('comments')?.size) errors.push('Comment highlights missing');
            const selection = getSelection(), range = document.createRange();range.selectNodeContents(leaf);selection.removeAllRanges();selection.addRange(range);
            document.dispatchEvent(new Event('selectionchange'));
            const mapped = selectedSource();
            if (!mapped || mapped.width <= 0 || mapped.height <= 0) errors.push('Selection bubble anchor is missing');
            commentSelection();
          }
          return {errors, fontSize:style.fontSize, background:style.backgroundColor};
        })()
        """#
        web.evaluateJavaScript(script) { [self] value, error in
            if let error { failures += 1; print("FAIL \(builtins[index].name) \(appearance): \(error)") }
            else if let result = value as? [String: Any], let errors = result["errors"] as? [String], errors.isEmpty {
                print("PASS \(builtins[index].name) \(appearance): \(result["fontSize"] ?? "") / \(result["background"] ?? "")")
            } else { failures += 1; print("FAIL \(builtins[index].name) \(appearance): \(value ?? "No result")") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [self] in
                if !messages.contains(where: { $0["type"] as? String == "remote-image-menu" && $0["source"] as? String == "http://127.0.0.1:1/two.png" }) {
                    failures += 1; print("FAIL blocked image did not offer its context menu")
                }
                if !messages.contains(where: { $0["type"] as? String == "selection" && $0["start"] as? Int == 15 && $0["end"] as? Int == 19 }) {
                    failures += 1; print("FAIL rendered selection did not map to the bold source range: \(messages)")
                }
                if !messages.contains(where: { $0["type"] as? String == "comment" && $0["start"] as? Int == 15 && $0["end"] as? Int == 19 }) {
                    failures += 1; print("FAIL context-menu comment did not preserve the selected source range")
                }
                if appearance == "light" { appearance = "dark" } else { appearance = "light"; index += 1 }
                next()
            }
        }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let value = message.body as? [String: Any] { messages.append(value) }
    }
}
