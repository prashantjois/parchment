# Parchment MCP integration

Parchment connects a document to an existing agent conversation through local MCP tools. Published feedback can queue a follow-up turn through the owning agent's registered runtime receiver.

The agent can open Parchment, attach a file, read published feedback, and edit the live document. Pending reviews remain private until submission.

## Client configuration

Build the app with `./scripts/build-app.sh`. Add this server to your MCP client's configuration:

```json
{
  "mcpServers": {
    "parchment": {
      "command": "/absolute/path/to/Parchment.app/Contents/MacOS/ParchmentMCP",
      "args": []
    }
  }
}
```

The current build places the app at `dist/Parchment.app`. Configuration formats differ across clients. The essential setting is the absolute helper path.

The helper uses newline-delimited JSON-RPC over stdio. It writes only protocol messages to stdout. It needs no Python, Node, network service, or API key.

Agents without a configured MCP connection can call the same tools through `ParchmentMCP --call TOOL`. Supply JSON arguments through stdin. The helper returns the tool's JSON result. Errors return `{"error":{"code":"...","message":"...","details":null}}` with exit status 1. An empty stdin supplies `{}`. Retain the original session token across calls. Supply tokens through stdin rather than command arguments.

If you install the helper separately, set `PARCHMENT_APP_PATH` to the absolute app bundle path. The bundled helper locates its own app.

For isolated development, set `PARCHMENT_DATA_DIR` to a separate directory. The helper passes this directory to an app that it launches.

## Conversation workflow

1. Create the Markdown file with the agent's normal file tools.
2. Call `create_session` once for the current conversation.
3. Retain the returned `session_token` in that conversation.
4. Call `open_document` with the file path, `attach: true`, and the token.
5. Retain the returned `binding_id` and `generation`.
6. Read `get_events`, or call `wait_for_events` during an active review. Registration already configured wake-up delivery.
7. Read the current document before each change.
8. Apply changes with `apply_patch` and the latest revision.
9. Reply to the relevant threads or resolve them as appropriate.
10. Acknowledge the last handled feedback cursor.
11. Continue the active review with `wait_for_events`, or let the registered command queue the next turn.

An existing file uses the same workflow. `open_document` opens or activates its tab without overwriting the file. `attach_document` accepts a path or document ID.

Example calls:

```json
{"name":"create_session","arguments":{"client":"My agent","conversation_label":"Design document review","model":"CURRENT-MODEL","wake_up":{"mode":"manual"}}}
{"name":"open_document","arguments":{"path":"/Users/me/design.md","attach":true,"session_token":"TOKEN"}}
{"name":"get_events","arguments":{"session_token":"TOKEN"}}
{"name":"wait_for_events","arguments":{"session_token":"TOKEN","timeout_seconds":25}}
{"name":"get_document","arguments":{"document_id":"DOCUMENT"}}
{"name":"apply_patch","arguments":{"session_token":"TOKEN","binding_id":"BINDING","generation":1,"operation_id":"UNIQUE-UUID","expected_revision":"REVISION","edits":[{"old_text":"Original passage","new_text":"Revised passage"}]}}
{"name":"acknowledge_feedback","arguments":{"session_token":"TOKEN","binding_id":"BINDING","generation":1,"cursor":42}}
```

These are `tools/call` parameters. A client supplies the JSON-RPC envelope.

The wait tool returns within 25 seconds and supports cancellation. Empty responses require another call. Delivery repeats until the agent acknowledges it.

The wait tool requires an active conversation. Automatic follow-up uses the generic agent delivery protocol described below.

The API display name includes the session name, optional model, client, and a short stable session ID. The tab's Sessions menu omits the identifier. Supply the runtime's current session name as `conversation_label` and its model as `model`. If the runtime does not expose a name, use a descriptive label. Omit an unknown model. An optional `conversation_id` records the client's conversation reference.

At each new turn or reconnection, call `resume_session` and compare the name and model with the current runtime. Use `update_session` to synchronize changes in place. An empty `model` clears a stale model value. Metadata changes preserve the session ID, token, attachments, and receiver. Metadata does not select or change the model.

`list_sessions` returns safe session metadata and attached document references. It includes receiver availability and last activity. Registration and last activity do not prove that a session is running.

