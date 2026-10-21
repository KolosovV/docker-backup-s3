#!/usr/bin/env bash
# ==============================================================================
# lib.sh — shared helpers for docker-backup.sh, docker-restore.sh and the other scripts
# Sourced via: source "${SCRIPT_DIR}/lib.sh"
# Expects backup.conf to be loaded already
# ==============================================================================

# aws-cli checksums — only where the S3 itself requires them.
# Since 2.23 aws-cli sends a new-style checksum with every upload by default (a CRC trailer at the
# end of the body). Not every S3-compatible storage understands it: some drop the
# connection — "SSL: UNEXPECTED_EOF_WHILE_READING" on multipart uploads and an empty "An error occurred ()"
# on plain ones. It shows up when snap auto-updates aws-cli: uploads to such a storage stop, while
# a naive diagnostic stays green (a test write from stdin carries no checksum).
# Environment variables rather than the aws config: every script sourcing lib.sh sees them, including
# diagnose-s3.sh and restore. Can be overridden in backup.conf.
export AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}"
export AWS_RESPONSE_CHECKSUM_VALIDATION="${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}"

# ==============================================================================
# COLORS
# ==============================================================================
_init_colors() {
    local mode="${COLOR_OUTPUT:-auto}"
    local enable=false

    case "$mode" in
        on)   enable=true ;;
        off)  enable=false ;;
        auto)
            if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
                local n; n=$(tput colors 2>/dev/null || echo 0)
                [[ "$n" -ge 8 ]] && enable=true
            fi
            ;;
    esac

    if $enable; then
        C_RESET=$'\033[0m'
        C_BOLD=$'\033[1m'
        C_DIM=$'\033[2m'
        C_RED=$'\033[31m'
        C_GREEN=$'\033[32m'
        C_YELLOW=$'\033[33m'
        C_BLUE=$'\033[34m'
        C_MAGENTA=$'\033[35m'
        C_CYAN=$'\033[36m'
    else
        C_RESET=""
        C_BOLD=""
        C_DIM=""
        C_RED=""
        C_GREEN=""
        C_YELLOW=""
        C_BLUE=""
        C_MAGENTA=""
        C_CYAN=""
    fi
}
_init_colors

# ==============================================================================
# LOGGING
# All logs go to stderr so they don't interfere with stdout (needed for $() in restore)
# ==============================================================================
_ts() { date '+%Y-%m-%d %H:%M:%S'; }

log()       { echo "[$(_ts)] $*" >&2; }
log_info()  { echo "${C_DIM}[$(_ts)]${C_RESET} $*" >&2; }
log_ok()    { echo "${C_DIM}[$(_ts)]${C_RESET} ${C_GREEN}✓${C_RESET} $*" >&2; }
log_warn()  { echo "${C_DIM}[$(_ts)]${C_RESET} ${C_YELLOW}⚠${C_RESET} $*" >&2; }
log_err()   { echo "${C_DIM}[$(_ts)]${C_RESET} ${C_RED}❌ $*${C_RESET}" >&2; }
log_step()  { echo "${C_DIM}[$(_ts)]${C_RESET} ${C_CYAN}▶${C_RESET} ${C_BOLD}$*${C_RESET}" >&2; }
log_done()  { echo "${C_DIM}[$(_ts)]${C_RESET} ${C_GREEN}${C_BOLD}✅ $*${C_RESET}" >&2; }

fail() { log_err "$*"; exit 1; }

