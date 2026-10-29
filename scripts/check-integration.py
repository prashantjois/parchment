#!/usr/bin/env python3
"""Exercise the actual app model, SQLite registry, Unix API, and stdio MCP helper."""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import queue
import shutil
import socket
import sqlite3
import subprocess
import tempfile
import threading
import time
import uuid


class MCP:
    def __init__(self, executable, env):
        self.process = subprocess.Popen([str(executable)], env=env, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        self.responses = queue.Queue()
        self.pending = {}
        self.counter = 0
        threading.Thread(target=self.read, daemon=True).start()
        self.request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                    "clientInfo": {"name": "integration-checks", "version": "1"}})
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def read(self):
        for line in self.process.stdout:
            try:
                self.responses.put(json.loads(line))
            except Exception as error:
                self.responses.put({"invalid_stdout": str(error), "line": line})

    def send(self, message):
        self.process.stdin.write(json.dumps(message, ensure_ascii=False) + "\n")
        self.process.stdin.flush()

    def begin(self, method, params=None):
        self.counter += 1
        self.send({"jsonrpc": "2.0", "id": self.counter, "method": method, "params": params or {}})
        return self.counter

    def receive(self, request_id, timeout=15):
        deadline = time.monotonic() + timeout
        while request_id not in self.pending:
            message = self.responses.get(timeout=max(0.01, deadline - time.monotonic()))
            assert "id" in message, message
            self.pending[message["id"]] = message
        return self.pending.pop(request_id)

    def request(self, method, params=None):
        result = self.receive(self.begin(method, params))
        assert "error" not in result, result
        return result["result"]

    def tool(self, name, args=None, error=None):
        result = self.request("tools/call", {"name": name, "arguments": args or {}})
        payload = json.loads(result["content"][0]["text"])
        if error:
            assert result.get("isError") and payload["code"] == error, (name, result)
        else:
            assert not result.get("isError"), (name, result)
        return payload

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        diagnostics = self.process.stderr.read()
        assert self.process.returncode == 0, diagnostics


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, default=Path(".build/debug/Parchment"))
    parser.add_argument("--mcp", type=Path, default=Path(".build/debug/ParchmentMCP"))
    options = parser.parse_args()
    checks = 0

    def passed(label):
        nonlocal checks
        checks += 1
        print(f"PASS {label}", flush=True)

    with tempfile.TemporaryDirectory(prefix="parchment-mcp-") as temporary:
        root = Path(temporary)
        state = root / "state"
        env = dict(os.environ, PARCHMENT_DATA_DIR=str(state))
        socket_root = Path(f"/tmp/parchment-{os.getuid()}-{hashlib.sha256(str(state).encode()).hexdigest()[:16]}")
        app = None
        clients = []
        log = open(root / "app.log", "w+")

        def local(method, **params):
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(10)
                connection.connect(str(socket_root / "app.sock"))
                connection.sendall((json.dumps({"method": method, "params": params}) + "\n").encode())
                with connection.makefile("r") as stream:
                    response = json.loads(stream.readline())
                assert response["ok"], response
                return response["result"]

        def start_app():
            process = subprocess.Popen([str(options.app.resolve()), "--integration-test-server", str(state)],
                                       env=env, stdout=log, stderr=log)
            for _ in range(150):
                try:
                    local("ping")
                    return process
                except (OSError, AssertionError):
                    if process.poll() is not None:
                        log.seek(0)
                        raise AssertionError(log.read())
                    time.sleep(0.1)
            process.kill()
            raise AssertionError("App API did not start")

        def stop_app():
            nonlocal app
            if app and app.poll() is None:
                app.terminate()
                app.wait(timeout=5)
            app = None

        def new_client():
            client = MCP(options.mcp.resolve(), env)
            clients.append(client)
            return client

        try:
            state.mkdir()
            with sqlite3.connect(state / "integration.sqlite") as database:
                database.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, token_hash TEXT NOT NULL UNIQUE, client TEXT NOT NULL, label TEXT NOT NULL, conversation_id TEXT, last_seen REAL NOT NULL)")
                database.execute("INSERT INTO sessions VALUES(?,?,?,?,?,?)", ("legacy-session", hashlib.sha256(b"legacy-token").hexdigest(), "Old client", "Legacy conversation", "old-runtime", 0))
                database.execute("PRAGMA user_version=1")
            a, b = new_client(), new_client()
            legacy = a.tool("resume_session", {"session_token": "legacy-token"})
            assert legacy["session_id"] == "legacy-session" and legacy["model"] is None
            passed("version-one registry migrates without losing session identity")
            tools = a.request("tools/list")["tools"]
            assert len(tools) == 23 and len({tool["name"] for tool in tools}) == 23
            a.tool("list_documents", error="APP_UNAVAILABLE")
            a.tool("create_session", {"wake_up": {"mode": "manual"}, "client": 42, "conversation_label": "bad"}, error="INVALID_ARGUMENT")
            passed("MCP initialization, schemas, and unavailable-app error")
            app = start_app()
            assert a.tool("open_app", {"activate": False})["app"] == "Parchment"
            initial = a.tool("list_documents")["documents"]
            assert len(initial) == 1 and initial[0]["path"] is None
            passed("live tab list includes unsaved documents")
            document_path = root / "notes.md"
            original = "# Plan\n\nHello 🌎.\n\nChange this paragraph.\n\nRepeated repeated.\n"
            document_path.write_text(original)
            first = a.tool("create_session", {"wake_up": {"mode": "manual"}, "client": "Agent A", "conversation_label": "Original conversation"})
            second = b.tool("create_session", {"wake_up": {"mode": "manual"}, "client": "Agent B", "conversation_label": "Second conversation"})
            draft_id = initial[0]["document_id"]
            draft_binding = a.tool("attach_document", {"document_id": draft_id, "session_token": first["session_token"]})
            draft_auth = dict(session_token=first["session_token"], binding_id=draft_binding["binding_id"], generation=draft_binding["generation"])
            draft = a.tool("get_document", {"document_id": draft_id})
            a.tool("apply_patch", dict(draft_auth, operation_id=str(uuid.uuid4()), expected_revision=draft["revision"], edits=[{"old_text": "", "new_text": "# Unsaved draft\n", "start": 0}]))
            assert a.tool("get_document", {"document_id": draft_id})["text"] == "# Unsaved draft\n"
            passed("agents can attach and edit unsaved tabs without a save dialog")
            opened = a.tool("open_document", {"path": str(document_path), "attach": True, "session_token": first["session_token"], "activate": False})
            doc_id = opened["document_id"]
            assert opened["attachment"]["status"] == "attached" and opened["view_mode"] == "rendered"
            attachment = opened["binding"]
            auth = {key: attachment[key] for key in ("binding_id", "generation")}
            auth["session_token"] = first["session_token"]
            assert a.tool("attach_document", {"document_id": doc_id, "session_token": first["session_token"]})["binding_id"] == auth["binding_id"]
            a.tool("open_document", {"path": str(document_path)})
            assert len(a.tool("list_documents")["documents"]) == 2
            assert json.loads(Path(str(document_path) + ".comments.json").read_text())["documentID"] == doc_id
            conflict = b.tool("attach_document", {"path": str(document_path), "session_token": second["session_token"]}, error="DOCUMENT_ALREADY_ATTACHED")
            assert first["session_token"] not in json.dumps(conflict)
            passed("open existing file, reuse tab, persist ID, and enforce one owner")
            updated = a.tool("update_session", {"session_token": first["session_token"], "conversation_label": "Renamed session", "model": "A different model"})
            assert updated["session_id"] == first["session_id"] and updated["model"] == "A different model"
            assert "Renamed session" in updated["display_name"] and "A different model" in updated["display_name"]
            assert a.tool("resume_session", {"session_token": first["session_token"]})["conversation_label"] == "Renamed session"
            assert a.tool("attach_document", {"document_id": doc_id, "session_token": first["session_token"]})["binding_id"] == auth["binding_id"]
            owners = a.tool("list_documents")["documents"]
            assert next(item for item in owners if item["document_id"] == doc_id)["attachment"]["model"] == "A different model"
            sessions = a.tool("list_sessions")
            listed = next(item for item in sessions["sessions"] if item["session_id"] == first["session_id"])
            assert len(listed["documents"]) == 2 and listed["conversation_label"] == "Renamed session"
            assert first["session_token"] not in json.dumps(sessions) and "token_hash" not in json.dumps(sessions)
            a.tool("update_session", {"session_token": "wrong", "model": "bad"}, error="INVALID_SESSION")
            a.tool("update_session", {"session_token": first["session_token"], "conversation_label": " "}, error="INVALID_ARGUMENT")
            assert a.tool("update_session", {"session_token": first["session_token"], "model": ""})["model"] is None
            assert a.tool("update_session", {"session_token": first["session_token"]})["conversation_label"] == "Renamed session"
            passed("session names and models synchronize in place and listing never exposes credentials")
            ref = {"document_id": doc_id}
            assert a.tool("get_document", ref)["text"] == original
            local("test_comment", **ref, quote="paragraph", body="Private draft", pending=True)
            assert a.tool("get_feedback", auth)["events"] == []
            assert "Private draft" not in json.dumps(a.tool("get_document", dict(ref, include_resolved=True)))
            local("test_comment", **ref, quote="Hello", body="Immediate feedback", pending=False)
            feedback = a.tool("get_feedback", auth)
            assert len(feedback["events"]) == 1
            thread_id = feedback["events"][0]["feedback"]["thread"]["thread"]["id"]
            local("test_reply", **ref, thread_id=thread_id, body="Pending reply secret", pending=True)
            assert "Pending reply secret" not in json.dumps(a.tool("get_document", dict(ref, include_resolved=True)))
            assert "Private draft" not in json.dumps(a.tool("get_feedback", auth))
            local("test_submit_review", **ref, summary="Please revise both passages")
            feedback = a.tool("get_feedback", auth)
            assert len(feedback["events"]) == 2
            review = feedback["events"][1]["feedback"]
            assert review["kind"] == "review_submitted" and len(review["threads"]) == 2
            assert "Pending reply secret" in json.dumps(review) and "Private draft" in json.dumps(review)
            passed("pending comments/replies stay private; review publishes one batch")
            assert a.tool("get_feedback", auth) == feedback
            a.tool("acknowledge_feedback", dict(auth, cursor=feedback["next_cursor"] + 100), error="INVALID_CURSOR")
            a.tool("acknowledge_feedback", dict(auth, cursor=feedback["next_cursor"]))
            a.tool("acknowledge_feedback", dict(auth, cursor=feedback["next_cursor"]))
            assert a.tool("get_feedback", auth)["events"] == []
            passed("feedback replays until durable, idempotent acknowledgement")
            waiting = a.begin("tools/call", {"name": "wait_for_feedback", "arguments": dict(auth, timeout_seconds=25)})
            assert a.request("ping") == {}
            a.send({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": waiting}})
            cancelled = a.receive(waiting)["result"]
            assert cancelled["isError"] and "CANCELLED" in cancelled["content"][0]["text"]
            assert a.tool("wait_for_feedback", dict(auth, timeout_seconds=0))["events"] == []
            passed("feedback wait supports concurrent requests, cancellation, and timeout")
            waiting = a.begin("tools/call", {"name": "wait_for_feedback", "arguments": dict(auth, timeout_seconds=5)})
            local("test_reply", **ref, thread_id=thread_id, body="User follow-up", pending=False)
            arrived = json.loads(a.receive(waiting)["result"]["content"][0]["text"])
            assert len(arrived["events"]) == 1 and arrived["events"][0]["feedback"]["kind"] == "reply_published"
            a.tool("acknowledge_feedback", dict(auth, cursor=arrived["next_cursor"]))
            passed("new user feedback completes an outstanding wait")
            current = a.tool("get_document", ref)
            patch = dict(auth, operation_id=str(uuid.uuid4()), expected_revision=current["revision"],
                         edits=[{"old_text": "Change this paragraph.", "new_text": "Revised paragraph."}])
            result = a.tool("apply_patch", patch)
            assert not result["replayed"]
            assert "Revised paragraph." in document_path.read_text()
            assert a.tool("apply_patch", patch)["replayed"]
            a.tool("apply_patch", dict(patch, operation_id=str(uuid.uuid4())), error="REVISION_CONFLICT")
            a.tool("apply_patch", dict(patch, edits=[{"old_text": "Hello", "new_text": "Bye"}]), error="OPERATION_ID_REUSED")
            local("test_undo", **ref)
            assert a.tool("get_document", ref)["text"] == original
            passed("revision-checked edits save live text, retry once, and support native undo")
            local("test_user_edit", **ref, text="# Changed\n\nrepeat repeat\n🌎\n")
            current = a.tool("get_document", ref)
            common = dict(auth, expected_revision=current["revision"])
            a.tool("apply_patch", dict(common, operation_id=str(uuid.uuid4()), edits=[{"old_text": "repeat", "new_text": "x"}]), error="PATCH_TARGET_AMBIGUOUS")
            a.tool("apply_patch", dict(common, operation_id=str(uuid.uuid4()), edits=[{"old_text": "", "new_text": "x", "start": 26}]), error="PATCH_TARGET_MISMATCH")
            a.tool("apply_patch", dict(common, operation_id=str(uuid.uuid4()), edits=[{"old_text": "repeat", "new_text": "x", "start": 11}, {"old_text": "repeat", "new_text": "y", "start": 11}]), error="OVERLAPPING_EDITS")
            a.tool("apply_patch", dict(common, operation_id=str(uuid.uuid4()), edits=[{"old_text": "repeat", "new_text": "first", "start": 11}]))
            assert "first repeat" in a.tool("get_document", ref)["text"]
            passed("patch ambiguity, Unicode boundaries, overlap, and explicit offsets")
            before = a.tool("get_document", ref)
            for old, new in (("first", "second"), ("second", "third")):
                live = a.tool("get_document", ref)
                a.tool("apply_patch", dict(auth, operation_id=str(uuid.uuid4()), expected_revision=live["revision"], edits=[{"old_text": old, "new_text": new}]))
            local("test_undo", **ref)
            assert "second repeat" in a.tool("get_document", ref)["text"], "One undo must reverse only the latest patch"
            local("test_undo", **ref)
            assert a.tool("get_document", ref)["text"] == before["text"]
            passed("successive agent edits remain separate undo steps")
            reply = dict(auth, operation_id=str(uuid.uuid4()), thread_id=thread_id, body="Updated the passage.")
            response = a.tool("reply_to_thread", reply)
            assert a.tool("reply_to_thread", reply)["event_id"] == response["event_id"]
            resolution = dict(auth, operation_id=str(uuid.uuid4()), thread_id=thread_id)
            a.tool("resolve_thread", resolution)
            assert a.tool("resolve_thread", resolution)["replayed"]
            history = a.tool("get_document", dict(ref, include_resolved=True))["comments"]["threads"]
            target = next(item for item in history if item["thread"]["id"] == thread_id)
            assert target["resolved"] and sum(event["kind"] == "reply" and event.get("origin") == "agent" for event in target["thread"]["events"]) == 1
            assert a.tool("get_feedback", auth)["events"] == []
            passed("agent replies and resolution retain history without feedback loops")
            local("test_comment", **ref, quote="Changed", body="Persist across restart", pending=False)
            queued = a.tool("get_feedback", auth)
            local("test_comment", **ref, quote="Changed", body="Discard this pending draft", pending=True)
            local("test_discard_review", **ref)
            assert a.tool("get_feedback", auth) == queued
            latest = a.tool("get_document", ref)
            recovery_patch = dict(auth, operation_id=str(uuid.uuid4()), expected_revision=latest["revision"], edits=[{"old_text": "# Changed", "new_text": "# Recovered"}])
            a.tool("apply_patch", recovery_patch)
            a.close()
            a = new_client()
            assert a.tool("resume_session", {"session_token": first["session_token"]})["session_id"] == first["session_id"]
            stop_app()
            # Simulate a crash after document save but before committing the receipt.
            with sqlite3.connect(state / "integration.sqlite") as database:
                database.execute("UPDATE operations SET state='prepared' WHERE operation_id IN (?,?,?)",
                                 (recovery_patch["operation_id"], reply["operation_id"], patch["operation_id"]))
            assert a.tool("get_feedback", auth) == queued
            app = start_app()
            assert a.tool("get_feedback", auth) == queued
            assert a.tool("attach_document", dict(ref, session_token=first["session_token"]))["binding_id"] == auth["binding_id"]
            assert a.tool("get_document", {"document_id": draft_id})["text"] == "# Unsaved draft\n"
            passed("ownership, source, and queued feedback survive helper and app restarts")
            assert a.tool("apply_patch", recovery_patch)["replayed"]
            assert a.tool("reply_to_thread", reply)["replayed"]
            a.tool("apply_patch", patch, error="OPERATION_INDETERMINATE")
            passed("interrupted operation receipts recover without duplicate edits or replies")
            a.tool("handoff_document", dict(auth, target_session_id=second["session_id"]))
            a.tool("get_feedback", auth, error="STALE_BINDING")
            a.tool("reply_to_thread", reply, error="STALE_BINDING")
            received = b.tool("attach_document", dict(ref, session_token=second["session_token"]))
            new_auth = dict(session_token=second["session_token"], binding_id=received["binding_id"], generation=received["generation"])
            assert b.tool("get_feedback", new_auth)["events"] == queued["events"]
            b.tool("acknowledge_feedback", dict(new_auth, cursor=queued["next_cursor"]))
            b.tool("detach_document", new_auth)
            b.tool("get_feedback", new_auth, error="STALE_BINDING")
            passed("explicit handoff carries feedback and rejects stale owner mutations")
            race_path = root / "race.md"
            race_path.write_text("# Concurrent attachments\n")
            race_id = a.tool("open_document", {"path": str(race_path)})["document_id"]
            with concurrent.futures.ThreadPoolExecutor() as pool:
                calls = [pool.submit(client.request, "tools/call", {"name": "attach_document", "arguments": {"document_id": race_id, "session_token": session["session_token"]}})
                         for client, session in ((a, first), (b, second))]
                results = [call.result() for call in calls]
            assert sorted(result["isError"] for result in results) == [False, True]
            passed("simultaneous agents cannot both own a document")
            copied = root / "copy" / "notes.md"
            copied.parent.mkdir()
            shutil.copyfile(document_path, copied)
            shutil.copyfile(str(document_path) + ".comments.json", str(copied) + ".comments.json")
            copy_id = a.tool("open_document", {"path": str(copied), "attach": True, "session_token": first["session_token"]})["document_id"]
            assert copy_id != doc_id
            copy_binding = a.tool("attach_document", {"document_id": copy_id, "session_token": first["session_token"]})
            assert a.tool("get_feedback", dict(session_token=first["session_token"], binding_id=copy_binding["binding_id"], generation=copy_binding["generation"]))["events"]
            local("test_close", **ref)
            moved_dir = root / "moved"
            moved_dir.mkdir()
            moved = moved_dir / "renamed.md"
            document_path.rename(moved)
            Path(str(document_path) + ".comments.json").rename(str(moved) + ".comments.json")
            assert a.tool("open_document", {"path": str(moved)})["document_id"] == doc_id
            passed("copied sidecars receive new IDs; moved files retain their identity")
            with sqlite3.connect(state / "integration.sqlite") as database:
                rows = database.execute("SELECT token_hash FROM sessions").fetchall()
                assert all(first["session_token"] != row[0] and len(row[0]) == 64 for row in rows)
            assert (state / "integration.sqlite").stat().st_mode & 0o777 == 0o600
            assert socket_root.stat().st_mode & 0o777 == 0o700
            passed("registry stores hashed tokens and restricts local transport permissions")
            empty = root / "file-comments.md"
            empty.write_text("")
            opened_file = a.tool("open_document", {"path": str(empty), "attach": True, "session_token": first["session_token"], "activate": False})
            file_ref = {"document_id": opened_file["document_id"]}
            file_auth = dict(session_token=first["session_token"], binding_id=opened_file["binding"]["binding_id"], generation=opened_file["binding"]["generation"])
            local("test_file_comment", **file_ref, body="Private file review", pending=True)
            assert a.tool("get_feedback", file_auth)["events"] == []
            local("test_submit_review", **file_ref, summary="Review the whole file")
            file_feedback = a.tool("get_feedback", file_auth)
            file_thread = file_feedback["events"][0]["feedback"]["threads"][0]
            assert file_thread["thread"]["scope"] == "file" and file_thread["current_anchor"]["state"] == "file"
            live_file = a.tool("get_document", file_ref)
            a.tool("apply_patch", dict(file_auth, operation_id=str(uuid.uuid4()), expected_revision=live_file["revision"], edits=[{"old_text":"", "new_text":"# New contents\n", "start":0}]))
            local("test_close", **file_ref)
            reopened_file = a.tool("get_document", file_ref)
            assert reopened_file["comments"]["threads"][0]["currentAnchor"]["state"] == "file"
            assert json.loads(Path(str(empty) + ".comments.json").read_text())["formatVersion"] == 3
            passed("file-level reviews stay private, publish through MCP, and survive edits and reopening")
            print(f"All {checks} integration checks passed.")
        except Exception:
            log.flush()
            log.seek(0)
            print(log.read())
            raise
        finally:
            stop_app()
            for client in clients:
                if client.process.poll() is None:
                    client.close()
            log.close()
            if socket_root.exists():
                shutil.rmtree(socket_root)


if __name__ == "__main__":
    main()
