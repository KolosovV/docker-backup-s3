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
# DBT_WORK: a folder whose path is the same for this script and the Docker daemon (the distro tests share one)
IT="$(mktemp -d "${DBT_WORK:-/tmp}/dbit.XXXXXX")"
chmod 755 "$IT"
PROJ="itproj"
PDIR="$IT/srv/${PROJ}-app"   # not named like the project: its name must come from -p, not from the folder
EXT="$IT/srv/${PROJ}-ext"          # a bind mount NEXT TO the project folder (the 1.0.1 fix)
S3C="dbit-s3-$$"
# "Remote" databases: containers with published ports, reached the way a server elsewhere would be
RPG="dbit-rpg-$$" RMY="dbit-rmy-$$" RMO="dbit-rmo-$$" RRE="dbit-rre-$$"
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
    docker rm -f "$S3C" "$RPG" "$RMY" "$RMO" "$RRE" >/dev/null 2>&1
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
mdb_q() { docker compose -p "$PROJ" -f "$PDIR/compose.yaml" exec -T mdb mariadb -uroot -pitpass -N -B -e "$1"; }
# The images first run a temporary server for their setup (socket or localhost only), then restart it: a check
# over the socket can pass on the temporary one, and what is written then gets cut off. TCP answers only the
# final server.
wait_pg() {   # Postgres and MariaDB both answer
    local _
    for _ in $(seq 1 90); do
        docker compose -p "$PROJ" -f "$PDIR/compose.yaml" exec -T db pg_isready -q -h 127.0.0.1 >/dev/null 2>&1 \
            && docker compose -p "$PROJ" -f "$PDIR/compose.yaml" exec -T mdb \
                mariadb -h127.0.0.1 --protocol=tcp -uroot -pitpass -e 'select 1' >/dev/null 2>&1 \
            && return 0
        sleep 1
    done
    return 1
}
# The project's data in one line per item, to compare before and after.
fingerprint() {
    echo "db: $(psql_q "select count(*) || ':' || md5(string_agg(v, ',' order by id)) from t")"
    echo "mariadb: $(mdb_q "select count(*), md5(group_concat(v order by id separator ',')) from it.t")"
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
docker run -d --name "$S3C" --label docker-backup-s3.skip=true -p "127.0.0.1:${S3PORT}:7070" \
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
  mdb:
    image: mariadb:11.4
    environment:
      MARIADB_ROOT_PASSWORD: itpass
    volumes:
      - mdbdata:/var/lib/mysql
  app:
    image: alpine:3.20
    command: ["sleep", "infinity"]
    volumes:
      - appdata:/data
      - ./files:/files
      - ${EXT}:/ext
volumes:
  pgdata: {}
  mdbdata: {}
  appdata: {}
EOF
printf 'SECRET_SETTING=%s\n' "$RANDOM$RANDOM" > "$PDIR/.env"
echo "alpha $RANDOM" > "$PDIR/files/a.txt"
echo "beta $RANDOM" > "$PDIR/files/sub/b.txt"
echo "outside the project folder $RANDOM" > "$EXT/ext.txt"
mkdir -p "$EXT/rebuildable"; echo "must not be backed up" > "$EXT/rebuildable/big.cache"   # BIND_EXCLUDE_PATHS
docker compose -p "$PROJ" -f "$PDIR/compose.yaml" up -d --quiet-pull >/dev/null 2>&1 || die "compose up failed"
wait_pg || die "Postgres did not start"
psql_q "create table t(id int primary key, v text); insert into t select g, md5(g::text) from generate_series(1, 5000) g;" >/dev/null
mdb_q "create database it; create table it.t(id int primary key, v varchar(40)); insert into it.t select seq, md5(seq) from seq_1_to_3000;" >/dev/null
app_sh 'head -c 3000000 /dev/urandom > /data/big.bin; echo note > /data/note.txt'
# A socket in a volume (mail servers keep them there): busybox tar's "socket ignored" stays out of the log
python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' \
    "$(docker volume inspect -f '{{.Mountpoint}}' "${PROJ}_appdata")/app.sock"
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
BIND_EXCLUDE_PATHS="$EXT/rebuildable"
MIN_FREE_SPACE_MB=100
S3_BANDWIDTH_LIMIT="200MB/s"
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
check "aws is pinned to the classic transfer client" grep -q 'preferred_transfer_client = classic' "$IT/work/aws-cli.conf"
check "no transfer-client warning from aws" bash -c "! grep -q \"Using the 'classic' s3 transfer client\" '$IT/backup.out'"
check "no \"socket ignored\" for the socket in the volume" bash -c "! grep -q 'socket ignored' '$IT/backup.out' '$IT/backup.log'"
check "the secondary got nothing (disabled)" test -z "$(s3 s3 ls --recursive s3://secondary/ 2>/dev/null)"
check "webhook: backup done, worded right" grep -qE '^success\|backup done\|Saved 1 project in the primary storage \(127\.0\.0\.1:[0-9]+\)\. / [0-9.]+ [MG]B in ' <<< "$(hook_msgs)"
check "the containers run again after the backup" test "$(docker ps -q --filter "label=com.docker.compose.project=$PROJ" --filter status=running | wc -l)" -eq 3
check "no database dumps left on the server (DB_DUMPS_RETENTION_COUNT=0 by default)" test ! -e "$PDIR/db-dumps"

step "The plan shows the exclusion"
run plan docker-backup.sh -c "$CONF" -p "$PROJ" --dry-run
check "the dry-run plan names the excluded folder" grep -q "$EXT (without $EXT/rebuildable)" "$IT/plan.out"

step "Projects left out: EXCLUDE_PROJECTS, DB_DUMP_EXCLUDE_PROJECTS"
{ cat "$CONF"; echo "EXCLUDE_PROJECTS=\"nothing-like-it ${PROJ:0:4}*\""; } > "$IT/excl.conf"; chmod 600 "$IT/excl.conf"
run excl docker-backup.sh -c "$IT/excl.conf" --dry-run
check "the project is left out, by a glob" grep -q "Left out (EXCLUDE_PROJECTS): $PROJ" "$IT/excl.out"
check "and is not in the plan" bash -c "! grep -q '📦 $PROJ' '$IT/excl.out'"
check "--list still shows it (the menu offers it)" grep -qx "$PROJ" <<< "$("$REPO/docker-backup.sh" -c "$IT/excl.conf" --list 2>/dev/null)"
run excl-p docker-backup.sh -c "$IT/excl.conf" -p "$PROJ" --dry-run
check "asked for with -p: backed up anyway" grep -q "$PROJ is in EXCLUDE_PROJECTS, but asked for with -p" "$IT/excl-p.out"
{ cat "$CONF"; echo "DB_DUMP_EXCLUDE_PROJECTS=\"$PROJ\""; } > "$IT/nodb.conf"; chmod 600 "$IT/nodb.conf"
run nodb docker-backup.sh -c "$IT/nodb.conf" -p "$PROJ" --dry-run
check "DB_DUMP_EXCLUDE_PROJECTS: the plan has no dumps" grep -q 'Database dumps: off for this project' "$IT/nodb.out"

step "What is inside"
if run contents docker-restore.sh -c "$CONF" -p "$PROJ" -t "$TS" --contents -y; then ok "--contents exit 0"; else bad "--contents failed"; show_tail contents; fi
check "the Postgres volume is in it" grep -q "${PROJ}_pgdata" "$IT/contents.out"
check "the app volume is in it" grep -q "${PROJ}_appdata" "$IT/contents.out"
check "a Postgres dump is in it" grep -qi 'itdb\|postgres.*\.sql' "$IT/contents.out"
check "a MariaDB 11 dump is in it (mariadb-dump: the image has no mysqldump)" grep -q 'mariadb_.*\.sql\.gz' "$IT/contents.out"
check "the bind mount next to the project folder is in it" grep -q "${PROJ}_ext\|${PROJ}-ext" "$IT/contents.out"
"$REPO/docker-restore.sh" -c "$CONF" -p "$PROJ" -t "$TS" --contents -y < /dev/null 2>/dev/null > "$IT/contents-stdout.out"
check "--contents > file: the report goes to stdout" grep -q "${PROJ}_pgdata" "$IT/contents-stdout.out"
check "--contents > file: and no log or aws lines with it" bash -c '! grep -qE "^download:|Downloading|RESTORE" "$1"' _ "$IT/contents-stdout.out"

step "verify-restore"
if run verify verify-restore.sh -c "$CONF" -p "$PROJ"; then ok "verify-restore exit 0"; else bad "verify-restore failed"; show_tail verify; fi
check "the MariaDB dump is recognized (no false 'doesn't look like' warning)" bash -c '! grep -q "look like" "$1"' _ "$IT/verify.out"
check "it says MySQL/MariaDB for it" grep -q 'mariadb_.*(MySQL' "$IT/verify.out"
check "webhook: backups restore fine" grep -q '^success|backups restore fine|' <<< "$(hook_msgs)"

# ------------------------------------------------------------------------------
step "BACKUP_MODE=stop: the project's containers are stopped and started again"
started_before="$(docker inspect -f '{{.State.StartedAt}}' "$(docker ps -q --filter "label=com.docker.compose.project=$PROJ" --filter "label=com.docker.compose.service=db")")"
cp "$CONF" "$IT/stop.conf"; printf 'BACKUP_MODE="stop"\nDB_DUMPS_RETENTION_COUNT=2\n' >> "$IT/stop.conf"
# An earlier dump kept on the server: it stays there (2 are kept), but is already in an earlier archive
db_name="$(docker inspect -f '{{.Name}}' "$(docker ps -q --filter "label=com.docker.compose.project=$PROJ" --filter "label=com.docker.compose.service=db")" | sed 's|^/||')"
stale="$PDIR/db-dumps/postgres_${db_name}_2000-01-01_00-00-00.sql.gz"
mkdir -p "$PDIR/db-dumps"; echo stale | gzip > "$stale"; touch -d '2000-01-01' "$stale"
if run stopmode docker-backup.sh -c "$IT/stop.conf" -p "$PROJ"; then ok "a backup in stop mode"
else bad "the stop-mode backup failed"; show_tail stopmode; fi
TS2="$(s3 s3 ls --recursive "s3://primary/it/$PROJ/" 2>/dev/null | awk '{print $4}' | cut -d/ -f3 | sort -u | tail -n 1)"
run contents2 docker-restore.sh -c "$CONF" -p "$PROJ" -t "$TS2" --contents -y
check "the archive has this run's Postgres dump" grep -q "postgres_${db_name}_${TS2}" "$IT/contents2.out"
check "but not the earlier one kept on the server" bash -c '! grep -q "2000-01-01_00-00-00" "$1"' _ "$IT/contents2.out"
check "DB_DUMPS_RETENTION_COUNT=2: the server keeps both" test -f "$stale" -a "$(ls "$PDIR"/db-dumps/postgres_* | wc -l)" -eq 2
rm -rf "$PDIR/db-dumps"
db_id="$(docker ps -q --filter "label=com.docker.compose.project=$PROJ" --filter "label=com.docker.compose.service=db")"
check "the database was really stopped and started (a new start time)" test -n "$db_id" -a "$(docker inspect -f '{{.State.StartedAt}}' "$db_id" 2>/dev/null)" != "$started_before"
check "all three containers run again" test "$(docker ps -q --filter "label=com.docker.compose.project=$PROJ" --filter status=running | wc -l)" -eq 3
wait_pg || bad "Postgres did not come back after the stop-mode backup"

step "Sync to the secondary"
echo 'SECONDARY_S3_ENABLED="true"' >> "$CONF"
if run sync sync-s3.sh -c "$CONF" -y; then ok "sync-s3.sh exit 0"; else bad "sync-s3.sh failed"; show_tail sync; fi
s3 s3 ls --recursive "s3://secondary/it/$PROJ/" > "$IT/secondary.ls" 2>/dev/null
s3 s3 ls --recursive "s3://primary/it/$PROJ/" > "$IT/primary.ls" 2>/dev/null   # the stop-mode backup added one
check "the secondary has the same objects and sizes" test "$(awk '{print $3, $4}' "$IT/primary.ls" | sort)" == "$(awk '{print $3, $4}' "$IT/secondary.ls" | sort)"
check "webhook: storages synchronized" grep -q '^success|storages synchronized|' <<< "$(hook_msgs)"
if run sync2 sync-s3.sh -c "$CONF" -y && grep -q 'already in sync' "$IT/sync2.out"; then ok "a second sync copies nothing"
else bad "the second sync was not a no-op"; show_tail sync2; fi

# ------------------------------------------------------------------------------
step "Disaster: the project, its volumes and folders are gone"
docker compose -p "$PROJ" -f "$PDIR/compose.yaml" down -v >/dev/null 2>&1
rm -rf "$PDIR"
# The bind mount's data is gone too — all but the excluded (rebuildable) folder, which must survive the restore
find "$EXT" -mindepth 1 -maxdepth 1 ! -name rebuildable -exec rm -rf {} +
echo "rebuilt since" > "$EXT/rebuildable/big.cache"
check "the volumes are gone" test -z "$(docker volume ls -q --filter "name=${PROJ}_")"

step "Restore from the secondary"
if run restore docker-restore.sh -c "$CONF" -p "$PROJ" -t "$TS" --from secondary -y; then ok "docker-restore.sh exit 0"
else bad "docker-restore.sh failed"; show_tail restore; fi
check "compose.yaml is back" test -f "$PDIR/compose.yaml"
check "the excluded folder on the host survived the restore (BIND_EXCLUDE_PATHS)" grep -qx "rebuilt since" "$EXT/rebuildable/big.cache"
check "the rest of that bind mount did" test -f "$EXT/ext.txt"
if wait_pg; then ok "Postgres is up after the restore"; else bad "Postgres did not come up"; show_tail restore; fi
fingerprint > "$IT/after.txt" 2>&1
if [[ "$(cat "$IT/before.txt")" == "$(cat "$IT/after.txt")" ]]; then ok "the data matches: database, volume, bind mounts, project folder"
else bad "the data differs"; echo "--- before:"; cat "$IT/before.txt"; echo "--- after:"; cat "$IT/after.txt"; fi

# ------------------------------------------------------------------------------
step "Remote databases: dumped straight into both storages, then loaded back"
RPW='r pg$1"x' RMW='r my"x' ROW='r mo!' RRW='r re'
docker run -d --name "$RPG" --label docker-backup-s3.skip=true -p 127.0.0.1:17080:5432 \
    -e POSTGRES_PASSWORD="$RPW" -e POSTGRES_DB=shop postgres:17-alpine >/dev/null
docker run -d --name "$RMY" --label docker-backup-s3.skip=true -p 127.0.0.1:17081:3306 \
    -e MARIADB_ROOT_PASSWORD="$RMW" mariadb:11.4 >/dev/null
docker run -d --name "$RMO" --label docker-backup-s3.skip=true -p 127.0.0.1:17082:27017 \
    -e MONGO_INITDB_ROOT_USERNAME=root -e MONGO_INITDB_ROOT_PASSWORD="$ROW" mongo:7 >/dev/null
docker run -d --name "$RRE" --label docker-backup-s3.skip=true -p 127.0.0.1:17083:6379 \
    redis:7-alpine redis-server --requirepass "$RRW" >/dev/null
r_pg() { docker exec -i "$RPG" psql -U postgres -d shop -tAc "$1"; }
r_my() { docker exec -i "$RMY" mariadb -uroot "-p$RMW" -N -B -e "$1"; }
r_mo() { docker exec "$RMO" mongosh -u root -p "$ROW" --quiet --eval "$1"; }
r_re() { docker exec "$RRE" redis-cli -a "$RRW" --no-auth-warning "$@"; }
r_fp() {
    echo "pg: $(r_pg "select count(*) || ':' || md5(string_agg(v, ',' order by id)) from t")"
    echo "my: $(r_my "select count(*), md5(group_concat(v order by id separator ',')) from rx.t")"
    echo "mo: $(r_mo 'db.getSiblingDB("app").c.countDocuments()')"
    echo "re: $(r_re get k)"
}
# Ready means the final server (see wait_pg): TCP, or Mongo on the container's own address (its setup server
# listens on localhost only)
for _ in $(seq 1 90); do
    docker exec "$RPG" pg_isready -q -h 127.0.0.1 >/dev/null 2>&1 \
        && docker exec "$RMY" mariadb -h127.0.0.1 --protocol=tcp -uroot "-p$RMW" -e 'select 1' >/dev/null 2>&1 \
        && docker exec "$RMO" sh -c 'set -- $(hostname -i); mongosh --quiet --host "$1" --eval 1' >/dev/null 2>&1 \
        && [[ "$(r_re ping 2>/dev/null)" == PONG ]] && break
    sleep 1
done
for c in "$RPG" "$RMY" "$RMO" "$RRE"; do
    [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" == true ]] && continue
    bad "the test server $c is not running: $(docker inspect -f '{{.State.Status}}, exit {{.State.ExitCode}} {{.State.Error}}' "$c" 2>&1)"
    docker logs "$c" 2>&1 | tail -n 15
done
r_pg "create table t(id int primary key, v text); insert into t select g, md5(g::text) from generate_series(1, 2000) g;" >/dev/null
r_my "create database rx; create table rx.t(id int primary key, v varchar(40)); insert into rx.t select seq, md5(seq) from rx.seq_1_to_1500;" >/dev/null
r_mo 'for (let i = 0; i < 300; i++) db.getSiblingDB("app").c.insertOne({i: i})' >/dev/null
r_re set k "remote value $RANDOM" >/dev/null
r_fp > "$IT/remote-before.txt"; cat "$IT/remote-before.txt"
cp "$CONF" "$IT/remote.conf"
cat >> "$IT/remote.conf" <<EOF
REMOTE_DBS="rpg rmy rmo rre rbad"
REMOTE_DB_RPG_TYPE="postgres"
REMOTE_DB_RPG_HOST="127.0.0.1"
REMOTE_DB_RPG_PORT="17080"
REMOTE_DB_RPG_PASSWORD='$RPW'
REMOTE_DB_RPG_DATABASE="shop"
REMOTE_DB_RPG_IMAGE="postgres:17-alpine"
REMOTE_DB_RMY_TYPE="mariadb"
REMOTE_DB_RMY_HOST="localhost"
REMOTE_DB_RMY_PORT="17081"
REMOTE_DB_RMY_PASSWORD='$RMW'
REMOTE_DB_RMO_TYPE="mongo"
REMOTE_DB_RMO_HOST="127.0.0.1"
REMOTE_DB_RMO_PORT="17082"
REMOTE_DB_RMO_USER="root"
REMOTE_DB_RMO_PASSWORD='$ROW'
REMOTE_DB_RMO_IMAGE="mongo:7"
REMOTE_DB_RRE_TYPE="redis"
REMOTE_DB_RRE_HOST="127.0.0.1"
REMOTE_DB_RRE_PORT="17083"
REMOTE_DB_RRE_PASSWORD='$RRW'
REMOTE_DB_RBAD_TYPE="postgres"
REMOTE_DB_RBAD_HOST="127.0.0.1"
REMOTE_DB_RBAD_PORT="17080"
REMOTE_DB_RBAD_PASSWORD="wrong"
REMOTE_DB_RBAD_IMAGE="postgres:17-alpine"
EOF
chmod 600 "$IT/remote.conf"
run rvalidate validate-config.sh -c "$IT/remote.conf"
check "validate-config logs in to all four" test "$(grep -c ': logged in — ' "$IT/rvalidate.out")" -eq 4
check "and says the wrong password does not" grep -q 'rbad: cannot log in — .*password authentication failed' "$IT/rvalidate.out"
check "validate-config shows no password" bash -c 'for p in "$2" "$3" "$4" "$5"; do grep -qF -- "$p" "$1" && exit 1; done; exit 0' _ "$IT/rvalidate.out" "$RPW" "$RMW" "$ROW" "$RRW"
if run rbackup docker-backup.sh -c "$IT/remote.conf" -p db:rpg,db:rmy,db:rmo,db:rre; then ok "the four are backed up"
else bad "the remote backup failed"; show_tail rbackup; fi
s3 s3 ls --recursive "s3://primary/it/" | awk '{print $3, $4}' | grep ' it/_db_' > "$IT/rprimary.ls"
s3 s3 ls --recursive "s3://secondary/it/" | awk '{print $3, $4}' | grep ' it/_db_' > "$IT/rsecondary.ls"
cat "$IT/rprimary.ls"
for n in rpg:sql.gz rmy:sql.gz rmo:archive.gz rre:rdb.gz; do
    check "${n%%:*}: an encrypted dump and its manifest in the primary" bash -c \
        'grep -qE " it/_db_$2/[0-9_-]+/_db_$2__[0-9_-]+\.$3\.gpg$" "$1" && grep -qE "\.$3\.gpg\.sha256$" "$1"' _ "$IT/rprimary.ls" "${n%%:*}" "${n#*:}"
done
check "the secondary has the same dumps, the same sizes" test "$(sort "$IT/rprimary.ls")" == "$(sort "$IT/rsecondary.ls")"
check "no dump was written in WORK_DIR" test -z "$(find "$IT/work" \( -name '*.sql*' -o -name '*.rdb*' -o -name '*.archive*' \) 2>/dev/null)"
check "no client container is left" test -z "$(docker ps -aq --filter name=dbb-db-)"
check "no password in the run's output or log" bash -c 'for p in "$3" "$4" "$5" "$6"; do grep -qF -- "$p" "$1" "$2" && exit 1; done; exit 0' _ \
    "$IT/rbackup.out" "$IT/backup.log" "$RPW" "$RMW" "$ROW" "$RRW"
if run rbad docker-backup.sh -c "$IT/remote.conf" -p db:rbad; then bad "a wrong password passed"; else ok "a wrong password fails the run"; fi
check "the reason is in the log" grep -q 'password authentication failed' "$IT/rbad.out"
check "webhook: saved nowhere — database rbad" grep -q '^error|backup with errors|Saved nowhere: database rbad\.' <<< "$(hook_msgs)"
check "nothing of it left in the storage" test -z "$(s3 s3 ls --recursive s3://primary/it/_db_rbad/ 2>/dev/null)"
run rstatus status.sh -c "$IT/remote.conf"
check "status: the remote databases, and their backups marked as such" bash -c 'grep -q "Remote databases" "$1" && grep -q "_db_rpg.*(remote database)" "$1"' _ "$IT/rstatus.out"
for n in rpg rmy rmo rre; do
    if run "rverify-$n" verify-restore.sh -c "$IT/remote.conf" -p "_db_$n"; then ok "verify-restore _db_$n"
    else bad "verify-restore _db_$n failed"; show_tail "rverify-$n"; fi
done
check "verify-restore knows each kind" bash -c 'grep -q "PostgreSQL dump, intact" "$1" && grep -q "MySQL/MariaDB dump, intact" "$2" && grep -q "MongoDB archive, intact" "$3" && grep -q "Redis RDB, intact" "$4"' _ \
    "$IT/rverify-rpg.out" "$IT/rverify-rmy.out" "$IT/rverify-rmo.out" "$IT/rverify-rre.out"
# The data is lost on the "remote" servers, and comes back from the dumps docker-restore saves
RTS="$(grep ' it/_db_rpg/' "$IT/rprimary.ls" | head -n 1 | cut -d/ -f3)"
for n in rpg rmy rmo rre; do
    if run "rrestore-$n" docker-restore.sh -c "$IT/remote.conf" -p "_db_$n" -t "$RTS" --from secondary --extract-to "$IT/rdumps" -y; then ok "docker-restore saves the dump of $n"
    else bad "docker-restore _db_$n failed"; show_tail "rrestore-$n"; fi
done
check "the saved dumps are mode 600" test "$(stat -c %a "$IT"/rdumps/* | sort -u)" == 600
check "it says how to load one" grep -q 'gunzip -c .* | psql -h 127.0.0.1 -p 17080 -U postgres -d shop' "$IT/rrestore-rpg.out"
r_pg 'drop table t' >/dev/null
r_my 'drop database rx' >/dev/null
r_mo 'db.getSiblingDB("app").c.drop()' >/dev/null
r_re flushall >/dev/null
gunzip -c "$IT"/rdumps/_db_rpg__*.sql.gz | docker exec -i "$RPG" psql -q -U postgres -d shop >/dev/null
gunzip -c "$IT"/rdumps/_db_rmy__*.sql.gz | docker exec -i "$RMY" mariadb -uroot "-p$RMW" >/dev/null
docker exec -i "$RMO" mongorestore --quiet -u root -p "$ROW" --authenticationDatabase admin --archive --gzip < "$(ls "$IT"/rdumps/_db_rmo__*.archive.gz)"
docker stop "$RRE" >/dev/null
gunzip -c "$IT"/rdumps/_db_rre__*.rdb.gz > "$IT/dump.rdb"; docker cp "$IT/dump.rdb" "$RRE:/data/dump.rdb" >/dev/null
docker start "$RRE" >/dev/null
for _ in $(seq 1 30); do [[ "$(r_re ping 2>/dev/null)" == PONG ]] && break; sleep 1; done
r_fp > "$IT/remote-after.txt"
if [[ "$(cat "$IT/remote-before.txt")" == "$(cat "$IT/remote-after.txt")" ]]; then ok "all four databases are back as they were"
else bad "the remote data differs"; echo "--- before:"; cat "$IT/remote-before.txt"; echo "--- after:"; cat "$IT/remote-after.txt"; fi
docker rm -f "$RPG" "$RMY" "$RMO" "$RRE" >/dev/null 2>&1

# ------------------------------------------------------------------------------
step "Encryption switched off by a second line, the passphrase in place"
echo 'ENCRYPT_BACKUPS="false"' >> "$CONF"     # the old config's trap: a template default further down wins
if run quiet docker-backup.sh -c "$CONF" -p "$PROJ"; then ok "the backup itself still works"; else bad "the backup failed"; show_tail quiet; fi
check "not a plain 'done': a warning" grep -q '^warn|backup done, but check the settings|' <<< "$(hook_msgs)"
check "it says encryption is off" grep -q 'Encryption is off' <<< "$(hook_msgs | tail -n 1)"
check "and says the user's true is overridden by the default further down" grep -q 'ENCRYPT_BACKUPS: your "true"' <<< "$(hook_msgs | tail -n 1)"
if run validate2 validate-config.sh -c "$CONF"; then bad "validate-config passed with a setting given twice"
else ok "validate-config fails on a setting given twice"; fi
check "validate-config warns: passphrase in place, encryption off" grep -q 'ENCRYPTION IS OFF' "$IT/validate2.out"
sed -i '$d' "$CONF"                            # back to one line

step "Ctrl+C during the S3 access check"
# A "storage" that accepts the connection and never answers, so the run sits in the access check
python3 -c 'import socket,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", 17072)); s.listen(5); c=[]
while True: c.append(s.accept()[0])' &
HOLE_PID=$!
sed 's|^PRIMARY_S3_ENDPOINT=.*|PRIMARY_S3_ENDPOINT="http://127.0.0.1:17072"|' "$CONF" > "$IT/hang.conf"
echo 'PRIMARY_S3_ENDPOINT="http://127.0.0.1:17072"' >> "$IT/hang.conf"
: > "$IT/backup.log"
set -m   # its own process group, like a job in a terminal: Ctrl+C goes to the whole group, the log pipe too
"$REPO/docker-backup.sh" -c "$IT/hang.conf" -p "$PROJ" > "$IT/int.out" 2>&1 &
BG=$!
set +m
for _ in $(seq 1 60); do grep -q 'Checking access to the primary S3' "$IT/backup.log" 2>/dev/null && break; sleep 1; done
sleep 2
if ! kill -0 "$BG" 2>/dev/null; then
    bad "the run ended before the signal could be sent (the hanging storage did not hang it)"; show_tail int
fi
kill -INT -- "-$BG" 2>/dev/null
wait "$BG"; int_rc=$?
kill "$HOLE_PID" 2>/dev/null
check "the run stopped with an error code ($int_rc)" test "$int_rc" -ne 0
check "the log says it was interrupted, by which signal and where" \
    grep -q 'Backup interrupted (signal INT) at: 🔌 Checking access to the primary S3' "$IT/backup.log"
grep -q 'Backup interrupted' "$IT/backup.log" \
    || { show_tail int; echo "---- last lines of backup.log:"; tail -n 15 "$IT/backup.log"; echo "----"; }
check "a notification: interrupted before the first project" \
    grep -q '^error|backup interrupted|Stopped by signal INT .*nothing was saved in this run' <<< "$(hook_msgs | tail -n 1)"
check "the lock is released" test ! -e "$IT/lock.d"
check "no half-made work folder left" test -z "$(find "$IT/work" -mindepth 1 -maxdepth 1 -type d -name '20*' 2>/dev/null)"

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
