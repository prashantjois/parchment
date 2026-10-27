import AppKit
import Carbon
import ParchmentCore
import ParchmentIntegration

@MainActor enum AppInstance {
    static func claimOrForward() -> LocalAPIServer {
        let server = LocalAPIServer()
        do { try server.claim(); return server }
        catch let error as BridgeError where error.code == "APP_ALREADY_RUNNING" {
            let application = NSApplication.shared
            let relay = LaunchRelay()
            application.setActivationPolicy(.prohibited)
            application.delegate = relay
            withExtendedLifetime(relay) { application.run() }
            exit(0)
        } catch {
            NSAlert(error: error).runModal()
            exit(1)
        }
    }
}

/// A second bundle copy forwards its launch events, then exits without loading
/// documents, writing session recovery, or starting another API listener.
@MainActor private final class LaunchRelay: NSObject, NSApplicationDelegate {
    private var pending: [URL] = []
    private var lastEvent = Date()
    private let client = LocalAPIClient()

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(openURL(_:withReplyEvent:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }
    @objc func openURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        if let value = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue, let url = URL(string: value) {
            application(NSApplication.shared, open: [url])
        }
    }
    func application(_ sender: NSApplication, open urls: [URL]) {
        pending.append(contentsOf: urls); lastEvent = Date()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            var ready = false
            for _ in 0..<100 {
                if (try? client.call("ping")) != nil { ready = true; break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard ready else {
                NSAlert(error: BridgeError("APP_BUSY", "Another Parchment copy is starting or closing. Retry opening the document after it finishes.")).runModal()
                exit(1)
            }
            do {
                _ = try client.call("activate")
                lastEvent = Date()
                repeat {
                    while !pending.isEmpty {
                        let url = pending.removeFirst()
                        do { _ = try client.call("open_url", params: .object(["url": .string(url.absoluteString)])) }
                        catch let error as BridgeError where error.code == "METHOD_NOT_FOUND" {
                            // Older installed builds can still open the file without line navigation.
                            let file = try url.isFileURL ? url : DocumentLink(url: url).fileURL
                            _ = try client.call("open_document", params: .object(["path": .string(file.path)]))
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                } while Date().timeIntervalSince(lastEvent) < 1
                exit(0)
            } catch {
                NSAlert(error: error).runModal()
                exit(1)
            }
        }
    }
}
