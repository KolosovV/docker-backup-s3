#!/usr/bin/env bash
# The repository itself: every script parses, LF line endings, executable, English only.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
cd "$REPO" || exit 2

section "bash -n"
for f in *.sh tests/*.sh; do
    check "$f parses" bash -n "$f"
done

section "line endings, executable bit, language"
for f in *.sh tests/*.sh backup.conf.example README.md CHANGELOG.md; do
    if grep -q $'\r' "$f"; then bad "$f has CRLF"; else ok "$f is LF"; fi
done
for f in *.sh tests/*.sh; do
    [[ "$f" == "pre-backup-hook.example.sh" || "$f" == "tests/helpers.sh" ]] && continue
    check "$f is executable" test -x "$f"
done
if grep -lP '[\x{0400}-\x{04FF}]' -- *.sh tests/*.sh backup.conf.example README.md CHANGELOG.md 2>/dev/null; then
    bad "Cyrillic text found (the project is English-only)"
else
    ok "English only"
fi

section "versions agree"
ver="$(tr -d '[:space:]' < VERSION)"
check "VERSION is semver ($ver)" grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' <<< "$ver"
check "CHANGELOG has [$ver]" grep -q "^## \[$ver\]" CHANGELOG.md
check "README badge shows $ver" grep -q "badge/version-${ver}-" README.md

finish
