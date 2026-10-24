#!/usr/bin/env bash
# ==============================================================================
# lib.sh — shared helpers for docker-backup.sh, docker-restore.sh and the other scripts
# Sourced via: source "${SCRIPT_DIR}/lib.sh"
# Expects backup.conf to be loaded already
# ==============================================================================

# conf_defaults [template] — every option backup.conf leaves out gets the value backup.conf.example (next to
# this file) gives it: the defaults the README documents, kept in one place. A config written by hand, or kept
# from an older version, lacks lines; under set -u each one used bare would stop the script. Left out: the
# primary storage's own settings — the template has placeholders there, not defaults.
conf_defaults() {
    local tpl="${1:-$(dirname "${BASH_SOURCE[0]}")/backup.conf.example}" line name
    [[ -r "$tpl" ]] || return 0
    while IFS= read -r line; do
        [[ "$line" =~ ^([A-Z][A-Z0-9_]*)= ]] || continue
        name="${BASH_REMATCH[1]}"
        [[ "$name" == PRIMARY_S3_* || -n "${!name+x}" ]] && continue
        eval "$line"
    done < "$tpl"
    return 0
}
conf_defaults

# Ctrl+C stops the script. aws-cli catches SIGINT itself and exits with an ordinary error code, so bash took it for
# a failed command and went on ("Cannot write to the bucket"). Raised again, the signal also stops the script that
# called this one (update.sh → validate-config.sh). A script with cleanup of its own sets its own trap after this.
trap 'trap - INT; kill -INT $$' INT

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

    # shellcheck disable=SC2034 # the colors are used by the scripts that source lib.sh
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
# LAST_STEP — the step under way, for "interrupted at …" (read by docker-backup.sh)
# shellcheck disable=SC2034
log_step()  { LAST_STEP="$*"; echo "${C_DIM}[$(_ts)]${C_RESET} ${C_CYAN}▶${C_RESET} ${C_BOLD}$*${C_RESET}" >&2; }
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

# in_project_list <project> <list> — 0 if the list (names or globs like test-*, spaces or commas) has it.
# For EXCLUDE_PROJECTS and DB_DUMP_EXCLUDE_PROJECTS.
in_project_list() {
    local name="$1" pat
    local -a pats=()
    mapfile -t pats < <(split_words "${2//,/ }")
    for pat in ${pats[@]+"${pats[@]}"}; do
        # shellcheck disable=SC2053 # a glob on purpose
        [[ "$name" == $pat ]] && return 0
    done
    return 1
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
    # The 'classic' transfer client, always: AWS CLI is moving its default to 'crt', which has no max_bandwidth
    # (S3_BANDWIDTH_LIMIT would be silently ignored) and is built for Amazon S3 rather than S3-compatible storages.
    # Pinned, an aws update does not change how uploads go — and aws stops warning about it.
    aws configure set default.s3.preferred_transfer_client classic 2>/dev/null || true
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

# conf_duplicates <conf> [template] — variables assigned more than once (bash keeps the LAST one).
# One line per variable, TAB-separated:
#   NAME  LAST_LINE  LAST_VALUE  EARLIER_LINE  EARLIER_VALUE  LOST
# EARLIER_* — the latest earlier line with a different value (or the first one if all are the same).
# LOST=1 — the last value is the template's default and an earlier line said something else: the user's
# setting is silently overridden by a default further down (how encryption was found switched off).
# A value appended at the end on purpose (an "overrides" block) is a duplicate with LOST=0.
conf_duplicates() {
    [[ -f "$1" ]] || return 0
    awk -F '\t' -v OFS='\t' '
        function parse(s,   name, val) {
            if (!match(s, /^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=/)) return ""
            name = substr(s, RSTART, RLENGTH); sub(/^[[:space:]]*(export[[:space:]]+)?/, "", name); sub(/=$/, "", name)
            val = substr(s, RSTART + RLENGTH); sub(/[[:space:]]+#.*$/, "", val); sub(/[[:space:]]+$/, "", val)
            PV = val; return name
        }
        FNR == NR && FILENAME != ARGV[2] { if ((k = parse($0)) != "" && !(k in def)) def[k] = PV; next }
        { if ((k = parse($0)) == "") next
          n[k]++; if (n[k] > 1) { pl[k] = ll[k]; pv[k] = lv[k] } ; ll[k] = FNR; lv[k] = PV
          if (n[k] == 1) { fl[k] = FNR; fv[k] = PV }
          vals[k, n[k]] = PV; lines[k, n[k]] = FNR }
        END { for (k in n) if (n[k] > 1) {
                el = fl[k]; ev = fv[k]
                for (i = n[k] - 1; i >= 1; i--) if (vals[k, i] != lv[k]) { el = lines[k, i]; ev = vals[k, i]; break }
                lost = ((k in def) && lv[k] == def[k] && ev != lv[k]) ? 1 : 0
                print k, ll[k], lv[k], el, ev, lost } }
    ' "${2:-/dev/null}" "$1" | sort
}

# Roles separated by spaces — for messages (the scripts run with IFS=$'\n\t', and ${S3_ROLES[*]} would print one per line)
s3_roles_txt() { local IFS=' '; printf '%s' "${S3_ROLES[*]}"; }

# days_ago N — "today", "1 day ago", "N days ago"
days_ago() {
    case "$1" in 0) printf 'today' ;; 1) printf '1 day ago' ;; *) printf '%s days ago' "$1" ;; esac
}

# ts_age <YYYY-mm-dd_HH-MM-SS> — a backup's age by the calendar (days_ago): last night's is "1 day ago" even
# 20 hours later, not "today". 1 if the name is not a date. +12 h: a day around a DST change is 23 or 25 hours.
ts_age() {
    local day now
    day="$(date -d "${1%%_*}" +%s 2>/dev/null)" || return 1
    now="$(date -d "$(date +%F)" +%s)"
    days_ago $(( (now - day + 43200) / 86400 ))
}

# join_list <item…> — "a, b, c" for messages. Not "${arr[*]}": the scripts run with IFS=$'\n\t', and that would put
# one item per line.
join_list() { local IFS=$'\x1f'; local s="$*"; printf '%s' "${s//$'\x1f'/, }"; }

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
# s3_complete <role> — the storage's settings are all there. The region too: every request is signed for it, and
# many S3-compatible storages reject a wrong one (it used to fall back to the primary's — wrong for another provider).
s3_complete() {
    local f
    for f in ACCESS_KEY SECRET_KEY ENDPOINT REGION BUCKET; do
        [[ -n "$(s3_var "$1" "$f")" ]] || return 1
    done
    return 0
}

# Enabled copies (all roles except primary) — in order
# s3_refresh — recompute after the config was re-sourced (the menu does that after editing storages)
s3_refresh() {
    local r
    S3_COPIES=()
    for r in "${S3_ROLES[@]:1}"; do
        s3_enabled "$r" && S3_COPIES+=("$r")
    done
    return 0
}
s3_refresh

# _aws_setup [role] [write|read] — point aws at the role's storage (primary and write by default).
#   read — the read-only key (<ROLE>_S3_RESTORE_*), if set.
# Sets S3_OPTS and S3_CUR_BUCKET / S3_CUR_ENDPOINT.
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
    export AWS_DEFAULT_REGION="$region"   # required (s3_complete); no fallback to another storage's region
    addr="$(s3_var "$role" ADDRESSING_STYLE)"
    export AWS_S3_ADDRESSING_STYLE="${addr:-path}"

    # The bandwidth limit is shared by all storages and set once, on the first write.
    # It goes into our AWS_CONFIG_FILE, which is recreated empty at startup:
    # if the limit is removed from backup.conf, it simply won't appear in the file.
    if [[ "$access" == "write" && -n "${S3_BANDWIDTH_LIMIT:-}" && -z "$_AWS_BANDWIDTH_SET" ]]; then
        aws configure set default.s3.max_bandwidth "$S3_BANDWIDTH_LIMIT" 2>/dev/null || true
        _AWS_BANDWIDTH_SET=1
    fi

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

# docker compose (v2, the Docker CLI plugin). The standalone docker-compose v1 is not supported: Docker ended it
# in 2023. usage: docker_compose -p NAME -f FILE up -d
docker_compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    else
        log_err "docker compose (v2) is not installed: install the Docker Compose plugin (docker-compose-plugin)"
        return 127
    fi
}

# s3_transient <aws output> — the failure is worth another try: the storage was busy or the connection broke.
# aws's own retries (max_attempts) are per HTTP request and do not cover all of these — OperationAborted
# ("a conflicting conditional operation is in progress", seen on a big upload) fails the whole multipart upload.
# Not transient: wrong keys, no bucket, no access — trying again would only delay the error.
s3_transient() {
    grep -qiE 'OperationAborted|SlowDown|InternalError|RequestTimeout|ServiceUnavailable|Throttl|TooManyRequests|\((500|502|503|504)\)|status code: 5[0-9][0-9]|Connection (reset|was closed|aborted)|connection broken|EndpointConnectionError|Could not connect|Read timeout|timed out|BrokenPipe|UNEXPECTED_EOF|IncompleteRead|reached max retries' <<< "$1" || return 1
    ! grep -qiE 'AccessDenied|InvalidAccessKeyId|SignatureDoesNotMatch|NoSuchBucket|InvalidBucketName|Forbidden \(403\)' <<< "$1"
}