## Tools

| Tool | Behavior |
| --- | --- |
| `create_session` | Registers identity and required wake-up settings atomically; returns its secret token once. |
| `resume_session` | Validates a token and returns current session metadata. |
| `update_session` | Updates session metadata or wake-up configuration without replacing its identity. |
| `list_sessions` | Lists registered sessions, receiver availability, and attached documents without tokens. |
| `get_events` | Reads the authenticated session inbox for all document event types. |
| `wait_for_events` | Waits up to 25 seconds for session events, including attachment requests. |
| `acknowledge_events` | Confirms read and handled bus events without acknowledging unfinished feedback. |
| `register_receiver` | Compatibility tool for older clients. New clients configure wake-up during registration. |
| `get_receiver_status` | Reports configuration, accepted notifications, and retry errors. |
| `unregister_receiver` | Stops automatic delivery without releasing document ownership. |
| `open_app` | Launches Parchment if needed and waits for its API. |
| `open_document` | Launches the app, opens an existing file, and optionally attaches it. |
| `list_documents` | Lists live tabs, unsaved documents, view modes, and attachment metadata. |
| `attach_document` | Claims a document for one conversation. |
| `get_document` | Returns live text, revision, published threads, history, and current anchors. |
| `get_feedback` | Returns published feedback after a cursor. |
| `wait_for_feedback` | Waits up to 25 seconds for published feedback. |
| `acknowledge_feedback` | Saves the cursor for handled feedback. |
| `apply_patch` | Applies exact replacements through native editing, undo, preview, and save. |
| `reply_to_thread` | Appends an agent reply to a published thread. |
| `resolve_thread` | Resolves a published thread and preserves its history. |
| `handoff_document` | Transfers ownership to another registered session. |
| `detach_document` | Releases the current attachment explicitly. |

`list_documents` reports the live app state. It returns `APP_UNAVAILABLE` when the app is closed. It does not return stale registry entries.

Saved document metadata includes `open_url`, a link such as `parchment://Users/me/notes.md`. Agents can use it in Markdown or terminal hyperlinks. Encode spaces and reserved characters in the path. An optional `?line=42` selects a one-based line. Existing `parchment://open?path=...&line=42` links remain supported. Unsaved documents return `open_url: null`. Opening a link preserves the current attachment.

Read tools can inspect published documents without ownership. Feedback delivery and mutation tools require the owning session, binding, and generation.

Document lookup can reopen a closed saved file. Unsaved documents use IDs and must remain open or available in session recovery.

## Attach from a tab

Right-click a tab and open **Sessions** to see registered sessions. The attached owner has a check mark. Click it to detach. Click another session to queue an attachment request in its inbox. Every registered session can receive requests, including sessions without automatic wake-up.

The menu shows pending requests and delivery status. Click a pending request again to cancel it. A session without wake-up configuration collects its request when the agent next reads its inbox.

Each document keeps one owner. Choosing another session asks for explicit transfer confirmation. The current owner stays attached until the receiving agent accepts through MCP. Unhandled feedback carries over.

A request validates the selected session and current ownership. Cancellation or an intervening ownership change causes `STALE_ATTACHMENT_REQUEST`. Retrying without its request ID must not bypass that decision.

An agent can still attach directly with its token as before. A successful attachment returns binding credentials. Later published comments and reviews enter the same common event bus.

## Common session event bus

Parchment stores attachment requests and published feedback notifications in one durable SQLite event bus. Each event belongs to a stable session ID. The inbox authenticates with the session token and returns only that session's pending events.

Register identity and wake-up delivery in one `create_session` call:

```json
{
  "client": "My agent",
  "conversation_label": "Current session name",
  "model": "KNOWN-MODEL",
  "wake_up": {
    "mode": "command",
    "agent_session_id": "EXISTING-AGENT-CONVERSATION-ID",
    "executable": "/absolute/path/to/runtime-queue-command",
    "arguments": ["enqueue", "--session", "{agent_session_id}", "--message", "{message}", "--idempotency-key", "{delivery_id}"]
  }
}
```

