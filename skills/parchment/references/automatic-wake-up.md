# Automatic wake-up by agent framework

Use this reference when registering or repairing Parchment wake-up delivery. Read the section for the current runtime.

## Choose a delivery route

| Framework or host | Route into the original conversation |
| --- | --- |
| Codex CLI or a compatible local Codex host | Native `codex queue` command, when installed |
| Claude Code | Claude channel adapter or a host-owned streaming-input queue |
| Claude Agent SDK | The existing client's streaming-input queue |
| Gemini CLI | The existing ACP client's prompt queue, when available |
| Cursor Agent CLI | The existing ACP client's prompt queue, when available |
| OpenCode | The existing server's session prompt API through a receiver adapter |
| Amp | The existing process's streaming JSON input through a receiver adapter |
| GitHub Copilot CLI, goose | Host integration, or a serialized resume worker owned by the host |
| Cline, Roo Code, Windsurf, other editor agents | A documented extension/host API for the selected conversation |
| Agents SDK, LangGraph, AutoGen, CrewAI, custom agents | The application's persistent inbox and conversation worker |

An adapter is a separate local program supplied by the host. Parchment does not bundle these framework adapters. MCP configuration alone does not create a wake-up route.

## Shared setup

1. Identify the current runtime and its installed version.
2. Resolve its executable to an absolute, stable path. Avoid terminal shims that disappear with a terminal window.
3. Obtain the exact conversation ID from runtime metadata, its session selector, or its API.
4. Select the supported route below. Verify its flags against the installed version's help.
5. Register the receiver in `create_session`, or repair the same Parchment session with `update_session`.
6. Call `get_receiver_status`. Check `registered: true`, `mode: "automatic"`, and `last_error`.
7. Verify delivery with a published Parchment comment or attachment request. Confirm that the original conversation receives the notification.

Use this `wake_up` shape for an adapter:

```json
{
  "mode": "command",
  "agent_session_id": "ACTUAL-RUNTIME-CONVERSATION-ID",
  "executable": "/absolute/path/to/your-installed-receiver",
  "arguments": []
}
```

The receiver reads a JSON object from stdin. It includes `agent_session_id`, `message`, `delivery_id`, and `document_id`. Argument templates can also contain `{agent_session_id}`, `{message}`, `{delivery_id}`, and `{document_id}`.

Parchment runs the executable directly, without a shell. The receiver must accept the notification within 10 seconds. Exit 0 only after saving it in a durable inbox or receiving durable acceptance from the host. Return nonzero on failure so Parchment can retry.

Deduplicate retries by `delivery_id` when the host supports it. Serialize turns for each conversation. Keep the original working directory, model, permissions, MCP setup, and conversation state. Forward `message` as data. Never construct shell code from notification content.

## Codex

Check the installed command:

```sh
command -v codex
codex queue --help
```

Obtain the current thread UUID from host metadata or the session UI. Prefer its UUID over a display name.

Use the resolved executable path in `wake_up`. For example, an installation at `/opt/homebrew/bin/codex` uses:

```json
{
  "mode": "command",
  "agent_session_id": "ACTUAL-CODEX-THREAD-UUID",
  "executable": "/opt/homebrew/bin/codex",
  "arguments": ["queue", "--thread", "{agent_session_id}", "--message", "{message}"]
}
```

The queue targets the existing thread. It does not start another `codex exec` conversation. For a remote host, include its existing `--remote` endpoint and authentication environment configuration.

If installed help supports `queue --resume`, use it when the host must resume a stopped thread. Check actual receipt: this option can warn about a failed resume while still accepting the queued message. Older versions without `queue` need a host adapter or manual delivery.

