#!/usr/bin/env bash
# Scheduling on a real init: run as root on a machine (or a container) where systemd is PID 1, with Docker.
#   install.sh -y → the cron service is active and has our job → switch to the systemd timer: it is enabled
#   and has a next run → the service itself makes a real backup → back to cron with "every minute": cron
#   runs a real backup on its own → --remove → uninstall.sh.
# It changes the machine: installs into /opt/docker-backup-s3 and replaces root's crontab entries of its own.
# Run it on a throwaway VM or container (CI does).
set -uo pipefail
IFS=$'\n\t'
export LC_ALL=C.UTF-8
SRC="${DBT_SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
T=/opt/docker-backup-s3
IT="$(mktemp -d "${DBT_WORK:-/tmp}/dbsd.XXXXXX")"; chmod 755 "$IT"
PROJ="sdproj"; PDIR="$IT/srv/$PROJ"
S3C="dbsd-s3-$$"; S3PORT=17080
FAILS=0; PASSES=0
ok()   { PASSES=$((PASSES + 1)); echo "  PASS $*"; }
bad()  { FAILS=$((FAILS + 1)); echo "  FAIL $*"; }
step() { echo; echo "== $*"; }
check() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }
die()  { echo "FATAL: $*"; exit 1; }
cleanup() {
    [[ -f "$PDIR/compose.yaml" ]] && docker compose -p "$PROJ" -f "$PDIR/compose.yaml" down -v >/dev/null 2>&1
    docker rm -f "$S3C" >/dev/null 2>&1
    rm -rf "$IT"
}
trap cleanup EXIT

[[ "$EUID" -eq 0 ]] || die "run as root"
[[ -d /run/systemd/system ]] || die "systemd is not running as init here"
command -v docker >/dev/null 2>&1 || die "docker is not installed"
. /etc/os-release
echo "== ${PRETTY_NAME:-?}, $(systemctl --version | head -1), $(uname -m)"

s3() { AWS_ACCESS_KEY_ID=sdkey AWS_SECRET_ACCESS_KEY=sdsecret AWS_DEFAULT_REGION=us-east-1 \
       AWS_CONFIG_FILE=/dev/null aws --endpoint-url "http://127.0.0.1:${S3PORT}" "$@"; }
backups() { s3 s3 ls "s3://sdbucket/sd/$PROJ/" 2>/dev/null | grep -c 'PRE ' || true; }
cron_unit() { local u; for u in cron crond cronie; do systemctl cat "$u.service" >/dev/null 2>&1 && { echo "$u"; return; }; done; }

step "install.sh -y (with scheduling, as a user would run it)"
if bash "$SRC/install.sh" -y > "$IT/install.log" 2>&1; then ok "install.sh exit 0"
else
    bad "install.sh failed"
    grep -iE 'error|fail|conflict|problem|cannot|scriptlet|trying again|could not' "$IT/install.log" | head -n 40
    tail -n 15 "$IT/install.log"
fi
hash -r
CU="$(cron_unit)"
check "a cron service exists (${CU:-none})" test -n "$CU"
check "cron service is active" systemctl is-active --quiet "$CU"
check "cron service is enabled at boot" systemctl is-enabled --quiet "$CU"
check "our job is in root's crontab" bash -c "crontab -l | grep -q '$T/docker-backup.sh'"

step "S3 and a project to back up"
docker run -d --name "$S3C" --label docker-backup-s3.skip=true -p "127.0.0.1:${S3PORT}:7070" -e ROOT_ACCESS_KEY=sdkey -e ROOT_SECRET_KEY=sdsecret \
    versity/versitygw:v1.8.0 --port=:7070 posix /tmp >/dev/null || die "cannot start versitygw"
for _ in $(seq 1 30); do s3 s3 ls >/dev/null 2>&1 && break; sleep 1; done
s3 s3 mb s3://sdbucket >/dev/null || die "cannot create the bucket"
mkdir -p "$PDIR"
cat > "$PDIR/compose.yaml" <<'EOF'
services:
  app:
    image: alpine:3.20
    command: ["sleep", "infinity"]
    volumes: [data:/data]
