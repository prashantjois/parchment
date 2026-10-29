# Parchment version history

Dates use America/Chicago time. These are local Apple Silicon installer builds. The tracker combines this development session, git history, and archived installer metadata.

| Version | Build | Date | Source | Changes |
| --- | --- | --- | --- | --- |
| 0.1.32 | 33 | 2026-10-29 | Current release | Combined tab attachment menus into Sessions, with check marks and click actions to attach, detach, or cancel a request. |
| 0.1.31 | 32 | 2026-10-29 | `dafb15f` | Replaced the theme collection with twenty original styles, category browsing, descriptions, and automatic selection migration. |
| 0.1.30 | 31 | 2026-10-29 | `a25ce7f` | Newly opened files always start in Rendered mode, including files previously closed in Raw or Split mode. |
| 0.1.29 | 30 | 2026-10-29 | `68c16ec` | Added session names and models, metadata synchronization, and tab menus for session inspection, attachment requests, and confirmed transfers. |
| 0.1.28 | 29 | 2026-10-28 | `fb61e02` | Fixed editing crashes during composed input and stabilized native editor and preview refresh layout. |
| 0.1.27 | 28 | 2026-10-28 | `24db304` | Changed installer version selection to local releases with numeric ordering and architecture filtering. |
| 0.1.26 | 27 | 2026-10-28 | `4a0aaae` | Enabled Markdown association by default and added an installer version prompt with latest as its default. |
| 0.1.25 | 26 | 2026-10-28 | `2c0576f` | Moved tab hover prompts below tabs, repaired Open Recent, and added app-wide System, Light, and Dark appearance. |
| 0.1.24 | 25 | 2026-10-28 | `9339823` | Added separate, always-visible horizontal scrollbars for Raw and Rendered, unwrapped Raw lines, and readable wide tables. |
| 0.1.23 | 24 | 2026-10-27 | `a7a9170` | Increased pane minimum widths, kept the horizontal scrollbar visible during overflow, and forwarded page-level WebKit wheel events. |
| 0.1.22 | 23 | 2026-10-27 | `c56d8ab` | Added minimum pane widths and horizontal editor scrolling to prevent compressed content. |
| 0.1.21 | 22 | 2026-10-27 | `7b8f8b8` | Shortened tooltips to a 300 ms delay and removed hover highlight animation. |
| 0.1.20 | 21 | 2026-10-27 | `aafbd4c` | Added consistent hover highlights and action tooltips to app buttons. |
| 0.1.19 | 20 | 2026-10-27 | `0623819` | Added Add File Comment to the tab context menu. |
| 0.1.18 | 19 | 2026-10-27 | `0b10bb2` | Document links select Rendered mode; terminal-link guidance now describes client limitations. |
| 0.1.17 | 18 | 2026-10-27 | `856d94b` | The install script requests a normal quit from running Parchment apps before installation. |
| 0.1.16 | 17 | 2026-10-27 | `46d7d0c` | Install scripts in a checkout prefer its matching local build and never select an older release silently. |
| 0.1.15 | 16 | 2026-10-27 | `84483f9` | Added tab reordering and context-menu actions to close groups of tabs. |
| 0.1.14 | 15 | 2026-10-27 | `3ef38ef` | Added interactive setup questions to the command-line installer. |
| 0.1.13 | 14 | 2026-10-27 | `f354621` | Added a command-line installer and documented macOS security prompts. |
| 0.1.12 | 13 | 2026-10-27 | `1e977f1`, tag `v0.1.12` | Moved comment and review instructions from the README to the Help menu. |
| 0.1.11 | 12 | 2026-10-27 | `a5433c1` | Moved editing instructions from the README to the Help menu. |
| 0.1.10 | 11 | 2026-10-27 | `2c6559e` | Made the installer the main README installation path. |
| 0.1.9 | 10 | 2026-10-27 | `b66bfb6` | Removed the README Checks section. |
| 0.1.8 | 9 | 2026-10-27 | `ef6cf8d` | File-level comments through tab icons, tab-name hover prompts, and Control-Shift-M. Added this version tracker. |
| 0.1.7 | 8 | 2026-10-27 | `29f58ea` | Persistent unread reply tracking, unread-first ordering, blue highlights, an Unread filter, and read/unread actions. |
| 0.1.6 | 7 | 2026-10-27 | `0eb32bd` | Back/Forward buttons and history across files, tabs, headings, and folders. Keyboard, mouse, and swipe navigation restore cursor and scroll positions. |
| 0.1.5 | 6 | 2026-10-27 | `3acd3b6`, tag `v0.1.5` | Automatic agent feedback delivery, syntax highlighting, link navigation, remote-image controls, external-change prompts, and documentation updates. |
| 0.1.4 | 5 | 2026-10-27 | `2c3a044` | Recorded the installer-options update, frontmatter hiding, and file-location copy menus. The exact installer delta from 0.1.3 was not recorded separately. |
| 0.1.3 | 4 | 2026-10-27 | Archived installer | Added the optional setting to make Parchment the default app for Markdown files. |
| 0.1.2 | 3 | 2026-10-27 | Archived installer | Added separate installer options for the agent skill and immediate registration of parchmentr:// links. |
| 0.1.1 | 2 | 2026-10-26 | `c007139` | First recorded source baseline: Markdown editing, ten themes, comments and reviews, MCP tools, agent skill, URL links, recovery, checks, and a macOS installer. |
| 0.1.0 | 1 | 2026-10-26 | Archived installer | Initial packaged app with URL-scheme registration. Detailed changes before the first source commit were not recorded. |

