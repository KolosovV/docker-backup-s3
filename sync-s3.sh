#!/usr/bin/env bash
# ==============================================================================
# sync-s3.sh  (formerly sync-secondary.sh)
# Synchronization between storages: the primary and the copies (secondary, tertiary).
#
# By default — primary → EVERY enabled copy: the primary S3 is the "source
# of truth", the copies are brought in line with it. --to ROLE — into one copy only.
#
# --reverse — the other way: copy → primary (secondary by default, --from ROLE —
# another one). This is a DISASTER RECOVERY scenario: use it only if the PRIMARY
# lost data and an intact copy remains. Writing to the primary always requires
# confirmation.
#
# In any direction:
#   • objects missing in the destination  → copied from the source
#   • object size differs                 → re-uploaded from the source
#   • objects missing in the source       → NOT touched (only with --prune)
#
# Copying goes through a temporary file (download from the source → upload to
# the destination → check the size), since these are different providers/endpoints and
# a server-side copy between them is impossible.
#
# Usage:
#   sudo ./sync-s3.sh                    # primary → all enabled copies
#   sudo ./sync-s3.sh --to tertiary      # primary → tertiary only
#   sudo ./sync-s3.sh --dry-run          # show the plan, change nothing
#   sudo ./sync-s3.sh --prune            # + delete extras in the destination
#   sudo ./sync-s3.sh --reverse          # secondary → primary (DR!)
#   sudo ./sync-s3.sh --reverse --from tertiary --dry-run
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/backup.conf"

# --- Arguments ---
DRY_RUN="false"
PRUNE="false"
NON_INTERACTIVE="false"
FROM_ROLE=""
TO_ROLE=""
REVERSE="false"       # copy → primary

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)      DRY_RUN="true"; shift ;;
        --prune)        PRUNE="true"; shift ;;
        --reverse)      REVERSE="true"; shift ;;
        --from)         FROM_ROLE="$2"; shift 2 ;;
        --to)           TO_ROLE="$2"; shift 2 ;;
        -y|--yes)       NON_INTERACTIVE="true"; shift ;;
        -c|--config)    CONFIG_FILE="$2"; shift 2 ;;
        -h|--help)
            cat <<EOF
Usage: $0 [options]

Synchronizes the storages. By default primary → every enabled copy
(the primary is the source of truth): copy what's missing + re-upload objects
whose size differs. Objects missing in the source are not touched.

  --to ROLE         into this copy only: secondary or tertiary
  --from ROLE       where to read from (primary by default; secondary with --reverse)
  --reverse         REVERSE direction: copy → primary (disaster recovery,
                    use only if the primary lost data). Requires
                    confirmation, since it overwrites the source of truth.
  --dry-run         only show the plan, change nothing
  --prune           delete objects in the destination that are not in the source
                    (e.g. after rotation) — IRREVERSIBLE
  -y, --yes         don't ask for confirmation (for --prune/--reverse and cron)
  -c, --config FILE config file (default: backup.conf next to the script)
  -h, --help        this help
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

require_cmd aws

human_size() {
    local bytes="${1:-0}"
    if (( bytes < 1024 )); then echo "${bytes}B"
    elif (( bytes < 1048576 )); then echo "$((bytes / 1024))KB"
    elif (( bytes < 1073741824 )); then echo "$((bytes / 1048576))MB"
    else local gb=$((bytes * 100 / 1073741824)); echo "$((gb / 100)).$((gb % 100))GB"; fi
}

