import Foundation

extension IntegrationRegistry {
    /// Called by the app after an explicit tab-menu action. No token leaves the agent.
    public func requestAttachment(documentID: String, sessionID: String, transfer: Bool = false, expectedOwner: JSON? = nil) throws -> JSON {
        try transaction {
            _ = try document(documentID)
            guard !(try rows("SELECT id FROM sessions WHERE id=? AND last_keep_alive>?", [.string(sessionID), .number(Date().timeIntervalSince1970 - Self.keepAliveTimeout)])).isEmpty else {
                throw BridgeError("SESSION_NOT_FOUND", "This session is no longer active. Resume it before requesting an attachment.")
            }
            let owner = try attachment(documentID)
            if let expectedOwner, owner["session_id"] != expectedOwner["session_id"] || owner["generation"] != expectedOwner["generation"] {
                throw BridgeError("STALE_ATTACHMENT_REQUEST", "Ownership changed while the menu was open. Choose the session again.")
            }
            if owner["session_id"].string == sessionID { return owner }
            if owner["status"].string == "attached" && !transfer {
                throw BridgeError("DOCUMENT_ALREADY_ATTACHED", "Disconnect the current session before requesting another attachment.", details: owner)
            }
            let bindingID = try rows("SELECT binding_id FROM bindings WHERE document_id=?", [.string(documentID)]).first?["binding_id"] ?? .null
            try execute("INSERT INTO attachment_requests(request_id,document_id,session_id,created,expected_binding_id) VALUES(?,?,?,?,?) ON CONFLICT(document_id,session_id) DO UPDATE SET request_id=excluded.request_id,state='pending',created=excluded.created,expected_binding_id=excluded.expected_binding_id,attempts=0,next_attempt=0,lease_id=NULL,lease_until=0,accepted_at=NULL,last_error=NULL WHERE attachment_requests.state!='pending' ", [.string(UUID().uuidString), .string(documentID), .string(sessionID), .number(Date().timeIntervalSince1970), bindingID])
            try synchronizeSessionEvents()
            return try attachmentRequests(documentID: documentID).array.first { $0["session_id"].string == sessionID } ?? .null
        }
    }
    public func cancelAttachmentRequest(documentID: String, sessionID: String) throws {
        try execute("UPDATE attachment_requests SET state='cancelled',lease_id=NULL,lease_until=0 WHERE document_id=? AND session_id=? AND state='pending'", [.string(documentID), .string(sessionID)])
    }
    public func attachmentRequests(documentID: String) throws -> JSON {
        .array(try rows("""
            SELECT a.request_id,a.session_id,a.state,w.accepted_at,w.last_error,COALESCE(w.attempts,0) AS attempts,
                   e.bus_event_id,e.cursor AS bus_cursor
            FROM attachment_requests a LEFT JOIN session_events e ON e.attachment_request_id=a.request_id
            LEFT JOIN receivers r ON r.session_id=a.session_id
            LEFT JOIN event_wakeups w ON w.bus_event_id=e.bus_event_id AND w.receiver_id=r.receiver_id
            WHERE a.document_id=? AND a.state='pending'
            """, [.string(documentID)]).map(JSON.object))
    }
}
