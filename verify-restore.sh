#!/usr/bin/env bash
# ==============================================================================
# verify-restore.sh
# Automatic check that backups can be restored.
#
# What it does:
#   1. Takes the latest backup of the given project (or of all)
#   2. Downloads it into a private temporary folder in WORK_DIR
#   3. Unpacks it, decrypts if needed
#   4. Checks tar integrity and file sizes
#   5. Checks that database dumps are valid (headers, gzip integrity)
#   6. Cleans up after itself
#   7. Sends a notification if something is wrong
#
# Usage:
#   sudo ./verify-restore.sh                  # check the latest backup of every project
#   sudo ./verify-restore.sh -p myapp         # myapp only
#   sudo ./verify-restore.sh --quick          # only that the object exists in S3, no download
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/backup.conf"

# --- Arguments ---
PROJECT_FILTER=""
MODE="standard"   # quick | standard | deep
MODE_SET=""       # given on the command line: VERIFY_DEEP does not override it
NOTIFY="true"
FROM_ROLE="primary"
WAIT_FOR_BACKUP="true"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)    CONFIG_FILE="$2"; shift 2 ;;
        -p|--project)   PROJECT_FILTER="$2"; shift 2 ;;
        --quick)        MODE="quick"; MODE_SET=1; shift ;;
        --standard)     MODE="standard"; MODE_SET=1; shift ;;
        --deep)         MODE="deep"; MODE_SET=1; shift ;;
        --no-notify)    NOTIFY="false"; shift ;;
        --from)         FROM_ROLE="$2"; shift 2 ;;
        --no-wait)      WAIT_FOR_BACKUP="false"; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [options]

Checks that backups can be restored.

  -c, --config FILE    config file (default: backup.conf)
  -p, --project NAME   check only the given project
      --quick          only the object's presence and size in S3, no download
      --deep           also load every database dump into a throwaway container
      --standard       the standard check, whatever VERIFY_DEEP says
      --no-notify      don't send a notification
      --from ROLE      which storage to check: primary (default), secondary, tertiary
      --no-wait        don't wait for a backup under way (by default the check waits up to
                       VERIFY_WAIT_MINUTES, 180, so it covers the copy being made)
  -h, --help           this help

The output also goes to LOG_FILE, as the backup's does. On a schedule: setup-cron.sh -v.

CHECK LEVELS:
  quick:    head-object — the object is there and non-empty (downloads nothing)
  standard: download → check size and sha256 → unpack → check tar
            and database dumps (default)
  deep:     standard, then every database dump is loaded into a throwaway
            container of its database (no network, removed after): PostgreSQL
            and MySQL/MariaDB of the dump's version, MongoDB; a Redis RDB goes
            through redis-check-rdb. Its tables are counted against the dump's.
            VERIFY_DEEP="true" in the config makes it the default.

EXAMPLES:
  Quick check of all:           sudo $0 --quick
  Detailed check of one:        sudo $0 -p myapp
EOF
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

