import Foundation
import Darwin

extension IntegrationRegistry {
    public func validateWakeUpConfiguration(_ configuration: JSON) throws {
        guard case .object = configuration else { throw BridgeError("INVALID_RECEIVER", "wake_up must contain mode: command or manual.") }
        let mode = try configuration.require("mode")
        if mode == "manual" {
            guard Set(configuration.object.keys) == ["mode"] else { throw BridgeError("INVALID_RECEIVER", "Manual delivery accepts only mode: manual.") }
            return
        }
        guard mode == "command", Set(configuration.object.keys).isSubset(of: ["mode", "agent_session_id", "executable", "arguments"]) else {
            throw BridgeError("INVALID_RECEIVER", "Use mode: command with an existing agent session ID, executable, and arguments, or mode: manual.")
        }
        let agent = try configuration.require("agent_session_id"), executable = try configuration.require("executable")
        let arguments = configuration["arguments"] == .null ? [] : configuration["arguments"].array
        if configuration["arguments"] != .null {
            guard case .array = configuration["arguments"] else { throw BridgeError("INVALID_RECEIVER", "Receiver arguments must be a string array.") }
        }
        guard agent.utf8.count <= 1024, !agent.contains("\0"), executable.hasPrefix("/"), !executable.contains("\0"),
              FileManager.default.isExecutableFile(atPath: executable), arguments.count <= 128,
              arguments.allSatisfy({ $0.string != nil && !$0.string!.contains("\0") }),
              arguments.reduce(0, { $0 + ($1.string?.utf8.count ?? 0) }) <= 16384 else {
            throw BridgeError("INVALID_RECEIVER", "Supply an existing agent session ID, an absolute executable, and at most 128 string arguments (16 KB total).")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: executable, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw BridgeError("INVALID_RECEIVER", "The receiver executable must be a file.")
        }
    }
    /// The caller holds the transaction so identity and wake-up settings commit together.
    func configureWakeUp(sessionID: JSON, configuration: JSON) throws {
        try validateWakeUpConfiguration(configuration)
        let mode = try configuration.require("mode")
        if mode == "manual" { try execute("DELETE FROM receivers WHERE session_id=?", [sessionID]) }
        else {
            let agent = configuration["agent_session_id"], executable = configuration["executable"]
            let encoded = JSON.array(configuration["arguments"].array).text()
            let current = try rows("SELECT * FROM receivers WHERE session_id=?", [sessionID]).first
            if current?["agent_session_id"] != agent || current?["executable"] != executable || current?["arguments"] != .string(encoded) {
                try execute("DELETE FROM receivers WHERE session_id=?", [sessionID])
                try execute("INSERT INTO receivers(session_id,receiver_id,agent_session_id,executable,arguments) VALUES(?,?,?,?,?)", [sessionID, .string(UUID().uuidString), agent, executable, .string(encoded)])
            }
        }
        try execute("UPDATE sessions SET wake_up_mode=? WHERE id=?", [.string(mode), sessionID])
    }
    /// Compatibility entry point. New clients supply wake_up when creating or updating a session.
    public func registerReceiver(_ args: JSON) throws -> JSON {
        try transaction {
            let owner = try session(args.require("session_token"))
            try configureWakeUp(sessionID: owner["session_id"], configuration: .object([
                "mode": .string("command"), "agent_session_id": args["agent_session_id"], "executable": args["executable"],
                "arguments": args["arguments"] == .null ? .array([]) : args["arguments"]]))
            return try receiverStatus(sessionID: owner["session_id"])
        }
    }
    public func unregisterReceiver(_ args: JSON) throws -> JSON {
        try transaction {
            let owner = try session(args.require("session_token"))
            try configureWakeUp(sessionID: owner["session_id"], configuration: .object(["mode": .string("manual")]))
            return try receiverStatus(sessionID: owner["session_id"])
        }
    }
    public func receiverStatus(_ args: JSON) throws -> JSON {
        let owner = try session(args.require("session_token"))
        return try receiverStatus(sessionID: owner["session_id"])
    }
    func receiverStatus(sessionID: JSON) throws -> JSON {
        try synchronizeSessionEvents()
        let receiver = try rows("SELECT receiver_id,agent_session_id FROM receivers WHERE session_id=?", [sessionID]).first
        let outstanding = try rows("SELECT COUNT(*) AS count FROM feedback f JOIN bindings b ON b.document_id=f.document_id WHERE b.session_id=? AND f.sequence>b.acknowledged", [sessionID]).first?["count"] ?? .integer(0)
        let pending = try rows("SELECT COUNT(*) AS count FROM session_events WHERE session_id=? AND state='pending'", [sessionID]).first?["count"] ?? .integer(0)
        let requests = try rows("SELECT COUNT(*) AS count FROM attachment_requests WHERE session_id=? AND state='pending'", [sessionID]).first?["count"] ?? .integer(0)
        let accepted = try rows("SELECT COUNT(*) AS count FROM event_wakeups w JOIN session_events e ON e.bus_event_id=w.bus_event_id WHERE e.session_id=? AND e.state='pending' AND w.accepted_at IS NOT NULL", [sessionID]).first?["count"] ?? .integer(0)
        let failed = try rows("SELECT w.attempts,w.last_error,w.next_attempt FROM event_wakeups w JOIN session_events e ON e.bus_event_id=w.bus_event_id WHERE e.session_id=? AND e.state='pending' AND w.accepted_at IS NULL AND w.last_error IS NOT NULL ORDER BY e.cursor LIMIT 1", [sessionID]).first
        let mode = try rows("SELECT wake_up_mode FROM sessions WHERE id=?", [sessionID]).first?["wake_up_mode"] ?? .string("unspecified")
        return .object(["registered": .bool(receiver != nil), "mode": .string(receiver == nil ? "manual" : "automatic"), "wake_up_mode": mode,
                        "protocol_version": .integer(2), "event_bus_version": .integer(1),
                        "receiver_id": receiver?["receiver_id"] ?? .null, "agent_session_id": receiver?["agent_session_id"] ?? .null,
                        "pending_events": pending, "pending_attachment_requests": requests, "pending_feedback": outstanding,
                        "accepted_notifications": accepted, "last_error": failed?["last_error"] ?? .null,
                        "attempts": failed?["attempts"] ?? .integer(0), "next_attempt": failed?["next_attempt"] ?? .null])
    }
}

