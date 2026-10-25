#!/usr/bin/env bash
# shellcheck disable=SC2034 # the variables are read by the code under test
# Database dumps without Docker: `docker exec` is a stub that runs the in-container script right here, with
# the "container's" environment and fake database tools. Checks which account and password each dump picks
# (variables, *_FILE secrets, the server command line, a config file), the skips, the reasons in the log,
# and that no password reaches the log or a command line we build.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
source "$REPO/lib.sh"
set +e
LOG_FILE="$W/log"
F="$W/fake"   # F/<container>/env (KEY=value lines), F/<container>/bin (its tools), F/<container>/cmd (its Cmd)
mkdir -p "$W/bin" "$F"; : > "$F/argv.log"

cat > "$W/bin/docker" <<'EOF'
#!/usr/bin/env bash
# The docker stub. exec: runs the command here, with only the "container's" environment and tools.
F="$DBT_FAKE"
case "$1" in
    exec)
        shift; envs=()
        while [[ "$1" == -* ]]; do
            [[ "$1" == -e ]] && { envs+=("$2=${!2}"); shift; }
            shift
        done
        c="$1"; shift
        printf '%s\n' "$@" >> "$F/argv.log"   # every argument docker exec got, for the leak check
        [[ -x "$F/$c/bin/sh" || -L "$F/$c/bin/sh" ]] || { echo "OCI runtime exec failed: exec failed: unable to start container process: exec: \"sh\": executable file not found in \$PATH: unknown" >&2; exit 127; }
        mapfile -t cenv < "$F/$c/env"
        exec env -i PATH="$F/$c/bin" HOME=/tmp "${cenv[@]}" "${envs[@]}" "$@" ;;
    inspect)
        fmt="$3"; c="$4"
        case "$fmt" in
            *docker-backup-s3.skip*) cat "$F/$c/skip" 2>/dev/null ;;
            *.Name*) echo "/$c" ;;
            *Config.Image*) cat "$F/$c/image" 2>/dev/null ;;
            *State.Status*) echo running ;;
            *Config.Cmd*) cat "$F/$c/cmd" 2>/dev/null ;;
        esac ;;
    ps) cat "$F/ps" 2>/dev/null ;;   # the project's containers, for auto_dump_databases
esac
EOF
chmod +x "$W/bin/docker"
export PATH="$W/bin:$PATH" DBT_FAKE="$F"

# container <name> <tools…> — a fake container with the given tools (sh and the basics are always there)
container() {
    local c="$1" t; shift
    rm -rf "${F:?}/$c"; mkdir -p "$F/$c/bin"; : > "$F/$c/env"
    for t in sh cat sed tail head tr mktemp rm sleep printf echo; do
        [[ -e "$(command -v "$t")" ]] && ln -s "$(command -v "$t")" "$F/$c/bin/$t"
    done
    for t in "$@"; do cp "$W/tools/$t" "$F/$c/bin/$t"; chmod +x "$F/$c/bin/$t"; done
}
cenv() { printf '%s\n' "$2" >> "$F/$1/env"; }

