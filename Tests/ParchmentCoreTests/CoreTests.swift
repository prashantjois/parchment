import Foundation
import ParchmentCore

final class CoreTests {
    func testDocumentLinksRoundTripSpecialPaths() throws {
        let file = URL(fileURLWithPath: "/tmp/Café 🪴 + & # % ? (draft).md")
        let url = try DocumentLink.url(for: file, line: 42)
        let link = try DocumentLink(url: url)
        expectEqual(link.fileURL, file)
        expectEqual(link.line, 42)
        expectTrue(url.absoluteString.contains("%2B"))
        expectFalse(url.absoluteString.contains(" "))
        expectFalse(url.absoluteString.contains("("))
        let literalPercent = try DocumentLink(url: URL(string: "parchment://open?path=%2Ftmp%2Fliteral%2520name.md")!)
        expectEqual(literalPercent.fileURL.path, "/tmp/literal%20name.md")
    }
    func testDocumentLinksRejectInvalidRequests() {
        for value in [
            "https://open?path=/tmp/a.md", "parchment://delete?path=/tmp/a.md",
            "parchment://user@open?path=/tmp/a.md", "parchment://open:80?path=/tmp/a.md",
            "parchment://open/extra?path=/tmp/a.md", "parchment://open?path=/tmp/a.md#fragment",
            "parchment://open?path=relative.md", "parchment://open?path=~/a.md",
            "parchment://open?path=//remote/a.md", "parchment://open?path=/tmp/a%00.md",
            "parchment://open?path=/tmp/a.sh", "parchment://open?path=/tmp/a.md&path=/tmp/b.md",
            "parchment://open?path=/tmp/a.md&session_token=secret", "parchment://open",
            "parchment://open?path=/tmp/a.md&line=0", "parchment://open?path=/tmp/a.md&line=-1",
            "parchment://open?path=/tmp/a.md&line=1.5", "parchment://open?path=/tmp/a.md&line",
            "parchment://open?path=/tmp/a.md&line=999999999999999999999999999",
            "parchment://open?path=/tmp/a.md&line=1&line=2"
        ] { expectThrows(try DocumentLink(url: URL(string: value)!)) }
    }
    func testDirectDocumentLinks() throws {
        let simple = try DocumentLink(url: URL(string: "parchment://Users/me/notes.md?line=42")!)
        expectEqual(simple.fileURL.path, "/Users/me/notes.md")
        expectEqual(simple.line, 42)
        expectEqual(try DocumentLink.url(for: simple.fileURL, line: 42).absoluteString, "parchment://Users/me/notes.md?line=42")
        let triple = try DocumentLink(url: URL(string: "parchment:///Users/me/Caf%C3%A9%20%2B%20%23.md")!)
        expectEqual(triple.fileURL.path, "/Users/me/Café + #.md")
        let literal = try DocumentLink(url: URL(string: "parchment://tmp/literal%2520name.md")!)
        expectEqual(literal.fileURL.path, "/tmp/literal%20name.md")
        for value in ["parchment://Users/me/a.md?line=0", "parchment://Users/me/a.md?line=2&line=3",
                      "parchment://Users/me/a.md?session_token=secret", "parchment://Users/me/a.md#fragment",
                      "parchment://user@Users/me/a.md", "parchment://Users:80/me/a.md", "parchment://Users/me/a%00.md",
                      "parchment://Users/me/a.sh", "parchment:////remote/a.md"] {
            expectThrows(try DocumentLink(url: URL(string: value)!))
        }
    }
    func testDocumentLinkLineLocations() throws {
        let file = URL(fileURLWithPath: "/tmp/a.md")
        let second = try DocumentLink(url: DocumentLink.url(for: file, line: 2))
        expectEqual(second.location(in: "🌎\r\nSecond\n"), 4)
        expectEqual(second.location(in: "First\rSecond"), 6)
        expectEqual(second.location(in: ""), 0)
        let beyond = try DocumentLink(url: DocumentLink.url(for: file, line: Int.max))
        expectEqual(beyond.location(in: "One\n"), 4)
        expectNil(try DocumentLink(url: DocumentLink.url(for: file)).location(in: "One"))
    }
    func anchor(_ text: String, quote: String) -> CommentAnchor {
        let range = (text as NSString).range(of: quote)
        return CommentAnchor(text: text, range: TextSpan(location: range.location, length: range.length))
    }
    func testAnchorSurvivesInsertionsWithUnicode() {
        let original = "# Café 🪴\n\nKeep this paragraph.\n"
        let anchor = anchor(original, quote: "Keep this paragraph.")
        expectEqual(anchor.locate(in: original).state, .exact)
        let changed = "New introduction 👋\n\n" + original
        let result = anchor.locate(in: changed)
        expectEqual(result.state, .moved)
        expectEqual(result.range?.nsRange, (changed as NSString).range(of: "Keep this paragraph."))
    }
    func testAnchorRefusesChangedTextAndAmbiguousMatches() {
        let anchor = anchor("target", quote: "target")
        expectEqual(anchor.locate(in: "changed").state, .orphaned)
        expectEqual(anchor.locate(in: "target target").state, .ambiguous)
        expectNil(anchor.locate(in: "target target").range)
    }
    func testContextDisambiguatesRepeatedText() {
        let original = "before target after"
        let result = anchor(original, quote: "target").locate(in: "target\n" + original)
        expectEqual(result.state, .moved)
        expectEqual(result.range?.location, 14)
    }
    func testOffsetMatchIsNotTrustedAfterDocumentChanges() {
        let original = "target"
        expectEqual(anchor(original, quote: "target").locate(in: "target and target").state, .ambiguous)
    }
    func testOverlappingMatchesAreAmbiguous() {
        expectEqual(anchor("aaa", quote: "aaa").locate(in: "aaaa").state, .ambiguous)
    }
    func testHeadingIDsAreUniqueAndStableAcrossInsertions() {
        let text = "# Hello\n\n# Hello\n\n# Hello-1\n"
        let first = MarkdownRenderer.render(text).headings.map(\.id)
        expectEqual(Set(first).count, 3)
        expectEqual(first, MarkdownRenderer.render("Introduction.\n\n" + text).headings.map(\.id))
    }
    func testCRLFAndEmojiOffsetsRemainExact() {
        let text = "# 🪴\r\n\r\nA café.\r\n"
        let selected = anchor(text, quote: "A café.")
        expectEqual(selected.startLine, 3)
        expectEqual(selected.locate(in: text).range?.nsRange, (text as NSString).range(of: "A café."))
        expectEqual(anchor("One\r\nTwo\r\n", quote: "One\r\n").endLine, 1)
    }
    func testResolveReopenAndReanchorPreserveHistory() {
        let original = anchor("old", quote: "old")
        var thread = CommentThread(anchor: original, body: "Revise this", author: "Reviewer")
        thread.events.append(CommentEvent(kind: .reply, author: "Author", body: "Will do"))
        thread.events.append(CommentEvent(kind: .resolve, author: "Reviewer"))
        expectTrue(thread.isResolved)
        thread.events.append(CommentEvent(kind: .reopen, author: "Author"))
        expectFalse(thread.isResolved)
        let replacement = anchor("new text", quote: "text")
        thread.events.append(CommentEvent(kind: .reanchor, author: "Author", anchor: replacement))
        expectEqual(thread.anchor, replacement)
        expectEqual(thread.originalAnchor, original)
        expectEqual(thread.events.count, 5)
        expectEqual(thread.messages.count, 2)
    }
    func testCompanionRoundTripAndAgentExport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("review.md")
        let text = "A useful sentence."
        var thread = CommentThread(anchor: anchor(text, quote: "useful"), body: "Be specific", author: "Reviewer")
        var file = CommentFile(document: "review.md", threads: [thread])
        try file.write(for: url)
        let restored = try CommentFile.read(for: url)
        expectEqual(restored.threads[0].anchor.quote, "useful")
        expectEqual(restored.threads[0].id, thread.id)
        thread.events.append(CommentEvent(kind: .resolve, author: "Reviewer")); file.threads = [thread]
        let unresolved = try JSONSerialization.jsonObject(with: file.export(text: text, path: url.path, includeResolved: false)) as! [String: Any]
        expectEqual((unresolved["threads"] as! [Any]).count, 0)
        let all = try JSONSerialization.jsonObject(with: file.export(text: text, path: url.path, includeResolved: true)) as! [String: Any]
        expectEqual((all["threads"] as! [Any]).count, 1)
        expectEqual(all["sourceSHA256"] as? String, sourceHash(text))
        expectEqual(all["sourceText"] as? String, text)
    }
    func testUnsupportedCompanionVersionIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("review.md")
        try Data(#"{"formatVersion":99,"document":"review.md","threads":[]}"#.utf8).write(to: CommentFile.companionURL(for: url))
        expectThrows(try CommentFile.read(for: url))
    }
    func testPendingReviewsNeverLeakIntoAgentExports() throws {
        let text = "Review this sentence."
        let anchor = anchor(text, quote: "sentence")
        var file = CommentFile(document: "review.md")
        file.threads.append(CommentThread(anchor: anchor, body: "Published comment", author: "Reviewer"))
        let review = file.startReview(author: "Reviewer")
        file.threads.append(CommentThread(anchor: anchor, body: "SECRET DRAFT COMMENT", author: "Reviewer", reviewID: review))
        file.threads[0].events.append(CommentEvent(kind: .reply, author: "Reviewer", body: "SECRET DRAFT REPLY", reviewID: review))
        file.threads.append(CommentThread(anchor: anchor, body: "Immediate comment during a review", author: "Reviewer"))
        expectEqual(file.pendingCount, 2)
        for includeResolved in [false, true] {
            let data = try file.export(text: text, path: "/review.md", includeResolved: includeResolved)
            let json = String(decoding: data, as: UTF8.self)
            expectFalse(json.contains("SECRET DRAFT"))
            expectTrue(json.contains("Immediate comment during a review"))
            let export = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            expectEqual((export["threads"] as! [Any]).count, 2)
            expectEqual((export["reviews"] as! [Any]).count, 0)
        }
    }
    func testReviewSubmissionPublishesCommentsAndRepliesTogether() throws {
        let text = "Review this sentence."
        let anchor = anchor(text, quote: "sentence")
        var file = CommentFile(document: "review.md", threads: [CommentThread(anchor: anchor, body: "Existing", author: "Reviewer")])
        let review = file.startReview(author: "Reviewer")
        expectEqual(file.startReview(author: "Reviewer"), review)
        file.threads.append(CommentThread(anchor: anchor, body: "Pending comment", author: "Reviewer", reviewID: review))
        file.threads[0].events.append(CommentEvent(kind: .reply, author: "Reviewer", body: "Pending reply", reviewID: review))
        let submitted = Date(timeIntervalSince1970: 1_800_000_000)
        expectTrue(file.submitReview(summary: "Please revise these passages.", at: submitted))
        expectNil(file.activeReview)
        expectEqual(file.pendingCount, 0)
        expectEqual(file.threads[1].publishedAt, submitted)
        expectEqual(file.threads[1].events[0].publishedAt, submitted)
        expectEqual(file.threads[0].events[1].publishedAt, submitted)
        let json = String(decoding: try file.export(text: text, path: "/review.md", includeResolved: false), as: UTF8.self)
        expectTrue(json.contains("Pending comment") && json.contains("Pending reply") && json.contains("Please revise these passages."))
        expectFalse(file.submitReview())
        expectTrue(file.startReview(author: "Reviewer") != review)
    }
    func testDiscardReviewPreservesPublishedDiscussion() throws {
        let text = "Review this sentence."
        let anchor = anchor(text, quote: "sentence")
        var file = CommentFile(document: "review.md", threads: [CommentThread(anchor: anchor, body: "Keep this", author: "Reviewer")])
        let review = file.startReview(author: "Reviewer")
        file.threads[0].events.append(CommentEvent(kind: .reply, author: "Reviewer", body: "Discard reply", reviewID: review))
        file.threads.append(CommentThread(anchor: anchor, body: "Discard thread", author: "Reviewer", reviewID: review))
        file.discardReview()
        expectEqual(file.threads.count, 1)
        expectEqual(file.threads[0].messages.count, 1)
        expectEqual(file.threads[0].messages[0].body, "Keep this")
        expectNil(file.activeReview)
        expectTrue(file.reviews?[0].discardedAt != nil)
    }
    func testPendingReviewPersistsAndLegacyCommentsStayPublished() throws {
        let text = "A sentence."
        var file = CommentFile(document: "review.md")
        let review = file.startReview(author: "Reviewer")
        file.threads.append(CommentThread(anchor: anchor(text, quote: "sentence"), body: "Draft", author: "Reviewer", reviewID: review))
        let restored = try CommentFile.decoder.decode(CommentFile.self, from: CommentFile.encoder.encode(file))
        expectEqual(restored.activeReview?.id, review)
        expectEqual(restored.pendingCount, 1)
        expectTrue(restored.threads[0].isPending)
        var legacy = CommentFile(document: "review.md", threads: [CommentThread(anchor: anchor(text, quote: "sentence"), body: "Old comment", author: "Reviewer")])
        legacy.formatVersion = 1
        let decoded = try CommentFile.decoder.decode(CommentFile.self, from: CommentFile.encoder.encode(legacy))
        expectFalse(decoded.threads[0].isPending)
        expectFalse(decoded.threads[0].messages[0].isPending)
        expectNil(decoded.activeReview)
    }
    func testViewModesRememberSinglePaneAndLayoutRoundTrips() throws {
        var layout = FileLayout()
        layout.toggleRendered(); expectEqual(layout.mode, .rendered)
        layout.toggleSplit(); expectEqual(layout.mode, .split)
        layout.toggleRendered(); expectEqual(layout.mode, .rendered)
        layout.toggleSplit(); expectEqual(layout.mode, .split)
        layout.toggleSplit(); expectEqual(layout.mode, .rendered)
        layout.toggleSplit(); layout.showSinglePane(.raw); expectEqual(layout.mode, .raw)
        layout.showSinglePane(.raw); expectEqual(layout.mode, .raw)
        layout.toggleSplit(); layout.toggleSplit(); expectEqual(layout.mode, .raw)
        layout.toggleSplit(); layout.showSinglePane(.rendered); expectEqual(layout.mode, .rendered)
        layout.showSinglePane(.rendered); expectEqual(layout.mode, .rendered)
        layout.filesWidth = 248; layout.rightPanel = .comments; layout.showRight = true
        expectEqual(try JSONDecoder().decode(FileLayout.self, from: JSONEncoder().encode(layout)), layout)
    }
    func testToolbarViewButtonWorksFromEveryMode() {
        for startingMode in ViewMode.allCases {
            for previousMode in [ViewMode.raw, .rendered] {
                var layout = FileLayout()
                layout.mode = startingMode; layout.previousSingleMode = previousMode
                layout.showFiles = true; layout.showRight = true; layout.splitFraction = 0.6
                let expected: ViewMode = startingMode == .rendered ? .raw : .rendered
                layout.toggleRendered()
                expectEqual(layout.mode, expected)
                expectEqual(layout.previousSingleMode, expected)
                layout.toggleSplit(); expectEqual(layout.mode, .split)
                layout.toggleSplit(); expectEqual(layout.mode, expected)
                expectTrue(layout.showFiles && layout.showRight)
                expectEqual(layout.splitFraction, 0.6)
            }
        }
    }
    func testRendererIncludesSixHeadingLevelsAndSourceMapping() {
        let source = "# Café 🪴\n\n## Two\n\n### Three\n\n#### Four\n\n##### Five\n\n###### Six\n\nA **bold** choice."
        let result = MarkdownRenderer.render(source)
        expectEqual(result.headings.map(\.level), [1, 2, 3, 4, 5, 6])
        expectEqual(result.headings[0].title, "Café 🪴")
        expectEqual(result.headings[1].location, (source as NSString).range(of: "## Two").location)
        let bold = (source as NSString).range(of: "bold")
        expectTrue(result.html.contains("data-start=\"\(bold.location)\" data-end=\"\(bold.location + bold.length)\" data-precise=\"1\">bold"))
    }
    func testFrontMatterIsHiddenWithOriginalSourceOffsets() {
        for newline in ["\n", "\r\n"] {
            for closing in ["---", "..."] {
                let source = ["\u{FEFF}---", "name: secret-metadata", "description: |", "  # Hidden heading 📝", closing, "# Visible heading", "", "Comment on café 📝."].joined(separator: newline)
                let rendered = MarkdownRenderer.render(source)
                expectFalse(rendered.html.contains("secret-metadata"))
                expectFalse(rendered.html.contains("Hidden heading"))
                expectEqual(rendered.headings.map(\.title), ["Visible heading"])
                expectEqual(rendered.headings.first?.location, (source as NSString).range(of: "# Visible heading").location)
                let range = (source as NSString).range(of: "Comment on café 📝.")
                expectTrue(rendered.html.contains("data-start=\"\(range.location)\" data-end=\"\(NSMaxRange(range))\" data-precise=\"1\""))
            }
        }
        expectEqual(MarkdownRenderer.render("---\nname: hidden\n---").html, "")
        expectEqual(MarkdownRenderer.render("").html, "")
    }
    func testFrontMatterDetectionPreservesOrdinaryMarkdown() {
        let incomplete = MarkdownRenderer.render("---\nname: still visible\n# Heading")
        expectTrue(incomplete.html.contains("still visible"))
        expectTrue(incomplete.html.contains("<hr"))
        let ordinary = MarkdownRenderer.render("# Heading\n\n---\n\nVisible\n\n---")
        expectTrue(ordinary.html.contains("Visible"))
        expectEqual(ordinary.headings.map(\.title), ["Heading"])
        let fenced = MarkdownRenderer.render("```yaml\n---\nname: visible example\n---\n```")
        expectTrue(fenced.html.contains("visible example"))
    }
    func testRendererHandlesTablesTasksLinksAndCode() {
        let source = """
        - [x] Done
        - [ ] Next

        | A | B |
        | :--- | ---: |
        | One | Two |

        ```swift
        let value = "<script>"
        ```

        [Link](https://example.com) and `inline`.
        """
        let html = MarkdownRenderer.render(source).html
        expectTrue(html.contains("task-list-item")); expectTrue(html.contains("disabled checked"))
        expectTrue(html.contains("data-align=\"right\"")); expectTrue(html.contains("<table>"))
        expectTrue(html.contains("data-language=\"swift\"")); expectTrue(html.contains("&lt;script&gt;"))
        expectTrue(html.contains("href=\"https://example.com\""))
    }
    func testRendererDoesNotExecuteRawHTMLOrUnsafeLinks() {
        let html = MarkdownRenderer.render("<script>alert(1)</script>\n\n[x](javascript:alert)\n\n![remote](https://example.com/tracker.png)").html
        expectFalse(html.contains("<script>")); expectFalse(html.contains("href=\"javascript:"))
        expectFalse(html.contains("<img src=\"https://")); expectTrue(html.contains("&lt;script&gt;"))
    }
    func testRemoteImagesStayBlockedUntilRequested() {
        let html = MarkdownRenderer.render("![A & B](https://example.com/image.png?a=1&b=2)").html
        expectTrue(html.contains("data-remote-src=\"https://example.com/image.png?a=1&amp;b=2\""))
        expectTrue(html.contains("data-alt=\"A &amp; B\""))
        expectTrue(html.contains("[Remote image: A &amp; B]"))
        expectFalse(html.contains("<img"))
        for source in ["javascript:alert", "data:image/png;base64,abc", "file:///tmp/a.png", "//example.com/a.png", "https://user:password@example.com/a.png"] {
            let blocked = MarkdownRenderer.render("![blocked](\(source))").html
            expectFalse(blocked.contains("data-remote-src="))
            expectFalse(blocked.contains("<img"))
        }
    }
    func testSyntaxHighlightingUsesTheFenceLanguageAndPreservesText() {
        let examples = [
            ("swift", "let value: String = greet(\"🌎\", 42) // note\n"),
            ("kt", "val value: String = greet(\"🌎\", 42) // note\n"),
            ("java", "final String value = greet(\"🌎\", 42); // note\n"),
            ("js", "const value = greet(`🌎`, 42); // note\n"),
            ("ts", "const value: string = greet(`🌎`, 42); // note\n"),
            ("py", "def greet():\n    return \"🌎\", 42 # note\n"),
            ("json", "{\"value\": true, \"count\": 42}"),
            ("sh", "if true; then echo \"🌎\"; fi # note\n"),
            ("sql", "SELECT '🌎', 42 FROM example -- note\n"),
            ("yml", "value: true\ncount: 42 # note\n")
        ]
        for (language, code) in examples {
            let tokens = SyntaxHighlighter.tokens(in: code, language: language)
            expectEqual(tokens.map { (code as NSString).substring(with: $0.range) }.joined(), code)
            expectTrue(tokens.contains { $0.kind == "keyword" })
            expectTrue(tokens.contains { $0.kind == "number" } || language == "sh")
            let html = MarkdownRenderer.render("```\(language)\n\(code)\n```").html
            expectTrue(html.contains("class=\"token keyword\""))
        }
        expectFalse(SyntaxHighlighter.tokens(in: "let value = 42", language: "unknown").contains { $0.kind != nil })
        expectFalse(SyntaxHighlighter.tokens(in: "let value", language: "json").contains { $0.kind != nil })
        _ = SyntaxHighlighter.tokens(in: "if🌎", language: "swift")
    }
    func testHighlightedCodePreservesUnicodeAndCRLFSourceOffsets() {
        for newline in ["\n", "\r\n", "\r"] {
            let code = ["let café = \"🌎\"", "let value: String = greet(42)", "// let 42 stays a comment"].joined(separator: newline)
            let source = "```swift" + newline + code + newline + "```"
            let html = MarkdownRenderer.render(source).html
            for (kind, token) in [("string", "\"🌎\""), ("type", "String"), ("function", "greet"), ("number", "42")] {
                let range = (source as NSString).range(of: token)
                let attributes = "class=\"token \(kind)\" data-leaf=\"true\" data-start=\"\(range.location)\" data-end=\"\(NSMaxRange(range))\" data-precise=\"1\""
                expectTrue(html.contains(attributes))
            }
            expectTrue(html.contains("class=\"token comment\""))
        }
    }
    func testHighlightedCodeEscapesMarkupAndKeepsStringsAndCommentsWhole() {
        let source = "```swift\nlet html = \"<script>// comment</script>\"\n/* let fake = 42 */\n```"
        let html = MarkdownRenderer.render(source).html
        expectFalse(html.contains("<script>"))
        expectTrue(html.contains("&lt;script&gt;// comment&lt;/script&gt;"))
        let code = "\"// inside string\" /* let fake = 42 */"
        let colored = SyntaxHighlighter.tokens(in: code, language: "swift").filter { $0.kind != nil }
        expectEqual(colored.map(\.kind), ["string", "comment"])
        let python = "\"\"\"multi\nline # string\"\"\""
        expectEqual(SyntaxHighlighter.tokens(in: python, language: "python").filter { $0.kind != nil }.map(\.kind), ["string"])
    }
    func testRendererPreservesLocalAndExternalNavigationLinks() {
        let html = MarkdownRenderer.render("[Relative](docs/guide.md#heading) [File](file:///tmp/a.md) [Parchment](parchment://Users/me/a.md?line=2) [Web](https://example.com) [Protocol relative](//example.com/path) [Unsafe](parchment://open?path=/tmp/a.md&session_token=secret) [Remote file](file://server/tmp/a.md)").html
        for href in ["docs/guide.md#heading", "file:///tmp/a.md", "parchment://Users/me/a.md?line=2", "https://example.com", "https://example.com/path"] {
            expectTrue(html.contains("href=\"\(href)\""))
        }
        expectFalse(html.contains("href=\"parchment://open"))
        expectFalse(html.contains("href=\"file://server"))
    }
    func testCodeAndAttributeValuesAreEscaped() {
        let html = MarkdownRenderer.render("`<img src=x onerror=bad>`\n\n[link](https://example.com/?a=1&b=2)").html
        expectTrue(html.contains("&lt;img")); expectFalse(html.contains("<img src=x"))
        expectTrue(html.contains("&amp;b=2"))
    }
}


