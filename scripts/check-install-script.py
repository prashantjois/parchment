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
    checkout = Path(temporary) / 'checkout with spaces'
    (checkout / 'scripts').mkdir(parents=True)
    releases = checkout / 'dist'
    releases.mkdir()
    (checkout / 'Package.swift').write_text('// Source checkout fixture\n')
    # Package files determine available versions, not source metadata.
    (checkout / 'scripts/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '99.0.0'}))
    local_script = checkout / 'scripts/install.sh'
    shutil.copyfile(script, local_script)
    version, architecture = package.stem.split('-')[1:]
    other_architecture = 'x86_64' if architecture == 'arm64' else 'arm64'

    def local_package(selected_version, selected_architecture=architecture):
        target = releases / f'Parchment-{selected_version}-{selected_architecture}.pkg'
        shutil.copyfile(package, target)
        Path(str(target) + '.sha256').write_text(hashlib.sha256(target.read_bytes()).hexdigest() + '  ' + target.name + '\n')
        return target

    local = local_package(version)
    (releases / 'Parchment-0.0.1-arm64.pkg').write_bytes(b'Older build: never select by filename order')
    local_package('99.0.0', other_architecture)
    (releases / 'Parchment-not-a-version-universal.pkg').write_bytes(b'Ignore unrelated files')

    def selected(*arguments, path=local_script):
        return subprocess.run(['bash', str(path), '--yes', '--dry-run', *arguments], cwd='/',
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)

    result = selected()
    assert result.returncode == 0, result.stderr
    assert 'Latest local version: ' + version in result.stderr
    assert 'Verified ' + package.name in result.stderr
    assert selected_choices(result.stdout) == {'parchment': 1, 'skill': 1, 'scheme': 1, 'default': 1}
    result = selected('--version', 'latest')
    assert result.returncode == 0 and 'Latest local version: ' + version in result.stderr
    code, output, errors = interactive('\n\n\n\n', script_path=local_script, package_path=None)
    assert code == 0 and 'Version to install [latest]' in errors and 'Verified ' + package.name in errors, errors
    assert selected_choices(output)['default'] == 1
    code, output, errors = interactive('invalid\nv' + version + '\n\n\n\n', script_path=local_script, package_path=None)
    assert code == 0 and 'Enter a version such as' in errors and 'Verified ' + package.name in errors, errors
    code, output, errors = interactive('\x04', script_path=local_script, package_path=None)
    assert code != 0 and 'Input ended; installation cancelled' in errors
    print('PASS local latest, explicit latest, prompt defaults, invalid input, EOF, spaces, and working-directory independence')

    for selected_version in ['1.9.9', '1.10.0']:
        local_package(selected_version)
    result = selected()
    assert result.returncode == 0 and 'Latest local version: 1.10.0' in result.stderr, result.stderr
    for selected_version in ['1.10.9', '1.10.10']:
        local_package(selected_version)
    result = selected()
    assert result.returncode == 0 and 'Latest local version: 1.10.10' in result.stderr, result.stderr
    for selected_version in ['1.99.99', '2.0.0']:
        local_package(selected_version)
    result = selected()
    assert result.returncode == 0 and 'Latest local version: 2.0.0' in result.stderr, result.stderr
    result = selected('--version', '1.10.0')
    assert result.returncode == 0 and 'Verified Parchment-1.10.0-' in result.stderr
    code, output, errors = interactive('1.9.9\n\n\n\n', script_path=local_script, package_path=None)
    assert code == 0 and 'Verified Parchment-1.9.9-' in errors, errors
    print('PASS numeric major/minor/patch ordering and selection of older local versions')

    universal = local_package('3.0.0', 'universal')
    result = selected()
    assert result.returncode == 0 and 'Verified ' + universal.name in result.stderr, result.stderr
    native = local_package('3.0.0')
    result = selected()
    assert result.returncode == 0 and 'Verified ' + native.name in result.stderr, result.stderr
    print('PASS newer universal packages, native preference at the same version, and incompatible-architecture exclusion')

    checksum = Path(str(native) + '.sha256')
    valid_checksum = checksum.read_text()
    checksum.unlink()
    result = selected()
    assert result.returncode != 0 and 'Checksum file not found' in result.stderr
    checksum.write_text(valid_checksum)
    native.write_bytes(native.read_bytes() + b'tampered')
    result = selected()
    assert result.returncode != 0 and 'checksum mismatch' in result.stderr
    result = selected('--version', '88.0.0')
    assert result.returncode != 0 and 'No local installer for 88.0.0' in result.stderr
    print('PASS the newest missing checksum, a corrupt package, and unavailable explicit versions fail without fallback')

    standalone = checkout / 'standalone/scripts/install.sh'
    standalone.parent.mkdir(parents=True)
    shutil.copyfile(script, standalone)
    result = selected(path=standalone)
    assert result.returncode != 0 and 'No local installers' in result.stderr
    result = selected('--package', str(package), path=standalone)
    assert result.returncode == 0, result.stderr
    for path in releases.iterdir(): path.unlink()
    result = selected()
    assert result.returncode != 0 and 'No local installers' in result.stderr
    print('PASS empty local release folders and standalone copies require an explicit package instead of accessing GitHub')