# --- fake database tools: they print what they were given, and check the password like a server would ---
mkdir -p "$W/tools"
for t in postgres mysqld mariadbd redis-server valkey-server mongod; do printf '#!/bin/sh\nexit 0\n' > "$W/tools/$t"; done
cat > "$W/tools/pg_dumpall" <<'EOF'
#!/bin/sh
echo "-- PostgreSQL database cluster dump"
echo "args=$* pass=${PGPASSWORD:-none} host=${PGHOST:-default}"
EOF
# mariadb (the client): a login works only with the password in GOOD_<user>
cat > "$W/tools/mariadb" <<'EOF'
#!/bin/sh
u="$2"; eval "good=\${GOOD_$u-__none__}"
[ "${MYSQL_PWD-}" = "$good" ] && exit 0
echo "ERROR 1045 (28000): Access denied for user '$u'@'localhost' (using password: YES)" >&2; exit 1
EOF
cat > "$W/tools/mariadb-dump" <<'EOF'
#!/bin/sh
echo "-- MariaDB dump"
echo "args=$* pass=${MYSQL_PWD:-none}"
EOF
# redis-cli: a server with the password in SERVER_PASS (empty — none), on port SERVER_PORT
cat > "$W/tools/redis-cli" <<'EOF'
#!/bin/sh
[ "$1" = -p ] && { [ "$2" = "${SERVER_PORT:-6379}" ] || { echo "Could not connect to Redis at 127.0.0.1:$2: Connection refused"; exit 1; }; shift 2; }
if [ -n "${SERVER_PASS:-}" ] && [ "${REDISCLI_AUTH:-}" != "$SERVER_PASS" ]; then echo "NOAUTH Authentication required."; exit 0; fi
if [ -z "${SERVER_PASS:-}" ] && [ -n "${REDISCLI_AUTH:-}" ]; then echo "AUTH failed: ERR AUTH called without any password configured" >&2; fi
case "$1" in
    PING) echo PONG ;;
    LASTSAVE) cat /tmp/dbt-lastsave 2>/dev/null || echo 100 ;;
    BGSAVE) echo "Background saving started"; echo 200 > /tmp/dbt-lastsave ;;
    INFO) printf 'rdb_bgsave_in_progress:0\r\nrdb_last_bgsave_status:ok\r\n' ;;
    CONFIG) case "$3" in dir) printf 'dir\n%s\n' "$RDB_DIR" ;; dbfilename) printf 'dbfilename\ndump.rdb\n' ;; esac ;;
esac
EOF
cat > "$W/tools/mongodump" <<'EOF'
#!/bin/sh
pw=""; case "$*" in *--username*) read -r pw ;; esac
echo "args=$* pass-from-stdin=${pw:-none}"
EOF

# dump <kind> <container> — runs dump_<kind>, returns its code; the files land in $W/p-<container>/db-dumps
dump() {
    local kind="$1" c="$2" rc=0
    mkdir -p "$W/p-$c"; : > "$LOG_FILE"
    case "$kind" in
        mysql) ( umask 077; dump_mysql "$c" "$W/p-$c" TS mariadb ) >> "$LOG_FILE" 2>&1 || rc=$? ;;
        *) ( umask 077; "dump_$kind" "$c" "$W/p-$c" TS ) >> "$LOG_FILE" 2>&1 || rc=$? ;;
    esac
    return "$rc"
}
out_of() { gunzip -c "$W/p-$1/db-dumps/$2" 2>/dev/null || cat "$W/p-$1/db-dumps/$2" 2>/dev/null; }

section "detect_db_type"
check "postgres" test "$(detect_db_type postgres:17)" == postgres
check "timescale" test "$(detect_db_type timescale/timescaledb:2.15-pg16)" == postgres
check "mariadb" test "$(detect_db_type mariadb:11.4)" == mariadb
check "percona server (MySQL)" test "$(detect_db_type percona/percona-server:8.0)" == mysql
check "percona server for MongoDB is Mongo" test "$(detect_db_type percona/percona-server-mongodb:7.0)" == mongo
check "valkey" test "$(detect_db_type valkey/valkey:8)" == redis
check "keydb" test "$(detect_db_type eqalpha/keydb)" == redis
check "nginx is nothing" test -z "$(detect_db_type nginx:1.27)"

section "sec(): variables and *_FILE secrets, in the container's sh"
printf 'from-file\n' > "$W/secret"
s() { env -i PATH="$PATH" "$@" sh -c "${_DB_SH_LIB}"'sec A B'; }
check "the first set variable" test "$(s A=a B=b)" == a
check "the next one when the first is empty" test "$(s A= B=b)" == b
check "A_FILE, with the trailing newline cut" test "$(s A_FILE="$W/secret" B=b)" == from-file
check "the variable wins over its _FILE" test "$(s A=a A_FILE="$W/secret")" == a
check "nothing set: exit 1" bash -c '! env -i PATH="$PATH" sh -c "$1"'"'"'sec A B'"'" _ "$_DB_SH_LIB"
check "an unreadable _FILE is skipped" test "$(s A_FILE=/nonexistent B=b)" == b