[[ -f "$CONFIG_FILE" ]] || { echo "❌ Config not found: $CONFIG_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG_FILE"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
[[ -z "$MODE_SET" && "${VERIFY_DEEP:-false}" == "true" ]] && MODE="deep"

# The log: to the screen (or the cron log) and to LOG_FILE, so logs.sh and the notification's
# "Details" line find it next to the backup's
LOG_FILE="${LOG_FILE:-/var/log/docker-backup.log}"
VR_LOG_PID=""
if mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null && touch "$LOG_FILE" 2>/dev/null; then
    exec 2> >(exec tee -a "$LOG_FILE" >&2)
    VR_LOG_PID=$!
fi

# A check that could not even start (no storage access, no tool, no space) says so: on a schedule
# nobody watches its output. The reason is the last fail() message.
VR_DONE="false"
VR_FAIL_MSG=""
fail() { VR_FAIL_MSG="$*"; log_err "$*"; exit 1; }
VERIFY_DIR=""
# The deep check's throwaway database containers (dbs-verify-<this PID>-…) are removed however the script ends:
# deep_load runs in a pipeline, a subshell, so they are found by name, not kept in a list
_vr_exit() {
    local rc=$?
    docker ps -aq --filter "name=^dbs-verify-$$-" 2>/dev/null | xargs -r docker rm -f -v >/dev/null 2>&1 || true
    [[ -n "$VERIFY_DIR" ]] && rm -rf "$VERIFY_DIR"
    if (( rc != 0 )) && [[ "$VR_DONE" != "true" ]]; then
        if [[ "$NOTIFY" == "true" ]]; then
            notify error "restore check did not run" "$(html_esc "${VR_FAIL_MSG:-verify-restore.sh stopped with exit code $rc}")"$'\n'"$(notify_log_hint)" || true
        else
            heartbeat fail "restore check did not run" "$(html_esc "${VR_FAIL_MSG:-exit code $rc}")"
        fi
        [[ -z "$PROJECT_FILTER" && "$FROM_ROLE" == "primary" ]] \
            && metrics_write docker_backup_s3_verify docker_backup_s3_verify 0 projects 0 projects_failed 0 duration_seconds 0
    fi
    # Let tee write the last lines: under systemd the leftover processes are killed when the script exits
    if [[ -n "$VR_LOG_PID" ]]; then exec 2>&-; wait "$VR_LOG_PID" 2>/dev/null || true; fi
    return "$rc"
}
trap _vr_exit EXIT

require_cmd docker tar gzip aws jq
[[ "${ENCRYPT_BACKUPS:-false}" == "true" ]] && require_cmd gpg
{ notify_any || [[ -n "${VERIFY_HEARTBEAT_URL:-}" ]]; } && require_cmd curl

# The monitor hears of whole checks of the primary storage only (a check of one project or of a copy is not
# the scheduled one). The ping goes before anything that can fail: a check that cannot start is a "fail".
[[ -z "$PROJECT_FILTER" && "$FROM_ROLE" == "primary" ]] && HB_URL="${VERIFY_HEARTBEAT_URL:-}"
heartbeat start

# The storage to check; the read-only key, if set
s3_is_role "$FROM_ROLE" || fail "Unknown storage: $FROM_ROLE (available: $(s3_roles_txt))"
s3_enabled "$FROM_ROLE" || fail "$(s3_label "$FROM_ROLE" title) is not enabled (${FROM_ROLE^^}_S3_ENABLED != true)"
_aws_setup "$FROM_ROLE" read
SRC_BUCKET="$S3_CUR_BUCKET"

# --- Working folder ---
# A private folder (700, unpredictable name) in WORK_DIR: the archives are decrypted here. A fixed
# /tmp/verify-restore-PID could be created in advance by another user of the host, and the data would land in it.
WORK_DIR="${WORK_DIR:-/var/tmp/docker-backup}"
umask 077
work_dir_ready || fail "$WORK_DIR_ERR"
VERIFY_DIR="$(mktemp -d "${WORK_DIR}/verify.XXXXXX")" || fail "Cannot create a temporary folder in $WORK_DIR"

# A backup under way: wait for it, so the check covers the copy it is making, and the two don't share
# the disk and the network. An archive appears in the storage only whole, so a check that does not wait
# (--no-wait, or after VERIFY_WAIT_MINUTES) takes the latest complete one.
if [[ "$WAIT_FOR_BACKUP" == "true" ]] && bpid="$(backup_running_pid)"; then
    max_wait=$(( ${VERIFY_WAIT_MINUTES:-180} * 60 )); waited=0
    log "⏳ A backup is under way (PID $bpid) — waiting for it to finish (up to ${VERIFY_WAIT_MINUTES:-180} min)"
    while backup_running_pid >/dev/null; do
        if (( waited >= max_wait )); then
            log_warn "The backup is still running after ${VERIFY_WAIT_MINUTES:-180} min — checking the copies already in the storage"
            break
        fi
        sleep 30; waited=$((waited + 30))
    done
    (( waited < max_wait )) && log_ok "The backup finished — checking"
fi

# --- Global statistics ---
TOTAL_PROJECTS=0
TOTAL_OK=0
TOTAL_FAIL=0
declare -a FAILED_PROJECTS=()
declare -a FAILURE_REASONS=()
SESSION_START=$(date +%s)

# ==============================================================================
# HELPERS
# ==============================================================================

# dump_kind <file.sql.gz> — what made the dump, by its first lines: postgres, mysql or unknown.
# The header is read into a variable first: "gunzip | head | grep -q" fails under pipefail on a big dump
# (gunzip gets SIGPIPE), which looked like "not a dump". MariaDB 10.11.8+/11.x puts
# "/*M!999999\- enable the sandbox mode */" before "-- MariaDB dump", hence several lines and both names.
dump_kind() {
    local head
    head="$(gunzip -c "$1" 2>/dev/null | head -n 20 || true)"
    if grep -qE 'PostgreSQL database (cluster )?dump|^--[[:space:]]+PostgreSQL' <<< "$head"; then echo postgres
    elif grep -qE -- '-- (MySQL|MariaDB) dump|mysqldump|mariadb-dump|^-- Server version' <<< "$head"; then echo mysql
    else echo unknown; fi
}

# ==============================================================================
# THE DEEP CHECK: a dump loaded into a throwaway database
# ==============================================================================
# A dump can be whole gzip and say "PostgreSQL" in its first line, and still not load: cut off midway, a
# version the server can't read, an extension missing. Only loading it tells.

# deep_image <kind> <the dump's first lines> — the image of the dump's own database and version.
# VERIFY_DEEP_IMAGE_<KIND> (POSTGRES, MYSQL, MARIADB, MONGO, REDIS, VALKEY) overrides it.
deep_image() {
    local kind="$1" head="$2" v ov
    case "$kind" in
        postgres)
            v="$(grep -m 1 -oE 'Dumped from database version [0-9]+' <<< "$head" | grep -oE '[0-9]+$' || true)"
            ov="${VERIFY_DEEP_IMAGE_POSTGRES:-}"
            if grep -q 'timescaledb' <<< "$head"; then printf '%s' "${ov:-timescale/timescaledb:latest-pg${v:-17}}"
            else printf '%s' "${ov:-postgres:${v:-17}-alpine}"; fi ;;
        mysql)
            v="$(grep -m 1 -E '^-- Server version' <<< "$head" | grep -oE '[0-9]+\.[0-9]+' | head -n 1 || true)"
            if grep -qi 'mariadb' <<< "$head"; then printf '%s' "${VERIFY_DEEP_IMAGE_MARIADB:-mariadb:${v:-11.4}}"
            else printf '%s' "${VERIFY_DEEP_IMAGE_MYSQL:-mysql:${v:-8.4}}"; fi ;;
        mongo)  printf '%s' "${VERIFY_DEEP_IMAGE_MONGO:-mongo:8}" ;;
        redis)  printf '%s' "${VERIFY_DEEP_IMAGE_REDIS:-redis:8-alpine}" ;;
        valkey) printf '%s' "${VERIFY_DEEP_IMAGE_VALKEY:-valkey/valkey:9-alpine}" ;;
    esac
}

# _deep_tables_expected <postgres|mysql> — from the dump on stdin: the tables it creates, those of the system
# schemas left out (the count in the database leaves them out too)
_deep_tables_expected() {
    if [[ "$1" == postgres ]]; then
        awk '/^CREATE (UNLOGGED |TEMP |TEMPORARY )?TABLE / && $0 !~ /TABLE (IF NOT EXISTS )?"?_?timescaledb/ { n++ } END { print n + 0 }'
    else
        awk '/^USE `/ { db = $2 } /^CREATE TABLE / && db !~ /^`(mysql|sys|performance_schema|information_schema)`;?$/ { n++ } END { print n + 0 }'
    fi
}