/// The receiver queues input in the existing agent session and exits after acceptance.
public struct SessionEventDispatcher: Sendable {
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
            let isAttachment = delivery["type"].string == "parchment.attachment_requested"
            let message = "🤖 Parchment has a queued \(isAttachment ? "attachment request" : "feedback event") for document \(delivery["document_id"].string!). Resume your original Parchment session and synchronize its name and model. Call get_events with your retained token to read this session’s event bus. Process events within the user’s task. Attachment requests require their attachment_request_id. Feedback requires the current binding and get_feedback. Read the latest document before edits. Acknowledge only handled feedback and events. Stop on stale ownership; do not reclaim a detached file from an old notification. Notification \(delivery["delivery_id"].string!), bus event \(delivery["bus_event_id"].string!)."
            let payload: JSON = .object(["protocol_version": .integer(2), "type": delivery["type"],
                "bus_event_id": delivery["bus_event_id"], "bus_cursor": delivery["bus_cursor"],
                "attachment_request_id": delivery["attachment_request_id"], "delivery_id": delivery["delivery_id"],
                "event_id": delivery["event_id"], "cursor": delivery["sequence"], "session_id": delivery["session_id"],
                "agent_session_id": delivery["agent_session_id"], "document_id": delivery["document_id"],
                "binding_id": delivery["binding_id"], "generation": delivery["generation"], "message": .string(message)])
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