# ==============================================================================
# SPLITTING STRINGS INTO WORDS
# The scripts run with IFS=$'\n\t' (no space), so a plain "for x in $var"
# or "arr+=($var)" does NOT split the value on spaces — the whole string goes
# as one argument. Here IFS is set explicitly, for reading only.
# usage: mapfile -t arr < <(split_words "$SCAN_DIRS")
# ==============================================================================
split_words() {
    local -a _words=()
    IFS=$' \t\n' read -ra _words <<< "${1:-}"
    ((${#_words[@]})) && printf '%s\n' "${_words[@]}"
    return 0
}

# ==============================================================================
# CHECKSUMS
# An object's size in S3 only proves the upload wasn't cut short. A hash catches
# data corruption: a broken transfer, damage on the provider side, a botched storage
# migration. The manifest sits next to the archive under the same key + ".sha256".
# ==============================================================================
sha256_of() {
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

# Writes the manifest "<sha256>  <file name>" next to the archive, prints its path
write_checksum_file() {
    local src="$1"
    local dst="${src}.sha256"
    local hash; hash="$(sha256_of "$src")"
    [[ -n "$hash" ]] || { log_warn "Could not compute sha256 for $(basename "$src")"; return 1; }
    printf '%s  %s\n' "$hash" "$(basename "$src")" > "$dst"
    printf '%s\n' "$dst"
}

# Checks a file against its manifest. usage: verify_checksum_file <file> <file.sha256>
verify_checksum_file() {
    local file="$1" manifest="$2"
    [[ -f "$manifest" ]] || return 2   # no manifest — nothing to check
    local expected actual
    expected="$(awk '{print $1}' "$manifest" | head -1)"
    [[ -n "$expected" ]] || return 2
    actual="$(sha256_of "$file")"
    [[ "$actual" == "$expected" ]]
}

# ==============================================================================
# CHECKS
# ==============================================================================
require_cmd() {
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || fail "Not installed: $cmd"
    done
}

# Free space check for the given directory
# usage: check_free_space <dir> <required_mb>
check_free_space() {
    local dir="$1" need_mb="$2"
    local avail_kb avail_mb
    avail_kb=$(df --output=avail "$dir" 2>/dev/null | tail -n1 | tr -d ' ' || echo 0)
    avail_mb=$((avail_kb / 1024))
    if [[ "$avail_mb" -lt "$need_mb" ]]; then
        log_err "Not enough space in ${dir}: ${avail_mb}MB < ${need_mb}MB required"
        return 1
    fi
    log_info "Free in ${dir}: ${avail_mb}MB (at least ${need_mb}MB required) — OK"
    return 0
}

# ==============================================================================
# AWS CLI WRAPPER
# Suppresses SSL warnings, adds the endpoint and extra options
# ==============================================================================
# The bandwidth limit has to be set via "aws configure set", which writes
# to a file (~/.aws/config by default). That used to mean the script's
# setting stayed in root's profile forever and affected every other
# aws command, and clearing S3_BANDWIDTH_LIMIT did not remove the old limit.
# So aws CLI is pointed at its own config file: it is recreated
# on every run, and whatever isn't in it simply doesn't apply.
_AWS_CONFIG_READY=""
_aws_config_init() {
    [[ -n "$_AWS_CONFIG_READY" ]] && return 0
    local dir="${WORK_DIR:-/var/tmp/docker-backup}"
    mkdir -p "$dir" 2>/dev/null || true
    AWS_CONFIG_FILE="${dir}/aws-cli.conf"
    export AWS_CONFIG_FILE
    : > "$AWS_CONFIG_FILE" 2>/dev/null || true
    chmod 600 "$AWS_CONFIG_FILE" 2>/dev/null || true
    # Multipart threshold (S3_MULTIPART_THRESHOLD, e.g. 4GB). Smaller files go in one request:
    # if it breaks, nothing is written. With multipart, some storages keep the parts in a hidden service
    # container, and parts of broken uploads stay there and are billed (habr.com/ru/articles/816647).
    # S3 accepts up to 5 GB in one request, so the threshold is 4–5GB at most.
    # But one request is one stream — on a loaded storage it can be much slower than a multipart upload,
    # so it is off by default.
    # Retries: by default aws gives up after two ("reached max retries: 2"), and a brief storage failure
    # (InternalError, SlowDown — a storage under load) turned into a backup error. standard —
    # retries with growing backoff; S3_MAX_ATTEMPTS — total number of attempts.
    aws configure set default.retry_mode standard 2>/dev/null || true
    aws configure set default.max_attempts "${S3_MAX_ATTEMPTS:-8}" 2>/dev/null || true
    if [[ -n "${S3_MULTIPART_THRESHOLD:-}" ]]; then
        aws configure set default.s3.multipart_threshold "$S3_MULTIPART_THRESHOLD" 2>/dev/null || true
    fi
    _AWS_CONFIG_READY=1
}

# ==============================================================================
# S3 STORAGES
# primary — the main one: the archive goes there first; restore and sync-s3 use it by default.
# secondary, tertiary — copies, each with its own ENABLED and REQUIRED. A role's settings are
# <ROLE>_S3_<FIELD>: PRIMARY_S3_BUCKET, TERTIARY_S3_ENDPOINT. One more storage — add the role here,
# its labels in s3_label and a block in backup.conf.example; the scripts walk the list on their own.
# ==============================================================================
S3_ROLES=(primary secondary tertiary)
S3_FIELDS=(ACCESS_KEY SECRET_KEY ENDPOINT REGION BUCKET OPTS_EXTRA ADDRESSING_STYLE RESTORE_ACCESS_KEY RESTORE_SECRET_KEY)

# Older versions named the main storage plain S3_* (S3_BUCKET etc.). An old backup.conf
# still works: if PRIMARY_S3_<field> is not set, S3_<field> is used. update.sh renames them itself.
_s3_compat() {
    local f old new
    for f in "${S3_FIELDS[@]}"; do
        old="S3_${f}"; new="PRIMARY_S3_${f}"
        [[ -z "${!new:-}" && -n "${!old:-}" ]] && printf -v "$new" '%s' "${!old}"
    done
    return 0
}

# s3_conf_migrate <backup.conf> — rename the main storage's S3_<field> to PRIMARY_S3_<field>,
# together with ${S3_<field>} references inside the file (the template had one: export AWS_S3_ADDRESSING_STYLE).
# Saves a copy <file>.bak.<time> before editing; if bash cannot parse the file afterwards,
# puts the copy back. Prints what was done (nothing — nothing to change). 1 — failed.
# Called by update.sh and install.sh: bash -c 'source lib.sh; s3_conf_migrate backup.conf'.
s3_conf_migrate() {
    local conf="$1" f alt bak
    local -a renamed=()
    for f in "${S3_FIELDS[@]}"; do
        grep -q "^S3_${f}=" "$conf" && renamed+=("$f")
    done
    ((${#renamed[@]})) || return 0

    bak="${conf}.bak.$(date +%Y%m%d_%H%M%S)"
    cp -p "$conf" "$bak" || { printf 'Could not make a copy %s — leaving the config alone\n' "$bak"; return 1; }
    for f in "${renamed[@]}"; do
        if grep -q "^PRIMARY_S3_${f}=" "$conf"; then
            # The new name already exists — comment out the old line so one field doesn't have two values
            sed -i "s/^S3_${f}=/# replaced by PRIMARY_S3_${f}: S3_${f}=/" "$conf"
        else
            sed -i "s/^S3_${f}=/PRIMARY_S3_${f}=/" "$conf"
        fi
    done
    alt="$(IFS='|'; printf '%s' "${S3_FIELDS[*]}")"
    sed -i -E 's/\$\{S3_('"$alt"')\}/${PRIMARY_S3_\1}/g; s/\$S3_('"$alt"')([^A-Za-z0-9_]|$)/$PRIMARY_S3_\1\2/g' "$conf"

    if ! bash -n "$conf" 2>/dev/null; then
        cp -p "$bak" "$conf"
        printf 'backup.conf does not parse after renaming — restored it as it was (%s)\n' "$bak"
        return 1
    fi
    printf 'Main storage: S3_* → PRIMARY_S3_* (%s)\n' "$(IFS=' '; printf '%s' "${renamed[*]}")"
    printf 'Copy before renaming: %s\n' "$bak"
    return 0
}

# Roles separated by spaces — for messages (the scripts run with IFS=$'\n\t', and ${S3_ROLES[*]} would print one per line)
s3_roles_txt() { local IFS=' '; printf '%s' "${S3_ROLES[*]}"; }

s3_is_role() {
    local r
    for r in "${S3_ROLES[@]}"; do [[ "$r" == "$1" ]] && return 0; done
    return 1
}

# s3_var <role> <FIELD> — value of <ROLE>_S3_<FIELD>: s3_var tertiary BUCKET
s3_var() {
    local n="${1^^}_S3_${2}"
    printf '%s' "${!n:-}"
}

# s3_label <role> [title|to|in|from] — label for humans. No second argument — "secondary S3",
# title — capitalized ("Secondary S3"), to — "to secondary S3", in — "in secondary S3",
# from — "from secondary S3".
s3_label() {
    case "$1:${2:-}" in
        primary:)       printf 'primary S3' ;;
        primary:title)  printf 'Primary S3' ;;
        primary:to)     printf 'to primary S3' ;;
        primary:in)     printf 'in primary S3' ;;
        primary:from)   printf 'from primary S3' ;;
        secondary:)     printf 'secondary S3' ;;
        secondary:title) printf 'Secondary S3' ;;
        secondary:to)   printf 'to secondary S3' ;;
        secondary:in)   printf 'in secondary S3' ;;
        secondary:from) printf 'from secondary S3' ;;
        tertiary:)      printf 'tertiary S3' ;;
        tertiary:title) printf 'Tertiary S3' ;;
        tertiary:to)    printf 'to tertiary S3' ;;
        tertiary:in)    printf 'in tertiary S3' ;;
        tertiary:from)  printf 'from tertiary S3' ;;
        *)              printf 'S3 %s' "$1" ;;
    esac
}

