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
        let document = Document(parsing: source)
        let lines = source.components(separatedBy: "\n")
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
        func leaf(_ node: Markup, text: String, tag: String = "span") -> String {
            var mapped = span(node)
            if let range = mapped, range.isValid(in: source) {
                let slice = (source as NSString).substring(with: range.nsRange) as NSString
                let found = slice.range(of: text, options: .literal)
                if found.location != NSNotFound { mapped = TextSpan(location: range.location + found.location, length: found.length) }
            }
            guard let range = mapped, range.isValid(in: source) else { return "<\(tag)>\(escape(text))</\(tag)>" }
            let precise = (source as NSString).substring(with: range.nsRange) == text
            return "<\(tag) data-leaf=\"true\" data-start=\"\(range.location)\" data-end=\"\(range.location + range.length)\" data-precise=\"\(precise ? 1 : 0)\">\(escape(text))</\(tag)>"
        }
        func safeLink(_ value: String) -> String? {
            guard !value.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 } == true }) else { return nil }
            let scheme = URL(string: value)?.scheme?.lowercased()
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
                return "<pre\(a)><code data-language=\"\(escape(code.language ?? ""))\">\(leaf(node, text: code.code))</code></pre>"
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
