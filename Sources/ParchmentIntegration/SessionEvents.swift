import Foundation

extension IntegrationRegistry {
    /// Called inside the registry's migration transaction. Old receipts remain valid.
    func createEventBus(migrating: Bool) throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS session_events (
              cursor INTEGER PRIMARY KEY AUTOINCREMENT, bus_event_id TEXT NOT NULL UNIQUE,
              session_id TEXT NOT NULL REFERENCES sessions(id), document_id TEXT NOT NULL REFERENCES documents(id),
              type TEXT NOT NULL, binding_id TEXT, generation INTEGER,
              feedback_sequence INTEGER REFERENCES feedback(sequence), attachment_request_id TEXT,
              state TEXT NOT NULL DEFAULT 'pending', read_at REAL, created REAL NOT NULL,
              UNIQUE(binding_id,feedback_sequence), UNIQUE(attachment_request_id))
            """)
        try execute("CREATE INDEX IF NOT EXISTS session_event_inbox ON session_events(session_id,state,cursor)")
        try execute("""
            CREATE TABLE IF NOT EXISTS event_wakeups (
              delivery_id TEXT PRIMARY KEY, bus_event_id TEXT NOT NULL REFERENCES session_events(bus_event_id),
              receiver_id TEXT NOT NULL REFERENCES receivers(receiver_id) ON DELETE CASCADE,
              attempts INTEGER NOT NULL DEFAULT 0, next_attempt REAL NOT NULL DEFAULT 0,
              lease_id TEXT, lease_until REAL NOT NULL DEFAULT 0, accepted_at REAL, last_error TEXT,
              UNIQUE(receiver_id,bus_event_id))
            """)
        try execute("CREATE INDEX IF NOT EXISTS event_wakeup_due ON event_wakeups(accepted_at,next_attempt,lease_until)")
        guard migrating else { return }
        try synchronizeSessionEvents()
        try execute("""
            INSERT OR IGNORE INTO event_wakeups(delivery_id,bus_event_id,receiver_id,attempts,next_attempt,lease_until,accepted_at,last_error)
            SELECT n.delivery_id,e.bus_event_id,n.receiver_id,n.attempts,n.next_attempt,n.lease_until,n.accepted_at,n.last_error
            FROM notifications n JOIN session_events e ON e.binding_id=n.binding_id AND e.feedback_sequence=n.sequence
            JOIN receivers r ON r.receiver_id=n.receiver_id AND r.session_id=e.session_id
            WHERE e.state='pending'
            """)
        try execute("""
            INSERT OR IGNORE INTO event_wakeups(delivery_id,bus_event_id,receiver_id,attempts,next_attempt,lease_until,accepted_at,last_error)
            SELECT a.request_id,e.bus_event_id,r.receiver_id,a.attempts,a.next_attempt,a.lease_until,a.accepted_at,a.last_error
            FROM attachment_requests a JOIN session_events e ON e.attachment_request_id=a.request_id
            JOIN receivers r ON r.session_id=a.session_id WHERE e.state='pending'
            """)
    }

    /// All event producers use this inbox, independently of receiver registration.
    func synchronizeSessionEvents() throws {
        try execute("""
            INSERT OR IGNORE INTO session_events(bus_event_id,session_id,document_id,type,binding_id,generation,feedback_sequence,created)
            SELECT lower(hex(randomblob(16))),b.session_id,b.document_id,'parchment.feedback_available',b.binding_id,b.generation,f.sequence,f.created
            FROM feedback f JOIN bindings b ON b.document_id=f.document_id
            WHERE b.session_id IS NOT NULL AND f.sequence>b.acknowledged
              AND NOT EXISTS(SELECT 1 FROM session_events e WHERE e.binding_id=b.binding_id AND e.feedback_sequence=f.sequence)
            """)
        try execute("""
            INSERT OR IGNORE INTO session_events(bus_event_id,session_id,document_id,type,attachment_request_id,created)
            SELECT a.request_id,a.session_id,a.document_id,'parchment.attachment_requested',a.request_id,a.created
            FROM attachment_requests a LEFT JOIN bindings b ON b.document_id=a.document_id
            WHERE a.state='pending' AND (a.expected_binding_id=b.binding_id OR (a.expected_binding_id IS NULL AND b.binding_id IS NULL))
              AND NOT EXISTS(SELECT 1 FROM session_events e WHERE e.attachment_request_id=a.request_id)
            """)
        try execute("""
            UPDATE session_events SET state='handled' WHERE state='pending' AND (
              EXISTS(SELECT 1 FROM bindings b WHERE b.binding_id=session_events.binding_id AND b.session_id=session_events.session_id
                     AND b.acknowledged>=session_events.feedback_sequence)
              OR EXISTS(SELECT 1 FROM attachment_requests a WHERE a.request_id=session_events.attachment_request_id AND a.state='attached'))
            """)
        try execute("""
            UPDATE session_events SET state='cancelled' WHERE state='pending' AND (
              (type='parchment.feedback_available' AND NOT EXISTS(
                SELECT 1 FROM bindings b WHERE b.binding_id=session_events.binding_id AND b.generation=session_events.generation
                  AND b.session_id=session_events.session_id))
              OR (type='parchment.attachment_requested' AND NOT EXISTS(
                SELECT 1 FROM attachment_requests a LEFT JOIN bindings b ON b.document_id=a.document_id
                WHERE a.request_id=session_events.attachment_request_id AND a.state='pending'
                  AND (a.expected_binding_id=b.binding_id OR (a.expected_binding_id IS NULL AND b.binding_id IS NULL)))))
            """)
    }

    public func sessionEvents(_ args: JSON) throws -> JSON {
        try transaction {
            let owner = try session(args.require("session_token"))
            try synchronizeSessionEvents()
            let limit = min(100, max(1, args["limit"].int ?? 50))
            let events = try rows("""
                SELECT e.cursor,e.bus_event_id,e.session_id,e.document_id,e.type,e.binding_id,e.generation,
                       e.feedback_sequence AS feedback_cursor,e.attachment_request_id,f.event_id,d.title,d.path
                FROM session_events e JOIN documents d ON d.id=e.document_id
                LEFT JOIN feedback f ON f.sequence=e.feedback_sequence
                WHERE e.session_id=? AND e.state='pending' ORDER BY e.cursor LIMIT ?
                """, [owner["session_id"], .integer(limit)])
            for event in events {
                try execute("UPDATE session_events SET read_at=? WHERE bus_event_id=?", [.number(Date().timeIntervalSince1970), event["bus_event_id"]!])
            }
            return .object(["session_id": owner["session_id"], "events": .array(events.map(JSON.object))])
        }
    }

    public func acknowledgeEvents(_ args: JSON) throws -> JSON {
        try transaction {
            let owner = try session(args.require("session_token")), ids = args["event_ids"].array
            guard !ids.isEmpty, ids.count <= 100, ids.allSatisfy({ $0.string?.isEmpty == false }) else {
                throw BridgeError("INVALID_ARGUMENT", "Supply 1–100 bus event IDs that this session has handled.")
            }
            try synchronizeSessionEvents()
            for id in ids {
                guard let event = try rows("SELECT * FROM session_events WHERE bus_event_id=? AND session_id=?", [id, owner["session_id"]]).first else {
                    throw BridgeError("EVENT_NOT_FOUND", "This event does not belong to the session.")
                }
                guard event["read_at"] != .null else { throw BridgeError("EVENT_NOT_READ", "Call get_events before acknowledging an event.") }
                guard event["state"]?.string != "pending" else {
                    throw BridgeError("EVENT_NOT_HANDLED", "Accept or cancel the attachment request, or handle and acknowledge its document feedback first.")
                }
            }
            return .object(["acknowledged_event_ids": .array(ids)])
        }
    }

    /// A single leased outbox wakes agents for every kind of bus event.
    public func claimNotification() throws -> JSON? {
        try transaction {
            try synchronizeSessionEvents()
            try execute("""
                INSERT OR IGNORE INTO event_wakeups(delivery_id,bus_event_id,receiver_id)
                SELECT lower(hex(randomblob(16))),e.bus_event_id,r.receiver_id
                FROM session_events e JOIN receivers r ON r.session_id=e.session_id WHERE e.state='pending'
                """)
            let now = Date().timeIntervalSince1970
            guard var delivery = try rows("""
                SELECT w.*,e.cursor AS bus_cursor,e.session_id,e.document_id,e.type,e.binding_id,e.generation,
                       e.feedback_sequence AS sequence,e.attachment_request_id,f.event_id,
                       r.agent_session_id,r.executable,r.arguments
                FROM event_wakeups w JOIN session_events e ON e.bus_event_id=w.bus_event_id
                JOIN receivers r ON r.receiver_id=w.receiver_id AND r.session_id=e.session_id
                LEFT JOIN feedback f ON f.sequence=e.feedback_sequence
                WHERE e.state='pending' AND w.accepted_at IS NULL AND w.next_attempt<=? AND w.lease_until<=?
                ORDER BY e.cursor LIMIT 1
                """, [.number(now), .number(now)]).first else { return nil }
            let lease = UUID().uuidString
            try execute("UPDATE event_wakeups SET lease_id=?,lease_until=?,attempts=attempts+1 WHERE delivery_id=?", [.string(lease), .number(now + 30), delivery["delivery_id"]!])
            delivery["lease_id"] = .string(lease)
            delivery["attempts"] = .integer((delivery["attempts"]?.int ?? 0) + 1)
            return .object(delivery)
        }
    }
    public func notificationIsCurrent(_ delivery: JSON) throws -> Bool {
        try transaction {
            try synchronizeSessionEvents()
            return !(try rows("""
                SELECT w.delivery_id FROM event_wakeups w JOIN session_events e ON e.bus_event_id=w.bus_event_id
                JOIN receivers r ON r.receiver_id=w.receiver_id AND r.session_id=e.session_id
                WHERE w.delivery_id=? AND w.lease_id=? AND e.state='pending' AND w.accepted_at IS NULL
                """, [delivery["delivery_id"], delivery["lease_id"]])).isEmpty
        }
    }
    public func finishNotification(_ delivery: JSON, error: String?) throws {
        if let error {
            let delay = min(60.0, pow(2, Double(min(delivery["attempts"].int ?? 1, 6))))
            try execute("UPDATE event_wakeups SET lease_id=NULL,lease_until=0,next_attempt=?,last_error=? WHERE delivery_id=? AND lease_id=?", [.number(Date().timeIntervalSince1970 + delay), .string(error), delivery["delivery_id"], delivery["lease_id"]])
        } else {
            try execute("UPDATE event_wakeups SET lease_id=NULL,lease_until=0,accepted_at=?,last_error=NULL WHERE delivery_id=? AND lease_id=?", [.number(Date().timeIntervalSince1970), delivery["delivery_id"], delivery["lease_id"]])
        }
    }
}