# abort_key_uploads <bucket> <key> — abort unfinished multipart uploads of exactly this key (a failed upload
# leaves its parts behind: invisible, yet stored and billed). Quiet; best effort.
abort_key_uploads() {
    local bucket="$1" key="$2" id
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        AWS_MAX_ATTEMPTS=2 aws_q s3api abort-multipart-upload --bucket "$bucket" --key "$key" --upload-id "$id" >/dev/null 2>&1 \
            && log "    ✂  Aborted the unfinished upload of this file" \
            || log_warn "    Could not abort an unfinished upload of $key (the rotation step of the next full run will try again)"
    done < <(aws_q s3api list-multipart-uploads --bucket "$bucket" --prefix "$key" --output json 2>/dev/null \
        | jq -r --arg k "$key" '(.Uploads // [])[] | select(.Key == $k) | .UploadId' 2>/dev/null || true)
}

# Uploads a file to S3, with progress if the file is large.
# A transient failure (s3_transient) is retried: S3_UPLOAD_TRIES attempts in all (3), the pauses growing
# from S3_UPLOAD_RETRY_DELAY seconds (15 → 15, 45). Before every retry, and after the last failure, the
# unfinished multipart upload of this file is aborted.
# usage: aws_upload <local> <s3-url> [size]
# <local> can be an s3:// URL in the PRIMARY storage (a remote database's dump, which never was on this disk):
# then it is read from there and piped into <s3-url>, nothing is stored here. [size] — its exact size, which
# aws needs to pick the part size of a stream.
aws_upload() {
    local src="$1" dst="$2" size="${3:-}"
    local size_mb=0 tries="${S3_UPLOAD_TRIES:-3}" delay="${S3_UPLOAD_RETRY_DELAY:-15}" try=1 out rc errf
    if [[ -f "$src" ]]; then
        size_mb=$(( $(stat -c %s "$src" 2>/dev/null || echo 0) / 1048576 ))
    fi
    local bucket="${dst#s3://}"; local key="${bucket#*/}"; bucket="${bucket%%/*}"
    while true; do
        rc=0
        # Progress is shown for files > 100MB and only on a TTY (its stderr is still kept, to judge a failure)
        if [[ "$size_mb" -gt 100 && -t 2 ]]; then
            errf="$(mktemp)"
            aws_q s3 cp "$src" "$dst" 2> >(tee "$errf" >&2) || rc=$?
            out="$(cat "$errf" 2>/dev/null)"; rm -f "$errf"
        elif [[ "$src" == s3://* ]]; then
            # The read side in a subshell with the primary's keys (the read-only ones, if set); this shell keeps the copy's
            local -a exp=()
            [[ -n "$size" ]] && exp=(--expected-size "$size")
            out="$( { ( _aws_setup primary read && aws "${S3_OPTS[@]}" s3 cp "$src" - ) \
                | aws "${S3_OPTS[@]}" s3 cp - "$dst" --only-show-errors ${exp[@]+"${exp[@]}"}; } 2>&1)" || rc=$?
            if [[ -n "$out" ]]; then
                printf '%s\n' "$out" \
                    | grep -v -E 'InsecureRequestWarning|urllib3/connectionpool|certificate verification is strongly advised' >&2 || true
            fi
        else
            # Capture the output and the REAL aws exit code (not the grep filter's):
            # otherwise, under pipefail, a successful upload with no output reads as an error.
            # --only-show-errors: aws says "upload: <file> to <url>" for every success, which only fills the log
            out="$(aws_q s3 cp "$src" "$dst" --only-show-errors 2>&1)" || rc=$?
            if [[ -n "$out" ]]; then
                printf '%s\n' "$out" \
                    | grep -v -E 'InsecureRequestWarning|urllib3/connectionpool|certificate verification is strongly advised' >&2 || true
            fi
        fi
        (( rc == 0 )) && return 0
        if (( try >= tries )) || ! s3_transient "$out"; then
            abort_key_uploads "$bucket" "$key"
            return "$rc"
        fi
        local wait_s=$(( delay * (3 ** (try - 1)) ))
        log_warn "    The storage failed the upload ($(printf '%s' "$out" | grep -oiE 'OperationAborted|SlowDown|InternalError|RequestTimeout|ServiceUnavailable|Throttl[a-z]*|TooManyRequests|Connection [a-z]+|timed out|EndpointConnectionError|Could not connect|\((50[0-9])\)|reached max retries' | head -n 1)) — trying again in ${wait_s} s ($((try + 1))/${tries})..."
        abort_key_uploads "$bucket" "$key"
        sleep "$wait_s"
        try=$((try + 1))
    done
}

# aws_rm <s3://bucket/key> — delete one object; a transient storage error (OperationAborted and the like, see
# s3_transient) is tried again, like an upload. aws's text of the last failure goes to stderr. Returns aws's code.
aws_rm() {
    local url="$1" tries="${S3_UPLOAD_TRIES:-3}" delay="${S3_UPLOAD_RETRY_DELAY:-15}" try=1 out rc
    while true; do
        rc=0
        out="$(aws_q s3 rm "$url" 2>&1 >/dev/null)" || rc=$?
        (( rc == 0 )) && return 0
        if (( try >= tries )) || ! s3_transient "$out"; then
            [[ -n "$out" ]] && printf '%s\n' "$out" >&2
            return "$rc"
        fi
        sleep $(( delay * (3 ** (try - 1)) ))
        try=$((try + 1))
    done
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
    if aws_upload "$src" "$s3_url" "$expected_size"; then
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
#   Goes to every configured channel: Telegram, the webhook, email. A channel that fails is logged
#   and does not stop the others.
notify() {
    local level="$1" title="$2" body="${3:-}"

    case "${NOTIFY_ON:-error}" in
        none)   return 0 ;;
        error)  [[ "$level" == "success" ]] && return 0 ;;
        always) ;;
    esac
    notify_send "$level" "$title" "$body"
}

# notify_send <level> <title> <details, HTML> [channel] — build the message and send it, without the
# NOTIFY_ON filter. With a channel (telegram|webhook|email) — only there; exit code 1 if it failed,
# the reason is in NOTIFY_ERR. Without one — to every configured channel, failures go to the log.
notify_send() {
    local level="$1" title="$2" body="${3:-}" only="${4:-}"
    local icon="🟢"
    case "$level" in
        error) icon="🔴" ;;
        warn)  icon="🟠" ;;
    esac
    local name="${NOTIFY_NAME:-$(uname -n)}"
    local full
    full="${icon} <b>Server $(html_esc "$name"): $(html_esc "$title")</b>"
    [[ -n "$body" ]] && full+=$'\n'"$body"
    local plain_body=""; [[ -n "$body" ]] && plain_body="$(html_plain "$body")"
    local subject="${icon} Server ${name}: ${title}"
    local ch rc=0
    for ch in telegram webhook email; do
        [[ -n "$only" && "$ch" != "$only" ]] && continue
        notify_configured "$ch" || { [[ -n "$only" ]] && { NOTIFY_ERR="not configured"; return 1; }; continue; }
        NOTIFY_ERR=""
        case "$ch" in
            telegram) _notify_telegram "$full" ;;
            webhook)  _notify_webhook "$level" "$name" "$title" "$full" "$plain_body" ;;
            email)    _notify_email "$subject" "$full" ;;
        esac && continue
        rc=1
        [[ -z "$only" ]] && log_warn "Could not send the notification to ${ch}: ${NOTIFY_ERR:-unknown error}"
    done
    return "$rc"
}

# notify_configured <telegram|webhook|email> — the channel's settings are filled in.
notify_configured() {
    case "$1" in
        telegram) [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] ;;
        webhook)  [[ -n "${NOTIFY_WEBHOOK_URL:-}" ]] ;;
        email)    [[ -n "${EMAIL_TO:-}" && -n "${SMTP_HOST:-}" ]] ;;
        *)        return 1 ;;
    esac
}

