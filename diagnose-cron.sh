#!/usr/bin/env bash
# ==============================================================================
# diagnose-cron.sh
# Diagnostic script — shows what setup-cron.sh sees on your system.
# Run it to understand why a false warning about cron may appear.
# ==============================================================================

case "${1:-}" in
    -h|--help)
        echo "Usage: $0"
        echo
        echo "Shows what setup-cron.sh sees about cron on this system: the binary, the process, the systemd"
        echo "units, root's crontab. Run it when setup-cron.sh warns about cron although it is there."
        exit 0 ;;
    "") ;;
    *) echo "Unknown argument: $1 (see --help)" >&2; exit 1 ;;
esac

os="$( . /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}")"
echo "=== Cron diagnostics on $(uname -n) ==="
echo "Date: $(date)"
echo "OS: ${os:-unknown}"
echo

echo "─── 1. Looking for the binary ───"
for cmd_path in /usr/sbin/cron /usr/sbin/crond /usr/bin/cron /usr/bin/crond; do
    if [[ -x "$cmd_path" ]]; then echo "  ✓ Found: $cmd_path"
    else echo "  ✗ Missing: $cmd_path"; fi
done

echo
echo "─── 2. command -v ───"
echo "  PATH=$PATH"
for c in cron crond; do
    if p="$(command -v "$c")"; then echo "  ✓ command -v $c: $p"
    else echo "  ✗ command -v $c found nothing"; fi
done

echo
echo "─── 3. The cron process ───"
for c in cron crond; do
    if pids="$(pgrep -x "$c")"; then echo "  ✓ pgrep -x $c: $(tr '\n' ' ' <<< "$pids")"
    else echo "  ✗ pgrep -x $c found nothing"; fi
done

echo
echo "─── 4. systemctl ───"
if command -v systemctl >/dev/null 2>&1; then
    for u in cron crond cronie; do
        # is-enabled prints "not-found" and fails: take what it printed, "?" only when it printed nothing
        state="$(systemctl is-active "$u" 2>/dev/null)"; enabled="$(systemctl is-enabled "$u" 2>/dev/null)"
        echo "  $u: is-active=${state:-?}, is-enabled=${enabled:-?}"
    done
else
    echo "  (no systemctl)"
fi

echo
echo "─── 5. Processes ───"
procs="$(ps -eo pid,args 2>/dev/null | grep -E '(^|/| )(cron|crond)( |$)' | grep -v -e grep -e diagnose-cron)"
if [[ -n "$procs" ]]; then printf '%s\n' "$procs" | head -5 | sed 's/^/  /'
else echo "  (no cron processes)"; fi

echo
echo "─── 6. root's crontab ───"
if tab="$(crontab -l 2>/dev/null)" && [[ -n "$tab" ]]; then printf '%s\n' "$tab" | grep -v '^#' | head -5 | sed 's/^/  /'
else echo "  (empty or none)"; fi

echo
echo "─── SUMMARY ───"
echo "If step 3 or 5 shows a cron process, or step 4 shows is-active=active,"
echo "setup-cron.sh will NOT warn about installing cron."
echo "If it warns anyway, that is a bug: please report it with this output."
