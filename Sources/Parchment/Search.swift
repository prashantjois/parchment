import AppKit
import SwiftUI
import ParchmentCore

struct SearchMenuCommands: Commands {
    @ObservedObject var workspace: Workspace
    @ObservedObject var search: SearchController
    var findAndReplace: () -> Void
    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find in Document…") { search.open(.document) }.keyboardShortcut("f").disabled(workspace.active == nil)
            Button("Find in All Open Documents…") { search.open(.allDocuments) }.keyboardShortcut("m", modifiers: [.command, .shift]).disabled(workspace.documents.isEmpty)
            Button("Find Next") { search.move(1) }.keyboardShortcut("g").disabled(search.results.isEmpty)
            Button("Find Previous") { search.move(-1) }.keyboardShortcut("g", modifiers: [.command, .shift]).disabled(search.results.isEmpty)
            if let document = workspace.active {
                FindAndReplaceMenuItem(document: document, action: findAndReplace)
            } else {
                Button("Find and Replace…", action: findAndReplace).keyboardShortcut("f", modifiers: [.command, .option]).disabled(true)
            }
        }
    }
}

private struct FindAndReplaceMenuItem: View {
    @ObservedObject var document: EditorDocument
    var action: () -> Void
    var body: some View {
        Button("Find and Replace…", action: action)
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(document.layout.mode == .rendered)
    }
}

enum SearchScope: String, CaseIterable { case document = "This Document", allDocuments = "All Open Documents" }

struct DocumentSearchResult: Identifiable, Sendable {
    var documentID: UUID
    var title: String
    var path: String?
    var occurrence: SearchOccurrence
    var id: String { "\(documentID):\(occurrence.range.location):\(occurrence.range.length)" }
}

@MainActor final class SearchController: ObservableObject {
    weak var workspace: Workspace?
    @Published var visible = false
    @Published var focusGeneration = 0
    @Published var query = "" { didSet { refresh() } }
    @Published var caseSensitive: Bool { didSet { defaults.set(caseSensitive, forKey: "search.matchCase"); refresh() } }
    @Published var useRegex: Bool { didSet { defaults.set(useRegex, forKey: "search.useRegex"); refresh() } }
    @Published var ignoreDiacritics: Bool { didSet { defaults.set(ignoreDiacritics, forKey: "search.ignoreDiacritics"); refresh() } }
    @Published var scope: SearchScope = .document { didSet { refresh() } }
    @Published private(set) var results: [DocumentSearchResult] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isSearching = false
    private struct Input: Equatable, Sendable { var id: UUID; var title: String; var path: String?; var text: String }
    private var lastInputs: [Input] = []
    private var lastQuery = ""
    private var lastCaseSensitive = false
    private var lastUseRegex = false
    private var lastIgnoreDiacritics = false
    private var lastScope: SearchScope?
    private var searchTask: Task<Void, Never>?
    private var generation = 0
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        caseSensitive = defaults.bool(forKey: "search.matchCase")
        useRegex = defaults.bool(forKey: "search.useRegex")
        ignoreDiacritics = defaults.bool(forKey: "search.ignoreDiacritics")
    }

    deinit { searchTask?.cancel() }

    func open(_ scope: SearchScope) {
        guard let workspace, !workspace.documents.isEmpty, scope == .allDocuments || workspace.active != nil else { return }
        visible = true; self.scope = scope; refresh(); focusGeneration += 1
    }
    func close() {
        searchTask?.cancel(); generation += 1; isSearching = false; errorMessage = nil
        visible = false; results = []; selectedID = nil; lastScope = nil
        updateHighlights()
        if let scroll = workspace?.active?.sourceScrollView, scroll.isFindBarVisible {
            let sender = NSMenuItem(); sender.tag = NSTextFinder.Action.hideFindInterface.rawValue
            workspace?.active?.sourceTextView?.performFindPanelAction(sender)
            scroll.isFindBarVisible = false
        }
        if let text = workspace?.active?.sourceTextView, let window = text.window { window.makeFirstResponder(text) }
    }
    func refresh() {
        guard visible, let workspace else { return }
        let documents = scope == .document ? workspace.active.map { [$0] } ?? [] : workspace.documents
        let inputs = documents.map { Input(id: $0.id, title: $0.title, path: $0.url?.path, text: $0.text) }
        let optionsChanged = caseSensitive != lastCaseSensitive || useRegex != lastUseRegex || ignoreDiacritics != lastIgnoreDiacritics
        guard inputs != lastInputs || query != lastQuery || optionsChanged || scope != lastScope else { return }
        let revealMatch = query != lastQuery || optionsChanged || scope != lastScope || inputs.map(\.id) != lastInputs.map(\.id)
        lastInputs = inputs; lastQuery = query; lastCaseSensitive = caseSensitive; lastScope = scope
        lastUseRegex = useRegex; lastIgnoreDiacritics = ignoreDiacritics
        searchTask?.cancel(); generation += 1; errorMessage = nil
        if useRegex && !query.isEmpty {
            isSearching = true; results = []; updateHighlights()
            let currentGeneration = generation, query = query, caseSensitive = caseSensitive, ignoreDiacritics = ignoreDiacritics
            let work = Task.detached(priority: .userInitiated) {
                let pattern = try SearchPattern(query, caseSensitive: caseSensitive, ignoreDiacritics: ignoreDiacritics)
                return try inputs.flatMap { input in
                    try Task.checkCancellation()
                    return try pattern.find(in: input.text).map {
                        DocumentSearchResult(documentID: input.id, title: input.title, path: input.path, occurrence: $0)
                    }
                }
            }
            searchTask = Task { [weak self] in
                do {
                    let found = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
                    guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
                    self.isSearching = false; self.install(found, revealMatch: revealMatch)
                } catch {
                    guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
                    self.isSearching = false; self.errorMessage = error.localizedDescription
                    self.install([], revealMatch: false)
                }
            }
            return
        }
        isSearching = false
        let found = inputs.flatMap { input in
            DocumentSearch.find(query, in: input.text, caseSensitive: caseSensitive, ignoreDiacritics: ignoreDiacritics).map {
                DocumentSearchResult(documentID: input.id, title: input.title, path: input.path, occurrence: $0)
            }
        }
        install(found, revealMatch: revealMatch)
    }
    private func install(_ found: [DocumentSearchResult], revealMatch: Bool) {
        results = found
        if !results.contains(where: { $0.id == selectedID }) { selectedID = nil }
        updateHighlights()
        if scope == .document && revealMatch, let first = results.first { select(results.first { $0.id == selectedID } ?? first) }
    }
    func move(_ direction: Int) {
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == selectedID }
        let index = current.map { ($0 + direction + results.count) % results.count } ?? (direction < 0 ? results.count - 1 : 0)
        select(results[index])
    }
    func select(_ result: DocumentSearchResult) {
        guard let workspace, let document = workspace.documents.first(where: { $0.id == result.documentID }) else { return }
        selectedID = result.id
        updateHighlights()
        workspace.navigate {
            workspace.activeID = document.id
            document.reveal(result.occurrence.range)
        }
    }
    private func updateHighlights() {
        for document in workspace?.documents ?? [] {
            let ranges = results.filter { $0.documentID == document.id }.map(\.occurrence.range)
            let active = results.first { $0.id == selectedID && $0.documentID == document.id }?.occurrence.range
            if document.searchRanges != ranges { document.searchRanges = ranges }
            if document.activeSearchRange != active { document.activeSearchRange = active }
        }
    }
    var status: String {
        if isSearching { return "Searching…" }
        if errorMessage != nil { return "Search error" }
        guard !query.isEmpty else { return "" }
        guard !results.isEmpty else { return "No matches" }
        if let index = results.firstIndex(where: { $0.id == selectedID }) { return "\(index + 1) of \(results.count)" }
        return "\(results.count) matches"
    }
}

