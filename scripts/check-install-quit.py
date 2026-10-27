#!/usr/bin/env python3
"""Exercise the installer's actual quit code against isolated AppKit fixtures."""
import plistlib
from pathlib import Path
import subprocess
import tempfile
import time
import uuid

repository = Path(__file__).resolve().parent.parent
script = (repository / 'scripts/install.sh').read_text()
quit_code = script.split("<<'JXA'\n", 1)[1].split('\nJXA\n', 1)[0]


def request_quit(identifier):
    return subprocess.run(['/usr/bin/osascript', '-l', 'JavaScript', '-', identifier, '1'],
                          input=quit_code, text=True, capture_output=True, timeout=15)


with tempfile.TemporaryDirectory(prefix='parchment-install-quit-') as temporary:
    root = Path(temporary)
    identifier = 'local.parchment.quit-check.' + uuid.uuid4().hex
    absent = request_quit(identifier)
    assert absent.returncode == 0, absent.stderr
    print('PASS no running app does not launch one')

    app = root / 'QuitFixture.app'
    executable = app / 'Contents/MacOS/QuitFixture'
    executable.parent.mkdir(parents=True)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'QuitFixture',
        'CFBundleName': 'QuitFixture', 'CFBundlePackageType': 'APPL', 'LSUIElement': True,
    }))
    source = root / 'fixture.swift'
    source.write_text('''import AppKit
let mode = CommandLine.arguments[1]
let state = URL(fileURLWithPath: CommandLine.arguments[2])
final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        try! Data().write(to: state.appendingPathComponent("ready"))
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        try! Data().write(to: state.appendingPathComponent("requested"))
        if mode == "refuse" { return .terminateCancel }
        if mode == "delay" { return .terminateLater }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        try! Data("Recovered unsaved draft".utf8).write(to: state.appendingPathComponent("recovery"))
    }
}
let application = NSApplication.shared
let delegate = Delegate()
application.delegate = delegate
application.setActivationPolicy(.prohibited)
application.run()
''')
    subprocess.run(['xcrun', 'swiftc', str(source), '-o', str(executable)], check=True)
    for mode in ['accept', 'refuse', 'delay']:
        state = root / mode
        state.mkdir()
        process = subprocess.Popen([str(executable), mode, str(state)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 10
            while not (state / 'ready').exists():
                assert process.poll() is None, process.communicate()
                assert time.monotonic() < deadline, 'Fixture did not launch'
                time.sleep(0.05)
            result = request_quit(identifier)
            assert (state / 'requested').exists(), result.stderr
            if mode == 'accept':
                assert result.returncode == 0, result.stderr
                assert process.wait(timeout=5) == 0
                assert (state / 'recovery').read_text() == 'Recovered unsaved draft'
                print('PASS normal quit waits for AppKit termination and recovery writes')
            else:
                assert result.returncode != 0 and process.poll() is None, result.stderr
                assert not (state / 'recovery').exists()
                print('PASS ' + mode + ' stops installation and leaves the app running')
        finally:
            # Only the isolated fixture is terminated during cleanup.
            if process.poll() is None:
                process.terminate()
            process.communicate(timeout=5)