section "PostgreSQL"
container pg postgres pg_dumpall
cenv pg POSTGRES_USER=app; cenv pg "POSTGRES_PASSWORD_FILE=$W/secret"
dump postgres pg; rc=$?
check "done" test "$rc" == 0
check "the user and the password from the _FILE" grep -q 'args=-U app pass=from-file' <<< "$(out_of pg postgres_pg_TS.sql.gz)"
check "the log names the user" grep -q 'user app' "$LOG_FILE"
container pgb postgres pg_dumpall
cenv pgb POSTGRESQL_POSTGRES_PASSWORD=bitnami-pw; cenv pgb POSTGRESQL_USERNAME=other
dump postgres pgb
check "Bitnami: the postgres superuser with its own password" grep -q 'args=-U postgres pass=bitnami-pw' <<< "$(out_of pgb postgres_pgb_TS.sql.gz)"
container exporter pg_dumpall
dump postgres exporter; rc=$?
check "no server binary: skipped (rc 3)" test "$rc" == 3
check "the skip says why" grep -q 'Skipped: no database server in the container' "$LOG_FILE"
check "and leaves no file" test -z "$(ls -A "$W/p-exporter/db-dumps")"
container scratch; rm "$F/scratch/bin/sh"
dump postgres scratch; rc=$?
check "no shell at all (FROM scratch): skipped too" test "$rc" == 3
container notool postgres
dump postgres notool; rc=$?
check "a server without pg_dumpall: a failure, with the reason" test "$rc" == 1
check "the reason" grep -q 'pg_dumpall not found in the container' "$LOG_FILE"

section "MySQL / MariaDB: which account"
container my1 mariadbd mariadb mariadb-dump
cenv my1 MARIADB_ROOT_PASSWORD=rootpw; cenv my1 GOOD_root=rootpw
dump mysql my1
check "root with its password: all databases, events" grep -q 'args=--all-databases --events --single-transaction --quick --routines --triggers -u root pass=rootpw' <<< "$(out_of my1 mariadb_my1_TS.sql.gz)"
container my2 mariadbd mariadb mariadb-dump
cenv my2 MARIADB_RANDOM_ROOT_PASSWORD=1; cenv my2 MARIADB_USER=app; cenv my2 MARIADB_PASSWORD=apppw
cenv my2 MARIADB_DATABASE=appdb; cenv my2 GOOD_app=apppw
dump mysql my2
check "random root: the app user and its database" grep -q 'args=--databases appdb --events --no-tablespaces .* -u app pass=apppw' <<< "$(out_of my2 mariadb_my2_TS.sql.gz)"
check "the log says so" grep -q 'no usable root password in the container: user app, database appdb' "$LOG_FILE"
container my3 mariadbd mariadb mariadb-dump
cenv my3 MYSQL_ROOT_PASSWORD=changed-since; cenv my3 MYSQL_USER=app; cenv my3 MYSQL_PASSWORD=apppw; cenv my3 GOOD_app=apppw
dump mysql my3
check "a root password that no longer works: the app user" grep -q -- '-u app pass=apppw' <<< "$(out_of my3 mariadb_my3_TS.sql.gz)"
container my4 mariadbd mariadb mariadb-dump
cenv my4 MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1; cenv my4 GOOD_root=
dump mysql my4
check "no password anywhere: root without one" grep -q -- '-u root pass=none' <<< "$(out_of my4 mariadb_my4_TS.sql.gz)"
container my5 mariadbd mariadb mariadb-dump
cenv my5 MYSQL_ROOT_PASSWORD=wrong-root-pw; cenv my5 GOOD_root=the-real-one
dump mysql my5; rc=$?
check "no account logs in: a failure" test "$rc" == 1
check "the reason is the server's own" grep -q "Access denied for user 'root'" "$LOG_FILE"
check "the password is not in the log" bash -c '! grep -q wrong-root-pw "$1"' _ "$LOG_FILE"
check "no file and no temporary files left" test -z "$(ls -A "$W/p-my5/db-dumps")"

