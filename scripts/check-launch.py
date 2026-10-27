#!/usr/bin/env python3
"""Verify URL dispatch and MCP access against an isolated GUI instance."""
import hashlib
import json
import os
from pathlib import Path
import runpy
import shutil
import signal
import socket
import subprocess
import tempfile
import time
from urllib.parse import urlencode, quote, urlparse, parse_qs

MCP = runpy.run_path(str(Path(__file__).with_name("check-integration.py")))["MCP"]
app = Path(__file__).resolve().parent.parent / "dist/Parchment.app"
with tempfile.TemporaryDirectory(prefix="parchment-launch-") as temporary:
    root = Path(temporary)
    state = root / "state"
    env = dict(os.environ, PARCHMENT_DATA_DIR=str(state))
    socket_root = Path(f"/tmp/parchment-{os.getuid()}-{hashlib.sha256(str(state).encode()).hexdigest()[:16]}")
    helper = MCP(app / "Contents/MacOS/ParchmentMCP", env)
    pid = None
    try:
        document = root / "Agent café + & # % (draft).md"
        document.write_text("# Created by an agent\n\nReady for comments.\n")
        link = "parchment://open?" + urlencode({"path": str(document), "line": 3}, quote_via=quote)
        launch = subprocess.run(["swift", str(Path(__file__).with_name("check-links.swift")), str(app), str(state), link], check=True, text=True, capture_output=True, timeout=30)
        pid = int(launch.stdout.strip())
        def matches_document(item):
            return item["path"] is not None and os.path.samefile(item["path"], document)
        for _ in range(100):
            listing = helper.tool("list_documents")
            if any(matches_document(item) for item in listing["documents"]):
                break
            time.sleep(0.1)
        else:
            raise AssertionError(f"URL dispatch did not open {document}; live paths: {[item['path'] for item in listing['documents']]}")
        opened_by_link = next(item for item in listing["documents"] if matches_document(item))
        assert listing["active_document_id"] == opened_by_link["document_id"]
        assert opened_by_link["attachment"]["status"] == "unattached"
        assert os.path.samefile(parse_qs(urlparse(opened_by_link["open_url"]).query)["path"][0], document)
        print("PASS registered parchment link launches the app and opens an encoded path without attaching an agent")
        session = helper.tool("create_session", {"client": "Launch check", "conversation_label": "Isolated launch"})
        opened = helper.tool("open_document", {"path": str(document), "attach": True, "session_token": session["session_token"], "activate": False})
        pid = helper.tool("open_app", {"activate": False})["pid"]
        assert helper.tool("get_document", {"document_id": opened["document_id"]})["text"] == document.read_text()
        listed = helper.tool("list_documents")["documents"]
        assert any(item["document_id"] == opened["document_id"] for item in listed)
        assert sum(matches_document(item) for item in listed) == 1
        assert helper.tool("open_app", {"activate": False})["pid"] == pid
        second = root / "opened-from-another-copy.md"
        second.write_text("# Forwarded document\n")
        second_link = "parchment://open?" + urlencode({"path": str(second)}, quote_via=quote)
        relay = subprocess.run(["swift", str(Path(__file__).with_name("check-links.swift")), str(app), str(state), second_link], check=True, text=True, capture_output=True, timeout=30)
        relay_pid = int(relay.stdout.strip())
        assert relay_pid != pid
        for _ in range(100):
            listing = helper.tool("list_documents")
            if any(item["path"] and os.path.samefile(item["path"], second) for item in listing["documents"]):
                break
            time.sleep(0.1)
        else:
            raise AssertionError("Second app did not forward its URL to the original owner")
        assert helper.tool("open_app", {"activate": False})["pid"] == pid
        for _ in range(50):
            try:
                os.kill(relay_pid, 0)
                time.sleep(0.1)
            except ProcessLookupError:
                break
        else:
            raise AssertionError("The second app stayed running")
        print("PASS second app forwards URLs and exits without taking API ownership")
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(5)
            connection.connect(str(socket_root / "app.sock"))
            connection.sendall(b'{"method":"test_shutdown","params":{}}\n')
            with connection.makefile("r") as stream:
                response = json.loads(stream.readline())
            assert not response["ok"] and response["error"]["code"] == "METHOD_NOT_FOUND"
        print("PASS MCP attaches the URL-opened file and reuses the app without duplicate tabs")
        print("PASS normal app rejects test-only API methods")
        subprocess.run(["swift", str(Path(__file__).with_name("check-quit.swift")), str(pid)], check=True, timeout=20)
        pid = None
        assert not (socket_root / "app.sock").exists(), "Quit must remove the API socket"
        helper.tool("list_documents", error="APP_UNAVAILABLE")
        pid = helper.tool("open_app", {"activate": False})["pid"]
        assert helper.tool("list_documents")["documents"]
        print("PASS quit removes the API and releases ownership so the app can restart")
    finally:
        if pid is not None:
            os.kill(pid, signal.SIGTERM)
            for _ in range(50):
                try:
                    os.kill(pid, 0)
                    time.sleep(0.1)
                except ProcessLookupError:
                    break
        helper.close()
        if socket_root.exists():
            shutil.rmtree(socket_root)
