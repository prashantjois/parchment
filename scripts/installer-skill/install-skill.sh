#!/bin/bash
set -euo pipefail

destination="${1:-$HOME/.agents/skills/parchment}"
references="${2:-}"
if [[ -n "$references" && ! -d "$references" ]]; then
    printf 'The packaged skill references are missing.\n' >&2
    exit 1
fi
mkdir -p "$destination"
temporary_skill="$(mktemp "$destination/.SKILL.md.XXXXXX")"
trap 'rm -f "$temporary_skill"' EXIT
cat > "$temporary_skill"
[[ -s "$temporary_skill" ]] || { printf 'The packaged skill is empty.\n' >&2; exit 1; }
skill_path="$destination/SKILL.md"
if [[ ! -f "$skill_path" ]] || ! cmp -s "$temporary_skill" "$skill_path"; then
    if [[ -e "$skill_path" || -L "$skill_path" ]]; then
        backup="$(mktemp "$destination/SKILL.md.backup.XXXXXX")"
        cp -p "$skill_path" "$backup"
    fi
    chmod 644 "$temporary_skill"
    mv -f "$temporary_skill" "$skill_path"
fi
if [[ -n "$references" ]]; then
    mkdir -p "$destination/references"
    for reference in "$references"/*.md; do
        [[ -f "$reference" ]] || continue
        reference_path="$destination/references/${reference##*/}"
        if [[ -f "$reference_path" ]] && cmp -s "$reference" "$reference_path"; then continue; fi
        if [[ -e "$reference_path" || -L "$reference_path" ]]; then
            backup="$(mktemp "$reference_path.backup.XXXXXX")"
            cp -p "$reference_path" "$backup"
        fi
        temporary_reference="$(mktemp "$destination/references/.reference.XXXXXX")"
        if ! cp "$reference" "$temporary_reference"; then
            rm -f "$temporary_reference"
            exit 1
        fi
        chmod 644 "$temporary_reference"
        mv -f "$temporary_reference" "$reference_path"
    done
fi