struct SearchPanel: View {
    @ObservedObject var search: SearchController
    @FocusState private var focused: Bool
    var body: some View {
        if search.visible {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(search.useRegex ? "Regular expression…" : "Search Markdown…", text: $search.query)
                        .textFieldStyle(.roundedBorder).focused($focused)
                        .onKeyPress(keys: [.return], phases: .down) { press in
                            search.move(press.modifiers.contains(.shift) ? -1 : 1); return .handled
                        }
                        .onExitCommand { search.close() }
                        .accessibilityLabel("Search documents")
                    Picker("Search in", selection: $search.scope) {
                        ForEach(SearchScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().frame(width: 185)
                    Menu {
                        Toggle("Regular Expression", isOn: $search.useRegex)
                        Toggle("Match Case", isOn: $search.caseSensitive)
                        Toggle("Ignore Diacritics", isOn: $search.ignoreDiacritics)
                    } label: {
                        let count = [search.useRegex, search.caseSensitive, search.ignoreDiacritics].filter { $0 }.count
                        Label(count == 0 ? "Options" : "Options (\(count))", systemImage: "slider.horizontal.3")
                    }.fixedSize().help("Regular expressions, case matching, and diacritics")
                    Text(search.status).font(.caption).foregroundStyle(.secondary).frame(minWidth: 72)
                    Button { search.move(-1) } label: { Image(systemName: "chevron.up") }
                        .help("Previous match (⇧Return)").accessibilityLabel("Previous match").disabled(search.results.isEmpty)
                    Button { search.move(1) } label: { Image(systemName: "chevron.down") }
                        .help("Next match (Return)").accessibilityLabel("Next match").disabled(search.results.isEmpty)
                    Button { search.close() } label: { Image(systemName: "xmark") }
                        .help("Close search (Escape)").accessibilityLabel("Close search")
                }.padding(10)
                if let error = search.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 10)
                }
                if search.scope == .allDocuments && !search.query.isEmpty && !search.results.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(search.results) { result in
                                    Button { search.select(result) } label: {
                                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                                            Text("\(result.title):\(result.occurrence.line)").font(.system(.caption, design: .monospaced))
                                                .frame(width: 190, alignment: .leading).lineLimit(1)
                                            Text(result.occurrence.preview).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                        }.padding(.horizontal, 14).padding(.vertical, 7).contentShape(Rectangle())
                                            .background(result.id == search.selectedID ? Color.accentColor.opacity(0.15) : .clear)
                                    }.buttonStyle(.plain).help(result.path ?? "Unsaved document").id(result.id)
                                }
                            }
                        }.frame(maxHeight: 190)
                            .onChange(of: search.selectedID) { _, id in if let id { proxy.scrollTo(id) } }
                    }
                }
                Divider()
            }.background(.bar)
                .onAppear { focused = true }
                .onChange(of: search.focusGeneration) { _, _ in focused = true }
        }
    }
}