# _deep_wait <container> <command…> — the server answers (up to VERIFY_DEEP_START seconds, 180)
_deep_wait() {
    local c="$1" i; shift
    for (( i = 0; i < ${VERIFY_DEEP_START:-180}; i++ )); do
        docker exec "$c" "$@" >/dev/null 2>&1 && return 0
        [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" == true ]] || return 1
        sleep 1
    done
    return 1
}

# deep_load <kind: postgres|mysql|mongo|redis> <name> <the dump's first lines> — the uncompressed dump on stdin.
# 0 — it loads; 1 — it does not; 2 — not checked (no image). What it found goes to the log.
deep_load() {
    local kind="$1" name="$2" head="$3" image c d out rc=0 n expected errs dbs db tmo="${VERIFY_DEEP_TIMEOUT:-3600}"
    [[ "$kind" == redis && "$head" == VALKEY* ]] && kind=valkey
    image="$(deep_image "$kind" "$head")"
    if ! docker image inspect "$image" >/dev/null 2>&1 && ! docker pull -q "$image" >/dev/null 2>&1; then
        log_warn "    $name: cannot get the image $image — not loaded"
        cat > /dev/null; return 2
    fi
    d="$(mktemp -d "${VERIFY_DIR}/deep.XXXXXX")"
    c="dbs-verify-$$-${BASHPID}-${RANDOM}"
    case "$kind" in
        redis|valkey)
            # No server needed: the checker reads the file
            cat > "$d/dump.rdb"; chmod 644 "$d/dump.rdb"; chmod 755 "$d"
            out="$(timeout "$tmo" docker run --rm --name "$c" --label docker-backup-s3.skip=true --network none \
                -v "$d/dump.rdb:/check/dump.rdb:ro" --entrypoint "${kind}-check-rdb" "$image" /check/dump.rdb 2>&1)" || rc=$?
            rm -rf "$d"
            if (( rc == 0 )) && grep -q 'RDB looks OK' <<< "$out"; then
                n="$(grep -oE '[0-9]+ keys read' <<< "$out" | head -n 1)"
                log_ok "    $name: ${kind}-check-rdb ($image): the RDB is sound${n:+, $n}"; return 0
            fi
            log_err "    $name: ${kind}-check-rdb ($image) rejects it: $(grep -iE 'error|fail|corrupt|unexpected' <<< "$out" | head -n 2 | tr '\n' ' ')"
            return 1 ;;
    esac

    log "    🧪 $name: loading into a throwaway $image (no network)..."
    case "$kind" in
        postgres) docker run -d --name "$c" --label docker-backup-s3.skip=true --network none \
                      -e POSTGRES_HOST_AUTH_METHOD=trust "$image" >/dev/null 2>"$d/run" || rc=$? ;;
        mysql)    docker run -d --name "$c" --label docker-backup-s3.skip=true --network none \
                      -e MYSQL_ALLOW_EMPTY_PASSWORD=yes -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 "$image" >/dev/null 2>"$d/run" || rc=$? ;;
        mongo)    docker run -d --name "$c" --label docker-backup-s3.skip=true --network none "$image" >/dev/null 2>"$d/run" || rc=$? ;;
    esac
    if (( rc != 0 )); then
        log_err "    $name: the database container did not start: $(head -n 1 "$d/run")"
        cat > /dev/null; rm -rf "$d"; return 1
    fi
    # Over TCP: the images first run a temporary server for their setup, then restart it
    local cli="mariadb"; [[ "$kind" == mysql && "$image" == mysql:* ]] && cli="mysql"
    local -a ready
    case "$kind" in
        postgres) ready=(pg_isready -q -h 127.0.0.1 -U postgres) ;;
        mysql)    ready=("$cli" -h127.0.0.1 --protocol=tcp -uroot -e 'select 1') ;;
        mongo)    ready=(mongosh --quiet --eval 'db.runCommand({ping: 1}).ok') ;;
    esac
    if ! _deep_wait "$c" "${ready[@]}"; then
        log_err "    $name: the $image server did not come up: $(docker logs --tail 3 "$c" 2>&1 | tr '\n' ' ')"
        cat > /dev/null; docker rm -f -v "$c" >/dev/null 2>&1; rm -rf "$d"; return 1
    fi

    rc=0
    case "$kind" in
        postgres)
            tee >(_deep_tables_expected postgres > "$d/expected") \
                | timeout "$tmo" docker exec -i "$c" psql -U postgres -h 127.0.0.1 -q -v ON_ERROR_STOP=0 -f - >/dev/null 2>"$d/err" || rc=$? ;;
        mysql)
            # A dump of all databases brings its own mysql.user, and the source's root password with it: the
            # tables are counted in the same session, after the dump
            { tee >(_deep_tables_expected mysql > "$d/expected")
              printf '\nSELECT CONCAT("DBS_TABLES=", COUNT(*)) FROM information_schema.tables WHERE table_type = "BASE TABLE" AND table_schema NOT IN ("mysql","sys","performance_schema","information_schema");\n'
            } | timeout "$tmo" docker exec -i "$c" "$cli" -uroot -h127.0.0.1 --protocol=tcp --force -N -B >"$d/out" 2>"$d/err" || rc=$? ;;
        mongo)
            timeout "$tmo" docker exec -i "$c" mongorestore --archive --quiet >/dev/null 2>"$d/err" || rc=$? ;;
    esac
    for _ in $(seq 1 100); do [[ "$kind" == mongo || -s "$d/expected" ]] && break; sleep 0.1; done
    if (( rc == 124 )); then
        log_err "    $name: still loading after ${tmo} s (VERIFY_DEEP_TIMEOUT) — stopped"
        docker rm -f -v "$c" >/dev/null 2>&1; rm -rf "$d"; return 1
    fi
    if (( rc != 0 )); then
        log_err "    $name: the load failed (exit code $rc): $(grep -v '^[[:space:]]*$' "$d/err" | tail -n 2 | tr '\n' ' ')"
        docker rm -f -v "$c" >/dev/null 2>&1; rm -rf "$d"; return 1
    fi

    # What is in the database now
    n=0
    case "$kind" in
        postgres)
            dbs="$(docker exec "$c" psql -U postgres -h 127.0.0.1 -Atc "select datname from pg_database where datallowconn and not datistemplate" 2>/dev/null)"
            while IFS= read -r db; do
                [[ -z "$db" ]] && continue
                n=$(( n + $(docker exec "$c" psql -U postgres -h 127.0.0.1 -d "$db" -Atc \
                    "select count(*) from pg_tables where schemaname not in ('pg_catalog','information_schema') and schemaname not like '\_timescaledb%' and schemaname not like 'timescaledb%'" 2>/dev/null || echo 0) ))
            done <<< "$dbs"
            errs="$(grep -E '^(psql:.*)?ERROR' "$d/err" | grep -v 'already exists' || true)" ;;
        mysql)
            n="$(sed -n 's/^DBS_TABLES=//p' "$d/out" | tail -n 1)"; n="${n:-?}"
            errs="$(grep -E '^ERROR' "$d/err" | grep -v 'already exists' || true)" ;;
        mongo)
            n="$(docker exec "$c" mongosh --quiet --eval 'let n = 0; db.adminCommand({listDatabases: 1}).databases.forEach(x => { if (!["admin", "local", "config"].includes(x.name)) n += db.getSiblingDB(x.name).getCollectionNames().length }); print(n)' 2>/dev/null || echo "?")"
            errs="$(grep -iE 'error|failed' "$d/err" || true)" ;;
    esac
    expected="$(cat "$d/expected" 2>/dev/null || true)"
    docker rm -f -v "$c" >/dev/null 2>&1
    rm -rf "$d"

    local what="tables"; [[ "$kind" == mongo ]] && what="collections"
    if [[ "$n" =~ ^[0-9]+$ && "$expected" =~ ^[0-9]+$ ]] && (( n < expected )); then
        log_err "    $name: loads, but only $n of the dump's $expected $what are there"
        return 1
    fi
    log_ok "    $name: loads into $image — ${n} ${what}${expected:+ (the dump creates $expected)}"
    if [[ -n "$errs" ]]; then
        log_warn "    $name: $(grep -c . <<< "$errs") error(s) while loading, the first: $(head -n 1 <<< "$errs" | cut -c1-200)"
    fi
    return 0
}

