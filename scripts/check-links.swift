import AppKit

// Launch an isolated instance through Launch Services and deliver a real URL event.
guard CommandLine.arguments.count == 4,
      let link = URL(string: CommandLine.arguments[3]) else { exit(2) }
let app = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
guard let registered = NSWorkspace.shared.urlForApplication(toOpen: link),
      Bundle(url: registered)?.bundleIdentifier == "local.parchment.editor" else {
    fputs("The parchment URL scheme is not registered to Parchment.\n", stderr); exit(1)
}
let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = false
configuration.createsNewApplicationInstance = true
configuration.environment = ["PARCHMENT_DATA_DIR": CommandLine.arguments[2]]
NSWorkspace.shared.open([link], withApplicationAt: app, configuration: configuration) { running, error in
    guard let running, error == nil else {
        fputs("URL launch failed: \(error?.localizedDescription ?? "No running app")\n", stderr); exit(1)
    }
    print(running.processIdentifier)
    exit(0)
}
RunLoop.main.run()