private enum Checks { static var failures = 0 }
private func expectTrue(_ condition: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    if !condition() { Checks.failures += 1; print("FAIL \(file):\(line)") }
}
private func expectFalse(_ condition: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) { expectTrue(!condition(), file: file, line: line) }
private func expectNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { expectTrue(value == nil, file: file, line: line) }
private func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #filePath, line: UInt = #line) {
    if lhs != rhs { Checks.failures += 1; print("FAIL \(file):\(line): \(lhs) != \(rhs)") }
}
private func expectThrows<T>(_ value: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try value(); expectTrue(false, file: file, line: line) } catch { }
}

@main struct TestRunner {
    static func main() {
        let suite = CoreTests()
        let tests: [(String, () throws -> Void)] = [
            ("testDocumentLinksRoundTripSpecialPaths", suite.testDocumentLinksRoundTripSpecialPaths),
            ("testDocumentLinksRejectInvalidRequests", suite.testDocumentLinksRejectInvalidRequests),
            ("testDirectDocumentLinks", suite.testDirectDocumentLinks),
            ("testDocumentLinkLineLocations", suite.testDocumentLinkLineLocations),
            ("testAnchorSurvivesInsertionsWithUnicode", suite.testAnchorSurvivesInsertionsWithUnicode),
            ("testAnchorRefusesChangedTextAndAmbiguousMatches", suite.testAnchorRefusesChangedTextAndAmbiguousMatches),
            ("testContextDisambiguatesRepeatedText", suite.testContextDisambiguatesRepeatedText),
            ("testOffsetMatchIsNotTrustedAfterDocumentChanges", suite.testOffsetMatchIsNotTrustedAfterDocumentChanges),
            ("testOverlappingMatchesAreAmbiguous", suite.testOverlappingMatchesAreAmbiguous),
            ("testHeadingIDsAreUniqueAndStableAcrossInsertions", suite.testHeadingIDsAreUniqueAndStableAcrossInsertions),
            ("testCRLFAndEmojiOffsetsRemainExact", suite.testCRLFAndEmojiOffsetsRemainExact),
            ("testResolveReopenAndReanchorPreserveHistory", suite.testResolveReopenAndReanchorPreserveHistory),
            ("testCompanionRoundTripAndAgentExport", suite.testCompanionRoundTripAndAgentExport),
            ("testUnsupportedCompanionVersionIsRejected", suite.testUnsupportedCompanionVersionIsRejected),
            ("testPendingReviewsNeverLeakIntoAgentExports", suite.testPendingReviewsNeverLeakIntoAgentExports),
            ("testReviewSubmissionPublishesCommentsAndRepliesTogether", suite.testReviewSubmissionPublishesCommentsAndRepliesTogether),
            ("testDiscardReviewPreservesPublishedDiscussion", suite.testDiscardReviewPreservesPublishedDiscussion),
            ("testPendingReviewPersistsAndLegacyCommentsStayPublished", suite.testPendingReviewPersistsAndLegacyCommentsStayPublished),
            ("testViewModesRememberSinglePaneAndLayoutRoundTrips", suite.testViewModesRememberSinglePaneAndLayoutRoundTrips),
            ("testToolbarViewButtonWorksFromEveryMode", suite.testToolbarViewButtonWorksFromEveryMode),
            ("testRendererIncludesSixHeadingLevelsAndSourceMapping", suite.testRendererIncludesSixHeadingLevelsAndSourceMapping),
            ("testRendererHandlesTablesTasksLinksAndCode", suite.testRendererHandlesTablesTasksLinksAndCode),
            ("testFrontMatterIsHiddenWithOriginalSourceOffsets", suite.testFrontMatterIsHiddenWithOriginalSourceOffsets),
            ("testFrontMatterDetectionPreservesOrdinaryMarkdown", suite.testFrontMatterDetectionPreservesOrdinaryMarkdown),
            ("testRendererDoesNotExecuteRawHTMLOrUnsafeLinks", suite.testRendererDoesNotExecuteRawHTMLOrUnsafeLinks),
            ("testRemoteImagesStayBlockedUntilRequested", suite.testRemoteImagesStayBlockedUntilRequested),
            ("testSyntaxHighlightingUsesTheFenceLanguageAndPreservesText", suite.testSyntaxHighlightingUsesTheFenceLanguageAndPreservesText),
            ("testHighlightedCodePreservesUnicodeAndCRLFSourceOffsets", suite.testHighlightedCodePreservesUnicodeAndCRLFSourceOffsets),
            ("testHighlightedCodeEscapesMarkupAndKeepsStringsAndCommentsWhole", suite.testHighlightedCodeEscapesMarkupAndKeepsStringsAndCommentsWhole),
            ("testRendererPreservesLocalAndExternalNavigationLinks", suite.testRendererPreservesLocalAndExternalNavigationLinks),
            ("testCodeAndAttributeValuesAreEscaped", suite.testCodeAndAttributeValuesAreEscaped),
        ]
        for (name, test) in tests {
            let before = Checks.failures
            do { try test() } catch { Checks.failures += 1; print("FAIL \(name): \(error)") }
            if before == Checks.failures { print("PASS \(name)") }
        }
        print("\(tests.count) checks, \(Checks.failures) failures")
        exit(Checks.failures == 0 ? 0 : 1)
    }
}