# deep_dump <file.gz> <postgres|mysql|redis|mongo> — deep_load of a dump on this disk; its return code
deep_dump() {
    local f="$1" kind="$2" head
    head="$(gunzip -c "$f" 2>/dev/null | head -c 16384 || true)"
    # The extension that picks the image may come long after the start (pg_dumpall: roles, then each database)
    [[ "$kind" == postgres ]] && head+=$'\n'"$(gunzip -c "$f" 2>/dev/null | grep -m 1 -E '^CREATE EXTENSION .*timescaledb' || true)"
    gunzip -c "$f" | deep_load "$kind" "$(basename "$f")" "$head"
}

# sealed_note <project> — a public-key archive, and no secret key here: it is whole (sha256), but what is inside
# was not checked. Counted as passed, listed in the summary (SEALED).
SEALED=()
sealed_note() {
    log_warn "Encrypted to a public key, and its secret key is not on this host: the archive is whole (sha256), its contents are not checked"
    log "    For the full check set GPG_SECRET_KEY_FILE — on a restore host, not on the one that makes the backups"
    SEALED+=("$1")
}

# List of projects in S3
list_s3_projects() {
    aws_q s3api list-objects-v2 \
        --bucket "$SRC_BUCKET" \
        --prefix "${BACKUP_PREFIX}/" \
        --delimiter "/" \
        --query 'CommonPrefixes[].Prefix' \
        --output text 2>/dev/null \
        | tr '\t' '\n' \
        | sed "s|^${BACKUP_PREFIX}/||; s|/$||" \
        | grep -v '^$' \
        | sort
}

# Latest timestamp for a project
latest_timestamp_of() {
    local project="$1"
    aws_q s3api list-objects-v2 \
        --bucket "$SRC_BUCKET" \
        --prefix "${BACKUP_PREFIX}/${project}/" \
        --delimiter "/" \
        --query 'CommonPrefixes[].Prefix' \
        --output text 2>/dev/null \
        | tr '\t' '\n' \
        | sed "s|^${BACKUP_PREFIX}/${project}/||; s|/$||" \
        | grep -v '^$' \
        | sort -r \
        | head -1
}

# Archive name for project/timestamp
find_archive_name() {
    local project="$1" timestamp="$2"
    # .sha256 is the manifest next to the archive, not the archive itself
    aws_q s3api list-objects-v2 \
        --bucket "$SRC_BUCKET" \
        --prefix "${BACKUP_PREFIX}/${project}/${timestamp}/" \
        --query 'Contents[].Key' --output text 2>/dev/null \
        | tr '\t' '\n' | grep -v '\.sha256$' | head -1 \
        | xargs -I{} basename {}
}

