#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

bash scripts/build-app.sh release
app_directory="$PWD/dist/Parchment.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_directory/Contents/Info.plist")"
architectures="$(/usr/bin/lipo -archs "$app_directory/Contents/MacOS/Parchment")"
helper_architectures="$(/usr/bin/lipo -archs "$app_directory/Contents/MacOS/ParchmentMCP")"
if [[ "$architectures" != "$helper_architectures" ]]; then
    printf 'The app and MCP helper must support the same architectures.\n' >&2
    exit 1
fi
case "$architectures" in
    arm64) artifact_arch="arm64" ;;
    x86_64) artifact_arch="x86_64" ;;
    "arm64 x86_64"|"x86_64 arm64") artifact_arch="universal" ;;
    *) printf 'Unsupported architectures: %s\n' "$architectures" >&2; exit 1 ;;
esac
staging_directory="$(mktemp -d "${TMPDIR:-/tmp}/parchment-installer.XXXXXX")"
trap 'rm -rf "$staging_directory"' EXIT
mkdir -p "$staging_directory/payload/Applications" "$staging_directory/packages"
ditto --noextattr --noqtn --noacl "$app_directory" "$staging_directory/payload/Applications/Parchment.app"
codesign --verify --deep --strict "$staging_directory/payload/Applications/Parchment.app"
pkgbuild --analyze --root "$staging_directory/payload" "$staging_directory/components.plist"

# Disable relocation: an existing build under dist/ must not redirect installation.
python3 - "$staging_directory" "$version" "$architectures" <<'PY'
from pathlib import Path
import plistlib
import sys
import xml.etree.ElementTree as ET

stage, version, architectures = Path(sys.argv[1]), sys.argv[2], sys.argv[3].split()
components_path = stage / 'components.plist'
components = plistlib.loads(components_path.read_bytes())
for component in components:
    component['BundleIsRelocatable'] = False
    component['BundleHasStrictIdentifier'] = True
    component['BundleIsVersionChecked'] = True
    component['BundleOverwriteAction'] = 'upgrade'
components_path.write_bytes(plistlib.dumps(components))

identifier = 'local.parchment.editor.installer'
distribution = ET.Element('installer-gui-script', {'minSpecVersion': '2'})
ET.SubElement(distribution, 'title').text = 'Parchment'
ET.SubElement(distribution, 'welcome', {'file': 'welcome.html', 'mime-type': 'text/html'})
ET.SubElement(distribution, 'conclusion', {'file': 'conclusion.html', 'mime-type': 'text/html'})
ET.SubElement(distribution, 'options', {'customize': 'never', 'require-scripts': 'false', 'hostArchitectures': ','.join(architectures)})
ET.SubElement(distribution, 'domains', {'enable_anywhere': 'false', 'enable_currentUserHome': 'false', 'enable_localSystem': 'true'})
volume_check = ET.SubElement(distribution, 'volume-check')
ET.SubElement(volume_check, 'allowed-os-versions').append(ET.Element('os-version', {'min': '14.0'}))
outline = ET.SubElement(distribution, 'choices-outline')
ET.SubElement(outline, 'line', {'choice': 'parchment'})
choice = ET.SubElement(distribution, 'choice', {'id': 'parchment', 'visible': 'false', 'title': 'Parchment'})
ET.SubElement(choice, 'pkg-ref', {'id': identifier})
ET.SubElement(distribution, 'pkg-ref', {'id': identifier, 'version': version, 'auth': 'Root', 'onConclusion': 'none'}).text = 'Parchment-component.pkg'
ET.indent(distribution)
ET.ElementTree(distribution).write(stage / 'Distribution.xml', encoding='utf-8', xml_declaration=True)
PY

chmod 755 scripts/installer/postinstall
pkgbuild --root "$staging_directory/payload" \
    --component-plist "$staging_directory/components.plist" \
    --scripts scripts/installer \
    --identifier local.parchment.editor.installer \
    --version "$version" --install-location / --ownership recommended \
    "$staging_directory/packages/Parchment-component.pkg"

installer_name="Parchment-$version-$artifact_arch.pkg"
installer_path="$PWD/dist/$installer_name"
productbuild --distribution "$staging_directory/Distribution.xml" \
    --resources scripts/installer-resources \
    --package-path "$staging_directory/packages" "$installer_path"
(
    cd dist
    shasum -a 256 "$installer_name" > "$installer_name.sha256"
)
printf 'Built %s\n' "$installer_path"
