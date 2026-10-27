import AppKit
import SwiftUI
import ParchmentCore

struct BrowserEntry: Identifiable {
    var url: URL
    var directory: Bool
    var id: String { url.path }
    static func children(of url: URL) -> [BrowserEntry] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return BrowserEntry(url: url, directory: values?.isDirectory == true && values?.isSymbolicLink != true)
        }.sorted {
            if $0.directory != $1.directory { return $0.directory }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }
}

struct FileBrowser: View {
    @ObservedObject var document: EditorDocument
    var open: (URL) -> Void
    @ViewState<[BrowserEntry]> private var entries: [BrowserEntry] = []
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(document.browserRoot.lastPathComponent.isEmpty ? "/" : document.browserRoot.lastPathComponent).font(.headline).lineLimit(1).help(document.browserRoot.path)
                Spacer()
                Button { document.browserRoot = document.browserRoot.deletingLastPathComponent() } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless).help("Parent Folder (⌘↑ while browser has focus)")
            }.padding(12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(entries) { entry in BrowserRow(entry: entry, document: document, open: open) }
                    if entries.isEmpty { Text("This folder is empty.").foregroundStyle(.secondary).padding(12) }
                }.padding(6)
            }
            HStack { Text(document.browserRoot.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head); Spacer() }.padding(10)
        }.background(.bar)
        .onAppear { refresh() }
        .onChange(of: document.browserRoot) { _, _ in refresh() }
        .onKeyPress(.upArrow, phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            document.browserRoot = document.browserRoot.deletingLastPathComponent(); return .handled
        }
    }
    func refresh() { entries = BrowserEntry.children(of: document.browserRoot) }
}

struct BrowserRow: View {
    var entry: BrowserEntry
    @ObservedObject var document: EditorDocument
    var open: (URL) -> Void
    @ViewState<[BrowserEntry]> private var children: [BrowserEntry] = []
    private var expanded: Bool { document.browserExpanded.contains(entry.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                if entry.directory {
                    if expanded { document.browserExpanded.remove(entry.id) }
                    else { children = BrowserEntry.children(of: entry.url); document.browserExpanded.insert(entry.id) }
                } else { open(entry.url) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: entry.directory ? (expanded ? "chevron.down" : "chevron.right") : "").font(.system(size: 9)).frame(width: 10)
                    Image(systemName: entry.directory ? "folder.fill" : "doc.text").foregroundStyle(entry.directory ? Color.accentColor : Color.secondary)
                    Text(entry.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }.padding(.vertical, 6).padding(.horizontal, 5).contentShape(Rectangle())
                    .background(document.url == entry.url ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
            }.buttonStyle(.plain)
            if entry.directory && expanded {
                ForEach(children) { child in BrowserRow(entry: child, document: document, open: open).padding(.leading, 14) }
            }
        }.onAppear { if expanded { children = BrowserEntry.children(of: entry.url) } }
    }
}

struct ContentsSidebar: View {
    @ObservedObject var document: EditorDocument
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Contents", systemImage: "list.bullet.indent").font(.headline).padding(14)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if document.rendered.headings.isEmpty { Text("Headings will appear here.").foregroundStyle(.secondary).padding(14) }
                    ForEach(document.rendered.headings) { heading in
                        Button { document.reveal(NSRange(location: heading.location, length: 0)) } label: {
                            Text(heading.title).font(heading.level == 1 ? .headline : .body).lineLimit(2)
                                .padding(.vertical, 7).padding(.leading, CGFloat(heading.level - 1) * 12 + 12)
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(.vertical, 6)
            }
        }.background(.bar)
    }
}

