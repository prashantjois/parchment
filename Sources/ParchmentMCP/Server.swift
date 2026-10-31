import AppKit
import ParchmentIntegration

actor AppLauncher {
    private var launch: Task<Void, Error>?
    func ensureRunning(client: LocalAPIClient) async throws {
        if (try? client.call("ping")) != nil { return }
        if let launch { return try await launch.value }
        let task = Task {
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
            let installed = ProcessInfo.processInfo.environment["PARCHMENT_DATA_DIR"] == nil ? URL(fileURLWithPath: "/Applications/Parchment.app") : nil
            let candidates = [ProcessInfo.processInfo.environment["PARCHMENT_APP_PATH"].map { URL(fileURLWithPath: $0) },
                              installed,
                              executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),
                              executable.deletingLastPathComponent().appendingPathComponent("Parchment.app"),
                              URL(fileURLWithPath: "/Applications/Parchment.app")].compactMap { $0 }
            guard let app = candidates.first(where: { $0.pathExtension == "app" && FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/MacOS/Parchment").path) }) else {
                throw BridgeError("APP_NOT_FOUND", "Set PARCHMENT_APP_PATH to Parchment.app, or use the helper bundled inside the app.")
            }
            try await launchApplication(app, directory: client.directory)
            for _ in 0..<100 {
                if (try? client.call("ping")) != nil { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw BridgeError("APP_START_TIMEOUT", "Parchment launched, but its API did not become ready within 10 seconds. If the app was updated, quit the old instance and reopen it.")
        }
        launch = task
        defer { launch = nil }
        try await task.value
    }
}

// Keep the AppKit callback on the main actor without blocking the JSON-RPC reader.
@MainActor private func launchApplication(_ app: URL, directory: URL) async throws {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.createsNewApplicationInstance = ProcessInfo.processInfo.environment["PARCHMENT_DATA_DIR"] != nil
    configuration.environment = ["PARCHMENT_DATA_DIR": directory.path]
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
            if let error { continuation.resume(throwing: BridgeError("APP_LAUNCH_FAILED", error.localizedDescription)) }
            else { continuation.resume() }
        }
    }
}