## 0.1.32

- The tab context menu has one Sessions submenu with all registered sessions. The attached session has a check mark.
- Clicking a checked session detaches it. Clicking an unchecked session requests attachment. Clicking a pending request cancels it.
- Transfers still require confirmation. Pending requests show delivery status until the receiving agent attaches.
- Detachment works without a receiver and affects only the selected session, including when ownership changes while the menu is open.

## 0.1.31

- Replaced the ten bundled themes with twenty new designs inspired by markdown.style, using original names and CSS.
- Themes vary typography, spacing, headings, quotes, code blocks, and tables. All include light and dark palettes and local font stacks.
- The theme picker groups styles by category and shows a short description with the live preview.
- Existing built-in selections move to similar new themes. Custom CSS and user overrides remain available.
- Packaging removes retired theme files so upgrades show the current collection.
- WebKit checks cover every theme in both appearances, text contrast, source selections, comments, and preference migration.

## 0.1.30

- Newly opened files start in Rendered mode through the file picker, Open Recent, file browser, links, and MCP.
- A saved Raw or Split preference no longer changes the initial mode. Sidebar settings, cursor, and scroll position remain available.
- Existing tabs and recovered sessions retain their selected view mode.

## 0.1.29

- Session display names include the session name, optional model, client, and a short stable ID.
- New MCP tools update session metadata in place and list registered sessions with their attached files.
- The Parchment skill checks session names and models at each turn or reconnection and synchronizes changes.
- Tab context menus show the attached owner and request attachment to another registered session through its existing receiver.
- Each file keeps one owner. Transfers require confirmation and complete when the receiving agent attaches with its own token.
- Attachment requests support durable retries, pending status, cancellation, and checks that reject delayed requests after ownership changes.
- Registry migration preserves existing session identities, tokens, attachments, feedback, and receivers.

## 0.1.28

- Deferred text-canvas sizing until native editing callbacks finish. This avoids forced TextKit layout during inline prediction and text composition.
- SwiftUI refreshes preserve marked text and synchronize committed edits without replacing the active native input buffer.
- The preview uses a native WebKit viewport directly. Refreshes no longer replace a nested SwiftUI host.
- Deferred editor refresh and scroll updates prevent model changes during layout passes.
- Regression checks cover composed input, repeated typing, stable pane sizes and scroll position, undo, and agent edits.

## 0.1.27

- The install script selects versions from local installers in dist/. Latest uses numeric major, minor, and patch ordering.
- Only this Mac’s architecture and universal packages qualify. An architecture-specific package takes priority at the same version.
- Missing packages, missing checksums, or checksum errors stop installation. No GitHub lookup or download occurs.
- The version prompt, explicit version/package flags, and Yes defaults for all setup options remain available.

## 0.1.26

- The install script and graphical installer select the default Markdown app option by default. Explicit skip flags and checkbox changes remain available.
- The script asks which version to install. Enter selects latest; an explicit version or package flag skips the question.
- Latest always selects the latest published GitHub release, including from a source checkout. Matching local installers can be reused for the selected version.
- Unattended installation accepts the latest published version and all setup defaults with --yes. Explicit local versions and packages remain available offline.

## 0.1.25

- Tab-name hover prompts appear below the full tab height so they do not cover toolbar buttons.
- Open Recent saves up to 20 available files. Its native submenu refreshes each time it opens.
- New opens, existing tabs, agent opens, and explicit saves update the recent-file list.
- Existing saved tabs seed the list after an upgrade. Duplicate and missing files are omitted.
- Clear Menu erases the saved list and remains clear after a restart.
- Settings → General and Themes offer System, Light, and Dark appearance for the whole app. The choice persists across restarts.

