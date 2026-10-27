#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
mkdir -p dist
swift build --build-system native -c "$configuration" --product Parchment
swift build --build-system native -c "$configuration" --product ParchmentMCP
binary_directory="$(swift build --build-system native -c "$configuration" --show-bin-path)"
app_directory="$PWD/dist/Parchment.app"
mkdir -p "$app_directory/Contents/MacOS" "$app_directory/Contents/Resources"
cp "$binary_directory/Parchment" "$app_directory/Contents/MacOS/Parchment"
cp "$binary_directory/ParchmentMCP" "$app_directory/Contents/MacOS/ParchmentMCP"
cp scripts/Info.plist "$app_directory/Contents/Info.plist"
ditto themes "$app_directory/Contents/Resources/themes"
ditto skills "$app_directory/Contents/Resources/skills"
ditto docs "$app_directory/Contents/Resources/docs"
codesign --force --deep --sign - "$app_directory"
if [[ ! -d /Applications/Parchment.app || "${PARCHMENT_REGISTER_DEVELOPMENT:-0}" == "1" ]]; then
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app_directory"
fi
printf 'Built %s\n' "$app_directory"
