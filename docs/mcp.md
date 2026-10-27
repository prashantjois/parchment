# Parchment MCP integration

Parchment connects a document to an existing agent conversation through local MCP tools. It never starts an agent.

The agent can open Parchment, attach a file, read published feedback, and edit the live document. Pending reviews remain private until submission.

## Client configuration

Build the app with `bash scripts/build-app.sh`. Add this server to your MCP client's configuration:

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

If you install the helper separately, set `PARCHMENT_APP_PATH` to the absolute app bundle path. The bundled helper locates its own app.

For isolated development, set `PARCHMENT_DATA_DIR` to a separate directory. The helper passes this directory to an app that it launches.

## Conversation workflow

1. Create the Markdown file with the agent's normal file tools.
2. Call `create_session` once for the current conversation.
3. Retain the returned `session_token` in that conversation.
4. Call `open_document` with the file path, `attach: true`, and the token.
5. Retain the returned `binding_id` and `generation`.
6. Call `wait_for_feedback` with those three credentials.
7. Read the current document before each change.
8. Apply changes with `apply_patch` and the latest revision.
9. Reply to the relevant threads or resolve them as appropriate.
10. Acknowledge the last handled feedback cursor.
11. Call `wait_for_feedback` again.

An existing file uses the same workflow. `open_document` opens or activates its tab without overwriting the file. `attach_document` accepts a path or document ID.

Example calls:

```json
{"name":"create_session","arguments":{"client":"My agent","conversation_label":"Design document review"}}
{"name":"open_document","arguments":{"path":"/Users/me/design.md","attach":true,"session_token":"TOKEN"}}
{"name":"wait_for_feedback","arguments":{"session_token":"TOKEN","binding_id":"BINDING","generation":1,"timeout_seconds":25}}
{"name":"get_document","arguments":{"document_id":"DOCUMENT"}}
{"name":"apply_patch","arguments":{"session_token":"TOKEN","binding_id":"BINDING","generation":1,"operation_id":"UNIQUE-UUID","expected_revision":"REVISION","edits":[{"old_text":"Original passage","new_text":"Revised passage"}]}}
{"name":"acknowledge_feedback","arguments":{"session_token":"TOKEN","binding_id":"BINDING","generation":1,"cursor":42}}
```

These are `tools/call` parameters. A client supplies the JSON-RPC envelope.

The wait tool returns within 25 seconds and supports cancellation. Empty responses require another call. Delivery repeats until the agent acknowledges it.

**A generic MCP server cannot wake a finished agent conversation.** The original conversation must remain active and call the wait tool. Automatic resumption needs a client-specific adapter. No such adapter is included in this client-neutral version.

The conversation label identifies the owner in Parchment. An optional `conversation_id` records the client's conversation reference. Neither field routes messages into a client.

## Tools

| Tool | Behavior |
| --- | --- |
| `create_session` | Creates a conversation identity and returns its secret token once. |
| `resume_session` | Validates a token after reconnection. |
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

SQLite stores document IDs, canonical paths, hashed session tokens, ownership generations, feedback cursors, and operation receipts. It uses WAL transactions and full synchronization.

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
bash scripts/build-app.sh
python3 scripts/check-integration.py --app dist/Parchment.app/Contents/MacOS/Parchment --mcp dist/Parchment.app/Contents/MacOS/ParchmentMCP
```

The integration checks use temporary storage and a headless app process. They exercise the actual app model, socket, registry, and MCP subprocesses. Test-only API methods require `--integration-test-server`; normal app launches do not expose them.
