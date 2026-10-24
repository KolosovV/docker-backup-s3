#!/usr/bin/env bash
# shellcheck disable=SC2034 # the variables are read by the code under test
# Remote databases without Docker or S3: `docker run` and `aws` are stubs. The stub storage is a folder
# (S3/<bucket>/<key>); the stub client container prints a known dump. Checks the settings check, the client
# command for each type, the stream into the storage (and what is left there when it breaks), the retry, the
# copies, a whole docker-backup.sh run with -p db:NAME — and that no password reaches a command line or the log.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
source "$REPO/lib.sh"
set +e
LOG_FILE="$W/log"
F="$W/fake"; S3="$W/s3"
mkdir -p "$W/bin" "$F" "$S3/pri" "$S3/sec"
: > "$F/argv.log"; : > "$S3/aws.log"

cat > "$W/bin/docker" <<'EOF'
#!/usr/bin/env bash
# The docker stub: `run` records its arguments, the values of -e NAME and its stdin, then prints a dump (FAKE_DUMP)
F="$DBT_FAKE"
case "$1" in
    run)
        shift; envs=(); feed=false
        while [[ "$1" == -* ]]; do
            case "$1" in
                -e) envs+=("$2=${!2-}"); printf '%s\n' "-e" "$2" >> "$F/argv.log"; shift 2 ;;
                -i) feed=true; shift ;;
                --name|--network|--log-driver) printf '%s\n' "$1" "$2" >> "$F/argv.log"; echo "$1 $2" >> "$F/opts"; shift 2 ;;
                *) printf '%s\n' "$1" >> "$F/argv.log"; echo "$1" >> "$F/opts"; shift ;;
            esac
        done
        printf '%s\n' "$@" >> "$F/argv.log"
        printf '%s\n' ${envs[@]+"${envs[@]}"} > "$F/env.last"
        printf '%s\n' "$@" > "$F/cmd.last"
        : > "$F/stdin.last"
        $feed && { IFS= read -r line; printf '%s\n' "$line" > "$F/stdin.last"; }
        echo run >> "$F/runs"
        case "${FAKE_DUMP:-ok}" in
            ok)      echo "-- PostgreSQL database dump"; seq 1 40000 ;;
            fail)    echo "-- PostgreSQL database dump"; seq 1 100
                     echo 'pg_dump: error: connection to server failed: FATAL:  password authentication failed for user "bk"' >&2; exit 1 ;;
            notool)  echo 'docker: Error response from daemon: exec: "pg_dump": executable file not found in $PATH' >&2; exit 127 ;;
            version) echo "PostgreSQL 17.6 on x86_64-pc-linux-musl" ;;
            pong)    echo PONG ;;
            noauth)  echo "NOAUTH Authentication required." ;;
        esac ;;
    image) exit 0 ;;
    pull)  exit 0 ;;
    rm)    echo "$*" >> "$F/rm.log" ;;
    --version) echo "Docker version 27.5.1" ;;
    *) exit 0 ;;   # ps, inspect: no containers on this "host"
esac
EOF
cat > "$W/bin/aws" <<'EOF'
#!/usr/bin/env bash
# The aws stub: a storage in folders. FAIL_UPLOADS=<file with a number> — that many stream uploads fail with SlowDown.
S3="$DBT_S3"
printf '%s\n' "$*" >> "$S3/aws.log"
args=(); exp=""
while (( $# )); do
    case "$1" in
        --endpoint-url|--output|--query) shift 2 ;;
        --only-show-errors|--quiet) shift ;;
        --expected-size) exp="$2"; shift 2 ;;
        *) args+=("$1"); shift ;;
    esac
