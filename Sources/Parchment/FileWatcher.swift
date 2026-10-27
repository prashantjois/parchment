import Foundation
import Darwin

/// Watch both the file and its folder so atomic replacements remain observable.
@MainActor final class FileWatcher {
    private let url: URL
    private let changed: () -> Void
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?

    init(url: URL, changed: @escaping () -> Void) {
        self.url = url; self.changed = changed
        watchFile()
        directorySource = watch(url.deletingLastPathComponent()) { [weak self] in
            self?.watchFile()
            self?.changed()
        }
    }
    private func watchFile() {
        fileSource?.cancel()
        fileSource = watch(url, changed: changed)
    }
    private func watch(_ url: URL, changed: @escaping @MainActor () -> Void) -> DispatchSourceFileSystemObject? {
        let fd = Darwin.open(url.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .rename, .delete], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { changed() } }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        return source
    }
    deinit { fileSource?.cancel(); directorySource?.cancel() }
}