s3_enabled()  { [[ "$1" == "primary" || "$(s3_var "$1" ENABLED)" == "true" ]]; }
s3_required() { [[ "$1" == "primary" || "$(s3_var "$1" REQUIRED)" == "true" ]]; }

# Are the keys, endpoint and bucket filled in
s3_complete() {
    local f
    for f in ACCESS_KEY SECRET_KEY ENDPOINT BUCKET; do
        [[ -n "$(s3_var "$1" "$f")" ]] || return 1
    done
    return 0
}

# Enabled copies (all roles except primary) — in order
# s3_refresh — recompute after the config was re-sourced (the menu does that after editing storages)
s3_refresh() {
    local r
    _s3_compat
    S3_COPIES=()
    for r in "${S3_ROLES[@]:1}"; do
        s3_enabled "$r" && S3_COPIES+=("$r")
    done
    return 0
}
s3_refresh

# _aws_setup [role] [write|read] — point aws at the role's storage (primary and write by default).
#   read — the read-only key (<ROLE>_S3_RESTORE_*), if set.
# Sets S3_OPTS and S3_CUR_ROLE / S3_CUR_BUCKET / S3_CUR_ENDPOINT.
_AWS_BANDWIDTH_SET=""
_aws_setup() {
    local role="${1:-primary}" access="${2:-write}" key secret region addr extra
    s3_is_role "$role" || { log_err "Unknown storage: $role (available: $(s3_roles_txt))"; return 1; }
    _aws_config_init

    key="$(s3_var "$role" ACCESS_KEY)"; secret="$(s3_var "$role" SECRET_KEY)"
    if [[ "$access" == "read" && -n "$(s3_var "$role" RESTORE_ACCESS_KEY)" ]]; then
        key="$(s3_var "$role" RESTORE_ACCESS_KEY)"; secret="$(s3_var "$role" RESTORE_SECRET_KEY)"
    fi
    export AWS_ACCESS_KEY_ID="$key"
    export AWS_SECRET_ACCESS_KEY="$secret"
    region="$(s3_var "$role" REGION)"
    export AWS_DEFAULT_REGION="${region:-${PRIMARY_S3_REGION:-us-east-1}}"
    addr="$(s3_var "$role" ADDRESSING_STYLE)"
    export AWS_S3_ADDRESSING_STYLE="${addr:-path}"

    # The bandwidth limit is shared by all storages and set once, on the first write.
    # It goes into our AWS_CONFIG_FILE, which is recreated empty at startup:
    # if the limit is removed from backup.conf, it simply won't appear in the file.
    if [[ "$access" == "write" && -n "${S3_BANDWIDTH_LIMIT:-}" && -z "$_AWS_BANDWIDTH_SET" ]]; then
        aws configure set default.s3.max_bandwidth "$S3_BANDWIDTH_LIMIT" 2>/dev/null || true
        _AWS_BANDWIDTH_SET=1
    fi

    S3_CUR_ROLE="$role"
    S3_CUR_BUCKET="$(s3_var "$role" BUCKET)"
    S3_CUR_ENDPOINT="$(s3_var "$role" ENDPOINT)"
    S3_OPTS=(--endpoint-url "$S3_CUR_ENDPOINT")
    extra="$(s3_var "$role" OPTS_EXTRA)"
    if [[ -n "$extra" ]]; then
        local -a _extra=()
        mapfile -t _extra < <(split_words "$extra")
        ((${#_extra[@]})) && S3_OPTS+=("${_extra[@]}")
    fi
    return 0
}

# Quiet aws call with SSL warnings filtered out
# usage: aws_q s3 ls ...
aws_q() {
    aws "${S3_OPTS[@]}" "$@" 2> >(grep -v -E 'InsecureRequestWarning|urllib3/connectionpool|certificate verification is strongly advised' >&2)
}

# docker compose wrapper: supports both v2 (the "docker compose" plugin)
# and v1 (the separate "docker-compose" binary). usage: docker_compose stop
docker_compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose "$@"
    else
        log_err "docker compose not found (neither the v2 plugin nor docker-compose v1)"
        return 127
    fi
}

# Uploads a file to S3, with progress if the file is large
# usage: aws_upload <local> <s3-url>
aws_upload() {
    local src="$1" dst="$2"
    local size_mb=0
    if [[ -f "$src" ]]; then
        size_mb=$(( $(stat -c %s "$src" 2>/dev/null || echo 0) / 1048576 ))
    fi
    # Progress is shown for files > 100MB and only on a TTY
    if [[ "$size_mb" -gt 100 && -t 2 ]]; then
        aws_q s3 cp "$src" "$dst"  # AWS CLI v2 shows progress on a TTY by default
    else
        # Capture the output and the REAL aws exit code (not the grep filter's):
        # otherwise, under pipefail, a successful upload with no output reads as an error.
        local out rc
        out="$(aws_q s3 cp "$src" "$dst" --no-progress 2>&1)"; rc=$?
        if [[ -n "$out" ]]; then
            printf '%s\n' "$out" \
                | grep -v -E 'InsecureRequestWarning|urllib3/connectionpool|certificate verification is strongly advised' >&2 || true
        fi
        return "$rc"
    fi
}

# Uploads an archive to a COPY (secondary, tertiary…) and checks its size.
# Call AFTER a successful upload to the primary S3, before the local archive is deleted.
# usage: upload_to_copy <role> <local_file> <s3_key> <expected_size_bytes>
# Returns:
#   0 — success OR this copy is disabled (nothing to do)
#   1 — the copy is enabled, but the upload/check failed
# IMPORTANT: the function restores the primary credentials (_aws_setup primary) before returning.
upload_to_copy() {
    local role="$1" src="$2" s3_key="$3" expected_size="$4" label
    label="$(s3_label "$role" title)"

    s3_enabled "$role" || return 0

    if ! s3_complete "$role"; then
        log_warn "  ☁²  ${label} is enabled, but not all ${role^^}_S3_* are filled in — skipping"
        return 1
    fi

    _aws_setup "$role"
    local s3_url="s3://${S3_CUR_BUCKET}/${s3_key}"
    log "  ☁²  Uploading $(s3_label "$role" to): $s3_url"

    local rc=0
    if aws_upload "$src" "$s3_url"; then
        local s3_size
        s3_size="$(aws_q s3api head-object --bucket "$S3_CUR_BUCKET" --key "$s3_key" \
            --query ContentLength --output text 2>/dev/null || echo 0)"
        if [[ "$s3_size" == "$expected_size" ]]; then
            log_ok "  ${label}: size matches (${expected_size} bytes)"
        else
            log_err "  ${label}: size ($s3_size) != local ($expected_size)"
            rc=1
        fi
    else
        log_err "  Upload $(s3_label "$role" to) failed"
        rc=1
    fi

    # Always restore the primary credentials for further operations
    _aws_setup primary
    return $rc
}

# ==============================================================================
# LOCK
# Protection against a double start. mkdir is used as the atomic operation
# (POSIX guarantees mkdir is atomic). This is more reliable than flock on an FD
# when process substitution is used for stderr.
# ==============================================================================
acquire_lock() {
    local lockfile="${1:-${LOCK_FILE:-/var/run/docker-backup.lock}}"
    local lockdir="${lockfile}.d"
    mkdir -p "$(dirname "$lockfile")"

    # If the lock directory already exists — check whether the process is alive
    if [[ -d "$lockdir" ]]; then
        local old_pid
        old_pid=$(cat "$lockdir/pid" 2>/dev/null || echo "")
        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            fail "Another instance is already running (PID: $old_pid). Lock: $lockdir"
        else
            log_warn "Found a stale lock (PID $old_pid is not running) — removing it"
            rm -rf "$lockdir"
        fi
    fi

    # Create the directory atomically. If someone else created it in parallel, this fails.
    if ! mkdir "$lockdir" 2>/dev/null; then
        local other_pid
        other_pid=$(cat "$lockdir/pid" 2>/dev/null || echo "?")
        fail "Could not create the lock (another process, PID $other_pid, got there first): $lockdir"
    fi
    echo $$ > "$lockdir/pid"
}

release_lock() {
    local lockdir="${LOCK_FILE:-/var/run/docker-backup.lock}.d"

    # Remove the lock directory only if it is ours
    if [[ -d "$lockdir" ]]; then
        local our_pid
        our_pid=$(cat "$lockdir/pid" 2>/dev/null || echo "")
        [[ "$our_pid" == "$$" ]] && rm -rf "$lockdir"
    fi
    return 0
}

# ==============================================================================
# NOTIFICATIONS
# ==============================================================================
# The look: an icon, a bold line "Server <name>: what happened", details and what to check below —
# so messages from several servers (and other monitoring in the same chat) read alike.
#
# usage: notify <level> "<what happened>" "<details, HTML>"
#   level: error 🔴 — no backup or an incomplete one; warn 🟠 — the primary copy is there, but something is off;
#          success 🟢 — everything went fine (only with NOTIFY_ON=always).
#   Details are already HTML: escape substituted names with html_esc.
notify() {
    local level="$1" title="$2" body="${3:-}"

    case "${NOTIFY_ON:-error}" in
        none)   return 0 ;;
        error)  [[ "$level" == "success" ]] && return 0 ;;
        always) ;;
    esac

    local icon="🟢"
    case "$level" in
        error) icon="🔴" ;;
        warn)  icon="🟠" ;;
    esac
    local name="${NOTIFY_NAME:-$(hostname)}"
    local full="${icon} <b>Server $(html_esc "$name"): $(html_esc "$title")</b>"
    [[ -n "$body" ]] && full+=$'\n'"$body"
    # Without markup — for the webhook and in case Telegram rejects the HTML.
    local plain; plain="$(printf '%s' "$full" | sed -e 's/<[^>]*>//g' -e 's/&lt;/</g; s/&gt;/>/g; s/&amp;/\&/g')"

    # Telegram
    if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
        local api="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" resp
        resp="$(curl -s -m 10 -X POST "$api" \
            --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
            --data-urlencode "text=${full}" \
            --data-urlencode "parse_mode=HTML" \
            --data-urlencode "disable_web_page_preview=true" 2>/dev/null || true)"
        if [[ "$resp" != *'"ok":true'* ]]; then
            # Markup rejected (or a network issue) — send as plain text, so the alert isn't lost over a tag.
            curl -s -m 10 -X POST "$api" \
                --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
                --data-urlencode "text=${plain}" 2>/dev/null | grep -q '"ok":true' \
                || log_warn "Could not send to Telegram"
        fi
    fi

    # Webhook (Slack/Discord/custom)
    if [[ -n "${NOTIFY_WEBHOOK_URL:-}" ]]; then
        jq -n --arg t "$plain" '{text: $t}' \
            | curl -s -m 10 -X POST -H 'Content-Type: application/json' -d @- "$NOTIFY_WEBHOOK_URL" \
            >/dev/null 2>&1 || log_warn "Could not send the webhook"
    fi
}