done
set -- "${args[@]}"
p() { printf '%s/%s' "$S3" "${1#s3://}"; }
case "$1 $2" in
    "configure set"|"s3 ls") exit 0 ;;
    "s3 cp")
        if [[ "$3" == - ]]; then
            n="$(cat "$S3/fail_uploads" 2>/dev/null || echo 0)"
            if (( n > 0 )); then
                echo $((n - 1)) > "$S3/fail_uploads"; cat > /dev/null
                echo "upload failed: An error occurred (SlowDown) when calling the UploadPart operation: Please reduce your request rate." >&2; exit 1
            fi
            [[ -f "$S3/deny" ]] && { cat > /dev/null; echo "An error occurred (AccessDenied) when calling the CreateMultipartUpload operation: Access Denied" >&2; exit 1; }
            mkdir -p "$(dirname "$(p "$4")")"; cat > "$(p "$4")"
            [[ -n "$exp" ]] && echo "$exp" > "$(p "$4").expected"
        elif [[ "$4" == - ]]; then
            cat "$(p "$3")"
        elif [[ "$3" == s3://* ]]; then
            cp "$(p "$3")" "$4"
        else
            mkdir -p "$(dirname "$(p "$4")")"; cp "$3" "$(p "$4")"
        fi ;;
    "s3 rm") rm -f "$(p "$3")" ;;
    "s3api head-object")
        b=""; k=""
        for (( i = 3; i <= $#; i++ )); do
            case "${!i}" in --bucket) j=$((i + 1)); b="${!j}" ;; --key) j=$((i + 1)); k="${!j}" ;; esac
        done
        [[ -f "$S3/$b/$k" ]] || { echo "An error occurred (404) when calling the HeadObject operation: Not Found" >&2; exit 254; }
        stat -c %s "$S3/$b/$k" ;;
    "s3api list-multipart-uploads") echo '{}' ;;
    "s3api list-objects-v2") echo None ;;
esac
exit 0
EOF
chmod +x "$W/bin/docker" "$W/bin/aws"
export PATH="$W/bin:$PATH" DBT_FAKE="$F" DBT_S3="$S3"

PRIMARY_S3_ACCESS_KEY=AKIATESTKEY; PRIMARY_S3_SECRET_KEY=s3cret; PRIMARY_S3_ENDPOINT=https://s3.example.test
PRIMARY_S3_REGION=r1; PRIMARY_S3_BUCKET=pri
WORK_DIR="$W/work"; mkdir -p "$WORK_DIR"
S3_UPLOAD_RETRY_DELAY=0
_aws_setup primary
PG_PASS='pg p@ss"$1'; MY_PASS="my'pw"; MO_PASS='mo ngo!'; RE_PASS='re dis'
REMOTE_DBS="shop, my-db ma mo re"
REMOTE_DB_SHOP_TYPE=postgres; REMOTE_DB_SHOP_HOST=db.example.test; REMOTE_DB_SHOP_USER=bk
REMOTE_DB_SHOP_PASSWORD="$PG_PASS"; REMOTE_DB_SHOP_DATABASE=shop; REMOTE_DB_SHOP_SSL=true
REMOTE_DB_MY_DB_TYPE=mysql; REMOTE_DB_MY_DB_HOST=localhost; REMOTE_DB_MY_DB_PASSWORD="$MY_PASS"
REMOTE_DB_MA_TYPE=mariadb; REMOTE_DB_MA_HOST=10.0.0.5; REMOTE_DB_MA_PORT=3307; REMOTE_DB_MA_USER=bk
REMOTE_DB_MA_PASSWORD_FILE="$W/ma.pass"; printf 'ma pass\nsecond line\n' > "$W/ma.pass"
REMOTE_DB_MA_DATABASE=app; REMOTE_DB_MA_SSL=true; REMOTE_DB_MA_ARGS="--events --hex-blob"
REMOTE_DB_MO_TYPE=mongo; REMOTE_DB_MO_HOST="mongodb+srv://cluster0.example.test/"; REMOTE_DB_MO_USER=root
REMOTE_DB_MO_PASSWORD="$MO_PASS"; REMOTE_DB_MO_SSL=true
REMOTE_DB_RE_TYPE=redis; REMOTE_DB_RE_HOST=cache.example.test; REMOTE_DB_RE_USER=backup; REMOTE_DB_RE_PASSWORD="$RE_PASS"
REMOTE_DB_RE_IMAGE=valkey/valkey:8; REMOTE_DB_RE_NETWORK=backnet

