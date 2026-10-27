import SwiftUI

struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Editing Guide") { openWindow(id: "editing-help") }
            Button("Comments Guide") { openWindow(id: "comments-help") }
        }
    }
}

struct HelpGuideView: View {
    @StateObject private var document: EditorDocument
    @ObservedObject var themes: ThemeLibrary
    var openDocument: (URL) -> Void

    init(name: String, themes: ThemeLibrary, openDocument: @escaping (URL) -> Void) {
        let url = Bundle.main.resourceURL?.appendingPathComponent("docs/help/\(name).md")
        let text: String
        if let url, let source = try? String(contentsOf: url, encoding: .utf8) {
            text = source
        } else {
            text = "# Help is unavailable\n\nReinstall Parchment to restore its help files."
        }
        _document = StateObject(wrappedValue: EditorDocument(url: url, text: text))
        self.themes = themes
        self.openDocument = openDocument
    }

    var body: some View {
        RenderedPane(document: document, themes: themes, allowsComments: false,
                     openDocument: openDocument, beginComment: {})
            .frame(minWidth: 480, minHeight: 360)
    }
}