## 0.1.24

- Raw and Rendered each have an always-visible horizontal scrollbar at the bottom of the pane.
- Raw lines do not wrap. The Raw canvas fits the longest line, with a 600-point minimum width.
- The Rendered canvas keeps its 720-point minimum width. Both visible panes fit inside the editor and scroll independently.
- The split divider resizes the visible panes. Sidebars remain fixed.
- Wide table values keep their words intact. Code blocks and tables have visible horizontal scrollbar tracks and thumbs.
- Full-window checks cover pointer access, native thumb dragging, long-line removal, sidebar changes, and mode switches.

## 0.1.23

- Increased the Raw minimum width to 600 points and the Rendered minimum width to 720 points. Split content requires 1328 points.
- The horizontal scrollbar stays visible during overflow, including with the macOS overlay scrollbar setting.
- Wheel events inside the rendered page reach the editor viewport. Code blocks retain their own scrolling until their edges.
- Expanded checks cover the full workspace, page-level wheel events, sidebar changes, window resizing, and view-mode switches.

## 0.1.22

- Raw panes have a 400-point minimum width. Rendered panes have a 480-point minimum width in split and single-pane modes.
- The editor area scrolls horizontally when the available width is smaller than its content. Sidebars remain fixed.
- Horizontal trackpad gestures and Shift-wheel scrolling work over Raw and Rendered panes.
- Code blocks and tables keep their own horizontal scrolling and hand off at their edges.
- The split divider respects both pane minimums. Wider windows remove excess horizontal overflow.
- Native scrollbar layout supports both overlay and always-visible scrollbars without clipping the bottom of either pane.

## 0.1.21

- Set the native tooltip delay to 300 milliseconds for Parchment.
- Disabled implicit layer animations so button hover highlights appear and disappear immediately.
- Updated the Editing Guide with the shorter delay.

## 0.1.20

- Added a shared hover highlight and native action tooltips for toolbar buttons, tab icons, sidebar rows, comments, review controls, and theme actions.
- Hover overlays preserve button clicks and keyboard focus. Disabled controls remain unhighlighted.
- Hover colors follow the system appearance and increased-contrast setting.
- Moved the tab's file-path tooltip onto its name so icon buttons show their own action tooltips.
- Added a native hover border to floating Comment buttons.
- Updated the Editing Guide with hover feedback.

## 0.1.19

- Added Add File Comment to each tab's right-click menu.
- The action opens the existing file-comment composer for the clicked tab, including background and empty tabs.
- Updated the Editing and Comments guides with the new menu action.

## 0.1.18

- Parchment and local file links open their target document in Rendered mode, including existing Raw and Split tabs.
- Link navigation preserves live edits. Back and Forward restore the prior mode, position, and target.
- Corrected the README and agent skill: terminal chat renderers can omit custom hyperlinks, allowing cmux to detect a plain file path.
- Documented direct MCP opening and the macOS open command as reliable alternatives.

## 0.1.17

- The install script requests a normal quit from running Parchment apps after package verification and before installation.
- Normal quit preserves session recovery and follows existing save behavior.
- Installation stops if an app refuses to quit or remains running after 30 seconds. The script does not force-quit it.
- Dry runs leave running apps untouched. The script still requires no Swift toolchain.
- Updated the README with the automatic quit behavior.

## 0.1.16

- The install script reads the checkout version from scripts/Info.plist and prefers a matching package in dist/.
- If that package is absent, it requests the exact checkout version from GitHub. It does not fall back to an older release.
- A standalone script still selects the latest published release. Explicit --version and --package choices retain precedence.
- Documented the difference between local builds and published releases in the README.

## 0.1.15

- Added native tab dragging with an insertion marker before or after the target tab.
- Tab order persists across restarts without changing the active tab, unsaved edits, comments, or view state.
- Added Close Tab, Close Tabs Before, Close Tabs After, and Close All Tabs to each tab's context menu.
- Bulk close uses the existing save prompts and stops on cancellation or a save failure.
- Updated the bundled Editing Guide with tab controls.

## 0.1.14

- The install script asks whether to install the skill, register parchment:// links, and change Markdown file associations.
- Enter accepts the graphical installer defaults: Yes, Yes, and No.
- Flags answer individual questions. The --yes flag accepts defaults for remaining choices without questions.
- Missing terminal input requires explicit choices or --yes. End of input cancels an unanswered prompt.
- Updated the README with prompts, defaults, and flags.

