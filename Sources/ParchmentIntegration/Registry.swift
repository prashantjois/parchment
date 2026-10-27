import Foundation
import Darwin
import CSQLite
import ParchmentCore

/// SQLite serializes ownership changes across MCP processes. The app alone
/// performs document mutations; credentials are never returned by list tools.
public final class IntegrationRegistry: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    public let directory: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(directory: URL = IntegrationPaths.directory) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("integration.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw BridgeError("REGISTRY_UNAVAILABLE", "Cannot open the document registry.") }
        chmod(path, 0o600); sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA journal_mode=WAL"); try execute("PRAGMA synchronous=FULL"); try execute("PRAGMA foreign_keys=ON")
        let version = try rows("PRAGMA user_version").first?["user_version"]?.int ?? 0
        guard version <= 1 else { throw BridgeError("REGISTRY_VERSION_UNSUPPORTED", "This registry requires a newer Parchment version.") }
        try transaction {
            try execute("CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, token_hash TEXT NOT NULL UNIQUE, client TEXT NOT NULL, label TEXT NOT NULL, conversation_id TEXT, last_seen REAL NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS documents (id TEXT PRIMARY KEY, path TEXT UNIQUE, identity TEXT, title TEXT NOT NULL, updated REAL NOT NULL)")
            try execute("CREATE INDEX IF NOT EXISTS document_identity ON documents(identity)")
            try execute("CREATE TABLE IF NOT EXISTS bindings (document_id TEXT PRIMARY KEY REFERENCES documents(id), binding_id TEXT NOT NULL UNIQUE, session_id TEXT REFERENCES sessions(id), generation INTEGER NOT NULL, acknowledged INTEGER NOT NULL DEFAULT 0, delivered INTEGER NOT NULL DEFAULT 0, last_activity REAL NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS feedback (sequence INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT NOT NULL, document_id TEXT NOT NULL REFERENCES documents(id), payload TEXT NOT NULL, created REAL NOT NULL, UNIQUE(document_id,event_id))")
            try execute("CREATE INDEX IF NOT EXISTS feedback_document_sequence ON feedback(document_id, sequence)")
            try execute("CREATE TABLE IF NOT EXISTS operations (operation_id TEXT PRIMARY KEY, document_id TEXT NOT NULL, binding_id TEXT NOT NULL, generation INTEGER NOT NULL, request_hash TEXT NOT NULL, before_revision TEXT, after_revision TEXT, result TEXT NOT NULL, state TEXT NOT NULL)")
            // Delivery is additive. Existing document/session tables remain compatible.
            try execute("CREATE TABLE IF NOT EXISTS receivers (session_id TEXT PRIMARY KEY REFERENCES sessions(id), receiver_id TEXT NOT NULL UNIQUE, agent_session_id TEXT NOT NULL, executable TEXT NOT NULL, arguments TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS notifications (delivery_id TEXT PRIMARY KEY, receiver_id TEXT NOT NULL REFERENCES receivers(receiver_id) ON DELETE CASCADE, document_id TEXT NOT NULL REFERENCES documents(id), binding_id TEXT NOT NULL, generation INTEGER NOT NULL, sequence INTEGER NOT NULL REFERENCES feedback(sequence), attempts INTEGER NOT NULL DEFAULT 0, next_attempt REAL NOT NULL DEFAULT 0, lease_id TEXT, lease_until REAL NOT NULL DEFAULT 0, accepted_at REAL, last_error TEXT, UNIQUE(receiver_id,binding_id,sequence))")
            try execute("CREATE INDEX IF NOT EXISTS notification_due ON notifications(accepted_at,next_attempt,lease_until)")
            try execute("PRAGMA user_version=1")
        }
    }
    deinit { sqlite3_close(db) }
    private func prepare(_ sql: String, _ values: [JSON]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        for (index, value) in values.enumerated() {
            let slot = Int32(index + 1)
            switch value {
            case .null: sqlite3_bind_null(statement, slot)
            case .number(let number): sqlite3_bind_double(statement, slot, number)
            case .bool(let flag): sqlite3_bind_int(statement, slot, flag ? 1 : 0)
            default: sqlite3_bind_text(statement, slot, value.string ?? value.text(), -1, transient)
            }
        }
        return statement
    }
    private func databaseError() -> BridgeError { BridgeError("REGISTRY_ERROR", db.map { String(cString: sqlite3_errmsg($0)) } ?? "Registry is closed.") }
    func execute(_ sql: String, _ values: [JSON] = []) throws {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw databaseError() }
    }
    func rows(_ sql: String, _ values: [JSON] = []) throws -> [[String: JSON]] {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        var result: [[String: JSON]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw databaseError() }
            var row: [String: JSON] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_NULL: row[name] = .null
                case SQLITE_INTEGER, SQLITE_FLOAT: row[name] = .number(sqlite3_column_double(statement, index))
                default: row[name] = .string(String(cString: sqlite3_column_text(statement, index)))
                }
            }
            result.append(row)
        }
        return result
    }
    func transaction<T>(_ action: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do { let value = try action(); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private var now: JSON { .number(Date().timeIntervalSince1970) }
    public static func canonicalPath(_ path: String) -> String { URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path }
    private func identity(_ path: String?) -> JSON {
        guard let path else { return .null }; var info = stat()
        guard stat(path, &info) == 0 else { return .null }
        return .string("\(info.st_dev):\(info.st_ino)")
    }
    public func registerDocument(path: String?, preferredID: UUID, title: String) throws -> String {
        try transaction {
            let canonical = path.map(Self.canonicalPath), physical = identity(path.map(Self.canonicalPath))
            var match: [String: JSON]?
            if let canonical { match = try rows("SELECT * FROM documents WHERE path=?", [.string(canonical)]).first }
            if match == nil, physical != .null { match = try rows("SELECT * FROM documents WHERE identity=?", [physical]).first }
            var identifier = match?["id"]?.string ?? preferredID.uuidString
            if match == nil, let previous = try rows("SELECT * FROM documents WHERE id=?", [.string(identifier)]).first,
               let oldPath = previous["path"]?.string, oldPath != canonical, FileManager.default.fileExists(atPath: oldPath) {
                // A copied sidecar must not steal the original document's binding.
                identifier = UUID().uuidString
            }
            try execute("INSERT INTO documents(id,path,identity,title,updated) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET path=excluded.path,identity=excluded.identity,title=excluded.title,updated=excluded.updated", [.string(identifier), canonical.map(JSON.string) ?? .null, physical, .string(title), now])
            return identifier
        }
    }
    public func document(_ id: String) throws -> JSON {
        guard let row = try rows("SELECT id AS document_id,path,title FROM documents WHERE id=?", [.string(id)]).first else { throw BridgeError("DOCUMENT_NOT_FOUND", "No registered document has that ID.") }
        return .object(row)
    }
    public func documentAtPath(_ path: String) throws -> JSON? {
        try rows("SELECT id AS document_id,path,title FROM documents WHERE path=?", [.string(Self.canonicalPath(path))]).first.map(JSON.object)
    }
    public func createSession(client: String, label: String, conversationID: String?) throws -> JSON {
        let id = UUID().uuidString, token = UUID().uuidString + UUID().uuidString
        try execute("INSERT INTO sessions(id,token_hash,client,label,conversation_id,last_seen) VALUES(?,?,?,?,?,?)", [.string(id), .string(sourceHash(token)), .string(client), .string(label), conversationID.map(JSON.string) ?? .null, now])
        return .object(["session_id": .string(id), "session_token": .string(token), "conversation_label": .string(label), "instructions": .string("Keep this session_token in this conversation. Reuse it after reconnecting; do not create a new session for every tool call.")])
    }
    public func session(_ token: String) throws -> JSON {
        guard let row = try rows("SELECT id AS session_id,client,label AS conversation_label,conversation_id FROM sessions WHERE token_hash=?", [.string(sourceHash(token))]).first else { throw BridgeError("INVALID_SESSION", "The session token is invalid. Create a session or reuse the token from the original conversation.") }
        try execute("UPDATE sessions SET last_seen=? WHERE id=? AND last_seen<?", [now, row["session_id"]!, .number(Date().timeIntervalSince1970 - 5)])
        return .object(row)
    }
    public func attachment(_ documentID: String) throws -> JSON {
        guard let row = try rows("SELECT b.session_id,b.generation,b.acknowledged,s.client,s.label,s.last_seen FROM bindings b LEFT JOIN sessions s ON s.id=b.session_id WHERE b.document_id=?", [.string(documentID)]).first, row["session_id"] != .null else { return .object(["status": .string("unattached")]) }
        let queued = try rows("SELECT COUNT(*) AS count FROM feedback WHERE document_id=? AND sequence>?", [.string(documentID), row["acknowledged"] ?? .integer(0)]).first?["count"] ?? .integer(0)
        return .object(["status": .string("attached"), "session_id": row["session_id"]!, "generation": row["generation"]!, "client": row["client"] ?? .null, "conversation_label": row["label"] ?? .null, "last_seen": row["last_seen"] ?? .null, "queued_feedback": queued, "delivery": try receiverStatus(sessionID: row["session_id"]!)])
    }
    public func attach(documentID: String, sessionToken: String) throws -> JSON {
        try transaction {
            _ = try document(documentID)
            let session = try self.session(sessionToken), sessionID = try session.require("session_id")
            let previous = try rows("SELECT * FROM bindings WHERE document_id=?", [.string(documentID)]).first
            if let previous, let owner = previous["session_id"]?.string, owner != sessionID {
                throw BridgeError("DOCUMENT_ALREADY_ATTACHED", "Another conversation owns this document. Request an explicit handoff; attachments never replace another owner.", details: try attachment(documentID))
            }
            if previous?["session_id"]?.string == sessionID { return .object(previous!) }
            let generation = (previous?["generation"]?.int ?? 0) + 1, bindingID = UUID().uuidString
            try execute("INSERT INTO bindings(document_id,binding_id,session_id,generation,last_activity) VALUES(?,?,?,?,?) ON CONFLICT(document_id) DO UPDATE SET binding_id=excluded.binding_id,session_id=excluded.session_id,generation=excluded.generation,delivered=bindings.acknowledged,last_activity=excluded.last_activity", [.string(documentID), .string(bindingID), .string(sessionID), .integer(generation), now])
            return .object(try rows("SELECT * FROM bindings WHERE document_id=?", [.string(documentID)])[0])
        }
    }
    public func validateBinding(_ args: JSON) throws -> JSON {
        let session = try self.session(args.require("session_token"))
        guard let row = try rows("SELECT * FROM bindings WHERE binding_id=?", [.string(args.require("binding_id"))]).first,
              row["session_id"] == session["session_id"], row["generation"]?.int == (try args.requireInt("generation")) else {
            throw BridgeError("STALE_BINDING", "This attachment is no longer owned by this conversation. Old bindings cannot read feedback or modify the document.")
        }
        return .object(row)
    }
    public func handoff(_ args: JSON) throws -> JSON {
        try transaction {
            let binding = try validateBinding(args), target = try args.require("target_session_id")
            guard !(try rows("SELECT id FROM sessions WHERE id=?", [.string(target)])).isEmpty else { throw BridgeError("SESSION_NOT_FOUND", "The receiving conversation must create a session first.") }
            if binding["session_id"].string == target { return binding }
            try execute("UPDATE bindings SET binding_id=?,session_id=?,generation=generation+1,delivered=acknowledged,last_activity=? WHERE document_id=?", [.string(UUID().uuidString), .string(target), now, binding["document_id"]])
            return try attachment(binding.require("document_id"))
        }
    }
    public func detach(_ args: JSON) throws -> JSON {
        try transaction {
            let binding = try validateBinding(args)
            try releaseDocument(binding.require("document_id"))
            return .object(["detached": .bool(true), "document_id": binding["document_id"]])
        }
    }
    /// Only the app's explicit user action can release an unavailable owner.
    public func releaseDocument(_ documentID: String) throws {
        try execute("UPDATE bindings SET binding_id=?,session_id=NULL,generation=generation+1,delivered=acknowledged,last_activity=? WHERE document_id=?", [.string(UUID().uuidString), now, .string(documentID)])
    }
    public func enqueue(documentID: String, eventID: String, payload: JSON) throws {
        try execute("INSERT OR IGNORE INTO feedback(event_id,document_id,payload,created) VALUES(?,?,?,?)", [.string(eventID), .string(documentID), .string(payload.text()), now])
    }
    public func feedback(_ args: JSON) throws -> JSON {
        try transaction {
            let binding = try validateBinding(args)
            let acknowledged = binding["acknowledged"].int ?? 0
            let cursor = args["after_cursor"].int ?? acknowledged
            guard cursor >= 0, cursor <= (binding["delivered"].int ?? acknowledged) else { throw BridgeError("INVALID_CURSOR", "The cursor skips feedback that this binding has not received.") }
            let limit = min(100, max(1, args["limit"].int ?? 50))
            let values = try rows("SELECT sequence,event_id,payload FROM feedback WHERE document_id=? AND sequence>? ORDER BY sequence LIMIT ?", [binding["document_id"], .integer(cursor), .integer(limit)])
            let events = try values.map { row -> JSON in
                .object(["cursor": row["sequence"]!, "event_id": row["event_id"]!, "feedback": try JSON.parse(Data(row["payload"]!.string!.utf8))])
            }
            let next = values.last?["sequence"]?.int ?? cursor
            try execute("UPDATE bindings SET delivered=MAX(delivered,?),last_activity=? WHERE binding_id=?", [.integer(next), now, binding["binding_id"]])
            return .object(["document_id": binding["document_id"], "events": .array(events), "next_cursor": .integer(next), "acknowledged_cursor": .integer(acknowledged)])
        }
    }
    public func acknowledge(_ args: JSON) throws -> JSON {
        try transaction {
            let binding = try validateBinding(args), cursor = try args.requireInt("cursor")
            guard cursor >= 0, cursor <= (binding["delivered"].int ?? 0) else { throw BridgeError("INVALID_CURSOR", "Cannot acknowledge feedback that has not been delivered.") }
            if cursor > 0, try rows("SELECT sequence FROM feedback WHERE document_id=? AND sequence=?", [binding["document_id"], .integer(cursor)]).isEmpty { throw BridgeError("INVALID_CURSOR", "The cursor does not belong to this document.") }
            try execute("UPDATE bindings SET acknowledged=MAX(acknowledged,?),last_activity=? WHERE binding_id=?", [.integer(cursor), now, binding["binding_id"]])
            return .object(["acknowledged_cursor": .integer(max(cursor, binding["acknowledged"].int ?? 0))])
        }
    }
    public func operation(_ id: String, fingerprint: String, binding: JSON) throws -> JSON? {
        guard let row = try rows("SELECT * FROM operations WHERE operation_id=?", [.string(id)]).first else { return nil }
        guard row["request_hash"]?.string == fingerprint, row["document_id"] == binding["document_id"], row["binding_id"] == binding["binding_id"], row["generation"] == binding["generation"] else { throw BridgeError("OPERATION_ID_REUSED", "Use a new operation_id for a different operation or attachment.") }
        return .object(row)
    }
    public func prepareOperation(id: String, fingerprint: String, binding: JSON, before: String?, after: String?, result: JSON) throws {
        try execute("INSERT INTO operations(operation_id,document_id,binding_id,generation,request_hash,before_revision,after_revision,result,state) VALUES(?,?,?,?,?,?,?,?, 'prepared')", [.string(id), binding["document_id"], binding["binding_id"], binding["generation"], .string(fingerprint), before.map(JSON.string) ?? .null, after.map(JSON.string) ?? .null, .string(result.text())])
    }
    public func finishOperation(_ id: String) throws { try execute("UPDATE operations SET state='complete' WHERE operation_id=?", [.string(id)]) }
    public func discardPreparedOperation(_ id: String) throws { try execute("DELETE FROM operations WHERE operation_id=? AND state='prepared'", [.string(id)]) }
}
