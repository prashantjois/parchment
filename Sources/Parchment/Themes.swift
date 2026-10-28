import AppKit
import SwiftUI
import ParchmentCore

struct EditorTheme: Identifiable {
    var id: String
    var name: String
    var css: String
    var url: URL
    var custom: Bool
}

@MainActor final class ThemeLibrary: ObservableObject {
    @Published var items: [EditorTheme] = []
    @Published var selectedID: String { didSet { UserDefaults.standard.set(selectedID, forKey: "theme") } }
    @Published var appearance: String { didSet { UserDefaults.standard.set(appearance, forKey: "appearance") } }
    @Published var fontSize: Double { didSet { UserDefaults.standard.set(fontSize, forKey: "fontSize") } }
    @Published var customFont: String { didSet { UserDefaults.standard.set(customFont, forKey: "customFont") } }
    @Published var lightText: String { didSet { UserDefaults.standard.set(lightText, forKey: "lightText") } }
    @Published var darkText: String { didSet { UserDefaults.standard.set(darkText, forKey: "darkText") } }
    let baseCSS: String
    let customDirectory: URL
    var selected: EditorTheme? { items.first { $0.id == selectedID } ?? items.first }
    static var bundledDirectory: URL {
        if let root = Bundle.main.resourceURL?.appendingPathComponent("themes"), FileManager.default.fileExists(atPath: root.path) { return root }
        return Bundle.module.resourceURL!.appendingPathComponent("themes")
    }
    init() {
        let defaults = UserDefaults.standard
        selectedID = defaults.string(forKey: "theme") ?? "parchment"
        appearance = defaults.string(forKey: "appearance") ?? "system"
        fontSize = defaults.double(forKey: "fontSize")
        customFont = defaults.string(forKey: "customFont") ?? ""
        lightText = defaults.string(forKey: "lightText") ?? ""; darkText = defaults.string(forKey: "darkText") ?? ""
        let root = Self.bundledDirectory
        baseCSS = (try? String(contentsOf: root.appendingPathComponent("base.css"), encoding: .utf8)) ?? ""
        customDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Parchment/Themes", isDirectory: true)
        try? FileManager.default.createDirectory(at: customDirectory, withIntermediateDirectories: true)
        reload()
    }
    func reload() {
        let root = Self.bundledDirectory
        items = [(root, false), (customDirectory, true)].flatMap { directory, custom in
            ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).compactMap { url -> EditorTheme? in
                guard url.lastPathComponent.hasSuffix(".theme.css"), let css = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let id = url.lastPathComponent.replacingOccurrences(of: ".theme.css", with: "")
                let regex = try! NSRegularExpression(pattern: #"--pt-theme-name:\s*"([^"]+)""#)
                let match = regex.firstMatch(in: css, range: NSRange(css.startIndex..., in: css))
                let name = match.map { (css as NSString).substring(with: $0.range(at: 1)) } ?? id.capitalized
                return EditorTheme(id: custom ? "custom-" + id : id, name: name, css: css, url: url, custom: custom)
            }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func css(dark: Bool, preview: String? = nil) -> String {
        var declarations = ""
        if fontSize > 0 { declarations += "--pt-font-size: \(fontSize)px;" }
        if !customFont.isEmpty {
            let safe = customFont.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "")
            declarations += "--pt-font-body: \"\(safe)\", serif;"
        }
        let color = dark ? darkText : lightText
        if color.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil { declarations += "--pt-text: \(color);" }
        return baseCSS + "\n" + (preview ?? selected?.css ?? "") + "\n@layer parchment-user { .markdown-doc { \(declarations) } }"
    }
    func duplicate(css: String, name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ThemeError.invalid("Enter a theme name.") }
        let id = UUID().uuidString.lowercased()
        let safeName = name.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\\", with: "")
        let content = css + "\n@layer parchment-theme { .markdown-doc { --pt-theme-name: \"\(safeName)\"; } }\n"
        try content.write(to: customDirectory.appendingPathComponent(id + ".theme.css"), atomically: true, encoding: .utf8)
        reload(); selectedID = "custom-" + id
    }
}
enum ThemeError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

