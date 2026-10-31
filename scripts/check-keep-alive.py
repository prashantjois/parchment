#!/usr/bin/env python3
"""Check real MCP heartbeats, expiry, and recovery with an isolated registry."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import runpy
import socket
import sqlite3
import subprocess
import tempfile
import time

MCP = runpy.run_path(str(Path(__file__).with_name("check-integration.py")))["MCP"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, default=Path(".build/debug/Parchment"))
    parser.add_argument("--mcp", type=Path, default=Path(".build/debug/ParchmentMCP"))
    options = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="parchment-heartbeats-") as temporary:
        root = Path(temporary)
        state = root / "state"
        env = dict(os.environ, PARCHMENT_DATA_DIR=str(state))
        executable = options.mcp.resolve()
        clients = []
        app = None
        socket_root = Path(f"/tmp/parchment-{os.getuid()}-{hashlib.sha256(str(state).encode()).hexdigest()[:16]}")

        def local(method, error=None, **params):
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(10)
                connection.connect(str(socket_root / "app.sock"))
                connection.sendall((json.dumps(dict(method=method, params=params)) + "\n").encode())
                with connection.makefile("r") as stream:
                    response = json.loads(stream.readline())
            if error:
                assert not response["ok"] and response["error"]["code"] == error, response
                return response["error"]
            assert response["ok"], response
            return response["result"]

        def one_shot(name, arguments):
            result = subprocess.run([str(executable), "--call", name], input=json.dumps(arguments),
                                    text=True, capture_output=True, env=env, timeout=10)
            assert result.returncode == 0, result.stderr
            value = json.loads(result.stdout)
            assert "error" not in value, value
            return value

        def until(predicate, timeout=15):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                value = predicate()
                if value:
                    return value
                time.sleep(.1)
            raise AssertionError("Timed out waiting for session presence")

        def client():
            value = MCP(executable, env)
            clients.append(value)
            return value

        with open(root / "app.log", "w+") as log:
            try:
                owner, observer = client(), client()
                owner.tool("keep_alive", {"session_token": "invalid"}, error="INVALID_SESSION")
                session = owner.tool("create_session", dict(client="Checks", conversation_label="Connected", wake_up={"mode": "manual"}))
                auth = dict(session_token=session["session_token"])
                inactive = one_shot("create_session", dict(client="Checks", conversation_label="One shot", wake_up={"mode": "manual"}))
                inactive_auth = dict(session_token=inactive["session_token"])
                app = subprocess.Popen([str(options.app.resolve()), "--integration-test-server", str(state)],
                                       env=env, stdout=log, stderr=log)
                def ready():
                    assert app.poll() is None, "Headless app exited"
                    try:
                        return local("ping")
                    except OSError:
                        return False
                until(ready)
                path = root / "owned.md"
                path.write_text("# Owned\n\nKeep this paragraph.\n")
                opened = owner.tool("open_document", dict(auth, path=str(path), attach=True, activate=False))
                binding = dict(auth, binding_id=opened["binding"]["binding_id"], generation=opened["binding"]["generation"])
                ref = dict(document_id=opened["document_id"])
                started = session["last_keep_alive"]
                # No further tool traffic on the owner connection while its timer runs.
                until(lambda: time.time() - started > 11.5)
                listed = observer.tool("list_sessions")["sessions"]
                live = next(item for item in listed if item["session_id"] == session["session_id"])
                assert live["last_keep_alive"] - started >= 9
                assert all(item["session_id"] != inactive["session_id"] for item in listed)
                assert "session_token" not in json.dumps(listed) and "token_hash" not in json.dumps(listed)
                print("PASS idle MCP connections send keep-alives every 10 seconds; one-shot sessions expire", flush=True)
                owner.close()
                until(lambda: all(item["session_id"] != session["session_id"] for item in observer.tool("list_sessions")["sessions"]))
                local("test_comment", **ref, quote="paragraph", body="Feedback while offline", pending=False)
                assert observer.tool("get_document", ref)["attachment"]["session_id"] == session["session_id"]
                resumed = observer.tool("resume_session", auth)
                assert resumed["session_id"] == session["session_id"]
                assert any(item["session_id"] == session["session_id"] for item in observer.tool("list_sessions")["sessions"])
                feedback = observer.tool("get_feedback", binding)
                assert "Feedback while offline" in json.dumps(feedback["events"])
                print("PASS disconnect hides the session; reconnect restores the same ownership and queued feedback", flush=True)
                # Inspecting credentials and metadata must not renew a missing heartbeat.
                observer.tool("get_receiver_status", inactive_auth)
                assert all(item["session_id"] != inactive["session_id"] for item in observer.tool("list_sessions")["sessions"])
                local("test_request_attachment", **ref, session_id=inactive["session_id"], error="SESSION_NOT_FOUND")
                heartbeat = one_shot("keep_alive", inactive_auth)
                assert heartbeat["keep_alive_interval_seconds"] == 10
                assert heartbeat["expires_at"] - heartbeat["last_keep_alive"] == 11
                assert any(item["session_id"] == inactive["session_id"] for item in observer.tool("list_sessions")["sessions"])
                with sqlite3.connect(state / "integration.sqlite") as database:
                    database.execute("UPDATE sessions SET last_keep_alive=? WHERE id=?", (time.time() - 12, inactive["session_id"]))
                observer.tool("get_receiver_status", inactive_auth)
                assert all(item["session_id"] != inactive["session_id"] for item in observer.tool("list_sessions")["sessions"])
                print("PASS explicit keep-alives restore presence; unrelated authenticated reads do not", flush=True)
            except Exception:
                log.flush(); log.seek(0); print(log.read())
                raise
            finally:
                for value in clients:
                    value.close()
                if app and app.poll() is None:
                    app.terminate(); app.wait(timeout=5)


if __name__ == "__main__":
    main()
