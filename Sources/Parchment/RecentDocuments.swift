import AppKit
import SwiftUI

@MainActor final class RecentDocuments {
    private(set) var urls: [URL]
    private let storageURL: URL
    private let recordsSystemRecents: Bool
    private let hasStoredHistory: Bool

    init(storageURL: URL, recordsSystemRecents: Bool) {
        self.storageURL = storageURL; self.recordsSystemRecents = recordsSystemRecents
        if let data = try? Data(contentsOf: storageURL), let paths = try? JSONDecoder().decode([String].self, from: data) {
            urls = Self.available(paths.map { URL(fileURLWithPath: $0) })
            hasStoredHistory = true
        } else {
            urls = recordsSystemRecents ? Self.available(NSDocumentController.shared.recentDocumentURLs) : []
            hasStoredHistory = false
        }
    }
    func seedFromSession(_ restored: [URL]) {
        guard !hasStoredHistory else { return }
        urls = Self.available(restored + urls)
        persist()
    }
    func note(_ url: URL) {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard Self.isAvailable(canonical) else { return }
        urls = Self.available([canonical] + urls)
        persist()
        if recordsSystemRecents { NSDocumentController.shared.noteNewRecentDocumentURL(canonical) }
    }
    func clear() {
        urls = []; persist()
        if recordsSystemRecents { NSDocumentController.shared.clearRecentDocuments(nil) }
    }
    func refresh() {
        let available = Self.available(urls)
        if available != urls { urls = available; persist() }
    }
    private static func isAvailable(_ url: URL) -> Bool {
        url.isFileURL && FileManager.default.isReadableFile(atPath: url.path) &&
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
    private static func available(_ urls: [URL]) -> [URL] {
        var seen: Set<URL> = []
        return Array(urls.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .filter { isAvailable($0) && seen.insert($0).inserted }.prefix(20))
    }
    private func persist() {
        do { try JSONEncoder().encode(urls.map(\.path)).write(to: storageURL, options: .atomic) }
        catch { NSLog("Could not save Parchment's recent-file list: %@", error.localizedDescription) }
    }
}

/// Refresh the native submenu as it opens; SwiftUI can cache command-menu content.
@MainActor final class RecentDocumentsMenuController: NSObject, NSMenuDelegate {
    private let recentDocuments: RecentDocuments
    private let open: (URL) -> Void
    private let menu = NSMenu(title: "Open Recent")
    private var observer: NSObjectProtocol?

    init(recentDocuments: RecentDocuments, open: @escaping (URL) -> Void) {
        self.recentDocuments = recentDocuments; self.open = open
        super.init()
        menu.delegate = self; menu.autoenablesItems = false
        observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, notification.object as? NSMenu !== self.menu else { return }
                self.install()
            }
        }
        install()
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func install() {
        func find(in menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.title == "Open Recent" { return item }
                if let submenu = item.submenu, let found = find(in: submenu) { return found }
            }
            return nil
        }
        guard let main = NSApp.mainMenu, let item = find(in: main) else { return }
        menuNeedsUpdate(menu)
        if item.submenu !== menu { item.submenu = menu }
        item.isEnabled = true
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        recentDocuments.refresh()
        menu.removeAllItems()
        if recentDocuments.urls.isEmpty {
            let empty = NSMenuItem(title: "No Recent Documents", action: nil, keyEquivalent: "")
            empty.isEnabled = false; menu.addItem(empty)
        }
        for url in recentDocuments.urls {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = url; item.toolTip = url.path
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearRecent), keyEquivalent: "")
        clear.target = self; clear.isEnabled = !recentDocuments.urls.isEmpty; menu.addItem(clear)
    }
    @objc private func openRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { open(url) }
    }
    @objc private func clearRecent() { recentDocuments.clear() }
}

struct FileOpeningCommands: Commands {
    var newDocument: () -> Void
    var openPanel: () -> Void
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab", action: newDocument).keyboardShortcut("n")
            Button("Open…", action: openPanel).keyboardShortcut("o")
            Menu("Open Recent") {
                Text("No Recent Documents")
            }
        }
    }
}