struct ThemeSettings: View {
    @ObservedObject var library: ThemeLibrary
    @Environment(\.dismiss) private var dismiss
    @ViewState<String> private var css = ""
    @ViewState<String> private var name = "My Theme"
    @ViewState<String?> private var error: String?
    @ViewState<Bool> private var preview = false
    @StateObject private var sample = EditorDocument(url: nil, text: "# A place for your words\n\nA native editor for **clear ideas**, thoughtful notes, and [useful links](https://example.com).\n\n## The details matter\n\n> Good writing starts with room to think.\n\n- Local Markdown files\n- Your fonts and colors\n- Comments that stay with the document\n\n```swift\nlet idea = \"Something worth keeping\"\n```\n\n| Feature | Status |\n| --- | --- |\n| Light and dark | Ready |")
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Themes").font(.title2.bold()); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonFeedback("Close theme settings (Return)") }
            HStack(alignment: .top, spacing: 20) {
                Form {
                    Picker("Theme", selection: $library.selectedID) { ForEach(library.items) { Text($0.name).tag($0.id) } }.buttonFeedback("Choose the document theme")
                    Picker("Appearance", selection: $library.appearance) {
                        Text("Follow System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                    }.buttonFeedback("Choose system, light, or dark appearance")
                    HStack {
                        Text("Font size")
                        Stepper(library.fontSize == 0 ? "Theme default" : "\(Int(library.fontSize)) px", value: $library.fontSize, in: 0...40).help("Adjust the document font size. Zero uses the theme default.")
                    }
                    Picker("Body font", selection: $library.customFont) {
                        Text("Theme default").tag("")
                        ForEach(["Georgia", "Charter", "Menlo", "Avenir Next", "Helvetica Neue", "Palatino", "Baskerville"], id: \.self) { Text($0).tag($0) }
                    }.buttonFeedback("Choose the document body font")
                    TextField("Light text color", text: $library.lightText, prompt: Text("#242424"))
                    TextField("Dark text color", text: $library.darkText, prompt: Text("#f2f2f7"))
                    Text("Leave colors empty to use the theme palette. Font size 0 uses the theme default.").font(.caption).foregroundStyle(.secondary)
                    Button("Reset overrides") { library.fontSize = 0; library.customFont = ""; library.lightText = ""; library.darkText = "" }.buttonFeedback("Restore the theme's font size, font, and text colors")
                    Divider()
                    Text("Theme CSS").font(.headline)
                    TextEditor(text: $css).font(.system(size: 11, design: .monospaced)).frame(height: 220).border(.quaternary)
                    TextField("Custom theme name", text: $name)
                    HStack {
                        Button("Preview CSS") { validateAnd { preview = true } }.buttonFeedback("Validate this CSS and preview it on the sample document")
                        Button("Save as Custom") { validateAnd { do { try library.duplicate(css: css, name: name); preview = false } catch { self.error = error.localizedDescription } } }.buttonFeedback("Save this CSS as a new custom theme")
                    }
                    Button("Import CSS…") {
                        let panel = NSOpenPanel(); panel.allowedContentTypes = [.init(filenameExtension: "css") ?? .plainText]
                        if panel.runModal() == .OK, let url = panel.url {
                            do { css = try String(contentsOf: url, encoding: .utf8); name = url.deletingPathExtension().lastPathComponent }
                            catch { self.error = error.localizedDescription }
                        }
                    }.buttonFeedback("Import a CSS theme from a file")
                }.formStyle(.grouped).frame(width: 390)
                RenderedPane(document: sample, themes: library, previewCSS: preview ? css : nil, allowsComments: false, beginComment: {}).frame(minWidth: 400)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(20).frame(width: 920, height: 740)
        .onAppear { css = library.selected?.css ?? "" }
        .onChange(of: library.selectedID) { _, _ in css = library.selected?.css ?? ""; preview = false }
    }
    func validateAnd(_ action: @escaping () -> Void) {
        ThemeCSSValidator.validate(css) { result in
            switch result { case .success: error = nil; action(); case .failure(let failure): error = failure.localizedDescription }
        }
    }
}
