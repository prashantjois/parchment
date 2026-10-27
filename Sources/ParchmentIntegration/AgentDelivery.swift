import Foundation
import Darwin

extension IntegrationRegistry {
    public func registerReceiver(_ args: JSON) throws -> JSON {
        let owner = try session(args.require("session_token"))
        let agent = try args.require("agent_session_id"), executable = try args.require("executable")
        let arguments = args["arguments"] == .null ? [] : args["arguments"].array
        guard agent.utf8.count <= 1024, !agent.contains("\0"),
              executable.hasPrefix("/"), !executable.contains("\0"),
              FileManager.default.isExecutableFile(atPath: executable),
              arguments.count <= 128, arguments.allSatisfy({ $0.string != nil && !$0.string!.contains("\0") }),
              arguments.reduce(0, { $0 + ($1.string?.utf8.count ?? 0) }) <= 16384 else {
            throw BridgeError("INVALID_RECEIVER", "Supply an agent session ID, an absolute executable path, and at most 128 string arguments (16 KB total).")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: executable, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw BridgeError("INVALID_RECEIVER", "The receiver executable must be a file.")
        }
        let sessionID = owner["session_id"], encoded = JSON.array(arguments).text()
        return try transaction {
            let current = try rows("SELECT * FROM receivers WHERE session_id=?", [sessionID]).first
            if current?["agent_session_id"] != .string(agent) || current?["executable"] != .string(executable) || current?["arguments"] != .string(encoded) {
                try execute("DELETE FROM receivers WHERE session_id=?", [sessionID])
                try execute("INSERT INTO receivers(session_id,receiver_id,agent_session_id,executable,arguments) VALUES(?,?,?,?,?)", [sessionID, .string(UUID().uuidString), .string(agent), .string(executable), .string(encoded)])
            }
            return try receiverStatus(sessionID: sessionID)
        }
    }
    public func unregisterReceiver(_ args: JSON) throws -> JSON {
        let owner = try session(args.require("session_token"))
        try execute("DELETE FROM receivers WHERE session_id=?", [owner["session_id"]])
        return .object(["registered": .bool(false)])
    }
    public func receiverStatus(_ args: JSON) throws -> JSON {
        let owner = try session(args.require("session_token"))
        return try receiverStatus(sessionID: owner["session_id"])
    }
    func receiverStatus(sessionID: JSON) throws -> JSON {
        guard let receiver = try rows("SELECT receiver_id,agent_session_id FROM receivers WHERE session_id=?", [sessionID]).first else {
            return .object(["registered": .bool(false), "mode": .string("manual")])
        }
        let outstanding = try rows("SELECT COUNT(*) AS count FROM feedback f JOIN bindings b ON b.document_id=f.document_id WHERE b.session_id=? AND f.sequence>b.acknowledged", [sessionID]).first?["count"] ?? .integer(0)
        let accepted = try rows("SELECT COUNT(*) AS count FROM notifications n JOIN bindings b ON b.document_id=n.document_id AND b.binding_id=n.binding_id WHERE n.receiver_id=? AND n.sequence>b.acknowledged AND n.accepted_at IS NOT NULL", [receiver["receiver_id"]!]).first?["count"] ?? .integer(0)
        let failed = try rows("SELECT n.attempts,n.last_error,n.next_attempt FROM notifications n JOIN bindings b ON b.binding_id=n.binding_id WHERE n.receiver_id=? AND n.sequence>b.acknowledged AND n.accepted_at IS NULL AND n.last_error IS NOT NULL ORDER BY n.sequence LIMIT 1", [receiver["receiver_id"]!]).first
        return .object(["registered": .bool(true), "mode": .string("automatic"), "protocol_version": .integer(1),
                        "receiver_id": receiver["receiver_id"]!, "agent_session_id": receiver["agent_session_id"]!,
                        "pending_feedback": outstanding, "accepted_notifications": accepted,
                        "last_error": failed?["last_error"] ?? .null, "attempts": failed?["attempts"] ?? .integer(0),
                        "next_attempt": failed?["next_attempt"] ?? .null])
    }
    /// Claim a lease so the app and an optional standalone worker cannot send concurrently.
    public func claimNotification() throws -> JSON? {
        try transaction {
            try execute("""
                INSERT OR IGNORE INTO notifications(delivery_id,receiver_id,document_id,binding_id,generation,sequence)
                SELECT lower(hex(randomblob(16))),r.receiver_id,b.document_id,b.binding_id,b.generation,f.sequence
                FROM feedback f JOIN bindings b ON b.document_id=f.document_id JOIN receivers r ON r.session_id=b.session_id
                WHERE f.sequence>b.acknowledged
                """)
            let now = Date().timeIntervalSince1970
            guard var row = try rows("""
                SELECT n.*,r.session_id,r.agent_session_id,r.executable,r.arguments,f.event_id
                FROM notifications n JOIN receivers r ON r.receiver_id=n.receiver_id
                JOIN bindings b ON b.binding_id=n.binding_id AND b.generation=n.generation AND b.session_id=r.session_id
                JOIN feedback f ON f.sequence=n.sequence
                WHERE n.sequence>b.acknowledged AND n.accepted_at IS NULL AND n.next_attempt<=? AND n.lease_until<=?
                ORDER BY n.sequence LIMIT 1
                """, [.number(now), .number(now)]).first else { return nil }
            let lease = UUID().uuidString
            try execute("UPDATE notifications SET lease_id=?,lease_until=?,attempts=attempts+1 WHERE delivery_id=?", [.string(lease), .number(now + 30), row["delivery_id"]!])
            row["lease_id"] = .string(lease)
            row["attempts"] = .integer((row["attempts"]?.int ?? 0) + 1)
            return .object(row)
        }
    }
    public func notificationIsCurrent(_ delivery: JSON) throws -> Bool {
        !(try rows("""
            SELECT n.delivery_id FROM notifications n JOIN receivers r ON r.receiver_id=n.receiver_id
            JOIN bindings b ON b.binding_id=n.binding_id AND b.generation=n.generation AND b.session_id=r.session_id
            WHERE n.delivery_id=? AND n.lease_id=? AND n.sequence>b.acknowledged AND n.accepted_at IS NULL
            """, [delivery["delivery_id"], delivery["lease_id"]])).isEmpty
    }
    public func finishNotification(_ delivery: JSON, error: String?) throws {
        if let error {
            let delay = min(60.0, pow(2, Double(min(delivery["attempts"].int ?? 1, 6))))
            try execute("UPDATE notifications SET lease_id=NULL,lease_until=0,next_attempt=?,last_error=? WHERE delivery_id=? AND lease_id=?", [.number(Date().timeIntervalSince1970 + delay), .string(error), delivery["delivery_id"], delivery["lease_id"]])
        } else {
            try execute("UPDATE notifications SET lease_id=NULL,lease_until=0,accepted_at=?,last_error=NULL WHERE delivery_id=? AND lease_id=?", [.number(Date().timeIntervalSince1970), delivery["delivery_id"], delivery["lease_id"]])
        }
    }
}