has_arg() { grep -qxF -- "$2" <<< "$1"; }      # has_arg "<lines>" <line>
cmd_has() { has_arg "$(printf '%s\n' "${RDB_DOCKER[@]}")" "$1"; }
# cmd_tail — the command in the container: what follows the image among docker run's arguments, space-separated
cmd_tail() {
    local a seen=false
    for a in "${RDB_DOCKER[@]}"; do
        $seen && printf '%s ' "$a"
        [[ "$a" == "$RDB_IMAGE" ]] && seen=true
    done
}

section "the list and the settings check"
check "REMOTE_DBS: spaces and commas" test "$(remote_db_names | tr '\n' ' ')" == "shop my-db ma mo re "
check "a name with - reads REMOTE_DB_MY_DB_*" test "$(remote_db_var my-db TYPE)" == mysql
for n in shop my-db ma mo re; do
    check "$n: the settings are complete" remote_db_check "$n"
done
REMOTE_DB_X_HOST=h
out="$(remote_db_check x)"; check "no TYPE: said so" grep -q 'REMOTE_DB_X_TYPE is not set' <<< "$out"
REMOTE_DB_X_TYPE=oracle; out="$(remote_db_check x)"; check "an unknown TYPE: said so" grep -q 'oracle is not a known type' <<< "$out"
REMOTE_DB_X_TYPE=postgres; REMOTE_DB_X_HOST=""; out="$(remote_db_check x)"; check "no HOST: said so" grep -q 'REMOTE_DB_X_HOST is not set' <<< "$out"
REMOTE_DB_X_HOST=h; REMOTE_DB_X_PORT=54x; out="$(remote_db_check x)"; check "a bad PORT: said so" grep -q 'not a port number' <<< "$out"
REMOTE_DB_X_PORT=""; REMOTE_DB_X_SSL=yes; out="$(remote_db_check x)"; check "SSL=yes: true or false" grep -q 'true or false' <<< "$out"
REMOTE_DB_X_SSL=""; REMOTE_DB_X_MAX_SIZE=lots; out="$(remote_db_check x)"; check "a bad MAX_SIZE: said so" grep -q 'a size like 200G' <<< "$out"
REMOTE_DB_X_MAX_SIZE=""; REMOTE_DB_X_TIMEOUT=0; out="$(remote_db_check x)"; check "TIMEOUT=0: said so" grep -q 'not a number of seconds' <<< "$out"
REMOTE_DB_X_TIMEOUT=""; REMOTE_DB_X_HOST="postgres://u:secret@h/db"; out="$(remote_db_check x)"
check "a password in HOST: refused" grep -q 'has a password in it' <<< "$out"
REMOTE_DB_X_HOST="postgres://h/db"; out="$(remote_db_check x)"; check "a URI for postgres: refused" grep -q 'works for mongo only' <<< "$out"
REMOTE_DB_X_HOST=h; REMOTE_DB_X_PASSWORD=a; REMOTE_DB_X_PASSWORD_FILE="$W/none"; out="$(remote_db_check x)"
check "PASSWORD and PASSWORD_FILE both: said so" grep -q 'keep one' <<< "$out"
check "an unreadable PASSWORD_FILE: said so" grep -q 'cannot read' <<< "$out"
out="$(remote_db_check 'Bad Name')"; check "an odd name: said so" grep -q 'lower-case letters' <<< "$out"
check "PASSWORD_FILE: its first line" test "$(remote_db_password ma)" == "ma pass"
desc="$(remote_db_desc shop)"
check "the description" test "$desc" == "postgres db.example.test:5432, database shop, user bk, TLS"
check "the description has no password" bash -c '[[ "$1" != *"$2"* ]]' _ "$desc" "$PG_PASS"
check "the description of a URI" test "$(remote_db_desc mo)" == "mongo mongodb+srv://cluster0.example.test/, all databases, user root, TLS"

