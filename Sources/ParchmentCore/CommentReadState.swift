import Foundation

/// Personal reading state is separate from discussion history and agent acknowledgements.
public struct CommentReadState: Codable, Equatable {
    private var seenMessages: Set<UUID> = []
    private var manuallyUnread: Set<UUID> = []
    public init() {}
    public func isUnread(_ thread: CommentThread, reader: String) -> Bool {
        !thread.isPending && (manuallyUnread.contains(thread.id) || thread.messages.contains {
            !$0.isPending && ($0.origin == "agent" || $0.author != reader) && !seenMessages.contains($0.id)
        })
    }
    public func isUnread(_ message: CommentEvent, in thread: CommentThread, reader: String) -> Bool {
        guard !thread.isPending, !message.isPending else { return false }
        if !seenMessages.contains(message.id), message.origin == "agent" || message.author != reader { return true }
        return manuallyUnread.contains(thread.id) && thread.messages.last(where: { !$0.isPending })?.id == message.id
    }
    public mutating func markRead(_ thread: CommentThread) {
        seenMessages.formUnion(thread.messages.filter { !$0.isPending }.map(\.id))
        manuallyUnread.remove(thread.id)
    }
    public mutating func markUnread(_ thread: CommentThread) {
        if !thread.isPending { manuallyUnread.insert(thread.id) }
    }
}
