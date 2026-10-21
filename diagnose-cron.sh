#!/usr/bin/env bash
# ==============================================================================
# diagnose-cron.sh
# Diagnostic script — shows what setup-cron.sh sees on your system.
# Run it to understand why a false warning about cron may appear.
# ==============================================================================

echo "=== Cron diagnostics on $(hostname) ==="
echo "Date: $(date)"
echo "OS: $(lsb_release -ds 2>/dev/null || cat /etc/os-release | head -1)"
echo

echo "─── 1. Looking for the binary ───"
for cmd_path in /usr/sbin/cron /usr/sbin/crond /usr/bin/cron /usr/bin/crond; do
    if [[ -x "$cmd_path" ]]; then
        echo "  ✓ Found: $cmd_path"
        ls -la "$cmd_path"
    else
        echo "  ✗ Missing: $cmd_path"
    fi
done

echo
echo "─── 2. command -v ───"
echo "  PATH=$PATH"
command -v cron && echo "  ✓ command -v cron works" || echo "  ✗ command -v cron found nothing"
command -v crond && echo "  ✓ command -v crond works" || echo "  ✗ command -v crond found nothing"

echo
echo "─── 3. pgrep ───"
pgrep -x cron && echo "  ✓ pgrep -x cron found processes" || echo "  ✗ pgrep -x cron found nothing"
pgrep -x crond && echo "  ✓ pgrep -x crond found" || echo "  ✗ pgrep -x crond found nothing"
pgrep -f '/usr/sbin/cron' && echo "  ✓ pgrep -f /usr/sbin/cron found" || echo "  ✗ pgrep -f /usr/sbin/cron found nothing"

echo
echo "─── 4. systemctl ───"
for u in cron cron.service crond crond.service cronie cronie.service; do
    state=$(systemctl is-active "$u" 2>/dev/null || echo "?")
    enabled=$(systemctl is-enabled "$u" 2>/dev/null || echo "?")
    echo "  $u: is-active=$state, is-enabled=$enabled"
done

echo
echo "─── 5. systemctl list-unit-files ───"
systemctl list-unit-files 2>/dev/null | grep -E "cron|crond|cronie" | head -5 || echo "  (nothing found)"

echo
echo "─── 6. ps ───"
ps -ef 2>/dev/null | grep -E "[c]ron|[c]rond" | head -5 || echo "  (no cron processes found)"

echo
echo "─── 7. service status ───"
service cron status 2>&1 | head -5 || echo "  (service cron does not respond)"

echo
echo "─── 8. crontab ───"
crontab -l 2>&1 | head -3 || echo "  (crontab is empty or unavailable)"

echo
echo "─── SUMMARY ───"
echo "If you see a cron process in step 3 or systemctl is-active=active in step 4,"
echo "then setup-cron.sh will NOT show the warning about installing cron."
echo "If the warning shows up anyway — that's a bug, send this output."
