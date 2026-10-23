#!/usr/bin/env bash
# The repository itself: every script parses, LF line endings, executable, English only.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
cd "$REPO" || exit 2

section "bash -n"
for f in *.sh tests/*.sh tests/*/*.sh; do
    check "$f parses" bash -n "$f"
done

section "line endings, executable bit, language"
for f in *.sh tests/*.sh tests/*/*.sh .github/workflows/*.yml backup.conf.example README.md CHANGELOG.md; do
    if grep -q $'\r' "$f"; then bad "$f has CRLF"; else ok "$f is LF"; fi
done
for f in *.sh tests/*.sh tests/*/*.sh; do
    [[ "$f" == "pre-backup-hook.example.sh" || "$f" == "tests/helpers.sh" ]] && continue
    check "$f is executable" test -x "$f"
done
if grep -lP '[\x{0400}-\x{04FF}]' -- *.sh tests/*.sh tests/*/*.sh .github/workflows/*.yml backup.conf.example README.md CHANGELOG.md 2>/dev/null; then
    bad "Cyrillic text found (the project is English-only)"
else
    ok "English only"
fi

section "--help works without a config"
for f in *.sh; do
    case "$f" in lib.sh|ui.sh|pre-backup-hook.example.sh) continue ;; esac
    out="$(cd / && timeout 20 bash "$REPO/$f" --help < /dev/null 2>&1)"; rc=$?
    if (( rc == 0 )) && [[ -n "$out" ]] && ! grep -q '^=== Cron diagnostics' <<< "$out"; then ok "$f --help"
    else bad "$f --help (rc=$rc): $(head -n 2 <<< "$out")"; fi
done

section "boxes line up (an emoji takes two columns)"
if command -v python3 >/dev/null 2>&1; then
    bad_boxes="$(python3 - *.sh <<'EOF'
import re, sys, unicodedata
def width(s):
    w = 0
    for ch in s:
        if unicodedata.combining(ch) or ch in '️‍':
            continue
        w += 2 if unicodedata.east_asian_width(ch) in 'WF' or ord(ch) >= 0x1F300 else 1
    return w
for f in sys.argv[1:]:
    for i, line in enumerate(open(f, encoding='utf-8'), 1):
        m = re.search(r'[╔║╚].*[╗║╝]', line)
        if m and width(m.group(0)) != 65:
            print(f'{f}:{i}')
EOF
)"
    check "every box is 65 columns wide${bad_boxes:+ (not: $(tr '\n' ' ' <<< "$bad_boxes"))}" test -z "$bad_boxes"
else
    ok "SKIP: no python3"
fi

section "versions agree"
ver="$(tr -d '[:space:]' < VERSION)"
check "VERSION is semver ($ver)" grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' <<< "$ver"
check "CHANGELOG has [$ver]" grep -q "^## \[$ver\]" CHANGELOG.md
check "README badge shows $ver" grep -q "badge/version-${ver}-" README.md

finish
