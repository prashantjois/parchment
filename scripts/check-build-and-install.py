#!/usr/bin/env python3
"""Check the executable build/install pipeline without administrator access."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

repository = Path(__file__).resolve().parent.parent
for name in ['build-app.sh', 'build-installer.sh', 'install.sh', 'build-and-install.sh']:
    path = repository / 'scripts' / name
    assert os.access(path, os.X_OK), path
    assert subprocess.run([str(path), '--help'], capture_output=True).returncode == 0
print('PASS all build and install entry points execute directly')

with tempfile.TemporaryDirectory(prefix='parchment-pipeline-') as temporary:
    root = Path(temporary) / 'checkout with spaces'
    scripts = root / 'scripts'; scripts.mkdir(parents=True)
    output = root / 'dist'; output.mkdir()
    fresh = output / 'Parchment-1.0.0-arm64.pkg'
    fresh.write_text('newly built fixture')
    Path(str(fresh)+'.sha256').write_text('fixture checksum')
    (output / 'Parchment-99.0.0-arm64.pkg').write_text('unrelated newer package')
    wrapper = scripts / 'build-and-install.sh'
    shutil.copy2(repository / 'scripts/build-and-install.sh', wrapper)
    log = root / 'steps.jsonl'
    builder = scripts / 'build-installer.sh'
    builder.write_text('''#!/usr/bin/env python3
import json,os,pathlib,sys
with open(os.environ['PIPELINE_LOG'],'a') as log: log.write(json.dumps(['build',sys.argv[1:]])+'\\n')
case=os.environ['PIPELINE_CASE']
if case=='build-failure':sys.exit(17)
if case=='missing-receipt':sys.exit(0)
assert sys.argv[1]=='--output-path-file' and len(sys.argv)==3
pathlib.Path(sys.argv[2]).write_text(os.environ['FRESH_PACKAGE']+'\\n')
''')
    installer = scripts / 'install.sh'
    installer.write_text('''#!/usr/bin/env python3
import json,os,sys
with open(os.environ['PIPELINE_LOG'],'a') as log:log.write(json.dumps(['install',sys.argv[1:]])+'\\n')
if os.environ['PIPELINE_CASE']=='install-failure':sys.exit(23)
''')
    builder.chmod(0o755); installer.chmod(0o755)

    def run(case='success', *arguments):
        log.write_text('')
        env = dict(os.environ, PIPELINE_CASE=case, PIPELINE_LOG=str(log), FRESH_PACKAGE=str(fresh))
        result = subprocess.run([str(wrapper), *arguments], cwd='/', env=env, text=True, capture_output=True)
        steps = [json.loads(line) for line in log.read_text().splitlines()]
        return result, steps

    result, steps = run('success', '--yes', '--skip-skill', '--dry-run')
    assert result.returncode == 0, result.stderr
    assert [step[0] for step in steps] == ['build', 'install']
    assert steps[1][1] == ['--package', str(fresh), '--yes', '--skip-skill', '--dry-run']
    assert not Path(steps[0][1][1]).parent.exists(), 'Receipt directory must be cleaned'
    print('PASS exact build output, options, dry-run forwarding, spaces, and working-directory independence')
    for case, expected in [('build-failure', 17), ('missing-receipt', 1), ('install-failure', 23)]:
        result, steps = run(case, '--yes')
        assert result.returncode == expected, (case, result.stderr)
        if case != 'install-failure': assert len(steps) == 1
    print('PASS build failures and missing receipts prevent installation; installation failures propagate')
    for flags in [('--version', '99.0.0'), ('--package', '/tmp/other.pkg'), ('--unknown',), ('--help',)]:
        result, steps = run('success', *flags)
        assert not steps, flags
        assert result.returncode == (0 if flags == ('--help',) else 1)
    print('PASS help and invalid selectors never start a build or install a different release')

    # The real app builder must stop before modifying its bundle if normal quit fails.
    shutil.copy2(repository / 'scripts/build-app.sh', scripts / 'build-app.sh')
    installer.write_text('#!/bin/bash\n[[ "$1" == --quit-only ]] || exit 99\nexit 19\n')
    original = output / 'Parchment.app/Contents/MacOS/Parchment'
    original.parent.mkdir(parents=True); original.write_text('running build')
    result = subprocess.run([str(scripts / 'build-app.sh')], cwd='/', text=True, capture_output=True)
    assert result.returncode == 19 and original.read_text() == 'running build', result.stderr
    print('PASS app build stops before overwriting files when Parchment refuses to quit')
