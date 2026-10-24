#!/usr/bin/env bash
# ==============================================================================
# drop-project.sh — remove from S3 the copies of a project that is no longer backed up.
#
# Each project's rotation keeps its last KEEP_MIN_BACKUPS copies, so
# the folder of a project that was renamed or removed from the server stays in S3
# forever. A typical case: mailcow-dockerized — a second archive of the mailcow folder under the
# directory name (older versions did that), next to the real project mailcowdockerized.
#
# Without --yes it only shows what is in every storage. Deletes one
# object at a time (like rotation). Refuses to delete a project that has containers
# on the server: that's a live backup, not an abandoned folder.
#
#   sudo ./drop-project.sh mailcow-dockerized          # look
#   sudo ./drop-project.sh mailcow-dockerized --yes    # delete — IRREVERSIBLE
#   -c, --config FILE   config file (default: backup.conf next to the script)
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/backup.conf"
NAME=""
YES="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)       YES="true"; shift ;;
        -c|--config)    CONFIG_FILE="$2"; shift 2 ;;
        -h|--help)      sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)             echo "Unknown argument: $1" >&2; exit 1 ;;
        *)              NAME="$1"; shift ;;
    esac
done

[[ -n "$NAME" ]] || { echo "Give the project name: $0 <project> [--yes]" >&2; exit 1; }
[[ "$NAME" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Odd project name: $NAME" >&2; exit 1; }
[[ -f "$CONFIG_FILE" ]] || { echo "❌ Config not found: $CONFIG_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG_FILE"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
require_cmd aws

if [[ -n "$(docker ps -aq --filter "label=com.docker.compose.project=${NAME}" 2>/dev/null || true)" ]]; then
    fail "Project ${NAME} has containers on this server — it's a live backup, not deleting."
fi
if [[ "$NAME" == _db_* ]] && remote_db_names | grep -qxF -- "${NAME#_db_}"; then
    fail "${NAME#_db_} is in REMOTE_DBS — a live backup of a remote database, not deleting. Take it out of REMOTE_DBS first."
fi

PREFIX="${BACKUP_PREFIX}/${NAME}/"   # with the slash: mailcow-dockerized/ doesn't touch mailcowdockerized/

# list_keys <role> — "key<TAB>size", one line per object.
list_keys() {
    _aws_setup "$1"
    aws_q s3api list-objects-v2 --bucket "$S3_CUR_BUCKET" --prefix "$PREFIX" \
        --query 'Contents[].[Key,Size]' --output text 2>/dev/null | grep -v '^None$' || true
}

# drop <role>
drop() {
    local role="$1" bucket label keys total=0 n=0 failed=0 key size
    bucket="$(s3_var "$role" BUCKET)"
    label="$(s3_label "$role" title) ($(s3_host "$(s3_var "$role" ENDPOINT)"))"
    keys="$(list_keys "$role")"
    if [[ -z "$keys" ]]; then
        log "  ${label}: nothing under s3://${bucket}/${PREFIX}"
        return 0
    fi
    while IFS=$'\t' read -r key size; do
        n=$((n + 1)); total=$((total + size))
    done <<< "$keys"
    log "  ${label}: ${n} $(plural "$n" object objects), $((total / 1048576)) MB under s3://${bucket}/${PREFIX}"
    printf '%s\n' "$keys" | cut -f1 | sed 's|.*/\([^/]*/[^/]*\)$|      • \1|' | head -20
    (( n > 20 )) && log "      … $((n - 20)) more"
    [[ "$YES" == "true" ]] || return 0
    _aws_setup "$role"
    while IFS=$'\t' read -r key size; do
        aws_rm "s3://${bucket}/${key}" || { failed=$((failed + 1)); log_warn "  not deleted: $key"; }
    done <<< "$keys"
    if (( failed == 0 )); then
        log_ok "  ${label}: deleted ${n}"
    else
        log_err "  ${label}: could not delete ${failed} of ${n}"
        return 1
    fi
}

log "Project ${NAME} in S3$([[ "$YES" == "true" ]] && echo ' — DELETING' || echo ' (view only, to delete: --yes)')"
rc=0
for role in primary ${S3_COPIES[@]+"${S3_COPIES[@]}"}; do
    drop "$role" || rc=1
done
exit $rc
