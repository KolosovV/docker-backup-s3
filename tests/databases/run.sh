#!/usr/bin/env bash
# Database dumps against real images: Postgres, MySQL, MariaDB, Redis / Valkey / KeyDB, MongoDB —
# several versions; passwords in variables, in *_FILE secrets, on the server command line, in a config file;
# root and app-user accounts; look-alikes (exporters) that must be skipped.
# Every dump must hold the marker written before it; one dump of each kind is loaded into a fresh container.
# While the dumps run, the command line of every process on the host is watched: no password may show up
# in one, nor in the log.
#
# Needs: docker, bash, gzip. To see the containers' processes, run it on the Docker host itself
# (or in a container with --pid=host). DBT_WORK — a folder with the same path here and for the Docker daemon.
# usage: tests/databases/run.sh [case-glob]     e.g. tests/databases/run.sh 'redis*'
set -uo pipefail
IFS=$'\n\t'
export LC_ALL=C.UTF-8

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ONLY="${1:-*}"
W="$(mktemp -d "${DBT_WORK:-/tmp}/dbdump.XXXXXX")"
chmod 755 "$W"
PFX="dbt$$"
FAILS=0; PASSES=0
declare -a CONTAINERS=()

ok()   { PASSES=$((PASSES + 1)); echo "  PASS $*"; }
bad()  { FAILS=$((FAILS + 1)); echo "  FAIL $*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

cleanup() {
    rm -f "$W/watching"
    [[ -n "${WATCH_PID:-}" ]] && wait "$WATCH_PID" 2>/dev/null
    (( ${#CONTAINERS[@]} )) && docker rm -f -v "${CONTAINERS[@]}" >/dev/null 2>&1
    rm -rf "$W"
}
trap cleanup EXIT

command -v docker >/dev/null 2>&1 || { echo "docker is not installed"; exit 1; }

# The code under test
LOG_FILE="$W/backup.log"
# shellcheck source=../../lib.sh
source "$REPO/lib.sh"
set +e   # lib.sh turns it on; the test checks results itself
DB_DUMP_TIMEOUT=180

# Every password used below goes in here: the watcher looks for them.
SECRETS="$W/secrets"; : > "$SECRETS"
secret() { printf '%s\n' "$1" >> "$SECRETS"; printf '%s' "$1"; }

# --- the process watcher: command lines of every process, while the dumps run ---
# A process that was already there before (a server started with --requirepass in its own Cmd: that is the
# user's choice, not ours) is not counted: only processes born during the dumps.
start_watch() {
    local p; for p in /proc/[0-9]*; do echo "${p#/proc/}"; done > "$W/pids.before"
    touch "$W/watching"
    (
        while [[ -f "$W/watching" ]]; do
            # One grep over every command line: a sweep takes milliseconds, short-lived processes are seen too
            for f in $(grep -a -l -F -f "$SECRETS" /proc/[0-9]*/cmdline 2>/dev/null); do
                c="$(tr '\0' ' ' < "$f" 2>/dev/null)" || continue
                f="${f#/proc/}"; printf '%s %s\n' "${f%/cmdline}" "$c"
            done
        done > "$W/leaks.raw"
    ) &
    WATCH_PID=$!
}
stop_watch() {
    rm -f "$W/watching"; wait "$WATCH_PID" 2>/dev/null; WATCH_PID=""
    awk 'NR==FNR { old[$1]=1; next } !($1 in old)' "$W/pids.before" "$W/leaks.raw" | sort -u -k2 > "$W/leaks"
}

# start <case> <image> [docker run args…] [-- cmd…] — a container labelled as compose project <case>
start() {
    local name="$1" image="$2"; shift 2
    local -a args=() cmd=()
    while (( $# )); do [[ "$1" == "--" ]] && { shift; cmd=("$@"); break; }; args+=("$1"); shift; done
    docker rm -f -v "${PFX}-${name}" >/dev/null 2>&1
    if ! docker run -d --name "${PFX}-${name}" --label "com.docker.compose.project=${PFX}-${name}" \
            ${args[@]+"${args[@]}"} "$image" ${cmd[@]+"${cmd[@]}"} >/dev/null 2>"$W/run.err"; then
        echo "  (cannot start $image: $(tail -n 1 "$W/run.err"))"
        return 1
    fi
    CONTAINERS+=("${PFX}-${name}")
}

# retry <seconds> <command…> — until it succeeds (the server is starting)
retry() {
    local t="$1" i; shift
    for (( i = 0; i < t; i++ )); do "$@" >/dev/null 2>&1 && return 0; sleep 1; done
    "$@"
}

# The markers, written through the database's own client with the known credentials
seed_pg()    { docker exec -e PGPASSWORD="$3" "$1" psql -v ON_ERROR_STOP=1 -U "$2" -d postgres -qc "CREATE TABLE IF NOT EXISTS dbt(m text); INSERT INTO dbt VALUES ('$4')"; }
mysql_cli()  { docker exec "$1" sh -c 'command -v mariadb || command -v mysql' | tr -d '\r'; }
seed_my()    { local c; c="$(mysql_cli "$1")" || return 1
               docker exec -e MYSQL_PWD="$3" "$1" "$c" -u "$2" -e "CREATE TABLE IF NOT EXISTS ${4}.dbt(m text); INSERT INTO ${4}.dbt VALUES ('$5')"; }
seed_redis() { local cli; cli="$(docker exec "$1" sh -c 'command -v redis-cli || command -v valkey-cli || command -v keydb-cli' | tr -d '\r')"
               local -a auth=(); [[ -n "$3" ]] && auth=(-e REDISCLI_AUTH="$3")
               [[ "$(docker exec ${auth[@]+"${auth[@]}"} "$1" "$cli" -p "$2" SET "$4" 1 2>&1 | tr -d '\r')" == OK ]]; }
# The official images run a temporary server while they initialise, then the real one as PID 1:
# a dump in between would hit a restart.
final_server() { local c; c="$(docker exec "$1" sh -c 'tr "\000" " " < /proc/1/cmdline' 2>/dev/null)" || return 1
                 [[ -n "$c" && ( "$c" != *entrypoint* || "$c" == tini* ) ]]; }   # Valkey: tini stays PID 1
seed_mongo() { local sh; sh="$(docker exec "$1" sh -c 'command -v mongosh || command -v mongo' | tr -d '\r')"
               local -a auth=(); [[ -n "$2" ]] && auth=(-u "$2" -p "$3" --authenticationDatabase admin)
               docker exec "$1" "$sh" --quiet ${auth[@]+"${auth[@]}"} --eval "db.getSiblingDB('dbt').m.insertOne({m: '$4'})"; }

# dumps_of <case> — the project folder and what auto-dump put there
proj_dir() { printf '%s/proj-%s' "$W" "$1"; }
has_marker() { gunzip -c "$1" 2>/dev/null | grep -a -F "$2" >/dev/null; }   # not -q: an early exit is a SIGPIPE for gunzip

# run_case <case> <kind> <expected file glob> — auto-dump the case's project, check the file and the marker
run_case() {
    local name="$1" glob="$2" marker="$3" f rc=0
    local dir; dir="$(proj_dir "$name")"; mkdir -p "$dir"
    : > "$LOG_FILE"
    auto_dump_databases "${PFX}-${name}" "$dir" "2026-01-01_00-00-00" 2>>"$LOG_FILE" >>"$LOG_FILE" || rc=$?
    # shellcheck disable=SC2086 # the glob on purpose
    f="$(ls "$dir"/db-dumps/$glob 2>/dev/null | head -n 1)"
    if [[ -n "$f" ]] && has_marker "$f" "$marker"; then
        ok "$name: dump with the marker ($(basename "$f"))"
    else
        bad "$name: no dump with the marker (rc=$rc)"; sed 's/^/      | /' "$LOG_FILE"
        return 1
    fi
    check "$name: the dump folder is 700" test "$(stat -c %a "$dir/db-dumps")" == 700
    check "$name: the dump is 600" test "$(stat -c %a "$f")" == 600
    if [[ "$f" == *.rdb.gz ]]; then   # what verify-restore.sh accepts as an RDB file
        local magic; magic="$(gunzip -c "$f" | head -c 6 || true)"
        check "$name: an RDB file (magic: ${magic})" bash -c '[[ "$1" == REDIS* || "$1" == VALKEY ]]' _ "$magic"
    fi
    check "$name: no temporary files left" test "$(find "$dir/db-dumps" -mindepth 1 | wc -l)" == 1
    LAST_DUMP="$f"
}

# expect_skip <case> — a look-alike: skipped, nothing written, not a failure
expect_skip() {
    local name="$1" rc=0 dir; dir="$(proj_dir "$name")"; mkdir -p "$dir"
    : > "$LOG_FILE"
    auto_dump_databases "${PFX}-${name}" "$dir" "2026-01-01_00-00-00" >>"$LOG_FILE" 2>&1 || rc=$?
    if grep -q "Skipped: no database server" "$LOG_FILE" && (( rc == 0 )); then
        ok "$name: skipped as not a database server, not a failure"
    else
        bad "$name: not skipped (rc=$rc)"; sed 's/^/      | /' "$LOG_FILE"
    fi
    check "$name: nothing written" test -z "$(ls -A "$dir/db-dumps" 2>/dev/null)"
}

# shellcheck disable=SC2053 # a glob on purpose
want() { [[ "$1" == $ONLY ]]; }

SEC="$W/secrets.d"; mkdir -p "$SEC"; chmod 755 "$SEC"
secret_file() { printf '%s\n' "$(secret "$2")" > "$SEC/$1"; chmod 644 "$SEC/$1"; printf '%s' "$SEC/$1"; }

# ==============================================================================
echo "== Starting the servers"
declare -A SEEDED=()
P1="$(secret 'pg17-Pa55 w0rd')"
want pg17 && start pg17 postgres:17-alpine -e POSTGRES_PASSWORD="$P1"
P2="$(secret 'pg16-file-$ecret')"
want pg16-scram-file && start pg16-scram-file postgres:16 -e POSTGRES_USER=app \
    -e POSTGRES_PASSWORD_FILE=/run/secrets/pg -v "$(secret_file pg16 "$P2"):/run/secrets/pg:ro" \
    -e POSTGRES_INITDB_ARGS="--auth-local=scram-sha-256 --auth-host=scram-sha-256"
P3="$(secret 'pg13-pw')"
want pg13 && start pg13 postgres:13-alpine -e POSTGRES_PASSWORD="$P3"
P4="$(secret 'my80-root-pw')"
want mysql80 && start mysql80 mysql:8.0 -e MYSQL_ROOT_PASSWORD="$P4" -e MYSQL_DATABASE=dbt
P5="$(secret 'my84-app-pw')"
want mysql84-user && start mysql84-user mysql:8.4 -e MYSQL_RANDOM_ROOT_PASSWORD=1 -e MYSQL_USER=app \
    -e MYSQL_PASSWORD="$P5" -e MYSQL_DATABASE=appdb
P6="$(secret 'my9-root-pw')"
want mysql9 && start mysql9 mysql:9 -e MYSQL_ROOT_PASSWORD="$P6" -e MYSQL_DATABASE=dbt
P7="$(secret "mdb1011-root'pw\"x")"
want mariadb1011-file && start mariadb1011-file mariadb:10.11 -e MARIADB_DATABASE=dbt \
    -e MARIADB_ROOT_PASSWORD_FILE=/run/secrets/mdb -v "$(secret_file mdb "$P7"):/run/secrets/mdb:ro"
P8="$(secret 'mdb114-app-pw')"
want mariadb114-user && start mariadb114-user mariadb:11.4 -e MARIADB_RANDOM_ROOT_PASSWORD=1 \
    -e MARIADB_USER=app -e MARIADB_PASSWORD="$P8" -e MARIADB_DATABASE=appdb
want mariadb114-nopass && start mariadb114-nopass mariadb:11.4 -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 -e MARIADB_DATABASE=dbt
want redis7 && start redis7 redis:7-alpine
P9="$(secret 'redis-cmd-pw')"
want redis7-cmd && start redis7-cmd redis:7 -- redis-server --requirepass "$P9"
P10="$(secret 'redis-conf-pw')"
printf 'port 6380\nrequirepass "%s"\ndir /data\ndbfilename snap.rdb\n' "$P10" > "$SEC/redis.conf"; chmod 644 "$SEC/redis.conf"
want redis7-conf && start redis7-conf redis:7-alpine -v "$SEC/redis.conf:/usr/local/etc/redis/redis.conf:ro" \
    -- redis-server /usr/local/etc/redis/redis.conf
P11="$(secret 'redis-env-pw')"
want redis6-env && start redis6-env redis:6 -e REDIS_PASSWORD="$P11" -- sh -c 'exec redis-server --requirepass "$REDIS_PASSWORD"'
P12="$(secret 'valkey-pw')"
want valkey8 && start valkey8 valkey/valkey:8 -- valkey-server --requirepass "$P12"
want valkey9 && start valkey9 valkey/valkey:9
want keydb && start keydb eqalpha/keydb:latest
P13="$(secret 'mongo7-pw')"
want mongo7 && start mongo7 mongo:7 -e MONGO_INITDB_ROOT_USERNAME=root -e MONGO_INITDB_ROOT_PASSWORD="$P13"
P14="$(secret "mongo8-file'pw")"
want mongo8-file && start mongo8-file mongo:8 -e MONGO_INITDB_ROOT_USERNAME=admin \
    -e MONGO_INITDB_ROOT_PASSWORD_FILE=/run/secrets/mongo -v "$(secret_file mongo "$P14"):/run/secrets/mongo:ro"
want mongo44 && start mongo44 mongo:4.4
# Look-alikes: the image name says postgres / redis, there is no server inside
want decoy-pg-exporter && start decoy-pg-exporter prometheuscommunity/postgres-exporter:v0.15.0 \
    -e DATA_SOURCE_NAME="postgresql://u:p@nowhere:5432/x?sslmode=disable"
want decoy-redis-exporter && start decoy-redis-exporter oliver006/redis_exporter:v1.62.0

echo "== Writing the markers"
try_seed() { local name="$1"; shift; want "$name" || return 0
    docker inspect "${PFX}-${name}" >/dev/null 2>&1 || { bad "$name: the server did not start"; return 0; }
    if retry 180 "$@"; then SEEDED[$name]=1; else bad "$name: cannot write the marker"; fi
    retry 180 final_server "${PFX}-${name}" || bad "$name: the server did not finish starting"; }
try_seed pg17             seed_pg "${PFX}-pg17" postgres "$P1" m-pg17
try_seed pg16-scram-file  seed_pg "${PFX}-pg16-scram-file" app "$P2" m-pg16
try_seed pg13             seed_pg "${PFX}-pg13" postgres "$P3" m-pg13
try_seed mysql80          seed_my "${PFX}-mysql80" root "$P4" dbt m-mysql80
try_seed mysql84-user     seed_my "${PFX}-mysql84-user" app "$P5" appdb m-mysql84
try_seed mysql9           seed_my "${PFX}-mysql9" root "$P6" dbt m-mysql9
try_seed mariadb1011-file seed_my "${PFX}-mariadb1011-file" root "$P7" dbt m-mdb1011
try_seed mariadb114-user  seed_my "${PFX}-mariadb114-user" app "$P8" appdb m-mdb114
try_seed mariadb114-nopass seed_my "${PFX}-mariadb114-nopass" root "" dbt m-mdbnopass
try_seed redis7           seed_redis "${PFX}-redis7" 6379 "" m-redis7
try_seed redis7-cmd       seed_redis "${PFX}-redis7-cmd" 6379 "$P9" m-redis7cmd
try_seed redis7-conf      seed_redis "${PFX}-redis7-conf" 6380 "$P10" m-redis7conf
try_seed redis6-env       seed_redis "${PFX}-redis6-env" 6379 "$P11" m-redis6env
try_seed valkey8          seed_redis "${PFX}-valkey8" 6379 "$P12" m-valkey8
try_seed valkey9          seed_redis "${PFX}-valkey9" 6379 "" m-valkey9
try_seed keydb            seed_redis "${PFX}-keydb" 6379 "" m-keydb
try_seed mongo7           seed_mongo "${PFX}-mongo7" root "$P13" m-mongo7
try_seed mongo8-file      seed_mongo "${PFX}-mongo8-file" admin "$P14" m-mongo8
try_seed mongo44          seed_mongo "${PFX}-mongo44" "" "" m-mongo44

echo "== Dumps (the process watcher is on)"
start_watch
dump() { local name="$1"; LAST_DUMP=""; want "$name" && [[ -n "${SEEDED[$name]:-}" ]] || return 0; run_case "$@"; }
dump pg17              'postgres_*.sql.gz' m-pg17;          PG_DUMP="${LAST_DUMP:-}"
dump pg16-scram-file   'postgres_*.sql.gz' m-pg16
dump pg13              'postgres_*.sql.gz' m-pg13
dump mysql80           'mysql_*.sql.gz' m-mysql80
dump mysql84-user      'mysql_*.sql.gz' m-mysql84
want mysql84-user && [[ -n "${SEEDED[mysql84-user]:-}" ]] && check "mysql84-user: says it used the app user" grep -q 'no usable root password in the container: user app' "$LOG_FILE"
dump mysql9            'mysql_*.sql.gz' m-mysql9
dump mariadb1011-file  'mariadb_*.sql.gz' m-mdb1011
dump mariadb114-user   'mariadb_*.sql.gz' m-mdb114;         MDB_DUMP="${LAST_DUMP:-}"
dump mariadb114-nopass 'mariadb_*.sql.gz' m-mdbnopass
dump redis7            'redis_*.rdb.gz' m-redis7
dump redis7-cmd        'redis_*.rdb.gz' m-redis7cmd
dump redis7-conf       'redis_*.rdb.gz' m-redis7conf;       REDIS_DUMP="${LAST_DUMP:-}"
want redis7-conf && [[ -n "${SEEDED[redis7-conf]:-}" ]] && check "redis7-conf: the RDB name and folder come from the server" grep -q '/data/snap.rdb' "$LOG_FILE"
dump redis6-env        'redis_*.rdb.gz' m-redis6env
dump valkey8           'redis_*.rdb.gz' m-valkey8
dump valkey9           'redis_*.rdb.gz' m-valkey9
dump keydb             'redis_*.rdb.gz' m-keydb
dump mongo7            'mongo_*.archive.gz' m-mongo7;       MONGO_DUMP="${LAST_DUMP:-}"
dump mongo8-file       'mongo_*.archive.gz' m-mongo8
dump mongo44           'mongo_*.archive.gz' m-mongo44
want decoy-pg-exporter && expect_skip decoy-pg-exporter
want decoy-redis-exporter && expect_skip decoy-redis-exporter
stop_watch
check "no password on any command line during the dumps" test ! -s "$W/leaks"
[[ -s "$W/leaks" ]] && sed 's/^/      | /' "$W/leaks"

# A wrong password: the reason is in the log, the password is not
if want redis-wrongpass; then
    PW="$(secret 'redis-right-pw')"
    if start redis-wrongpass redis:7-alpine -e REDIS_PASSWORD="$(secret 'redis-wrong-pw')" -- redis-server --requirepass "$PW" \
       && retry 60 docker exec "${PFX}-redis-wrongpass" redis-cli PING; then
        # the Cmd password is found, so make the server forget it: only the wrong env one is left
        docker exec "${PFX}-redis-wrongpass" redis-cli -a "$PW" --no-auth-warning CONFIG SET requirepass "$(secret 'redis-changed-pw')" >/dev/null
        dir="$(proj_dir redis-wrongpass)"; mkdir -p "$dir"; : > "$LOG_FILE"
        rc=0; auto_dump_databases "${PFX}-redis-wrongpass" "$dir" "2026-01-01_00-00-00" >>"$LOG_FILE" 2>&1 || rc=$?
        check "wrong password: the dump fails" test "$rc" != 0
        check "wrong password: the reason is logged" grep -q 'no password from the container works' "$LOG_FILE"
        check "wrong password: no file left" test -z "$(ls -A "$dir/db-dumps" 2>/dev/null)"
    else bad "redis-wrongpass: the server did not start"; fi
fi
check "no password in the log" test -z "$(grep -F -f "$SECRETS" "$LOG_FILE")"

# ==============================================================================
echo "== Loading the dumps into fresh servers"
if [[ -n "${PG_DUMP:-}" ]] && start r-pg postgres:17-alpine -e POSTGRES_HOST_AUTH_METHOD=trust \
   && retry 90 docker exec "${PFX}-r-pg" pg_isready -h 127.0.0.1 -U postgres; then
    gunzip -c "$PG_DUMP" | docker exec -i "${PFX}-r-pg" psql -q -U postgres -d postgres > "$W/load-pg.log" 2>&1
    got="$(docker exec "${PFX}-r-pg" psql -U postgres -d postgres -tAc 'select m from dbt' 2>/dev/null)"
    check "Postgres: the marker is back" test "$got" == m-pg17
    [[ "$got" == m-pg17 ]] || tail -n 5 "$W/load-pg.log"
fi
if [[ -n "${MDB_DUMP:-}" ]] && start r-mdb mariadb:11.4 -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 \
   && retry 90 docker exec "${PFX}-r-mdb" mariadb -h127.0.0.1 --protocol=tcp -uroot -e 'select 1'; then
    gunzip -c "$MDB_DUMP" | docker exec -i "${PFX}-r-mdb" mariadb -uroot > "$W/load-mdb.log" 2>&1
    got="$(docker exec "${PFX}-r-mdb" mariadb -uroot -N -B -e 'select m from appdb.dbt' 2>/dev/null)"
    check "MariaDB (app-user dump): the marker is back" test "$got" == m-mdb114
    [[ "$got" == m-mdb114 ]] || tail -n 5 "$W/load-mdb.log"
fi
if [[ -n "${REDIS_DUMP:-}" ]]; then
    mkdir -p "$W/rdata"; gunzip -c "$REDIS_DUMP" > "$W/rdata/dump.rdb"; chmod -R 777 "$W/rdata"
    if start r-redis redis:7-alpine -v "$W/rdata:/data" && retry 60 docker exec "${PFX}-r-redis" redis-cli PING; then
        check "Redis: the marker is back" test "$(docker exec "${PFX}-r-redis" redis-cli EXISTS m-redis7conf | tr -d '\r')" == 1
    fi
fi
if [[ -n "${MONGO_DUMP:-}" ]] && start r-mongo mongo:7 && retry 90 docker exec "${PFX}-r-mongo" mongosh --quiet --eval 1; then
    docker exec -i "${PFX}-r-mongo" mongorestore --quiet --archive --gzip < "$MONGO_DUMP" >/dev/null 2>&1
    check "MongoDB: the marker is back" test "$(docker exec "${PFX}-r-mongo" mongosh --quiet --eval "db.getSiblingDB('dbt').m.countDocuments({m: 'm-mongo7'})" | tr -d '\r')" == 1
fi

echo
echo "${PASSES} passed, ${FAILS} failed"
(( FAILS == 0 ))
