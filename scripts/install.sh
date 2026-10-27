#!/bin/bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: bash scripts/install.sh [options]

Download the latest release, verify its checksum, and install Parchment in
/Applications using macOS's command-line installer. Run without sudo; only
the installation step requests administrator access.

  --version VERSION     Install a specific release (for example, 0.1.12).
  --package PATH        Use a local .pkg and its adjacent .pkg.sha256 file.
  --install-skill       Install the skill without asking about it.
  --skip-skill          Skip installing the Parchment agent skill.
  --register            Register parchment:// links without asking about it.
  --skip-register       Skip immediate parchment:// link registration.
  --markdown-default    Make Parchment the default app for .md and .markdown.
  --skip-markdown-default  Leave default file associations unchanged.
  --yes                 Skip questions; use defaults for unspecified choices.
  --dry-run             Verify the package and show choices without installing.
  --help                Show this help.

The script asks about each setup choice unless a flag supplies its answer.
Press Enter to accept the defaults: skill and link registration on, default
Markdown app off. Without interactive input, supply --yes or all three choices.
MCP client configuration remains a separate step.
This script does not sign or notarize the app. If macOS blocks its first launch,
use System Settings > Privacy & Security > Open Anyway for Parchment.
USAGE
}

fail() { printf '%s\n' "$*" >&2; exit 1; }
version=""
package=""
install_skill=""
register_scheme=""
markdown_default=""
assume_defaults=0
dry_run=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version|--package)
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || fail "Missing value for $1."
            if [[ "$1" == --version ]]; then version="${2#v}"; else package="$2"; fi
            shift 2 ;;
        --install-skill) install_skill=1; shift ;;
        --skip-skill) install_skill=0; shift ;;
        --register) register_scheme=1; shift ;;
        --skip-register) register_scheme=0; shift ;;
        --markdown-default) markdown_default=1; shift ;;
        --skip-markdown-default) markdown_default=0; shift ;;
        --yes) assume_defaults=1; shift ;;
        --dry-run) dry_run=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown option: $1. Use --help." ;;
    esac
done
[[ -z "$version" || -z "$package" ]] || fail 'Use --version or --package, not both.'
if [[ -n "$version" ]]; then
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Expected a release version such as 0.1.12.'
fi
[[ "$(uname -s)" == Darwin ]] || fail 'Parchment requires macOS 14 or later.'
os_version="$(/usr/bin/sw_vers -productVersion)"
[[ "${os_version%%.*}" -ge 14 ]] || fail 'Parchment requires macOS 14 or later.'
[[ "$EUID" -ne 0 ]] || fail 'Run this script without sudo; it requests administrator access for installation.'
if [[ "$dry_run" -eq 0 ]] && /usr/bin/pgrep -x Parchment >/dev/null; then
    fail 'Quit Parchment before installing or upgrading it.'
fi

prompt_choice() {
    local choice_variable="$1" question="$2" default_answer="$3" answer=""
    while true; do
        printf '%s ' "$question" >&2
        IFS= read -r answer || fail 'Input ended; installation cancelled.'
        case "$answer" in
            '') printf -v "$choice_variable" '%s' "$default_answer"; return ;;
            [Yy]|[Yy][Ee][Ss]) printf -v "$choice_variable" '%s' 1; return ;;
            [Nn]|[Nn][Oo]) printf -v "$choice_variable" '%s' 0; return ;;
            *) printf 'Enter y or n.\n' >&2 ;;
        esac
    done
}
if [[ "$assume_defaults" -eq 1 ]]; then
    install_skill="${install_skill:-1}"
    register_scheme="${register_scheme:-1}"
    markdown_default="${markdown_default:-0}"
else
    if [[ -z "$install_skill" || -z "$register_scheme" || -z "$markdown_default" ]]; then
        [[ -t 0 ]] || fail 'No interactive input. Run in Terminal, supply --yes, or set all three setup choices.'
    fi
    if [[ -z "$install_skill" ]]; then
        prompt_choice install_skill 'Install the Parchment agent skill in ~/.agents/skills/parchment? [Y/n]' 1
    fi
    if [[ -z "$register_scheme" ]]; then
        prompt_choice register_scheme 'Register parchment:// links now? [Y/n]' 1
    fi
    if [[ -z "$markdown_default" ]]; then
        prompt_choice markdown_default 'Make Parchment the default app for .md and .markdown files? [y/N]' 0
    fi
