#!/usr/bin/env bash
# The check for one distro, as root inside its container (see run.sh): install, tools, scheduling, tests.
set -uo pipefail
IFS=$'\n\t'
. /etc/os-release
echo "== ${DBT_IMAGE:-?}: ${PRETTY_NAME:-unknown}, bash ${BASH_VERSION}"
FAILS=0
# Full logs stay in <the shared folder>/dbt-logs/<image>/ on the host for a look after a failure
LOGS="${DBT_WORK:-/tmp}/dbt-logs/$(tr '/: ()' '_____' <<< "${DBT_IMAGE:-local}")"
rm -rf "$LOGS"; mkdir -p "$LOGS"
ok()  { echo "  PASS $*"; }
bad() { echo "  FAIL $*"; FAILS=$((FAILS + 1)); }
check() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }

# The package manager — only for what the tests themselves need (python3) and what a server normally has
# (Docker is not the installer's job). Everything the scripts need, install.sh must install itself.
pm_install() {
    if   command -v apt-get >/dev/null 2>&1; then apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1
    elif command -v dnf     >/dev/null 2>&1; then dnf install -y -q "$@" >/dev/null 2>&1
    elif command -v yum     >/dev/null 2>&1; then yum install -y -q "$@" >/dev/null 2>&1
    elif command -v zypper  >/dev/null 2>&1; then zypper --non-interactive -q install -y "$@" >/dev/null 2>&1
    elif command -v pacman  >/dev/null 2>&1; then pacman -Sy --noconfirm --needed "$@" >/dev/null 2>&1
    elif command -v apk     >/dev/null 2>&1; then apk add --no-cache -q "$@" >/dev/null 2>&1
    fi
}

# Docker CLI from the host's static build (a server has Docker before it has backups)
mkdir -p /usr/local/bin /usr/local/lib/docker/cli-plugins
ln -sf /dbt-tools/docker /usr/local/bin/docker
ln -sf /dbt-tools/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose
export PATH="/usr/local/bin:$PATH"

echo "-- install.sh -y"
if bash /src/install.sh -y --no-cron --skip-validate > "$LOGS/install.log" 2>&1; then ok "install.sh exit 0"
else bad "install.sh failed"; tail -n 40 "$LOGS/install.log"; fi
grep -E '⚠|❌|WARN|ERROR' "$LOGS/install.log" | sed 's/^/    install: /' | head -20
hash -r
T=/opt/docker-backup-s3

echo "-- what the scripts need"
for c in bash jq tar gzip curl gpg crontab whiptail docker aws flock base64 sha256sum mktemp find awk sed grep date stat; do
    check "$c is installed" command -v "$c"
done
check "aws is v2 ($(aws --version 2>&1 | head -1))" bash -c 'aws --version 2>&1 | grep -q "aws-cli/2\."'
check "GNU date (date -d)" date -d '24 hours ago' +%s
check "GNU stat (stat -c)" stat -c %s /etc/os-release
check "the docker-backup-s3 command" "$T/menu.sh" version
check "backup.conf with mode 600" test "$(stat -c %a "$T/backup.conf")" = 600

echo "-- setup-cron.sh"
if "$T/setup-cron.sh" -y -m cron -s daily > "$LOGS/cron.log" 2>&1 && crontab -l 2>/dev/null | grep -q "$T/docker-backup.sh"; then
    ok "a cron job is installed"
else
    bad "no cron job"; tail -n 15 "$LOGS/cron.log"
fi
if crontab -l 2>/dev/null | grep -qF "$T/verify-restore.sh"; then ok "the restore check is scheduled next to it"
else bad "no restore check in the crontab"; crontab -l 2>/dev/null | tail -n 5; fi
if "$T/setup-cron.sh" --remove -y > "$LOGS/cron-remove.log" 2>&1 && ! crontab -l 2>/dev/null | grep -q "docker-backup-s3"; then
    ok "and removed"
else
    bad "the cron job was not removed"; tail -n 15 "$LOGS/cron-remove.log"
fi

echo "-- tests"
if command -v python3 >/dev/null 2>&1 || pm_install python3 || pm_install python; then :; fi
if bash /src/tests/run.sh > "$LOGS/unit.log" 2>&1; then ok "tests/run.sh"
else bad "tests/run.sh"; grep -E 'FAIL|^==|Missing' "$LOGS/unit.log" | head -30; fi

echo "-- integration (the host's Docker)"
if bash /src/tests/integration/run.sh > "$LOGS/integration.log" 2>&1; then ok "tests/integration/run.sh ($(grep -o '[0-9]* passed, [0-9]* failed' "$LOGS/integration.log" | tail -1))"
else bad "tests/integration/run.sh"; grep -E 'FAIL|FATAL' -A12 "$LOGS/integration.log" | head -60; fi

echo "== ${DBT_IMAGE:-?}: ${FAILS} failed"
(( FAILS == 0 ))
