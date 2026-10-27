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
        expectFalse(html.contains("src=\"https://")); expectTrue(html.contains("&lt;script&gt;"))
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
            ("testRendererDoesNotExecuteRawHTMLOrUnsafeLinks", suite.testRendererDoesNotExecuteRawHTMLOrUnsafeLinks),
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