# Turns (possibly multi-line) aws error output into one readable line,
# dropping SSL warnings along the way. Needed so the log/report has the SPECIFIC reason
# (NoSuchBucket / AccessDenied / SignatureDoesNotMatch / Could not connect …),
# and not just "failed".
_clean_aws_err() {
    printf '%s' "$1" \
        | grep -v -E 'InsecureRequestWarning|urllib3/connectionpool|certificate verification is strongly advised' \
        | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

# ==============================================================================
# "Source → destination" pairs
# ==============================================================================
if [[ "$REVERSE" == "true" ]]; then
    FROM_ROLE="${FROM_ROLE:-secondary}"; TO_ROLE="${TO_ROLE:-primary}"
fi
FROM_ROLE="${FROM_ROLE:-primary}"
for r in "$FROM_ROLE" ${TO_ROLE:+"$TO_ROLE"}; do
    s3_is_role "$r" || fail "Unknown storage: $r (available: $(s3_roles_txt))"
done

declare -a PAIRS=()   # "source:destination"
if [[ -n "$TO_ROLE" ]]; then
    [[ "$TO_ROLE" != "$FROM_ROLE" ]] || fail "Source and destination are the same: $FROM_ROLE"
    PAIRS+=("${FROM_ROLE}:${TO_ROLE}")
else
    for r in primary ${S3_COPIES[@]+"${S3_COPIES[@]}"}; do
        [[ "$r" == "$FROM_ROLE" ]] || PAIRS+=("${FROM_ROLE}:${r}")
    done
    ((${#PAIRS[@]})) || fail "No copies enabled (SECONDARY_S3_ENABLED / TERTIARY_S3_ENABLED). Nothing to synchronize."
fi

# Whether a pair can be worked with: both sides enabled and filled in, the destination has full write keys
check_pair() {  # $1 = source, $2 = destination
    local r v
    for r in "$1" "$2"; do
        v="${r^^}_S3"
        s3_enabled "$r" || { log_err "$(s3_label "$r" title) is not enabled (${v}_ENABLED != true)"; return 1; }
        [[ -n "$(s3_var "$r" BUCKET)" && -n "$(s3_var "$r" ENDPOINT)" ]] \
            || { log_err "Fill in ${v}_BUCKET and ${v}_ENDPOINT in backup.conf"; return 1; }
    done
    v="${1^^}_S3"
    [[ -n "$(s3_var "$1" RESTORE_ACCESS_KEY)" || -n "$(s3_var "$1" ACCESS_KEY)" ]] \
        || { log_err "A read key is needed ($(s3_label "$1")): ${v}_ACCESS_KEY or ${v}_RESTORE_ACCESS_KEY"; return 1; }
    v="${2^^}_S3"
    [[ -n "$(s3_var "$2" ACCESS_KEY)" && -n "$(s3_var "$2" SECRET_KEY)" ]] \
        || { log_err "Fill in ${v}_ACCESS_KEY/SECRET_KEY (full keys are needed to write $(s3_label "$2" to))"; return 1; }
    return 0
}

# ==============================================================================
# Listing of the source and destination: key -> size
# ==============================================================================
# Prints "key<TAB>size" lines to stdout.
# On a listing error: prints the SPECIFIC aws reason to stderr and returns != 0
# (important: an empty bucket and an unreachable bucket are DIFFERENT situations; they used to
# merge, so an access failure looked like "the bucket is empty").
list_bucket() {  # $1 = bucket; reads with the current _aws_setup
    local out rc
    out="$(aws "${S3_OPTS[@]}" s3api list-objects-v2 --bucket "$1" --prefix "${BACKUP_PREFIX}/" \
            --query 'Contents[].[Key,Size]' --output text 2>&1)"; rc=$?
    if (( rc != 0 )); then
        local reason; reason="$(_clean_aws_err "$out")"
        log_err "  s3://${1}/${BACKUP_PREFIX}/ — ${reason:-unknown aws error (exit ${rc})}"
        return "$rc"
    fi
    # Remove: SSL noise, the literal None (empty result), empty lines and
    # "folder markers" — zero-size objects with a key ending in "/"
    # (S3 web consoles create them; aws s3 cp behaves oddly with such a key, and they are
    # not backups but artifacts — no need to synchronize them).
    printf '%s\n' "$out" \
        | grep -v -E 'InsecureRequestWarning|urllib3/connectionpool|certificate verification is strongly advised' \
        | sed 's/^None$//' | grep -v '^[[:space:]]*$' \
        | awk -F'\t' '$1 !~ /\/$/' || true
}

show_sample() {  # $1=title, then the keys
    local title="$1"; shift
    [[ $# -eq 0 ]] && return
    echo "    ${C_DIM}${title}:${C_RESET}" >&2
    local i=0 k
    for k in "$@"; do
        (( i >= 5 )) && { echo "      ${C_DIM}… $(($# - 5)) more${C_RESET}" >&2; break; }
        echo "      • ${k}" >&2; i=$((i + 1))
    done
}

# ==============================================================================
# Working folder for temporary files
# ==============================================================================
WORK_DIR="${WORK_DIR:-/var/tmp/docker-backup}"
mkdir -p "$WORK_DIR"
TMP_DIR="$(mktemp -d "${WORK_DIR}/sync.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

LAST_ERR=""      # reason of the last copy_key failure

# Copies one key: source → destination, with a size check.
# On failure puts the SPECIFIC reason (with the aws error text) into LAST_ERR.
copy_key() {  # $1 = key, $2 = expected_size
    local key="$1" expected="$2"
    local tmp="${TMP_DIR}/obj.bin"
    local raw cleaned
    rm -f "$tmp"; LAST_ERR=""

    # 1) download from the source
    _aws_setup "$SRC_ROLE" read
    if ! raw="$(aws "${S3_OPTS[@]}" s3 cp "s3://${SRC_BUCKET}/${key}" "$tmp" --no-progress 2>&1)"; then
        cleaned="$(_clean_aws_err "$raw")"
        LAST_ERR="download from the source (${SRC_LABEL}): ${cleaned:-unknown aws error}"
        return 1
    fi

    # 1b) if the object has a manifest — check the download BEFORE uploading.
    # Sizes match for any object of the same length, so without a hash, corruption
    # would silently spread into the other storage and be taken as normal there.
    if [[ -n "${SRC_SIZE["${key}.sha256"]:-}" ]]; then
        local man="${TMP_DIR}/obj.sha256"
        if aws "${S3_OPTS[@]}" s3 cp "s3://${SRC_BUCKET}/${key}.sha256" "$man" --no-progress >/dev/null 2>&1; then
            if ! verify_checksum_file "$tmp" "$man"; then
                LAST_ERR="sha256 mismatch for the object in the source (${SRC_LABEL}) — it is corrupted, not copying"
                rm -f "$tmp" "$man"
                return 1
            fi
        fi
        rm -f "$man"
    fi

    # 2) upload to the destination
    _aws_setup "$DST_ROLE"
    if ! raw="$(aws "${S3_OPTS[@]}" s3 cp "$tmp" "s3://${DST_BUCKET}/${key}" --no-progress 2>&1)"; then
        cleaned="$(_clean_aws_err "$raw")"
        LAST_ERR="upload to the destination (${DST_LABEL}): ${cleaned:-unknown aws error}"
        rm -f "$tmp"; return 1
    fi

    # 3) check the size in the destination
    local s3_size
    s3_size="$(aws "${S3_OPTS[@]}" s3api head-object --bucket "$DST_BUCKET" --key "$key" \
        --query ContentLength --output text 2>/dev/null || echo "?")"
    rm -f "$tmp"
    if [[ "$s3_size" != "$expected" ]]; then
        LAST_ERR="size check in the destination (${DST_LABEL}): ${s3_size} bytes after upload, expected ${expected}"
        return 1
    fi
    return 0
}

# Synchronizes one pair. Returns 0 — everything matched, 1 — there were errors or the pair failed its checks.
sync_pair() {  # $1 = source role, $2 = destination role
    local SRC_ROLE="$1" DST_ROLE="$2"
    local SRC_LABEL DST_LABEL SRC_BUCKET DST_BUCKET SRC_ENDPOINT DST_ENDPOINT
    SRC_LABEL="$(s3_label "$SRC_ROLE")"; DST_LABEL="$(s3_label "$DST_ROLE")"
    SRC_BUCKET="$(s3_var "$SRC_ROLE" BUCKET)"; DST_BUCKET="$(s3_var "$DST_ROLE" BUCKET)"
    SRC_ENDPOINT="$(s3_var "$SRC_ROLE" ENDPOINT)"; DST_ENDPOINT="$(s3_var "$DST_ROLE" ENDPOINT)"
    local PRUNE="$PRUNE"   # may be switched off below for this pair
    local -A SRC_SIZE=() DST_SIZE=()
    local -a TO_COPY=() TO_REPLACE=() TO_PRUNE=() FAILED=()
    local SRC_LIST DST_LIST key size src_count=0 dst_count=0 n_copy n_replace n_prune
    local copied=0 replaced=0 pruned=0 errors=0 confirm confirm2 rm_raw item shown
    local f_op f_key f_reason e_op e_key e_reason notify_msg

    echo "${C_BOLD}${C_BLUE}═══ S3 synchronization (${SRC_LABEL} → ${DST_LABEL}) ═══${C_RESET}" >&2
    check_pair "$SRC_ROLE" "$DST_ROLE" || return 1
    log "Source:       s3://${SRC_BUCKET}/${BACKUP_PREFIX}/  @ ${SRC_ENDPOINT}  (${SRC_LABEL})"
    log "Destination:  s3://${DST_BUCKET}/${BACKUP_PREFIX}/  @ ${DST_ENDPOINT}  (${DST_LABEL})"
    [[ "$DRY_RUN" == "true" ]] && log "${C_YELLOW}Mode: DRY-RUN (nothing changes)${C_RESET}"
    [[ "$PRUNE" == "true" ]] && log "${C_YELLOW}Mode: PRUNE (extras in the destination will be deleted)${C_RESET}"
    if [[ "$DST_ROLE" == "primary" ]]; then
        log "${C_RED}⚠ REVERSE direction: the PRIMARY S3 is being overwritten (disaster recovery).${C_RESET}"
    fi

    log_step "Reading the source object list (${SRC_LABEL})..."
    _aws_setup "$SRC_ROLE" read
    SRC_LIST="$(list_bucket "$SRC_BUCKET")" \
        || { log_err "Could not read the source (${SRC_LABEL}). The reason is in the line above. Skipping the pair so as not to cause damage."; return 1; }

    log_step "Reading the destination object list (${DST_LABEL})..."
    _aws_setup "$DST_ROLE"
    DST_LIST="$(list_bucket "$DST_BUCKET")" \
        || { log_err "Could not read the destination (${DST_LABEL}). The reason is in the line above."; return 1; }

    if [[ -n "$SRC_LIST" ]]; then
        while IFS=$'\t' read -r key size; do
            [[ -z "$key" ]] && continue
            SRC_SIZE["$key"]="$size"; src_count=$((src_count + 1))
        done <<< "$SRC_LIST"
    fi
    if [[ -n "$DST_LIST" ]]; then
        while IFS=$'\t' read -r key size; do
            [[ -z "$key" ]] && continue
            DST_SIZE["$key"]="$size"; dst_count=$((dst_count + 1))
        done <<< "$DST_LIST"
    fi
    log "Objects: source=${src_count}, destination=${dst_count}"

    # Disaster protection: an empty source + --prune = wiping the WHOLE destination.
    # It almost always means a wrong BACKUP_PREFIX/bucket/keys, not "really empty".
    # The listing was already checked (list_bucket fails on an access error), but just in
    # case --prune is not allowed to wipe the destination on an empty source, even under -y.
    if [[ "$PRUNE" == "true" && "$src_count" -eq 0 && "$dst_count" -gt 0 ]]; then
        log_warn "The source (${SRC_LABEL}) is empty, while the destination has ${dst_count} objects."
        log_warn "Turning --prune off: otherwise I would delete EVERYTHING in the destination. Check BACKUP_PREFIX/bucket/keys."
        PRUNE="false"
    fi

    # ==============================================================================
    # Compute the differences (the source is the reference)
    # ==============================================================================
    # TO_COPY — missing in the destination; TO_REPLACE — present, but the size differs; TO_PRUNE — in the destination, not in the source

    for key in "${!SRC_SIZE[@]}"; do
        if [[ -z "${DST_SIZE[$key]:-}" ]]; then
            TO_COPY+=("$key")
        elif [[ "${DST_SIZE[$key]}" != "${SRC_SIZE[$key]}" ]]; then
            TO_REPLACE+=("$key")
        fi
    done
    for key in "${!DST_SIZE[@]}"; do
        [[ -z "${SRC_SIZE[$key]:-}" ]] && TO_PRUNE+=("$key")
    done

    n_copy=${#TO_COPY[@]}
    n_replace=${#TO_REPLACE[@]}
    n_prune=${#TO_PRUNE[@]}

    echo "${C_BOLD}─── Plan (${SRC_LABEL} → ${DST_LABEL}) ───${C_RESET}" >&2
    log "  Copy (missing in the destination):        ${n_copy}"
    log "  Re-upload (size mismatch):                ${n_replace}"
    if [[ "$PRUNE" == "true" ]]; then
        log "  Delete in the destination (not in source): ${n_prune}"
    else
        log "  Extra in the destination (not in source):  ${n_prune}  ${C_DIM}(deleted only with --prune)${C_RESET}"
    fi

    if (( n_copy == 0 && n_replace == 0 )) && { [[ "$PRUNE" != "true" ]] || (( n_prune == 0 )); }; then
        log_done "The storages are already in sync — nothing to do."
        return 0
    fi

    [[ $n_copy -gt 0 ]]    && show_sample "Will be copied to the destination (${DST_LABEL})" "${TO_COPY[@]}"
    [[ $n_replace -gt 0 ]] && show_sample "Will be re-uploaded to the destination (${DST_LABEL})" "${TO_REPLACE[@]}"
    [[ "$PRUNE" == "true" && $n_prune -gt 0 ]] && show_sample "Will be deleted in the destination (${DST_LABEL})" "${TO_PRUNE[@]}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_done "DRY-RUN finished. Run without --dry-run to apply."
        return 0
    fi

    # --- Confirmations ---
    # The reverse direction writes to the PRIMARY (the source of truth) — always confirm.
    if [[ "$DST_ROLE" == "primary" && "$NON_INTERACTIVE" != "true" ]]; then
        echo "${C_RED}REVERSE synchronization will write ${n_copy} + re-upload ${n_replace} objects to the PRIMARY S3.${C_RESET}" >&2
        read -rp "This is disaster recovery. Continue? (type yes): " confirm </dev/tty
        [[ "$confirm" == "yes" ]] || { log "Cancelled by the user."; return 0; }
    fi
    # Destructive deletion in the destination
    if [[ "$PRUNE" == "true" && $n_prune -gt 0 && "$NON_INTERACTIVE" != "true" ]]; then
        echo "${C_YELLOW}${n_prune} objects in the destination (${DST_LABEL}) will be deleted IRREVERSIBLY.${C_RESET}" >&2
        [[ "$DST_ROLE" == "primary" ]] && echo "${C_RED}This deletes from the PRIMARY S3!${C_RESET}" >&2
        read -rp "Continue the deletion? (type yes): " confirm2 </dev/tty
        [[ "$confirm2" == "yes" ]] || { log "Deletion cancelled (copying may already have run)."; PRUNE="false"; }
    fi

    if (( n_copy > 0 )); then
        log_step "Copying missing objects to the destination (${DST_LABEL}): ${n_copy}..."
        for key in "${TO_COPY[@]}"; do
            if copy_key "$key" "${SRC_SIZE[$key]}"; then
                copied=$((copied + 1))
                log_ok "  → ${key}  ($(human_size "${SRC_SIZE[$key]}"))"
            else
                errors=$((errors + 1))
                FAILED+=("copy|${key}|${LAST_ERR}")
                log_err "  ✗ ${key} — ${LAST_ERR}"
            fi
        done
    fi

    if (( n_replace > 0 )); then
        log_step "Re-uploading objects whose size differs (${n_replace})..."
        for key in "${TO_REPLACE[@]}"; do
            if copy_key "$key" "${SRC_SIZE[$key]}"; then
                replaced=$((replaced + 1))
                log_ok "  ↻ ${key}  ($(human_size "${SRC_SIZE[$key]}"))"
            else
                errors=$((errors + 1))
                FAILED+=("re-upload|${key}|${LAST_ERR}")
                log_err "  ✗ ${key} — ${LAST_ERR}"
            fi
        done
    fi

    if [[ "$PRUNE" == "true" && $n_prune -gt 0 ]]; then
        log_step "Deleting extra objects in the destination (${DST_LABEL}): ${n_prune}..."
        _aws_setup "$DST_ROLE"
        for key in "${TO_PRUNE[@]}"; do
            if rm_raw="$(aws "${S3_OPTS[@]}" s3 rm "s3://${DST_BUCKET}/${key}" 2>&1)"; then
                pruned=$((pruned + 1))
                log_ok "  ✗ deleted ${key}"
            else
                errors=$((errors + 1))
                FAILED+=("delete|${key}|$(_clean_aws_err "$rm_raw")")
                log_err "  ✗ did not delete ${key} — $(_clean_aws_err "$rm_raw")"
            fi
        done
    fi

    _aws_setup primary

    # ==============================================================================
    # Summary
    # ==============================================================================
    echo "${C_BOLD}─── Summary (${SRC_LABEL} → ${DST_LABEL}) ───${C_RESET}" >&2
    log "  Copied:       ${copied}"
    log "  Re-uploaded:  ${replaced}"
    [[ "$PRUNE" == "true" ]] && log "  Deleted:      ${pruned}"
    log "  Errors:       ${errors}"

    if (( errors > 0 )); then
        echo "${C_BOLD}${C_RED}─── Not synchronized (${errors}) ───${C_RESET}" >&2
        shown=0
        for item in "${FAILED[@]}"; do
            IFS='|' read -r f_op f_key f_reason <<< "$item"
            if (( shown >= 20 )); then
                echo "    ${C_DIM}… $((errors - 20)) more — see the full list in the log${C_RESET}" >&2
                break
            fi
            echo "    • [${f_op}] ${f_key}" >&2
            echo "        ${C_DIM}reason:${C_RESET} ${f_reason:-unknown error}" >&2
            shown=$((shown + 1))
        done

        # The notification gets the SPECIFIC first failure, not just a count.
        IFS='|' read -r e_op e_key e_reason <<< "${FAILED[0]}"
        notify error "storage synchronization with errors" "$(html_esc "${SRC_LABEL} → ${DST_LABEL}"): ${errors} $(plural "$errors" error errors). Copied ${copied}, re-uploaded ${replaced}, deleted ${pruned}."$'\n'"First: [$(html_esc "$e_op")] <code>$(html_esc "$e_key")</code> — $(html_esc "${e_reason:-reason unknown}")."
        log_err "Synchronization ${SRC_LABEL} → ${DST_LABEL} finished with errors (${errors}). The specific reasons are above."
        return 1
    fi

    notify_msg="$(html_esc "${SRC_LABEL} → ${DST_LABEL}"): copied ${copied}, re-uploaded ${replaced}"
    [[ "$PRUNE" == "true" ]] && notify_msg="${notify_msg}, deleted ${pruned}"
    notify success "storages synchronized" "${notify_msg}."

    log_done "Done: ${DST_LABEL} is in sync with the source (${SRC_LABEL})."
    return 0
}

rc=0
for pair in "${PAIRS[@]}"; do
    sync_pair "${pair%%:*}" "${pair#*:}" || rc=1
    echo >&2
done
(( rc == 0 )) || fail "Synchronization finished with errors. The specific reasons are above."