The executable and flags are illustrative. Supply the host's documented queue command and actual conversation ID. Parchment validates the configuration before committing the session. A failed registration leaves no partial identity. It does not choose a model or start another agent conversation.

When the host has no supported wake-up interface, explicitly supply `"wake_up":{"mode":"manual"}`. Events remain in its inbox until the agent next runs or calls `wait_for_events`. Registration requires this delivery choice.

Use `update_session` with the retained token and `wake_up` to configure an existing session. Omitted wake-up settings preserve its receiver. Identical command settings preserve delivery receipts. Explicit manual mode stops automatic wake-up without removing pending events.

Existing registrations and credentials survive migration. A legacy session without a receiver reports `wake_up_mode: "unspecified"`. The agent supplies known wake-up details on its next reconnect, or explicitly chooses manual delivery. Existing receiver commands and accepted notification receipts remain intact.

### Read and handle events

At each new turn and after each notification, call `get_events` with `session_token`. For an ongoing review, use `wait_for_events` with `timeout_seconds: 25`. The inbox covers all session documents, including requests for files not yet attached.

Each returned event includes `bus_event_id`, an ordered `cursor`, `type`, `document_id`, and routing references. It contains no document text or private review bodies.

| Event type | Action |
| --- | --- |
| `parchment.attachment_requested` | Call `attach_document` with the event's document ID, `attachment_request_id`, and retained token. Read the latest document and feedback after attachment. |
| `parchment.feedback_available` | Call `get_feedback` with the event's binding ID, generation, and retained token. Read the latest document before changes. |

Inbox events for feedback also include the original publication's `event_id` and `feedback_cursor`. These references do not authorize acknowledgement. Read feedback first and acknowledge only handled document cursors.

Attachment acceptance or cancellation completes its bus event. Document feedback acknowledgement completes the matching feedback bus events. After reading and handling events, call `acknowledge_events` with their `bus_event_id` values in `event_ids`. It confirms completion idempotently and refuses unread or unfinished work.

A stale request or binding stops work for that event. Do not reclaim a detached file by reattaching from an old notification. Ownership changes cancel obsolete bus events and route outstanding feedback to the new binding.

### Automatic agent delivery

One dispatcher reads the common event bus and invokes the selected session's registered command for every event type. Attachment requests, comments, replies, and submitted reviews use this same wake-up path.

The executable receives one newline-terminated JSON notification through stdin. Protocol version 2 retains the event types and document routing fields. It adds `bus_event_id` and `bus_cursor` so the resumed agent can read its session inbox.

```json
{
  "protocol_version": 2,
  "type": "parchment.feedback_available",
  "bus_event_id": "BUS-EVENT-ID",
  "bus_cursor": 12,
  "delivery_id": "STABLE-WAKE-UP-ID",
  "session_id": "PARCHMENT-SESSION-ID",
  "agent_session_id": "EXISTING-AGENT-CONVERSATION-ID",
  "document_id": "DOCUMENT-ID",
  "binding_id": "BINDING-ID",
  "generation": 1,
  "event_id": "PUBLISHED-EVENT-ID",
  "cursor": 42,
  "attachment_request_id": null,
  "message": "🤖 Parchment has a queued feedback event..."
}
```

An attachment notification includes its `attachment_request_id`; feedback-specific fields are null. The `delivery_id` identifies a wake-up attempt across retries. The `bus_event_id` identifies the logical event. Reconfiguring a receiver can create a new wake-up for the same pending event.

Arguments support `{agent_session_id}`, `{message}`, `{delivery_id}`, and `{document_id}`. Expansion runs once and uses no shell. The child receives `PARCHMENT_DATA_DIR` for the same registry. Standard output and error are discarded.

Exit 0 means the host durably queued input in the original conversation. It does not acknowledge a bus event or document feedback. Hosts must serialize turns in that conversation and should deduplicate repeated `delivery_id` values.

Launch failures, nonzero exits, and a 10-second timeout trigger retries. Delays increase from 2 to 60 seconds. Workers claim 30-second leases so the app and a standalone worker can share delivery. A crash can repeat the same wake-up ID after runtime acceptance.

The app runs the dispatcher independently of agent turns. For delivery while the app is closed, supervise:

