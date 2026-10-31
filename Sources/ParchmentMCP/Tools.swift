import Foundation
import ParchmentIntegration

enum ToolCatalog {
    static func field(_ type: String, _ description: String) -> JSON {
        .object(["type": .string(type), "description": .string(description)])
    }
    static let string = field("string", "")
    static let binding: [String: JSON] = [
        "session_token": field("string", "Secret token for this conversation, returned by create_session."),
        "binding_id": field("string", "Attachment ID returned by attach_document."),
        "generation": field("integer", "Attachment generation returned by attach_document.")
    ]
    static let reference: [String: JSON] = ["document_id": string, "path": field("string", "Absolute file path. Supply document_id or path. Closed files reopen in the app.")]
    static func tool(_ name: String, _ description: String, _ properties: [String: JSON] = [:], required: [String] = [], readOnly: Bool = false) -> JSON {
        .object(["name": .string(name), "description": .string(description),
                 "inputSchema": .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map(JSON.string)), "additionalProperties": .bool(false)]),
                 "annotations": .object(["readOnlyHint": .bool(readOnly), "openWorldHint": .bool(false)])])
    }
    static func with(_ base: [String: JSON], _ extra: [String: JSON]) -> [String: JSON] { base.merging(extra) { _, new in new } }
    static let requiredBinding = ["session_token", "binding_id", "generation"]
    static let sessionReference = ["session_token": binding["session_token"]!]
    static let wakeUp: JSON = .object([
        "type": .string("object"), "description": .string("Register wake-up delivery with the session. Use command with a known runtime queue command, or manual when unsupported. Never invent a queue command or conversation ID."),
        "properties": .object([
            "mode": .object(["type": .string("string"), "enum": .array([.string("command"), .string("manual")])]),
            "agent_session_id": field("string", "Existing runtime conversation ID. Required for command mode."),
            "executable": field("string", "Absolute queue executable path. Required for command mode."),
            "arguments": .object(["type": .string("array"), "items": string, "maxItems": .integer(128)])]),
        "required": .array([.string("mode")]), "additionalProperties": .bool(false)])
    static let tools: [JSON] = [
        tool("create_session", "Register identity and wake_up configuration together for the current agent conversation. Choose command or explicit manual delivery. Retain the token across reconnects; never create a session per tool call.", ["client": string, "conversation_label": string, "conversation_id": string, "model": field("string", "Current model, when known. Omit if unavailable."), "wake_up": wakeUp], required: ["client", "conversation_label", "wake_up"]),
        tool("resume_session", "Resume the original conversation token and restart automatic keep-alives on this MCP connection.", ["session_token": string], required: ["session_token"]),
        tool("keep_alive", "Keep this session in the active session list. The connected MCP helper renews every 10 seconds after create_session, resume_session, or keep_alive. With --call, call this every 10 seconds yourself. Sessions disappear after 11 seconds without a keep-alive, allowing one second of scheduling tolerance. Document ownership and feedback remain intact.", sessionReference, required: ["session_token"]),
        tool("update_session", "Update this conversation's name, model, or wake_up configuration in place. Preserves its ID, token, and attachments. Omitting wake_up preserves the receiver. An empty model clears stale model metadata.", with(sessionReference, ["conversation_label": field("string", "Current session name from the runtime, or a descriptive name when unavailable."), "model": field("string", "Current model when known; empty clears stale model metadata."), "wake_up": wakeUp]), required: ["session_token"]),
        tool("list_sessions", "List conversations with a recent keep-alive and their attached documents. Sessions without a keep-alive for 11 seconds are hidden. Never returns tokens or executable commands.", readOnly: true),
        tool("get_events", "Read this session's common event bus, including attachment requests and published feedback notifications. Authenticate with the original token. Events repeat until handled; reading or wake-up acceptance never acknowledges feedback.", with(sessionReference, ["limit": field("integer", "Maximum pending events, 1–100. Default 50.")]), required: ["session_token"], readOnly: true),
        tool("wait_for_events", "Wait for events in this session's inbox, including requests for documents not yet attached. Returns within 25 seconds. Supports cancellation. Does not wake a finished agent turn.", with(sessionReference, ["limit": field("integer", "Maximum pending events, 1–100."), "timeout_seconds": field("integer", "0–25 seconds. Default 25.")]), required: ["session_token"], readOnly: true),
        tool("acknowledge_events", "Confirm handled bus events by bus_event_id after reading them. Attachment acceptance/cancellation and document feedback acknowledgement complete the associated bus events. Never acknowledges document feedback or discards unfinished work.", with(sessionReference, ["event_ids": .object(["type": .string("array"), "items": string, "minItems": .integer(1), "maxItems": .integer(100)])]), required: ["session_token", "event_ids"]),
        tool("register_receiver", "Compatibility tool. Prefer wake_up in create_session or update_session. Registers the command that wakes this conversation for all bus event types. The command receives JSON on stdin. Exit 0 means durable enqueue, not feedback completion. Arguments support {agent_session_id}, {message}, {delivery_id}, and {document_id}; no shell is used. Use only a known runtime queue command.", with(sessionReference, ["agent_session_id": field("string", "The existing agent conversation's runtime ID. Never invent an ID."), "executable": field("string", "Absolute path to a runtime queue executable or receiver program."), "arguments": .object(["type": .string("array"), "items": string, "maxItems": .integer(128)])]), required: ["session_token", "agent_session_id", "executable"]),
        tool("unregister_receiver", "Stop automatic delivery for this agent session. Document ownership and unhandled feedback are preserved.", sessionReference, required: ["session_token"]),
        tool("get_receiver_status", "Read wake-up configuration, pending session events, feedback, accepted wake-ups, and retry errors. Does not acknowledge feedback or prove the runtime resumed the agent.", sessionReference, required: ["session_token"], readOnly: true),
        tool("open_app", "Launch Parchment if needed and wait for its API. Does not start an agent.", ["activate": field("boolean", "Bring the app to the foreground. Default true.")]),
        tool("open_document", "Launch Parchment if needed, open an existing Markdown file, and optionally attach this conversation. Existing tabs are reused. Does not create or overwrite the file.", ["path": string, "attach": field("boolean", "Default false. If true, session_token is required."), "session_token": string, "activate": field("boolean", "Default true.")], required: ["path"]),
        tool("list_documents", "List live open tabs, including unsaved documents and safe attachment metadata. APP_UNAVAILABLE means the app is not running.", readOnly: true),
        tool("attach_document", "Attach an existing document by ID or path to this conversation. Same-session attachment is idempotent. Another owner requires a handoff or a user-confirmed attachment_request_id.", with(reference, ["session_token": string, "attachment_request_id": field("string", "Request ID from parchment.attachment_requested. Validates the user’s current attachment or transfer request.")]), required: ["session_token"]),
        tool("get_document", "Read live text, its revision, and published comments with source anchors. Pending reviews are excluded. A closed saved document reopens.", with(reference, ["include_resolved": field("boolean", "Include resolved comment history. Default false.")]), readOnly: true),
        tool("get_feedback", "Read durable published feedback for the owning conversation. Delivery repeats until acknowledged. Pending reviews are excluded.", with(binding, ["after_cursor": field("integer", "Default last acknowledged cursor. Never advance beyond delivered feedback."), "limit": field("integer", "Maximum events, 1–100. Default 50.")]), required: requiredBinding, readOnly: true),
        tool("wait_for_feedback", "Wait for published feedback in this conversation. Call again after an empty response. Does not wake a finished conversation or launch an agent. Supports request cancellation.", with(binding, ["after_cursor": field("integer", "Default last acknowledged cursor."), "limit": field("integer", "Maximum events, 1–100."), "timeout_seconds": field("integer", "Wait duration, 0–25 seconds. Default 25.")]), required: requiredBinding, readOnly: true),
        tool("acknowledge_feedback", "Acknowledge delivered feedback after handling it. Cursor advancement is durable and idempotent.", with(binding, ["cursor": field("integer", "Last handled event cursor.")]), required: requiredBinding + ["cursor"]),
        tool("apply_patch", "Apply exact replacements to live text through native undo and save. Requires the current revision. Retry transport failures with identical arguments and operation_id. Re-read on REVISION_CONFLICT.", with(binding, ["operation_id": string, "expected_revision": string, "edits": .object(["type": .string("array"), "minItems": .integer(1), "maxItems": .integer(1000), "items": .object(["type": .string("object"), "properties": .object(["old_text": string, "new_text": string, "start": field("integer", "Optional zero-based UTF-16 offset. Required for insertions or repeated old_text.")]), "required": .array([.string("old_text"), .string("new_text")]), "additionalProperties": .bool(false)])])]), required: requiredBinding + ["operation_id", "expected_revision", "edits"]),
        tool("reply_to_thread", "Add an agent reply to a published thread. Reuse operation_id only for identical retries. Replies do not generate feedback loops.", with(binding, ["operation_id": string, "thread_id": string, "body": string]), required: requiredBinding + ["operation_id", "thread_id", "body"]),
        tool("resolve_thread", "Resolve a published thread and preserve its history. Use a unique operation_id.", with(binding, ["operation_id": string, "thread_id": string]), required: requiredBinding + ["operation_id", "thread_id"]),
        tool("handoff_document", "Explicitly transfer ownership to a registered session. Invalidates the old binding. The receiver calls attach_document with its own token. Unacknowledged feedback carries over.", with(binding, ["target_session_id": string]), required: requiredBinding + ["target_session_id"]),
        tool("detach_document", "Explicitly release ownership. Disconnecting the MCP transport alone never detaches a document.", binding, required: requiredBinding)
    ]
    static func validate(_ name: String, _ arguments: JSON) throws {
        guard let tool = tools.first(where: { $0["name"].string == name }) else { throw BridgeError("UNKNOWN_TOOL", "Unknown tool: \(name)") }
        guard case .object(let values) = arguments else { throw BridgeError("INVALID_ARGUMENT", "Tool arguments must be an object.") }
        let schema = tool["inputSchema"], properties = schema["properties"].object
        for key in schema["required"].array.compactMap(\.string) where values[key] == nil { throw BridgeError("INVALID_ARGUMENT", "Missing required argument: \(key)") }
        for (key, value) in values {
            guard let definition = properties[key] else { throw BridgeError("INVALID_ARGUMENT", "Unknown argument: \(key)") }
            let valid: Bool
            switch definition["type"].string {
            case "string": valid = value.string != nil
            case "boolean": valid = value.bool != nil
            case "integer": valid = value.int != nil
            case "array": if case .array = value { valid = true } else { valid = false }
            case "object": if case .object = value { valid = true } else { valid = false }
            default: valid = true
            }
            guard valid else { throw BridgeError("INVALID_ARGUMENT", "Invalid argument type: \(key)") }
        }
    }
}
