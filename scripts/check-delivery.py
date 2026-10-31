#!/usr/bin/env python3
"""Exercise real receiver processes and the durable agent notification outbox."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import runpy
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time

MCP = runpy.run_path(str(Path(__file__).with_name("check-integration.py")))["MCP"]
options = argparse.ArgumentParser()
options.add_argument("--app", type=Path, default=Path(".build/debug/Parchment"))
options.add_argument("--mcp", type=Path, default=Path(".build/debug/ParchmentMCP"))
args = options.parse_args()


def until(predicate, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError("Timed out waiting for receiver state")


with tempfile.TemporaryDirectory(prefix="parchment-delivery-") as temporary:
    root = Path(temporary)
    state, inbox = root / "state", root / "inbox"
    inbox.mkdir()
    env = dict(os.environ, PARCHMENT_DATA_DIR=str(state))
    socket_root = Path(f"/tmp/parchment-{os.getuid()}-{hashlib.sha256(str(state).encode()).hexdigest()[:16]}")
    clients, workers = [], []
    app = None
    log = open(root / "app.log", "w+")
    mode = inbox / "mode"
    mode.write_text("accept")
    fixture = root / "receiver.py"
    fixture.write_text('''import json, os, pathlib, signal, sys, time
inbox = pathlib.Path(sys.argv[1])
mode = (inbox / "mode").read_text()
with open(inbox / "attempts.jsonl", "a") as log:
    log.write(json.dumps({"pid":os.getpid(), "args":sys.argv[2:], "mode":mode}) + "\\n")
if mode == "reject": sys.exit(75)
if mode == "hang":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    time.sleep(60)
event = json.load(sys.stdin)
path = inbox / (event["delivery_id"] + ".json")
if not path.exists():
    staged = path.with_suffix(".tmp")
    with open(staged, "w") as stream:
        json.dump({"event":event, "args":sys.argv[2:]}, stream)
        stream.flush(); os.fsync(stream.fileno())
    staged.replace(path)
''')

    def client():
        value = MCP(args.mcp.resolve(), env)
        clients.append(value)
        return value

    def local(method, expected_error=None, **params):
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(10)
            connection.connect(str(socket_root / "app.sock"))
            connection.sendall((json.dumps({"method": method, "params": params}) + "\n").encode())
            with connection.makefile("r") as stream:
                response = json.loads(stream.readline())
        if expected_error:
            assert not response["ok"] and response["error"]["code"] == expected_error, response
            return response["error"]
        assert response["ok"], response
        return response["result"]

    def start_app():
        process = subprocess.Popen([str(args.app.resolve()), "--integration-test-server", str(state)], env=env, stdout=log, stderr=log)
        def ready():
            assert process.poll() is None, "App exited"
            try:
                return local("ping")
            except OSError:
                return False
        until(ready)
        return process

    def stop(process):
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait(timeout=3)

    def start_worker():
        process = subprocess.Popen([str(args.mcp.resolve()), "--dispatch-feedback"], env=env, stdout=log, stderr=log)
        workers.append(process)
        return process

    def messages():
        return [json.loads(path.read_text()) for path in sorted(inbox.glob("*.json"))]

    def attempts():
        path = inbox / "attempts.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def accepted(count):
        return until(lambda: messages() if len(messages()) == count else False)

    def registration(session, agent):
        return dict(session_token=session["session_token"], agent_session_id=agent, executable=sys.executable,
                    arguments=[str(fixture), str(inbox), "{agent_session_id}", "{message}", "{delivery_id}"])

    try:
        app = start_app()
        a = client()
        first = a.tool("create_session", {"wake_up": {"mode": "manual"}, "client": "Generic agent", "conversation_label": "Delivery checks"})
        agent_id = "existing-agent-session ' ; $(ignored) {message}"
        config = registration(first, agent_id)
        a.tool("register_receiver", dict(config, executable="relative"), error="INVALID_RECEIVER")
        a.tool("register_receiver", dict(config, arguments=[1]), error="INVALID_RECEIVER")
        a.tool("register_receiver", dict(config, executable=str(root)), error="INVALID_RECEIVER")
        a.tool("get_receiver_status", {"session_token": "wrong"}, error="INVALID_SESSION")
        route = a.tool("register_receiver", config)
        assert a.tool("register_receiver", config)["receiver_id"] == route["receiver_id"]
        direct = subprocess.run([str(args.mcp.resolve()), "--call", "get_receiver_status"], input=json.dumps({"session_token": first["session_token"]}), env=env, text=True, capture_output=True, check=True)
        assert json.loads(direct.stdout)["receiver_id"] == route["receiver_id"]
        invalid = subprocess.run([str(args.mcp.resolve()), "--call", "get_receiver_status"], input='{"session_token":"wrong"}', env=env, text=True, capture_output=True)
        assert invalid.returncode == 1 and json.loads(invalid.stdout)["error"]["code"] == "INVALID_SESSION"
        print("PASS receiver validation and idempotent registration")
        path = root / "review.md"
        path.write_text("# Review\n\nAn editable paragraph.\n")
        opened = a.tool("open_document", {"path": str(path), "attach": True, "session_token": first["session_token"], "activate": False})
        ref = {"document_id": opened["document_id"]}
        auth = dict(session_token=first["session_token"], binding_id=opened["binding"]["binding_id"], generation=opened["binding"]["generation"])
        local("test_comment", **ref, quote="paragraph", body="PRIVATE PENDING FEEDBACK", pending=True)
        time.sleep(0.4)
        assert messages() == [] and attempts() == []
        a.close()  # The agent's turn and its MCP connection have both ended.
        local("test_submit_review", **ref, summary="Published review")
        delivered = accepted(1)[0]
        event = delivered["event"]
        assert event["type"] == "parchment.feedback_available" and event["protocol_version"] == 2
        assert event["agent_session_id"] == agent_id and event["session_id"] == first["session_id"]
        assert event["document_id"] == ref["document_id"] and event["binding_id"] == auth["binding_id"]
        assert delivered["args"] == [agent_id, event["message"], event["delivery_id"]]
        assert event["message"].startswith("🤖")
        assert first["session_token"] not in json.dumps(delivered)
        assert "PRIVATE PENDING FEEDBACK" not in json.dumps(delivered)
        print("PASS submitted review notifies the owning agent without an active MCP connection; pending drafts stay private")
        a = client()
        a.tool("resume_session", {"session_token": first["session_token"]})
        status_args = {"session_token": first["session_token"]}
        until(lambda: a.tool("get_receiver_status", status_args)["accepted_notifications"] == 1)
        a.tool("acknowledge_feedback", dict(auth, cursor=event["cursor"]), error="INVALID_CURSOR")
        feedback = a.tool("get_feedback", auth)
        assert len(feedback["events"]) == 1 and feedback["acknowledged_cursor"] == 0
        assert feedback["events"][0]["event_id"] == event["event_id"]
        a.tool("acknowledge_feedback", dict(auth, cursor=feedback["next_cursor"]))
        print("PASS notification acceptance never acknowledges or skips agent feedback")

        mode.write_text("reject")
        local("test_comment", **ref, quote="paragraph", body="Retry delivery", pending=False)
        until(lambda: a.tool("get_receiver_status", status_args)["last_error"])
        assert len(messages()) == 1
        failed_attempt = attempts()[-1]
        stop(app); app = None
        mode.write_text("accept")
        worker = start_worker()
        accepted(2)
        retried = next(item for item in messages() if item["event"]["delivery_id"] == failed_attempt["args"][2])
        assert retried["event"]["agent_session_id"] == agent_id
        until(lambda: a.tool("get_receiver_status", status_args)["accepted_notifications"] == 1)
        app = start_app()
        time.sleep(0.4)
        assert len(messages()) == 2
        print("PASS rejected delivery survives app restart and retries with a stable ID through the standalone worker")

        count = len(attempts())
        local("test_comment", **ref, quote="paragraph", body="Two workers, one delivery", pending=False)
        accepted(3)
        until(lambda: a.tool("get_receiver_status", status_args)["accepted_notifications"] == 2)
        time.sleep(0.4)
        assert len(attempts()) == count + 1
        stop(app); app = None
        stop(worker)
        # Crash window: the receiver accepted, but the dispatcher did not commit its receipt.
        replay = max(messages(), key=lambda item: item["event"]["cursor"])["event"]
        with sqlite3.connect(state / "integration.sqlite") as database:
            database.execute("UPDATE event_wakeups SET accepted_at=NULL,lease_id='crashed',lease_until=? WHERE delivery_id=?", (time.time() - 1, replay["delivery_id"]))
        worker = start_worker()
        until(lambda: len(attempts()) == count + 2)
        until(lambda: a.tool("get_receiver_status", status_args)["accepted_notifications"] == 2)
        assert len(messages()) == 3
        print("PASS concurrent workers respect leases; a crash replays the same ID and the receiver deduplicates acceptance")
        feedback = a.tool("get_feedback", auth)
        a.tool("acknowledge_feedback", dict(auth, cursor=feedback["next_cursor"]))
        stop(worker)
        app = start_app()

        b = client()
        second = b.tool("create_session", {"wake_up": {"mode": "manual"}, "client": "Other framework", "conversation_label": "Receiving agent"})
        second_config = registration(second, "other-agent-session")
        b.tool("register_receiver", second_config)
        mode.write_text("reject")
        local("test_comment", **ref, quote="paragraph", body="Transfer this feedback", pending=False)
        until(lambda: a.tool("get_receiver_status", status_args)["last_error"])
        old_attempts = sum(item["args"][0] == agent_id for item in attempts())
        a.tool("handoff_document", dict(auth, target_session_id=second["session_id"]))
        mode.write_text("accept")
        accepted(4)
        handoff = next(item["event"] for item in messages() if item["event"]["agent_session_id"] == "other-agent-session")
        assert handoff["generation"] == auth["generation"] + 1
        a.tool("get_feedback", auth, error="STALE_BINDING")
        attached = b.tool("attach_document", dict(ref, session_token=second["session_token"]))
        second_auth = dict(session_token=second["session_token"], binding_id=attached["binding_id"], generation=attached["generation"])
        time.sleep(2.2)
        assert sum(item["args"][0] == agent_id for item in attempts()) == old_attempts
        feedback = b.tool("get_feedback", second_auth)
        b.tool("acknowledge_feedback", dict(second_auth, cursor=feedback["next_cursor"]))
        print("PASS handoff routes outstanding feedback to the receiving agent and cancels the old owner's retries")

        second_status = {"session_token": second["session_token"]}
        mode.write_text("reject")
        local("test_comment", **ref, quote="paragraph", body="Detach before retry", pending=False)
        until(lambda: b.tool("get_receiver_status", second_status)["last_error"])
        b.tool("detach_document", second_auth)
        count = len(attempts())
        mode.write_text("accept")
        time.sleep(2.3)
        assert len(attempts()) == count and len(messages()) == 4
        attached = b.tool("attach_document", dict(ref, session_token=second["session_token"]))
        second_auth.update(binding_id=attached["binding_id"], generation=attached["generation"])
        accepted(5)
        feedback = b.tool("get_feedback", second_auth)
        b.tool("acknowledge_feedback", dict(second_auth, cursor=feedback["next_cursor"]))
        print("PASS detachment stops delivery; reattachment preserves and redelivers unhandled feedback")

        mode.write_text("reject")
        local("test_comment", **ref, quote="paragraph", body="Disable the receiver", pending=False)
        until(lambda: b.tool("get_receiver_status", second_status)["last_error"])
        b.tool("unregister_receiver", second_status)
        assert b.tool("get_receiver_status", second_status)["mode"] == "manual"
        count = len(attempts())
        mode.write_text("accept")
        time.sleep(2.3)
        assert len(attempts()) == count and len(messages()) == 5
        assert b.tool("get_feedback", second_auth)["events"]
        b.tool("register_receiver", second_config)
        accepted(6)
        feedback = b.tool("get_feedback", second_auth)
        b.tool("acknowledge_feedback", dict(second_auth, cursor=feedback["next_cursor"]))
        print("PASS unregistering stops automatic delivery without releasing ownership or losing feedback")

        mode.write_text("hang")
        local("test_comment", **ref, quote="paragraph", body="Bounded receiver timeout", pending=False)
        until(lambda: b.tool("get_receiver_status", second_status)["last_error"], timeout=14)
        status = b.tool("get_receiver_status", second_status)
        assert "RECEIVER_TIMEOUT" in status["last_error"], status
        pid = attempts()[-1]["pid"]
        def exited():
            try:
                os.kill(pid, 0)
                return False
            except ProcessLookupError:
                return True
        until(exited)
        b.tool("unregister_receiver", second_status)
        print("PASS a stalled receiver is forcibly stopped and leaves feedback queued for retry")
        # A tab can request attachment before any document binding or feedback exists.
        b.tool("register_receiver", second_config)
        attach_path = root / "attach-from-tab.md"
        attach_path.write_text("# Attach me\n")
        attach_doc = b.tool("open_document", {"path": str(attach_path), "activate": False})
        attach_ref = {"document_id": attach_doc["document_id"]}
        mode.write_text("reject")
        request = local("test_request_attachment", **attach_ref, session_id=second["session_id"])
        repeat = local("test_request_attachment", **attach_ref, session_id=second["session_id"])
        assert request["request_id"] == repeat["request_id"]
        # Wait for this request's rejection, not an older feedback delivery error.
        until(lambda: local("test_request_attachment", **attach_ref, session_id=second["session_id"])["last_error"])
        stop(app); app = None
        mode.write_text("accept")
        worker = start_worker()
        requested = until(lambda: next((item["event"] for item in messages() if item["event"]["attachment_request_id"] == request["request_id"]), None))
        assert requested["document_id"] == attach_doc["document_id"] and requested["session_id"] == second["session_id"]
        assert requested["attachment_request_id"] == request["request_id"] and requested["binding_id"] is None
        assert requested["cursor"] is None and second["session_token"] not in json.dumps(requested)
        assert requested["message"].startswith("🤖")
        app = start_app()
        b.tool("attach_document", dict(attach_ref, session_token=first["session_token"], attachment_request_id=request["request_id"]), error="STALE_ATTACHMENT_REQUEST")
        bound = b.tool("attach_document", dict(attach_ref, session_token=second["session_token"], attachment_request_id=request["request_id"]))
        attach_auth = dict(session_token=second["session_token"], binding_id=bound["binding_id"], generation=bound["generation"])
        assert b.tool("get_feedback", attach_auth)["events"] == []
        assert local("test_request_attachment", **attach_ref, session_id=second["session_id"])["status"] == "attached"
        metadata_receiver_id = b.tool("get_receiver_status", second_status)["receiver_id"]
        renamed = b.tool("update_session", dict(second_status, conversation_label="Live renamed session", model="New model"))
        assert renamed["session_id"] == second["session_id"]
        assert b.tool("get_receiver_status", second_status)["receiver_id"] == metadata_receiver_id
        assert b.tool("register_receiver", second_config)["receiver_id"] == metadata_receiver_id
        print("PASS tab attachment requests retry after restart, deduplicate, preserve credentials, and attach without fake feedback")
        # Explicit transfer keeps the owner until acceptance, then invalidates its credentials.
        a.tool("register_receiver", config)
        local("test_comment", **attach_ref, quote="Attach", body="Feedback follows the transfer", pending=False)
        local("test_request_attachment", **attach_ref, session_id=first["session_id"], expected_error="DOCUMENT_ALREADY_ATTACHED")
        transfer = local("test_request_attachment", **attach_ref, session_id=first["session_id"], transfer=True)
        assert b.tool("get_document", attach_ref)["attachment"]["session_id"] == second["session_id"]
        assert b.tool("attach_document", dict(attach_ref, session_token=second["session_token"]))["binding_id"] == bound["binding_id"]
        accepted_transfer = until(lambda: next((item for item in messages() if item["event"]["attachment_request_id"] == transfer["request_id"]), None))
        assert accepted_transfer["event"]["agent_session_id"] == agent_id
        moved = a.tool("attach_document", dict(attach_ref, session_token=first["session_token"], attachment_request_id=transfer["request_id"]))
        assert moved["generation"] == bound["generation"] + 1 and moved["binding_id"] != bound["binding_id"]
        b.tool("get_feedback", attach_auth, error="STALE_BINDING")
        transfer_auth = dict(session_token=first["session_token"], binding_id=moved["binding_id"], generation=moved["generation"])
        assert a.tool("get_feedback", transfer_auth)["events"]
        assert a.tool("attach_document", dict(attach_ref, session_token=first["session_token"], attachment_request_id=transfer["request_id"]))["binding_id"] == moved["binding_id"]
        print("PASS confirmed tab transfer keeps the owner until acceptance, preserves feedback, and rejects stale bindings")

        # Cancelling a queued request makes a delayed agent notification harmless.
        cancelled = local("test_request_attachment", **attach_ref, session_id=second["session_id"], transfer=True)
        local("test_cancel_attachment", **attach_ref, session_id=second["session_id"])
        b.tool("attach_document", dict(attach_ref, session_token=second["session_token"], attachment_request_id=cancelled["request_id"]), error="STALE_ATTACHMENT_REQUEST")
        retry = local("test_request_attachment", **attach_ref, session_id=second["session_id"], transfer=True)
        assert retry["request_id"] != cancelled["request_id"]
        a.tool("detach_document", transfer_auth)
        b.tool("attach_document", dict(attach_ref, session_token=second["session_token"], attachment_request_id=retry["request_id"]), error="STALE_ATTACHMENT_REQUEST")
        fresh = local("test_request_attachment", **attach_ref, session_id=second["session_id"])
        assert fresh["request_id"] != retry["request_id"]
        b.tool("attach_document", dict(attach_ref, session_token=second["session_token"], attachment_request_id=fresh["request_id"]))
        unknown = a.tool("create_session", {"wake_up": {"mode": "manual"}, "client": "Offline framework", "conversation_label": "No receiver"})
        local("test_request_attachment", **attach_ref, session_id=unknown["session_id"], transfer=True)
        local("test_request_attachment", **attach_ref, session_id="missing", transfer=True, expected_error="SESSION_NOT_FOUND")
        print("PASS cancelled or outdated requests cannot steal ownership; new requests and missing receivers are handled")
        toggle_path = root / "session-toggle.md"
        toggle_path.write_text("# Toggle attachment\n")
        toggle_doc = a.tool("open_document", {"path": str(toggle_path), "activate": False})
        toggle_ref = {"document_id": toggle_doc["document_id"]}
        state = local("test_set_session", **toggle_ref, session_id=first["session_id"], attached=True)
        assert state["attachment"]["status"] == "unattached" and len(state["requests"]) == 1
        cancelled_id = state["requests"][0]["request_id"]
        state = local("test_set_session", **toggle_ref, session_id=first["session_id"], attached=True)
        assert state["requests"] == [] and state["attachment"]["status"] == "unattached"
        a.tool("attach_document", dict(toggle_ref, session_token=first["session_token"], attachment_request_id=cancelled_id), error="STALE_ATTACHMENT_REQUEST")
        state = local("test_set_session", **toggle_ref, session_id=first["session_id"], attached=True)
        on = a.tool("attach_document", dict(toggle_ref, session_token=first["session_token"], attachment_request_id=state["requests"][0]["request_id"]))
        a.tool("unregister_receiver", {"session_token": first["session_token"]})
        state = local("test_set_session", **toggle_ref, session_id=first["session_id"], attached=False)
        assert state["attachment"]["status"] == "unattached"
        a.tool("get_feedback", dict(session_token=first["session_token"], binding_id=on["binding_id"], generation=on["generation"]), error="STALE_BINDING")
        b.tool("attach_document", dict(toggle_ref, session_token=second["session_token"]))
        state = local("test_set_session", **toggle_ref, session_id=first["session_id"], attached=False)
        assert state["attachment"]["session_id"] == second["session_id"]
        state = local("test_set_session", **toggle_ref, session_id=second["session_id"], attached=False)
        assert state["attachment"]["status"] == "unattached"
        assert any(item["session_id"] == first["session_id"] for item in a.tool("list_sessions")["sessions"])
        print("PASS session menu toggles request, cancel, and detach; stale toggles preserve another owner and offline owners remain detachable")
        print("All agent delivery checks passed.")
    except Exception:
        log.flush(); log.seek(0); print(log.read())
        raise
    finally:
        stop(app)
        for worker in workers:
            stop(worker)
        for value in clients:
            if value.process.poll() is None:
                value.close()
        log.close()
        if socket_root.exists():
            shutil.rmtree(socket_root)