struct CommentsSidebar: View {
    @ObservedObject var document: EditorDocument
    var beginComment: () -> Void
    var export: () -> Void
    @ViewState<String> private var filter = "Open"
    @ViewState<Bool> private var finishReview = false
    @ViewState<Bool> private var discardReview = false
    @ViewState<Bool> private var disconnectAgent = false
    var visibleThreads: [CommentThread] {
        document.comments.threads.filter {
            switch filter {
            case "Pending": return $0.isPending || $0.messages.contains(where: \.isPending)
            case "Resolved": return !$0.isPending && $0.isResolved
            case "Open": return !$0.isPending && !$0.isResolved
            default: return true
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Comments", systemImage: "text.bubble").font(.headline)
                Spacer()
                Button(action: beginComment) { Image(systemName: "plus") }.buttonStyle(.borderless).disabled(document.selection.length == 0).help("Add Comment (⌃M)")
            }.padding(14)
            if document.integrationAttachment["status"].string == "attached" {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Agent attached", systemImage: "link").font(.caption.bold())
                    Text(document.integrationAttachment["conversation_label"].string ?? "Agent conversation").font(.callout).lineLimit(2)
                    Text("\(document.integrationAttachment["client"].string ?? "Agent") · \(document.integrationAttachment["queued_feedback"].int ?? 0) feedback items awaiting acknowledgement")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Disconnect Agent…") { disconnectAgent = true }.buttonStyle(.borderless).font(.caption)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 10).padding(.bottom, 10)
            }
            if let error = document.integrationError {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 14).padding(.bottom, 10)
            }
            if document.comments.activeReview != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Review in progress", systemImage: "square.and.pencil").font(.headline)
                    Text("\(document.comments.pendingCount) pending comments and replies").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Finish Review…") { finishReview = true }.buttonStyle(.borderedProminent)
                        Spacer()
                        Button("Discard") { discardReview = true }.buttonStyle(.borderless)
                    }
                }.padding(12).background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 10).padding(.bottom, 10)
            } else {
                Button("Start a Review") { document.startReview(); filter = "Pending" }.buttonStyle(.borderless).padding(.horizontal, 14).padding(.bottom, 12)
            }
            Picker("Show", selection: $filter) { Text("Open").tag("Open"); Text("Pending").tag("Pending"); Text("Resolved").tag("Resolved"); Text("All").tag("All") }.pickerStyle(.segmented).padding(.horizontal, 10).padding(.bottom, 10)
            Divider()
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if visibleThreads.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(filter == "Open" ? "No open comments" : "No comments in this view").font(.headline)
                                Text("Select text in either view, then press ⌃M to start a thread.").foregroundStyle(.secondary)
                            }.padding(16)
                        }
                        ForEach(visibleThreads) { thread in ThreadCard(thread: thread, document: document).id(thread.id) }
                        if filter == "All" {
                            ForEach((document.comments.reviews ?? []).filter { !$0.isPending }.reversed()) { review in
                                VStack(alignment: .leading, spacing: 5) {
                                    Label(review.submittedAt == nil ? "Review discarded" : "Review submitted", systemImage: review.submittedAt == nil ? "xmark.circle" : "checkmark.circle").font(.caption.bold())
                                    Text("\(review.author) · \((review.submittedAt ?? review.discardedAt ?? review.startedAt).formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                                    if let summary = review.summary, !summary.isEmpty { Text(summary).font(.callout).textSelection(.enabled) }
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }.padding(10)
                }.onChange(of: document.selectedThread) { _, id in
                    if let thread = document.comments.threads.first(where: { $0.id == id }) {
                        if thread.isPending || thread.messages.contains(where: \.isPending) { filter = "Pending" }
                        else if thread.isResolved { filter = "Resolved" }
                        else if filter != "All" { filter = "Open" }
                    }
                    withAnimation { reader.scrollTo(id, anchor: .top) }
                }
            }
            Divider()
            Button("Export Open Comments for Agent…", action: export).buttonStyle(.borderless).padding(12).disabled(document.comments.threads.allSatisfy { $0.isResolved || $0.isPending } && !(document.comments.reviews ?? []).contains { $0.submittedAt != nil })
        }.background(.bar)
            .sheet(isPresented: $finishReview) { ReviewSubmission(document: document) }
            .confirmationDialog("Discard this review and its pending comments?", isPresented: $discardReview) {
                Button("Discard Pending Review", role: .destructive) { document.discardReview() }
            }
            .confirmationDialog("Disconnect this agent conversation?", isPresented: $disconnectAgent) {
                Button("Disconnect Agent", role: .destructive) { document.disconnectAgent?() }
            } message: {
                Text("The old attachment will no longer accept edits. Another conversation can attach. Comments and queued feedback remain saved.")
            }
            .onChange(of: document.comments.activeReview?.id) { _, id in if id == nil && filter == "Pending" { filter = "Open" } }
    }
}