section "the client commands"
_remote_db_build shop dump
check "postgres: pg_dump of the one database" test "$(cmd_tail)" == "pg_dump -h db.example.test -p 5432 -U bk --dbname=shop "
check "postgres: the default image" cmd_has postgres:18-alpine
check "postgres: --log-driver none" bash -c 'printf "%s\n" "$@" | grep -qx -- none' _ "${RDB_DOCKER[@]}"
check "postgres: the host network by default" cmd_has host
check "postgres: the password goes by -e PGPASSWORD, its value in the environment" \
    bash -c 'printf "%s\n" "$@" | grep -qx PGPASSWORD' _ "${RDB_DOCKER[@]}"
check "postgres: PGPASSWORD's value is the password" has_arg "$(printf '%s\n' "${RDB_ENV[@]}")" "PGPASSWORD=$PG_PASS"
check "postgres: SSL=true is PGSSLMODE=require" has_arg "$(printf '%s\n' "${RDB_ENV[@]}")" "PGSSLMODE=require"
check "postgres: gzip here, .sql.gz" test "$RDB_GZIP:$RDB_EXT" == true:sql.gz
REMOTE_DB_SHOP_DATABASE=""; _remote_db_build shop dump
check "postgres, no DATABASE: pg_dumpall" test "$(cmd_tail)" == "pg_dumpall -h db.example.test -p 5432 -U bk "
REMOTE_DB_SHOP_DATABASE=shop
_remote_db_build shop probe
check "postgres probe: psql SELECT version()" test "${RDB_DOCKER[-1]}" == "SELECT version()"
check "probe: a 60 s limit" test "$RDB_TIMEOUT" == 60
_remote_db_build my-db dump
check "mysql: mysqldump as root, over TCP, all databases" \
    test "$(cmd_tail)" == "mysqldump -h localhost -P 3306 -u root --protocol=TCP --single-transaction --quick --routines --triggers --no-tablespaces --all-databases "
check "mysql: MYSQL_PWD" has_arg "$(printf '%s\n' "${RDB_ENV[@]}")" "MYSQL_PWD=$MY_PASS"
check "mysql: the default image" cmd_has mysql:8.4
_remote_db_build ma dump
check "mariadb: mariadb-dump, port, --ssl, ARGS, one database" \
    test "$(cmd_tail)" == "mariadb-dump -h 10.0.0.5 -P 3307 -u bk --protocol=TCP --ssl --single-transaction --quick --routines --triggers --no-tablespaces --events --hex-blob --databases app "
check "mariadb: the password from the file" has_arg "$(printf '%s\n' "${RDB_ENV[@]}")" "MYSQL_PWD=ma pass"
_remote_db_build ma probe
check "mariadb probe: SELECT VERSION()" test "${RDB_DOCKER[-1]}" == "SELECT VERSION()"
_remote_db_build mo dump
check "mongo: --uri, the user, --tls, an archive gzipped by mongodump" \
    test "$(cmd_tail)" == "mongodump --quiet --uri=mongodb+srv://cluster0.example.test/ --username root --authenticationDatabase admin --tls --archive --gzip "
check "mongo: the password on stdin (-i)" test "$RDB_FEED:$RDB_STDIN" == "true:$MO_PASS"
check "mongo: docker run -i" cmd_has -i
check "mongo: no gzip here, .archive.gz" test "$RDB_GZIP:$RDB_EXT" == false:archive.gz
check "mongo: no password in the environment" test "${#RDB_ENV[@]}" == 0
_remote_db_build re dump
check "redis: through a file in the container, --user" grep -q 'redis-cli "$@" --rdb /tmp/dbb.rdb' <<< "${RDB_DOCKER[-8]}"
check "redis: the connection arguments" test "$(printf '%s ' "${RDB_DOCKER[@]: -6}")" == "-h cache.example.test -p 6379 --user backup "
check "redis: REDISCLI_AUTH" has_arg "$(printf '%s\n' "${RDB_ENV[@]}")" "REDISCLI_AUTH=$RE_PASS"
check "redis: its IMAGE and NETWORK" bash -c 'printf "%s\n" "$@" | grep -qx valkey/valkey:8 && printf "%s\n" "$@" | grep -qx backnet' _ "${RDB_DOCKER[@]}"
for n in shop my-db ma mo re; do
    for w in dump probe; do
        _remote_db_build "$n" "$w"
        a="$(printf '%s\n' "${RDB_DOCKER[@]}")"
        check "$n $w: no password among docker's arguments" \
            bash -c 'for p in "$2" "$3" "$4" "$5" "ma pass"; do [[ "$1" == *"$p"* ]] && exit 1; done; exit 0' _ "$a" "$PG_PASS" "$MY_PASS" "$MO_PASS" "$RE_PASS"
    done
