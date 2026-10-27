import Foundation

/// A local document navigation request. Links never carry agent credentials or edits.
public struct DocumentLink {
    public let fileURL: URL
    public let line: Int?

    public init(url: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "parchment", url.absoluteString.lowercased().hasPrefix("parchment://"),
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.fragment == nil else {
            throw DocumentLinkError.invalidFormat
        }
        let items = parts.queryItems ?? []
        let path: String
        if parts.host?.lowercased() == "open", parts.path.isEmpty || parts.path == "/" {
            // Keep existing query-style links working.
            guard items.allSatisfy({ ["path", "line"].contains($0.name) }),
                  items.filter({ $0.name == "path" }).count == 1,
                  let value = items.first(where: { $0.name == "path" })?.value else {
                throw DocumentLinkError.invalidFormat
            }
            path = value
        } else {
            guard items.allSatisfy({ $0.name == "line" }) else { throw DocumentLinkError.invalidFormat }
            let root = parts.host ?? ""
            guard !root.contains("/") else { throw DocumentLinkError.invalidPath }
            path = root.isEmpty ? parts.path : "/" + root + parts.path
        }
        guard items.filter({ $0.name == "line" }).count <= 1 else { throw DocumentLinkError.invalidFormat }
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw DocumentLinkError.invalidPath
        }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        guard ["md", "markdown", "mdown", "txt"].contains(file.pathExtension.lowercased()) else {
            throw DocumentLinkError.unsupportedFile
        }
        if let item = items.first(where: { $0.name == "line" }) {
            guard let value = item.value, !value.isEmpty,
                  value.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(value), number > 0 else {
                throw DocumentLinkError.invalidLine
            }
            line = number
        } else { line = nil }
        fileURL = file
    }

    public static func url(for file: URL, line: Int? = nil) throws -> URL {
        guard file.isFileURL else { throw DocumentLinkError.invalidPath }
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
        guard let path = file.standardizedFileURL.path.addingPercentEncoding(withAllowedCharacters: unreserved),
              let result = URL(string: "parchment://" + path.dropFirst() + (line.map { "?line=\($0)" } ?? "")) else {
            throw DocumentLinkError.invalidFormat
        }
        _ = try DocumentLink(url: result)
        return result
    }

    /// One-based lines with native CR/LF handling. Oversized line numbers select EOF.
    public func location(in text: String) -> Int? {
        guard let line else { return nil }
        let source = text as NSString
        var current = 1, offset = 0
        while current < line && offset < source.length {
            offset = NSMaxRange(source.lineRange(for: NSRange(location: offset, length: 0)))
            current += 1
        }
        return offset
    }
}

public enum DocumentLinkError: LocalizedError {
    case invalidFormat, invalidPath, invalidLine, unsupportedFile
    public var errorDescription: String? {
        switch self {
        case .invalidFormat: return "Use parchment://Users/me/notes.md with an optional ?line=42."
        case .invalidPath: return "Parchment links require an absolute local file path without control characters."
        case .invalidLine: return "The line number must be a positive integer."
        case .unsupportedFile: return "Parchment links can open Markdown and plain-text files only."
        }
    }
}