struct ThreadCard: View {
    var thread: CommentThread
    @ObservedObject var document: EditorDocument
    @ViewState<String> private var reply = ""
    @ViewState<Bool> private var history = false
    @ViewState<UUID?> private var editingMessage: UUID?
    @ViewState<String> private var editedBody = ""
    var match: AnchorMatch { thread.anchor.locate(in: document.text) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if thread.isPending { Label("Pending review", systemImage: "clock").font(.caption.bold()).foregroundStyle(.orange) }
            Button { document.selectThread(thread) } label: {
                HStack(alignment: .top) {
                    Rectangle().fill(.yellow).frame(width: 3)
                    Text(thread.anchor.quote).font(.caption).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                    if thread.isResolved { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                }.fixedSize(horizontal: false, vertical: true)
            }.buttonStyle(.plain)
            if match.range == nil {
                Text(match.state == .ambiguous ? "This text occurs more than once. Select the correct text to reattach." : "The original text changed. Select text to reattach this thread.")
                    .font(.caption).foregroundStyle(.orange)
                Button("Attach to Current Selection") {
                    let range = TextSpan(location: document.selection.location, length: document.selection.length)
                    guard range.isValid(in: document.text) else { return }
                    document.append(CommentEvent(kind: .reanchor, author: NSFullUserName(), anchor: CommentAnchor(text: document.text, range: range)), to: thread.id)
                }.disabled(document.selection.length == 0)
            }
            ForEach(thread.messages) { message in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(message.author).font(.caption.bold())
                        Spacer()
                        Text(message.timestamp, style: .date).font(.caption2).foregroundStyle(.secondary)
                    }
                    if editingMessage == message.id {
                        TextField("Comment", text: $editedBody, axis: .vertical).lineLimit(2...8).textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Save Draft") { document.editPendingMessage(message.id, in: thread.id, body: editedBody); editingMessage = nil }.disabled(editedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("Cancel") { editingMessage = nil }
                        }
                    } else {
                        Text(message.body ?? "").font(.callout).textSelection(.enabled)
                        if message.isPending {
                            HStack {
                                Text("Pending").foregroundStyle(.orange)
                                Spacer()
                                Button("Edit") { editedBody = message.body ?? ""; editingMessage = message.id }
                                Button("Delete", role: .destructive) { document.removePendingMessage(message.id, in: thread.id) }
                            }.font(.caption).buttonStyle(.borderless)
                        }
                    }
                }
            }
            if !thread.isResolved {
                TextField("Reply to this thread…", text: $reply, axis: .vertical).lineLimit(2...6).textFieldStyle(.roundedBorder)
                HStack {
                    Button(document.comments.activeReview != nil ? "Add to Review" : "Reply") {
                        document.addReply(reply, to: thread.id, pending: document.comments.activeReview != nil); reply = ""
                    }.disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    if !thread.isPending {
                        Button("Resolve") { document.append(CommentEvent(kind: .resolve, author: NSFullUserName()), to: thread.id) }
                    }
                }
                if document.comments.activeReview != nil && !thread.isPending {
                    Button("Reply Now") { document.addReply(reply, to: thread.id, pending: false); reply = "" }.buttonStyle(.borderless).disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Button("Reopen Thread") { document.append(CommentEvent(kind: .reopen, author: NSFullUserName()), to: thread.id) }
            }
            DisclosureGroup("History", isExpanded: $history) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(thread.events) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(event.author) · \(event.kind.rawValue.capitalized)").font(.caption)
                            Text(event.timestamp.formatted(date: .abbreviated, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                            if let published = event.publishedAt { Text("Review submitted \(published.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }.padding(.top, 6)
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(thread.id == document.selectedThread ? Color.accentColor : Color.secondary.opacity(0.15), lineWidth: 1))
    }
}

struct CommentComposer: View {
    @ObservedObject var document: EditorDocument
    @Environment(\.dismiss) private var dismiss
    @ViewState<String> private var bodyText = ""
    @ViewState<String?> private var error: String?
    @FocusState private var focused: Bool
    var quote: String {
        if let anchor = document.commentDraftAnchor { return anchor.quote }
        let range = TextSpan(location: document.selection.location, length: document.selection.length)
        return range.isValid(in: document.text) ? (document.text as NSString).substring(with: range.nsRange) : ""
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Comment").font(.title2.bold())
            Text(quote).font(.callout).lineLimit(6).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            TextEditor(text: $bodyText).font(.body).frame(height: 130).focused($focused).border(.quaternary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Text(document.url == nil ? "Save this document to create its companion file." : "Saved beside \(document.title)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if document.comments.activeReview != nil {
                    Button("Comment Now") { submit(pending: false) }.disabled(cannotSubmit)
                    Button("Add to Review") { submit(pending: true) }.keyboardShortcut(.defaultAction).disabled(cannotSubmit)
                } else {
                    Button("Start a Review") { submit(pending: true) }.disabled(cannotSubmit)
                    Button("Comment Now") { submit(pending: false) }.keyboardShortcut(.defaultAction).disabled(cannotSubmit)
                }
            }
            Text(document.comments.activeReview == nil ? "Comment now publishes immediately. Start a review keeps your comments pending until submission." : "Review comments stay pending until you submit the review. Comment now publishes this comment immediately.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 560).onAppear { focused = true }
            .onDisappear { document.commentDraftAnchor = nil }
    }
    var cannotSubmit: Bool { bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || quote.isEmpty }
    func submit(pending: Bool) {
        if let anchor = document.commentDraftAnchor {
            guard let range = anchor.locate(in: document.text).range else {
                error = "The selected passage changed. Cancel and select the passage again."; return
            }
            document.selection = range.nsRange
        }
        document.addComment(body: bodyText, pending: pending); dismiss()
    }
}

struct ReviewSubmission: View {
    @ObservedObject var document: EditorDocument
    @Environment(\.dismiss) private var dismiss
    @ViewState<String> private var summary = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Submit Review").font(.title2.bold())
            Text("Publish \(document.comments.pendingCount) pending comments and replies together.").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(document.comments.threads.filter { $0.messages.contains(where: \.isPending) }) { thread in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(thread.anchor.quote).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            ForEach(thread.messages.filter(\.isPending)) { message in Text(message.body ?? "").font(.callout) }
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }.frame(maxHeight: 240)
            Text("Review summary (optional)").font(.headline)
            TextEditor(text: $summary).font(.body).frame(height: 90).border(.quaternary)
            HStack {
                Spacer()
                Button("Keep Reviewing") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Submit Review") { document.submitReview(summary: summary); dismiss() }.keyboardShortcut(.defaultAction).disabled(document.comments.pendingCount == 0 && summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 540)
    }
}
