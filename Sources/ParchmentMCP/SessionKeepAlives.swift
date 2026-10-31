import Foundation
import ParchmentIntegration

/// Presence follows the live MCP transport, including while the model is idle.
/// Dispatch workers do not renew presence for dormant conversations.
final class SessionKeepAlives: @unchecked Sendable {
    private let registry: IntegrationRegistry
    private let lock = NSLock()
    private var tokens = Set<String>()
    private var timer: DispatchSourceTimer?
    private var stopped = false

    init(registry: IntegrationRegistry) {
        self.registry = registry
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + IntegrationRegistry.keepAliveInterval,
                       repeating: IntegrationRegistry.keepAliveInterval, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.renew() }
        self.timer = timer
        timer.resume()
    }
    deinit { stop() }

    @discardableResult func track(_ token: String) throws -> JSON {
        let result = try registry.keepAlive(token)
        lock.lock(); defer { lock.unlock() }
        if !stopped { tokens.insert(token) }
        return result
    }
    private func renew() {
        lock.lock()
        let current = stopped ? [] : Array(tokens)
        lock.unlock()
        for token in current {
            do { _ = try registry.keepAlive(token) }
            catch let error as BridgeError where error.code == "INVALID_SESSION" {
                lock.lock(); tokens.remove(token); lock.unlock()
            } catch { /* Keep the token and retry after transient registry errors. */ }
        }
    }
    func stop() {
        lock.lock()
        stopped = true; tokens.removeAll()
        let current = timer; timer = nil
        lock.unlock()
        current?.cancel()
    }
}
