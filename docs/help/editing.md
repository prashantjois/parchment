# Editing guide

Each file opens in a tab. An already open file activates its existing tab. Each file remembers its view mode, sidebar widths, split divider, cursor, and scroll position.

Hover over an enabled button to see its highlight immediately. Pause for about 0.3 seconds to see a tooltip with its action and available shortcut. This feedback covers toolbar buttons, tab icons, sidebar actions, comments, reviews, and theme controls. Disabled buttons remain unhighlighted.

Drag a tab to reorder it. The insertion marker shows the drop position before or after another tab. Tab order survives a restart. Reordering preserves the active tab and unsaved edits.

Right-click a tab for **Add File Comment**, **Close Tab**, **Close Tabs Before**, **Close Tabs After**, or **Close All Tabs**. Add File Comment opens the composer for the clicked tab, even when another tab is active. Before and After refer to the clicked tab in the current tab order. These actions preserve the existing save prompts. If you cancel a prompt or a save fails, bulk closing stops. Tabs already closed remain closed.

Raw mode provides native text editing, selection, cut/copy/paste, undo/redo, find and replace, spelling, formatting shortcuts, and automatic list continuation. Tab and Shift-Tab indent and outdent selected lines. `⌘⌥]` and `⌘⌥[` also change indentation. Rendered mode is a read-only preview. Split mode shows both views with proportional scroll synchronization. The preview updates about 180 milliseconds after a typing pause. Rendered content fills the pane width with 16-pixel side margins by default.

Raw and Rendered each have a horizontal scrollbar at the bottom of the pane. Both bars stay visible even when the content fits. Raw content has a minimum width of 600 points. Long Raw lines stay on one line and scroll sideways. Rendered content has a minimum width of 720 points.

If the window or sidebars leave less space, scroll each pane independently. Drag the split divider to resize the visible panes. Sidebars remain in place. Use the horizontal scrollbar, scroll sideways on a trackpad, or use Shift with the mouse wheel. Code blocks and wide tables have their own horizontal scrollbars. Their wheel events move the Rendered pane after they reach an edge.

The file browser starts in the current file's folder. An unsaved document starts in the user's home folder. The browser supports expandable folders and parent navigation.

In Rendered and Split modes, clicking a local file link opens or selects its tab in Rendered mode. External parchment:// document links also select Rendered mode. Links preserve live edits even when the target tab was open in Raw or Split mode. Heading fragments navigate to the heading in the target file. Folder links open the file browser. Web links open in the system's default browser.

The Back and Forward toolbar buttons navigate through files, tabs, heading jumps, and folder changes. They restore the previous selection, view mode, and scroll positions without replacing unsaved text. Use `⌘[` / `⌘]`, `⌘⌥←` / `⌘⌥→`, mouse back/forward buttons, or horizontal swipe gestures. History lasts for the current app session.

The right sidebar shows either the table of contents or comments. Its two toolbar buttons select the panel. Clicking the active panel's button closes the sidebar. Drag its left divider to adjust the width. The file browser remains independent.

| Toolbar action | Shortcut |
| --- | --- |
| Back | `⌘[` or `⌘⌥←` |
| Forward | `⌘]` or `⌘⌥→` |
| File Browser | `Control-N` |
| Split View | `Control-S` |
| Rendered Only | `Control-R` |
| Raw Only | `Control-E` |
| Table of Contents | `Control-T` |
| Themes | `⌘5` |
| Comments | `⌘6` |
| Add Comment | `Control-M` |
| Add File Comment | `Control-Shift-M` |

`Control-R` and `Control-E` select their views directly, including from Split mode. The toolbar Raw / Rendered button opens Rendered from Split and otherwise switches between Raw and Rendered. Turning Split off restores the previous single-pane mode. Standard commands include `⌘N`, `⌘O`, `⌘S`, `⌘⇧S`, and `⌘W`. `⌘⇧[` and `⌘⇧]` switch tabs.

Existing files autosave after an edit pause. Unsaved drafts and open tabs use local recovery data in `~/Library/Application Support/Parchment/`. Closing a nonempty unsaved tab prompts for Save, Cancel, or Discard. Quitting preserves unsaved drafts for the next launch.

