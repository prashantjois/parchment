#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-release}" in
    --help|-h) printf 'Usage: ./scripts/build-app.sh [release|debug]\n'; exit 0 ;;
    release|debug) configuration="${1:-release}" ;;
    *) printf 'Use release or debug. See --help.\n' >&2; exit 1 ;;
esac
[[ $# -le 1 ]] || { printf 'Unexpected arguments. See --help.\n' >&2; exit 1; }
./scripts/install.sh --quit-only
mkdir -p dist
swift build --build-system native -c "$configuration" --product Parchment
swift build --build-system native -c "$configuration" --product ParchmentMCP
binary_directory="$(swift build --build-system native -c "$configuration" --show-bin-path)"
app_directory="$PWD/dist/Parchment.app"
mkdir -p "$app_directory/Contents/MacOS" "$app_directory/Contents/Resources"
cp "$binary_directory/Parchment" "$app_directory/Contents/MacOS/Parchment"
cp "$binary_directory/ParchmentMCP" "$app_directory/Contents/MacOS/ParchmentMCP"
setup_directory="$(mktemp -d "${TMPDIR:-/tmp}/parchment-setup.XXXXXX")"
trap 'rm -rf "$setup_directory"' EXIT
setup_binaries=()
for architecture in $(/usr/bin/lipo -archs "$binary_directory/Parchment"); do
    xcrun swiftc -O -target "$architecture-apple-macosx14.0" scripts/set-markdown-default.swift -o "$setup_directory/$architecture"
    setup_binaries+=("$setup_directory/$architecture")
done
/usr/bin/lipo -create "${setup_binaries[@]}" -output "$app_directory/Contents/MacOS/ParchmentSetup"
cp scripts/Info.plist "$app_directory/Contents/Info.plist"
for resource in themes skills docs vendor; do
    mkdir -p "$app_directory/Contents/Resources/$resource"
    /usr/bin/rsync -a --delete --delete-excluded --exclude='*.comments.json' --exclude='*.review.json' \
        "$resource/" "$app_directory/Contents/Resources/$resource/"
done
codesign --force --deep --sign - "$app_directory"
if [[ ! -d /Applications/Parchment.app || "${PARCHMENT_REGISTER_DEVELOPMENT:-0}" == "1" ]]; then
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app_directory"
fi
printf 'Built %s\n' "$app_directory"