final class MCPServer: @unchecked Sendable {
    let registry: IntegrationRegistry
    private let keepAlives: SessionKeepAlives
    let client = LocalAPIClient()
    let launcher = AppLauncher()
    private let lock = NSLock()
    private var tasks: [String: Task<Void, Never>] = [:]
    private var initialized = false
    private var stopped = false
    init() throws {
        let registry = try IntegrationRegistry()
        self.registry = registry
        keepAlives = SessionKeepAlives(registry: registry)
    }
    private func send(_ value: JSON) {
        lock.lock(); defer { lock.unlock() }
        FileHandle.standardOutput.write(Data((value.text() + "\n").utf8))
    }
    private func rpcError(_ id: JSON, _ code: Int, _ message: String) {
        send(.object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .integer(code), "message": .string(message)])]))
    }
    func accept(_ line: String) {
        guard let request = try? JSON.parse(Data(line.utf8)) else { rpcError(.null, -32700, "Parse error"); return }
        guard request["jsonrpc"].string == "2.0", let method = request["method"].string else { rpcError(request["id"], -32600, "Invalid request"); return }
        if request["id"] == .null {
            if method == "notifications/cancelled" {
                lock.lock(); tasks[request["params"]["requestId"].text()]?.cancel(); lock.unlock()
            }
            return
        }
        let id = request["id"], key = id.text()
        guard id.string != nil || id.int != nil else { rpcError(id, -32600, "Invalid request ID"); return }
        if method == "initialize" {
            let requested = request["params"]["protocolVersion"].string ?? ""
            let version = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"].contains(requested) ? requested : "2025-11-25"
            initialized = true
            send(.object(["jsonrpc": .string("2.0"), "id": id, "result": .object([
                "protocolVersion": .string(version), "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("parchment"), "version": .string("1.3.0")]),
                "instructions": .string("Use one session per agent conversation. Register its current name, optional model, and wake_up configuration together in create_session. Use command mode with a documented queue command, or explicit manual mode. Keep the token. The connected helper sends keep-alives every 10 seconds after create_session or resume_session. Sessions disappear from the session list after 11 seconds without a keep-alive, including one second of scheduling tolerance. Ownership and pending feedback survive inactivity. Resume and synchronize metadata each turn; update_session can repair wake-up configuration without creating another identity. Read get_events at the start of each turn and on every notification. wait_for_events covers all documents, including new attachment requests. Accept requests with attach_document and attachment_request_id. For feedback events use the event's binding_id and generation with get_feedback; stale notifications must not reclaim detached files. Read the latest document before edits. Acknowledge only handled document feedback and bus events. A wake-up only queues input, never acknowledges work. Pending reviews stay private. Only one session owns a document; transfer requires explicit user approval.")
            ])])); return
        }
        guard initialized || method == "ping" else { rpcError(id, -32002, "Initialize the server first"); return }
        if method == "ping" { send(.object(["jsonrpc": .string("2.0"), "id": id, "result": .object([:]) ])); return }
        if method == "tools/list" { send(.object(["jsonrpc": .string("2.0"), "id": id, "result": .object(["tools": .array(ToolCatalog.tools)])])); return }
        guard method == "tools/call" else { rpcError(id, -32601, "Method not found"); return }
        lock.lock()
        if tasks[key] != nil { lock.unlock(); rpcError(id, -32600, "Duplicate active request ID"); return }
        tasks[key] = Task.detached { [self] in
            let result: JSON
            do {
                let value = try await call(request["params"])
                result = .object(["content": .array([.object(["type": .string("text"), "text": .string(value.text())])]), "structuredContent": value, "isError": .bool(false)])
            } catch {
                let error = error is CancellationError ? BridgeError("CANCELLED", "The request was cancelled.") : BridgeError.wrap(error)
                result = .object(["content": .array([.object(["type": .string("text"), "text": .string(error.json.text())])]), "structuredContent": .object(["error": error.json]), "isError": .bool(true)])
            }
            send(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
            finish(key)
        }
        lock.unlock()
    }
    private func finish(_ key: String) { lock.lock(); tasks.removeValue(forKey: key); lock.unlock() }
    func stop() {
        keepAlives.stop()
        lock.lock(); stopped = true; tasks.values.forEach { $0.cancel() }; lock.unlock()
    }
    private func checkConnection() throws {
        try Task.checkCancellation()
        lock.lock(); defer { lock.unlock() }
        if stopped { throw CancellationError() }
    }
    func call(_ params: JSON) async throws -> JSON {
        let name = try params.require("name"), args = params["arguments"] == .null ? JSON.object([:]) : params["arguments"]
        try ToolCatalog.validate(name, args)
        try checkConnection()
        // Any authenticated request proves that this conversation is connected.
        // Reconnects must not depend on calling resume_session before other tools.
        if let token = args["session_token"].string { try keepAlives.track(token) }
        switch name {
        case "create_session", "update_session":
            if name == "update_session" { _ = try registry.session(args.require("session_token")) }
            if args["wake_up"] != .null {
                try registry.validateWakeUpConfiguration(args["wake_up"])
                if args["wake_up"]["mode"].string == "command" {
                    try await launcher.ensureRunning(client: client)
                    guard try client.call("ping")["event_bus_version"].int == 1 else {
                        throw BridgeError("APP_UPDATE_REQUIRED", "Reopen the updated Parchment app before registering event-bus wake-ups.")
                    }
                }
            }
            if name == "update_session" { return try registry.updateSession(args) }
            let session = try registry.createSession(client: args.require("client"), label: args.require("conversation_label"), conversationID: args["conversation_id"].string, model: args["model"].string, wakeUp: args["wake_up"])
            try keepAlives.track(session.require("session_token"))
            return session
        case "list_sessions": return try registry.registeredSessions()
        case "resume_session": return try registry.session(args.require("session_token"))
        case "keep_alive": return try keepAlives.track(args.require("session_token"))
        case "register_receiver":
            _ = try registry.session(args.require("session_token"))
            try await launcher.ensureRunning(client: client)
            guard try client.call("ping")["agent_delivery_version"].int == 2 else {
                throw BridgeError("APP_UPDATE_REQUIRED", "Reopen the updated Parchment app before registering an agent receiver.")
            }
            return try registry.registerReceiver(args)
        case "unregister_receiver": return try registry.unregisterReceiver(args)
        case "get_receiver_status": return try registry.receiverStatus(args)
        case "open_app", "open_document":
            if name == "open_document", args["attach"].bool == true { _ = try registry.session(args.require("session_token")) }
            try await launcher.ensureRunning(client: client)
            if name == "open_document" { return try client.call(name, params: args) }
            if args["activate"].bool != false { return try client.call("activate") }
            return try client.call("ping")
        case "get_events", "wait_for_events":
            _ = try registry.session(args.require("session_token"))
            do { _ = try client.call("sync_feedback") }
            catch let error as BridgeError where error.code == "APP_UNAVAILABLE" { }
            let timeout = name == "wait_for_events" ? args["timeout_seconds"].int ?? 25 : 0
            guard (0...25).contains(timeout) else { throw BridgeError("INVALID_ARGUMENT", "timeout_seconds must be between 0 and 25.") }
            let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
            while true {
                try checkConnection()
                let events = try registry.sessionEvents(args)
                if !events["events"].array.isEmpty || ContinuousClock.now >= deadline { return events }
                try await Task.sleep(for: .milliseconds(250))
            }
        case "acknowledge_events": return try registry.acknowledgeEvents(args)
        case "get_feedback", "wait_for_feedback":
            _ = try registry.validateBinding(args)
            // Persist live comments before delivery. A closed app still has a durable queue.
            do { _ = try client.call("sync_feedback") }
            catch let error as BridgeError where error.code == "APP_UNAVAILABLE" { }
            let timeout = name == "wait_for_feedback" ? args["timeout_seconds"].int ?? 25 : 0
            guard (0...25).contains(timeout) else { throw BridgeError("INVALID_ARGUMENT", "timeout_seconds must be between 0 and 25.") }
            let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
            while true {
                try checkConnection()
                let feedback = try registry.feedback(args)
                if !feedback["events"].array.isEmpty || ContinuousClock.now >= deadline { return feedback }
                try await Task.sleep(for: .milliseconds(250))
            }
        case "attach_document":
            if args["attachment_request_id"].string != nil {
                guard try client.call("ping")["attachment_requests_version"].int == 1 else {
                    throw BridgeError("APP_UPDATE_REQUIRED", "Reopen the updated Parchment app before accepting an attachment request.")
                }
            }
            return try client.call(name, params: args)
        case "acknowledge_feedback": return try registry.acknowledge(args)
        default: return try client.call(name, params: args)
        }
    }
}

