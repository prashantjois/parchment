# Comment companion format, versions 2 and 3

For `notes.md`, comments live in `notes.md.comments.json`. The app writes UTF-8 JSON atomically. The Markdown file contains no comment markers.

The root object contains `formatVersion`, `document` (the Markdown filename), `threads`, optional `documentID`, and an optional `reviews` array. Each thread has a UUID, an `originalAnchor`, and an `events` array. Published events are immutable. Pending comment and reply bodies can be edited or removed before submission.

`documentID` gives MCP attachments a stable identity. New saves include it even when a document has no comments. Files with this identity can retain comments after a filename change. The registry gives copied companions separate identities when the original still exists.

The reader accepts versions 1, 2, and 3. Version 1 comments are published. Version 2 adds pending reviews and prevents older readers from treating drafts as published comments. Companions containing file-level comments use version 3 so older readers cannot discard their scope. Selection-only companions remain compatible with version 2.

## Reviews and publication

A review contains `id`, `author`, `startedAt`, optional `submittedAt`, optional `discardedAt`, and an optional `summary`. A review with neither completion timestamp is pending. Each file has at most one active review.

Threads and events can carry `reviewID` and `publishedAt`. A record with a review ID and no publication timestamp is pending. A record without a review ID is an immediate, published comment or event. This rule also covers legacy records.

Submission assigns one publication timestamp to all pending threads and events in the active review. It also records the review summary and submission time. Immediate comments made during the review remain independent.

Discarding a review removes its pending threads and pending replies on published threads. It preserves published discussion and records the review's discard time. Deleting a pending root comment also removes its pending thread.

Pending drafts are persisted beside the document and in recovery snapshots. Consumers must respect publication state. They must not treat the raw companion file's pending records as actionable feedback.

## File-level comments

A thread with `scope: "file"` applies to the whole document, including an empty file. Its `originalAnchor` is an empty placeholder. Consumers must use the scope rather than interpret that placeholder as a text selection. Its current anchor has `state: "file"` and no range. File comments remain valid after edits and do not require reattachment.

File comments support the same replies, publication rules, resolution, event history, and agent feedback as selection comments. The app provides a comment icon in each tab, a tab-name hover prompt, and Control-Shift-M.

Read/unread state is local to the current user on this Mac. It does not modify this companion, publication state, or agent acknowledgements.

## Anchors

An anchor contains:

| Field | Meaning |
| --- | --- |
| `range.location` | Zero-based UTF-16 offset in the original source |
| `range.length` | Selection length in UTF-16 code units; the end is exclusive |
| `quote` | Exact source text inside the selection |
| `prefix`, `suffix` | Up to 64 surrounding Unicode characters |
| `sourceSHA256` | SHA-256 of the original UTF-8 source, including its original line endings |
| `startLine`, `endLine` | One-based source lines for human reference |

Line numbers are advisory. A selection in the rendered view maps back to source ranges. A selection across formatting can include Markdown delimiters. An escaped or transformed leaf maps to its full source span if exact character mapping is unavailable.

The app first checks the stored range against the original source hash. After edits, it searches for the exact quote. A unique match is `moved`. Multiple matches require an exact context match. Remaining duplicate matches are `ambiguous`. Missing text is `orphaned`.

The app never guesses between ambiguous matches. The comment panel can attach a thread to a new selection. A `reanchor` event stores the new anchor and preserves the original one.

## Threads and history

Every event contains `id`, `kind`, `author`, and an ISO 8601 `timestamp`.

MCP replies and resolutions also contain `origin: "agent"` and `operationID`. These fields prevent feedback loops and duplicate events after a retry. The author starts with 🤖 and identifies the agent conversation.

- `comment`: Starts the thread. `body` contains the comment text.
- `reply`: Adds a flat reply. `body` contains the reply text.
- `resolve`: Marks the thread resolved.
- `reopen`: Marks the thread open again.
- `reanchor`: Supplies a replacement `anchor`.

Event order defines thread state. Replies have no nested reply relationships. The last resolve or reopen event determines resolution. The last reanchor event determines the active anchor.

The comment panel provides Open, Unread, Pending, Resolved, and All filters. Unread threads appear first and remain visible in Open when resolved. Each thread exposes its full event history. Resolved threads remain in the companion file.

## Agent export

An export contains `formatVersion`, `documentPath`, `sourceSHA256`, `sourceText`, `offsetEncoding`, `threads`, and submitted `reviews`. Each exported thread includes its published history, a derived `resolved` flag, and a `currentAnchor` result.

Open published threads are the default. `--include-resolved` also includes resolved published threads. Every export excludes pending threads, pending replies, and unsubmitted reviews. Each export recalculates anchors against the exported source.

An agent must compare the current source hash with the exported hash before applying edits. An ambiguous or orphaned anchor requires review. Agent edits do not automatically resolve comments. Resolution is a separate action in the app or through the MCP `resolve_thread` tool.

The app watches external edits and offers a reload prompt. Keeping local text pauses autosave until an explicit save. The [MCP integration](mcp.md) provides live text, published feedback, and revision-checked edits without closing the tab.

Unsaved documents retain comments in local recovery data. The first save creates the companion file beside the Markdown file. Save As creates a companion for the new file and preserves the old companion.