```sh
/absolute/path/to/Parchment.app/Contents/MacOS/ParchmentMCP --dispatch-events
```

The older `--dispatch-feedback` flag aliases the same worker. `register_receiver` also remains as a compatibility tool; new clients supply `wake_up` in session registration or update.

Use `get_receiver_status` to inspect pending events, feedback, attachment requests, accepted wake-ups, and retry errors. Registration proves configuration; an accepted wake-up proves runtime enqueue. Completion requires the agent to handle the event. A host without wake-up support still has a durable inbox.

## Ownership and recovery

Exactly one conversation owns a document. Multiple MCP processes can use that conversation's token. The same session can attach again without changing ownership.

Another conversation receives `DOCUMENT_ALREADY_ATTACHED` with safe owner metadata. Tokens are never returned in lists or conflicts. Transport disconnection does not release ownership.

For a handoff, the receiver first creates a session. The owner calls `handoff_document` with the receiver's session ID. The receiver then attaches with its own token.

A handoff changes the binding and generation. Requests with the old binding fail with `STALE_BINDING`. Unacknowledged feedback follows the document.

The Comments sidebar shows the owner and queued feedback count. **Disconnect Agent** releases an unavailable owner after confirmation. It preserves comments and feedback.

The local registry lives at:

```text
~/Library/Application Support/Parchment/integration.sqlite
```

SQLite stores session metadata, hashed tokens, document identities, ownership generations, feedback cursors, operation receipts, and receiver commands. Its common session event bus and wake-up outbox preserve pending events, delivery receipts, and retry state. It uses WAL transactions and full synchronization.

The companion file stores the stable `documentID`. Opening a copied sidecar assigns a new ID when the original still exists. File moves preserve identity through the registry and companion. Save As creates a separate identity for a previously saved document.

The app uses a private Unix socket under `/tmp/parchment-<uid>-<directory-hash>/`. Socket permissions and peer checks restrict access to the current macOS user. There is no network listener.

This is a local trust boundary. Other processes under the same macOS account can read local files. Pending reviews are excluded from MCP delivery, not encrypted.

## Feedback and edits

An immediate comment or user reply creates one durable event. A submitted review creates one event with its comments, replies, summary, and anchors.

Pending comments, replies, and unsubmitted reviews never enter feedback or document exports. Agent replies and resolutions do not create feedback loops.

Feedback remains queued across app and helper restarts. An acknowledgement advances a durable cursor. It does not delete discussion history. Historical published comments become available on first attachment.

`get_document` returns a SHA-256 revision of the live text. `apply_patch` requires that revision. A user edit before the patch causes `REVISION_CONFLICT`.

Each replacement contains `old_text` and `new_text`. Without `start`, the old text must occur exactly once. Insertions and repeated passages require an explicit offset.

Offsets use zero-based UTF-16 code units. Edits refer to the same original revision. Overlapping edits and offsets inside Unicode characters fail.

Mutation tools require a unique `operation_id`. After a transport failure, retry with identical arguments and the same ID. Completed retries return the original result without another edit or reply.

The app records an operation before mutation. After an interrupted save, it checks the resulting revision or comment event before replay. Ambiguous recovery returns `OPERATION_INDETERMINATE` for inspection.

Patches use the native text view and document undo manager. Saved files update on disk. Unsaved documents update their local recovery snapshot. The preview follows normal editor updates.

Parchment watches open files for external changes and asks whether to reload them. Keeping local text pauses autosave until an explicit save. Local text and the paused state survive restarts. Reloading preserves local comments and review drafts. Agents attached through MCP must use `apply_patch` for live changes to preserve native undo and avoid external-change prompts.

## Verification

```sh
swift build --build-system native
python3 scripts/check-integration.py
python3 scripts/check-delivery.py
python3 scripts/check-event-bus.py
python3 scripts/check-bus-migration.py
./scripts/build-app.sh
python3 scripts/check-integration.py --app dist/Parchment.app/Contents/MacOS/Parchment --mcp dist/Parchment.app/Contents/MacOS/ParchmentMCP
```

The integration checks use temporary storage and a headless app process. They exercise the actual app model, socket, registry, and MCP subprocesses. Test-only API methods require `--integration-test-server`; normal app launches do not expose them.
