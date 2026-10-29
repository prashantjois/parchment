#!/usr/bin/env python3
"""Check installer choices and skill updates without installing the app."""
import itertools
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

package = Path(sys.argv[1]).resolve()
repository = Path(__file__).resolve().parent.parent


def run(*arguments):
    return subprocess.check_output(arguments)


def flatten(choices):
    result = {}
    for choice in choices:
        result[choice['choiceIdentifier']] = choice
        result.update(flatten(choice.get('childItems', [])))
    return result


with tempfile.TemporaryDirectory(prefix='parchment-installer-check-') as temporary:
    root = Path(temporary)
    defaults = flatten(plistlib.loads(run('/usr/sbin/installer', '-pkg', str(package), '-target', '/', '-showChoicesXML')))
    assert defaults['parchment']['choiceIsSelected'] == 1
    assert not defaults['parchment']['choiceIsEnabled']
    for option in ['skill', 'scheme', 'default']:
        assert defaults[option]['choiceIsVisible'] and defaults[option]['choiceIsEnabled']
        assert defaults[option]['choiceIsSelected'] == 1
    for skill, scheme, default in itertools.product([0, 1], repeat=3):
        changes = root / 'choices.plist'
        changes.write_bytes(plistlib.dumps([
            {'choiceIdentifier': name, 'choiceAttribute': 'selected', 'attributeSetting': selected}
            for name, selected in [('skill', skill), ('scheme', scheme), ('default', default)]
        ]))
        choices = plistlib.loads(run('/usr/sbin/installer', '-pkg', str(package), '-target', '/', '-showChoicesAfterApplyingChangesXML', str(changes)))
        selected = {item['choiceIdentifier']: item['attributeSetting'] for item in choices if item['choiceAttribute'] == 'selected'}
        assert selected == {'parchment': 1, 'skill': skill, 'scheme': scheme, 'default': default}
    print('PASS required app and all eight optional checkbox combinations')

    expanded = root / 'expanded'
    run('pkgutil', '--expand-full', str(package), str(expanded))
    distribution = ET.parse(expanded / 'Distribution').getroot()
    assert distribution.find('options').get('customize') == 'always'
    app_package = expanded / 'Parchment-component.pkg'
    assert not (app_package / 'Scripts/postinstall').exists()
    app = app_package / 'Payload/Applications/Parchment.app'
    run('codesign', '--verify', '--deep', '--strict', str(app))
    for option in ['skill', 'scheme', 'default']:
        scripts = expanded / f'Parchment-{option}.pkg/Scripts'
        assert (scripts / 'postinstall').read_bytes() == (repository / f'scripts/installer-{option}/postinstall').read_bytes()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    resources = app / 'Contents/Resources'
    assert not list(resources.rglob('*.comments.json'))
    assert not list(resources.rglob('*.review.json'))
    expected_themes = {path.name: path.read_bytes() for path in (repository / 'themes').glob('*.css')}
    packaged_themes = {path.name: path.read_bytes() for path in (resources / 'themes').glob('*.css')}
    assert packaged_themes == expected_themes, 'Packaged themes must match the current catalog without retired files'
    print('PASS packaged theme catalog matches source without retired styles')
    for document in (repository / 'docs').rglob('*.md'):
        assert (resources / document.relative_to(repository)).read_bytes() == document.read_bytes()
    markdown_type = next(item for item in info['UTImportedTypeDeclarations'] if item['UTTypeIdentifier'] == 'net.daringfireball.markdown')
    assert markdown_type['UTTypeTagSpecification']['public.filename-extension'] == ['md', 'markdown']
    setup = app / 'Contents/MacOS/ParchmentSetup'
    types = json.loads(run(str(setup), '--inspect-markdown-types'))
    assert 'net.daringfireball.markdown' in types
    assert not set(types) & {'public.plain-text', 'public.text', 'public.data', 'public.content', 'public.item'}
    invalid = subprocess.run([str(setup), '--invalid-option'], capture_output=True)
    assert invalid.returncode == 2
    print('PASS Markdown type declarations and setup inspection without changing defaults')
    scripts = expanded / 'Parchment-skill.pkg/Scripts'
    skill = (scripts / 'SKILL.md').read_bytes()
    assert skill == (repository / 'skills/parchment/SKILL.md').read_bytes()
    destination = root / 'user-skills/parchment'

    def install(content):
        return subprocess.run(['bash', str(scripts / 'install-skill.sh'), str(destination)], input=content, capture_output=True)

    assert install(skill).returncode == 0
    assert (destination / 'SKILL.md').read_bytes() == skill
    assert install(skill).returncode == 0
    assert not list(destination.glob('SKILL.md.backup.*'))
    (destination / 'SKILL.md').write_text('User customizations')
    assert install(skill).returncode == 0
    backups = list(destination.glob('SKILL.md.backup.*'))
    assert len(backups) == 1 and backups[0].read_text() == 'User customizations'
    assert install(b'').returncode != 0
    assert (destination / 'SKILL.md').read_bytes() == skill
    assert not list(destination.glob('.SKILL.md.*'))
    print('PASS packaged scripts, app signature, skill install, repeat install, backup, and empty-input protection')