## 0.1.13

- Added scripts/install.sh to download a release or use a local package, verify its checksum, and install through macOS.
- Script choices match the graphical installer: agent skill and immediate URL registration on, default Markdown app off.
- Added flags for each choice, a specific release version, and a dry run without installation.
- Documented the unsigned installer, missing Apple notarization, and the Open Anyway steps in the README.
- Linked the README to published GitHub Releases.

## 0.1.12

- Moved detailed comment and review instructions from the README into a bundled comments guide.
- Added Help → Comments Guide with file comments, unread replies, and feedback exports.
- Updated export examples to use the installed app.

## 0.1.11

- Moved detailed editing instructions from the README into a bundled editing guide.
- Added Help → Editing Guide, which opens a separate, read-only window.
- The guide works offline and follows the selected theme.

## 0.1.10

- Made the macOS installer the standard installation and upgrade path in the README.
- Documented installer choices and opening the installed app from Applications or Spotlight.
- Kept source-build instructions in a secondary section.

## 0.1.9

- Removed the README Checks section as requested during review.
- Build and verification scripts remain available in the repository.

## 0.1.8

- Added comments for the entire file, including empty files. File comments remain valid after text changes.
- Added a comment icon to each tab and a floating Comment prompt when the pointer rests on its name.
- Added Control-Shift-M and the Add File Comment menu action.
- File comments support replies, pending reviews, resolution, unread tracking, and published agent feedback.
- Companions with file-level comments use format 3. Older apps reject this format. Existing format 2 selection-only companions remain supported.
- Bundled documentation and skills exclude local comment companions and review exports.
- Fixed sidebar resizing when a stored width exceeds the visible space. Added wider dividers and a compact comment filter menu.
- Added this tracker and linked it from the README.

## 0.1.7

- New replies from agents or other reviewers mark threads unread.
- Unread threads appear first with blue highlights and message indicators.
- Added an Unread filter, unread count, and Mark as Read / Mark as Unread actions.
- Interacting with a discussion marks it read. Read state survives reopening on this Mac.
- Unread replies remain visible when a thread is resolved. Reading does not acknowledge agent feedback.

## 0.1.6

- Added Back and Forward toolbar buttons and the Navigate menu.
- Added Command-[ / Command-], Command-Option-Left/Right, mouse back/forward buttons, and horizontal swipe support.
- History covers file links, tab changes, heading jumps, and folder navigation during the current app session.
- Returning to a location restores selections, view modes, and scroll positions while preserving live edits.
- Moved indentation shortcuts to Command-Option-[ / Command-]. Tab and Shift-Tab still change indentation.

## 0.1.5

This release includes the work after the 0.1.4 baseline through `3acd3b6`:

- `054f8f3`: Additional ignore rules for Xcode artifacts and macOS metadata.
- `cb77f52`: README introduction describes collaboration with an agent.
- `899f130`: Direct links such as parchment://Users/me/notes.md?line=42, with support for existing query-style links.
- `576913c`: Optional automatic remote-image loading and individual-image context-menu actions.
- `6d7fe0c`: External-file monitoring, reload prompts, and preservation of local edits with paused autosave.
- `0bb1c8e`: Updated documentation and launch checks.
- `8480ff2`: Generic agent-session delivery with durable retries, receiver registration, status, worker mode, and a CLI fallback.
- `f7b08a5`: Local lexical highlighting for Swift, Kotlin, Java, JavaScript, TypeScript, Python, JSON, Bash, SQL, and YAML.
- `d954f7c`: Local preview links open in Parchment; web links open in the default browser.
- `1727dd2`: README explains ownership, feedback queues, delivery acceptance, fetching, and acknowledgement.

## Earlier releases and evidence

The first source commit records version 0.1.1. The next baseline records 0.1.4, so git cannot establish every intermediate code change.

The archived 0.1.0–0.1.4 installers confirm their version numbers, build numbers, and installer choices. Version 0.1.2 offers skill and URL-registration options. Version 0.1.3 adds the default-Markdown-app option. Version 0.1.4 retains those choices.

The `2c3a044` baseline also contains hidden frontmatter with preserved source offsets, file-location copy menus, installer validation, and Markdown type declarations. Those changes are recorded with 0.1.4 here because the earlier versions have no separate source commits.

## Updating this tracker

Record the version, build number, date, and user-visible changes with each new build. Include source commits when available. Create and verify a fresh app and installer after every commit. Keep older installers and checksums in dist/.
