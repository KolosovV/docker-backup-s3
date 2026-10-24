#!/usr/bin/env bash
# ==============================================================================
# diagnose-s3.sh
# Shows the REAL S3 access errors — hides nothing (unlike
# validate-config.sh, which mutes output with 2>/dev/null), BUT drops the
# useless urllib3 SSL warning (it pours out on every call with --no-verify-ssl).
#
# Checks the PRIMARY S3 and every configured copy (secondary, tertiary), and for each
# gives a clear verdict: whether the key is valid, which addressing style works
# (path / virtual-hosted) and what to put into backup.conf.
#
# Usage:  sudo bash /opt/docker-backup-s3/diagnose-s3.sh
# ==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/backup.conf"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config) CONFIG_FILE="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [-c FILE]"
            echo
            echo "S3 access diagnostics with the real aws errors: for the primary and every enabled copy —"
            echo "whether the key works, which addressing style works, and what to put into backup.conf."
            echo
            echo "  -c, --config FILE   config file (default: backup.conf next to the script)"
            echo "  -h, --help          this help"
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done
[[ -f "$CONFIG_FILE" ]] || { echo "❌ No $CONFIG_FILE"; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG_FILE"
# Ctrl+C stops it: aws-cli catches SIGINT and exits with an ordinary error (the same trap as in lib.sh)
trap 'trap - INT; kill -INT $$' INT

# aws-cli is installed by the official installer (/usr/local/bin) or via snap (/snap/bin),
# which may not be in PATH — this script doesn't source lib.sh, so add them manually.
for _d in /usr/local/bin /snap/bin; do
    case ":${PATH}:" in *":${_d}:"*) ;; *) export PATH="${PATH}:${_d}" ;; esac
done
command -v aws >/dev/null 2>&1 || { echo "❌ aws not found. Reinstall it: sudo ${SCRIPT_DIR}/install.sh"; exit 1; }

# Same as in lib.sh: checksums only where the S3 itself requires them (the explanation is there).
# Diagnostics must behave like the backup, otherwise they're green while the backup fails.
export AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}"
export AWS_RESPONSE_CHECKSUM_VALIDATION="${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}"

# Mute urllib3 SSL warnings at the source (aws-cli is Python).
export PYTHONWARNINGS="ignore"

PREFIX="${BACKUP_PREFIX:-backups}"

# Filter out noise lines (urllib3 SSL warnings) — in case PYTHONWARNINGS didn't help.
_filter_noise() {
    grep -v -E 'InsecureRequestWarning|urllib3/connectionpool|certificate verification is strongly advised|tls-warnings'
}

# Runs one aws command: prints the cleaned output, returns the REAL aws exit code.
run() {
    local title="$1"; shift
    echo "─── $title ───"
    echo "  \$ aws ${*}"
    local output rc cleaned
    output="$(aws "$@" 2>&1)"; rc=$?
    cleaned="$(printf '%s\n' "$output" | _filter_noise || true)"
    [[ -n "${cleaned//[[:space:]]/}" ]] && printf '%s\n' "$cleaned" | sed 's/^/    /'
    if (( rc == 0 )); then echo "  → OK (exit 0)"; else echo "  → ERROR (exit $rc)"; fi
    echo
    return "$rc"
}

mark() { (( $1 == 0 )) && echo "✓ works" || echo "✗ does not work"; }