volumes:
  data: {}
EOF
docker compose -p "$PROJ" -f "$PDIR/compose.yaml" up -d --quiet-pull >/dev/null 2>&1 || die "compose up failed"
docker compose -p "$PROJ" -f "$PDIR/compose.yaml" exec -T app sh -c 'echo hello > /data/x'
cat >> "$T/backup.conf" <<EOF

# ---- systemd test overrides ----
SCAN_DIRS="$IT/srv"
BACKUP_PREFIX="sd"
WORK_DIR="$IT/work"
MIN_FREE_SPACE_MB=100
PRIMARY_S3_ACCESS_KEY="sdkey"
PRIMARY_S3_SECRET_KEY="sdsecret"
PRIMARY_S3_ENDPOINT="http://127.0.0.1:${S3PORT}"
PRIMARY_S3_REGION="us-east-1"
PRIMARY_S3_BUCKET="sdbucket"
PRIMARY_S3_ADDRESSING_STYLE="path"
EOF
ok "S3 up, project up, config filled in"

step "systemd timer"
if "$T/setup-cron.sh" -y -m systemd -s daily > "$IT/timer.log" 2>&1; then ok "setup-cron.sh -m systemd exit 0"
else bad "setup-cron.sh -m systemd failed"; tail -n 20 "$IT/timer.log"; fi
check "the cron job was replaced (gone)" bash -c "! crontab -l 2>/dev/null | grep -q docker-backup-s3"
check "the timer is enabled" systemctl is-enabled --quiet docker-backup.timer
check "the timer is active" systemctl is-active --quiet docker-backup.timer
next="$(systemctl show -p NextElapseUSecRealtime --value docker-backup.timer 2>/dev/null)"
check "the timer has a next run (${next:-none})" test -n "$next"
check "the restore-check timer came along (install.sh set a weekly check)" systemctl is-enabled --quiet docker-backup-verify.timer
check "and is active" systemctl is-active --quiet docker-backup-verify.timer
check "weekly, Sunday 06:00" grep -qx 'OnCalendar=Sun \*-\*-\* 06:00:00' /etc/systemd/system/docker-backup-verify.timer
verify_out="$(systemd-analyze verify /etc/systemd/system/docker-backup{,-verify}.service /etc/systemd/system/docker-backup{,-verify}.timer 2>&1 \
    | grep -v '^$' | grep -vi 'docker.service\|network-online' | grep -iE 'docker-backup(-verify)?\.(service|timer)' \
    | grep -iE 'error|warn|fail|invalid|unknown|ignor|bad|not' || true)"
if [[ -z "$verify_out" ]]; then ok "systemd-analyze verify: nothing about our units"
else bad "systemd-analyze verify complains"; printf '    %s\n' "$verify_out" | head -n 10; fi

step "the service makes a real backup"
before="$(backups)"
: > /var/log/docker-backup-cron.log
if timeout 300 systemctl start docker-backup.service; then ok "systemctl start docker-backup.service"
else bad "the service failed"; systemctl status docker-backup.service --no-pager -l 2>&1 | tail -n 15; fi
check "Result=success" test "$(systemctl show -p Result --value docker-backup.service)" == success
grep -q "Result=success" <(systemctl show -p Result docker-backup.service) || tail -n 25 /var/log/docker-backup-cron.log
check "a new backup in S3 ($before → $(backups))" test "$(backups)" -gt "$before"
check "the service wrote its log" grep -q "$PROJ" /var/log/docker-backup-cron.log
grep -q "$PROJ" /var/log/docker-backup-cron.log || { ls -la /var/log/docker-backup*; tail -n 5 /var/log/docker-backup-cron.log; journalctl -u docker-backup.service --no-pager -n 15; }
check "the S3 container was left out by its label" grep -q "Skipped (label docker-backup-s3.skip=true): $S3C" /var/log/docker-backup-cron.log

