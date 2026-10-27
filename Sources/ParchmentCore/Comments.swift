import Foundation
import CryptoKit

public struct TextSpan: Codable, Equatable {
    public var location: Int
    public var length: Int
    public init(location: Int, length: Int) { self.location = location; self.length = length }
    public var nsRange: NSRange { NSRange(location: location, length: length) }
    public func isValid(in text: String) -> Bool {
        location >= 0 && length > 0 && location <= (text as NSString).length && length <= (text as NSString).length - location
    }
}

public func sourceHash(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

public struct CommentAnchor: Codable, Equatable {
    public var range: TextSpan
    public var quote: String
    public var prefix: String
    public var suffix: String
    public var sourceSHA256: String
    public var startLine: Int
    public var endLine: Int

    public init(text: String, range: TextSpan) {
        let ns = text as NSString
        self.range = range
        quote = ns.substring(with: range.nsRange)
        // Swift characters preserve complete Unicode sequences in context snippets.
        prefix = String(ns.substring(to: range.location).suffix(64))
        suffix = String(ns.substring(from: range.location + range.length).prefix(64))
        sourceSHA256 = sourceHash(text)
        startLine = ns.substring(to: range.location).utf8.filter { $0 == 10 }.count + 1
        endLine = ns.substring(to: range.location + max(0, range.length - 1)).utf8.filter { $0 == 10 }.count + 1
    }

    public func locate(in text: String) -> AnchorMatch {
        let ns = text as NSString
        if sourceHash(text) == sourceSHA256, range.isValid(in: text), ns.substring(with: range.nsRange) == quote {
            return AnchorMatch(state: .exact, range: range)
        }
        guard !quote.isEmpty else { return AnchorMatch(state: .orphaned) }
        var matches: [NSRange] = []
        var offset = 0
        while offset <= ns.length {
            let found = ns.range(of: quote, options: .literal, range: NSRange(location: offset, length: ns.length - offset))
            if found.location == NSNotFound { break }
            matches.append(found)
            // Overlapping occurrences also make an anchor ambiguous.
            offset = found.location + 1
        }
        if matches.count == 1 {
            return AnchorMatch(state: .moved, range: TextSpan(location: matches[0].location, length: matches[0].length))
        }
        let contextual = matches.filter {
            let before = ns.substring(to: $0.location)
            let after = ns.substring(from: $0.location + $0.length)
            return (!prefix.isEmpty || !suffix.isEmpty) && before.hasSuffix(prefix) && after.hasPrefix(suffix)
        }
        if contextual.count == 1 {
            return AnchorMatch(state: .moved, range: TextSpan(location: contextual[0].location, length: contextual[0].length))
        }
        return AnchorMatch(state: matches.isEmpty ? .orphaned : .ambiguous)
    }
}

public struct AnchorMatch: Codable, Equatable {
    public enum State: String, Codable { case exact, moved, ambiguous, orphaned, file }
    public var state: State
    public var range: TextSpan?
    public init(state: State, range: TextSpan? = nil) { self.state = state; self.range = range }
}

public struct CommentEvent: Codable, Identifiable {
    public enum Kind: String, Codable { case comment, reply, resolve, reopen, reanchor }
    public var id: UUID
    public var kind: Kind
    public var author: String
    public var timestamp: Date
    public var body: String?
    public var anchor: CommentAnchor?
    public var reviewID: UUID?
    public var publishedAt: Date?
    public var origin: String?
    public var operationID: String?
    public var isPending: Bool { reviewID != nil && publishedAt == nil }
    public init(kind: Kind, author: String, body: String? = nil, anchor: CommentAnchor? = nil, reviewID: UUID? = nil) {
        id = UUID(); self.kind = kind; self.author = author; timestamp = Date(); self.body = body; self.anchor = anchor; self.reviewID = reviewID
    }
}

public struct CommentThread: Codable, Identifiable {
    public enum Scope: String, Codable { case file }
    public var scope: Scope?
    public var isFileLevel: Bool { scope == .file }
    public var id: UUID
    public var originalAnchor: CommentAnchor
    public var events: [CommentEvent]
    public var reviewID: UUID?
    public var publishedAt: Date?
    public var isPending: Bool { reviewID != nil && publishedAt == nil }
    public init(anchor: CommentAnchor, body: String, author: String, reviewID: UUID? = nil, fileLevel: Bool = false) {
        id = UUID(); originalAnchor = anchor; self.reviewID = reviewID
        scope = fileLevel ? .file : nil
        events = [CommentEvent(kind: .comment, author: author, body: body, reviewID: reviewID)]
    }
    public var anchor: CommentAnchor { events.last(where: { $0.kind == .reanchor })?.anchor ?? originalAnchor }
    public func locate(in text: String) -> AnchorMatch { isFileLevel ? AnchorMatch(state: .file) : anchor.locate(in: text) }
    public var isResolved: Bool { events.last(where: { $0.kind == .resolve || $0.kind == .reopen })?.kind == .resolve }
    public var messages: [CommentEvent] { events.filter { $0.kind == .comment || $0.kind == .reply } }
}

public struct CommentReview: Codable, Identifiable {
    public var id: UUID
    public var author: String
    public var startedAt: Date
    public var submittedAt: Date?
    public var discardedAt: Date?
    public var summary: String?
    public var isPending: Bool { submittedAt == nil && discardedAt == nil }
    public init(author: String) { id = UUID(); self.author = author; startedAt = Date() }
}

public struct CommentFile: Codable {
    public var formatVersion = 2
    public var document: String
    public var documentID: UUID?
    public var threads: [CommentThread]
    public var reviews: [CommentReview]?
    public var activeReview: CommentReview? { reviews?.last(where: \.isPending) }
    public var pendingCount: Int { threads.flatMap(\.messages).filter(\.isPending).count }
    public var encodingVersion: Int { max(formatVersion, threads.contains(where: \.isFileLevel) ? 3 : 2) }
    public init(document: String, threads: [CommentThread] = []) { self.document = document; self.threads = threads }
    @discardableResult public mutating func startReview(author: String) -> UUID {
        if let activeReview { return activeReview.id }
        let review = CommentReview(author: author)
        if reviews == nil { reviews = [] }; reviews!.append(review)
        formatVersion = encodingVersion
        return review.id
    }
    @discardableResult public mutating func submitReview(summary: String = "", at date: Date = Date()) -> Bool {
        guard let review = activeReview, pendingCount > 0 || !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let index = reviews?.firstIndex(where: { $0.id == review.id }) else { return false }
        for threadIndex in threads.indices {
            if threads[threadIndex].reviewID == review.id && threads[threadIndex].isPending { threads[threadIndex].publishedAt = date }
            for eventIndex in threads[threadIndex].events.indices where threads[threadIndex].events[eventIndex].reviewID == review.id && threads[threadIndex].events[eventIndex].isPending {
                threads[threadIndex].events[eventIndex].publishedAt = date
            }
        }
        reviews![index].summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        reviews![index].submittedAt = date
        return true
    }
    public mutating func discardReview() {
        guard let review = activeReview, let index = reviews?.firstIndex(where: { $0.id == review.id }) else { return }
        threads.removeAll { $0.reviewID == review.id && $0.isPending }
        for index in threads.indices { threads[index].events.removeAll { $0.reviewID == review.id && $0.isPending } }
        reviews![index].discardedAt = Date()
    }
    public static func companionURL(for url: URL) -> URL { URL(fileURLWithPath: url.path + ".comments.json") }
    public static func read(for url: URL) throws -> CommentFile {
        let companion = companionURL(for: url)
        guard FileManager.default.fileExists(atPath: companion.path) else { return CommentFile(document: url.lastPathComponent) }
        var value = try decoder.decode(CommentFile.self, from: Data(contentsOf: companion))
        guard [1, 2, 3].contains(value.formatVersion) else { throw CommentError.unsupportedVersion }
        guard value.document == url.lastPathComponent || value.documentID != nil else { throw CommentError.wrongDocument }
        value.document = url.lastPathComponent
        value.formatVersion = value.encodingVersion
        return value
    }
    public func write(for url: URL) throws {
        var updated = self
        updated.formatVersion = encodingVersion
        updated.document = url.lastPathComponent
        try Self.encoder.encode(updated).write(to: Self.companionURL(for: url), options: .atomic)
    }
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601; return encoder
    }
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }
    public func export(text: String, path: String, includeResolved: Bool) throws -> Data {
        struct ThreadExport: Encodable { let thread: CommentThread; let resolved: Bool; let currentAnchor: AnchorMatch }
        struct Export: Encodable {
            let formatVersion: Int
            let documentPath: String
            let sourceSHA256: String
            let sourceText: String
            let offsetEncoding: String
            let threads: [ThreadExport]
            let reviews: [CommentReview]
        }
        return try Self.encoder.encode(Export(formatVersion: encodingVersion, documentPath: path, sourceSHA256: sourceHash(text), sourceText: text,
            offsetEncoding: "UTF-16 code units; zero-based location, exclusive end; original line endings",
            threads: threads.filter { !$0.isPending && (includeResolved || !$0.isResolved) }.map {
                var published = $0
                published.events.removeAll(where: \.isPending)
                return ThreadExport(thread: published, resolved: published.isResolved, currentAnchor: published.locate(in: text))
            }, reviews: (reviews ?? []).filter { $0.submittedAt != nil }))
    }
}

public enum CommentError: LocalizedError {
    case unsupportedVersion, wrongDocument
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "This comment file uses an unsupported format version. It was not changed."
        case .wrongDocument: return "The companion file belongs to another document. It was not changed."
        }
    }
}

public enum ViewMode: String, Codable, CaseIterable { case raw, rendered, split }
public enum RightPanel: String, Codable { case contents, comments }
public struct FileLayout: Codable, Equatable {
    public var mode: ViewMode = .raw
    public var previousSingleMode: ViewMode = .raw
    public var showFiles = false
    public var showRight = false
    public var rightPanel: RightPanel = .contents
    public var filesWidth: Double = 230
    public var rightWidth: Double = 280
    public var splitFraction: Double = 0.5
    public var cursorLocation = 0
    public var sourceScroll: Double = 0
    public var renderedScroll: Double = 0
    public init() {}
    public mutating func toggleSplit() {
        if mode == .split { mode = previousSingleMode }
        else { previousSingleMode = mode; mode = .split }
    }
    public mutating func toggleRendered() {
        showSinglePane(mode == .rendered ? .raw : .rendered)
    }
    public mutating func showSinglePane(_ selected: ViewMode) {
        guard selected != .split else { return }
        mode = selected; previousSingleMode = selected
    }
}
