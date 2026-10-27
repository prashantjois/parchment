import SwiftUI
import AppKit
import Carbon
import ParchmentCore

@main struct ParchmentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var workspace: Workspace
    init() {
        if let index = CommandLine.arguments.firstIndex(of: "--integration-test-server"), CommandLine.arguments.count > index + 1 {
            IntegrationController.runTestServer(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        if CommandLine.arguments.contains("--check-themes") { ThemeChecks.run() }
        if CommandLine.arguments.contains("--check-storage") { StorageChecks.run() }
        if CommandLine.arguments.contains("--check-editor") { EditorChecks.run() }
        if let index = CommandLine.arguments.firstIndex(of: "--export-comments") {
            guard CommandLine.arguments.count > index + 1 else { fputs("Usage: Parchment --export-comments FILE [--include-resolved]\n", stderr); exit(2) }
            do {
                let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                let text = try String(contentsOf: url, encoding: .utf8)
                let data = try CommentFile.read(for: url).export(text: text, path: url.path, includeResolved: CommandLine.arguments.contains("--include-resolved"))
                FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8)); exit(0)
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        }
        let server = AppInstance.claimOrForward()
        let state = Workspace(); _workspace = StateObject(wrappedValue: state); AppDelegate.workspace = state
        guard state.startIntegration(server: server) else {
            let alert = NSAlert(); alert.messageText = "Parchment could not start."
            alert.informativeText = state.error ?? "The local API is unavailable."
            alert.runModal(); server.stop(); exit(1)
        }
    }
    var body: some Scene {
        Window("Parchment", id: "main") {
            WorkspaceView(workspace: workspace).frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1240, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { workspace.newDocument() }.keyboardShortcut("n")
                Button("Open…") { workspace.openPanel() }.keyboardShortcut("o")
                Menu("Open Recent") {
                    ForEach(NSDocumentController.shared.recentDocumentURLs.filter { FileManager.default.fileExists(atPath: $0.path) }, id: \.self) { url in Button(url.lastPathComponent) { workspace.open(url) } }
                }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { if let doc = workspace.active { workspace.save(doc) } }.keyboardShortcut("s").disabled(workspace.active == nil)
                Button("Save As…") { if let doc = workspace.active { workspace.save(doc, saveAs: true) } }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(workspace.active == nil)
                Button("Close Tab") { if let doc = workspace.active { workspace.close(doc) } }.keyboardShortcut("w").disabled(workspace.active == nil)
                Divider()
                Button("Export Open Comments for Agent…") { workspace.exportComments() }.keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("Toggle File Browser") { workspace.toggleFiles() }.keyboardShortcut("n", modifiers: .control)
                Button("Toggle Split View") { workspace.toggleSplit() }.keyboardShortcut("s", modifiers: .control)
                Button("Rendered Only") { workspace.showSinglePane(.rendered) }.keyboardShortcut("r", modifiers: .control)
                Button("Raw Only") { workspace.showSinglePane(.raw) }.keyboardShortcut("e", modifiers: .control)
                Button("Toggle Table of Contents") { workspace.toggleRight(.contents) }.keyboardShortcut("t", modifiers: .control)
                Button("Themes…") { workspace.showThemes = true }.keyboardShortcut("5")
                Button("Toggle Comments") { workspace.toggleRight(.comments) }.keyboardShortcut("6")
                Divider()
                Button("Next Tab") { workspace.nextTab(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") { workspace.nextTab(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) {
                Button("Find…") { showFind(.showFindInterface) }.keyboardShortcut("f")
                Button("Find and Replace…") { showFind(.showReplaceInterface) }.keyboardShortcut("f", modifiers: [.command, .option])
            }
            CommandMenu("Format") {
                Button("Bold") { NSApp.sendAction(#selector(MarkdownTextView.wrapBold), to: nil, from: nil) }.keyboardShortcut("b")
                Button("Italic") { NSApp.sendAction(#selector(MarkdownTextView.wrapItalic), to: nil, from: nil) }.keyboardShortcut("i")
                Button("Inline Code") { NSApp.sendAction(#selector(MarkdownTextView.wrapCode), to: nil, from: nil) }.keyboardShortcut("`", modifiers: [.command, .shift])
                Button("Indent") { NSApp.sendAction(#selector(MarkdownTextView.indentSelection), to: nil, from: nil) }.keyboardShortcut("]")
                Button("Outdent") { NSApp.sendAction(#selector(MarkdownTextView.outdentSelection), to: nil, from: nil) }.keyboardShortcut("[")
                Divider()
                Button("Add Comment") { workspace.beginComment() }.keyboardShortcut("m", modifiers: .control)
            }
        }
        Settings { ThemeSettings(library: workspace.themes) }
    }
    private func showFind(_ action: NSTextFinder.Action) {
        let sender = NSMenuItem(); sender.tag = action.rawValue
        NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: sender)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var workspace: Workspace?
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleOpenURL(_:withReplyEvent:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }
    @objc func handleOpenURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let value = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: value) else { return }
        application(NSApplication.shared, open: [url])
    }
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { Self.workspace?.integration?.stop() }
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { Self.workspace?.openIncomingURL($0) }
        application.activate(ignoringOtherApps: true)
        application.windows.first(where: { $0.isVisible && $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace = Self.workspace else { return .terminateNow }
        for document in workspace.documents where document.isDirty && document.url != nil {
            do { try document.save() }
            catch { let alert = NSAlert(error: error); alert.runModal(); return .terminateCancel }
        }
        guard workspace.persist() else {
            let alert = NSAlert(); alert.messageText = "Recovery data could not be saved."
            alert.informativeText = workspace.error ?? "Save your documents before quitting."
            alert.runModal(); return .terminateCancel
        }
        workspace.integration?.stop()
        return .terminateNow
    }
}

struct WorkspaceView: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        VStack(spacing: 0) {
            if !workspace.documents.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(workspace.documents) { document in
                            DocumentTab(document: document, selected: workspace.activeID == document.id,
                                        activate: { workspace.activeID = document.id; workspace.scheduleRecovery() }, close: { workspace.close(document) })
                        }
                        Spacer(minLength: 0)
                    }
                }.frame(height: 38).background(.bar)
                Divider()
            }
            if let document = workspace.active {
                DocumentWorkspace(document: document, workspace: workspace).id(document.id)
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "doc.richtext").font(.system(size: 52, weight: .light)).foregroundStyle(.secondary)
                    Text("A place for your words").font(.title)
                    Text("Open a Markdown file or start a new document.").foregroundStyle(.secondary)
                    HStack { Button("New Document") { workspace.newDocument() }; Button("Open…") { workspace.openPanel() } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(WindowShortcutBridge(workspace: workspace).frame(width: 0, height: 0))
        .sheet(isPresented: $workspace.showThemes) { ThemeSettings(library: workspace.themes) }
        .sheet(isPresented: $workspace.composeComment) { if let doc = workspace.active { CommentComposer(document: doc) } }
        .alert("Parchment", isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
            Button("OK", role: .cancel) { workspace.error = nil }
        } message: { Text(workspace.error ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in workspace.persist() }
    }
}

struct DocumentTab: View {
    @ObservedObject var document: EditorDocument
    var selected: Bool
    var activate: () -> Void
    var close: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text").font(.caption).foregroundStyle(.secondary)
            Text(document.title).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
            if document.isDirty { Circle().fill(.secondary).frame(width: 5, height: 5) }
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).padding(4) }.buttonStyle(.plain).help("Close Tab (⌘W)")
        }.padding(.horizontal, 14).frame(height: 38).frame(minWidth: 130, maxWidth: 240)
            .background(selected ? Color(nsColor: .controlBackgroundColor) : .clear)
            .overlay(alignment: .bottom) { if selected { Rectangle().fill(Color.accentColor).frame(height: 2) } }
            .contentShape(Rectangle()).onTapGesture(perform: activate).help(document.url?.path ?? "Unsaved document")
    }
}

struct DocumentWorkspace: View {
    @ObservedObject var document: EditorDocument
    @ObservedObject var workspace: Workspace
    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    if document.layout.showFiles {
                        FileBrowser(document: document, open: workspace.open)
                            .frame(width: min(document.layout.filesWidth, geometry.size.width * 0.3)).transition(.move(edge: .leading).combined(with: .opacity))
                        ResizeHandle(value: $document.layout.filesWidth, limits: 170...360)
                    }
                    editor.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if document.layout.showRight {
                        ResizeHandle(value: $document.layout.rightWidth, limits: 240...440, direction: -1)
                        Group {
                            if document.layout.rightPanel == .contents { ContentsSidebar(document: document) }
                            else { CommentsSidebar(document: document, beginComment: workspace.beginComment, export: workspace.exportComments) }
                        }.frame(width: min(document.layout.rightWidth, geometry.size.width * 0.35)).transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            Divider()
            HStack(spacing: 14) {
                Text(document.url?.path ?? "Untitled · Save to create a Markdown file").lineLimit(1).truncationMode(.middle)
                Spacer()
                if !document.saveMessage.isEmpty { Text(document.saveMessage).foregroundStyle(document.isDirty ? Color.orange : Color.secondary).lineLimit(1).help(document.saveMessage) }
                Text("\(document.text.split(whereSeparator: { $0.isWhitespace }).count) words")
                Text(document.layout.mode.rawValue.capitalized)
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 14).frame(height: 28).background(.bar)
        }
        .animation(.easeInOut(duration: 0.18), value: document.layout.showFiles)
        .animation(.easeInOut(duration: 0.18), value: document.layout.showRight)
        .onChange(of: document.layout) { _, _ in workspace.scheduleRecovery() }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                toolbarButton("File Browser", icon: "sidebar.left", shortcut: "⌃N", active: document.layout.showFiles, action: workspace.toggleFiles)
            }
            ToolbarItemGroup(placement: .principal) {
                toolbarButton("Split View", icon: "rectangle.split.2x1", shortcut: "⌃S", active: document.layout.mode == .split, action: workspace.toggleSplit)
                toolbarButton(document.layout.mode == .rendered ? "Show Raw Markdown" : "Show Rendered Markdown", icon: document.layout.mode == .rendered ? "chevron.left.forwardslash.chevron.right" : "doc.richtext", shortcut: document.layout.mode == .rendered ? "⌃E" : "⌃R", active: document.layout.mode == .rendered, action: workspace.toggleRendered)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                toolbarButton("Themes", icon: "paintpalette", shortcut: "⌘5", active: false) { workspace.showThemes = true }
                toolbarButton("Add Comment", icon: "text.badge.plus", shortcut: "⌃M", active: false, action: workspace.beginComment).disabled(document.selection.length == 0)
                toolbarButton("Comments", icon: "text.bubble", shortcut: "⌘6", active: document.layout.showRight && document.layout.rightPanel == .comments) { workspace.toggleRight(.comments) }
                toolbarButton("Table of Contents", icon: "sidebar.right", shortcut: "⌃T", active: document.layout.showRight && document.layout.rightPanel == .contents) { workspace.toggleRight(.contents) }
            }
        }
    }
    @ViewBuilder var editor: some View {
        if document.layout.mode == .split {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    SourcePane(document: document, beginComment: workspace.beginComment).frame(width: max(120, (geometry.size.width - 5) * document.layout.splitFraction))
                    ResizeHandle(value: $document.layout.splitFraction, limits: 0.2...0.8, scale: max(1, geometry.size.width - 5))
                    RenderedPane(document: document, themes: workspace.themes, beginComment: workspace.beginComment)
                }
            }
        } else if document.layout.mode == .raw { SourcePane(document: document, beginComment: workspace.beginComment) }
        else { RenderedPane(document: document, themes: workspace.themes, beginComment: workspace.beginComment) }
    }
    func toolbarButton(_ title: String, icon: String, shortcut: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).foregroundStyle(active ? Color.accentColor : Color.primary) }.help("\(title) (\(shortcut))")
    }
}

struct ResizeHandle: View {
    @Binding var value: Double
    var limits: ClosedRange<Double>
    var direction: Double = 1
    var scale: Double = 1
    @ViewState<Double?> private var initial: Double?
    var body: some View {
        Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.5)).frame(width: 5).contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                if initial == nil { initial = value }
                value = min(limits.upperBound, max(limits.lowerBound, initial! + drag.translation.width * direction / scale))
            }.onEnded { _ in initial = nil })
    }
}
