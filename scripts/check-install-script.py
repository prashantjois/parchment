#!/usr/bin/env python3
"""Exercise the install script against a real package without installing it."""
import hashlib
import itertools
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

script = Path(__file__).with_name('install.sh')
package = Path(sys.argv[1]).resolve()


def run(*arguments):
    return subprocess.run(['bash', str(script), *arguments], capture_output=True, text=True)


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
    choices = plistlib.loads(result.stdout.encode())
    selected = {item['choiceIdentifier']: item['attributeSetting']
                for item in choices if item['choiceAttribute'] == 'selected'}
    assert selected == {'parchment': 1, 'skill': skill, 'scheme': scheme, 'default': default}
print('PASS script defaults and all eight installer choices using the real package')

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