section "Redis"
container r1 redis-server redis-cli
cenv r1 SERVER_PASS=; cenv r1 REDIS_PASSWORD=unused-by-the-server; cenv r1 "RDB_DIR=$W/rdb1"
mkdir -p "$W/rdb1"; printf 'REDIS0011-r1' > "$W/rdb1/dump.rdb"; rm -f /tmp/dbt-lastsave
dump redis r1; rc=$?
check "no password on the server: done without one (a variable that is not used is not tried)" test "$rc" == 0
check "the RDB copied" test "$(out_of r1 redis_r1_TS.rdb.gz)" == REDIS0011-r1
container r2 redis-server redis-cli
cenv r2 SERVER_PASS=cmd-pw; cenv r2 SERVER_PORT=6390; cenv r2 "RDB_DIR=$W/rdb1"
printf 'redis-server\n--port\n6390\n--requirepass\ncmd-pw\n' > "$F/r2/cmd"; rm -f /tmp/dbt-lastsave
dump redis r2; rc=$?
check "--requirepass and --port from the container's command" test "$rc" == 0
check "the Cmd password went to docker exec through the environment, not as an argument" bash -c '! grep -q cmd-pw "$1"' _ "$F/argv.log"
container r3 redis-server redis-cli
printf 'port 6391\nrequirepass "conf pw"\n' > "$W/redis.conf"
cenv r3 SERVER_PASS="conf pw"; cenv r3 SERVER_PORT=6391; cenv r3 "RDB_DIR=$W/rdb1"
printf 'redis-server\n%s\n' "$W/redis.conf" > "$F/r3/cmd"; rm -f /tmp/dbt-lastsave
dump redis r3; rc=$?
check "requirepass (quoted, with a space) and port from the config file" test "$rc" == 0
container r4 valkey-server redis-cli
cenv r4 SERVER_PASS=env-pw; cenv r4 VALKEY_PASSWORD=env-pw; cenv r4 "RDB_DIR=$W/rdb1"; rm -f /tmp/dbt-lastsave
dump redis r4; rc=$?
check "Valkey, the password from VALKEY_PASSWORD" test "$rc" == 0
container r5 redis-server redis-cli
cenv r5 SERVER_PASS=the-real-pw; cenv r5 REDIS_PASSWORD=a-stale-pw
dump redis r5; rc=$?
check "a wrong password: a failure" test "$rc" == 1
check "with the reason" grep -q 'no password from the container works' "$LOG_FILE"
check "the password is not in the log" bash -c '! grep -q -e a-stale-pw -e the-real-pw "$1"' _ "$LOG_FILE"

section "MongoDB"
container m1 mongod mongodump
cenv m1 MONGO_INITDB_ROOT_USERNAME=admin; cenv m1 "MONGO_INITDB_ROOT_PASSWORD_FILE=$W/secret"
dump mongo m1; rc=$?
check "done" test "$rc" == 0
check "the password on stdin, not as an argument" grep -q 'args=--quiet --username admin --authenticationDatabase admin --archive --gzip pass-from-stdin=from-file' <<< "$(out_of m1 mongo_m1_TS.archive.gz)"
check "named .archive.gz" test -f "$W/p-m1/db-dumps/mongo_m1_TS.archive.gz"
touch "$W/p-m1/db-dumps/mongo_m1_old.tar.gz"
dump mongo m1
check "the old misnamed .tar.gz dumps are removed" test ! -e "$W/p-m1/db-dumps/mongo_m1_old.tar.gz"
container m2 mongod mongodump
dump mongo m2
check "no credentials: without authentication" grep -q 'args=--quiet --archive --gzip pass-from-stdin=none' <<< "$(out_of m2 mongo_m2_TS.archive.gz)"

