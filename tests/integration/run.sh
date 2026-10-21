#!/usr/bin/env bash
# Integration test with real Docker and a real S3 (Versity Gateway in a container):
#   a compose project (Postgres + named volumes + bind mounts, one of them next to the project folder)
#   → validate-config → backup (encrypted, to the primary) → contents → verify-restore
#   → sync to the secondary → the project is wiped out → restore from the secondary → the data is compared
#   → a failed run (S3 down) must fail and notify.
# Notifications go to a local webhook receiver and are checked too.
#
# Needs: root (or passwordless sudo), docker with compose v2, aws cli v2, jq, python3, gpg.
# Leaves nothing behind: its containers, volumes, network and files are removed on exit.
# usage: tests/integration/run.sh [-k]   (-k keeps everything for a look, prints where)
if [[ "$EUID" -ne 0 ]]; then
    exec sudo -E env "PATH=$PATH" bash "$0" "$@"
fi
set -uo pipefail
IFS=$'\n\t'
export LC_ALL=C.UTF-8

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KEEP=false; [[ "${1:-}" == "-k" ]] && KEEP=true
IT="$(mktemp -d /tmp/dbit.XXXXXX)"
chmod 755 "$IT"
PROJ="itproj"
PDIR="$IT/srv/$PROJ"
EXT="$IT/srv/${PROJ}-ext"          # a bind mount NEXT TO the project folder (the 1.0.1 fix)
S3C="dbit-s3-$$"
S3PORT=17070
HOOKPORT=17071
CONF="$IT/backup.conf"
FAILS=0; PASSES=0