# abort_stale_uploads <bucket> — abort unfinished multipart uploads under BACKUP_PREFIX older than
# a day. The right storage's credentials are already set (_aws_setup). Prints the number aborted.
#
# Where they come from: the storage cuts an upload midway (seen on an S3-compatible storage: a response with no
# code on CreateMultipartUpload and later), aws can no longer abort it, and the parts sit invisibly — not
# in the file listing, yet taking space. Younger than a day is left alone: it may be an upload in progress.
abort_stale_uploads() {
    local bucket="$1" cut n=0 key id
    cut="$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%S)"
    while IFS=$'\t' read -r key id; do
        [[ -z "$id" ]] && continue
        # Two attempts, not S3_MAX_ATTEMPTS: an upload the storage won't abort (seen on an S3-compatible storage under
        # load — InternalError on every abort) would otherwise eat minutes of nightly rotation each,
        # every night. If it fails — we'll try again the next night.
        if AWS_MAX_ATTEMPTS=2 aws_q s3api abort-multipart-upload --bucket "$bucket" --key "$key" --upload-id "$id" >/dev/null; then
            n=$((n + 1))
            log "  ✂  Aborted an unfinished upload: $key"
        else
            log_warn "Could not abort an unfinished upload: $key"
        fi
    done < <(aws_q s3api list-multipart-uploads --bucket "$bucket" --prefix "${BACKUP_PREFIX}/" --output json 2>/dev/null \
        | jq -r --arg cut "$cut" '(.Uploads // [])[] | select(.Initiated[0:19] < $cut) | [.Key, .UploadId] | @tsv' 2>/dev/null || true)
    printf '%d' "$n"
}

