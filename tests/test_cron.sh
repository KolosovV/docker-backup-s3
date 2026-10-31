#!/usr/bin/env bash
# setup-cron.sh with cron: the backup job, the restore check next to it, what -y keeps and replaces,
# -v alone, the admin's own lines. crontab and systemctl are stubs; the real cron and the systemd
# timers are run by tests/systemd and tests/distros. setup-cron.sh needs root.
if [[ "$EUID" -ne 0 ]]; then
    if sudo -n true 2>/dev/null; then exec sudo -E env "PATH=$PATH" bash "$0" "$@"; fi
    echo "   SKIP: setup-cron.sh needs root (run as root, or with passwordless sudo)"
    exit 0
fi
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

mkdir -p "$W/bin" "$W/logrotate.d"
export CRONTAB_FILE="$W/crontab" LOGROTATE_DIR="$W/logrotate.d"
cat > "$W/bin/crontab" <<'EOF'
#!/bin/sh
case "$1" in
    -l) [ -s "$CRONTAB_FILE" ] && exec cat "$CRONTAB_FILE"; echo "no crontab for root" >&2; exit 1 ;;
    # Read it all, then replace — as the real one does: in "crontab -l | … | crontab -" both run at once
    -)  cat > "$CRONTAB_FILE.new" && mv "$CRONTAB_FILE.new" "$CRONTAB_FILE" ;;
esac
EOF
printf '#!/bin/sh\nexit 1\n' > "$W/bin/systemctl"
printf '#!/bin/sh\nexit 0\n' > "$W/bin/pgrep"   # "cron is running"
chmod +x "$W/bin/crontab" "$W/bin/systemctl" "$W/bin/pgrep"
export PATH="$W/bin:$PATH"

B="$REPO/docker-backup.sh"; V="$REPO/verify-restore.sh"
cron() { "$REPO/setup-cron.sh" "$@" > "$W/out" 2>&1; }
backup_at() { grep -F "$B" "$CRONTAB_FILE" | awk '{print $1, $2, $3, $4, $5}'; }
verify_at() {   # the check in our block
    sed -n '/^# === Docker backup ===/,/^# === \/Docker backup ===/p' "$CRONTAB_FILE" | grep -F "$V" | awk '{print $1, $2, $3, $4, $5}'
}
OWN_VERIFY="0 4 * * 0 $V --quick >> /var/log/my-verify.log 2>&1"

section "a new setup"
printf '5 5 * * * /usr/local/bin/my-own-job\n%s\n' "$OWN_VERIFY" > "$CRONTAB_FILE"
cron -y -m cron -s daily
check "exit 0" test $? -eq 0
check "the backup at 03:00" test "$(backup_at)" == "0 3 * * *"
check "the restore check weekly, Sunday 06:00" test "$(verify_at)" == "0 6 * * 0"
check "both inside our block" bash -c 'sed -n "/^# === Docker backup ===/,/^# === \/Docker backup ===/p" "$1" | grep -c -e "$2" -e "$3" | grep -qx 2' _ "$CRONTAB_FILE" "$B" "$V"
check "the check goes to the cron log" grep -qF "$V >> /var/log/docker-backup-cron.log 2>&1" "$CRONTAB_FILE"
check "the admin's own line is kept" grep -qx '5 5 \* \* \* /usr/local/bin/my-own-job' "$CRONTAB_FILE"
check "and their own verify-restore.sh line too, as it was" grep -qxF "$OWN_VERIFY" "$CRONTAB_FILE"
check "logrotate set up in the folder given" test -f "$W/logrotate.d/docker-backup"

section "-y without -v keeps the check"
cron -y -m cron -s twice
check "the backup changed" test "$(backup_at)" == "0 4,16 * * *"
check "the check stayed" test "$(verify_at)" == "0 6 * * 0"
check "one block, not two" test "$(grep -c '^# === Docker backup ===' "$CRONTAB_FILE")" == 1

section "-v alone changes only the check"
cron -v '30 5 * * *' -y
check "exit 0" test $? -eq 0
check "the check is daily at 05:30" test "$(verify_at)" == "30 5 * * *"
check "the backup kept its schedule" test "$(backup_at)" == "0 4,16 * * *"
check "it says so" grep -q 'Only the restore check changes; the backups keep cron: 0 4,16 \* \* \*' "$W/out"
cron -v daily -y
check "a preset: every day at 06:00" test "$(verify_at)" == "0 6 * * *"

section "-v off, and a setup without a check stays without"
cron -v off -y
check "no check line" test -z "$(verify_at)"
check "the backup is still there" test "$(backup_at)" == "0 4,16 * * *"
cron -y -m cron -s daily
check "-y without -v does not add one back" test -z "$(verify_at)"

section "a wrong schedule changes nothing"
cron -v weekly -y
before="$(cat "$CRONTAB_FILE")"
cron -v '1 2 3' -y
check "it fails" test $? -ne 0
check "and says why" grep -q "Invalid cron format for the restore check: '1 2 3'" "$W/out"
check "the crontab is as it was" test "$(cat "$CRONTAB_FILE")" == "$before"

section "--status"
cron --status
check "it shows the check" grep -q 'Restore check (cron):' "$W/out"
check "and its line" grep -qF "$V" "$W/out"

section "--remove"
cron --remove -y
check "our lines are gone" bash -c '! grep -qe "$2" -e "Docker backup" "$1" && [[ $(grep -cF "$3" "$1") == 1 ]]' _ "$CRONTAB_FILE" "$B" "$V"
check "the admin's own lines are kept" bash -c 'grep -qx "5 5 \* \* \* /usr/local/bin/my-own-job" "$1" && grep -qxF "$2" "$1"' _ "$CRONTAB_FILE" "$OWN_VERIFY"

finish
