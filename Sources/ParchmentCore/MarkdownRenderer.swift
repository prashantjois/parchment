import Foundation
import Markdown

public struct DocumentHeading: Identifiable, Equatable {
    public var id: String
    public var title: String
    public var level: Int
    public var location: Int
}

public struct RenderedDocument {
    public var html: String
    public var headings: [DocumentHeading]
}

public enum MarkdownRenderer {
    public static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    public static func render(_ source: String, baseURL: URL? = nil) -> RenderedDocument {
        let lines = source.components(separatedBy: "\n")
        var renderedLines = lines
        let firstLine = lines[0].hasPrefix("\u{FEFF}") ? String(lines[0].dropFirst()) : lines[0]
        if firstLine.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
           let closing = lines.indices.dropFirst().first(where: {
               let delimiter = lines[$0].trimmingCharacters(in: .whitespacesAndNewlines)
               return delimiter == "---" || delimiter == "..."
           }) {
            // Keep line numbers unchanged so selections and comments map to the raw source.
            for index in 0...closing { renderedLines[index] = "" }
        }
        let document = Document(parsing: renderedLines.joined(separator: "\n"))
        var lineOffsets = [0]
        for line in lines.dropLast() { lineOffsets.append(lineOffsets.last! + (line as NSString).length + 1) }
        var headings: [DocumentHeading] = []
        var headingIDs: [String: Int] = [:]
        var usedHeadingIDs = Set<String>()
        func offset(_ point: SourceLocation) -> Int {
            guard point.line > 0, point.line <= lines.count else { return (source as NSString).length }
            let bytes = Array(lines[point.line - 1].utf8.prefix(max(0, point.column - 1)))
            return lineOffsets[point.line - 1] + (String(decoding: bytes, as: UTF8.self) as NSString).length
        }
        func span(_ node: Markup) -> TextSpan? {
            guard let range = node.range else { return nil }
            let start = offset(range.lowerBound), end = offset(range.upperBound)
            return TextSpan(location: start, length: max(0, end - start))
        }
        func attrs(_ node: Markup) -> String {
            guard let range = span(node) else { return "" }
            return " data-start=\"\(range.location)\" data-end=\"\(range.location + range.length)\""
        }
        func leaf(_ node: Markup, text: String, tag: String = "span", html: String? = nil) -> String {
            var mapped = span(node)
            if let range = mapped, range.isValid(in: source) {
                let slice = (source as NSString).substring(with: range.nsRange) as NSString
                let found = slice.range(of: text, options: .literal)
                if found.location != NSNotFound { mapped = TextSpan(location: range.location + found.location, length: found.length) }
            }
            guard let range = mapped, range.isValid(in: source) else { return "<\(tag)>\(html ?? escape(text))</\(tag)>" }
            let precise = (source as NSString).substring(with: range.nsRange) == text
            return "<\(tag) data-leaf=\"true\" data-start=\"\(range.location)\" data-end=\"\(range.location + range.length)\" data-precise=\"\(precise ? 1 : 0)\">\(html ?? escape(text))</\(tag)>"
        }
        func highlightedCode(_ code: CodeBlock) -> String {
            let tokens = SyntaxHighlighter.tokens(in: code.code, language: code.language ?? "")
            let text = code.code as NSString
            func tokenHTML(_ token: SyntaxToken, mapping: String = "") -> String {
                let classes = token.kind.map { " class=\"token \($0)\"" } ?? ""
                return "<span\(classes)\(mapping)>\(escape(text.substring(with: token.range)))</span>"
            }
            guard tokens.contains(where: { $0.kind != nil }) else { return leaf(code, text: code.code) }
            // Normalize CR/LF for matching while retaining every original UTF-16 boundary.
            if let range = span(code), range.isValid(in: source) {
                let raw = (source as NSString).substring(with: range.nsRange) as NSString
                var units: [UInt16] = [], boundaries = [0], index = 0
                while index < raw.length {
                    let unit = raw.character(at: index)
                    if unit == 13 {
                        index += 1
                        if index < raw.length && raw.character(at: index) == 10 { index += 1 }
                        units.append(10)
                    } else { units.append(unit); index += 1 }
                    boundaries.append(index)
                }
                let normalized = String(decoding: units, as: UTF16.self) as NSString
                let match = normalized.range(of: code.code, options: .literal)
                if match.location != NSNotFound {
                    return tokens.map { token in
                        let start = boundaries[match.location + token.range.location], end = boundaries[match.location + NSMaxRange(token.range)]
                        let precise = raw.substring(with: NSRange(location: start, length: end - start)) == text.substring(with: token.range)
                        let mapping = " data-leaf=\"true\" data-start=\"\(range.location + start)\" data-end=\"\(range.location + end)\" data-precise=\"\(precise ? 1 : 0)\""
                        return tokenHTML(token, mapping: mapping)
                    }.joined()
                }
            }
            return leaf(code, text: code.code, html: tokens.map { tokenHTML($0) }.joined())
        }
        func safeLink(_ value: String) -> String? {
            guard !value.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 } == true }) else { return nil }
            if value.hasPrefix("//") { return "https:" + value }
            let scheme = URL(string: value)?.scheme?.lowercased()
            if scheme == "parchment" {
                guard let url = URL(string: value), (try? DocumentLink(url: url)) != nil else { return nil }
                return value
            }
            if scheme == "file", let url = URL(string: value) {
                return [nil, "", "localhost"].contains(url.host) ? value : nil
            }
            return scheme == nil || ["https", "http", "mailto"].contains(scheme!) ? value : nil
        }
        func imageSource(_ value: String) -> String? {
            guard let baseURL, URL(string: value)?.scheme == nil, !value.hasPrefix("//") else { return nil }
            let path = value.removingPercentEncoding ?? value
            let url = URL(fileURLWithPath: path, relativeTo: baseURL).standardizedFileURL
            let types = ["png":"image/png", "jpg":"image/jpeg", "jpeg":"image/jpeg", "gif":"image/gif", "webp":"image/webp", "heic":"image/heic"]
            guard let mime = types[url.pathExtension.lowercased()],
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 20_000_000,
                  let data = try? Data(contentsOf: url) else { return nil }
            return "data:\(mime);base64,\(data.base64EncodedString())"
        }
        func children(_ node: Markup) -> String { node.children.map { renderNode($0) }.joined() }
        func renderNode(_ node: Markup) -> String {
            let a = attrs(node)
            switch node {
            case let heading as Heading:
                let location = span(node)?.location ?? 0
                let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "-_"))
                let stem = heading.plainText.lowercased().components(separatedBy: allowed.inverted).joined().trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
                let base = stem.isEmpty ? "heading" : stem
                var count = headingIDs[base, default: 0]
                var id = count == 0 ? base : "\(base)-\(count)"
                while usedHeadingIDs.contains(id) { count += 1; id = "\(base)-\(count)" }
                headingIDs[base] = count + 1; usedHeadingIDs.insert(id)
                headings.append(DocumentHeading(id: id, title: heading.plainText, level: heading.level, location: location))
                return "<h\(heading.level) id=\"\(id)\"\(a)>\(children(node))</h\(heading.level)>"
            case let text as Markdown.Text: return leaf(node, text: text.string)
            case let code as InlineCode: return leaf(node, text: code.code, tag: "code")
            case let code as CodeBlock:
                if code.language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "mermaid" {
                    return "<figure class=\"diagram mermaid-diagram\"\(a)><pre><code data-language=\"mermaid\">\(leaf(code, text: code.code))</code></pre></figure>"
                }
                return "<pre\(a)><code data-language=\"\(escape(code.language ?? ""))\">\(highlightedCode(code))</code></pre>"
            case is Paragraph: return "<p\(a)>\(children(node))</p>"
            case is Strong: return "<strong\(a)>\(children(node))</strong>"
            case is Emphasis: return "<em\(a)>\(children(node))</em>"
            case is Strikethrough: return "<del\(a)>\(children(node))</del>"
            case is BlockQuote: return "<blockquote\(a)>\(children(node))</blockquote>"
            case let list as OrderedList: return "<ol start=\"\(list.startIndex)\"\(a)>\(children(node))</ol>"
            case is UnorderedList: return "<ul\(a)>\(children(node))</ul>"
            case let item as ListItem:
                let check = item.checkbox.map { "<input type=\"checkbox\" disabled \($0 == .checked ? "checked" : "")>" } ?? ""
                return "<li class=\"\(item.checkbox == nil ? "" : "task-list-item")\"\(a)>\(check)\(children(node))</li>"
            case let link as Markdown.Link:
                guard let href = safeLink(link.destination ?? "") else { return children(node) }
                return "<a href=\"\(escape(href))\"\(a)>\(children(node))</a>"
            case let image as Markdown.Image:
                if let remote = URL(string: image.source ?? ""),
                   ["https", "http"].contains(remote.scheme?.lowercased() ?? ""),
                   remote.host?.isEmpty == false, remote.user == nil, remote.password == nil {
                    let alt = escape(image.plainText)
                    return "<span class=\"remote-image\" data-remote-src=\"\(escape(remote.absoluteString))\" data-alt=\"\(alt)\"\(a)>[Remote image: \(alt)]</span>"
                }
                guard let src = imageSource(image.source ?? "") else { return "<span\(a)>[Image: \(escape(image.plainText))]</span>" }
                return "<img src=\"\(src)\" alt=\"\(escape(image.plainText))\"\(a)>"
            case is LineBreak: return "<br\(a)>"
            case is SoftBreak: return "\n"
            case is ThematicBreak: return "<hr\(a)>"
            case let table as Markdown.Table:
                func row(_ cells: MarkupChildren, tag: String) -> String {
                    "<tr>" + cells.enumerated().map { index, cell in
                        let alignment = index < table.columnAlignments.count ? table.columnAlignments[index] : nil
                        let align = alignment.map { String(describing: $0) } ?? "left"
                        return "<\(tag) data-align=\"\(align)\"\(attrs(cell))>\(children(cell))</\(tag)>"
                    }.joined() + "</tr>"
                }
                return "<div class=\"table-scroll\"\(a)><table><thead>\(row(table.head.children, tag: "th"))</thead><tbody>" + table.body.children.map { row($0.children, tag: "td") }.joined() + "</tbody></table></div>"
            case let raw as HTMLBlock: return "<pre\(a)>\(escape(raw.rawHTML))</pre>"
            case let raw as InlineHTML: return leaf(node, text: raw.rawHTML)
            default: return children(node)
            }
        }
        let html = renderNode(document)
        return RenderedDocument(html: html, headings: headings)
    }
}