/// The receiver queues input in the existing agent session and exits after acceptance.
public struct FeedbackDispatcher: Sendable {
    public let registry: IntegrationRegistry
    public init(registry: IntegrationRegistry) { self.registry = registry }
    public func run() async {
        while !Task.isCancelled {
            do {
                if let delivery = try registry.claimNotification() { await deliver(delivery) }
                else { try await Task.sleep(for: .milliseconds(250)) }
            } catch {
                if Task.isCancelled { return }
                // Keep the worker alive across transient registry errors.
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    private func deliver(_ delivery: JSON) async {
        let process = Process()
        do {
            guard !Task.isCancelled, try registry.notificationIsCurrent(delivery) else { return }
            let message = "🤖 Published Parchment feedback is available for document \(delivery["document_id"].string!). Resume your existing Parchment session, attach this document to validate ownership, and read get_feedback. Read the latest document before edits. Handle feedback within the user's task, then acknowledge only the handled cursors. Notification \(delivery["delivery_id"].string!) (event \(delivery["event_id"].string!), binding \(delivery["binding_id"].string!), generation \(delivery["generation"].int!))."
            let payload: JSON = .object(["protocol_version": .integer(1), "type": .string("parchment.feedback_available"),
                "delivery_id": delivery["delivery_id"], "event_id": delivery["event_id"], "cursor": delivery["sequence"],
                "session_id": delivery["session_id"], "agent_session_id": delivery["agent_session_id"],
                "document_id": delivery["document_id"], "binding_id": delivery["binding_id"], "generation": delivery["generation"], "message": .string(message)])
            let substitutions = ["{agent_session_id}": delivery["agent_session_id"].string!, "{message}": message,
                                 "{delivery_id}": delivery["delivery_id"].string!, "{document_id}": delivery["document_id"].string!]
            process.executableURL = URL(fileURLWithPath: try delivery.require("executable"))
            // Expand each original template once; values never become templates or shell code.
            let template = try JSON.parse(Data(delivery.require("arguments").utf8)).array
            process.arguments = template.map { argument in
                let text = argument.string!
                var result = "", remaining = text[...]
                while let start = remaining.firstIndex(of: "{"), let end = remaining[start...].firstIndex(of: "}") {
                    result += remaining[..<start]
                    let key = String(remaining[start...end])
                    result += substitutions[key] ?? key
                    remaining = remaining[remaining.index(after: end)...]
                }
                return result + String(remaining)
            }
            process.currentDirectoryURL = registry.directory
            var environment = ProcessInfo.processInfo.environment
            environment["PARCHMENT_DATA_DIR"] = registry.directory.path
            process.environment = environment
            // An unlinked input file also supports receivers that exit without reading stdin.
            // Unlike a pipe, it cannot block the worker or raise SIGPIPE.
            let path = registry.directory.appendingPathComponent("delivery-" + UUID().uuidString).path
            let fd = Darwin.open(path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw BridgeError("DELIVERY_INPUT_FAILED", "Cannot prepare the receiver input.") }
            unlink(path)
            let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? input.close() }
            var data = try payload.data(); data.append(10)
            try input.write(contentsOf: data); try input.seek(toOffset: 0)
            process.standardInput = input; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while process.isRunning {
                guard !Task.isCancelled, try registry.notificationIsCurrent(delivery) else { throw BridgeError("DELIVERY_CANCELLED", "Delivery no longer belongs to the active attachment.") }
                guard ContinuousClock.now < deadline else { throw BridgeError("RECEIVER_TIMEOUT", "The receiver did not accept the notification within 10 seconds.") }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard process.terminationReason == .exit && process.terminationStatus == 0 else {
                throw BridgeError("RECEIVER_REJECTED", "The receiver exited with status \(process.terminationStatus).")
            }
            try registry.finishNotification(delivery, error: nil)
        } catch {
            if process.isRunning {
                process.terminate()
                for _ in 0..<10 where process.isRunning { try? await Task.sleep(for: .milliseconds(25)) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            try? registry.finishNotification(delivery, error: error.localizedDescription)
        }
    }
}
