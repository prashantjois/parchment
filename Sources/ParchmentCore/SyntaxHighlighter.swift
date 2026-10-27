import Foundation

public struct SyntaxToken {
    public let range: NSRange
    public let kind: String?
}

/// Local lexical highlighting. Unknown languages retain their original plain text.
public enum SyntaxHighlighter {
    private struct Rules {
        let expression: NSRegularExpression
        let keywords: Set<String>
        let identifiers: Bool
        let caseInsensitive: Bool
        init(keywords: String, comments: String, strings: String = #""(?:\\[\s\S]|[^"\\])*(?:"|$)|'(?:\\[\s\S]|[^'\\])*(?:'|$)"#,
             identifiers: Bool = true, caseInsensitive: Bool = false) {
            self.keywords = Set(keywords.split(separator: " ").map(String.init))
            self.identifiers = identifiers; self.caseInsensitive = caseInsensitive
            let numbers = #"\b(?:0[xX][\da-fA-F_]+|0[bB][01_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?[\d_]+)?)(?:[uUlLfFdD]+)?\b"#
            expression = try! NSRegularExpression(pattern: "(?<comment>\(comments))|(?<string>\(strings))|(?<number>\(numbers))|(?<word>[\\p{L}_$][\\p{L}\\p{N}_$]*)")
        }
    }
    private static let cComments = #"//[^\r\n]*|/\*[\s\S]*?(?:\*/|$)"#
    private static let tripleStrings = #""""[\s\S]*?(?:"""|$)|'''[\s\S]*?(?:'''|$)|"(?:\\[\s\S]|[^"\\])*(?:"|$)|'(?:\\[\s\S]|[^'\\])*(?:'|$)"#
    private static let rules: [String: Rules] = [
        "swift": Rules(keywords: "actor any as associatedtype async await break case catch class continue convenience default defer deinit didSet do dynamic else enum extension fallthrough false fileprivate final for func get guard if import in indirect infix init inout internal is lazy let mutating nil nonisolated nonmutating open operator optional override postfix precedencegroup prefix private protocol public repeat required rethrows return self Self set some static struct subscript super switch throw throws true try typealias unowned var weak where while willSet", comments: cComments, strings: tripleStrings),
        "kotlin": Rules(keywords: "abstract actual annotation as break by case catch class companion const constructor continue crossinline data delegate do dynamic else enum expect external false field file final finally for fun get if import in infix init inline inner interface internal is lateinit noinline null object open operator out override package param private property protected public receiver reified return sealed set setparam super suspend tailrec this throw true try typealias typeof val value var vararg when where while", comments: cComments, strings: tripleStrings),
        "java": Rules(keywords: "abstract assert boolean break byte case catch char class const continue default do double else enum extends false final finally float for goto if implements import instanceof int interface long native new null package private protected public record return short static strictfp super switch synchronized this throw throws transient true try var void volatile while yield", comments: cComments, strings: tripleStrings),
        "javascript": Rules(keywords: "as async await break case catch class const continue debugger default delete do else export extends false finally for from function get if import in instanceof let new null of return set static super switch this throw true try typeof undefined var void while with yield", comments: cComments,
                            strings: #"`(?:\\[\s\S]|[^`\\])*(?:`|$)|"(?:\\[\s\S]|[^"\\])*(?:"|$)|'(?:\\[\s\S]|[^'\\])*(?:'|$)"#),
        "typescript": Rules(keywords: "abstract any as asserts async await bigint boolean break case catch class const constructor continue declare default delete do else enum export extends false finally for from function get if implements import in infer instanceof interface is keyof let namespace never new null number object of private protected public readonly require return set static string super switch symbol this throw true try type typeof undefined unique unknown var void while with yield", comments: cComments,
                            strings: #"`(?:\\[\s\S]|[^`\\])*(?:`|$)|"(?:\\[\s\S]|[^"\\])*(?:"|$)|'(?:\\[\s\S]|[^'\\])*(?:'|$)"#),
        "python": Rules(keywords: "and as assert async await break case class continue def del elif else except False finally for from global if import in is lambda match None nonlocal not or pass raise return True try while with yield", comments: #"#[^\r\n]*"#, strings: tripleStrings),
        "json": Rules(keywords: "true false null", comments: #"(?!)"#, strings: #""(?:\\[\s\S]|[^"\\])*(?:"|$)"#, identifiers: false),
        "bash": Rules(keywords: "if then else elif fi for while in do done case esac function select until time coproc", comments: #"(?<!\S)#[^\r\n]*"#, identifiers: false),
        "sql": Rules(keywords: "all alter and as asc begin between by case check column commit constraint create cross database default delete desc distinct drop else end exists false foreign from full group having in index inner insert into is join key left like limit not null offset on or order outer primary references right rollback select set table then true union unique update using values view when where with", comments: #"--[^\r\n]*|/\*[\s\S]*?(?:\*/|$)"#,
                     strings: #"'(?:''|[^'])*(?:'|$)|"(?:""|[^"])*(?:"|$)"#, identifiers: false, caseInsensitive: true),
        "yaml": Rules(keywords: "true false null yes no on off", comments: #"(?<!\S)#[^\r\n]*"#, identifiers: false, caseInsensitive: true)
    ]
    private static let aliases = ["js":"javascript", "mjs":"javascript", "cjs":"javascript", "ts":"typescript", "kt":"kotlin", "kts":"kotlin", "py":"python", "sh":"bash", "shell":"bash", "zsh":"bash", "yml":"yaml"]

    public static func tokens(in code: String, language: String) -> [SyntaxToken] {
        let source = code as NSString, length = source.length
        let name = language.split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() } ?? ""
        guard let rule = rules[aliases[name] ?? name], length <= 2_000_000 else {
            return [SyntaxToken(range: NSRange(location: 0, length: length), kind: nil)]
        }
        var tokens: [SyntaxToken] = [], offset = 0
        rule.expression.enumerateMatches(in: code, range: NSRange(location: 0, length: length)) { match, _, _ in
            guard let match else { return }
            var kind: String?
            for candidate in ["comment", "string", "number"] where match.range(withName: candidate).location != NSNotFound { kind = candidate }
            if kind == nil {
                let word = source.substring(with: match.range)
                if rule.keywords.contains(rule.caseInsensitive ? word.lowercased() : word) { kind = "keyword" }
                else if rule.identifiers {
                    var next = NSMaxRange(match.range)
                    while next < length, let scalar = UnicodeScalar(source.character(at: next)), CharacterSet.whitespacesAndNewlines.contains(scalar) { next += 1 }
                    if next < length && source.character(at: next) == 40 { kind = "function" }
                    else if word.first?.isUppercase == true { kind = "type" }
                }
            }
            guard let kind else { return }
            if match.range.location > offset { tokens.append(SyntaxToken(range: NSRange(location: offset, length: match.range.location - offset), kind: nil)) }
            tokens.append(SyntaxToken(range: match.range, kind: kind)); offset = NSMaxRange(match.range)
        }
        if offset < length { tokens.append(SyntaxToken(range: NSRange(location: offset, length: length - offset), kind: nil)) }
        return tokens
    }
}