# html_esc — text into message HTML: & < > are escaped. Via sed, not ${s//</&lt;}: in bash 5.2
# "&" in the replacement means the match, which produced "<lt;".
html_esc() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# s3_host — short storage name from its endpoint: https://s3.example.com/path → s3.example.com.
s3_host() {
    local u="${1#*://}"
    printf '%s' "${u%%/*}"
}

# plural N one many — "1 project", "2 projects".
plural() {
    if (( $1 == 1 )); then printf '%s' "$2"; else printf '%s' "$3"; fi
}

# notify_log_hint — the "where are the details" line for messages.
notify_log_hint() {
    printf 'Details: <code>tail -n 80 %s</code>' "$(html_esc "${LOG_FILE:-/var/log/docker-backup.log}")"
}

# ==============================================================================
# GPG ENCRYPTION
# ==============================================================================
encrypt_file() {
    local src="$1"
    local dst="${src}.gpg"
    [[ -f "$GPG_PASSPHRASE_FILE" ]] || fail "Passphrase file not found: $GPG_PASSPHRASE_FILE"
    [[ -r "$GPG_PASSPHRASE_FILE" ]] || fail "No read permission: $GPG_PASSPHRASE_FILE"

    gpg --batch --yes --quiet \
        --passphrase-file "$GPG_PASSPHRASE_FILE" \
        --symmetric --cipher-algo AES256 \
        -o "$dst" "$src" \
        || fail "Encryption failed: $src"
    rm -f "$src"
    echo "$dst"
}

decrypt_file() {
    local src="$1"
    local dst="${src%.gpg}"
    [[ -f "$GPG_PASSPHRASE_FILE" ]] || fail "Passphrase file not found: $GPG_PASSPHRASE_FILE"

    gpg --batch --yes --quiet \
        --passphrase-file "$GPG_PASSPHRASE_FILE" \
        --decrypt -o "$dst" "$src" \
        || fail "Decryption failed: $src"
    echo "$dst"
}

# ==============================================================================
# CONFIRM (y/yes)
# ==============================================================================
is_yes() {
    local ans="${1,,}"
    [[ "$ans" == "yes" || "$ans" == "y" ]]
}

# ==============================================================================
# DATABASE AUTO-DUMP
# Finds PostgreSQL/MySQL/MariaDB/Redis/MongoDB containers in a project
# and dumps every database it finds.
# Results go to $project_dir/$DB_DUMPS_DIR/
# ==============================================================================

# Database type from the container image
# usage: detect_db_type <image>
detect_db_type() {
    local image="${1,,}"  # to lowercase
    case "$image" in
        *postgres*|*postgis*|*timescale*) echo "postgres" ;;
        *mariadb*) echo "mariadb" ;;
        *mysql*|*percona*) echo "mysql" ;;
        *redis*|*keydb*) echo "redis" ;;
        *mongo*) echo "mongo" ;;
        *) echo "" ;;
    esac
}

# Value of an env variable from the container
# usage: container_env <container> <var_name>
container_env() {
    local container="$1" var="$2"
    docker exec "$container" sh -c "echo \"\${$var:-}\"" 2>/dev/null || echo ""
}

# Delete old dumps by mask, keeping the last N
# usage: prune_old_dumps <dir> <pattern> <keep_count>
prune_old_dumps() {
    local dir="$1" pattern="$2" keep="$3"
    [[ -d "$dir" ]] || return 0
    # shellcheck disable=SC2012
    ls -t "$dir"/$pattern 2>/dev/null | tail -n +$((keep + 1)) | xargs -r rm -f
}

# --- PostgreSQL dump ---
dump_postgres() {
    local container="$1" project_dir="$2" timestamp="$3"
    local dumps_dir="${project_dir}/${DB_DUMPS_DIR:-db-dumps}"
    mkdir -p "$dumps_dir"
    # The directory may be left over from old versions with 755 — tighten it explicitly
    chmod 700 "$dumps_dir" 2>/dev/null || true

    # Determine the user — try the standard env variables
    local pg_user
    pg_user="$(container_env "$container" POSTGRES_USER)"
    [[ -z "$pg_user" ]] && pg_user="postgres"

    local cname; cname=$(docker inspect --format '{{.Name}}' "$container" | sed 's|^/||')
    local out="${dumps_dir}/postgres_${cname}_${timestamp}.sql.gz"

    log "    🐘 PostgreSQL: $cname (user=$pg_user) -> $(basename "$out")"

    # Password: the official postgres image allows trust on the local socket, so it is usually
    # not needed. But with POSTGRES_HOST_AUTH_METHOD=scram or a custom pg_hba, pg_dumpall would
    # fail without it. Pass it when set: with trust it is simply ignored.
    local pg_pass; pg_pass="$(container_env "$container" POSTGRES_PASSWORD)"

    # pg_dumpall = all databases + roles + tablespaces
    if timeout "${DB_DUMP_TIMEOUT:-1800}" \
        docker exec -e "PGPASSWORD=$pg_pass" "$container" pg_dumpall -U "$pg_user" 2>/dev/null \
        | gzip > "$out"; then

        local size; size=$(du -h "$out" | awk '{print $1}')
        log_ok "    Postgres dump done: $size"
        prune_old_dumps "$dumps_dir" "postgres_${cname}_*.sql.gz" "${DB_DUMPS_RETENTION_COUNT:-3}"
        return 0
    else
        log_warn "    pg_dumpall failed for $cname"
        rm -f "$out"
        return 1
    fi
}