done

section "the stream into the storage"
KEY="b/_db_shop/2026-10-24_03-00-00/_db_shop__2026-10-24_03-00-00.sql.gz"
_remote_db_build shop dump
remote_db_stream shop "$KEY" 2>"$W/err"; rc=$?
check "it went in" test "$rc" == 0 || cat "$W/err"
check "the object is the gzipped dump" bash -c 'gunzip -c "$1" | head -n 1 | grep -q "PostgreSQL database dump" && [[ "$(gunzip -c "$1" | wc -l)" == 40001 ]]' _ "$S3/pri/$KEY"
check "RDB_SIZE is its size" test "$RDB_SIZE" == "$(stat -c %s "$S3/pri/$KEY")"
check "RDB_SHA256 is its sha256" test "$RDB_SHA256" == "$(sha256sum < "$S3/pri/$KEY" | cut -d' ' -f1)"
check "the client got PGPASSWORD (its value from the environment)" grep -qxF -- "PGPASSWORD=$PG_PASS" "$F/env.last"
check "nothing left in WORK_DIR" test -z "$(find "$WORK_DIR" -mindepth 1 ! -name aws-cli.conf)"
check "the container is removed after it (a broken pipe or a timeout leaves it)" grep -q "rm -f dbb-db-shop-" "$F/rm.log"
_remote_db_build mo dump; : > "$F/stdin.last"
remote_db_stream mo "b/_db_mo/t/mo.archive.gz" 2>>"$W/err"
check "mongo: the password reached the client's stdin" test "$(cat "$F/stdin.last")" == "$MO_PASS"
check "mongo: not gzipped once more" bash -c 'head -c 20 "$1" | grep -q "PostgreSQL"' _ "$S3/pri/b/_db_mo/t/mo.archive.gz"

if command -v gpg >/dev/null 2>&1; then
    echo "test passphrase" > "$W/pass"
    ENCRYPT_BACKUPS=true GPG_PASSPHRASE_FILE="$W/pass"
    _remote_db_build shop dump
    remote_db_stream shop "b/_db_shop/t/e.sql.gz.gpg" 2>>"$W/err"
    check "encrypted: gpg → gunzip gives the dump back" bash -c \
        'gpg --batch --quiet --passphrase-file "$2" -d "$1" 2>/dev/null | gunzip -c | head -n 1 | grep -q "PostgreSQL database dump"' _ "$S3/pri/b/_db_shop/t/e.sql.gz.gpg" "$W/pass"
    ENCRYPT_BACKUPS=false
else
    echo "   (gpg is not here: the encryption step is not checked)"
fi

REMOTE_DB_SHOP_MAX_SIZE=200G
_remote_db_build shop dump
remote_db_stream shop "b/_db_shop/t/big.sql.gz" 2>>"$W/err"
check "MAX_SIZE=200G: --expected-size in bytes" test "$(cat "$S3/pri/b/_db_shop/t/big.sql.gz.expected")" == 214748364800
REMOTE_DB_SHOP_MAX_SIZE=""

