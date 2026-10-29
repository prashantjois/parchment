#!/usr/bin/env python3
"""Upgrade a version-two registry with accepted deliveries and an expired retry."""
import argparse
import json
import os
from pathlib import Path
import runpy
import sqlite3
import subprocess
import sys
import tempfile
import time

MCP = runpy.run_path(str(Path(__file__).with_name('check-integration.py')))['MCP']
parser=argparse.ArgumentParser()
parser.add_argument('--mcp', type=Path, default=Path('.build/release/ParchmentMCP'))
options=parser.parse_args()
with tempfile.TemporaryDirectory(prefix='parchment-bus-migration-') as temporary:
    root=Path(temporary)
    state=root/'state'; inbox=root/'inbox'; inbox.mkdir()
    env=dict(os.environ,PARCHMENT_DATA_DIR=str(state))
    helper=MCP(options.mcp.resolve(),env)
    session=helper.tool('create_session',dict(client='Legacy host',conversation_label='Preserved conversation',wake_up={'mode':'manual'}))
    helper.close()
    fixture=root/'receiver.py'
    fixture.write_text('import json,pathlib,sys\ne=json.load(sys.stdin)\npathlib.Path(sys.argv[1],e["delivery_id"]+".json").write_text(json.dumps(e))\n')
    token=session['session_token']; sid=session['session_id']
    with sqlite3.connect(state/'integration.sqlite') as db:
        for document in ['old-feedback','old-request','old-retry']:
            db.execute('INSERT INTO documents(id,path,identity,title,updated) VALUES(?,NULL,NULL,?,?)',(document,document,time.time()))
        for document,binding in [('old-feedback','old-binding'),('old-retry','retry-binding')]:
            db.execute('INSERT INTO bindings(document_id,binding_id,session_id,generation,last_activity) VALUES(?,?,?,1,?)',(document,binding,sid,time.time()))
        for document,event in [('old-feedback','old-comment'),('old-retry','retry-comment')]:
            db.execute('INSERT INTO feedback(event_id,document_id,payload,created) VALUES(?,?,?,?)',(event,document,'{"kind":"comment_published"}',time.time()))
        db.execute('INSERT INTO receivers VALUES(?,?,?,?,?)',(sid,'legacy-receiver','existing-runtime',sys.executable,json.dumps([str(fixture),str(inbox)])))
        db.execute('INSERT INTO notifications(delivery_id,receiver_id,document_id,binding_id,generation,sequence,attempts,accepted_at) VALUES(?,?,?, ?,1,1,2,?)',('legacy-accepted','legacy-receiver','old-feedback','old-binding',time.time()))
        db.execute('INSERT INTO notifications(delivery_id,receiver_id,document_id,binding_id,generation,sequence,attempts,lease_id,lease_until,last_error) VALUES(?,?,?, ?,1,2,3,?,?,?)',('legacy-retry','legacy-receiver','old-retry','retry-binding','expired-lease',time.time()-1,'RECEIVER_REJECTED'))
        db.execute('INSERT INTO attachment_requests(request_id,document_id,session_id,created,accepted_at,attempts) VALUES(?,?,?,?,?,2)',('old-request-id','old-request',sid,time.time(),time.time()))
        # Remove only the new schema from this isolated fixture to reproduce 0.1.32.
        db.execute('DROP TABLE event_wakeups');db.execute('DROP TABLE session_events')
        db.execute('ALTER TABLE sessions DROP COLUMN wake_up_mode')
        db.execute('PRAGMA user_version=2')
    helper=MCP(options.mcp.resolve(),env)
    worker=None
    try:
        auth=dict(session_token=token)
        resumed=helper.tool('resume_session',auth)
        assert resumed['session_id']==sid and resumed['wake_up_mode']=='command'
        events=helper.tool('get_events',auth)['events']
        assert len(events)==3 and {e['type'] for e in events}=={'parchment.feedback_available','parchment.attachment_requested'}
        status=helper.tool('get_receiver_status',auth)
        assert status['receiver_id']=='legacy-receiver' and status['accepted_notifications']==2
        worker=subprocess.Popen([str(options.mcp.resolve()),'--dispatch-events'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        deadline=time.monotonic()+8
        while not (inbox/'legacy-retry.json').exists() and time.monotonic()<deadline:time.sleep(.05)
        assert (inbox/'legacy-retry.json').exists()
        time.sleep(.3)
        assert len(list(inbox.glob('*.json')))==1, 'Previously accepted notifications must not be resent'
        retried=json.loads((inbox/'legacy-retry.json').read_text())
        assert retried['delivery_id']=='legacy-retry' and retried['session_id']==sid
        args=dict(auth,binding_id='old-binding',generation=1)
        feedback=helper.tool('get_feedback',args)
        assert feedback['events'][0]['event_id']=='old-comment'
        helper.tool('acknowledge_feedback',dict(args,cursor=feedback['next_cursor']))
        remaining=helper.tool('get_events',auth)['events']
        assert len(remaining)==2 and any(e['attachment_request_id']=='old-request-id' for e in remaining)
        with sqlite3.connect(state/'integration.sqlite') as db:
            assert db.execute('PRAGMA user_version').fetchone()[0]==3
        print('PASS version-two migration preserves tokens, bindings, accepted wake-ups, pending requests, and retry IDs')
    finally:
        if worker:
            worker.terminate();worker.wait(timeout=5)
        helper.close()