fi

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/parchment-install.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT
download() {
    /usr/bin/curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
        --retry 2 --connect-timeout 20 --max-time 300 "$1" --output "$2"
}
if [[ -z "$package" ]]; then
    if [[ -z "$version" ]]; then
        # Follow the public release redirect without GitHub API credentials or quotas.
        latest_url="$(/usr/bin/curl --fail --location --head --silent --show-error \
            --proto '=https' --proto-redir '=https' --retry 2 --connect-timeout 20 --max-time 60 \
            --output /dev/null --write-out '%{url_effective}' \
            'https://github.com/prashantjois/parchment/releases/latest')"
        [[ "$latest_url" =~ ^https://github\.com/prashantjois/parchment/releases/tag/v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || fail 'The latest release has an unsupported version tag.'
        version="${BASH_REMATCH[1]}"
    fi
    architecture="$(uname -m)"
    # Prefer arm64 even when Terminal runs under Rosetta.
    if [[ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true)" == 1 ]]; then architecture=arm64; fi
    case "$architecture" in arm64|x86_64) ;; *) fail "Unsupported architecture: $architecture." ;; esac
    package_name="Parchment-$version-$architecture.pkg"
    release_url="https://github.com/prashantjois/parchment/releases/download/v$version"
    printf 'Downloading %s…\n' "$package_name" >&2
    download "$release_url/$package_name" "$temporary_directory/$package_name" || fail "No installer could be downloaded for $version ($architecture)."
    download "$release_url/$package_name.sha256" "$temporary_directory/$package_name.sha256"
    package="$temporary_directory/$package_name"
else
    [[ -f "$package" && "$package" == *.pkg ]] || fail "Installer not found: $package."
    [[ -f "$package.sha256" ]] || fail "Checksum file not found: $package.sha256."
    package_name="$(basename "$package")"
    cp "$package" "$temporary_directory/$package_name"
    cp "$package.sha256" "$temporary_directory/$package_name.sha256"
    package="$temporary_directory/$package_name"
fi

# Accept exactly one checksum for this package; never follow paths from a manifest.
checksum="$(cat "$package.sha256")"
[[ "$checksum" != *$'\n'* && "$checksum" =~ ^([[:xdigit:]]{64})[[:space:]]+\*?(.+)$ ]] || fail 'Invalid checksum file.'
expected_hash="${BASH_REMATCH[1]}"
[[ "${BASH_REMATCH[2]}" == "$package_name" ]] || fail 'The checksum names a different installer.'
actual_hash="$(/usr/bin/shasum -a 256 "$package")"
[[ "${actual_hash%% *}" == "$expected_hash" ]] || fail 'Installer checksum mismatch; installation stopped.'
printf 'Verified %s.\n' "$package_name" >&2

choices="$temporary_directory/choices.plist"
cat > "$choices" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><array>
<dict><key>choiceIdentifier</key><string>skill</string><key>choiceAttribute</key><string>selected</string><key>attributeSetting</key><integer>$install_skill</integer></dict>
<dict><key>choiceIdentifier</key><string>scheme</string><key>choiceAttribute</key><string>selected</string><key>attributeSetting</key><integer>$register_scheme</integer></dict>
<dict><key>choiceIdentifier</key><string>default</string><key>choiceAttribute</key><string>selected</string><key>attributeSetting</key><integer>$markdown_default</integer></dict>
</array></plist>
PLIST
if [[ "$dry_run" -eq 1 ]]; then
    /usr/sbin/installer -pkg "$package" -target / -showChoicesAfterApplyingChangesXML "$choices"
    printf 'Dry run complete. No app, skill, or user settings changed.\n' >&2
    exit 0
fi

printf 'Installing in /Applications. macOS will request administrator access.\n' >&2
/usr/bin/sudo /usr/sbin/installer -pkg "$package" -target / -applyChoiceChangesXML "$choices"
printf '\nInstalled Parchment. Open /Applications/Parchment.app from Applications or Spotlight.\n'
