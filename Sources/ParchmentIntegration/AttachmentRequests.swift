import Foundation

extension IntegrationRegistry {
    /// Called by the app after an explicit tab-menu action. No token leaves the agent.
    public func requestAttachment(documentID: String, sessionID: String, transfer: Bool = false, expectedOwner: JSON? = nil) throws -> JSON {
        try transaction {
            _ = try document(documentID)
            guard !(try rows("SELECT id FROM sessions WHERE id=?", [.string(sessionID)])).isEmpty else {
                throw BridgeError("SESSION_NOT_FOUND", "This session is no longer registered.")
            }
            let owner = try attachment(documentID)
            if let expectedOwner, owner["session_id"] != expectedOwner["session_id"] || owner["generation"] != expectedOwner["generation"] {
                throw BridgeError("STALE_ATTACHMENT_REQUEST", "Ownership changed while the menu was open. Choose the session again.")
            }
            if owner["session_id"].string == sessionID { return owner }
            if owner["status"].string == "attached" && !transfer {
                throw BridgeError("DOCUMENT_ALREADY_ATTACHED", "Disconnect the current session before requesting another attachment.", details: owner)
            }
            guard !(try rows("SELECT session_id FROM receivers WHERE session_id=?", [.string(sessionID)])).isEmpty else {
                throw BridgeError("RECEIVER_NOT_REGISTERED", "This session has no automatic receiver. Ask that agent to attach the document through MCP.")
            }
            let bindingID = try rows("SELECT binding_id FROM bindings WHERE document_id=?", [.string(documentID)]).first?["binding_id"] ?? .null
            try execute("INSERT INTO attachment_requests(request_id,document_id,session_id,created,expected_binding_id) VALUES(?,?,?,?,?) ON CONFLICT(document_id,session_id) DO UPDATE SET request_id=excluded.request_id,state='pending',created=excluded.created,expected_binding_id=excluded.expected_binding_id,attempts=0,next_attempt=0,lease_id=NULL,lease_until=0,accepted_at=NULL,last_error=NULL WHERE attachment_requests.state!='pending' ", [.string(UUID().uuidString), .string(documentID), .string(sessionID), .number(Date().timeIntervalSince1970), bindingID])
            return try attachmentRequests(documentID: documentID).array.first { $0["session_id"].string == sessionID } ?? .null
        }
    }
    public func cancelAttachmentRequest(documentID: String, sessionID: String) throws {
        try execute("UPDATE attachment_requests SET state='cancelled',lease_id=NULL,lease_until=0 WHERE document_id=? AND session_id=? AND state='pending'", [.string(documentID), .string(sessionID)])
    }
    public func attachmentRequests(documentID: String) throws -> JSON {
        .array(try rows("SELECT request_id,session_id,state,accepted_at,last_error,attempts FROM attachment_requests WHERE document_id=? AND state='pending'", [.string(documentID)]).map(JSON.object))
    }
    func claimAttachmentRequest() throws -> JSON? {
        let now = Date().timeIntervalSince1970
        guard var row = try rows("""
            SELECT a.*,a.request_id AS delivery_id,r.receiver_id,r.agent_session_id,r.executable,r.arguments
            FROM attachment_requests a JOIN receivers r ON r.session_id=a.session_id
            LEFT JOIN bindings b ON b.document_id=a.document_id
            WHERE a.state='pending' AND a.accepted_at IS NULL AND a.next_attempt<=? AND a.lease_until<=?
            AND (b.binding_id=a.expected_binding_id OR (b.binding_id IS NULL AND a.expected_binding_id IS NULL))
            ORDER BY a.created LIMIT 1
            """, [.number(now), .number(now)]).first else { return nil }
        let lease = UUID().uuidString
        try execute("UPDATE attachment_requests SET lease_id=?,lease_until=?,attempts=attempts+1 WHERE request_id=?", [.string(lease), .number(now + 30), row["request_id"]!])
        row["lease_id"] = .string(lease)
        row["attempts"] = .integer((row["attempts"]?.int ?? 0) + 1)
        row["type"] = .string("parchment.attachment_requested")
        return .object(row)
    }
    func attachmentRequestIsCurrent(_ delivery: JSON) throws -> Bool {
        !(try rows("""
            SELECT a.request_id FROM attachment_requests a JOIN receivers r ON r.session_id=a.session_id
            LEFT JOIN bindings b ON b.document_id=a.document_id
            WHERE a.request_id=? AND a.lease_id=? AND r.receiver_id=? AND a.state='pending' AND a.accepted_at IS NULL
            AND (b.binding_id=a.expected_binding_id OR (b.binding_id IS NULL AND a.expected_binding_id IS NULL))
            """, [delivery["delivery_id"], delivery["lease_id"], delivery["receiver_id"]])).isEmpty
    }
    func finishAttachmentRequest(_ delivery: JSON, error: String?) throws {
        if let error {
            let delay = min(60.0, pow(2, Double(min(delivery["attempts"].int ?? 1, 6))))
            try execute("UPDATE attachment_requests SET lease_id=NULL,lease_until=0,next_attempt=?,last_error=? WHERE request_id=? AND lease_id=?", [.number(Date().timeIntervalSince1970 + delay), .string(error), delivery["delivery_id"], delivery["lease_id"]])
        } else {
            try execute("UPDATE attachment_requests SET lease_id=NULL,lease_until=0,accepted_at=?,last_error=NULL WHERE request_id=? AND lease_id=?", [.number(Date().timeIntervalSince1970), delivery["delivery_id"], delivery["lease_id"]])
        }
    }
}