# Full diagnostics of one storage.
#   $1=label $2=access $3=secret $4=region $5=endpoint $6=bucket $7=addressing $8=opts_extra $9=addressing_var_name
diagnose_store() {
    local label="$1" access="$2" secret="$3" region="$4" endpoint="$5" bucket="$6" addressing="$7" opts="$8" var="$9"

    echo "================================================================"
    echo "  DIAGNOSTICS: ${label} S3"
    echo "================================================================"
    echo "  ENDPOINT  = ${endpoint:-(empty)}"
    echo "  REGION    = ${region:-(empty)}"
    echo "  BUCKET    = ${bucket:-(empty)}"
    if [[ -n "$access" ]]; then
        echo "  ACCESS    = ${access:0:4}...${access: -4}"
    else
        echo "  ACCESS    = (empty)"
    fi
    echo "  ADDRESSING= ${addressing:-path} (from the config)"
    echo "  OPTS_EXTRA= ${opts:-(empty)}"
    echo

    # This storage's credentials/endpoint — set directly (without lib.sh, to keep it explicit)
    export AWS_ACCESS_KEY_ID="$access"
    export AWS_SECRET_ACCESS_KEY="$secret"
    export AWS_DEFAULT_REGION="${region:-us-east-1}"
    local EP=(--endpoint-url "$endpoint")
    # shellcheck disable=SC2206
    [[ -n "$opts" ]] && EP+=($opts)

    local rc_lsp rc_headp rc_objp rc_lsv rc_headv rc_objv rc_write

    echo "############ TEST 1: path-style (as usual in the config) ############"
    export AWS_S3_ADDRESSING_STYLE=path
    run "1a. List all buckets (checks that the key is valid)"   "${EP[@]}" s3 ls; rc_lsp=$?
    run "1b. head-bucket of the specific bucket"                "${EP[@]}" s3api head-bucket --bucket "$bucket"; rc_headp=$?
    run "1c. List objects in the bucket"                        "${EP[@]}" s3 ls "s3://${bucket}"
    run "1d. list-objects-v2 (as in backup/rotation)"          "${EP[@]}" s3api list-objects-v2 --bucket "$bucket" --max-items 1; rc_objp=$?

    echo "############ TEST 2: virtual-hosted ############"
    export AWS_S3_ADDRESSING_STYLE=virtual
    run "2a. List all buckets"                                 "${EP[@]}" s3 ls; rc_lsv=$?
    run "2b. head-bucket"                                      "${EP[@]}" s3api head-bucket --bucket "$bucket"; rc_headv=$?
    run "2c. List objects in the bucket"                       "${EP[@]}" s3 ls "s3://${bucket}"; rc_objv=$?

    echo "############ TEST 3: test write (path-style) ############"
    export AWS_S3_ADDRESSING_STYLE=path
    local testkey wout dout cleaned_w
    testkey="${PREFIX}/.diag-$(date +%s).tmp"
    echo "─── 3a. Write and delete a test object (a 9 MB file, multipart — like a backup archive) ───"
    # Not "echo diag | s3 cp -": a write from stdin goes a different path and would succeed where a real
    # archive fails (aws-cli checksums, see lib.sh). The multipart threshold
    # of aws-cli is 8 MB, hence 9 MB.
    local tfile; tfile="$(mktemp)"
    head -c 9M /dev/urandom > "$tfile"
    wout="$(aws "${EP[@]}" s3 cp "$tfile" "s3://${bucket}/${testkey}" --no-progress 2>&1)"; rc_write=$?
    rm -f "$tfile"
    cleaned_w="$(printf '%s\n' "$wout" | _filter_noise || true)"
    [[ -n "${cleaned_w//[[:space:]]/}" ]] && printf '%s\n' "$cleaned_w" | sed 's/^/    /'
    if (( rc_write == 0 )); then
        echo "  → OK (written, deleting the test object)"
        dout="$(aws "${EP[@]}" s3 rm "s3://${bucket}/${testkey}" 2>&1)"
        printf '%s\n' "$dout" | _filter_noise | sed 's/^/    /' || true
    else
        echo "  → write ERROR (exit $rc_write)"
    fi
    echo

    # ----------------------------------------------------------------------
    # VERDICT
    # ----------------------------------------------------------------------
    local path_ok=0 virt_ok=0 key_ok=0
    (( rc_headp == 0 && rc_objp == 0 )) && path_ok=1
    (( rc_headv == 0 && rc_objv == 0 )) && virt_ok=1
    (( rc_lsp == 0 || rc_lsv == 0 ))    && key_ok=1

    echo "════════════════ SUMMARY: ${label} S3 ════════════════"
    if (( key_ok == 1 )); then
        echo "  Key / access:     ✓ valid (S3 responds, the key is accepted)"
    else
        echo "  Key / access:     ✗ NOT valid — SignatureDoesNotMatch / no connection / wrong endpoint"
    fi
    if (( rc_headp == 0 || rc_headv == 0 )); then
        echo "  Bucket '${bucket}':  ✓ exists and is reachable"
    else
        echo "  Bucket '${bucket}':  ✗ unreachable or not created (NoSuchBucket / no permissions)"
    fi
    echo "  path-style:       $(mark $(( path_ok == 1 ? 0 : 1 )))"
    echo "  virtual-hosted:   $(mark $(( virt_ok == 1 ? 0 : 1 )))"
    echo "  Test write:       $( (( rc_write == 0 )) && echo '✓ succeeded' || echo '✗ failed' )"
    echo

    # Addressing style recommendation
    local rec=""
    (( path_ok == 1 )) && rec="path"
    [[ -z "$rec" ]] && (( virt_ok == 1 )) && rec="virtual"

    if [[ -z "$rec" ]]; then
        echo "  ⚠ Verdict: neither path nor virtual responds."
        echo "    Check the endpoint / keys / that the bucket exists (errors are in the blocks above)."
    elif (( path_ok == 1 && virt_ok == 1 )); then
        echo "  ✓ Verdict: BOTH styles work. The current ${var}=\"${addressing}\" is fine, no need to change it."
    elif [[ "$rec" == "${addressing}" ]]; then
        echo "  ✓ Verdict: \"${rec}\" works — that is your current ${var}=\"${addressing}\". All good."
    else
        echo "  ⚠ Verdict: only \"${rec}\" works, while you have ${var}=\"${addressing}\"."
        echo "    FIX in backup.conf:  ${var}=\"${rec}\""
    fi
    echo
}

# ==============================================================================
# Storages: the primary — always, copies — if enabled or at least filled in
# ==============================================================================
# v <FIELD> — value of <P>_<FIELD> for the current storage
v() { local n="${P}_$1"; printf '%s' "${!n:-}"; }
for role in primary secondary tertiary; do
    P="${role^^}_S3"
    case "$role" in primary) title="PRIMARY" ;; secondary) title="SECONDARY" ;; tertiary) title="TERTIARY" ;; esac
    if [[ "$role" != "primary" ]]; then
        en="${P}_ENABLED"; bk="${P}_BUCKET"; ak="${P}_ACCESS_KEY"
        if [[ "${!en:-false}" != "true" ]] && { [[ -z "${!bk:-}" ]] || [[ -z "${!ak:-}" ]]; }; then
            echo "================================================================"
            echo "  ${title} S3 is not configured — skipping (that's fine)."
            echo "================================================================"
            echo
            continue
        fi
    fi
    addr="$(v ADDRESSING_STYLE)"
    diagnose_store "$title" \
        "$(v ACCESS_KEY)" "$(v SECRET_KEY)" "$(v REGION)" "$(v ENDPOINT)" \
        "$(v BUCKET)" "${addr:-path}" "$(v OPTS_EXTRA)" "${P}_ADDRESSING_STYLE"
done

echo "=== OVERALL SUMMARY ==="
echo "• For each storage above there is a \"SUMMARY\" block with a verdict and a recommendation."
