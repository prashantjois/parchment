import AppKit
import SwiftUI
import WebKit
import ParchmentCore

final class PreviewWebView: WKWebView, NSMenuItemValidation {
    var commentAction: (() -> Void)?
    var hasCommentSelection = false
    var remoteImageAction: ((String, Bool) -> Void)?
    private var remoteImageSource = ""
    private var outerHorizontalOverflow: Bool?
    let selectionPopover = SelectionCommentPopover()
    func updateHorizontalScrolling(force: Bool = false) {
        let overflow = EditorViewportScrollView.containing(self)?.hasHorizontalOverflow == true
        guard force || outerHorizontalOverflow != overflow else { return }
        outerHorizontalOverflow = overflow
        evaluateJavaScript("window.parchmentOuterHorizontalScrolling = \(overflow)", completionHandler: nil)
    }
    override func scrollWheel(with event: NSEvent) {
        guard let viewport = EditorViewportScrollView.containing(self), viewport.hasHorizontalOverflow,
              let delta = EditorViewportScrollView.horizontalDelta(for: event) else {
            super.scrollWheel(with: event); return
        }
        let point = convert(event.locationInWindow, from: nil)
        let y = isFlipped ? point.y : bounds.height - point.y
        // Let code blocks and tables consume their own horizontal scrolling first.
        evaluateJavaScript("canScrollHorizontallyAtPoint(\(point.x), \(y), \(delta))") { [weak self, weak viewport] result, error in
            guard let self else { return }
            if error != nil || result as? Bool == true || viewport?.hasHorizontalOverflow != true {
                self.scrollWebContent(with: event)
            } else { viewport?.scrollHorizontally(by: delta) }
        }
    }
    private func scrollWebContent(with event: NSEvent) { super.scrollWheel(with: event) }
    func showRemoteImageMenu(source: String, at point: NSPoint) {
        remoteImageSource = source
        let menu = NSMenu()
        for (title, action) in [("Load This Image", #selector(loadRemoteImage)), ("Automatically Load All Remote Images", #selector(loadAllRemoteImages))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: point, in: self)
    }
    @objc func loadRemoteImage() { remoteImageAction?(remoteImageSource, false) }
    @objc func loadAllRemoteImages() { remoteImageAction?(remoteImageSource, true) }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        selectionPopover.hide()
        guard commentAction != nil else { return menu }
        menu.addItem(.separator())
        let item = NSMenuItem(title: "Add Comment to Selection", action: #selector(addComment), keyEquivalent: "")
        item.target = self; menu.addItem(item); return menu
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(addComment) ? hasCommentSelection : true
    }
    @objc func addComment() { selectionPopover.hide(); commentAction?() }
}

struct RenderedPane: NSViewRepresentable {
    @ObservedObject var document: EditorDocument
    @ObservedObject var themes: ThemeLibrary
    var minimumContentWidth: CGFloat? = nil
    var previewCSS: String? = nil
    var allowsComments = true
    var openDocument: ((URL) -> Void)? = nil
    var openExternal: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var beginComment: () -> Void
    @AppStorage("loadRemoteImages") private var loadRemoteImages = false
    @Environment(\.colorScheme) private var colorScheme
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSView {
        let config = WKWebViewConfiguration()
        MermaidPreview.install(in: config.userContentController)
        config.userContentController.add(context.coordinator, name: "parchment")
        let web = PreviewWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.remoteImageAction = { [weak coordinator = context.coordinator] source, all in
            guard let coordinator else { return }
            if all { coordinator.parent.loadRemoteImages = true }
            else { coordinator.parent.document.loadedRemoteImages.insert(source) }
            coordinator.updateState()
        }
        if allowsComments { web.commentAction = { [weak coordinator = context.coordinator] in coordinator?.requestComment() } }
        web.setValue(false, forKey: "drawsBackground")
        context.coordinator.web = web
        guard let minimumContentWidth else { return web }
        let scroll = EditorViewportScrollView()
        scroll.scrollerStyle = .legacy
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = false; scroll.drawsBackground = true; scroll.borderType = .noBorder
        scroll.horizontalScrollElasticity = .none; scroll.verticalScrollElasticity = .none
        scroll.documentView = web; scroll.minimumContentWidth = minimumContentWidth
        return scroll
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        guard let web = coordinator.web else { return }
        web.configuration.userContentController.removeScriptMessageHandler(forName: "parchment")
        web.selectionPopover.hide()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        guard minimumContentWidth != nil else { return nil }
        return proposal.replacingUnspecifiedDimensions(by: CGSize(width: EditorPaneLayout.renderedMinimum, height: 480))
    }
    func updateNSView(_ view: NSView, context: Context) {
        guard let web = context.coordinator.web else { return }
        if let scroll = view as? EditorViewportScrollView { scroll.minimumContentWidth = minimumContentWidth ?? 0 }
        let c = context.coordinator; c.parent = self
        let dark = themes.appearance == "dark" || (themes.appearance == "system" && colorScheme == .dark)
        let css = themes.css(dark: dark, preview: previewCSS)
        let key = sourceHash(document.rendered.html + css + String(dark))
        if c.lastPage != key {
            web.selectionPopover.hide(); web.hasCommentSelection = false
            c.lastPage = key; c.ready = false
            c.loadedSourceHash = sourceHash(document.renderedSource)
            let nonce = UUID().uuidString
            let encodedCSS = Data(css.utf8).base64EncodedString()
            let html = """
            <!doctype html><html><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: https: http:; style-src 'unsafe-inline'; script-src 'nonce-\(nonce)';">
            <meta name="referrer" content="no-referrer">
            <style>html,body{margin:0;min-height:100%;}.markdown-doc{min-height:100vh;}::highlight(comments){background:#e5b54b55;}::highlight(active-comment){background:#e5b54b99;}::highlight(search){background:#ffb34066;}::highlight(active-search){background:#ff9c20bb;}</style>
            </head><body><article class="markdown-doc" data-appearance="\(dark ? "dark" : "light")">\(document.rendered.html)</article>
            <script nonce="\(nonce)">
            const theme = document.createElement('style');
            theme.textContent = new TextDecoder().decode(Uint8Array.from(atob('\(encodedCSS)'), c => c.charCodeAt(0)));
            document.head.appendChild(theme);
            \(Self.script)
            \(MermaidPreview.script)
            </script></body></html>
            """
            web.loadHTMLString(html, baseURL: document.url?.deletingLastPathComponent())
        } else if c.ready { c.updateState() }
    }
    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: RenderedPane
        weak var web: PreviewWebView?
        var lastPage = ""
        var loadedSourceHash = ""
        var ready = false
        var lastJump: UUID?
        var lastScroll = -1.0
        var lastHighlights = ""
        var lastSearchHighlights = ""
        var lastImagePolicy = ""
        init(_ parent: RenderedPane) { self.parent = parent }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Restore scroll and comment state after asynchronous diagrams settle.
            webView.evaluateJavaScript("void renderMermaidDiagrams().finally(() => send({type:'diagrams-ready'}))", completionHandler: nil)
        }
        func previewReady() {
            ready = true; lastScroll = -1; lastHighlights = ""; lastSearchHighlights = ""; lastImagePolicy = ""; updateState()
            web?.updateHorizontalScrolling(force: true)
        }
        func updateState() {
            guard let web else { return }
            let doc = parent.document
            let policy = String(data: try! JSONSerialization.data(withJSONObject: ["enabled": parent.loadRemoteImages, "sources": doc.loadedRemoteImages.sorted()]), encoding: .utf8)!
            if policy != lastImagePolicy {
                lastImagePolicy = policy
                web.evaluateJavaScript("setRemoteImages(\(policy))", completionHandler: nil)
            }
            let ranges = doc.comments.threads.filter { !$0.isResolved }.compactMap { thread -> [String: Any]? in
                guard let range = thread.locate(in: doc.text).range else { return nil }
                return ["id": thread.id.uuidString, "start": range.location, "end": range.location + range.length, "active": thread.id == doc.selectedThread]
            }
            let json = String(data: try! JSONSerialization.data(withJSONObject: ranges), encoding: .utf8)!
            if json != lastHighlights { lastHighlights = json; web.evaluateJavaScript("setComments(\(json))", completionHandler: nil) }
            let searchRanges: [[String: Any]] = sourceHash(doc.text) == loadedSourceHash ? doc.searchRanges.map {
                ["start": $0.location, "end": NSMaxRange($0), "active": $0 == doc.activeSearchRange]
            } : []
            let searchJSON = String(data: try! JSONSerialization.data(withJSONObject: searchRanges), encoding: .utf8)!
            if searchJSON != lastSearchHighlights {
                lastSearchHighlights = searchJSON
                web.evaluateJavaScript("setSearchHighlights(\(searchJSON))", completionHandler: nil)
            }
            if let jump = doc.jump, lastJump != jump.id, sourceHash(doc.text) == loadedSourceHash {
                lastJump = jump.id
                if jump.restoreScroll {
                    lastScroll = doc.layout.renderedScroll
                    web.evaluateJavaScript("setScroll(\(lastScroll))", completionHandler: nil)
                } else if jump.range == doc.activeSearchRange {
                    web.evaluateJavaScript("jumpToSearch(\(jump.range.location))", completionHandler: nil)
                } else { web.evaluateJavaScript("jumpToSource(\(jump.range.location))", completionHandler: nil) }
            } else if abs(lastScroll - doc.layout.renderedScroll) > 0.005 {
                lastScroll = doc.layout.renderedScroll
                web.evaluateJavaScript("setScroll(\(lastScroll))", completionHandler: nil)
            }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = message.body as? [String: Any], let type = value["type"] as? String else { return }
            let doc = parent.document
            if type == "diagrams-ready" {
                previewReady()
            } else if ["selection", "comment"].contains(type), let start = value["start"] as? Int, let end = value["end"] as? Int {
                guard sourceHash(doc.text) == loadedSourceHash else { return }
                let range = TextSpan(location: start, length: end - start)
                guard range.isValid(in: doc.text) else { return }
                doc.selection = range.nsRange
                guard parent.allowsComments else { return }
                web?.hasCommentSelection = true
                if type == "comment" { web?.selectionPopover.hide(); parent.beginComment() }
                else if let web, let x = value["x"] as? Double, let y = value["y"] as? Double, let width = value["width"] as? Double, let height = value["height"] as? Double {
                    let rect = NSRect(x: x, y: web.isFlipped ? y : web.bounds.height - y - height, width: max(1, width), height: max(1, height))
                    let revision = loadedSourceHash
                    web.selectionPopover.schedule(in: web, rect: rect) { [weak self] in
                        guard let self, sourceHash(self.parent.document.text) == revision else { return }
                        self.parent.document.selection = range.nsRange; self.parent.beginComment()
                    }
                }
            } else if type == "selection-cleared" {
                web?.hasCommentSelection = false; web?.selectionPopover.hide()
                if let web, let responder = web.window?.firstResponder as? NSView, responder.isDescendant(of: web) { doc.selection = NSRange(location: 0, length: 0) }
            } else if type == "scroll", let fraction = value["fraction"] as? Double {
                web?.selectionPopover.hide()
                lastScroll = fraction; doc.layout.renderedScroll = fraction
                if doc.layout.mode == .split { doc.layout.sourceScroll = fraction }
                doc.onChange?()
            } else if type == "horizontal-scroll", let delta = value["delta"] as? Double,
                      delta.isFinite, let web,
                      let viewport = EditorViewportScrollView.containing(web), viewport.hasHorizontalOverflow {
                web.selectionPopover.hide()
                viewport.scrollHorizontally(by: delta)
            } else if type == "remote-image-menu", let source = value["source"] as? String,
                      let x = value["x"] as? Double, let y = value["y"] as? Double, let web {
                web.selectionPopover.hide()
                web.showRemoteImageMenu(source: source, at: NSPoint(x: x, y: web.isFlipped ? y : web.bounds.height - y))
            } else if type == "fragment", let id = value["id"] as? String,
                      let heading = doc.rendered.headings.first(where: { $0.id == id }) {
                doc.reveal(NSRange(location: heading.location, length: 0))
            } else if type == "thread", let id = value["id"] as? String, let thread = doc.comments.threads.first(where: { $0.id.uuidString == id }) {
                doc.selectThread(thread)
            }
        }
        func requestComment() { web?.evaluateJavaScript("commentSelection()", completionHandler: nil) }
        func openLink(_ url: URL) {
            let sameFile = url.isFileURL && URL(fileURLWithPath: url.path).standardizedFileURL == parent.document.url?.standardizedFileURL
            if let fragment = url.fragment, !fragment.isEmpty, url.scheme == "about" || sameFile {
                let decoded = fragment.removingPercentEncoding ?? fragment
                if let heading = parent.document.rendered.headings.first(where: { $0.id == decoded }) {
                    parent.document.reveal(NSRange(location: heading.location, length: 0))
                }
            } else if url.isFileURL && [nil, "", "localhost"].contains(url.host) || url.scheme?.lowercased() == "parchment" {
                parent.openDocument?(url)
            } else if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                parent.openExternal(url)
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated, let url = action.request.url else { decisionHandler(.allow); return }
            openLink(url)
            decisionHandler(.cancel)
        }
    }
    static let script = #"""
    const send = value => window.webkit.messageHandlers.parchment.postMessage(value);
    function canScrollHorizontallyAtPoint(x, y, delta) {
      for (let node = document.elementFromPoint(x, y); node; node = node.parentElement) {
        const overflow = getComputedStyle(node).overflowX;
        if (!['auto', 'scroll', 'overlay'].includes(overflow) || node.scrollWidth <= node.clientWidth + 1) continue;
        const maximum = node.scrollWidth - node.clientWidth;
        if ((delta > 0 && node.scrollLeft < maximum - 1) || (delta < 0 && node.scrollLeft > 1)) return true;
      }
      return false;
    }
    // WKWebView's internal content view can consume wheel events before AppKit's override.
    document.addEventListener('wheel', event => {
      if (!window.parchmentOuterHorizontalScrolling) return;
      let delta;
      if (Math.abs(event.deltaX) > Math.abs(event.deltaY)) delta = event.deltaX;
      else if (event.shiftKey) delta = event.deltaY;
      else return;
      if (!delta || canScrollHorizontallyAtPoint(event.clientX, event.clientY, delta)) return;
      event.preventDefault();
      const scale = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? innerWidth : 1;
      send({type:'horizontal-scroll', delta:delta * scale});
    }, {passive:false});
    function setRemoteImages(policy) {
      const allowed = new Set(policy.sources);
      for (const element of document.querySelectorAll('[data-remote-src]')) {
        if (policy.enabled || allowed.has(element.dataset.remoteSrc)) {
          if (element.querySelector('img')) continue;
          const image = document.createElement('img');
          image.alt = element.dataset.alt;
          image.referrerPolicy = 'no-referrer';
          image.onerror = () => {
            if (element.contains(image)) element.textContent = '[Remote image unavailable: ' + element.dataset.alt + ']';
          };
          image.src = element.dataset.remoteSrc;
          element.replaceChildren(image);
        } else {
          element.textContent = '[Remote image: ' + element.dataset.alt + ']';
        }
      }
    }
    document.addEventListener('contextmenu', event => {
      const element = event.target.closest('[data-remote-src]');
      if (!element || element.querySelector('img')) return;
      event.preventDefault();
      send({type:'remote-image-menu', source:element.dataset.remoteSrc, x:event.clientX, y:event.clientY});
    });
    let ignoreScroll = false, commentRanges = [];
    const leaves = () => [...document.querySelectorAll('[data-leaf]')];
    function endpoint(node, offset, end) {
      const element = (node.nodeType === 1 ? node : node.parentElement)?.closest('[data-leaf]');
      if (!element) return null;
      if (element.dataset.precise !== '1') return +(end ? element.dataset.end : element.dataset.start);
      const range = document.createRange(); range.selectNodeContents(element);
      try { range.setEnd(node, offset); } catch { return null; }
      return Math.min(+element.dataset.end, +element.dataset.start + range.toString().length);
    }
    function selectedSource() {
      const selection = getSelection(); if (!selection.rangeCount || selection.isCollapsed) return null;
      const range = selection.getRangeAt(0);
      let start = endpoint(range.startContainer, range.startOffset, false);
      let end = endpoint(range.endContainer, range.endOffset, true);
      const intersecting = leaves().filter(e => range.intersectsNode(e));
      if (start === null && intersecting.length) start = +intersecting[0].dataset.start;
      if (end === null && intersecting.length) end = +intersecting.at(-1).dataset.end;
      if (start === null || end <= start) return null;
      const rect = range.getClientRects()[0] || range.getBoundingClientRect();
      return {start, end, x:rect.x, y:rect.y, width:rect.width, height:rect.height};
    }
    function reportSelection() {
      const value = selectedSource();
      send(value ? {type:'selection', ...value} : {type:'selection-cleared'});
    }
    function commentSelection() {
      const value = selectedSource(); if (value) send({type:'comment', ...value});
    }
    document.addEventListener('selectionchange', reportSelection);
    document.addEventListener('mouseup', reportSelection);
    function setScroll(fraction) {
      ignoreScroll = true;
      scrollTo(0, fraction * Math.max(0, document.documentElement.scrollHeight - innerHeight));
      requestAnimationFrame(() => requestAnimationFrame(() => { ignoreScroll = false; }));
    }
    let scrollScheduled = false;
    addEventListener('scroll', () => {
      if (ignoreScroll || scrollScheduled) return;
      scrollScheduled = true;
      requestAnimationFrame(() => {
        scrollScheduled = false;
        if (!ignoreScroll) send({type:'scroll', fraction: Math.max(0, Math.min(1, scrollY / Math.max(1, document.documentElement.scrollHeight - innerHeight)))});
      });
    });
    function jumpToSource(offset) {
      const elements = [...document.querySelectorAll('[data-start]')];
      const element = elements.find(e => +e.dataset.start <= offset && +e.dataset.end > offset) || elements.find(e => +e.dataset.start >= offset);
      element?.scrollIntoView({block:'center'});
    }
    function setComments(comments) {
      commentRanges = comments;
      if (!CSS.highlights || !window.Highlight) return;
      const all = [], active = [];
      for (const comment of comments) for (const element of leaves()) {
        const start = +element.dataset.start, end = +element.dataset.end;
        if (end <= comment.start || start >= comment.end) continue;
        const range = document.createRange(); range.selectNodeContents(element);
        if (element.dataset.precise === '1' && element.firstChild?.nodeType === 3) {
          range.setStart(element.firstChild, Math.max(0, comment.start - start));
          range.setEnd(element.firstChild, Math.min(element.textContent.length, comment.end - start));
        }
        all.push(range); if (comment.active) active.push(range);
      }
      CSS.highlights.set('comments', new Highlight(...all));
      CSS.highlights.set('active-comment', new Highlight(...active));
    }
    function setSearchHighlights(matches) {
      if (!CSS.highlights || !window.Highlight) return;
      const all = [], active = [];
      const elements = leaves().sort((a, b) => +a.dataset.start - +b.dataset.start);
      let next = 0;
      for (const element of elements) {
        const start = +element.dataset.start, end = +element.dataset.end;
        while (next < matches.length && matches[next].end <= start) next++;
        for (let index = next; index < matches.length && matches[index].start < end; index++) {
          const match = matches[index];
          const range = document.createRange(); range.selectNodeContents(element);
          if (element.dataset.precise === '1' && element.firstChild?.nodeType === 3) {
            range.setStart(element.firstChild, Math.max(0, match.start - start));
            range.setEnd(element.firstChild, Math.min(element.textContent.length, match.end - start));
          }
          all.push(range); if (match.active) active.push(range);
        }
      }
      CSS.highlights.set('search', new Highlight(...all));
      CSS.highlights.set('active-search', new Highlight(...active));
    }
    function jumpToSearch(offset) {
      const ranges = CSS.highlights?.get('active-search');
      if (ranges) for (const range of ranges) {
        const rect = range.getBoundingClientRect();
        if (rect.height > 0) { scrollBy(0, rect.top - innerHeight / 2); return; }
      }
      jumpToSource(offset);
    }
    document.addEventListener('click', event => {
      const link = event.target.closest('a');
      if (link?.getAttribute('href')?.startsWith('#')) {
        event.preventDefault();
        try { send({type:'fragment', id:decodeURIComponent(link.getAttribute('href').slice(1))}); } catch {}
        return;
      }
      if (!getSelection().isCollapsed || link) return;
      const leaf = event.target.closest('[data-leaf]'); if (!leaf) return;
      const comment = commentRanges.find(c => c.end > +leaf.dataset.start && c.start < +leaf.dataset.end);
      if (comment) send({type:'thread', id:comment.id});
    });
    """#
}

@MainActor final class ThemeCSSValidator: NSObject, WKNavigationDelegate {
    static var pending: [UUID: ThemeCSSValidator] = [:]
    let id = UUID()
    let css: String
    let completion: (Result<Void, Error>) -> Void
    let web = WKWebView()
    init(css: String, completion: @escaping (Result<Void, Error>) -> Void) { self.css = css; self.completion = completion }
    static func validate(_ css: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let validator = ThemeCSSValidator(css: css, completion: completion)
        pending[validator.id] = validator; validator.web.navigationDelegate = validator
        validator.web.loadHTMLString("<html><head><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; style-src 'unsafe-inline'\"></head><body></body></html>", baseURL: nil)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let literal = String(data: try! JSONSerialization.data(withJSONObject: css, options: .fragmentsAllowed), encoding: .utf8)!
        let js = #"""
        (() => {
          const css = CSS_VALUE;
          if (!css.includes('--pt-theme-version: 1') || !css.includes('--pt-theme-name:')) return 'Include theme name and version 1 metadata.';
          const style = document.createElement('style'); style.textContent = css; document.head.appendChild(style);
          let declarations = 0;
          function selectors(value) {
            let depth = 0, current = '', result = [];
            for (const c of value) { if (c === '(' || c === '[') depth++; if (c === ')' || c === ']') depth--; if (c === ',' && depth === 0) {result.push(current.trim());current='';} else current += c; }
            result.push(current.trim()); return result;
          }
          function inspect(rules, inside) {
            for (const rule of rules) {
              if (rule.constructor.name === 'CSSLayerBlockRule' && rule.name === 'parchment-theme') { const error = inspect(rule.cssRules, true); if (error) return error; }
              else if (rule.type === CSSRule.STYLE_RULE && inside) {
                if (selectors(rule.selectorText).some(s => !/^\.markdown-doc(?:[\s.:#\[]|$)/.test(s))) return 'Scope every selector to .markdown-doc.';
                for (const key of rule.style) {
                  if (rule.style.getPropertyPriority(key)) return '!important is not supported.';
                  if (/url\s*\(|image-set\s*\(/i.test(rule.style.getPropertyValue(key))) return 'External resources are not supported.';
                  if (/^(animation|transition)/.test(key)) return 'Animations are not supported.';
                  declarations++;
                }
              } else return 'Use only style rules inside @layer parchment-theme.';
            }
          }
          return inspect(style.sheet.cssRules, false) || (declarations ? '' : 'No valid theme declarations were found.');
        })()
        """#.replacingOccurrences(of: "CSS_VALUE", with: literal)
        web.evaluateJavaScript(js) { [self] value, error in
            if let error { completion(.failure(error)) }
            else if let message = value as? String, !message.isEmpty { completion(.failure(ThemeError.invalid(message))) }
            else { completion(.success(())) }
            Self.pending[id] = nil
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { completion(.failure(error)); Self.pending[id] = nil }
}