# notify_test <channel> — a test message to one channel (validate-config, install). Prints the result.
notify_test() {
    if notify_send success "test message" "Sent by $(html_esc "${0##*/}") at $(date -u '+%Y-%m-%d %H:%M UTC'). If you see it, $(html_esc "$1") notifications work." "$1"; then
        return 0
    fi
    printf '%s\n' "${NOTIFY_ERR:-unknown error}" >&2
    return 1
}

# html_plain — message HTML to plain text: tags dropped, entities back to characters.
html_plain() {
    printf '%s' "$1" | sed -e 's/<[^>]*>//g' -e 's/&lt;/</g; s/&gt;/>/g; s/&amp;/\&/g'
}

# _cut_lines <text> <max bytes> — whole lines while they fit (never splits a UTF-8 character).
_cut_lines() {
    local text="$1" max="$2" out="" line
    (( ${#text} <= max )) && { printf '%s' "$text"; return 0; }
    while IFS= read -r line; do
        (( ${#out} + ${#line} + 2 > max - 4 )) && break
        out+="${out:+$'\n'}${line}"
    done <<< "$text"
    printf '%s\n…' "$out"
}

# curl_url_cfg <url> — the URL as a curl config line, for `curl -K <(curl_url_cfg "$url")`. The Telegram
# bot token and a webhook URL (Discord/Slack put their secret in it) stay off the command line, where any
# user of the host would see them in ps.
curl_url_cfg() {
    local u="${1//\\/\\\\}"
    u="${u//\"/\\\"}"
    printf 'url = "%s"\n' "$u"
}

# _tg_send <text> [HTML] — one sendMessage; the answer in TG_RESP. No answer at all (the network, a
# timeout) is tried again after 5 and 15 seconds; an answer, even a refusal, is final.
_tg_send() {
    local api="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" try=1 pause
    local -a pm=()
    [[ -n "${2:-}" ]] && pm=(--data-urlencode "parse_mode=$2" --data-urlencode "disable_web_page_preview=true")
    while :; do
        TG_RESP="$(curl -s -m 10 -X POST -K <(curl_url_cfg "$api") \
            --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
            --data-urlencode "text=$1" ${pm[@]+"${pm[@]}"} 2>/dev/null || true)"
        [[ "$TG_RESP" == *'"ok":'* ]] && return 0
        (( try >= ${TG_SEND_TRIES:-3} )) && return 1
        pause=$(( 5 * 3 ** (try - 1) )); try=$((try + 1))
        sleep "$pause"
    done
}

# Telegram: HTML; if the markup is rejected — as plain text, so the alert isn't lost over a tag.
# A message is at most 4096 characters: a longer one goes as plain text, cut on a line.
_notify_telegram() {
    local full="$1" resp
    if (( ${#full} <= 4000 )); then
        _tg_send "$full" HTML || { NOTIFY_ERR="no response from api.telegram.org"; return 1; }
        [[ "$TG_RESP" == *'"ok":true'* ]] && return 0
    fi
    _tg_send "$(_cut_lines "$(html_plain "$full")" 4000)" || true
    resp="$TG_RESP"
    [[ "$resp" == *'"ok":true'* ]] && return 0
    NOTIFY_ERR="$(printf '%s' "$resp" | jq -r '.description // empty' 2>/dev/null || true)"
    NOTIFY_ERR="${NOTIFY_ERR:-no response from api.telegram.org}"
    return 1
}

# webhook_format — the payload shape: NOTIFY_WEBHOOK_FORMAT, or guessed from the URL.
#   discord — {"content"} with Discord markdown (Discord rejects {"text"});
#   slack   — {"text"} with Slack markup (Slack, Mattermost, Rocket.Chat);
#   json    — {"text", "level", "server", "title", "details", "time"} for your own receiver.
webhook_format() {
    local f="${NOTIFY_WEBHOOK_FORMAT:-auto}"
    if [[ "$f" == "auto" ]]; then
        case "$NOTIFY_WEBHOOK_URL" in
            https://discord.com/api/webhooks/*|https://*.discord.com/api/webhooks/*|https://discordapp.com/api/webhooks/*) f=discord ;;
            https://hooks.slack.com/*) f=slack ;;
            *) f=json ;;
        esac
    fi
    printf '%s' "$f"
}

_notify_webhook() {
    local level="$1" server="$2" title="$3" full="$4" details="$5" payload code
    case "$(webhook_format)" in
        discord)
            # **bold**, `code`; a message is at most 2000 characters.
            payload="$(printf '%s' "$full" | sed -e 's#</\{0,1\}b>#**#g' -e 's#</\{0,1\}code>#`#g')"
            payload="$(_cut_lines "$(html_plain "$payload")" 1990)"
            payload="$(jq -n --arg t "$payload" '{content: $t, allowed_mentions: {parse: []}}')" ;;
        slack)
            # *bold*, `code`; & < > stay escaped, as Slack wants them.
            payload="$(printf '%s' "$full" | sed -e 's#</\{0,1\}b>#*#g' -e 's#</\{0,1\}code>#`#g' -e 's/<[^>]*>//g')"
            payload="$(jq -n --arg t "$payload" '{text: $t}')" ;;
        json)
            payload="$(jq -n --arg t "$(html_plain "$full")" --arg l "$level" --arg s "$server" --arg ti "$title" \
                --arg d "$details" --arg tm "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                '{text: $t, level: $l, server: $s, title: $ti, details: $d, time: $tm}')" ;;
        *)
            NOTIFY_ERR="NOTIFY_WEBHOOK_FORMAT must be auto, discord, slack or json"; return 1 ;;
    esac
    code="$(printf '%s' "$payload" | curl -s -m 15 -o /dev/null -w '%{http_code}' -X POST \
        -H 'Content-Type: application/json' --data-binary @- -K <(curl_url_cfg "$NOTIFY_WEBHOOK_URL") 2>/dev/null)" || true
    [[ "$code" == 2?? ]] && return 0
    if [[ -z "$code" || "$code" == "000" ]]; then NOTIFY_ERR="no response from the webhook URL"
    else NOTIFY_ERR="the webhook replied HTTP ${code}"; fi
    return 1
}

# Email over SMTP with curl (no mail server on this host needed). The message has a plain-text and
# an HTML part. The password goes to curl in a temporary config file, not on the command line.
_notify_email() {
    local subject="$1" full="$2"
    local sec="${SMTP_SECURITY:-starttls}" scheme="smtp" port from="${SMTP_FROM:-${SMTP_USER:-}}"
    case "$sec" in
        starttls) port=587 ;;
        tls)      port=465; scheme="smtps" ;;
        none)     port=25 ;;
        *) NOTIFY_ERR="SMTP_SECURITY must be starttls, tls or none"; return 1 ;;
    esac
    port="${SMTP_PORT:-$port}"
    [[ -n "$from" ]] || { NOTIFY_ERR="SMTP_FROM is empty"; return 1; }
    local -a rcpt=()
    mapfile -t rcpt < <(split_words "${EMAIL_TO//,/ }")
    (( ${#rcpt[@]} )) || { NOTIFY_ERR="EMAIL_TO is empty"; return 1; }

    local msg cfg boundary out rc=0 to_hdr
    msg="$(mktemp)" || { NOTIFY_ERR="mktemp failed"; return 1; }
    cfg="$(mktemp)" || { rm -f "$msg"; NOTIFY_ERR="mktemp failed"; return 1; }
    chmod 600 "$cfg"
    boundary="=_docker-backup_$(date +%s)_$$"
    to_hdr="$(printf '%s, ' "${rcpt[@]}")"; to_hdr="${to_hdr%, }"
    local html_body
    html_body="$(printf '%s' "$full" | sed -e 's#<code>#<code style="background:\#f2f2f2;padding:0 3px;border-radius:3px">#g' -e 's/$/<br>/')"
    {
        printf 'From: docker-backup-s3 <%s>\n' "$from"
        printf 'To: %s\n' "$to_hdr"
        printf 'Subject: =?UTF-8?B?%s?=\n' "$(printf '%s' "$subject" | base64 | tr -d '\n')"
        printf 'Date: %s\n' "$(LC_ALL=C date -R)"
        printf 'Message-ID: <%s.%s.%s@%s>\n' "$(date +%s)" "$$" "$RANDOM" "$(uname -n)"
        printf 'Auto-Submitted: auto-generated\n'
        printf 'MIME-Version: 1.0\n'
        printf 'Content-Type: multipart/alternative; boundary="%s"\n\n' "$boundary"
        printf -- '--%s\nContent-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: base64\n\n' "$boundary"
        html_plain "$full" | base64
        printf -- '--%s\nContent-Type: text/html; charset=UTF-8\nContent-Transfer-Encoding: base64\n\n' "$boundary"
        printf '<html><body style="font-family:sans-serif;font-size:14px;line-height:1.5">%s</body></html>' "$html_body" | base64
        printf -- '--%s--\n' "$boundary"
    } | sed 's/$/\r/' > "$msg"

    local -a args=(-sS -m 30 --url "${scheme}://${SMTP_HOST}:${port}" --mail-from "$from" --upload-file "$msg")
    local r
    for r in "${rcpt[@]}"; do args+=(--mail-rcpt "$r"); done
    [[ "$sec" == "starttls" ]] && args+=(--ssl-reqd)
    if [[ -n "${SMTP_USER:-}" ]]; then
        local cred="${SMTP_USER}:${SMTP_PASSWORD:-}"
        cred="${cred//\\/\\\\}"; cred="${cred//\"/\\\"}"
        printf 'user = "%s"\n' "$cred" > "$cfg"
        args+=(-K "$cfg")
    fi
    out="$(curl "${args[@]}" 2>&1)" || rc=$?
    rm -f "$msg" "$cfg"
    (( rc == 0 )) && return 0
    NOTIFY_ERR="$(printf '%s' "$out" | tail -n 1)"
    NOTIFY_ERR="${NOTIFY_ERR#curl: }"
    NOTIFY_ERR="${NOTIFY_ERR:-curl exit code $rc}"
    return 1
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
        # load — InternalError on every abort) would otherwise eat minutes of the rotation on
        # every run. If it fails — we'll try again on the next run.
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

# path_within <path> <dir> — the path is the directory itself or lies inside it.
# Not a plain prefix test: /opt/app-data is NOT inside /opt/app.
path_within() {
    local path="${1%/}" dir="${2%/}"
    [[ -n "$dir" && ( "$path" == "$dir" || "$path" == "$dir/"* ) ]]
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
        *mongo*) echo "mongo" ;;   # before percona: percona-server-mongodb is Mongo
        *mariadb*) echo "mariadb" ;;
        *mysql*|*percona*) echo "mysql" ;;
        *redis*|*keydb*|*valkey*) echo "redis" ;;
        *) echo "" ;;
    esac
}