# --- MySQL/MariaDB dump ---
dump_mysql() {
    local container="$1" project_dir="$2" timestamp="$3" db_type="$4"
    local dumps_dir="${project_dir}/${DB_DUMPS_DIR:-db-dumps}"
    mkdir -p "$dumps_dir"
    # The directory may be left over from old versions with 755 — tighten it explicitly
    chmod 700 "$dumps_dir" 2>/dev/null || true

    local cname; cname=$(docker inspect --format '{{.Name}}' "$container" | sed 's|^/||')

    # Get the root password from env
    local mysql_pass
    mysql_pass="$(container_env "$container" MYSQL_ROOT_PASSWORD)"
    [[ -z "$mysql_pass" ]] && mysql_pass="$(container_env "$container" MARIADB_ROOT_PASSWORD)"
    # mailcow names the root password its own way
    [[ -z "$mysql_pass" ]] && mysql_pass="$(container_env "$container" DBROOT)"
    [[ -z "$mysql_pass" ]] && mysql_pass="$(container_env "$container" MYSQL_PASSWORD)"

    local out="${dumps_dir}/${db_type}_${cname}_${timestamp}.sql.gz"

    log "    🐬 ${db_type^}: $cname -> $(basename "$out")"

    if [[ -z "$mysql_pass" ]]; then
        log_warn "    No MYSQL_ROOT_PASSWORD/MARIADB_ROOT_PASSWORD found — trying without a password"
        if timeout "${DB_DUMP_TIMEOUT:-1800}" \
            docker exec "$container" sh -c \
            'mysqldump --all-databases --single-transaction --quick --routines --triggers -u root' \
            2>/dev/null | gzip > "$out"; then
            log_ok "    ${db_type^} dump done"
            prune_old_dumps "$dumps_dir" "${db_type}_${cname}_*.sql.gz" "${DB_DUMPS_RETENTION_COUNT:-3}"
            return 0
        fi
    else
        # Password goes via the MYSQL_PWD env, not --password (visible in ps)
        if timeout "${DB_DUMP_TIMEOUT:-1800}" \
            docker exec -e "MYSQL_PWD=$mysql_pass" "$container" sh -c \
            'mysqldump --all-databases --single-transaction --quick --routines --triggers -u root' \
            2>/dev/null | gzip > "$out"; then

            local size; size=$(du -h "$out" | awk '{print $1}')
            log_ok "    ${db_type^} dump done: $size"
            prune_old_dumps "$dumps_dir" "${db_type}_${cname}_*.sql.gz" "${DB_DUMPS_RETENTION_COUNT:-3}"
            return 0
        fi
    fi

    log_warn "    mysqldump failed for $cname"
    rm -f "$out"
    return 1
}

# --- Redis BGSAVE (produces a copy of the RDB file) ---
dump_redis() {
    local container="$1" project_dir="$2" timestamp="$3"
    local dumps_dir="${project_dir}/${DB_DUMPS_DIR:-db-dumps}"
    mkdir -p "$dumps_dir"
    # The directory may be left over from old versions with 755 — tighten it explicitly
    chmod 700 "$dumps_dir" 2>/dev/null || true

    local cname; cname=$(docker inspect --format '{{.Name}}' "$container" | sed 's|^/||')
    local out="${dumps_dir}/redis_${cname}_${timestamp}.rdb.gz"

    log "    🟥 Redis: $cname -> $(basename "$out")"

    # Password from the container environment. mailcow sets REDISPASS and runs redis with
    # --requirepass, so redis-cli without -a gets NOAUTH. The catch: redis-cli
    # returns 0 even when the server replied with an error: this used to look like
    # "BGSAVE succeeded", while the wait loop dutifully spun for DB_DUMP_TIMEOUT — all 30 minutes.
    local rpass
    rpass=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null |
            sed -n -E 's/^(REDISPASS|REDIS_PASSWORD|REDIS_PASS|REQUIREPASS)=//p' | head -1)
    # The password is often passed not as a variable but as an argument: redis-server --requirepass X
    if [[ -z "$rpass" ]]; then
        rpass=$(docker inspect --format '{{join .Config.Cmd " "}} {{join .Args " "}}' "$container" 2>/dev/null |
                sed -n -E 's/.*--requirepass[= ]+([^ ]+).*/\1/p' | head -1)
    fi
    local -a rcli=(redis-cli)
    [[ -n "$rpass" ]] && rcli=(redis-cli --no-auth-warning -a "$rpass")

    # Run BGSAVE and wait for it to finish (watching lastsave)
    local before after timeout_sec="${DB_DUMP_TIMEOUT:-1800}"
    before=$(docker exec "$container" "${rcli[@]}" LASTSAVE 2>/dev/null | tr -d '\r')

    # Check the REPLY, not the exit code: LASTSAVE must return unix time as a number. Not a number —
    # the command did not run (no auth, wrong port, not Redis), and there is nothing to wait for.
    if [[ ! "$before" =~ ^[0-9]+$ ]]; then
        log_warn "    Redis does not answer LASTSAVE for $cname (password needed? NOAUTH)"
        log_warn "    Logical dump skipped; the RDB still goes into the backup along with the volume"
        return 1
    fi

    if ! docker exec "$container" "${rcli[@]}" BGSAVE >/dev/null 2>&1; then
        log_warn "    redis-cli BGSAVE failed for $cname"
        return 1
    fi

    local i
    for ((i=0; i<timeout_sec; i++)); do
        sleep 1
        after=$(docker exec "$container" "${rcli[@]}" LASTSAVE 2>/dev/null | tr -d '\r')
        [[ "$after" != "$before" ]] && break
    done

    if [[ "$after" == "$before" ]]; then
        log_warn "    BGSAVE did not finish within ${timeout_sec}s for $cname"
        return 1
    fi

    # Find the RDB file path inside the container and copy it
    # CONFIG GET is also behind auth — pass the same arguments as above.
    local rdb_path rdb_dir rdb_name
    rdb_dir=$(docker exec "$container" "${rcli[@]}" CONFIG GET dir 2>/dev/null | tail -1 | tr -d '\r')
    rdb_name=$(docker exec "$container" "${rcli[@]}" CONFIG GET dbfilename 2>/dev/null | tail -1 | tr -d '\r')
    if [[ -n "$rdb_dir" && -n "$rdb_name" ]]; then
        rdb_path="${rdb_dir}/${rdb_name}"
    else
        rdb_path="/data/dump.rdb"
    fi

    if docker exec "$container" cat "$rdb_path" 2>/dev/null | gzip > "$out"; then
        local size; size=$(du -h "$out" | awk '{print $1}')
        log_ok "    Redis dump done: $size"
        prune_old_dumps "$dumps_dir" "redis_${cname}_*.rdb.gz" "${DB_DUMPS_RETENTION_COUNT:-3}"
        return 0
    else
        log_warn "    Could not copy the RDB file from $cname"
        rm -f "$out"
        return 1
    fi
}

