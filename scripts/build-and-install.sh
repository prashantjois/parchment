#!/bin/bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: ./scripts/build-and-install.sh [installation options]

Build the release app, build its installer, and install that exact package.
Parchment quits normally before the app bundle is replaced. Installation keeps
the skill, URL scheme, and Markdown-default prompts; Enter selects Yes.
Run without sudo. Only installation requests administrator access.

  --yes                   Accept default setup choices without questions.
  --install-skill          Install the agent skill without asking.
  --skip-skill             Skip the agent skill.
  --register              Register parchment:// links without asking.
  --skip-register         Skip immediate link registration.
  --markdown-default      Make Parchment the default Markdown viewer.
  --skip-markdown-default Leave file associations unchanged.
  --dry-run               Build both artifacts and preview installation only.
                          Still quits Parchment and replaces the local build.
  --help                  Show this help without building or installing.

Version selection is skipped because this script installs the package it builds.
Use ./scripts/install.sh to choose a different local release.
USAGE
}

for argument in "$@"; do
    case "$argument" in
        --help|-h) usage; exit 0 ;;
        --yes|--install-skill|--skip-skill|--register|--skip-register|--markdown-default|--skip-markdown-default|--dry-run) ;;
        *) printf 'Unsupported option: %s. Use --help.\n' "$argument" >&2; exit 1 ;;
    esac
done
[[ "$EUID" -ne 0 ]] || { printf 'Run without sudo; installation requests administrator access.\n' >&2; exit 1; }

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
receipt_directory="$(mktemp -d "${TMPDIR:-/tmp}/parchment-build-install.XXXXXX")"
trap 'rm -rf "$receipt_directory"' EXIT
receipt="$receipt_directory/package-path"

"$script_directory/build-installer.sh" --output-path-file "$receipt"
[[ -s "$receipt" ]] || { printf 'The build did not return an installer path.\n' >&2; exit 1; }
IFS= read -r package < "$receipt"
[[ -f "$package" && -f "$package.sha256" ]] || { printf 'The completed installer or checksum is missing.\n' >&2; exit 1; }

"$script_directory/install.sh" --package "$package" "$@"
