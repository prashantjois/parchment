import Foundation
import ParchmentCore

public enum DocumentPatch {
    public static func apply(_ args: JSON, to text: String) throws -> String {
        let revision = sourceHash(text)
        guard try args.require("expected_revision") == revision else {
            throw BridgeError("REVISION_CONFLICT", "The document changed. Read the latest document and reconsider the patch.", details: .object(["current_revision": .string(revision)]))
        }
        let edits = args["edits"].array
        guard !edits.isEmpty, edits.count <= 1000 else { throw BridgeError("INVALID_ARGUMENT", "Provide between 1 and 1000 edits.") }
        let source = text as NSString
        func isBoundary(_ offset: Int) -> Bool {
            offset == source.length || source.rangeOfComposedCharacterSequence(at: offset).location == offset
        }
        var replacements: [(NSRange, String)] = []
        for edit in edits {
            guard let old = edit["old_text"].string, let new = edit["new_text"].string else { throw BridgeError("INVALID_ARGUMENT", "Every edit needs old_text and new_text strings.") }
            var start = edit["start"].int
            if start == nil {
                guard !old.isEmpty else { throw BridgeError("INVALID_ARGUMENT", "Insertions require a zero-based UTF-16 start offset.") }
                let match = source.range(of: old, options: .literal)
                guard match.location != NSNotFound else { throw BridgeError("PATCH_TARGET_MISSING", "The expected text does not occur in the document.") }
                let remaining = NSRange(location: match.location + 1, length: source.length - match.location - 1)
                guard source.range(of: old, options: .literal, range: remaining).location == NSNotFound else { throw BridgeError("PATCH_TARGET_AMBIGUOUS", "The expected text occurs more than once. Supply an exact start offset.") }
                start = match.location
            }
            let length = (old as NSString).length, location = start!
            guard location >= 0, location <= source.length, length <= source.length - location else { throw BridgeError("INVALID_RANGE", "The edit is outside the document.") }
            let range = NSRange(location: location, length: length)
            guard isBoundary(location), isBoundary(location + length), Range(range, in: text) != nil, source.substring(with: range).utf8.elementsEqual(old.utf8) else { throw BridgeError("PATCH_TARGET_MISMATCH", "The selected source does not exactly match old_text or splits a Unicode character.") }
            replacements.append((range, new))
        }
        replacements.sort { $0.0.location < $1.0.location }
        for index in replacements.indices.dropFirst() {
            let previous = replacements[index - 1].0, next = replacements[index].0
            guard next.location > previous.location, next.location >= NSMaxRange(previous) else { throw BridgeError("OVERLAPPING_EDITS", "Edits must not overlap or share an insertion point.") }
        }
        let result = NSMutableString(string: text)
        for (range, new) in replacements.reversed() { result.replaceCharacters(in: range, with: new) }
        return result as String
    }
}

public enum FeedbackPublication {
    public static func sync(documentID: String, text: String, comments: CommentFile, registry: IntegrationRegistry) throws {
        let published = comments.threads.filter { !$0.isPending }
        func threadValue(_ thread: CommentThread) throws -> JSON {
            var value = thread; value.events.removeAll(where: \.isPending)
            return .object(["thread": try JSON.encode(value), "current_anchor": try JSON.encode(value.anchor.locate(in: text))])
        }
        for thread in published {
            for event in thread.events where !event.isPending && event.reviewID == nil && event.origin != "agent" && !event.author.hasPrefix("🤖") && [.comment, .reply].contains(event.kind) {
                try registry.enqueue(documentID: documentID, eventID: event.id.uuidString, payload: .object([
                    "kind": .string(event.kind == .comment ? "comment_published" : "reply_published"), "document_id": .string(documentID), "revision": .string(sourceHash(text)), "event": try JSON.encode(event), "thread": try threadValue(thread)
                ]))
            }
        }
        for review in comments.reviews ?? [] where review.submittedAt != nil {
            let threads = try published.filter { $0.events.contains { $0.reviewID == review.id && !$0.isPending } }.map(threadValue)
            try registry.enqueue(documentID: documentID, eventID: review.id.uuidString, payload: .object([
                "kind": .string("review_submitted"), "document_id": .string(documentID), "revision": .string(sourceHash(text)), "review": try JSON.encode(review), "threads": .array(threads)
            ]))
        }
    }
}