# --- MongoDB dump ---
dump_mongo() {
    local container="$1" project_dir="$2" timestamp="$3"
    local dumps_dir="${project_dir}/${DB_DUMPS_DIR:-db-dumps}"
    mkdir -p "$dumps_dir"
    # The directory may be left over from old versions with 755 — tighten it explicitly
    chmod 700 "$dumps_dir" 2>/dev/null || true

    local cname; cname=$(docker inspect --format '{{.Name}}' "$container" | sed 's|^/||')
    local out_dir="${dumps_dir}/mongo_${cname}_${timestamp}"
    local out_archive="${out_dir}.tar.gz"

    # Get the root credentials
    local mongo_user mongo_pass
    mongo_user="$(container_env "$container" MONGO_INITDB_ROOT_USERNAME)"
    mongo_pass="$(container_env "$container" MONGO_INITDB_ROOT_PASSWORD)"

    log "    🍃 MongoDB: $cname -> $(basename "$out_archive")"

    # mongodump into /tmp inside the container
    local dump_cmd="mongodump --archive --gzip"
    if [[ -n "$mongo_user" && -n "$mongo_pass" ]]; then
        dump_cmd="mongodump --archive --gzip --username '$mongo_user' --password '$mongo_pass' --authenticationDatabase admin"
    fi

    if timeout "${DB_DUMP_TIMEOUT:-1800}" \
        docker exec "$container" sh -c "$dump_cmd" 2>/dev/null > "$out_archive"; then

        local size; size=$(du -h "$out_archive" | awk '{print $1}')
        log_ok "    MongoDB dump done: $size"
        prune_old_dumps "$dumps_dir" "mongo_${cname}_*.tar.gz" "${DB_DUMPS_RETENTION_COUNT:-3}"
        return 0
    else
        log_warn "    mongodump failed for $cname"
        rm -f "$out_archive"
        return 1
    fi
}

# --- Main auto-dump function ---
# usage: auto_dump_databases <project_name> <project_dir> <timestamp>
# Returns 0 if at least one dump succeeded (or there are no databases at all), 1 if there are databases but every dump failed
#
# Dumps are all of the database's data in plain form, lying in the project folder on the host.
# So all the work runs under umask 077 (files 600), and the db-dumps/ directory is 700.
auto_dump_databases() {
    [[ "${AUTO_DUMP_DATABASES:-true}" != "true" ]] && return 0
    ( umask 077; _auto_dump_databases_impl "$@" )
}

_auto_dump_databases_impl() {
    local project="$1" project_dir="$2" timestamp="$3"

    # Get all running containers of the project
    local containers
    containers=$(docker ps -q --filter "label=com.docker.compose.project=$project" 2>/dev/null || true)
    [[ -z "$containers" ]] && return 0

    local found_any=false
    local success_count=0
    local fail_count=0

    while IFS= read -r cid; do
        [[ -z "$cid" ]] && continue
        local image; image=$(docker inspect --format '{{.Config.Image}}' "$cid" 2>/dev/null || true)
        [[ -z "$image" ]] && continue

        local db_type; db_type=$(detect_db_type "$image")
        [[ -z "$db_type" ]] && continue

        # Check that the container is running (dumping needs exec)
        local state
        state=$(docker inspect --format '{{.State.Status}}' "$cid" 2>/dev/null || echo "")
        if [[ "$state" != "running" ]]; then
            log_warn "  Container $cid ($db_type) is not running (state=$state) — skipping dump"
            continue
        fi

        found_any=true
        case "$db_type" in
            postgres)
                [[ "${AUTO_DUMP_POSTGRES:-true}" == "true" ]] || continue
                if dump_postgres "$cid" "$project_dir" "$timestamp"; then
                    success_count=$((success_count + 1))
                else
                    fail_count=$((fail_count + 1))
                fi
                ;;
            mysql|mariadb)
                [[ "${AUTO_DUMP_MYSQL:-true}" == "true" ]] || continue
                if dump_mysql "$cid" "$project_dir" "$timestamp" "$db_type"; then
                    success_count=$((success_count + 1))
                else
                    fail_count=$((fail_count + 1))
                fi
                ;;
            redis)
                [[ "${AUTO_DUMP_REDIS:-true}" == "true" ]] || continue
                if dump_redis "$cid" "$project_dir" "$timestamp"; then
                    success_count=$((success_count + 1))
                else
                    fail_count=$((fail_count + 1))
                fi
                ;;
            mongo)
                [[ "${AUTO_DUMP_MONGO:-true}" == "true" ]] || continue
                if dump_mongo "$cid" "$project_dir" "$timestamp"; then
                    success_count=$((success_count + 1))
                else
                    fail_count=$((fail_count + 1))
                fi
                ;;
        esac
    done <<< "$containers"

    if $found_any; then
        log "  📊 Auto-dump: ${success_count} succeeded, ${fail_count} failed"
        # Return an error only if ALL dumps failed
        [[ $fail_count -gt 0 && $success_count -eq 0 ]] && return 1
    fi
    return 0
}

# ==============================================================================
# RUN TIME
# ==============================================================================
fmt_duration() {
    local sec="$1"
    if (( sec < 60 )); then
        printf '%ds' "$sec"
    elif (( sec < 3600 )); then
        printf '%dm %02ds' $((sec/60)) $((sec%60))
    else
        printf '%dh %02dm %02ds' $((sec/3600)) $(((sec%3600)/60)) $((sec%60))
    fi
}

# ==============================================================================
# BACKUP AGE BY KEY
# Age is taken from the timestamp in the key (YYYY-MM-DD_HH-MM-SS) — the real
# backup date. That way all storages rotate the same and do NOT depend on
# LastModified (the upload time into a particular bucket, which can differ,
# e.g. after sync-s3.sh). If no timestamp is found in the key —
# fall back to LastModified.
# usage: epoch=$(backup_epoch_from_key "$key" "$last_modified")
backup_epoch_from_key() {
    local key="$1" last_modified="${2:-}" ts d t
    ts="$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}' <<< "$key" | head -1 || true)"
    if [[ -n "$ts" ]]; then
        d="${ts%_*}"          # YYYY-MM-DD
        t="${ts#*_}"          # HH-MM-SS
        t="${t//-/:}"         # HH:MM:SS
        date -d "$d $t" +%s 2>/dev/null && return 0
    fi
    date -d "$last_modified" +%s 2>/dev/null || echo 0
}