step "the restore-check service checks it"
if timeout 300 systemctl start docker-backup-verify.service; then ok "systemctl start docker-backup-verify.service"
else bad "the check failed"; systemctl status docker-backup-verify.service --no-pager -l 2>&1 | tail -n 15; tail -n 25 /var/log/docker-backup-cron.log; fi
check "Result=success" test "$(systemctl show -p Result --value docker-backup-verify.service)" == success
check "it wrote ALL CHECKS PASSED to the cron log" grep -q "ALL CHECKS PASSED" /var/log/docker-backup-cron.log
check "and to the backup log" grep -q "ALL CHECKS PASSED" /var/log/docker-backup.log
check "last-verify.json says ok" test "$(jq -r .ok /var/lib/docker-backup/last-verify.json 2>/dev/null)" == true
"$T/status.sh" > "$IT/status-verify.out" 2>&1 || true
check "status shows the timer and the last check" bash -c 'grep -q "Restore check: timer" "$1" && grep -q "Last check: .* restore (primary)" "$1"' _ "$IT/status-verify.out"

step "cron runs a real backup on its own"
if "$T/setup-cron.sh" -y -m cron -s '* * * * *' > "$IT/cron.log" 2>&1; then ok "setup-cron.sh -m cron exit 0"
else bad "setup-cron.sh -m cron failed"; tail -n 20 "$IT/cron.log"; fi
check "the timer was replaced (gone)" bash -c '! systemctl is-enabled --quiet docker-backup.timer'
check "the restore-check timer too" test ! -e /etc/systemd/system/docker-backup-verify.timer
check "the check moved to cron, weekly" bash -c 'crontab -l | grep -F "$1/verify-restore.sh" | grep -q "^0 6 \* \* 0 "' _ "$T"
before="$(backups)"
# A backup timestamp has seconds, so two runs in a row never collide; give cron up to 3 minutes
for _ in $(seq 1 36); do (( $(backups) > before )) && break; sleep 5; done
if (( $(backups) > before )); then ok "cron started a backup by itself ($before → $(backups))"
elif journalctl -u "$CU" --no-pager 2>/dev/null | grep -q 'FAILED to authorize user with PAM'; then
    # The environment, not docker-backup-s3: this crond refuses ANY job of root. Seen now and then in GitHub's
    # containers of the RHEL family; the same images pass elsewhere, and the real VM test covers cron firing.
    # Our job being in the crontab is checked above.
    echo "  SKIP cron firing: crond in this container refuses every root job (PAM) — a limit of the container"
else
    bad "cron did not run the backup in 3 minutes"
    tail -n 20 /var/log/docker-backup-cron.log 2>/dev/null; journalctl -u "$CU" --no-pager -n 20 2>/dev/null
    echo "--- PAM and the account cron runs as:"
    getent passwd root; ls -l /etc/shadow; command -v authselect >/dev/null && authselect current
    cat /etc/pam.d/crond 2>/dev/null; journalctl --no-pager -n 30 -g 'pam|PAM' 2>/dev/null | tail -n 15
fi

step "removal"
"$T/setup-cron.sh" --remove -y > "$IT/remove.log" 2>&1
# A run cron started just before is still going: uninstall.sh rightly refuses to remove during a backup
for _ in $(seq 1 60); do pgrep -f "$T/docker-backup.sh" >/dev/null || break; sleep 2; done
check "no cron job left" bash -c '! crontab -l 2>/dev/null | grep -q docker-backup-s3'
check "no timer left" test ! -e /etc/systemd/system/docker-backup.timer
check "no restore-check timer left" test ! -e /etc/systemd/system/docker-backup-verify.timer
if bash "$T/uninstall.sh" -y > "$IT/uninstall.log" 2>&1; then ok "uninstall.sh exit 0"; else bad "uninstall.sh failed"; tail -n 20 "$IT/uninstall.log"; fi
check "the installation is gone" test ! -e "$T/docker-backup.sh"
[[ -e "$T/docker-backup.sh" ]] && tail -n 25 "$IT/uninstall.log"
check "the docker-backup-s3 command is gone" test ! -e /usr/local/bin/docker-backup-s3

echo
echo "${PASSES} passed, ${FAILS} failed"
(( FAILS == 0 ))
