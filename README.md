# Parchment

Parchment is an AI-native Markdown editor for macOS 14 or later. Write, review, and revise local documents together with your agent.

## Build and open

The build requires Apple command-line developer tools and Swift 6.2 or later. The first build downloads Apple's Swift Markdown parser and its cmark dependency. Normal editor use requires no network connection.

```sh
bash scripts/build-app.sh
open dist/Parchment.app
```

The app bundle uses a local ad hoc signature. It is not notarized for distribution.

This machine's default Swift build backend fails during initialization. The build script uses the alternate `native` backend. A future Swift toolchain can remove that option after the default backend works.

## Editing

Each file opens in a tab. An already open file activates its existing tab. Each file remembers its view mode, sidebar widths, split divider, cursor, and scroll position.

Raw mode provides native text editing, selection, cut/copy/paste, undo/redo, find and replace, spelling, formatting shortcuts, and automatic list continuation. Tab and Shift-Tab indent and outdent selected lines. `⌘]` and `⌘[` also change indentation. Rendered mode is a read-only preview. Split mode shows both views with proportional scroll synchronization. The preview updates about 180 milliseconds after a typing pause. Rendered content fills the pane width with 16-pixel side margins by default.

The file browser starts in the current file's folder. An unsaved document starts in the user's home folder. The browser supports expandable folders and parent navigation.

The right sidebar shows either the table of contents or comments. Its two toolbar buttons select the panel. Clicking the active panel's button closes the sidebar. The file browser remains independent.

| Toolbar action | Shortcut |
| --- | --- |
| File Browser | `Control-N` |
| Split View | `Control-S` |
| Rendered Only | `Control-R` |
| Raw Only | `Control-E` |
| Table of Contents | `Control-T` |
| Themes | `⌘5` |
| Comments | `⌘6` |
| Add Comment | `Control-M` |

`Control-R` and `Control-E` select their views directly, including from Split mode. The toolbar Raw / Rendered button opens Rendered from Split and otherwise switches between Raw and Rendered. Turning Split off restores the previous single-pane mode. Standard commands include `⌘N`, `⌘O`, `⌘S`, `⌘⇧S`, and `⌘W`. `⌘⇧[` and `⌘⇧]` switch tabs.

Existing files autosave after an edit pause. Unsaved drafts and open tabs use local recovery data in `~/Library/Application Support/Parchment/`. Closing a nonempty unsaved tab prompts for Save, Cancel, or Discard. Quitting preserves unsaved drafts for the next launch.

## Themes

Ten themes include light and dark palettes: Native, Parchment, Editorial, Terminal, Nordic, Ocean, Forest, Rose, Graphite, and Bookish.

The theme panel provides appearance, font, size, and text-color settings. It also supports CSS import, preview, and custom theme copies. Custom themes live in `~/Library/Application Support/Parchment/Themes/`.

Fenced code blocks use local, language-aware syntax highlighting. Supported languages include Swift, Kotlin, Java, JavaScript, TypeScript, Python, JSON, Bash, SQL, and YAML. Themes control the colors for comments, keywords, strings, numbers, functions, and types. Unspecified and unsupported languages remain plain text.

See [the CSS theme format](docs/theming.md) and [the sample themes](themes/).

## Comments

Select text in Raw or Rendered mode to see a small floating **Comment** button. You can also right-click the selection or press `Control-M`. The floating button preserves the selection and leaves keyboard focus in the editor.

The composer offers **Comment Now** for immediate publication and **Start a Review** for a pending comment. During a review, **Add to Review** adds further pending comments. **Comment Now** remains available for individual comments that need immediate publication.

The Comments sidebar shows the pending count and a **Finish Review** button. The submission sheet lists pending feedback and accepts an optional summary. **Submit Review** publishes all pending comments and replies together. Pending drafts can be edited or deleted. **Discard** removes the pending review without removing published discussion.

Each comment starts one flat reply thread. Threads support resolution, reopening, history, and manual reattachment after text changes. The Open, Pending, Resolved, and All filters separate discussion states. The All view includes submitted review summaries and discarded-review history.

Pending reviews survive autosave and session restoration. Agent exports exclude pending comments, pending replies, and unsubmitted reviews, including exports with `--include-resolved`.

The app stores comments in `<filename>.comments.json` beside the Markdown file. Markdown content stays free of annotation markup.