# ==============================================================================
# ROTATION PLAN
# Decides which backups to delete and which to keep. The same function is
# used by the rotation itself (docker-backup.sh) and by the forecast in status.sh —
# otherwise "N objects will be deleted" and the actual deletion would follow different
# rules and drift apart.
#
# Input  (stdin):  lines "key<TAB>LastModified"
# Output (stdout): lines "KEEP<TAB>key" / "DELETE<TAB>key"
#
# The unit of decision is not an object but a BACKUP: all objects with a common prefix
# "BACKUP_PREFIX/project/timestamp/" (the archive and its .sha256) live and die together.
#
# Rules, in the order applied to one project's timestamps (newest to oldest):
#   1. The last KEEP_MIN_BACKUPS are ALWAYS kept, regardless of age.
#      This protects against "the project was renamed / backups failed for a month",
#      where plain age-based rotation wipes out the last surviving copy.
#   2. GFS_ENABLED=true  → keep one backup per day/week/month
#      in the amounts GFS_DAILY/GFS_WEEKLY/GFS_MONTHLY. RETENTION_DAYS is
#      not used then: the retention scheme is set by exactly these three numbers.
#   3. GFS_ENABLED=false → keep everything younger than RETENTION_DAYS.
#      RETENTION_DAYS=0 means "rotation off", nothing is deleted.
# ==============================================================================
plan_rotation() {
    local retention="${RETENTION_DAYS:-30}"
    local keep_min="${KEEP_MIN_BACKUPS:-3}"
    local gfs="${GFS_ENABLED:-false}"
    local gfs_daily="${GFS_DAILY:-7}"
    local gfs_weekly="${GFS_WEEKLY:-4}"
    local gfs_monthly="${GFS_MONTHLY:-6}"
    local prefix="${BACKUP_PREFIX:-backups}"

    [[ "$keep_min" =~ ^[0-9]+$ ]] || keep_min=3

    local -A group_epoch=()   # "project|timestamp" -> epoch
    local -A group_keys=()    # "project|timestamp" -> keys separated by \n
    local -A proj_groups=()   # "project"           -> groups separated by \n

    local key lm rest proj ts group epoch
    while IFS=$'\t' read -r key lm; do
        [[ -z "$key" ]] && continue
        # Expect a key of the form "<prefix>/<project>/<timestamp>/<file>"
        rest="${key#"${prefix}/"}"
        proj="${rest%%/*}"
        rest="${rest#*/}"
        ts="${rest%%/*}"
        # Not our format (no project or timestamp) — leave it alone to be safe
        if [[ -z "$proj" || -z "$ts" || "$ts" == "$rest" ]]; then
            printf 'KEEP\t%s\n' "$key"
            continue
        fi
        group="${proj}|${ts}"
        if [[ -z "${group_epoch[$group]:-}" ]]; then
            group_epoch["$group"]="$(backup_epoch_from_key "$key" "$lm")"
            proj_groups["$proj"]="${proj_groups[$proj]:-}${group}"$'\n'
        fi
        group_keys["$group"]="${group_keys[$group]:-}${key}"$'\n'
    done

    local now cutoff
    now="$(date +%s)"
    cutoff=$(( now - retention * 86400 ))

    local g e decision i k
    local day week month
    for proj in "${!proj_groups[@]}"; do
        # The KEEP_MIN_BACKUPS floor protects the last copies of a LIVE project whose backups broke.
        # A project that no longer exists on the server has nothing to protect: its copies age out by the
        # common retention, otherwise the last three would lie there forever — against the retention policy.
        # docker-backup.sh provides the list of live ones (ROTATION_LIVE_PROJECTS, one per line); unset — floor for all.
        local proj_keep="$keep_min"
        if [[ -n "${ROTATION_LIVE_PROJECTS+x}" ]] && ! grep -qxF -- "$proj" <<< "$ROTATION_LIVE_PROJECTS"; then
            proj_keep=0
        fi
        # The project's timestamps from newest to oldest
        local -a groups=()
        mapfile -t groups < <(
            while IFS= read -r g; do
                [[ -z "$g" ]] && continue
                printf '%s\t%s\n' "${group_epoch[$g]}" "$g"
            done <<< "${proj_groups[$proj]}" | sort -rn | cut -f2-
        )

        local -A seen_day=() seen_week=() seen_month=()
        local n_daily=0 n_weekly=0 n_monthly=0
        i=0

        local keep_by_gfs
        for g in "${groups[@]}"; do
            e="${group_epoch[$g]}"
            decision="DELETE"
            keep_by_gfs="false"

            # Count slots BEFORE the floor check and for every backup.
            # Otherwise the first KEEP_MIN_BACKUPS would bypass accounting, the daily
            # quota would start being spent only from the (KEEP_MIN+1)-th backup, and dense
            # retention would stretch to GFS_DAILY + KEEP_MIN days instead of GFS_DAILY.
            if [[ "$gfs" == "true" ]]; then
                # All three labels in one date call: on a bucket with thousands of objects
                # three separate calls per backup noticeably slow rotation down.
                day=""; week=""; month=""
                local dwm
                dwm="$(date -d "@$e" '+%Y-%m-%d %G-%V %Y-%m' 2>/dev/null || echo "")"
                [[ -n "$dwm" ]] && IFS=' ' read -r day week month <<< "$dwm"
                # The slot is taken by the first (newest) backup of the day/week/month.
                # Mark the slot as seen regardless of whether the quota was enough:
                # otherwise the next backup of the same day would again count as the first.
                if [[ -n "$day" && -z "${seen_day[$day]:-}" ]]; then
                    seen_day["$day"]=1
                    if (( n_daily < gfs_daily )); then
                        keep_by_gfs="true"; n_daily=$((n_daily + 1))
                    fi
                fi
                if [[ -n "$week" && -z "${seen_week[$week]:-}" ]]; then
                    seen_week["$week"]=1
                    if (( n_weekly < gfs_weekly )); then
                        keep_by_gfs="true"; n_weekly=$((n_weekly + 1))
                    fi
                fi
                if [[ -n "$month" && -z "${seen_month[$month]:-}" ]]; then
                    seen_month["$month"]=1
                    if (( n_monthly < gfs_monthly )); then
                        keep_by_gfs="true"; n_monthly=$((n_monthly + 1))
                    fi
                fi
            fi

            if (( i < proj_keep )); then
                decision="KEEP"     # floor — overrides any age limits
            elif [[ "$gfs" == "true" ]]; then
                [[ "$keep_by_gfs" == "true" ]] && decision="KEEP"
            elif [[ "$retention" == "0" ]]; then
                decision="KEEP"     # rotation off
            elif (( e >= cutoff )); then
                decision="KEEP"     # younger than the limit
            fi

            while IFS= read -r k; do
                [[ -z "$k" ]] && continue
                printf '%s\t%s\n' "$decision" "$k"
            done <<< "${group_keys[$g]}"

            i=$((i + 1))
        done
    done
    return 0
}
