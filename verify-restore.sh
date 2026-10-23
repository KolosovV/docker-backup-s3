#!/usr/bin/env bash
# ==============================================================================
# verify-restore.sh
# Automatic check that backups can be restored.
#
# What it does:
#   1. Takes the latest backup of the given project (or of all)
#   2. Downloads it into /tmp/verify-restore-XXX
#   3. Unpacks it, decrypts if needed
#   4. Checks tar integrity and file sizes
#   5. Checks that database dumps are valid (headers, gzip integrity)
#   6. Cleans up after itself
#   7. Sends a Telegram notification if something is wrong
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
MODE="standard"   # quick | standard
NOTIFY="true"
FROM_ROLE="primary"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)    CONFIG_FILE="$2"; shift 2 ;;
        -p|--project)   PROJECT_FILTER="$2"; shift 2 ;;
        --quick)        MODE="quick"; shift ;;
        --no-notify)    NOTIFY="false"; shift ;;
        --from)         FROM_ROLE="$2"; shift 2 ;;
        -h|--help)
            cat <<EOF
Usage: $0 [options]

Checks that backups can be restored.

  -c, --config FILE    config file (default: backup.conf)
  -p, --project NAME   check only the given project
      --quick          only the object's presence and size in S3, no download
      --no-notify      don't send a notification
      --from ROLE      which storage to check: primary (default), secondary, tertiary
  -h, --help           this help

CHECK LEVELS:
  quick:    head-object — the object is there and non-empty (downloads nothing)
  standard: download → check size and sha256 → unpack → check tar
            and database dumps (default)

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

require_cmd docker tar gzip aws jq
[[ "${ENCRYPT_BACKUPS:-false}" == "true" ]] && require_cmd gpg

# The storage to check; the read-only key, if set
s3_is_role "$FROM_ROLE" || fail "Unknown storage: $FROM_ROLE (available: $(s3_roles_txt))"
s3_enabled "$FROM_ROLE" || fail "$(s3_label "$FROM_ROLE" title) is not enabled (${FROM_ROLE^^}_S3_ENABLED != true)"
_aws_setup "$FROM_ROLE" read
SRC_BUCKET="$S3_CUR_BUCKET"

# --- Working folder ---
VERIFY_DIR="/tmp/verify-restore-$$"
mkdir -p "$VERIFY_DIR"
trap 'rm -rf "$VERIFY_DIR"' EXIT

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
    local local_dt epoch age_days
    local_dt=$(echo "$timestamp" | sed 's/_/ /; s/-/:/3; s/-/:/3')
    if epoch=$(date -d "$local_dt" +%s 2>/dev/null); then
        age_days=$(( ($(date +%s) - epoch) / 86400 ))
        log "  ⏱  Age: $age_days d"
    fi

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
            local dump_failed=0

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
                    # RDB starts with the "REDIS" magic
                    local magic; magic=$(gunzip -c "$d" 2>/dev/null | head -c 5)
                    if [[ "$magic" == "REDIS" ]]; then
                        local size; size=$(stat -c %s "$d")
                        log_ok "    $name (Redis RDB, $size bytes)"
                    else
                        log_warn "    $name — gzip is intact, but the magic is not REDIS"
                    fi
                else
                    log_err "    $name — corrupted gzip"
                    dump_failed=$((dump_failed + 1))
                fi
            done

            # Mongo dumps
            for d in "$dumps_dir"/mongo_*.tar.gz; do
                [[ -f "$d" ]] || continue
                local name; name=$(basename "$d")
                if gunzip -t "$d" 2>/dev/null; then
                    log_ok "    $name (MongoDB)"
                else
                    log_err "    $name — corrupted gzip"
                    dump_failed=$((dump_failed + 1))
                fi
            done

            if [[ "$dump_failed" -gt 0 ]]; then
                FAILED_PROJECTS+=("$project")
                FAILURE_REASONS+=("Corrupted DB dumps ($dump_failed)")
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
TOTAL_DURATION=$(($(date +%s) - SESSION_START))

log ""
log "${C_BOLD}${C_BLUE}═══════════════════════════════════════════════════════════════${C_RESET}"
if [[ "$TOTAL_FAIL" -eq 0 ]]; then
    log "${C_GREEN}${C_BOLD}✅ ALL CHECKS PASSED${C_RESET}"
    log "    Checked: ${TOTAL_OK}/${TOTAL_PROJECTS}"
    log "    Mode:    $MODE"
    log "    Time:    $(fmt_duration $TOTAL_DURATION)"

    if [[ "$NOTIFY" == "true" && "${NOTIFY_ON:-error}" == "always" ]]; then
        notify success "backups restore fine" "Checked ${TOTAL_OK} of ${TOTAL_PROJECTS} $(plural "$TOTAL_PROJECTS" project projects) (${MODE} mode) in $(fmt_duration $TOTAL_DURATION)."
    fi
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

    if [[ "$NOTIFY" == "true" ]]; then
        reasons=""
        for i in "${!FAILED_PROJECTS[@]}"; do
            reasons+=$'\n'"• <b>$(html_esc "${FAILED_PROJECTS[$i]}")</b>: $(html_esc "${FAILURE_REASONS[$i]}")"
        done
        notify error "a backup does not restore" "Restore check: ${TOTAL_FAIL} of ${TOTAL_PROJECTS} failed.${reasons}"$'\n'"$(notify_log_hint)"
    fi
fi
log "${C_BOLD}${C_BLUE}═══════════════════════════════════════════════════════════════${C_RESET}"

[[ "$TOTAL_FAIL" -eq 0 ]] && exit 0 || exit 1
