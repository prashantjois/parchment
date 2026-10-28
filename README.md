# Parchment

Parchment is an AI-native Markdown editor for macOS 14 or later. Write, review, and revise local documents together with your agent.

See [Version history](docs/versions.md) for release dates, build numbers, and changes.

## Install and open

Use the macOS installer (`.pkg`) to install or upgrade Parchment. Download it from [the latest GitHub Release](https://github.com/prashantjois/parchment/releases/latest). Each release includes the installer and its SHA-256 checksum. Installer names include the version and architecture.

1. Quit Parchment before an upgrade.
2. Open the installer for your Mac in Finder.
3. Choose the options for the agent skill, `parchment://` links, and the default app for Markdown files.
4. Complete the installation.
5. Open Parchment from Applications or Spotlight.

The installer places the app in `/Applications/Parchment.app`. All three setup options are selected by default, including the default Markdown app. Clear an option to skip it. Normal editor use requires no network connection. Local builds and installers are in `dist/`, which Git excludes.

### macOS security prompt

The installer is unsigned. The app uses an ad hoc signature, and Apple has not notarized it. macOS can block the download with an “Apple could not verify” malware warning.

If you trust this release and macOS blocks it:

1. Try to open the installer once.
2. Open **System Settings → Privacy & Security**.
3. Under **Security**, click **Open Anyway** for the Parchment installer.
4. Authenticate and approve opening the installer.

If macOS blocks the installed app, repeat these steps for Parchment. See [Apple's instructions](https://support.apple.com/en-us/102445).

### Install from Terminal

From this checkout, run:

```sh
bash scripts/install.sh
```

The script first asks which version to install. Press Enter for `latest`, or enter a version such as `0.1.26`. The default always selects the latest published GitHub Release, including from a source checkout.

The script reuses a matching installer in `dist/` when available. Otherwise, it downloads the selected version. If that version is unpublished and has no local installer, installation stops. Build it with `bash scripts/build-installer.sh`, then select that version explicitly or supply its package path.

Use `--version VERSION` or `--package PATH` to skip the version question. If the release lookup is unavailable, use an explicit version with a matching local installer, or supply its package path.

The script verifies the package checksum before installation. It runs macOS's command-line installer with the same setup actions as the graphical installer. Only the installation step requests administrator access. Run the script without `sudo`.

After verification, the script requests a normal quit from any running Parchment app before installation. Parchment saves its session recovery data as usual. The script waits up to 30 seconds. If the app refuses or remains open, installation stops without a forced quit. Resolve any save dialogs, then run the script again. A dry run leaves the app running.

The script requires no Swift toolchain, Python, or GitHub CLI. It avoids opening the package in Finder, but it does not sign or notarize Parchment. A first-launch security prompt can still require **Open Anyway**.

The script asks for a version and three setup choices:

```text
Version to install [latest]:
Install the Parchment agent skill in ~/.agents/skills/parchment? [Y/n]
Register parchment:// links now? [Y/n]
Make Parchment the default app for .md and .markdown files? [Y/n]
```

Enter a version or `latest` for the first question. Enter `y` or `n` for each setup question. Press Enter to accept each default. All three setup defaults match the graphical installer: on.

Flags answer individual questions. The script still asks about any choice without an explicit answer.

| Setup action | Yes flag | No flag |
| --- | --- | --- |
| Install the agent skill | `--install-skill` | `--skip-skill` |
| Register `parchment://` links immediately | `--register` | `--skip-register` |
| Set the default app for `.md` and `.markdown` files | `--markdown-default` | `--skip-markdown-default` |

Use `--yes` to skip all questions and accept defaults for unspecified choices. Without interactive input, supply `--yes`, or a version/package flag and explicit answers for all three setup choices. If input ends during a prompt, the script cancels installation.

The skill installer backs up a different existing copy. Skipping link registration preserves existing registrations. The default app choice leaves `.txt` files unchanged. MCP client configuration remains a separate step.

To skip setup questions, omit the skill, register links, and set Markdown file associations, run:

```sh
bash scripts/install.sh --yes --skip-skill --markdown-default
```

To install a local build, keep its `.pkg.sha256` file beside the package and run:

```sh
bash scripts/install.sh --package dist/Parchment-0.1.26-arm64.pkg
```

Use `--version 0.1.26` to select that version, or `--version latest` to select the latest published release. Add `--dry-run` to verify the package and inspect the choices without installation. `--help` lists all options. A checksum verifies file integrity; it does not certify that the software is free of malware.

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

A client must preserve the complete custom URL for a Parchment link to work. Some terminal chat renderers omit custom-scheme hyperlinks. cmux can then detect the Markdown file path and open its own preview. An inline code span does not guarantee a clickable Parchment link.

If a terminal link opens in cmux, open the document through Parchment's MCP tools or run:

```sh
open 'parchment://Users/me/notes.md?line=42'
```

Standalone terminal programs can emit OSC 8 hyperlinks with the complete URL. A chat renderer can still strip these control sequences from tool output. The [agent skill](skills/parchment/SKILL.md) includes an example for direct terminal output.

The build script registers the scheme with macOS. Document links select Rendered mode, including when the target tab was open in Raw or Split mode. They preserve unsaved edits and existing agent ownership. Back restores the previous mode and position. Links open files but do not create them or attach conversations. MCP document responses include an `open_url` for saved files.

## Current limits

- Markdown supports CommonMark and GFM tables, task lists, and strikethrough. Raw HTML appears as escaped text. Math, diagrams, and footnotes are not enabled.
- Local raster images render. Remote images stay blocked by default. In Settings → General, toggle **Automatically load remote images**. Right-click a blocked image to **Load This Image** or **Automatically Load All Remote Images**. The latter enables the setting for every document. Image paste and asset management are not implemented.
- Scroll synchronization uses document proportions, not exact block alignment.
- Parchment watches open files for external changes and asks whether to load the external version or keep your local text. Keeping local text pauses autosave until an explicit save. The local text and paused state survive restarts. Reloading preserves local comments and review drafts.
- Published comments have flat replies and an immutable event history. Pending review drafts support editing and deletion.
