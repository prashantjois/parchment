import AppKit
import UniformTypeIdentifiers

// This helper runs as the console user, only for the selected installer option.
let markdown = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
var types = [markdown.identifier: markdown]
for ext in ["md", "markdown"] {
    if let type = UTType(filenameExtension: ext), !type.isDynamic,
       type.conforms(to: .plainText), type != .plainText {
        types[type.identifier] = type
    }
}
let identifiers = types.keys.sorted()
if CommandLine.arguments == [CommandLine.arguments[0], "--inspect-markdown-types"] {
    let data = try JSONSerialization.data(withJSONObject: identifiers, options: .sortedKeys)
    FileHandle.standardOutput.write(data)
    exit(0)
}
guard CommandLine.arguments == [CommandLine.arguments[0], "--set-markdown-default"] else {
    fputs("Usage: ParchmentSetup --set-markdown-default | --inspect-markdown-types\n", stderr)
    exit(2)
}
guard getuid() != 0 else {
    fputs("Run the default app setup as the logged-in user.\n", stderr)
    exit(1)
}
let applicationURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
guard Bundle(url: applicationURL)?.bundleIdentifier == "local.parchment.editor" else {
    fputs("The setup helper must run from the installed Parchment app.\n", stderr)
    exit(1)
}
Task { @MainActor in
    do {
        for identifier in identifiers {
            try await NSWorkspace.shared.setDefaultApplication(at: applicationURL, toOpen: types[identifier]!)
        }
        print("Parchment is the default app for Markdown files.")
        exit(0)
    } catch {
        fputs("Could not change the default Markdown app: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}
RunLoop.main.run()