section "when it breaks"
: > "$W/err"
FAKE_DUMP=fail; export FAKE_DUMP
_remote_db_build shop dump
remote_db_stream shop "b/_db_shop/t/fail.sql.gz" 2>"$W/err"; rc=$?
check "a dump that broke off: failed" test "$rc" == 1
check "and its half is not left in the storage" test ! -e "$S3/pri/b/_db_shop/t/fail.sql.gz"
check "the reason in the log" grep -q 'password authentication failed for user "bk"' "$W/err"
check "the log says it removed the half" grep -q 'Removed the incomplete dump' "$W/err"
FAKE_DUMP=notool
_remote_db_build shop dump
remote_db_stream shop "b/_db_shop/t/notool.sql.gz" 2>"$W/err"; rc=$?
check "no dump tool in the image: failed, and said so" bash -c '[[ $1 == 1 ]] && grep -q "the dump tool is not in the image postgres:18-alpine" "$2"' _ "$rc" "$W/err"
FAKE_DUMP=ok
echo 1 > "$S3/fail_uploads"; : > "$F/runs"
_remote_db_build shop dump
remote_db_stream shop "b/_db_shop/t/retry.sql.gz" 2>"$W/err"; rc=$?
check "a storage hiccup (SlowDown): dumped again, and in" bash -c '[[ $1 == 0 && -s $2 ]]' _ "$rc" "$S3/pri/b/_db_shop/t/retry.sql.gz"
check "two dumps were made" test "$(wc -l < "$F/runs")" == 2
check "the retry is in the log" grep -q 'dumping again in 0 s (2/3)' "$W/err"
touch "$S3/deny"
_remote_db_build shop dump
remote_db_stream shop "b/_db_shop/t/denied.sql.gz" 2>"$W/err"; rc=$?
check "access denied: failed at once" bash -c '[[ $1 == 1 ]] && grep -q AccessDenied "$2" && ! grep -q "dumping again" "$2"' _ "$rc" "$W/err"
rm -f "$S3/deny"

section "the copy streams from the primary"
SECONDARY_S3_ENABLED=true; SECONDARY_S3_ACCESS_KEY=AKIASEC; SECONDARY_S3_SECRET_KEY=sec2; SECONDARY_S3_ENDPOINT=https://s3b.example.test
SECONDARY_S3_REGION=r2; SECONDARY_S3_BUCKET=sec
s3_refresh
upload_to_copy secondary "s3://pri/$KEY" "$KEY" "$(stat -c %s "$S3/pri/$KEY")" 2>"$W/err"; rc=$?
check "the copy is in, the same bytes" bash -c '[[ $1 == 0 && "$(sha256sum < "$2")" == "$(sha256sum < "$3")" ]]' _ "$rc" "$S3/pri/$KEY" "$S3/sec/$KEY"
check "aws got the stream's size" test "$(cat "$S3/sec/$KEY.expected")" == "$(stat -c %s "$S3/pri/$KEY")"
check "nothing written in WORK_DIR on the way" test -z "$(find "$WORK_DIR" -mindepth 1 ! -name aws-cli.conf)"

section "the login check"
FAKE_DUMP=version; out="$(remote_db_probe shop)"; rc=$?
check "postgres: logged in, the version shown" bash -c '[[ $1 == 0 && $2 == "PostgreSQL 17.6"* ]]' _ "$rc" "$out"
FAKE_DUMP=noauth; out="$(remote_db_probe re)"; rc=$?
check "redis: a refusal with exit code 0 is still a failure" bash -c '[[ $1 == 1 && $2 == NOAUTH* ]]' _ "$rc" "$out"
FAKE_DUMP=pong; out="$(remote_db_probe re)"; rc=$?
check "redis: PONG" test "$rc:$out" == "0:PONG"
REMOTE_DB_X_TYPE=""; out="$(remote_db_probe x)"; rc=$?
check "incomplete settings: no container started, the problem said" bash -c '[[ $1 == 1 && $2 == *"TYPE is not set"* ]]' _ "$rc" "$out"
FAKE_DUMP=ok