# verify_remote_dump <project> <s3 key> <file name> — the full check of a remote database's dump without a copy
# on this disk: download | sha256 | decrypt | gunzip (which checks the gzip CRC), the first 64 KB kept to tell
# what made the dump.
verify_remote_dump() {
    local project="$1" key="$2" name="$3" d st expected rc_aws rc_tee rc_gpg rc_gz head kind sealed=false
    d="${VERIFY_DIR}/${project}"
    mkdir -p "$d"
    # Encrypted to a public key whose secret key is not on this host: the checksum is all that can be checked
    if [[ "$name" == *.gpg ]] && aws_q s3api get-object --bucket "$SRC_BUCKET" --key "$key" --range bytes=0-65535 "$d/start" >/dev/null 2>&1 \
        && [[ "$(gpg_kind "$d/start")" == pubkey ]] && ! gpg_can_decrypt; then
        sealed=true
    fi
    rm -f "$d/start"
    if $sealed; then log "  🗄  A remote database's dump, encrypted to a public key: download and sha256 only"
    else log "  🗄  A remote database's dump: checking it as it streams by (download, sha256, decrypt, gunzip)"; fi
    st="$(
        set +e
        aws_q s3 cp "s3://${SRC_BUCKET}/${key}" - \
            | tee >(sha256sum | awk '{print $1}' > "$d/sum") \
            | if $sealed; then cat > /dev/null; elif [[ "$name" == *.gpg ]]; then gpg_dec; else cat; fi \
            | if $sealed; then cat; else gunzip -c 2> "$d/gz"; fi \
            | { head -c 65536 > "$d/head"; cat > /dev/null; }
        printf '%s ' "${PIPESTATUS[@]}"
    )"
    IFS=' ' read -r rc_aws rc_tee rc_gpg rc_gz _ <<< "$st"
    for _ in $(seq 1 100); do [[ -s "$d/sum" ]] && break; sleep 0.1; done
    if [[ "${rc_aws:-1}" != 0 ]]; then
        log_err "Download failed"; FAILED_PROJECTS+=("$project"); FAILURE_REASONS+=("Download error"); return 1
    fi
    if expected="$(aws_q s3 cp "s3://${SRC_BUCKET}/${key}.sha256" - 2>/dev/null | awk '{print $1}' | head -n 1)" && [[ -n "$expected" ]]; then
        if [[ "$(cat "$d/sum" 2>/dev/null)" == "$expected" ]]; then
            log_ok "sha256 matches"
        else
            log_err "sha256 does NOT match — the object in S3 is corrupted"
            FAILED_PROJECTS+=("$project"); FAILURE_REASONS+=("sha256 mismatch (corruption in the storage)"); return 1
        fi
    else
        log_warn "No sha256 manifest — checking by size only"
    fi
    if $sealed; then
        sealed_note "$project"; rm -rf "$d"; return 0
    fi
    if [[ "${rc_gpg:-1}" != 0 ]]; then
        log_err "Decryption failed"; FAILED_PROJECTS+=("$project"); FAILURE_REASONS+=("GPG decryption"); return 1
    fi
    if [[ "${rc_gz:-1}" != 0 ]]; then
        log_err "The dump is corrupted: $(head -n 1 "$d/gz" 2>/dev/null)"
        FAILED_PROJECTS+=("$project"); FAILURE_REASONS+=("Corrupted dump (gzip)"); return 1
    fi
    head="$(head -c 4096 "$d/head" 2>/dev/null | tr -d '\0' || true)"
    case "$name" in
        *.sql.gz*)
            if grep -qE 'PostgreSQL database (cluster )?dump|^--[[:space:]]+PostgreSQL' <<< "$head"; then kind="PostgreSQL dump"
            elif grep -qE -- '-- (MySQL|MariaDB) dump|mysqldump|mariadb-dump|^-- Server version' <<< "$head"; then kind="MySQL/MariaDB dump"
            fi ;;
        *.rdb.gz*)
            [[ "$head" == REDIS* || "$head" == VALKEY* ]] && kind="Redis RDB" ;;
        *.archive.gz*)
            [[ "$(od -An -tx1 -N4 "$d/head" | tr -d ' \n')" == 6de29981 ]] && kind="MongoDB archive" ;;
    esac
    if [[ -z "${kind:-}" ]]; then
        log_err "gzip is intact, but it is not the dump its name says ($name)"
        FAILED_PROJECTS+=("$project"); FAILURE_REASONS+=("Not a database dump"); return 1
    fi
    log_ok "$kind, intact"
    if [[ "$MODE" == deep ]]; then
        # Streamed once more, straight into the throwaway database: the dump may be too big for this disk
        local dk drc=0
        case "$kind" in PostgreSQL*) dk=postgres ;; MySQL*) dk=mysql ;; Redis*) dk=redis ;; *) dk=mongo ;; esac
        aws_q s3 cp "s3://${SRC_BUCKET}/${key}" - 2>/dev/null \
            | if [[ "$name" == *.gpg ]]; then gpg_dec 2>/dev/null; else cat; fi \
            | gunzip -c 2>/dev/null \
            | deep_load "$dk" "$name" "$(head -c 65536 "$d/head" 2>/dev/null | tr -d '\0')" || drc=$?
        if (( drc == 1 )); then
            FAILED_PROJECTS+=("$project"); FAILURE_REASONS+=("The dump does not load (deep check)"); rm -rf "$d"; return 1
        fi
    fi
    log_ok "${C_BOLD}Check passed${C_RESET}"
    rm -rf "$d"
    return 0
}

