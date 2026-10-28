# Comments guide

Select text in Raw or Rendered mode to see a small floating **Comment** button. You can also right-click the selection or press `Control-M`. The floating button preserves the selection and leaves keyboard focus in the editor.

To comment on an entire file, right-click its tab and choose **Add File Comment**. You can also click the tab's comment icon, hover over its name for the floating Comment prompt, or press `Control-Shift-M`. File comments work without a selection, including in empty files. They remain attached to the file after text changes and support the same replies, reviews, and resolution actions.

The composer offers **Comment Now** for immediate publication and **Start a Review** for a pending comment. During a review, **Add to Review** adds further pending comments. **Comment Now** remains available for individual comments that need immediate publication.

The Comments sidebar shows the pending count and a **Finish Review** button. The submission sheet lists pending feedback and accepts an optional summary. **Submit Review** publishes all pending comments and replies together. Pending drafts can be edited or deleted. **Discard** removes the pending review without removing published discussion.

Each comment starts one flat reply thread. Threads support resolution, reopening, history, and manual reattachment after text changes. The Open, Unread, Pending, Resolved, and All filters separate discussion states. The All view includes submitted review summaries and discarded-review history.

New replies from agents or other reviewers mark a thread unread. Unread threads appear first with a blue highlight, and new messages carry a **New reply** label. Interacting with a thread marks it read. Use **Mark as Unread** on the card or its context menu to restore unread status. Unread replies remain visible even when their threads are resolved. Read state persists on this Mac and stays separate from agent feedback acknowledgement.

Pending reviews survive autosave and session restoration. Agent exports exclude pending comments, pending replies, and unsubmitted reviews, including exports with `--include-resolved`.

The app stores comments in `<filename>.comments.json` beside the Markdown file. Markdown content stays free of annotation markup.

The File menu exports open comments with the current document text, source hash, and anchor status. The command-line entry point also exports comments:

```sh
/Applications/Parchment.app/Contents/MacOS/Parchment --export-comments /path/to/notes.md > review.json
/Applications/Parchment.app/Contents/MacOS/Parchment --export-comments /path/to/notes.md --include-resolved > history.json
```

The CLI reads saved files. It does not send data to an agent or start an agent. See [the companion file contract](../comments.md).