The File menu exports open comments with the current document text, source hash, and anchor status. The command-line entry point also exports comments:

```sh
dist/Parchment.app/Contents/MacOS/Parchment --export-comments /path/to/notes.md > review.json
dist/Parchment.app/Contents/MacOS/Parchment --export-comments /path/to/notes.md --include-resolved > history.json
```

The CLI reads saved files. It does not send data to an agent or start an agent. See [the companion file contract](docs/comments.md).

## MCP integration

The bundled `ParchmentMCP` helper connects documents to existing agent conversations. Agents can open the app, list live tabs, attach files, receive published feedback, and apply revision-checked edits.

One conversation owns each document. Pending reviews stay private until submission. Ownership, feedback, and acknowledgements survive restarts. The Comments sidebar shows the owner and offers an explicit disconnect action.

Configure your MCP client with `dist/Parchment.app/Contents/MacOS/ParchmentMCP` as an absolute executable path. See [MCP setup and workflow](docs/mcp.md).

Published feedback can notify the owning agent after its turn ends. Register the existing agent session and its runtime queue command through `register_receiver`. Parchment delivers notifications with durable retries; the agent reads and acknowledges feedback through MCP. The protocol works across models and frameworks with a supported runtime queue interface. Without a receiver, the wait tool works within an active conversation. See [automatic agent delivery](docs/mcp.md#automatic-agent-delivery).

The loadable [Parchment agent skill](skills/parchment/SKILL.md) makes Parchment the default for Markdown document work. It covers document attachment, live edits, published feedback, review sessions, and conflict recovery. Load the file directly, or install the `skills/parchment` folder in your agent's skill directory. The skill requires the Parchment MCP connection described above.

## Parchment links

Links such as `parchment://Users/me/notes.md?line=42` open or focus a local file in Parchment. The path after `parchment://` names an absolute local file. The optional line number is one-based. Encode spaces as `%20` and reserved characters such as `+`, `#`, `%`, and `?`. Existing `parchment://open?path=...&line=42` links also work.

In cmux, Cmd-click a Parchment hyperlink to open it without changing cmux's file-preview settings. Terminal programs can emit OSC 8 hyperlinks when their Markdown renderer does not support custom URL schemes. The [agent skill](skills/parchment/SKILL.md) includes examples.

The build script registers the scheme with macOS. Links preserve unsaved edits and existing agent ownership. They open files but do not create them or attach conversations. MCP document responses include an `open_url` for saved files.

## Checks

```sh
swift run --build-system native ParchmentChecks
dist/Parchment.app/Contents/MacOS/Parchment --check-themes
dist/Parchment.app/Contents/MacOS/Parchment --check-storage
dist/Parchment.app/Contents/MacOS/Parchment --check-editor
python3 scripts/check-integration.py --app dist/Parchment.app/Contents/MacOS/Parchment --mcp dist/Parchment.app/Contents/MacOS/ParchmentMCP
python3 scripts/check-delivery.py --app dist/Parchment.app/Contents/MacOS/Parchment --mcp dist/Parchment.app/Contents/MacOS/ParchmentMCP
```

The core checks use a standalone Swift executable so they work with command-line developer tools without XCTest. They cover anchors, Unicode offsets, ambiguity, history, serialization, export, layout persistence, and HTML escaping. The headless WebKit checks cover all ten themes in both appearances, rendered selection mapping, and comment highlights. Storage checks use temporary files to verify tabs, companions, session restoration, and draft recovery. Editor checks cover native editing, undo/redo, clipboard operations, indentation, live previews, and shortcut routing.

## Current limits

- Markdown supports CommonMark and GFM tables, task lists, and strikethrough. Raw HTML appears as escaped text. Math, diagrams, and footnotes are not enabled.
- Local raster images render. Remote images stay blocked by default. In Settings → General, toggle **Automatically load remote images**. Right-click a blocked image to **Load This Image** or **Automatically Load All Remote Images**. The latter enables the setting for every document. Image paste and asset management are not implemented.
- Scroll synchronization uses document proportions, not exact block alignment.
- Parchment watches open files for external changes and asks whether to load the external version or keep your local text. Keeping local text pauses autosave until an explicit save. The local text and paused state survive restarts. Reloading preserves local comments and review drafts.
- Published comments have flat replies and an immutable event history. Pending review drafts support editing and deletion.