ok()   { PASSES=$((PASSES + 1)); echo "  PASS $*"; }
bad()  { FAILS=$((FAILS + 1)); echo "  FAIL $*"; }
step() { echo; echo "== $*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
die()  { echo "FATAL: $*"; exit 1; }

cleanup() {
    if $KEEP; then echo "Kept: $IT, container $S3C"; return; fi
    [[ -f "$PDIR/compose.yaml" ]] && docker compose -p "$PROJ" -f "$PDIR/compose.yaml" down -v --remove-orphans >/dev/null 2>&1
    docker rm -f "$S3C" >/dev/null 2>&1
    docker volume rm -f "${PROJ}_pgdata" "${PROJ}_appdata" >/dev/null 2>&1
    [[ -n "${HOOK_PID:-}" ]] && kill "$HOOK_PID" 2>/dev/null
    rm -rf "$IT"
}
trap cleanup EXIT

for c in docker aws jq python3 gpg; do command -v "$c" >/dev/null 2>&1 || die "$c is not installed"; done
docker compose version >/dev/null 2>&1 || die "docker compose v2 is not installed"

s3() { AWS_ACCESS_KEY_ID=itkey AWS_SECRET_ACCESS_KEY=itsecret AWS_DEFAULT_REGION=us-east-1 \
       AWS_CONFIG_FILE=/dev/null aws --endpoint-url "http://127.0.0.1:${S3PORT}" "$@"; }
psql_q() { docker compose -p "$PROJ" -f "$PDIR/compose.yaml" exec -T db psql -U postgres -d itdb -tAc "$1"; }
app_sh() { docker compose -p "$PROJ" -f "$PDIR/compose.yaml" exec -T app sh -c "$1"; }
wait_pg() {
    local _
    for _ in $(seq 1 60); do
        psql_q 'select 1' >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}
# The project's data in one line per item, to compare before and after.
fingerprint() {
    echo "db: $(psql_q "select count(*) || ':' || md5(string_agg(v, ',' order by id)) from t")"
    echo "appdata: $(app_sh 'cd /data && sha256sum big.bin note.txt')"
    echo "files: $(app_sh 'cd /files && sha256sum a.txt sub/b.txt')"
    echo "ext: $(app_sh 'cat /ext/ext.txt')"
    echo "projdir: $(sha256sum "$PDIR/.env" | cut -d' ' -f1)"
}
hook_msgs() { cat "$IT/hook.log" 2>/dev/null; }
run() {   # run <log name> <script> [args] — the script's output goes to a file, the exit code is returned
    local name="$1" script="$2"; shift 2
    "$REPO/$script" "$@" > "$IT/$name.out" 2>&1
}
show_tail() { echo "---- last lines of $1:"; tail -n 25 "$IT/$1.out"; echo "----"; }

# ------------------------------------------------------------------------------
step "S3 (Versity Gateway) and the webhook receiver"
docker run -d --name "$S3C" -p "127.0.0.1:${S3PORT}:7070" \
    -e ROOT_ACCESS_KEY=itkey -e ROOT_SECRET_KEY=itsecret \
    versity/versitygw:v1.8.0 --port=:7070 posix /tmp >/dev/null || die "cannot start versitygw"
for _ in $(seq 1 30); do s3 s3 ls >/dev/null 2>&1 && break; sleep 1; done
s3 s3 mb s3://primary >/dev/null && s3 s3 mb s3://secondary >/dev/null || die "cannot create the buckets"
ok "buckets primary and secondary"

cat > "$IT/hook.py" <<'PY'
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        with open(sys.argv[2], 'a', encoding='utf-8') as f:
            d = json.loads(body)
            f.write(d['level'] + '|' + d['title'] + '|' + d['details'].replace('\n', ' / ') + '\n')
        self.send_response(204); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PY
python3 "$IT/hook.py" "$HOOKPORT" "$IT/hook.log" &
HOOK_PID=$!

# ------------------------------------------------------------------------------
step "The compose project"
mkdir -p "$PDIR/files/sub" "$EXT"
cat > "$PDIR/compose.yaml" <<EOF
services:
  db:
    image: postgres:17-alpine
    environment:
      POSTGRES_PASSWORD: itpass
      POSTGRES_DB: itdb
    volumes:
      - pgdata:/var/lib/postgresql/data
  app:
    image: alpine:3.20
    command: ["sleep", "infinity"]
    volumes:
      - appdata:/data
      - ./files:/files
      - ${EXT}:/ext
volumes:
  pgdata: {}
  appdata: {}
EOF
printf 'SECRET_SETTING=%s\n' "$RANDOM$RANDOM" > "$PDIR/.env"
echo "alpha $RANDOM" > "$PDIR/files/a.txt"
echo "beta $RANDOM" > "$PDIR/files/sub/b.txt"
echo "outside the project folder $RANDOM" > "$EXT/ext.txt"
docker compose -p "$PROJ" -f "$PDIR/compose.yaml" up -d --quiet-pull >/dev/null 2>&1 || die "compose up failed"
wait_pg || die "Postgres did not start"
psql_q "create table t(id int primary key, v text); insert into t select g, md5(g::text) from generate_series(1, 5000) g;" >/dev/null
app_sh 'head -c 3000000 /dev/urandom > /data/big.bin; echo note > /data/note.txt'
fingerprint > "$IT/before.txt"
cat "$IT/before.txt"
ok "project up with data"

# ------------------------------------------------------------------------------
step "Config"
head -c 32 /dev/urandom | base64 > "$IT/pass"; chmod 600 "$IT/pass"
cp "$REPO/backup.conf.example" "$CONF"
cat >> "$CONF" <<EOF

# ---- integration test overrides ----
SCAN_DIRS="$IT/srv"
BACKUP_PREFIX="it"
WORK_DIR="$IT/work"
LOG_FILE="$IT/backup.log"
LOCK_FILE="$IT/lock"
LAST_RUN_FILE="$IT/last-run.json"
MIN_FREE_SPACE_MB=100
ENCRYPT_BACKUPS="true"
GPG_PASSPHRASE_FILE="$IT/pass"
NOTIFY_ON="always"
NOTIFY_NAME="it-host"
NOTIFY_WEBHOOK_URL="http://127.0.0.1:${HOOKPORT}/hook"
NOTIFY_WEBHOOK_FORMAT="json"
PRIMARY_S3_ACCESS_KEY="itkey"
PRIMARY_S3_SECRET_KEY="itsecret"
PRIMARY_S3_ENDPOINT="http://127.0.0.1:${S3PORT}"
PRIMARY_S3_REGION="us-east-1"
PRIMARY_S3_BUCKET="primary"
PRIMARY_S3_ADDRESSING_STYLE="path"
SECONDARY_S3_ENABLED="false"
SECONDARY_S3_ACCESS_KEY="itkey"
SECONDARY_S3_SECRET_KEY="itsecret"
SECONDARY_S3_ENDPOINT="http://127.0.0.1:${S3PORT}"
SECONDARY_S3_REGION="us-east-1"
SECONDARY_S3_BUCKET="secondary"
SECONDARY_S3_ADDRESSING_STYLE="path"
EOF
chmod 600 "$CONF"
if run validate validate-config.sh -c "$CONF"; then ok "validate-config passes"; else bad "validate-config failed"; show_tail validate; fi

# ------------------------------------------------------------------------------
step "Backup"
if run backup docker-backup.sh -c "$CONF" -p "$PROJ"; then ok "docker-backup.sh exit 0"; else bad "docker-backup.sh failed"; show_tail backup; fi
s3 s3 ls --recursive "s3://primary/it/$PROJ/" > "$IT/primary.ls" 2>/dev/null
cat "$IT/primary.ls"
TS="$(awk '{print $4}' "$IT/primary.ls" | cut -d/ -f3 | sort -u | tail -n 1)"
check "a timestamped backup in the primary ($TS)" test -n "$TS"
check "the archive is encrypted (.gpg)" grep -q "${PROJ}.*\.tar\.gz\.gpg$" "$IT/primary.ls"
check "a sha256 manifest next to it" grep -q '\.sha256$' "$IT/primary.ls"
check "the secondary got nothing (disabled)" test -z "$(s3 s3 ls --recursive s3://secondary/ 2>/dev/null)"
check "webhook: backup done" grep -q '^success|backup done|' <<< "$(hook_msgs)"
check "the containers run again after the backup" test "$(docker compose -p "$PROJ" -f "$PDIR/compose.yaml" ps -q --status running | wc -l)" -eq 2

step "What is inside"
if run contents docker-restore.sh -c "$CONF" -p "$PROJ" -t "$TS" --contents -y; then ok "--contents exit 0"; else bad "--contents failed"; show_tail contents; fi
check "the Postgres volume is in it" grep -q "${PROJ}_pgdata" "$IT/contents.out"
check "the app volume is in it" grep -q "${PROJ}_appdata" "$IT/contents.out"
check "a Postgres dump is in it" grep -qi 'itdb\|postgres.*\.sql' "$IT/contents.out"
check "the bind mount next to the project folder is in it" grep -q "${PROJ}_ext\|${PROJ}-ext" "$IT/contents.out"

step "verify-restore"
if run verify verify-restore.sh -c "$CONF" -p "$PROJ"; then ok "verify-restore exit 0"; else bad "verify-restore failed"; show_tail verify; fi
check "webhook: backups restore fine" grep -q '^success|backups restore fine|' <<< "$(hook_msgs)"

# ------------------------------------------------------------------------------
step "Sync to the secondary"
echo 'SECONDARY_S3_ENABLED="true"' >> "$CONF"
if run sync sync-s3.sh -c "$CONF" -y; then ok "sync-s3.sh exit 0"; else bad "sync-s3.sh failed"; show_tail sync; fi
s3 s3 ls --recursive "s3://secondary/it/$PROJ/" > "$IT/secondary.ls" 2>/dev/null
check "the secondary has the same objects and sizes" test "$(awk '{print $3, $4}' "$IT/primary.ls" | sort)" == "$(awk '{print $3, $4}' "$IT/secondary.ls" | sort)"
check "webhook: storages synchronized" grep -q '^success|storages synchronized|' <<< "$(hook_msgs)"
if run sync2 sync-s3.sh -c "$CONF" -y && grep -q 'already in sync' "$IT/sync2.out"; then ok "a second sync copies nothing"
else bad "the second sync was not a no-op"; show_tail sync2; fi

# ------------------------------------------------------------------------------
step "Disaster: the project, its volumes and folders are gone"
docker compose -p "$PROJ" -f "$PDIR/compose.yaml" down -v >/dev/null 2>&1
rm -rf "$PDIR" "$EXT"
check "the volumes are gone" test -z "$(docker volume ls -q --filter "name=${PROJ}_")"

step "Restore from the secondary"
if run restore docker-restore.sh -c "$CONF" -p "$PROJ" -t "$TS" --from secondary -y; then ok "docker-restore.sh exit 0"
else bad "docker-restore.sh failed"; show_tail restore; fi
check "compose.yaml is back" test -f "$PDIR/compose.yaml"
if wait_pg; then ok "Postgres is up after the restore"; else bad "Postgres did not come up"; show_tail restore; fi
fingerprint > "$IT/after.txt" 2>&1
if [[ "$(cat "$IT/before.txt")" == "$(cat "$IT/after.txt")" ]]; then ok "the data matches: database, volume, bind mounts, project folder"
else bad "the data differs"; echo "--- before:"; cat "$IT/before.txt"; echo "--- after:"; cat "$IT/after.txt"; fi

# ------------------------------------------------------------------------------
step "A failed run: the primary S3 is down"
docker stop "$S3C" >/dev/null
if run fail docker-backup.sh -c "$CONF" -p "$PROJ"; then bad "the backup reported success with S3 down"
else ok "the backup fails with S3 down"; fi
check "webhook: backup did not start" grep -q '^error|backup did not start|' <<< "$(hook_msgs)"

echo
echo "Webhook messages:"; hook_msgs | sed 's/^/  /'
echo
echo "${PASSES} passed, ${FAILS} failed"
(( FAILS == 0 ))
