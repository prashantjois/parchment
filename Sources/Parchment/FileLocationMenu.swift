import AppKit
import SwiftUI

struct FileLocationMenu: View {
    var name: String
    var url: URL?
    var isDirectory = false

    var body: some View {
        Button(isDirectory ? "Copy Folder Name" : "Copy File Name") {
            copy(name)
        }
        Button(isDirectory ? "Copy Folder Path" : "Copy File Path") {
            if let url { copy(url.path) }
        }
        .disabled(url == nil)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
