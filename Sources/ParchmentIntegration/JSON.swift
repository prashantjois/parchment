import Foundation
import ParchmentCore

public enum JSON: Codable, Equatable, Sendable {
    case object([String: JSON]), array([JSON]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let x = try? value.decode(Bool.self) { self = .bool(x) }
        else if let x = try? value.decode(String.self) { self = .string(x) }
        else if let x = try? value.decode(Double.self) { self = .number(x) }
        else if let x = try? value.decode([String: JSON].self) { self = .object(x) }
        else { self = .array(try value.decode([JSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let x): try value.encode(x)
        case .string(let x): try value.encode(x)
        case .number(let x): try value.encode(x)
        case .object(let x): try value.encode(x)
        case .array(let x): try value.encode(x)
        }
    }
    public subscript(_ key: String) -> JSON { if case .object(let x) = self { return x[key] ?? .null }; return .null }
    public var string: String? { if case .string(let x) = self { return x }; return nil }
    public var int: Int? { if case .number(let x) = self, x.isFinite, x >= Double(Int.min), x < Double(Int.max), x.rounded() == x { return Int(x) }; return nil }
    public var bool: Bool? { if case .bool(let x) = self { return x }; return nil }
    public var array: [JSON] { if case .array(let x) = self { return x }; return [] }
    public var object: [String: JSON] { if case .object(let x) = self { return x }; return [:] }
    public func require(_ key: String) throws -> String {
        guard let value = self[key].string, !value.isEmpty else { throw BridgeError("INVALID_ARGUMENT", "\(key) must be a nonempty string.") }; return value
    }
    public func requireInt(_ key: String) throws -> Int {
        guard let value = self[key].int else { throw BridgeError("INVALID_ARGUMENT", "\(key) must be an integer.") }; return value
    }
    public func data() throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(self) }
    public func text() -> String { String(data: (try? data()) ?? Data(), encoding: .utf8) ?? "null" }
    public static func parse(_ data: Data) throws -> JSON { try JSONDecoder().decode(JSON.self, from: data) }
    public static func encode<T: Encodable>(_ value: T) throws -> JSON { try parse(CommentFile.encoder.encode(value)) }
    public static func integer(_ value: Int) -> JSON { .number(Double(value)) }
}

public struct BridgeError: Error, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public let details: JSON
    public init(_ code: String, _ message: String, details: JSON = .null) { self.code = code; self.message = message; self.details = details }
    public var errorDescription: String? { "\(code): \(message)" }
    public var json: JSON { .object(["code": .string(code), "message": .string(message), "details": details]) }
    public static func wrap(_ error: Error) -> BridgeError {
        error as? BridgeError ?? BridgeError("INTERNAL_ERROR", error.localizedDescription)
    }
}

public enum IntegrationPaths {
    public static var directory: URL {
        if let path = ProcessInfo.processInfo.environment["PARCHMENT_DATA_DIR"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Parchment", isDirectory: true)
    }
    public static func socketDirectory(for directory: URL) -> URL {
        URL(fileURLWithPath: "/tmp/parchment-\(getuid())-\(sourceHash(directory.standardizedFileURL.path).prefix(16))", isDirectory: true)
    }
}
