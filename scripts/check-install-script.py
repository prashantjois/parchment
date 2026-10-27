#!/usr/bin/env python3
"""Exercise the install script against a real package without installing it."""
import hashlib
import itertools
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

script = Path(__file__).with_name('install.sh')
package = Path(sys.argv[1]).resolve()


def run(*arguments, defaults=True):
    options = ['--yes'] if defaults else []
    return subprocess.run(['bash', str(script), *arguments, *options],
                          stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)


def selected_choices(output):
    choices = plistlib.loads(output.encode())
    return {item['choiceIdentifier']: item['attributeSetting']
            for item in choices if item['choiceAttribute'] == 'selected'}


def interactive(answers, *options):
    terminal, input_fd = os.openpty()
    try:
        with subprocess.Popen(['bash', str(script), '--package', str(package), '--dry-run', *options],
                              stdin=input_fd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
            os.close(input_fd)
            input_fd = None
            os.write(terminal, answers.encode())
            output, errors = process.communicate(timeout=30)
            return process.returncode, output, errors
    finally:
        if input_fd is not None:
            os.close(input_fd)
        os.close(terminal)


for skill, scheme, default in itertools.product([0, 1], repeat=3):
    options = []
    if not skill:
        options.append('--skip-skill')
    if not scheme:
        options.append('--skip-register')
    if default:
        options.append('--markdown-default')
    result = run('--package', str(package), '--dry-run', *options)
    assert result.returncode == 0, result.stderr
    assert selected_choices(result.stdout) == {'parchment': 1, 'skill': skill, 'scheme': scheme, 'default': default}
print('PASS script defaults and all eight installer choices using the real package')

for skill, scheme, default in itertools.product([0, 1], repeat=3):
    answers = ''.join('yes\n' if enabled else 'no\n' for enabled in (skill, scheme, default))
    code, output, errors = interactive(answers)
    assert code == 0, errors
    assert selected_choices(output) == {'parchment': 1, 'skill': skill, 'scheme': scheme, 'default': default}
    assert all(question in errors for question in ['Install the Parchment agent skill',
                                                  'Register parchment://', 'Make Parchment the default'])
code, output, errors = interactive('\n\n\n')
assert code == 0 and selected_choices(output) == {'parchment': 1, 'skill': 1, 'scheme': 1, 'default': 0}
code, output, errors = interactive('maybe\nn\ny\n', '--skip-skill')
assert code == 0 and selected_choices(output) == {'parchment': 1, 'skill': 0, 'scheme': 0, 'default': 1}
assert 'Enter y or n.' in errors and 'Install the Parchment agent skill' not in errors
code, output, errors = interactive('\x04')
assert code != 0 and 'Input ended; installation cancelled' in errors
result = run('--package', str(package), '--dry-run', defaults=False)
assert result.returncode != 0 and 'No interactive input' in result.stderr
result = run('--package', str(package), '--dry-run', '--install-skill', '--register',
             '--skip-markdown-default', defaults=False)
assert result.returncode == 0 and selected_choices(result.stdout) == {'parchment': 1, 'skill': 1, 'scheme': 1, 'default': 0}
print('PASS terminal prompts, Enter defaults, flag overrides, invalid answers, EOF, and unattended use')

with tempfile.TemporaryDirectory(prefix='parchment-install-script-check-') as temporary:
    local = Path(temporary) / 'package with spaces.pkg'
    local.write_bytes(package.read_bytes())
    checksum = Path(str(local) + '.sha256')
    valid = hashlib.sha256(local.read_bytes()).hexdigest() + '  ' + local.name + '\n'
    checksum.write_text(valid)
    assert run('--package', str(local), '--dry-run').returncode == 0
    local.write_bytes(local.read_bytes() + b'tampered')
    result = run('--package', str(local), '--dry-run')
    assert result.returncode != 0 and 'checksum mismatch' in result.stderr
    checksum.write_text(valid.replace(local.name, '../unrelated.pkg'))
    result = run('--package', str(local), '--dry-run')
    assert result.returncode != 0 and 'different installer' in result.stderr
    checksum.write_text(valid + valid)
    result = run('--package', str(local), '--dry-run')
    assert result.returncode != 0 and 'Invalid checksum' in result.stderr
    checksum.unlink()
    result = run('--package', str(local), '--dry-run')
    assert result.returncode != 0 and 'Checksum file not found' in result.stderr
print('PASS spaces in paths, tampered packages, unsafe manifests, and missing checksums')

for arguments in [('--unknown',), ('--package',), ('--version',),
                  ('--version', '../../bad'), ('--package', str(package), '--version', '0.1.12')]:
    assert run(*arguments).returncode != 0, arguments
assert run('--help').returncode == 0
print('PASS help and invalid arguments without administrator access')

with tempfile.TemporaryDirectory(prefix='parchment-checkout-install-') as temporary:
    checkout = Path(temporary)
    (checkout / 'scripts').mkdir()
    (checkout / 'dist').mkdir()
    (checkout / 'Package.swift').write_text('// Source checkout fixture\n')
    local_script = checkout / 'scripts/install.sh'
    shutil.copyfile(script, local_script)
    # Use the real package version and architecture; place an older file beside it.
    parts = package.stem.split('-')
    version = parts[1]
    (checkout / 'scripts/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': version}))
    local_package = checkout / 'dist' / package.name
    shutil.copyfile(package, local_package)
    shutil.copyfile(str(package) + '.sha256', str(local_package) + '.sha256')
    (checkout / 'dist/Parchment-0.0.1-arm64.pkg').write_bytes(b'Older build: never select this file')
    result = subprocess.run(['bash', str(local_script), '--yes', '--dry-run'], cwd='/',
                            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stderr
    assert 'Using the local installer for checkout version ' + version in result.stderr
    assert 'Verified ' + package.name in result.stderr and 'Downloading' not in result.stderr
    assert selected_choices(result.stdout) == {'parchment': 1, 'skill': 1, 'scheme': 1, 'default': 0}
    # A local package with no checksum must fail rather than fall back to a release.
    Path(str(local_package) + '.sha256').unlink()
    result = subprocess.run(['bash', str(local_script), '--yes', '--dry-run'],
                            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
    assert result.returncode != 0 and 'Checksum file not found' in result.stderr
print('PASS checkout version selection, working-directory independence, and no silent release fallback')