# ==============================================================================
# CHECKING ONE PROJECT
# ==============================================================================
verify_project() {
    local project="$1"
    local timestamp archive_name s3_size local_size

    log ""
    log "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    log "${C_BOLD}🔍 Checking: $project${C_RESET}"
    log "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"

    # 1. Find the latest backup
    timestamp=$(latest_timestamp_of "$project")
    if [[ -z "$timestamp" ]]; then
        log_err "No backups for $project"
        FAILED_PROJECTS+=("$project")
        FAILURE_REASONS+=("No backups $(s3_label "$FROM_ROLE" in)")
        return 1
    fi
    log "  📅 Timestamp: $timestamp"

    # Age
    local age
    if age="$(ts_age "$timestamp")"; then log "  ⏱  Age: $age"; fi

    # 2. Archive
    archive_name=$(find_archive_name "$project" "$timestamp")
    if [[ -z "$archive_name" || "$archive_name" == "None" ]]; then
        log_err "Cannot find the archive for $project @ $timestamp"
        FAILED_PROJECTS+=("$project")
        FAILURE_REASONS+=("Archive not found")
        return 1
    fi

    local s3_key="${BACKUP_PREFIX}/${project}/${timestamp}/${archive_name}"

    # 3. Size via head-object
    s3_size=$(aws_q s3api head-object \
        --bucket "$SRC_BUCKET" --key "$s3_key" \
        --query ContentLength --output text 2>/dev/null || echo 0)

    if [[ "$s3_size" == "0" || -z "$s3_size" ]]; then
        log_err "head-object returned a zero size"
        FAILED_PROJECTS+=("$project")
        FAILURE_REASONS+=("Zero size $(s3_label "$FROM_ROLE" in)")
        return 1
    fi

    local size_mb=$((s3_size / 1048576))
    log_ok "Size $(s3_label "$FROM_ROLE" in): ${size_mb} MB"

    # ─── QUICK MODE: stop here ───
    if [[ "$MODE" == "quick" ]]; then
        log_ok "Quick check passed"
        return 0
    fi

    # A remote database's dump (_db_<name>): checked as it streams by, it may be too big for this disk
    if [[ "$project" == _db_* ]]; then
        verify_remote_dump "$project" "$s3_key" "$archive_name"
        return
    fi

    # 4. Download
    local proj_dir="${VERIFY_DIR}/${project}"
    mkdir -p "$proj_dir"
    local local_archive="${proj_dir}/${archive_name}"

    log "  ⬇  Downloading..."
    # Progress on a terminal; in a log (cron) a progress line per chunk is noise — errors only there
    local -a quiet=(); [[ -t 2 ]] || quiet=(--only-show-errors)
    if ! aws_q s3 cp "s3://${SRC_BUCKET}/${s3_key}" "$local_archive" ${quiet[@]+"${quiet[@]}"}; then
        log_err "Download failed"
        FAILED_PROJECTS+=("$project")
        FAILURE_REASONS+=("Download error")
        return 1
    fi

    local_size=$(stat -c %s "$local_archive")
    if [[ "$local_size" != "$s3_size" ]]; then
        log_err "Size mismatch: S3=$s3_size, downloaded=$local_size"
        FAILED_PROJECTS+=("$project")
        FAILURE_REASONS+=("Size mismatch (corruption?)")
        return 1
    fi
    log_ok "Size matches after download"

    # 4b. Check against the sha256 manifest, if there is one. Matching sizes say nothing
    # about the content — it's the hash that catches corruption that appeared in the storage.
    if aws_q s3 cp "s3://${SRC_BUCKET}/${s3_key}.sha256" "${local_archive}.sha256" >/dev/null 2>&1; then
        if verify_checksum_file "$local_archive" "${local_archive}.sha256"; then
            log_ok "sha256 matches"
        else
            log_err "sha256 does NOT match — the object in S3 is corrupted"
            FAILED_PROJECTS+=("$project")
            FAILURE_REASONS+=("sha256 mismatch (corruption in the storage)")
            return 1
        fi
    else
        log_warn "No sha256 manifest — checking by size only"
    fi

    # 5. Decrypt if needed
    local work_archive="$local_archive"
    if [[ "$archive_name" == *.gpg && "$(gpg_kind "$local_archive")" == pubkey ]] && ! gpg_can_decrypt; then
        sealed_note "$project"
        return 0
    fi
    if [[ "$archive_name" == *.gpg ]]; then
        log "  🔐 Decrypting..."
        if work_archive=$(decrypt_file "$local_archive"); then
            log_ok "Decryption succeeded"
        else
            log_err "Decryption failed"
            FAILED_PROJECTS+=("$project")
            FAILURE_REASONS+=("GPG decryption")
            return 1
        fi
    fi

    # 6. tar.gz integrity check
    log "  📦 Checking archive integrity (tar tzf)..."
    if ! tar tzf "$work_archive" >/dev/null 2>&1; then
        log_err "The archive is corrupted (tar tzf failed)"
        FAILED_PROJECTS+=("$project")
        FAILURE_REASONS+=("Corrupted tar.gz")
        return 1
    fi

    # Count the files
    local files_count
    files_count=$(tar tzf "$work_archive" 2>/dev/null | wc -l)
    log_ok "The archive is intact, files inside: $files_count"

    # 7. Unpack
    log "  📂 Unpacking..."
    local extract_dir="${proj_dir}/extracted"
    mkdir -p "$extract_dir"
    if ! tar xzf "$work_archive" -C "$extract_dir" 2>&1 | head -5; then
        log_err "Unpacking failed"
        FAILED_PROJECTS+=("$project")
        FAILURE_REASONS+=("Could not unpack")
        return 1
    fi
    log_ok "Unpacked into $extract_dir"

    # 8. Check that metadata.txt, containers.tsv are there
    local proj_inner="${extract_dir}/${project}"
    if [[ ! -d "$proj_inner" ]]; then
        log_err "No $project folder inside the archive"
        FAILED_PROJECTS+=("$project")
        FAILURE_REASONS+=("Broken archive structure")
        return 1
    fi

    if [[ ! -f "${proj_inner}/metadata.txt" ]]; then
        log_warn "No metadata.txt in the archive"
    fi

    # 9. Check project_dir.tar.gz inside
    if [[ -f "${proj_inner}/project_dir.tar.gz" ]]; then
        log "  📂 Checking project_dir.tar.gz..."
        if tar tzf "${proj_inner}/project_dir.tar.gz" >/dev/null 2>&1; then
            log_ok "project_dir.tar.gz is intact"
        else
            log_err "project_dir.tar.gz is corrupted"
            FAILED_PROJECTS+=("$project")
            FAILURE_REASONS+=("Corrupted project_dir.tar.gz")
            return 1
        fi
    fi

    # 10. Check the volumes
    if [[ -d "${proj_inner}/volumes" ]]; then
        local vol_count vol_failed=0
        vol_count=$(find "${proj_inner}/volumes" -maxdepth 1 -name "volume_*.tar.gz" 2>/dev/null | wc -l)
        if [[ "$vol_count" -gt 0 ]]; then
            log "  💾 Checking volumes (${vol_count}):"
            for vol_archive in "${proj_inner}/volumes/"volume_*.tar.gz; do
                [[ -f "$vol_archive" ]] || continue
                vol_name=$(basename "$vol_archive" .tar.gz)
                if tar tzf "$vol_archive" >/dev/null 2>&1; then
                    log_ok "    $vol_name"
                else
                    log_err "    $vol_name — corrupted"
                    vol_failed=$((vol_failed + 1))
                fi
            done
            if [[ "$vol_failed" -gt 0 ]]; then
                FAILED_PROJECTS+=("$project")
                FAILURE_REASONS+=("Corrupted volumes ($vol_failed)")
                return 1
            fi
        fi
    fi

    # 11. Check DB dumps if any (taken out of project_dir.tar.gz)
    if [[ -f "${proj_inner}/project_dir.tar.gz" ]]; then
        local pd_dir="${proj_dir}/project_dir_extracted"
        mkdir -p "$pd_dir"
        tar xzf "${proj_inner}/project_dir.tar.gz" -C "$pd_dir" 2>/dev/null || true

        # Look for db-dumps
        local dumps_dir
        dumps_dir=$(find "$pd_dir" -maxdepth 3 -type d -name "db-dumps" 2>/dev/null | head -1)

        if [[ -n "$dumps_dir" && -d "$dumps_dir" ]]; then
            log "  🗄  Checking DB dumps in $(basename "$(dirname "$dumps_dir")")/db-dumps/..."
            local dump_failed=0 drc

            # PostgreSQL dumps
            for d in "$dumps_dir"/postgres_*.sql.gz; do
                [[ -f "$d" ]] || continue
                local name; name=$(basename "$d")
                # gunzip integrity
                if gunzip -t "$d" 2>/dev/null; then
                    # Check that it starts with a PostgreSQL header
                    if [[ "$(dump_kind "$d")" == postgres ]]; then
                        local lines; lines=$(gunzip -c "$d" 2>/dev/null | wc -l)
                        log_ok "    $name (PostgreSQL, $lines lines)"
                        if [[ "$MODE" == deep ]]; then drc=0; deep_dump "$d" postgres || drc=$?; if (( drc == 1 )); then dump_failed=$((dump_failed + 1)); fi; fi
                    else
                        log_warn "    $name — gzip is intact, but it doesn't look like pg_dumpall"
                    fi
                else
                    log_err "    $name — corrupted gzip"
                    dump_failed=$((dump_failed + 1))
                fi
            done

            # MySQL dumps
            for d in "$dumps_dir"/mysql_*.sql.gz "$dumps_dir"/mariadb_*.sql.gz; do
                [[ -f "$d" ]] || continue
                local name; name=$(basename "$d")
                if gunzip -t "$d" 2>/dev/null; then
                    if [[ "$(dump_kind "$d")" == mysql ]]; then
                        local lines; lines=$(gunzip -c "$d" 2>/dev/null | wc -l)
                        log_ok "    $name (MySQL, $lines lines)"
                        if [[ "$MODE" == deep ]]; then drc=0; deep_dump "$d" mysql || drc=$?; if (( drc == 1 )); then dump_failed=$((dump_failed + 1)); fi; fi
                    else
                        log_warn "    $name — gzip is intact, but it doesn't look like a mysqldump/mariadb-dump"
                    fi
                else
                    log_err "    $name — corrupted gzip"
                    dump_failed=$((dump_failed + 1))
                fi
            done

            # Redis dumps (RDB)
            for d in "$dumps_dir"/redis_*.rdb.gz; do
                [[ -f "$d" ]] || continue
                local name; name=$(basename "$d")
                if gunzip -t "$d" 2>/dev/null; then
                    # RDB starts with the "REDIS" magic ("VALKEY" in Valkey 9+). `|| true`: on a big file
                    # gunzip gets SIGPIPE from head, and under pipefail + set -e that ended the whole check.
                    local magic; magic=$(gunzip -c "$d" 2>/dev/null | head -c 6 || true)
                    if [[ "$magic" == REDIS* || "$magic" == VALKEY ]]; then
                        local size; size=$(stat -c %s "$d")
                        log_ok "    $name (Redis RDB, $size bytes)"
                        if [[ "$MODE" == deep ]]; then drc=0; deep_dump "$d" redis || drc=$?; if (( drc == 1 )); then dump_failed=$((dump_failed + 1)); fi; fi
                    else
                        log_warn "    $name — gzip is intact, but it is not an RDB file (no REDIS/VALKEY magic)"
                    fi
                else
                    log_err "    $name — corrupted gzip"
                    dump_failed=$((dump_failed + 1))
                fi
            done

            # Mongo dumps: a mongodump archive (.tar.gz before 2.0.0 — the same thing under a wrong name)
            for d in "$dumps_dir"/mongo_*.archive.gz "$dumps_dir"/mongo_*.tar.gz; do
                [[ -f "$d" ]] || continue
                local name; name=$(basename "$d")
                if gunzip -t "$d" 2>/dev/null; then
                    # The archive starts with the magic number 0x8199e26d (little-endian)
                    local magic; magic=$(gunzip -c "$d" 2>/dev/null | od -An -tx1 -N4 | tr -d ' \n' || true)
                    if [[ "$magic" == 6de29981 ]]; then
                        log_ok "    $name (MongoDB archive)"
                        if [[ "$MODE" == deep ]]; then drc=0; deep_dump "$d" mongo || drc=$?; if (( drc == 1 )); then dump_failed=$((dump_failed + 1)); fi; fi
                    else
                        log_warn "    $name — gzip is intact, but it is not a mongodump archive"
                    fi
                else
                    log_err "    $name — corrupted gzip"
                    dump_failed=$((dump_failed + 1))
                fi
            done

            if [[ "$dump_failed" -gt 0 ]]; then
                FAILED_PROJECTS+=("$project")
                FAILURE_REASONS+=("DB dumps that fail the check ($dump_failed)")
                return 1
            fi
        fi
    fi

    log_ok "${C_BOLD}Check passed${C_RESET}"
    rm -rf "$proj_dir"
    return 0
}

