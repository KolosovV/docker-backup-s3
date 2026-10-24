#!/usr/bin/env bash
# The README's minimal backup.conf (the primary storage and SCAN_DIRS, nothing else) — every other option missing,
# as in a config written by hand or kept from an older version. Every script must run with it: under set -u a
# missing option used without a default is "unbound variable". docker and aws are stubs; the storage is empty.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

mkdir -p "$W/bin" "$W/p"
printf '#!/bin/sh\ncase "$1" in --version) echo "Docker version 27.5.1" ;; compose) echo "Docker Compose version v2.30.0" ;; esac\nexit 0\n' > "$W/bin/docker"
printf '#!/bin/sh\ncase "$1" in --version) echo "aws-cli/2.30.0 Python/3.13" ;; esac\nexit 0\n' > "$W/bin/aws"
printf '#!/bin/sh\nexit 0\n' > "$W/bin/crontab"
chmod +x "$W/bin/docker" "$W/bin/aws" "$W/bin/crontab"
export PATH="$W/bin:$PATH"

CONF="$W/backup.conf"
cat > "$CONF" <<EOF
PRIMARY_S3_ACCESS_KEY="AKIATESTKEY"
PRIMARY_S3_SECRET_KEY="s3cret"
PRIMARY_S3_ENDPOINT="https://s3.example.test"
PRIMARY_S3_REGION="us-east-1"
PRIMARY_S3_BUCKET="bucket"
SCAN_DIRS="$W/p"
EOF
# The default paths (/var/log, /var/tmp, /var/run, /var/lib) are used as they are only where writing there is
# harmless: as root in a throwaway container or CI. Elsewhere they go to the temp folder.
if [[ "$EUID" -ne 0 || ( ! -f /.dockerenv && -z "${CI:-}" ) ]]; then
    cat >> "$CONF" <<EOF
WORK_DIR="$W/work"
LOG_FILE="$W/backup.log"
LOCK_FILE="$W/backup.lock"
LAST_RUN_FILE="$W/last-run.json"
EOF
fi
chmod 600 "$CONF"

# run <name> <script> <args…> — the output in $W/<name>.out; stdin closed, no questions can hang it
run() { local n="$1" s="$2"; shift 2; timeout 120 bash "$REPO/$s" "$@" < /dev/null > "$W/$n.out" 2>&1; echo "$?" > "$W/$n.rc"; }
clean() {   # clean <name> — no "unbound variable" (or other bash error) in its output
    if grep -qE 'unbound variable|syntax error|command not found|bad substitution' "$W/$1.out"; then
        bad "$1: $(grep -m1 -E 'unbound variable|syntax error|command not found|bad substitution' "$W/$1.out")"
    else ok "$1: no bash error"; fi
}

section "every script with the minimal config"
run backup-dry  docker-backup.sh -c "$CONF" -n;        clean backup-dry
check "the dry run gets to its plan" grep -q 'DRY-RUN END' "$W/backup-dry.out"
# Leftovers of runs killed with -9 or by a reboot, in the work folder
WD="$(bash -c 'source "$1"; source "$2/lib.sh"; printf %s "$WORK_DIR"' _ "$CONF" "$REPO" 2>/dev/null)"
mkdir -p "$WD/2026-10-21_23-21-38/app" "$WD/restore.old1" "$WD/restore.new1" "$WD/mine"
echo archive > "$WD/2026-10-21_23-21-38/app/x.tar.gz"; touch -d '2 days ago' "$WD/restore.old1"
run backup      docker-backup.sh -c "$CONF";           clean backup
check "a backup removes the work folder of an unfinished run" test ! -e "$WD/2026-10-21_23-21-38"
check "and says so" grep -q 'Removing the work folder of an unfinished run' "$W/backup.out"
check "a restore folder older than a day goes" test ! -e "$WD/restore.old1"
check "a fresh one stays (a restore may be running)" test -d "$WD/restore.new1"
check "a folder it did not make stays" test -d "$WD/mine"
rm -rf "$WD/restore.new1" "$WD/mine"
run backup-list docker-backup.sh -c "$CONF" --list;    clean backup-list
run validate    validate-config.sh -c "$CONF";         clean validate
run status      status.sh -c "$CONF";                  clean status
run verify      verify-restore.sh -c "$CONF" --quick --no-notify; clean verify
run restore     docker-restore.sh -c "$CONF" --list;   clean restore
run sync        sync-s3.sh -c "$CONF" --dry-run;       clean sync
run logs        logs.sh -c "$CONF" -n 20;              clean logs
run logs-err    logs.sh -c "$CONF" --errors;           clean logs-err
run diagnose    diagnose-s3.sh -c "$CONF";             clean diagnose
run drop        drop-project.sh -c "$CONF" -y nothing-here; clean drop
section "docker-restore.sh --list -p with several projects"
# A storage with two projects. aws --output text answers "None" to a listing with nothing in it — as for a
# project name that does not exist; the script must not take it for a date or a size.
mkdir -p "$W/bin2"
cat > "$W/bin2/aws" <<'STUB'
#!/bin/sh
case "$*" in
    *--version*) echo "aws-cli/2.30.0 Python/3.13" ;;
    *"--prefix backups/app/2026-10-23_21-15-10/"*) echo 2097152 ;;
    *"--prefix backups/web/2026-10-22_21-15-10/"*) echo 1048576 ;;
    *"--prefix backups/app/"*) printf 'backups/app/2026-10-23_21-15-10/\n' ;;
    *"--prefix backups/web/"*) printf 'backups/web/2026-10-22_21-15-10/\n' ;;
    *"--prefix backups/ "*) printf 'backups/app/\tbackups/web/\n' ;;
    *list-objects-v2*) echo None ;;
esac
exit 0
STUB
chmod +x "$W/bin2/aws"
PATH="$W/bin2:$PATH" run list-two docker-restore.sh -c "$CONF" --list -p app,web; clean list-two
check "--list -p app,web: a table for app"  grep -q "Backups of project 'app'" "$W/list-two.out"
check "--list -p app,web: a table for web"  grep -q "Backups of project 'web'" "$W/list-two.out"
check "--list -p app,web: app's date and size" grep -qE '2026-10-23_21-15-10 .* 2 MB' "$W/list-two.out"
check "--list -p app,web: web's date and size" grep -qE '2026-10-22_21-15-10 .* 1 MB' "$W/list-two.out"
PATH="$W/bin2:$PATH" run list-none docker-restore.sh -c "$CONF" --list -p nothing-here; clean list-none
check "--list -p <unknown>: says there is no such project" grep -q "No project 'nothing-here'" "$W/list-none.out"
check "--list -p <unknown>: and names the ones there are" grep -q 'Projects there: app, web' "$W/list-none.out"
check "--list -p <unknown>: not a date called None" bash -c '! grep -q None "$1"' _ "$W/list-none.out"
check "--list -p <unknown>: exit 0" test "$(cat "$W/list-none.rc")" = 0

if [[ "$EUID" -eq 0 ]]; then
    printf '12\n' > "$W/answers"
    UI_PLAIN=true UI_TTY="$W/answers" timeout 60 bash "$REPO/menu.sh" -c "$CONF" < /dev/null > "$W/menu.out" 2>&1
    clean menu
fi

finish
