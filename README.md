# Parchment

Parchment is an AI-native Markdown editor for macOS 14 or later. Write, review, and revise local documents together with your agent.

See [Version history](docs/versions.md) for release dates, build numbers, and changes.

## Install and open

Use the macOS installer (`.pkg`) to install or upgrade Parchment. Local installers are in `dist/`; their names include the version and architecture.

1. Quit Parchment before an upgrade.
2. Open the latest installer for your Mac in Finder, such as `dist/Parchment-0.1.10-arm64.pkg`.
3. Choose the installer options for the agent skill, `parchment://` links, and the default app for Markdown files.
4. Complete the installation.
5. Open Parchment from Applications or Spotlight.

The installer places the app in `/Applications/Parchment.app`. Normal editor use requires no network connection.

### Build from source

Source builds require Apple command-line developer tools and Swift 6.2 or later. The first build downloads Apple's Swift Markdown parser and its cmark dependency.

To create an installer from this checkout, run:

```sh
bash scripts/build-installer.sh
```

For development, build and open the app directly:

```sh
bash scripts/build-app.sh
open dist/Parchment.app
```

The app bundle uses a local ad hoc signature. It is not notarized for distribution.

This machine's default Swift build backend fails during initialization. The build script uses the alternate `native` backend.

## App help

In Parchment, choose **Help → Editing Guide** for editor modes, navigation, keyboard shortcuts, and file recovery.

Choose **Help → Comments Guide** for comments, reviews, unread replies, and feedback exports.

See [the editing guide](docs/help/editing.md) and [the comments guide](docs/help/comments.md) in this repository.

## Themes

Ten themes include light and dark palettes: Native, Parchment, Editorial, Terminal, Nordic, Ocean, Forest, Rose, Graphite, and Bookish.

The theme panel provides appearance, font, size, and text-color settings. It also supports CSS import, preview, and custom theme copies. Custom themes live in `~/Library/Application Support/Parchment/Themes/`.

Fenced code blocks use local, language-aware syntax highlighting. Supported languages include Swift, Kotlin, Java, JavaScript, TypeScript, Python, JSON, Bash, SQL, and YAML. Themes control the colors for comments, keywords, strings, numbers, functions, and types. Unspecified and unsupported languages remain plain text.

See [the CSS theme format](docs/theming.md) and [the sample themes](themes/).

## MCP integration

The bundled `ParchmentMCP` helper connects documents to existing agent conversations. Agents can open the app, list live tabs, attach files, receive published feedback, and apply revision-checked edits.

Only one agent session can own a document. If agents attach concurrently, one becomes the owner; the others receive `DOCUMENT_ALREADY_ATTACHED`. Explicit handoff transfers ownership and unhandled feedback. Other agents can read the document and published comments. Reading the feedback queue and applying edits require owner credentials.

Published comments queue while the agent handles earlier feedback. Each submitted review forms one batch. Feedback stays pending until the agent acknowledges it. Pending reviews stay private until submission. Ownership, feedback, and acknowledgements survive restarts.

Each comment has an event ID and thread ID. Each notification has a stable delivery ID for retries. Runtime acceptance means that the notification reached the agent's input queue. Fetching means that the agent retrieved feedback. Acknowledgement means that the agent handled the feedback. Fetching does not identify the comment currently in progress. The Comments sidebar counts feedback awaiting acknowledgement. It also shows the owner and offers an explicit disconnect action.

Configure your MCP client with `dist/Parchment.app/Contents/MacOS/ParchmentMCP` as an absolute executable path. See [MCP setup and workflow](docs/mcp.md).

Published feedback can notify the owning agent after its turn ends. Register the existing agent session and its runtime queue command through `register_receiver`. Parchment delivers notifications with durable retries; the agent reads and acknowledges feedback through MCP. The protocol works across models and frameworks with a supported runtime queue interface. Without a receiver, the wait tool works within an active conversation. See [automatic agent delivery](docs/mcp.md#automatic-agent-delivery).

The loadable [Parchment agent skill](skills/parchment/SKILL.md) makes Parchment the default for Markdown document work. It covers document attachment, live edits, published feedback, review sessions, and conflict recovery. Load the file directly, or install the `skills/parchment` folder in your agent's skill directory. The skill requires the Parchment MCP connection described above.

## Parchment links

Links such as `parchment://Users/me/notes.md?line=42` open or focus a local file in Parchment. The path after `parchment://` names an absolute local file. The optional line number is one-based. Encode spaces as `%20` and reserved characters such as `+`, `#`, `%`, and `?`. Existing `parchment://open?path=...&line=42` links also work.

In cmux, Cmd-click a Parchment hyperlink to open it without changing cmux's file-preview settings. Terminal programs can emit OSC 8 hyperlinks when their Markdown renderer does not support custom URL schemes. The [agent skill](skills/parchment/SKILL.md) includes examples.

The build script registers the scheme with macOS. Links preserve unsaved edits and existing agent ownership. They open files but do not create them or attach conversations. MCP document responses include an `open_url` for saved files.

## Current limits

- Markdown supports CommonMark and GFM tables, task lists, and strikethrough. Raw HTML appears as escaped text. Math, diagrams, and footnotes are not enabled.
- Local raster images render. Remote images stay blocked by default. In Settings → General, toggle **Automatically load remote images**. Right-click a blocked image to **Load This Image** or **Automatically Load All Remote Images**. The latter enables the setting for every document. Image paste and asset management are not implemented.
- Scroll synchronization uses document proportions, not exact block alignment.
- Parchment watches open files for external changes and asks whether to load the external version or keep your local text. Keeping local text pauses autosave until an explicit save. The local text and paused state survive restarts. Reloading preserves local comments and review drafts.
- Published comments have flat replies and an immutable event history. Pending review drafts support editing and deletion.
