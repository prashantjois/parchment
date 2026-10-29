#!/usr/bin/env python3
"""Check atomic session setup and the shared, authenticated agent event inbox."""
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

MCP = runpy.run_path(str(Path(__file__).with_name('check-integration.py')))['MCP']
parser = argparse.ArgumentParser()
parser.add_argument('--app', type=Path, default=Path('.build/release/Parchment'))
parser.add_argument('--mcp', type=Path, default=Path('.build/release/ParchmentMCP'))
options = parser.parse_args()


def until(predicate, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.05)
    raise AssertionError('Timed out waiting for event bus')


with tempfile.TemporaryDirectory(prefix='parchment-bus-') as temporary:
    root = Path(temporary)
    state, inbox = root / 'state', root / 'notifications'
    inbox.mkdir()
    env = dict(os.environ, PARCHMENT_DATA_DIR=str(state))
    socket_root = Path(f'/tmp/parchment-{os.getuid()}-{hashlib.sha256(str(state).encode()).hexdigest()[:16]}')
    log = open(root / 'app.log', 'w+')
    clients, workers = [], []
    app = None
    fixture = root / 'receiver.py'
    fixture.write_text('import json,pathlib,sys\nevent=json.load(sys.stdin)\npathlib.Path(sys.argv[1],event["delivery_id"]+".json").write_text(json.dumps(event))\n')

    def client(environment=env):
        value = MCP(options.mcp.resolve(), environment)
        clients.append(value)
        return value

    def local(method, **params):
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(10)
            connection.connect(str(socket_root / 'app.sock'))
            connection.sendall((json.dumps(dict(method=method, params=params))+'\n').encode())
            with connection.makefile('r') as stream:
                response = json.loads(stream.readline())
        assert response['ok'], response
        return response['result']

    def start_app():
        process = subprocess.Popen([str(options.app.resolve()), '--integration-test-server', str(state)], env=env, stdout=log, stderr=log)
        def ready():
            assert process.poll() is None, 'App exited'
            try:
                return local('ping')
            except OSError:
                return False
        until(ready)
        return process

    def stop(process):
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait(timeout=3)

    def command(agent):
        return dict(mode='command', agent_session_id=agent, executable=sys.executable, arguments=[str(fixture), str(inbox)])

    def notification(event_id):
        return next((json.loads(p.read_text()) for p in inbox.glob('*.json') if json.loads(p.read_text())['bus_event_id'] == event_id), None)

    try:
        app = start_app()
        a, b = client(), client()
        count = len(a.tool('list_sessions')['sessions'])
        a.tool('create_session', dict(client='Agent', conversation_label='Missing wake-up'), error='INVALID_ARGUMENT')
        a.tool('create_session', dict(client='Agent', conversation_label='Bad command', wake_up=dict(command('bad'), executable='relative')), error='INVALID_RECEIVER')
        assert len(a.tool('list_sessions')['sessions']) == count
        first = a.tool('create_session', dict(client='Agent', conversation_label='Ready immediately', model='Known model', wake_up=command('existing-thread')))
        assert first['wake_up_mode'] == 'command' and first['delivery']['registered']
        assert a.tool('get_receiver_status', dict(session_token=first['session_token']))['receiver_id'] == first['delivery']['receiver_id']
        manual = b.tool('create_session', dict(client='Other host', conversation_label='Manual inbox', wake_up={'mode':'manual'}))
        assert manual['wake_up_mode'] == 'manual' and not manual['delivery']['registered']
        print('PASS one-call registration validates wake-up configuration and never leaves a failed registration behind', flush=True)

        path = root / 'queued.md'
        path.write_text('# Queued document\n\nA paragraph.\n')
        opened = a.tool('open_document', dict(path=str(path), activate=False))
        ref = dict(document_id=opened['document_id'])
        request = local('test_request_attachment', **ref, session_id=manual['session_id'])
        manual_auth = dict(session_token=manual['session_token'])
        automatic_auth = dict(session_token=first['session_token'])
        b.tool('acknowledge_events', dict(manual_auth, event_ids=[request['bus_event_id']]), error='EVENT_NOT_READ')
        assert a.tool('get_events', automatic_auth)['events'] == []
        pending = b.tool('get_events', manual_auth)['events']
        assert len(pending) == 1 and pending[0]['type'] == 'parchment.attachment_requested'
        assert pending[0]['attachment_request_id'] == request['request_id']
        assert manual['session_token'] not in json.dumps(pending)
        a.tool('acknowledge_events', dict(automatic_auth, event_ids=[request['bus_event_id']]), error='EVENT_NOT_FOUND')
        b.tool('acknowledge_events', dict(manual_auth, event_ids=[request['bus_event_id']]), error='EVENT_NOT_HANDLED')
        stop(app); app = start_app()
        assert b.tool('get_events', manual_auth)['events'][0]['bus_event_id'] == request['bus_event_id']
        repaired = b.tool('update_session', dict(manual_auth, wake_up=command('manual-now-automatic')))
        assert repaired['session_id'] == manual['session_id'] and repaired['delivery']['registered']
        delivered = until(lambda: notification(request['bus_event_id']))
        assert delivered['attachment_request_id'] == request['request_id']
        assert delivered['agent_session_id'] == 'manual-now-automatic' and delivered['session_id'] == manual['session_id']
        bound = b.tool('attach_document', dict(ref, **manual_auth, attachment_request_id=request['request_id']))
        assert b.tool('get_events', manual_auth)['events'] == []
        b.tool('acknowledge_events', dict(manual_auth, event_ids=[request['bus_event_id']]))
        print('PASS receiverless attachment requests survive restart, remain isolated, and wake through the common bus after configuration', flush=True)

        auth = dict(manual_auth, binding_id=bound['binding_id'], generation=bound['generation'])
        local('test_comment', **ref, quote='paragraph', body='PRIVATE DRAFT', pending=True)
        assert b.tool('get_events', manual_auth)['events'] == []
        local('test_submit_review', **ref, summary='Published review')
        events = b.tool('get_events', manual_auth)['events']
        assert len(events) == 1 and events[0]['type'] == 'parchment.feedback_available'
        event = events[0]
        until(lambda: notification(event['bus_event_id']))
        assert 'PRIVATE DRAFT' not in json.dumps(event)
        b.tool('acknowledge_feedback', dict(auth, cursor=event['feedback_cursor']), error='INVALID_CURSOR')
        b.tool('acknowledge_events', dict(manual_auth, event_ids=[event['bus_event_id']]), error='EVENT_NOT_HANDLED')
        feedback = b.tool('get_feedback', auth)
        assert len(feedback['events']) == 1 and feedback['events'][0]['event_id'] == event['event_id']
        b.tool('acknowledge_feedback', dict(auth, cursor=feedback['next_cursor']))
        b.tool('acknowledge_events', dict(manual_auth, event_ids=[event['bus_event_id']]))
        assert b.tool('get_events', manual_auth)['events'] == []
        assert a.tool('get_events', automatic_auth)['events'] == []
        print('PASS reviews and attachments share one bus and wake-up path; inbox reads never publish drafts or acknowledge feedback', flush=True)

        # A delayed notification must not reclaim a file after a user detaches it.
        local('test_comment', **ref, quote='paragraph', body='Stale feedback', pending=False)
        stale = b.tool('get_events', manual_auth)['events'][0]
        local('test_set_session', **ref, session_id=manual['session_id'], attached=False)
        assert b.tool('get_events', manual_auth)['events'] == []
        b.tool('get_feedback', auth, error='STALE_BINDING')
        b.tool('acknowledge_events', dict(manual_auth, event_ids=[stale['bus_event_id']]))
        assert b.tool('get_document', ref)['attachment']['status'] == 'unattached'
        waiting = b.begin('tools/call', dict(name='wait_for_events', arguments=dict(manual_auth, timeout_seconds=5)))
        local('test_request_attachment', **ref, session_id=manual['session_id'])
        response = b.receive(waiting)
        assert not response['result'].get('isError') and json.loads(response['result']['content'][0]['text'])['events']
        local('test_cancel_attachment', **ref, session_id=manual['session_id'])
        waiting = b.begin('tools/call', dict(name='wait_for_events', arguments=dict(manual_auth, timeout_seconds=25)))
        b.send(dict(jsonrpc='2.0', method='notifications/cancelled', params={'requestId':waiting}))
        assert b.receive(waiting)['result']['isError']
        before = b.tool('resume_session', manual_auth)
        b.tool('update_session', dict(manual_auth, conversation_label='Must roll back', wake_up=dict(command('bad'), executable='relative')), error='INVALID_RECEIVER')
        assert b.tool('resume_session', manual_auth)['conversation_label'] == before['conversation_label']
        print('PASS stale events cannot reclaim ownership, session-wide waits wake for new files, and failed updates preserve metadata', flush=True)
        print('All event bus checks passed.', flush=True)
    except Exception:
        log.flush(); log.seek(0); print(log.read())
        raise
    finally:
        stop(app)
        for process in workers: stop(process)
        for value in clients:
            if value.process.poll() is None: value.close()
        log.close()
        if socket_root.exists(): shutil.rmtree(socket_root)