section "leaving out: a project, a container"
container pga postgres pg_dumpall; echo postgres:17 > "$F/pga/image"
container pgb2 postgres pg_dumpall; echo postgres:16 > "$F/pgb2/image"; echo true > "$F/pgb2/skip"
printf 'pga\npgb2\n' > "$F/ps"
mkdir -p "$W/p-proj"; : > "$LOG_FILE"
auto_dump_databases proj "$W/p-proj" TS >> "$LOG_FILE" 2>&1
check "a container without the label is dumped" test -f "$W/p-proj/db-dumps/postgres_pga_TS.sql.gz"
check "the labelled one is not" test ! -e "$W/p-proj/db-dumps/postgres_pgb2_TS.sql.gz"
check "and the log says why" grep -q 'pgb2: label docker-backup-s3.skip=true — no dump' "$LOG_FILE"
rm -rf "$W/p-proj"; mkdir -p "$W/p-proj"; : > "$LOG_FILE"
DB_DUMP_EXCLUDE_PROJECTS="other, pro*" auto_dump_databases proj "$W/p-proj" TS >> "$LOG_FILE" 2>&1
check "DB_DUMP_EXCLUDE_PROJECTS (a glob): no dumps in the project" test -z "$(ls -A "$W/p-proj" 2>/dev/null)"
check "the log says so" grep -q 'Database dumps are off for this project (DB_DUMP_EXCLUDE_PROJECTS)' "$LOG_FILE"
check "in_project_list: commas, spaces, globs" in_project_list web-2 "api, web-*"
check "in_project_list: no partial match" bash -c 'source "$1/lib.sh"; ! in_project_list web "webapp api"' _ "$REPO"
check "in_project_list: empty list" bash -c 'source "$1/lib.sh"; ! in_project_list web ""' _ "$REPO"

section "permissions"
check "db-dumps is 700" test "$(stat -c %a "$W/p-pg/db-dumps")" == 700
check "a dump is 600" test "$(stat -c %a "$W/p-pg/db-dumps/postgres_pg_TS.sql.gz")" == 600

section "the dumps on the server: what the archive takes, what stays after the upload"
P="$W/p-keep"; D="$P/db-dumps"; R="$W/dumps.rec"; mkdir -p "$P"
# keep_run <timestamp> <retention> [record] — one dump of the stub container pg, made a minute older each time
keep_run() {
    ( umask 077; DB_DUMPS_RETENTION_COUNT="$2" DUMP_RECORD="${3:-}" dump_postgres pg "$P" "$1" ) >> "$LOG_FILE" 2>&1
    touch -d "-$(( 10 - ${1#T} )) min" "$D/postgres_pg_$1.sql.gz"
}
keep_run T1 0
keep_run T2 0
check "retention 0: the new dump stays until the upload, the earlier one goes" \
    test "$(ls "$D")" == "postgres_pg_T2.sql.gz"
rm -rf "$D"; keep_run T1 2; keep_run T2 2; rm -f "$R"; keep_run T3 2 "$R"
check "retention 2: two dumps stay" test "$(ls "$D" | tr '\n' ' ')" == "postgres_pg_T2.sql.gz postgres_pg_T3.sql.gz "
check "the record: this run's dump is new" grep -qx "new	$D/postgres_pg_T3.sql.gz" "$R"
check "the record: the earlier one is old (left out of the archive)" grep -qx "old	$D/postgres_pg_T2.sql.gz" "$R"
DB_DUMPS_RETENTION_COUNT=1 keep_local_dumps "$R"
check "after the upload, retention 1: only the newest stays" test "$(ls "$D")" == "postgres_pg_T3.sql.gz"
echo mine > "$D/hook-dump.sql"
DB_DUMPS_RETENTION_COUNT=0 keep_local_dumps "$R"
check "retention 0: our dumps go" test -z "$(ls "$D"/postgres_* 2>/dev/null)"
check "a file of the user's own hook stays, and so does the folder" test -f "$D/hook-dump.sql"
rm -f "$D/hook-dump.sql"; keep_run T4 0; rm -f "$R"; keep_run T5 0 "$R"
DB_DUMPS_RETENTION_COUNT=0 keep_local_dumps "$R"
check "nothing else in it: the folder goes too" test ! -e "$D"
P="$W/p keep"; D="$P/db-dumps"; mkdir -p "$P"; keep_run T1 2; keep_run T2 2; rm -f "$R"; keep_run T3 2 "$R"
DB_DUMPS_RETENTION_COUNT=1 keep_local_dumps "$R"
check "a project folder with a space: the old dumps go all the same" test "$(ls "$D")" == "postgres_pg_T3.sql.gz"

section "no secret on a command line we build"
check "docker exec never got a password as an argument" bash -c '! grep -q -e rootpw -e apppw -e from-file -e bitnami-pw -e env-pw -e "conf pw" "$1"' _ "$F/argv.log"
check "curl_url_cfg quotes the URL for a curl config" test "$(curl_url_cfg 'https://h/a"b\c')" == 'url = "https://h/a\"b\\c"'

finish