# How database passwords are handled: they are read INSIDE the database container, by a small sh
# script, from the same variables the image itself uses (or the files their *_FILE twins point to —
# Docker secrets). They never come to this host's shell, never go on a command line (any user of the
# host sees command lines in ps), never into the log or the archive name. The one exception: a Redis
# password given as `redis-server --requirepass X` lives only in the container's Cmd (Redis hides it
# from its own process title), so it is read with docker inspect and handed to docker exec through the
# environment (-e NAME without a value), not as an argument.
#
# The scripts below run as `sh -c "$_DB_SH_LIB$script"`: busybox, dash and bash all understand them.
# They report through stderr: a line "@note …" is logged always, anything else only when the dump
# fails (the last lines — the reason). Exit code 3 means "not a database server" (an exporter, an admin
# UI, a backup sidecar whose image name matched): skipped, not counted as a failure.
_DB_SH_LIB='
sec() {
    for _n in "$@"; do
        eval "_v=\${$_n:-}"
        if [ -z "$_v" ]; then
            eval "_f=\${${_n}_FILE:-}"
            [ -n "$_f" ] && [ -r "$_f" ] && _v=$(cat "$_f")
        fi
        [ -n "$_v" ] && { printf "%s" "$_v"; return 0; }
    done
    return 1
}
has() { command -v "$1" >/dev/null 2>&1; }
note() { echo "@note $*" >&2; }
server() {
    for _b in "$@"; do has "$_b" && return 0; done
    echo "no database server in the container (none of: $*)" >&2; exit 3
}
'

# pg_dumpall = all databases + roles + tablespaces. The official image trusts the local socket, so the
# password is usually not needed; with scram on the socket or a custom pg_hba it is. Bitnami images
# keep the socket in /tmp and use their own variable names.
_PG_DUMP_SH='server postgres
has pg_dumpall || { echo "pg_dumpall not found in the container" >&2; exit 4; }
if p=$(sec POSTGRESQL_POSTGRES_PASSWORD); then u=postgres
else
    u=$(sec POSTGRES_USER POSTGRESQL_USERNAME) || u=postgres
    p=$(sec POSTGRES_PASSWORD POSTGRESQL_PASSWORD) || p=""
fi
[ -n "$p" ] && export PGPASSWORD="$p"
for s in /var/run/postgresql/.s.PGSQL.* /run/postgresql/.s.PGSQL.* /tmp/.s.PGSQL.*; do
    case "$s" in *.lock) continue ;; esac
    [ -S "$s" ] && { PGHOST=${s%/*}; PGPORT=${s##*.}; export PGHOST PGPORT; break; }
done
note "user $u"
exec pg_dumpall -U "$u"'

# mariadb-dump where there is one (MariaDB 11 images have no mysqldump at all), otherwise mysqldump.
# Accounts are tried in order: root with its password; the app user (MYSQL_USER) — when the root password
# is random or not in the environment, that user's database is dumped; root without a password.
# The first one that can log in makes the dump. The password goes in MYSQL_PWD, read by both tools.
_MYSQL_DUMP_SH='server mysqld mariadbd
if has mariadb-dump; then d=mariadb-dump; elif has mysqldump; then d=mysqldump
else echo "neither mariadb-dump nor mysqldump in the container" >&2; exit 4; fi
if has mariadb; then c=mariadb; elif has mysql; then c=mysql
else echo "no mariadb/mysql client in the container to check the login" >&2; exit 4; fi
login() { MYSQL_PWD="$2" "$c" -u "$1" -N -e "SELECT 1" >/dev/null 2>"$errf"; }
errf=$(mktemp 2>/dev/null || echo /dev/null)
ok=""
if rp=$(sec MYSQL_ROOT_PASSWORD MARIADB_ROOT_PASSWORD DBROOT); then
    ru=$(sec MYSQL_ROOT_USER MARIADB_ROOT_USER) || ru=root
    login "$ru" "$rp" && { ok=root; u=$ru; p=$rp; }
fi
if [ -z "$ok" ] && au=$(sec MYSQL_USER MARIADB_USER) && ap=$(sec MYSQL_PASSWORD MARIADB_PASSWORD); then
    login "$au" "$ap" && { ok=user; u=$au; p=$ap; }
fi
if [ -z "$ok" ] && [ -z "${rp:-}" ]; then
    login root "" && { ok=root; u=root; p=""; }
fi
if [ -z "$ok" ]; then
    echo "no account from the container environment can log in" >&2
    tail -n 2 "$errf" >&2; rm -f "$errf"; exit 1
fi
rm -f "$errf"
if [ "$ok" = root ]; then
    set -- --all-databases --events
    note "user $u, all databases"
else
    if db=$(sec MYSQL_DATABASE MARIADB_DATABASE); then set -- --databases "$db" --events; else set -- --all-databases; fi
    set -- "$@" --no-tablespaces
    note "no usable root password in the container: user $u, database ${db:-all it can see}"
fi
[ -n "$p" ] && export MYSQL_PWD="$p"
exec "$d" "$@" --single-transaction --quick --routines --triggers -u "$u"'

# BGSAVE, then the RDB file to stdout. $1 — the timeout in seconds, $2 — a config file from the server
# command line (may be empty). The password: from Cmd (DBB_REDIS_PASS, see above), from the config
# file, from the usual variables; tried in that order, and none at all first — a wrong guess is an
# error on a server without a password. REDISCLI_AUTH keeps it off the redis-cli command line.
_REDIS_DUMP_SH='server redis-server valkey-server keydb-server
cli=""
for b in redis-cli valkey-cli keydb-cli; do has "$b" && { cli=$b; break; }; done
[ -n "$cli" ] || { echo "no redis-cli in the container" >&2; exit 4; }
conf=${2:-}
[ -n "$conf" ] && [ ! -r "$conf" ] && conf=""
cfg() { [ -n "$conf" ] && sed -n "s/^[[:space:]]*$1[[:space:]][[:space:]]*//p" "$conf" | tail -n 1 | sed "s/^\"\(.*\)\"\$/\1/; s/^'"'"'\(.*\)'"'"'\$/\1/"; }
port=${DBB_REDIS_PORT:-$(cfg port)}; port=${port:-6379}
r() { "$cli" -p "$port" "$@" 2>&1 | tr -d "\r"; }
unset REDISCLI_AUTH
if [ "$(r PING)" != PONG ]; then
    found=""
    for pw in "${DBB_REDIS_PASS:-}" "$(cfg requirepass)" "$(sec REDIS_PASSWORD REDISPASS REDIS_PASS REQUIREPASS VALKEY_PASSWORD KEYDB_PASSWORD)"; do
        [ -n "$pw" ] || continue
        export REDISCLI_AUTH="$pw"
        [ "$(r PING)" = PONG ] && { found=1; break; }
        unset REDISCLI_AUTH
    done
    [ -n "$found" ] || { echo "Redis does not answer PING: $(r PING | head -n 1) (no password from the container works)" >&2; exit 1; }
fi
before=$(r LASTSAVE)
reply=$(r BGSAVE SCHEDULE)
case "$reply" in
    *started*|*"already in progress"*) wait_for=done ;;
    *scheduled*) wait_for=lastsave ;;
    *) echo "BGSAVE: $reply" >&2; exit 1 ;;
esac
i=0
while :; do
    info=$(r INFO persistence)
    case "$info" in
        *rdb_bgsave_in_progress:0*)
            [ "$wait_for" = done ] && break
            [ "$(r LASTSAVE)" != "$before" ] && break ;;
    esac
    i=$((i + 1))
    [ "$i" -ge "$1" ] && { echo "BGSAVE did not finish in $1 s" >&2; exit 1; }
    sleep 1
done
case "$(r INFO persistence)" in
    *rdb_last_bgsave_status:ok*) ;;
    *) echo "BGSAVE failed: rdb_last_bgsave_status is not ok (no space or no write access to the data folder?)" >&2; exit 1 ;;
esac
dir=$(r CONFIG GET dir | sed -n 2p); file=$(r CONFIG GET dbfilename | sed -n 2p)
[ -n "$dir" ] || dir=$(cfg dir); [ -n "$file" ] || file=$(cfg dbfilename)
case "$dir" in ""|*ERR*) dir=/data ;; esac
case "$file" in ""|*ERR*) file=dump.rdb ;; esac
note "$dir/$file"
exec cat "$dir/$file"'