# ==============================================================================
# MAIN FLOW
# ==============================================================================
log "${C_BOLD}${C_BLUE}═══════════════════════════════════════════════════════════════${C_RESET}"
log "${C_BOLD}🧪 Checking that backups can be restored${C_RESET}"
log "${C_BOLD}${C_BLUE}═══════════════════════════════════════════════════════════════${C_RESET}"
log "Mode: ${C_BOLD}$MODE${C_RESET}"
log "Storage: $(s3_label "$FROM_ROLE"), s3://${SRC_BUCKET}/${BACKUP_PREFIX}/"

# Get the list of projects
declare -a PROJECTS_TO_CHECK=()

if [[ -n "$PROJECT_FILTER" ]]; then
    PROJECTS_TO_CHECK+=("$PROJECT_FILTER")
    log "Project: $PROJECT_FILTER"
else
    log "Scanning all projects $(s3_label "$FROM_ROLE" in)..."
    mapfile -t PROJECTS_TO_CHECK < <(list_s3_projects)
    log "Projects found: ${#PROJECTS_TO_CHECK[@]}"
fi

if [[ ${#PROJECTS_TO_CHECK[@]} -eq 0 ]]; then
    log_warn "No projects to check"
    heartbeat success "nothing to check" "No projects in the storage yet."
    exit 0
fi

TOTAL_PROJECTS=${#PROJECTS_TO_CHECK[@]}

# Check each one
for proj in "${PROJECTS_TO_CHECK[@]}"; do
    if verify_project "$proj"; then
        TOTAL_OK=$((TOTAL_OK + 1))
    else
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
done

# ==============================================================================
# SUMMARY
# ==============================================================================
VR_DONE="true"   # from here the summary reports the result itself
TOTAL_DURATION=$(($(date +%s) - SESSION_START))

# The result of a whole check, for status.sh (and an external monitor, by the file's age)
LAST_VERIFY_FILE="${LAST_VERIFY_FILE:-/var/lib/docker-backup/last-verify.json}"
if [[ -z "$PROJECT_FILTER" ]] && mkdir -p "$(dirname "$LAST_VERIFY_FILE")" 2>/dev/null; then
    printf '{"finished":"%s","ok":%s,"checked":%d,"failed":%d,"mode":"%s","from":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$([[ "$TOTAL_FAIL" -eq 0 ]] && echo true || echo false)" \
        "$TOTAL_PROJECTS" "$TOTAL_FAIL" "$MODE" "$FROM_ROLE" > "${LAST_VERIFY_FILE}.tmp" \
        && mv "${LAST_VERIFY_FILE}.tmp" "$LAST_VERIFY_FILE"
    chmod 644 "$LAST_VERIFY_FILE" 2>/dev/null || true
fi
if [[ -z "$PROJECT_FILTER" && "$FROM_ROLE" == "primary" ]]; then
    metrics_write docker_backup_s3_verify docker_backup_s3_verify "$([[ "$TOTAL_FAIL" -eq 0 ]] && echo 1 || echo 0)" \
        projects "$TOTAL_PROJECTS" projects_failed "$TOTAL_FAIL" duration_seconds "$TOTAL_DURATION"
fi

log ""
log "${C_BOLD}${C_BLUE}═══════════════════════════════════════════════════════════════${C_RESET}"
if [[ "$TOTAL_FAIL" -eq 0 ]]; then
    log "${C_GREEN}${C_BOLD}✅ ALL CHECKS PASSED${C_RESET}"
    log "    Checked: ${TOTAL_OK}/${TOTAL_PROJECTS}"
    log "    Mode:    $MODE"
    log "    Time:    $(fmt_duration $TOTAL_DURATION)"
    sealed_txt=""
    if (( ${#SEALED[@]} )); then
        sealed_txt="${#SEALED[@]} encrypted to a public key without its secret key here: checked by sha256 only ($(IFS=,; printf '%s' "${SEALED[*]}" | sed 's/,/, /g'))."
        log "    ${C_YELLOW}${sealed_txt}${C_RESET}"
    fi

    # Always through notify: it sends the message only with NOTIFY_ON=always, but the monitor's ping and
    # PagerDuty's resolve go whatever NOTIFY_ON says
    pass_msg="Checked ${TOTAL_OK} of ${TOTAL_PROJECTS} $(plural "$TOTAL_PROJECTS" project projects) (${MODE} mode) in $(fmt_duration $TOTAL_DURATION)."
    [[ -n "$sealed_txt" ]] && pass_msg+=$'\n'"$(html_esc "$sealed_txt")"
    if [[ "$NOTIFY" == "true" ]]; then notify success "backups restore fine" "$pass_msg"
    else heartbeat success "backups restore fine" "$pass_msg"; fi
else
    log "${C_RED}${C_BOLD}❌ PROBLEMS WITH BACKUPS FOUND${C_RESET}"
    log "    Succeeded: ${TOTAL_OK}/${TOTAL_PROJECTS}"
    log "    Errors:    ${TOTAL_FAIL}"
    log ""
    log "    ${C_RED}Problematic projects:${C_RESET}"
    for i in "${!FAILED_PROJECTS[@]}"; do
        log "      • ${FAILED_PROJECTS[$i]}: ${FAILURE_REASONS[$i]}"
    done
    log "    Time: $(fmt_duration $TOTAL_DURATION)"

    reasons=""
    for i in "${!FAILED_PROJECTS[@]}"; do
        reasons+=$'\n'"• <b>$(html_esc "${FAILED_PROJECTS[$i]}")</b>: $(html_esc "${FAILURE_REASONS[$i]}")"
    done
    fail_msg="Restore check: ${TOTAL_FAIL} of ${TOTAL_PROJECTS} failed.${reasons}"$'\n'"$(notify_log_hint)"
    if [[ "$NOTIFY" == "true" ]]; then notify error "a backup does not restore" "$fail_msg"
    else heartbeat fail "a backup does not restore" "$fail_msg"; fi
fi
log "${C_BOLD}${C_BLUE}═══════════════════════════════════════════════════════════════${C_RESET}"

[[ "$TOTAL_FAIL" -eq 0 ]] && exit 0 || exit 1