section "a whole run: docker-backup.sh -p db:shop"
CONF="$W/backup.conf"
cp "$REPO/backup.conf.example" "$CONF"
cat >> "$CONF" <<EOF
PRIMARY_S3_ACCESS_KEY="AKIATESTKEY"
PRIMARY_S3_SECRET_KEY="s3cret"
PRIMARY_S3_ENDPOINT="https://s3.example.test"
PRIMARY_S3_REGION="r1"
PRIMARY_S3_BUCKET="pri"
SECONDARY_S3_ENABLED="true"
SECONDARY_S3_ACCESS_KEY="AKIASEC"
SECONDARY_S3_SECRET_KEY="sec2"
SECONDARY_S3_ENDPOINT="https://s3b.example.test"
SECONDARY_S3_REGION="r2"
SECONDARY_S3_BUCKET="sec"
BACKUP_PREFIX="bk"
WORK_DIR="$W/run"
LOG_FILE="$W/run.log"
LOCK_FILE="$W/run.lock"
LAST_RUN_FILE="$W/last-run.json"
SCAN_DIRS=""
ENCRYPT_BACKUPS="false"
NOTIFY_ON="none"
REMOTE_DBS="shop broken"
REMOTE_DB_SHOP_TYPE="postgres"
REMOTE_DB_SHOP_HOST="db.example.test"
REMOTE_DB_SHOP_USER="bk"
REMOTE_DB_SHOP_PASSWORD='$PG_PASS'
REMOTE_DB_SHOP_DATABASE="shop"
REMOTE_DB_BROKEN_HOST="h"
EOF
: > "$F/argv.log"; : > "$S3/aws.log"
"$REPO/docker-backup.sh" -c "$CONF" -n > "$W/plan.out" 2>&1
check "dry run: the plan lists it" grep -q 'shop: postgres db.example.test:5432, database shop, user bk' "$W/plan.out"
check "dry run: and says what is missing in the other" grep -q 'REMOTE_DB_BROKEN_TYPE is not set' "$W/plan.out"
"$REPO/docker-backup.sh" -c "$CONF" -p db:nope > "$W/nope.out" 2>&1; rc=$?
check "-p db:nope: not found, and the list shown" bash -c '[[ $1 != 0 ]] && grep -q "Projects not found: db:nope" "$2" && grep -q "db:shop  (remote database)" "$2"' _ "$rc" "$W/nope.out"
"$REPO/docker-backup.sh" -c "$CONF" -p db:shop > "$W/run.out" 2>&1; rc=$?
k="$(cd "$S3/pri" && find bk/_db_shop -name '*.sql.gz')"
check "the run succeeded" bash -c '[[ $1 == 0 ]]' _ "$rc" || tail -n 30 "$W/run.out"
check "the dump is at bk/_db_shop/<time>/_db_shop__<time>.sql.gz" grep -qE '^bk/_db_shop/([0-9_-]+)/_db_shop__\1\.sql\.gz$' <<< "$k"
check "its .sha256 manifest next to it" bash -c 'cd "$1" && [[ "$(cut -d" " -f1 "$2.sha256")" == "$(sha256sum < "$2" | cut -d" " -f1)" ]] && grep -q "  ${2##*/}$" "$2.sha256"' _ "$S3/pri" "$k"
check "the secondary has both" bash -c 'for f in "$2" "$2.sha256"; do [[ -f "$1/sec/$f" && "$(sha256sum < "$1/pri/$f")" == "$(sha256sum < "$1/sec/$f")" ]] || exit 1; done' _ "$S3" "$k"
check "the summary counts it" grep -q 'Projects:  1/1' "$W/run.out"
check "the last-run file says ok" grep -q '"ok":true' "$W/last-run.json"
check "no password in the run's log" bash -c '! grep -qF -- "$1" "$2" "$3"' _ "$PG_PASS" "$W/run.out" "$W/run.log"
check "no password on docker's or aws's command line" bash -c '! grep -qF -- "$1" "$2" "$3"' _ "$PG_PASS" "$F/argv.log" "$S3/aws.log"
check "WORK_DIR has no dump left" test -z "$(find "$W/run" -name '*.sql.gz*' 2>/dev/null)"
"$REPO/docker-backup.sh" -c "$CONF" -p db:broken > "$W/broken.out" 2>&1; rc=$?
check "incomplete settings: the run fails and says why" bash -c '[[ $1 == 1 ]] && grep -q "REMOTE_DB_BROKEN_TYPE is not set" "$2" && grep -q "Errors:    1  (database broken)" "$2"' _ "$rc" "$W/broken.out"

finish
