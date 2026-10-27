#!/bin/bash
set -euo pipefail

destination="${1:-$HOME/.agents/skills/parchment}"
mkdir -p "$destination"
temporary_skill="$(mktemp "$destination/.SKILL.md.XXXXXX")"
trap 'rm -f "$temporary_skill"' EXIT
cat > "$temporary_skill"
[[ -s "$temporary_skill" ]] || { printf 'The packaged skill is empty.\n' >&2; exit 1; }
skill_path="$destination/SKILL.md"
if [[ -f "$skill_path" ]] && cmp -s "$temporary_skill" "$skill_path"; then
    exit 0
fi
if [[ -e "$skill_path" || -L "$skill_path" ]]; then
    backup="$(mktemp "$destination/SKILL.md.backup.XXXXXX")"
    cp -p "$skill_path" "$backup"
fi
chmod 644 "$temporary_skill"
mv -f "$temporary_skill" "$skill_path"
