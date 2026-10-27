import Foundation
import Darwin

private enum SocketIO {
    static let maximum = 32 * 1024 * 1024
    static func address(_ path: String) throws -> sockaddr_un {
        var value = sockaddr_un(); value.sun_family = sa_family_t(AF_UNIX)
        value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [UInt8(0)]
        guard bytes.count <= MemoryLayout.size(ofValue: value.sun_path) else { throw BridgeError("SOCKET_PATH_TOO_LONG", "The local socket path is too long.") }
        withUnsafeMutableBytes(of: &value.sun_path) { $0.copyBytes(from: bytes) }
        return value
    }
    static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        // Darwin can inherit O_NONBLOCK from the listening socket on accept.
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
        var timeout = timeval(tv_sec: 8, tv_usec: 0), yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }
    static func verifyPeer(_ fd: Int32) throws {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw BridgeError("ACCESS_DENIED", "The local API only accepts the current macOS user.") }
    }
    static func read(_ fd: Int32) throws -> JSON {
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16384)
        while data.count < maximum {
            let count = Darwin.recv(fd, &buffer, buffer.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw BridgeError("APP_UNAVAILABLE", "The app did not complete the local API request. Retry the same operation_id if this was a mutation.") }
            data.append(contentsOf: buffer.prefix(count))
            if let newline = data.firstIndex(of: 10) { return try JSON.parse(data.prefix(upTo: newline)) }
        }
        throw BridgeError("MESSAGE_TOO_LARGE", "The local API message exceeds 32 MB.")
    }
    static func write(_ value: JSON, to fd: Int32) throws {
        var data = try value.data(); data.append(10)
        guard data.count <= maximum else { throw BridgeError("MESSAGE_TOO_LARGE", "The local API message exceeds 32 MB.") }
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let count = Darwin.send(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw BridgeError("APP_UNAVAILABLE", "Could not send the local API message.") }
                sent += count
            }
        }
    }
}

public struct LocalAPIClient: Sendable {
    public let directory: URL
    public init(directory: URL = IntegrationPaths.directory) { self.directory = directory }
    public func call(_ method: String, params: JSON = .object([:])) throws -> JSON {
        let path = IntegrationPaths.socketDirectory(for: directory).appendingPathComponent("app.sock").path
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeError("APP_UNAVAILABLE", "Cannot create a local socket.") }
        defer { Darwin.close(fd) }; SocketIO.configure(fd)
        var address = try SocketIO.address(path)
        let status = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard status == 0 else { throw BridgeError("APP_UNAVAILABLE", "Parchment is not running or its API is unavailable. Call open_app or open_document.") }
        try SocketIO.verifyPeer(fd)
        try SocketIO.write(.object(["method": .string(method), "params": params]), to: fd)
        let response = try SocketIO.read(fd)
        if response["ok"].bool == true { return response["result"] }
        let error = response["error"]
        throw BridgeError(error["code"].string ?? "APP_ERROR", error["message"].string ?? "The app rejected the request.", details: error["details"])
    }
}

public final class LocalAPIServer: @unchecked Sendable {
    private var listener: DispatchSourceRead?
    private var lockFD: Int32 = -1
    private var ownsSocket = false
    private let directory: URL
    private let capacity = DispatchSemaphore(value: 16)
    public init(directory: URL = IntegrationPaths.directory) { self.directory = directory }
    /// Claim before loading a workspace so a second app cannot write session data.
    public func claim() throws {
        if lockFD >= 0 { return }
        let root = IntegrationPaths.socketDirectory(for: directory)
        var info = stat()
        if lstat(root.path, &info) == 0 {
            guard info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFDIR else { throw BridgeError("SOCKET_DIRECTORY_UNSAFE", "The socket directory is not owned by this user.") }
        } else { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        chmod(root.path, 0o700)
        lockFD = Darwin.open(root.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { Darwin.close(lockFD); lockFD = -1 }
            throw BridgeError("APP_ALREADY_RUNNING", "Another Parchment instance owns this local API.")
        }
    }
    public func start(handler: @escaping @Sendable (JSON) async -> JSON) throws {
        try claim()
        let root = IntegrationPaths.socketDirectory(for: directory)
        var info = stat()
        do {
            let path = root.appendingPathComponent("app.sock").path
            if lstat(path, &info) == 0 {
                guard info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFSOCK else { throw BridgeError("SOCKET_PATH_UNSAFE", "Refusing to replace a non-socket file.") }
                unlink(path)
            }
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw BridgeError("SOCKET_ERROR", "Cannot create the local API socket.") }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var address = try SocketIO.address(path)
            let status = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            ownsSocket = status == 0
            guard status == 0, Darwin.listen(fd, 16) == 0 else { Darwin.close(fd); throw BridgeError("SOCKET_ERROR", "Cannot listen on the local API socket.") }
            chmod(path, 0o600); _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "Parchment.LocalAPI"))
            source.setEventHandler { [weak self] in
                guard let self else { return }
                while true {
                    let client = Darwin.accept(fd, nil, nil)
                    guard client >= 0 else { break }
                    guard self.capacity.wait(timeout: .now()) == .success else { Darwin.close(client); continue }
                    SocketIO.configure(client)
                    DispatchQueue.global().async {
                        do {
                            try SocketIO.verifyPeer(client)
                            let request = try SocketIO.read(client)
                            Task {
                                let result = await handler(request)
                                try? SocketIO.write(result, to: client)
                                Darwin.close(client); self.capacity.signal()
                            }
                        } catch {
                            try? SocketIO.write(.object(["ok": .bool(false), "error": BridgeError.wrap(error).json]), to: client)
                            Darwin.close(client); self.capacity.signal()
                        }
                    }
                }
            }
            source.setCancelHandler { Darwin.close(fd) }
            listener = source; source.resume()
        } catch { stop(); throw error }
    }
    public func stop() {
        listener?.cancel(); listener = nil
        if lockFD >= 0 {
            if ownsSocket {
                unlink(IntegrationPaths.socketDirectory(for: directory).appendingPathComponent("app.sock").path)
                ownsSocket = false
            }
            flock(lockFD, LOCK_UN); Darwin.close(lockFD); lockFD = -1
        }
    }
    deinit { stop() }
}