Sources: [official Codex command reference](https://developers.openai.com/codex/cli/reference), plus the installed `codex queue --help` for version-specific options.

## Claude Code and Claude Agent SDK

For an interactive Claude Code session, use a host-provided Claude channel adapter:

1. Follow the [channel reference](https://code.claude.com/docs/en/channels-reference) to configure a local channel server and its receiver command.
2. Give the adapter a durable inbox for this exact conversation. Map the Parchment runtime ID to that inbox.
3. Enable the channel through the host's supported channel configuration. Custom development channels require the documented development flag and interactive confirmation.
4. Configure the channel server to emit `notifications/claude/channel` with the notification message as `params.content`.
5. Register the adapter's receiver executable in Parchment using the shared setup.

Channels require a running session and supported account/organization settings. The standard `ParchmentMCP` server does not declare the Claude channel capability. Adding it as an ordinary MCP server does not enable push delivery.

For a host built with Claude Agent SDK, enqueue the notification into the existing client's streaming input. The host must retain the client, process output, and handle permissions. Register its enqueue executable, which returns after durable acceptance.

`claude --resume SESSION_ID --print PROMPT` runs a resumed turn in another process. Use that only behind a host-owned serialized worker when the original process has released the conversation. Do not register it directly as the receiver: a full turn can exceed Parchment's 10-second acceptance timeout.

Sources: [Claude channels](https://code.claude.com/docs/en/channels), [streaming input](https://code.claude.com/docs/en/agent-sdk/streaming-vs-single-mode), [CLI reference](https://code.claude.com/docs/en/cli-reference).

## Gemini CLI

Current Gemini releases start ACP mode with `gemini --acp`. Check `gemini --help` for the installed version.

For an ACP-hosted Gemini conversation:

1. Use the ACP client that already owns the session. Discover its actual session ID from that client.
2. Configure its receiver to save notifications in the conversation's inbox.
3. Have the client send `session/prompt` with that same `sessionId` and the notification as a text prompt.
4. Queue messages while a turn is running. Keep the client available to handle tools and permission requests.
5. Register the client's enqueue executable in Parchment.

ACP support varies by installed Gemini version and host. Check the advertised capabilities before using session loading. Starting a new ACP process does not attach it to an existing interactive terminal session.

For a plain CLI session without a host queue, check `gemini --help` and `gemini --list-sessions`. A host-owned worker can resume the exact saved UUID with `gemini --resume SESSION_UUID --prompt PROMPT` after the original process stops. Preserve its project directory. Use the shared serialized-worker contract below; otherwise register manual delivery.

Sources: [Gemini ACP mode](https://geminicli.com/docs/cli/acp-mode/), [session management](https://geminicli.com/docs/cli/session-management/), [headless mode](https://geminicli.com/docs/cli/headless/).

## Cursor Agent CLI

Cursor supports an ACP client connection through `agent acp` in current releases. Use the existing client's session ID and enqueue receiver. Follow the same ACP route described for Gemini.

The client's request targets the existing conversation:

```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "method": "session/prompt",
  "params": {
    "sessionId": "ACTUAL-ACP-SESSION-ID",
    "prompt": [{"type": "text", "text": "PARCHMENT-NOTIFICATION-MESSAGE"}]
  }
}
```

The host allocates the JSON-RPC request ID and queues this request after any active turn. This example goes through the established ACP connection, not Parchment's MCP connection.

For a plain CLI session, inspect `agent --help` and `agent ls`. Older installations use `cursor-agent`. A serialized worker can use `agent --resume CHAT_ID --print PROMPT` after exclusive ownership passes to it. This does not inject input into a running editor conversation. Without a host integration, use manual delivery.

Sources: [Cursor ACP](https://cursor.com/docs/cli/acp), [CLI parameters](https://cursor.com/docs/cli/reference/parameters), [ACP prompt lifecycle](https://agentclientprotocol.com/protocol/prompt-turn).

## OpenCode

Use the HTTP server attached to the current OpenCode conversation. Obtain its endpoint and session ID from that host. Starting another `opencode serve` process does not select the existing server.

Configure a receiver adapter to enqueue the notification and submit it to:

```text
POST /session/ACTUAL-SESSION-ID/prompt_async
Content-Type: application/json

{"parts":[{"type":"text","text":"PARCHMENT-NOTIFICATION-MESSAGE"}]}
```

Read the running server's `/doc` schema before implementation. Preserve its directory context and authentication. Queue while the session is busy, unless that server version explicitly supports ordered admission. Treat HTTP errors as delivery failures. An asynchronous HTTP response alone does not establish crash-safe persistence; keep the adapter's durable inbox until the host confirms admission.

Register the adapter executable in Parchment. Do not register a long-running `opencode run` turn as the receiver.

Source: [OpenCode server API](https://opencode.ai/docs/server/).

## Amp

An Amp host can keep the original thread connected through streaming JSON input:

```sh
amp threads continue ACTUAL-THREAD-ID --execute --stream-json --stream-json-input
```

Verify those flags with the installed help. Keep stdin open and read stdout continuously. Configure a receiver that durably queues messages for that existing process. The host forwards each message as one JSON line:

```json
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"PARCHMENT-NOTIFICATION-MESSAGE"}]}}
```

Use the actual `T-…` thread ID. Avoid `--last`. Preserve the current mode and settings. A separate `amp threads continue` process is a resume operation; it does not enqueue into an already-running CLI. Transfer process ownership to the host before using this route.

Sources: [Amp streaming JSON](https://ampcode.com/docs/cli/streaming-json), [threads](https://ampcode.com/docs/threads).

## GitHub Copilot CLI and goose

Inspect the installed host for an API or enqueue command that targets the current session. Register that receiver when available.

For a host-owned worker, these commands can resume saved sessions after the original process releases them:

| Runtime | Resumed worker command |
| --- | --- |
| GitHub Copilot CLI | `copilot --resume=SESSION_ID -p PROMPT` |
| goose | `goose run --resume --session-id SESSION_ID --text PROMPT` |

Discover the exact ID through the host's session UI or documented session commands. Verify the options against installed help. Follow the serialized-worker contract below. Neither command is a durable enqueue interface for a running conversation.

Sources: [Copilot CLI reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference), [goose session management](https://goose-docs.ai/docs/guides/sessions/session-management/).

## Editor agents: Cline, Roo Code, Windsurf, and similar hosts

Check the installed extension's documented integration API for sending a prompt to an exact existing task. Use a host-provided adapter only after verifying its conversation targeting and acceptance behavior.

Configure that adapter with the selected task ID, project, and existing runtime settings. Register its local enqueue executable in Parchment. Verify that a test notification appears in the same task. Do not substitute a new task, a terminal keystroke, or an invented CLI command.

If the installed host exposes no supported input route, use manual delivery. Ordinary MCP tools and file-change hooks do not prove that the host can start another turn.

## Application frameworks and SDKs

These frameworks require application code that owns delivery. They do not share a universal wake-up CLI.

1. Add a durable inbox keyed by the application's actual conversation ID and `delivery_id`.
2. Expose a local executable that saves the Parchment stdin payload and returns within 10 seconds.
3. Have the application's existing worker process the inbox under a conversation lock.
4. Restore the same conversation state and settings before supplying the notification as the next input.
5. Keep the existing Parchment token in the conversation's private state. Process `get_events` before document changes.

| Framework | State to preserve in the application worker |
| --- | --- |
| OpenAI Agents SDK | Existing session/history and agent configuration |
| Claude Agent SDK | Existing client and streaming input, or its explicitly resumed session |
| LangGraph / LangChain | Existing checkpointer and `thread_id` |
| AutoGen | Existing agent/team state and conversation routing |
| CrewAI | Existing application/Flow state and conversation routing |

For LangGraph, a checkpoint `thread_id` identifies persisted state; it is not a running-process input queue. For AutoGen and CrewAI, restoring state still needs an application worker. Apply the shared receiver contract to each framework.

Sources: [OpenAI agents](https://developers.openai.com/api/docs/guides/agents), [LangGraph persistence](https://docs.langchain.com/oss/python/langgraph/persistence), [AutoGen state](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/tutorial/state.html).

## Serialized resume worker and manual fallback

A resume worker is an integration supplied by the host. Use one only when it can retain the original conversation identity and private credentials.

The receiver saves the notification and returns promptly. A separate supervised worker acquires exclusive ownership, resumes the exact conversation, processes the event, and saves its result. It must not run concurrently with the original agent or fork the conversation. Process shutdown and retry recovery belong to the host.

If no supported queue, adapter, or worker exists, register:

```json
{"mode":"manual"}
```

State the specific missing capability. Events remain queued until the conversation runs again. During an active review, use `wait_for_events` with `timeout_seconds: 25`. Polling cannot start a finished agent turn.

Keep a persistent MCP or `ParchmentMCP --bridge` connection open while the conversation is available. It sends keep-alives every 10 seconds, including while idle. `--call` exits after one request and cannot keep an idle session listed. Wake-up registration and keep-alive presence are separate: one routes notifications, and the other keeps the session selectable.
