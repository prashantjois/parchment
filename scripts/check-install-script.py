#!/usr/bin/env python3
"""Exercise the install script against a real package without installing it."""
import hashlib
import itertools
import json
import shlex
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


def interactive(answers, *options, script_path=script, package_path=package, env=None):
    terminal, input_fd = os.openpty()
    try:
        command = ['bash', str(script_path), '--dry-run', *options]
        if package_path is not None:
            command.extend(['--package', str(package_path)])
        with subprocess.Popen(command, env=env,
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
    options.append('--markdown-default' if default else '--skip-markdown-default')
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
assert code == 0 and selected_choices(output) == {'parchment': 1, 'skill': 1, 'scheme': 1, 'default': 1}
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
    # Mock only HTTP in the copied script. Choices still use the real macOS installer.
    mock_curl = checkout / 'curl-fixture.py'
    mock_curl.write_text("#!" + sys.executable + "\n" + r'''import hashlib, json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['CURL_TRACE'], 'a') as stream:
    stream.write(json.dumps(args) + '\n')
if '--head' in args:
    if os.environ.get('CURL_OFFLINE') == '1': sys.exit(22)
    print('https://github.com/prashantjois/parchment/releases/tag/v' + os.environ['PUBLISHED_VERSION'], end='')
    sys.exit(0)
if os.environ.get('ALLOW_DOWNLOAD') != '1': sys.exit(22)
destination = pathlib.Path(args[args.index('--output') + 1])
content = pathlib.Path(os.environ['PACKAGE_FIXTURE']).read_bytes()
if args[-1].endswith('.sha256'):
    name = destination.name.removesuffix('.sha256')
    destination.write_text(hashlib.sha256(content).hexdigest() + '  ' + name + '\n')
else:
    destination.write_bytes(content)
''')
    mock_curl.chmod(0o755)
    local_script.write_text(script.read_text().replace('/usr/bin/curl', shlex.quote(str(mock_curl))))
    parts = package.stem.split('-')
    version, architecture = parts[1:]
    (checkout / 'scripts/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '99.0.0'}))
    local_package = checkout / 'dist' / package.name
    shutil.copyfile(package, local_package)
    shutil.copyfile(str(package) + '.sha256', str(local_package) + '.sha256')
    (checkout / 'dist/Parchment-0.0.1-arm64.pkg').write_bytes(b'Older build: never select this file')
    trace = checkout / 'curl-trace.jsonl'
    env = dict(os.environ, CURL_TRACE=str(trace), PUBLISHED_VERSION=version, PACKAGE_FIXTURE=str(package))

    def selected(*arguments, environment=None):
        return subprocess.run(['bash', str(local_script), '--yes', '--dry-run', *arguments], cwd='/',
                              env=environment or env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)

    result = selected()
    assert result.returncode == 0, result.stderr
    assert 'Latest published version: ' + version in result.stderr
    assert 'Using the local installer for version ' + version in result.stderr
    assert 'Verified ' + package.name in result.stderr and 'Downloading' not in result.stderr
    assert selected_choices(result.stdout) == {'parchment': 1, 'skill': 1, 'scheme': 1, 'default': 1}
    code, output, errors = interactive('\n\n\n\n', script_path=local_script, package_path=None, env=env)
    assert code == 0 and 'Version to install [latest]' in errors, errors
    assert selected_choices(output)['default'] == 1 and 'Verified ' + package.name in errors
    code, output, errors = interactive('invalid\nv' + version + '\n\n\n\n', script_path=local_script, package_path=None, env=env)
    assert code == 0 and 'Enter a version such as' in errors and 'Verified ' + package.name in errors, errors
    code, output, errors = interactive('\x04', script_path=local_script, package_path=None, env=env)
    assert code != 0 and 'Input ended; installation cancelled' in errors
    print('PASS version prompt, Enter/latest defaults, explicit version input, invalid input, and version-prompt EOF')

    before = trace.read_text()
    result = selected('--version', version)
    assert result.returncode == 0 and trace.read_text() == before, result.stderr
    result = selected(environment=dict(env, CURL_OFFLINE='1'))
    assert result.returncode != 0 and 'Could not find the latest published version' in result.stderr
    result = selected('--version', version, environment=dict(env, CURL_OFFLINE='1'))
    assert result.returncode == 0, result.stderr
    result = selected(environment=dict(env, PUBLISHED_VERSION='../bad'))
    assert result.returncode != 0 and 'unsupported version tag' in result.stderr
    print('PASS explicit local versions work offline; latest requires a valid published release and ignores newer checkout metadata')

    release_env = dict(env, PUBLISHED_VERSION='0.1.100', ALLOW_DOWNLOAD='1')
    result = selected(environment=release_env)
    assert result.returncode == 0, result.stderr
    assert 'Latest published version: 0.1.100' in result.stderr
    assert 'Downloading Parchment-0.1.100-' + architecture in result.stderr
    code, output, errors = interactive('0.1.100\n\n\n\n', script_path=local_script, package_path=None,
                                       env=dict(env, ALLOW_DOWNLOAD='1'))
    assert code == 0 and 'Downloading Parchment-0.1.100-' + architecture in errors, errors
    standalone = checkout / 'standalone/install.sh'
    standalone.parent.mkdir()
    shutil.copyfile(local_script, standalone)
    result = subprocess.run(['bash', str(standalone), '--yes', '--dry-run'], env=release_env,
                            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
    assert result.returncode == 0 and 'Latest published version: 0.1.100' in result.stderr, result.stderr
    result = subprocess.run(['bash', str(standalone), '--yes', '--dry-run'], env=dict(env, CURL_OFFLINE='1'),
                            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
    assert result.returncode != 0 and 'Could not find the latest published version' in result.stderr
    print('PASS newer published versions, explicit release selection, standalone latest selection, and standalone offline failure')

    Path(str(local_package) + '.sha256').unlink()
    result = selected()
    assert result.returncode != 0 and 'Checksum file not found' in result.stderr
    local_package.unlink()
    result = selected()
    assert result.returncode != 0 and 'No published installer for ' + version in result.stderr
    assert 'Downloading Parchment-0.0.1-' not in result.stderr
print('PASS selected versions fail on missing checksums or unavailable installers without falling back to a different version')