@main enum ParchmentMCP {
    static func main() async {
        do {
            if CommandLine.arguments.dropFirst().elementsEqual(["--bridge"]) {
                let server = try MCPServer()
                let requests = AsyncStream<String> { continuation in
                    DispatchQueue.global().async {
                        while let line = readLine(strippingNewline: true) { continuation.yield(line) }
                        server.stop(); continuation.finish()
                    }
                }
                for await line in requests {
                    let response: JSON
                    do {
                        let request = try JSON.parse(Data(line.utf8))
                        let tool = try request.require("tool")
                        let result = try await server.call(.object(["name": .string(tool), "arguments": request["arguments"]]))
                        response = .object(["exit_code": .integer(0), "result": result, "stderr": .string("")])
                    } catch {
                        response = .object(["exit_code": .integer(1), "result": .object(["error": BridgeError.wrap(error).json]), "stderr": .string("")])
                    }
                    FileHandle.standardOutput.write(Data((response.text() + "\n").utf8))
                }
                return
            }
            if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--call" {
                do {
                    let input = FileHandle.standardInput.readDataToEndOfFile()
                    let arguments = input.isEmpty ? JSON.object([:]) : try JSON.parse(input)
                    let server = try MCPServer()
                    var result = try await server.call(.object(["name": .string(CommandLine.arguments[2]), "arguments": arguments]))
                    if case .object(var fields) = result,
                       CommandLine.arguments[2] == "create_session" || arguments["session_token"].string != nil {
                        fields["connection"] = .object([
                            "persistent": .bool(false),
                            "instructions": .string("This --call helper exits after this response, so it cannot keep an idle session listed. Use ParchmentMCP --bridge instead: keep stdin open and send one JSON line per request with tool and arguments fields. Resume this same token through the bridge. The connection automatically sends keep-alives every 10 seconds, including while idle. Close stdin when the conversation is no longer available.")])
                        result = .object(fields)
                    }
                    FileHandle.standardOutput.write(Data((result.text() + "\n").utf8))
                } catch {
                    let result: JSON = .object(["error": BridgeError.wrap(error).json])
                    FileHandle.standardOutput.write(Data((result.text() + "\n").utf8)); exit(1)
                }
                return
            }
            if CommandLine.arguments.dropFirst().elementsEqual(["--dispatch-events"]) || CommandLine.arguments.dropFirst().elementsEqual(["--dispatch-feedback"]) {
                let dispatcher = SessionEventDispatcher(registry: try IntegrationRegistry())
                await dispatcher.run(); return
            }
            guard CommandLine.arguments.count == 1 else { throw BridgeError("INVALID_ARGUMENT", "Usage: ParchmentMCP [--bridge | --dispatch-events | --dispatch-feedback | --call TOOL < arguments.json]") }
            let server = try MCPServer()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    while let line = readLine(strippingNewline: true) { server.accept(line) }
                    server.stop(); continuation.resume()
                }
            }
        } catch { fputs("Parchment MCP: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
