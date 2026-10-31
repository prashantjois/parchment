import Foundation

public struct SearchOccurrence: Equatable, Sendable {
    public var range: NSRange
    public var line: Int
    public var preview: String
}

public enum DocumentSearch {
    public static func find(_ query: String, in text: String, caseSensitive: Bool = false, ignoreDiacritics: Bool = false) -> [SearchOccurrence] {
        guard !query.isEmpty else { return [] }
        let source = text as NSString
        var options: NSString.CompareOptions = []
        if !caseSensitive { options.insert(.caseInsensitive) }
        if ignoreDiacritics { options.insert(.diacriticInsensitive) }
        var ranges: [NSRange] = [], offset = 0
        while offset < source.length {
            let range = source.range(of: query, options: options, range: NSRange(location: offset, length: source.length - offset))
            guard range.location != NSNotFound, range.length > 0 else { break }
            ranges.append(range)
            offset = NSMaxRange(range)
        }
        return occurrences(ranges, in: text)
    }

    fileprivate static func occurrences(_ ranges: [NSRange], in text: String) -> [SearchOccurrence] {
        let source = text as NSString
        let units = Array(text.utf16)
        var lineStarts = [0]
        for (index, unit) in units.enumerated() {
            if unit == 10 || (unit == 13 && (index + 1 == units.count || units[index + 1] != 10)) {
                lineStarts.append(index + 1)
            }
        }
        var results: [SearchOccurrence] = [], line = 0
        for range in ranges {
            while line + 1 < lineStarts.count && lineStarts[line + 1] <= range.location { line += 1 }
            let lineRange = source.lineRange(for: NSRange(location: range.location, length: 0))
            let start = max(lineRange.location, range.location - 40)
            let end = min(NSMaxRange(lineRange), range.location + max(range.length, 140))
            let context = source.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
            let preview = (start > lineRange.location ? "…" : "") + source.substring(with: context).trimmingCharacters(in: .whitespacesAndNewlines)
            results.append(SearchOccurrence(range: range, line: line + 1, preview: preview))
        }
        return results
    }
}

public enum SearchPatternError: LocalizedError {
    case invalidPattern(String), timedOut
    public var errorDescription: String? {
        switch self {
        case .invalidPattern(let detail): return "Invalid regular expression: \(detail)"
        case .timedOut: return "This regular expression took too long. Try a more specific pattern."
        }
    }
}

public struct SearchPattern {
    private let regex: NSRegularExpression
    private let ignoreDiacritics: Bool

    public init(_ pattern: String, caseSensitive: Bool = false, ignoreDiacritics: Bool = false) throws {
        self.ignoreDiacritics = ignoreDiacritics
        let pattern = ignoreDiacritics ? Self.fold(pattern) : pattern
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if !caseSensitive { options.insert(.caseInsensitive) }
        do { regex = try NSRegularExpression(pattern: pattern, options: options) }
        catch { throw SearchPatternError.invalidPattern(error.localizedDescription) }
    }

    public func find(in text: String) throws -> [SearchOccurrence] {
        try Task.checkCancellation()
        let folded = ignoreDiacritics ? try FoldedText(text) : nil
        let searchable = folded?.text ?? text
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        var ranges: [NSRange] = [], seen = Set<NSRange>(), timedOut = false, cancelled = false
        regex.enumerateMatches(in: searchable, options: [.reportProgress], range: NSRange(location: 0, length: searchable.utf16.count)) { match, _, stop in
            if Task.isCancelled { cancelled = true; stop.pointee = true; return }
            if ContinuousClock.now >= deadline { timedOut = true; stop.pointee = true; return }
            guard let match else { return }
            let range = folded?.originalRange(match.range) ?? match.range
            if seen.insert(range).inserted { ranges.append(range) }
        }
        if cancelled { throw CancellationError() }
        if timedOut { throw SearchPatternError.timedOut }
        return DocumentSearch.occurrences(ranges, in: text)
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    private struct FoldedText {
        var text = ""
        var starts: [Int] = []
        var ends: [Int] = []
        var originalLength = 0
        init(_ source: String) throws {
            for (index, character) in source.enumerated() {
                if index % 256 == 0 { try Task.checkCancellation() }
                let original = String(character), folded = SearchPattern.fold(original)
                let originalCount = original.utf16.count, foldedCount = folded.utf16.count
                let unchanged = original == folded && originalCount == foldedCount
                for offset in 0..<foldedCount {
                    starts.append(originalLength + (unchanged ? offset : 0))
                    ends.append(originalLength + (unchanged ? offset + 1 : originalCount))
                }
                text += folded; originalLength += originalCount
            }
        }
        func originalRange(_ range: NSRange) -> NSRange {
            if range.length == 0 {
                return NSRange(location: range.location < starts.count ? starts[range.location] : originalLength, length: 0)
            }
            let start = starts[range.location], end = ends[NSMaxRange(range) - 1]
            return NSRange(location: start, length: end - start)
        }
    }
}