# mongodump of everything, as an archive gzipped by mongodump itself. The password goes in on stdin:
# without --password, mongodump reads it from there when stdin is not a terminal.
_MONGO_DUMP_SH='server mongod
has mongodump || { echo "mongodump not found in the container (an image without the database tools?)" >&2; exit 4; }
if p=$(sec MONGO_INITDB_ROOT_PASSWORD MONGODB_ROOT_PASSWORD); then
    u=$(sec MONGO_INITDB_ROOT_USERNAME MONGODB_ROOT_USER) || u=root
    note "user $u"
    printf "%s\n" "$p" | mongodump --quiet --username "$u" --authenticationDatabase admin --archive --gzip
else
    note "no root password in the container: without authentication"
    exec mongodump --quiet --archive --gzip
fi'

# _db_dump <container> <out> <gzip|raw> <script> [args…] — runs the script in the container; its stdout
# goes to <out> (through gzip, or as is). Returns 0, 3 (not a database server: skipped) or 1, with the reason logged.
_db_dump() {
    local container="$1" out="$2" mode="$3" script="$4"; shift 4
    local err rc=0
    local -a st env=()
    err="$(mktemp "${out%/*}/.dump-err.XXXXXX")" || { log_warn "      Cannot create a temporary file in ${out%/*}"; return 1; }
    [[ -n "${DBB_REDIS_PASS:-}" ]] && env+=(-e DBB_REDIS_PASS)
    [[ -n "${DBB_REDIS_PORT:-}" ]] && env+=(-e DBB_REDIS_PORT)
    if [[ "$mode" == gzip ]]; then
        timeout "${DB_DUMP_TIMEOUT:-1800}" docker exec ${env[@]+"${env[@]}"} "$container" \
            sh -c "${_DB_SH_LIB}${script}" sh "$@" 2>"$err" | gzip > "$out"
        st=("${PIPESTATUS[@]}")
        rc=${st[0]}; (( rc == 0 && st[1] != 0 )) && rc=1
    else
        timeout "${DB_DUMP_TIMEOUT:-1800}" docker exec ${env[@]+"${env[@]}"} "$container" \
            sh -c "${_DB_SH_LIB}${script}" sh "$@" 2>"$err" > "$out" || rc=$?
    fi
    # docker exec could not start sh at all (126/127; our scripts exit 1, 3 or 4): an exporter built FROM scratch.
    # Docker prints that error to stdout, so it is not in $err.
    if (( rc == 126 || rc == 127 )); then
        rc=3; echo "no database server in the container (no shell in it)" > "$err"
    fi
    _db_report "$err" "$rc" "${DB_DUMP_TIMEOUT:-1800} s (DB_DUMP_TIMEOUT)" || rc=$?
    rm -f "$err"
    (( rc == 0 )) || rm -f "$out"
    return "$rc"
}

# _db_report <stderr file> <rc> <timeout text> — logs what a dump said on stderr: "@note …" lines always;
# when rc is not 0, the last 3 other lines (the reason). Returns 0, 3 (skipped: not a database server) or 1.
_db_report() {
    local errf="$1" rc="$2" line
    local -a notes=() errs=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "${line// /}" ]] && continue
        case "$line" in
            "@note "*) notes+=("${line#@note }") ;;
            *"Enter password"*|*"reading password from standard input"*) ;;
            *) errs+=("${line:0:200}") ;;
        esac
    done < "$errf"
    for line in ${notes[@]+"${notes[@]}"}; do log "      ${C_DIM}${line}${C_RESET}"; done
    (( rc == 0 )) && return 0
    if (( rc == 3 )); then
        log "      ⊘ Skipped: ${errs[0]:-not a database server}"
        return 3
    fi
    (( rc == 124 )) && errs+=("timed out after $3")
    (( ${#errs[@]} )) || errs=("exit code $rc")
    local n=${#errs[@]} i
    for (( i = (n > 3 ? n - 3 : 0); i < n; i++ )); do log_warn "      ${errs[i]}"; done
    return 1
}

# _db_prepare <container> <project_dir> — sets DUMPS_DIR (700) and CNAME.
_db_prepare() {
    DUMPS_DIR="${2}/${DB_DUMPS_DIR:-db-dumps}"
    mkdir -p "$DUMPS_DIR"
    # The directory may be left over from old versions with 755 — tighten it explicitly
    chmod 700 "$DUMPS_DIR" 2>/dev/null || true
    CNAME=$(docker inspect --format '{{.Name}}' "$1" | sed 's|^/||')
}

# _db_done <title> <file> <prune glob> — the size line and the rotation of local dumps.
# The new dump stays until the archive is in the storage (keep_local_dumps then leaves DB_DUMPS_RETENTION_COUNT).
# With DUMP_RECORD set, it notes there what the archive needs: "new" — this run's dump, "old" — earlier dumps of
# the same container (left out of the archive), "glob" — the mask for the cleanup after the upload.
_db_done() {
    local size keep="${DB_DUMPS_RETENTION_COUNT:-0}" f
    size=$(du -h "$2" | awk '{print $1}')
    log_ok "    $1 dump done: $size"
    [[ "$keep" =~ ^[0-9]+$ ]] || keep=0
    prune_old_dumps "$DUMPS_DIR" "$3" "$(( keep > 0 ? keep : 1 ))"
    [[ -n "${DUMP_RECORD:-}" ]] || return 0
    {
        printf 'new\t%s\n' "$2"
        # shellcheck disable=SC2086 # $3 is a glob on purpose
        for f in "$DUMPS_DIR"/$3; do
            [[ -f "$f" && "$f" != "$2" ]] && printf 'old\t%s\n' "$f"
        done
        printf 'glob\t%s\t%s\n' "$DUMPS_DIR" "$3"
    } >> "$DUMP_RECORD"
    return 0
}

# keep_local_dumps <record> — after the archive with the dumps is in the storage: of each container's dumps
# keep the DB_DUMPS_RETENTION_COUNT latest on the server (0 — none; the folder goes too, if nothing else is in it).
keep_local_dumps() {
    local rec="$1" kind dir glob keep="${DB_DUMPS_RETENTION_COUNT:-0}"
    [[ -f "$rec" ]] || return 0
    [[ "$keep" =~ ^[0-9]+$ ]] || keep=0
    while IFS=$'\t' read -r kind dir glob; do
        [[ "$kind" == glob ]] || continue
        prune_old_dumps "$dir" "$glob" "$keep"
        (( keep == 0 )) && rmdir "$dir" 2>/dev/null
    done < "$rec"
    return 0
}

# Delete old dumps by mask, keeping the last N
# usage: prune_old_dumps <dir> <pattern> <keep_count>
prune_old_dumps() {
    local dir="$1" pattern="$2" keep="$3"
    [[ -d "$dir" ]] || return 0
    # shellcheck disable=SC2012,SC2086 # $pattern is a glob on purpose; dump names have no spaces
    ls -t "$dir"/$pattern 2>/dev/null | tail -n +$((keep + 1)) | xargs -r rm -f || true   # no match is fine
}

dump_postgres() {
    local container="$1" timestamp="$3" rc=0 DUMPS_DIR CNAME
    _db_prepare "$container" "$2"
    local out="${DUMPS_DIR}/postgres_${CNAME}_${timestamp}.sql.gz"
    log "    🐘 PostgreSQL: $CNAME -> $(basename "$out")"
    _db_dump "$container" "$out" gzip "$_PG_DUMP_SH" || rc=$?
    (( rc == 0 )) || { (( rc == 3 )) || log_warn "    pg_dumpall failed for $CNAME"; return "$rc"; }
    _db_done PostgreSQL "$out" "postgres_${CNAME}_*.sql.gz"
}

dump_mysql() {
    local container="$1" timestamp="$3" db_type="$4" rc=0 DUMPS_DIR CNAME
    _db_prepare "$container" "$2"
    local out="${DUMPS_DIR}/${db_type}_${CNAME}_${timestamp}.sql.gz"
    local db_name="MySQL"; [[ "$db_type" == mariadb ]] && db_name="MariaDB"
    log "    🐬 ${db_name}: $CNAME -> $(basename "$out")"
    _db_dump "$container" "$out" gzip "$_MYSQL_DUMP_SH" || rc=$?
    (( rc == 0 )) || { (( rc == 3 )) || log_warn "    mariadb-dump/mysqldump failed for $CNAME"; return "$rc"; }
    _db_done "$db_name" "$out" "${db_type}_${CNAME}_*.sql.gz"
}

# A copy of the RDB file after BGSAVE.
dump_redis() {
    local container="$1" timestamp="$3" rc=0 DUMPS_DIR CNAME
    _db_prepare "$container" "$2"
    local out="${DUMPS_DIR}/redis_${CNAME}_${timestamp}.rdb.gz"
    log "    🟥 Redis: $CNAME -> $(basename "$out")"
    # The server command line: --requirepass X, --port N and a config file. Each argument on its own line;
    # `sh -c "redis-server --requirepass X"` is one argument, so the words inside it are looked at too.
    local -a words=()
    local w prev="" conf="" DBB_REDIS_PASS="" DBB_REDIS_PORT=""
    mapfile -t words < <(docker inspect --format '{{range .Config.Entrypoint}}{{println .}}{{end}}{{range .Config.Cmd}}{{println .}}{{end}}' "$container" 2>/dev/null | tr ' \t' '\n\n')
    for w in ${words[@]+"${words[@]}"}; do
        case "$prev" in
            --requirepass) DBB_REDIS_PASS="$w" ;;
            --port) DBB_REDIS_PORT="$w" ;;
        esac
        case "$w" in
            --requirepass=*) DBB_REDIS_PASS="${w#--requirepass=}" ;;
            --port=*) DBB_REDIS_PORT="${w#--port=}" ;;
            *.conf) [[ -z "$conf" ]] && conf="$w" ;;
        esac
        prev="$w"
    done
    # Quotes from `sh -c "… --requirepass '$X'"`
    DBB_REDIS_PASS="${DBB_REDIS_PASS#[\"\']}"; DBB_REDIS_PASS="${DBB_REDIS_PASS%[\"\']}"
    [[ "$DBB_REDIS_PASS" == *'$'* ]] && DBB_REDIS_PASS=""   # a variable, not the password: the env lookup finds it
    [[ "$DBB_REDIS_PORT" =~ ^[0-9]+$ ]] || DBB_REDIS_PORT=""
    export DBB_REDIS_PASS DBB_REDIS_PORT
    _db_dump "$container" "$out" gzip "$_REDIS_DUMP_SH" "${DB_DUMP_TIMEOUT:-1800}" "$conf" || rc=$?
    (( rc == 0 )) || { (( rc == 3 )) || log_warn "    Redis dump failed for $CNAME; the RDB still goes into the backup along with the volume"; return "$rc"; }
    _db_done Redis "$out" "redis_${CNAME}_*.rdb.gz"
}

# A mongodump archive (gzipped by mongodump): mongorestore --archive=<file> --gzip.
# Versions before 2.0.0 named it .tar.gz though it is not a tar; those are removed with the first new dump.
dump_mongo() {
    local container="$1" timestamp="$3" rc=0 DUMPS_DIR CNAME
    _db_prepare "$container" "$2"
    local out="${DUMPS_DIR}/mongo_${CNAME}_${timestamp}.archive.gz"
    log "    🍃 MongoDB: $CNAME -> $(basename "$out")"
    _db_dump "$container" "$out" raw "$_MONGO_DUMP_SH" || rc=$?
    (( rc == 0 )) || { (( rc == 3 )) || log_warn "    mongodump failed for $CNAME"; return "$rc"; }
    _db_done MongoDB "$out" "mongo_${CNAME}_*.archive.gz"
    prune_old_dumps "$DUMPS_DIR" "mongo_${CNAME}_*.tar.gz" 0
}

# --- Main auto-dump function ---
# usage: auto_dump_databases <project_name> <project_dir> <timestamp>
# Returns 0 if at least one dump succeeded (or there are no databases at all), 1 if there are databases but every dump failed
#
# Dumps are all of the database's data in plain form, lying in the project folder on the host.
# So all the work runs under umask 077 (files 600), and the db-dumps/ directory is 700.
auto_dump_databases() {
    [[ "${AUTO_DUMP_DATABASES:-true}" != "true" ]] && return 0
    if in_project_list "$1" "${DB_DUMP_EXCLUDE_PROJECTS:-}"; then
        log "  ⊘ Database dumps are off for this project (DB_DUMP_EXCLUDE_PROJECTS)"
        return 0
    fi
    ( umask 077; _auto_dump_databases_impl "$@" )
}

# db_dump_skipped <container> — 0 if the container carries the label docker-backup-s3.skip=true
db_dump_skipped() {
    [[ "$(docker inspect --format '{{ index .Config.Labels "docker-backup-s3.skip" }}' "$1" 2>/dev/null)" == "true" ]]
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
        if db_dump_skipped "$cid"; then
            log "  ⊘ $(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||'): label docker-backup-s3.skip=true — no dump"
            continue
        fi

        # Check that the container is running (dumping needs exec)
        local state
        state=$(docker inspect --format '{{.State.Status}}' "$cid" 2>/dev/null || echo "")
        if [[ "$state" != "running" ]]; then
            log_warn "  Container $cid ($db_type) is not running (state=$state) — skipping dump"
            continue
        fi

        # rc 3 — not a database server after all (an exporter, an admin UI): not counted
        local rc=0
        case "$db_type" in
            postgres)
                [[ "${AUTO_DUMP_POSTGRES:-true}" == "true" ]] || continue
                dump_postgres "$cid" "$project_dir" "$timestamp" || rc=$? ;;
            mysql|mariadb)
                [[ "${AUTO_DUMP_MYSQL:-true}" == "true" ]] || continue
                dump_mysql "$cid" "$project_dir" "$timestamp" "$db_type" || rc=$? ;;
            redis)
                [[ "${AUTO_DUMP_REDIS:-true}" == "true" ]] || continue
                dump_redis "$cid" "$project_dir" "$timestamp" || rc=$? ;;
            mongo)
                [[ "${AUTO_DUMP_MONGO:-true}" == "true" ]] || continue
                dump_mongo "$cid" "$project_dir" "$timestamp" || rc=$? ;;
        esac
        case "$rc" in
            0) found_any=true; success_count=$((success_count + 1)) ;;
            3) ;;
            *) found_any=true; fail_count=$((fail_count + 1)) ;;
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
# REMOTE DATABASES
# Databases that are not containers on this host: a managed service, a database on another server.
# Listed in backup.conf: REMOTE_DBS="shop cache", then REMOTE_DB_<NAME>_<FIELD> for each one
# (the name in capitals, "-" as "_"), the fields in REMOTE_DB_FIELDS (see backup.conf.example).
#
# The dump is made by a throwaway client container and goes into the primary storage through a pipe,
# dump | gzip | gpg | aws s3 cp -, so nothing lands on this host's disk, however big it is. Redis is the
# exception: its client needs a file, kept inside the container and gone with it. The copies read the
# dump back from the primary the same way (aws_upload with an s3:// source). In the storages it is a
# project named _db_<name>, so rotation, sync-s3, status, verify-restore and docker-restore handle it
# like the others.
#
# Passwords go to docker as -e NAME, with the value taken from this shell's environment and not from the
# command line, and to mongodump on stdin. The container runs with --log-driver none: otherwise Docker
# keeps everything the container prints, which is the whole dump, in its own log file on this disk.
# ==============================================================================
# shellcheck disable=SC2034 # the menu uses it
REMOTE_DB_FIELDS=(TYPE HOST PORT USER PASSWORD PASSWORD_FILE DATABASE SSL IMAGE NETWORK ARGS TIMEOUT MAX_SIZE)

# remote_db_names — the names in REMOTE_DBS, one per line (spaces or commas between them)
remote_db_names() { local l="${REMOTE_DBS:-}"; split_words "${l//,/ }"; }

# remote_db_key <name> — its part of the variable names: shop-db → SHOP_DB
remote_db_key() { local k="${1^^}"; printf '%s' "${k//-/_}"; }

# remote_db_var <name> <FIELD> — the value of REMOTE_DB_<NAME>_<FIELD>
remote_db_var() {
    local n; n="REMOTE_DB_$(remote_db_key "$1")_$2"
    [[ "$n" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 0
    printf '%s' "${!n:-}"
}

remote_db_default_port() {
    case "$1" in postgres) echo 5432 ;; mysql|mariadb) echo 3306 ;; mongo) echo 27017 ;; redis) echo 6379 ;; esac
}

# The client images. A newer client dumps an older server, not the other way round: pg_dump refuses a
# server newer than itself. REMOTE_DB_<NAME>_IMAGE picks another one.
remote_db_default_image() {
    case "$1" in
        postgres) echo postgres:18-alpine ;;
        mysql)    echo mysql:8.4 ;;
        mariadb)  echo mariadb:11.4 ;;
        mongo)    echo mongo:8 ;;
        redis)    echo redis:7-alpine ;;
    esac
}

# remote_db_check <name> — what is wrong with its settings, one problem per line; 1 if anything is
remote_db_check() {
    local name="$1" k type host v
    local -a bad=()
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9_-]{0,47}$ ]]; then
        echo "the name \"$name\": lower-case letters, digits, - and _ only (up to 48)"
        return 1
    fi
    k="REMOTE_DB_$(remote_db_key "$name")"
    type="$(remote_db_var "$name" TYPE)"; host="$(remote_db_var "$name" HOST)"
    case "$type" in
        postgres|mysql|mariadb|mongo|redis) ;;
        "") bad+=("${k}_TYPE is not set (postgres, mysql, mariadb, mongo or redis)") ;;
        *)  bad+=("${k}_TYPE=$type is not a known type (postgres, mysql, mariadb, mongo or redis)") ;;
    esac
    if [[ -z "$host" ]]; then
        bad+=("${k}_HOST is not set")
    elif [[ "$host" =~ ://[^/@]*:[^/@]*@ ]]; then
        # It would be on the client's command line, which every user of the host can read in ps
        bad+=("${k}_HOST has a password in it: put the password in ${k}_PASSWORD")
    elif [[ "$host" == *://* && "$type" != mongo ]]; then
        bad+=("${k}_HOST: an address with :// works for mongo only; give the host name")
    fi
    v="$(remote_db_var "$name" PORT)"
    [[ -z "$v" || "$v" =~ ^[0-9]{1,5}$ ]] || bad+=("${k}_PORT=$v is not a port number")
    v="$(remote_db_var "$name" SSL)"
    [[ -z "$v" || "$v" == true || "$v" == false ]] || bad+=("${k}_SSL=$v: true or false")
    v="$(remote_db_var "$name" TIMEOUT)"
    [[ -z "$v" || "$v" =~ ^[1-9][0-9]*$ ]] || bad+=("${k}_TIMEOUT=$v is not a number of seconds")
    v="$(remote_db_var "$name" MAX_SIZE)"
    [[ -z "$v" || "$v" =~ ^[1-9][0-9]*[KMGT]?$ ]] || bad+=("${k}_MAX_SIZE=$v: a size like 200G")
    v="$(remote_db_var "$name" PASSWORD_FILE)"
    if [[ -n "$v" ]]; then
        [[ -n "$(remote_db_var "$name" PASSWORD)" ]] && bad+=("both ${k}_PASSWORD and ${k}_PASSWORD_FILE are set: keep one")
        [[ -r "$v" ]] || bad+=("${k}_PASSWORD_FILE: cannot read $v")
    fi
    (( ${#bad[@]} )) || return 0
    printf '%s\n' "${bad[@]}"
    return 1
}

# remote_db_password <name> — PASSWORD, or the first line of PASSWORD_FILE
remote_db_password() {
    local p f
    p="$(remote_db_var "$1" PASSWORD)"; f="$(remote_db_var "$1" PASSWORD_FILE)"
    if [[ -z "$p" && -n "$f" && -r "$f" ]]; then IFS= read -r p < "$f" || true; fi
    printf '%s' "$p"
}

# remote_db_desc <name> — "postgres db.example.com:5432, database shop, user backup, TLS" (no password)
remote_db_desc() {
    local n="$1" type host port db user where
    type="$(remote_db_var "$n" TYPE)"; host="$(remote_db_var "$n" HOST)"; db="$(remote_db_var "$n" DATABASE)"
    port="$(remote_db_var "$n" PORT)"; port="${port:-$(remote_db_default_port "$type")}"
    user="$(remote_db_var "$n" USER)"
    where="$host"; [[ "$host" == *://* ]] || where="${host}:${port}"
    if [[ -n "$db" ]]; then printf '%s %s, database %s' "${type:-?}" "$where" "$db"
    else printf '%s %s, all databases' "${type:-?}" "$where"; fi
    [[ -n "$user" ]] && printf ', user %s' "$user"
    [[ "$(remote_db_var "$n" SSL)" == true ]] && printf ', TLS'
    return 0
}

# _remote_db_build <name> <dump|probe> — the client container for a dump (or a quick login check):
#   RDB_DOCKER  the arguments of docker run      RDB_ENV    NAME=value pairs it gets by -e NAME
#   RDB_FEED    true — RDB_STDIN goes to its stdin (mongo: the password)
#   RDB_GZIP    true — gzip the output here      RDB_EXT    the dump file's extension
#   RDB_IMAGE, RDB_TIMEOUT (seconds), RDB_CNAME (the container's name, to remove it if it is left running)
# shellcheck disable=SC2034 # RDB_EXT: docker-backup.sh names the dump with it
_remote_db_build() {
    local name="$1" what="$2" type host port user db ssl net pw
    local -a args=() cmd=() conn=()
    type="$(remote_db_var "$name" TYPE)"; host="$(remote_db_var "$name" HOST)"
    port="$(remote_db_var "$name" PORT)"; port="${port:-$(remote_db_default_port "$type")}"
    user="$(remote_db_var "$name" USER)"; db="$(remote_db_var "$name" DATABASE)"
    ssl="$(remote_db_var "$name" SSL)"; net="$(remote_db_var "$name" NETWORK)"
    RDB_IMAGE="$(remote_db_var "$name" IMAGE)"; RDB_IMAGE="${RDB_IMAGE:-$(remote_db_default_image "$type")}"
    RDB_TIMEOUT="$(remote_db_var "$name" TIMEOUT)"; RDB_TIMEOUT="${RDB_TIMEOUT:-14400}"
    [[ "$what" == probe ]] && RDB_TIMEOUT=60
    RDB_CNAME="dbb-db-${name}-$$"
    mapfile -t args < <(split_words "$(remote_db_var "$name" ARGS)")
    pw="$(remote_db_password "$name")"
    RDB_ENV=(); RDB_FEED=false; RDB_STDIN=""; RDB_GZIP=true; RDB_EXT=sql.gz
    case "$type" in
        postgres)
            user="${user:-postgres}"
            [[ -n "$pw" ]] && RDB_ENV+=("PGPASSWORD=$pw")
            [[ "$ssl" == true ]] && RDB_ENV+=("PGSSLMODE=require")
            RDB_ENV+=("PGCONNECT_TIMEOUT=30")
            conn=(-h "$host" -p "$port" -U "$user")
            if [[ "$what" == probe ]]; then
                cmd=(psql "${conn[@]}" -d "${db:-postgres}" -tAc "SELECT version()")
            elif [[ -n "$db" ]]; then
                cmd=(pg_dump "${conn[@]}" ${args[@]+"${args[@]}"} "--dbname=$db")
            else
                cmd=(pg_dumpall "${conn[@]}" ${args[@]+"${args[@]}"})
            fi ;;
        mysql|mariadb)
            user="${user:-root}"
            local dumper=mysqldump client=mysql tls=--ssl-mode=REQUIRED
            [[ "$type" == mariadb ]] && { dumper=mariadb-dump; client=mariadb; tls=--ssl; }
            [[ -n "$pw" ]] && RDB_ENV+=("MYSQL_PWD=$pw")
            # TCP even for "localhost": the client would look for a local socket file otherwise
            conn=(-h "$host" -P "$port" -u "$user" --protocol=TCP)
            [[ "$ssl" == true ]] && conn+=("$tls")
            if [[ "$what" == probe ]]; then
                cmd=("$client" "${conn[@]}" -N -e "SELECT VERSION()")
            else
                cmd=("$dumper" "${conn[@]}" --single-transaction --quick --routines --triggers --no-tablespaces ${args[@]+"${args[@]}"})
                if [[ -n "$db" ]]; then cmd+=(--databases "$db"); else cmd+=(--all-databases); fi
            fi ;;
        mongo)
            if [[ "$host" == mongodb://* || "$host" == mongodb+srv://* ]]; then conn=("--uri=$host")
            else conn=(--host "$host" --port "$port"); fi
            # Without --password, mongodump reads it from stdin
            if [[ -n "$user" ]]; then conn+=(--username "$user" --authenticationDatabase admin); RDB_FEED=true; RDB_STDIN="$pw"; fi
            [[ "$ssl" == true ]] && conn+=(--tls)
            if [[ "$what" == probe ]]; then
                # Nothing to dump: a collection that is not there. It still has to log in and list the database.
                cmd=(mongodump --quiet "${conn[@]}" --db "${db:-admin}" --collection dbb-probe-none --archive=/dev/null)
            else
                cmd=(mongodump --quiet "${conn[@]}")
                [[ -n "$db" ]] && cmd+=(--db "$db")
                cmd+=(${args[@]+"${args[@]}"} --archive --gzip)
            fi
            RDB_GZIP=false; RDB_EXT=archive.gz ;;
        redis)
            [[ -n "$pw" ]] && RDB_ENV+=("REDISCLI_AUTH=$pw")
            conn=(-h "$host" -p "$port")
            [[ -n "$user" ]] && conn+=(--user "$user")
            [[ "$ssl" == true ]] && conn+=(--tls)
            if [[ "$what" == probe ]]; then
                cmd=(redis-cli "${conn[@]}" ${args[@]+"${args[@]}"} PING)
            else
                # A file, not --rdb - : on stdout redis-cli leaves the transfer's end marker in the stream
                cmd=(sh -c 'redis-cli "$@" --rdb /tmp/dbb.rdb >&2 || exit 1
[ -s /tmp/dbb.rdb ] || { echo "the server sent an empty RDB file" >&2; exit 1; }
exec cat /tmp/dbb.rdb' sh "${conn[@]}" ${args[@]+"${args[@]}"})
            fi
            RDB_EXT=rdb.gz ;;
    esac
    local e
    RDB_DOCKER=(--rm --log-driver none --name "$RDB_CNAME" --network "${net:-host}")
    for e in ${RDB_ENV[@]+"${RDB_ENV[@]}"}; do RDB_DOCKER+=(-e "${e%%=*}"); done
    [[ "$RDB_FEED" == true ]] && RDB_DOCKER+=(-i)
    RDB_DOCKER+=("$RDB_IMAGE" "${cmd[@]}")
}

# _remote_db_run — docker run of what _remote_db_build set, its stdout to stdout. In a subshell: the passwords
# are exported there only, for docker to pass on.
_remote_db_run() {
    (
        local e
        for e in ${RDB_ENV[@]+"${RDB_ENV[@]}"}; do export "${e?}"; done
        if [[ "$RDB_FEED" == true ]]; then
            printf '%s\n' "$RDB_STDIN" | timeout "$RDB_TIMEOUT" docker run "${RDB_DOCKER[@]}"
        else
            timeout "$RDB_TIMEOUT" docker run "${RDB_DOCKER[@]}" < /dev/null
        fi
    )
}

_rdb_compress() { if [[ "$RDB_GZIP" == true ]]; then gzip -c "-${COMPRESS_LEVEL:-6}"; else cat; fi; }
_rdb_encrypt() {
    if [[ "${ENCRYPT_BACKUPS:-false}" == "true" ]]; then
        gpg --batch --yes --quiet --passphrase-file "$GPG_PASSPHRASE_FILE" --symmetric --cipher-algo AES256 -o -
    else
        cat
    fi
}

# remote_db_image_ready — the client image is here, or pulled now. 1 with docker's reason in the log.
remote_db_image_ready() {
    docker image inspect "$RDB_IMAGE" >/dev/null 2>&1 && return 0
    log "  ⬇  Pulling the client image $RDB_IMAGE..."
    local out
    out="$(docker pull -q "$RDB_IMAGE" 2>&1)" && return 0
    log_err "  Could not pull $RDB_IMAGE: $(tail -n 1 <<< "$out")"
    return 1
}

# _size_bytes <200G> — the number of bytes (K, M, G, T are powers of 1024)
_size_bytes() {
    local n="${1%[KMGT]}"
    case "$1" in
        *K) echo $(( n * 1024 )) ;; *M) echo $(( n * 1048576 )) ;;
        *G) echo $(( n * 1073741824 )) ;; *T) echo $(( n * 1099511627776 )) ;;
        *) echo "$n" ;;
    esac
}

# _rdb_drop <bucket> <key> — remove a dump that must not stay: aws finishes an upload as soon as its input
# ends, so a dump that broke off would lie there looking like a complete one.
_rdb_drop() {
    abort_key_uploads "$1" "$2"
    aws_q s3api head-object --bucket "$1" --key "$2" >/dev/null 2>&1 || return 0
    if aws_rm "s3://$1/$2" 2>/dev/null; then log "  ✂  Removed the incomplete dump from the storage"
    else log_warn "  Could not remove the incomplete dump s3://$1/$2 — delete it by hand"; fi
}

# remote_db_stream <name> <s3 key> — after _remote_db_build <name> dump: the dump into the primary storage.
# Sets RDB_SIZE (bytes, checked against the storage) and RDB_SHA256. 0 — it is in place; 1 — it is not,
# the reason logged. A transient storage failure is retried with a new dump (a stream cannot be sent twice),
# S3_UPLOAD_TRIES attempts in all, like any upload.
remote_db_stream() {
    local name="$1" key="$2" bucket="$PRIMARY_S3_BUCKET"
    local url="s3://${PRIMARY_S3_BUCKET}/$2" tries="${S3_UPLOAD_TRIES:-3}" delay="${S3_UPLOAD_RETRY_DELAY:-15}"
    local try=1 dir st rc_src rc_gz rc_gpg rc_tee rc_aws aws_out i s3_size ms wait_s
    local -a exp=()
    RDB_SIZE=""; RDB_SHA256=""
    dir="$(mktemp -d "${WORK_DIR:-/var/tmp/docker-backup}/remote-db.XXXXXX")" \
        || { log_err "  Cannot create a temporary folder in ${WORK_DIR:-/var/tmp/docker-backup}"; return 1; }
    ms="$(remote_db_var "$name" MAX_SIZE)"
    [[ -n "$ms" ]] && exp=(--expected-size "$(_size_bytes "$ms")")
    while true; do
        : > "$dir/err"; rm -f "$dir/sum" "$dir/size"
        st="$(
            set +e
            _remote_db_run 2> "$dir/err" | _rdb_compress | _rdb_encrypt \
                | tee >(sha256sum | awk '{print $1}' > "$dir/sum") >(wc -c > "$dir/size") \
                | aws "${S3_OPTS[@]}" s3 cp - "$url" --only-show-errors ${exp[@]+"${exp[@]}"} > "$dir/aws" 2>&1
            printf '%s ' "${PIPESTATUS[@]}"
        )"
        IFS=' ' read -r rc_src rc_gz rc_gpg rc_tee rc_aws <<< "$st"
        rc_src="${rc_src:-1}" rc_gz="${rc_gz:-1}" rc_gpg="${rc_gpg:-1}" rc_tee="${rc_tee:-1}" rc_aws="${rc_aws:-1}"
        # Gone by itself with --rm, but not after a timeout or a broken pipe: then docker run ended, the container did not
        docker rm -f "$RDB_CNAME" >/dev/null 2>&1 || true
        aws_out="$(grep -v -E 'InsecureRequestWarning|urllib3/connectionpool|certificate verification is strongly advised' "$dir/aws" || true)"
        (( rc_aws == 0 )) && break
        if (( try < tries )) && s3_transient "$aws_out"; then
            wait_s=$(( delay * (3 ** (try - 1)) ))
            log_warn "    The storage failed the upload ($(grep -oiE 'OperationAborted|SlowDown|InternalError|RequestTimeout|ServiceUnavailable|Throttl[a-z]*|TooManyRequests|Connection [a-z]+|timed out|EndpointConnectionError|Could not connect|reached max retries' <<< "$aws_out" | head -n 1)) — dumping again in ${wait_s} s ($((try + 1))/${tries})..."
            abort_key_uploads "$bucket" "$key"
            sleep "$wait_s"
            try=$((try + 1))
            continue
        fi
        log_err "  The upload to the primary S3 failed"
        [[ -n "$aws_out" ]] && tail -n 3 <<< "$aws_out" | sed 's/^/      /' >&2
        _rdb_drop "$bucket" "$key"
        rm -rf "$dir"
        return 1
    done
    if (( rc_src != 0 || rc_gz != 0 || rc_gpg != 0 || rc_tee != 0 )); then
        if (( rc_src != 0 )); then
            log_err "  The dump failed"
            case "$rc_src" in
                125) echo "docker could not start the client container (image $RDB_IMAGE, network $(remote_db_var "$name" NETWORK))" >> "$dir/err" ;;
                126|127) echo "the dump tool is not in the image $RDB_IMAGE (REMOTE_DB_$(remote_db_key "$name")_IMAGE)" >> "$dir/err" ;;
            esac
            _db_report "$dir/err" "$rc_src" "${RDB_TIMEOUT} s (REMOTE_DB_$(remote_db_key "$name")_TIMEOUT)" || true
        else
            log_err "  Compressing or encrypting the dump failed (gzip $rc_gz, gpg $rc_gpg, tee $rc_tee)"
        fi
        _rdb_drop "$bucket" "$key"
        rm -rf "$dir"
        return 1
    fi
    # The counts come from tee's two side processes, which end a moment after it
    for (( i = 0; i < 300; i++ )); do
        [[ -s "$dir/sum" && -s "$dir/size" ]] && break
        sleep 0.1
    done
    # shellcheck disable=SC2034 # docker-backup.sh writes the manifest from it
    RDB_SHA256="$(cat "$dir/sum" 2>/dev/null || true)"
    RDB_SIZE="$(tr -dc '0-9' < "$dir/size" 2>/dev/null || true)"
    rm -rf "$dir"
    s3_size="$(aws_q s3api head-object --bucket "$bucket" --key "$key" --query ContentLength --output text 2>/dev/null || echo 0)"
    if [[ -z "$RDB_SIZE" || "$s3_size" != "$RDB_SIZE" ]]; then
        log_err "  Size in S3 (${s3_size}) != sent (${RDB_SIZE:-unknown})"
        _rdb_drop "$bucket" "$key"
        return 1
    fi
    return 0
}

# remote_db_probe <name> — logs in with the backup's settings and asks the server something small.
# Prints its answer (the version) or the reason it failed; 1 if it failed.
remote_db_probe() {
    local name="$1" out rc=0 problems
    if ! problems="$(remote_db_check "$name")"; then printf '%s\n' "$problems"; return 1; fi
    _remote_db_build "$name" probe
    if ! docker image inspect "$RDB_IMAGE" >/dev/null 2>&1; then
        out="$(docker pull -q "$RDB_IMAGE" 2>&1)" || { printf 'could not pull %s: %s\n' "$RDB_IMAGE" "$(tail -n 1 <<< "$out")"; return 1; }
    fi
    out="$(_remote_db_run 2>&1)" || rc=$?
    docker rm -f "$RDB_CNAME" >/dev/null 2>&1 || true
    out="$(grep -v -i -E 'Enter password|reading password from standard input|^[[:space:]]*$|^(mysql: \[)?warning' <<< "$out" | tr -d '\r' || true)"
    # redis-cli prints a refusal (NOAUTH, WRONGPASS) with exit code 0
    [[ "$(remote_db_var "$name" TYPE)" == redis && "$out" != PONG* ]] && (( rc == 0 )) && rc=1
    if (( rc == 0 )); then
        [[ -z "$out" ]] && out="logged in"
        head -n 1 <<< "$out"
        return 0
    fi
    (( rc == 124 )) && out="no answer in ${RDB_TIMEOUT} s${out:+: $out}"
    tail -n 3 <<< "${out:-exit code $rc}"
    return 1
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

    local key lm rest proj ts group
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
