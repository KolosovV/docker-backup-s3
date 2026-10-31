#!/usr/bin/env bash
# ==============================================================================
# validate-config.sh
# Checks that the configuration is correct and every component is in order.
# Run it after the initial installation or after changes to backup.conf.
# ==============================================================================
set -uo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/backup.conf"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config) CONFIG_FILE="$2"; shift 2 ;;
        -h|--help)
            cat <<EOF
Usage: $0 [-c <config_file>]
Checks the docker-backup-s3 configuration and that every component is reachable.
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
# system_ca_bundle (the same one the installer uses)
# shellcheck source=ui.sh
source "${SCRIPT_DIR}/ui.sh"

ERRORS=0
WARNINGS=0

ok()    { echo "  ${C_GREEN}✓${C_RESET} $*"; }
err()   { echo "  ${C_RED}✗ $*${C_RESET}"; ERRORS=$((ERRORS + 1)); }
warn()  { echo "  ${C_YELLOW}⚠ $*${C_RESET}"; WARNINGS=$((WARNINGS + 1)); }

# The bucket is unreachable — find out why. If aws does not trust the certificate
# (CERTIFICATE_VERIFY_FAILED; that's aws from snap with a storage on the GlobalSign Root R46 root),
# try with the system CA bundle and, if that works, give a ready line for backup.conf.
# --no-verify-ssl is not suggested: without verification the storage can be spoofed.
# aws options come from S3_OPTS, set by _aws_setup. usage: cert_hint <OPTS_EXTRA_NAME> <bucket>
cert_hint() {
    local var="$1" bucket="$2" cur="${!1:-}" out bundle
    out="$(aws "${S3_OPTS[@]}" s3api head-bucket --bucket "$bucket" 2>&1 >/dev/null)" && return 0
    if [[ "$out" != *CERTIFICATE_VERIFY_FAILED* ]]; then
        out="$(printf '%s\n' "$out" | grep -v -E 'InsecureRequestWarning|urllib3|^[[:space:]]*$' | tail -1)"
        [[ -n "$out" ]] && echo "    aws: $out"
        return 0
    fi
    echo "    Reason: aws does not trust the S3 certificate (CERTIFICATE_VERIFY_FAILED)"
    if [[ "$cur" == *--ca-bundle* ]]; then
        echo "    ${var} already has --ca-bundle, but it is still rejected. If the certificate is self-signed —"
        echo "    put its root into /usr/local/share/ca-certificates/ and run update-ca-certificates"
        return 0
    fi
    if ! bundle="$(system_ca_bundle)"; then
        echo "    No system CA bundle — install the ca-certificates package and check again"
        return 0
    fi
    out="$(aws "${S3_OPTS[@]}" --ca-bundle "$bundle" s3api head-bucket --bucket "$bucket" 2>&1 >/dev/null)"
    if [[ "$out" == *CERTIFICATE_VERIFY_FAILED* ]]; then
        echo "    Rejected with the system CA bundle (${bundle}) too. If the certificate is"
        echo "    self-signed — its root into /usr/local/share/ca-certificates/, then update-ca-certificates"
        return 0
    fi
    echo "    With the system CA bundle the certificate is accepted. Put this into backup.conf:"
    echo "      ${C_BOLD}${var}=\"${cur:+$cur }--ca-bundle ${bundle}\"${C_RESET}"
}

# --no-verify-ssl in the options: it works, but without verification the storage can be spoofed
check_no_verify() {
    local var="$1"
    [[ "${!var:-}" == *--no-verify-ssl* ]] || return 0
    warn "${var} contains --no-verify-ssl — the S3 certificate is not verified. Remove it and run"
    echo "    validate-config.sh again: if aws does not trust the certificate, it will suggest a line with --ca-bundle"
}
section() { echo; echo "${C_BOLD}${C_CYAN}━━━ $* ━━━${C_RESET}"; }

# ==============================================================================
# 1. STORAGES — the primary always, copies (secondary, tertiary) if enabled
# ==============================================================================
for role in "${S3_ROLES[@]}"; do
    P="${role^^}_S3"
    if [[ "$role" != "primary" ]]; then
        s3_enabled "$role" || continue
        section "Configuration — $(s3_label "$role")"
        ok "${P}_ENABLED = true (REQUIRED=$(s3_var "$role" REQUIRED))"
    else
        section "Configuration — $(s3_label "$role")"
    fi
    for f in ACCESS_KEY SECRET_KEY ENDPOINT BUCKET; do
        var="${P}_${f}"; val="$(s3_var "$role" "$f")"
        if [[ -z "$val" ]]; then
            err "$var is not set"
        elif [[ "$val" == YOUR_* || "$val" == *_ACCESS_KEY || "$val" == *_SECRET_KEY ]]; then
            err "$var is not filled in with a real value yet (placeholder)"
        else
            case "$f" in
                ACCESS_KEY) ok "$var = ${val:0:4}...${val: -4}" ;;
                SECRET_KEY) ok "$var is set (${#val} characters, not shown)" ;;
                *) ok "$var = $val" ;;
            esac
        fi
    done
    val="$(s3_var "$role" ENDPOINT)"
    if [[ -n "$val" && ! "$val" =~ ^https?:// ]]; then
        err "${P}_ENDPOINT has no http(s):// — give the scheme (e.g. https://${val})"
    fi
    val="$(s3_var "$role" REGION)"
    if [[ -n "$val" ]]; then ok "${P}_REGION = ${val}"
    else err "${P}_REGION is empty — the storage's region is required (requests are signed for it): see your provider's docs"; fi
    val="$(s3_var "$role" ADDRESSING_STYLE)"; ok "${P}_ADDRESSING_STYLE = ${val:-path}"
    val="$(s3_var "$role" OPTS_EXTRA)";       ok "${P}_OPTS_EXTRA = ${val:-(empty)}"
    check_no_verify "${P}_OPTS_EXTRA"
    val="$(s3_var "$role" RESTORE_ACCESS_KEY)"
    [[ -n "$val" ]] && ok "${P}_RESTORE_ACCESS_KEY = ${val:0:4}...${val: -4} (read-only for restore)"
done

# --- General settings ---
section "Configuration — general settings"
for var in BACKUP_PREFIX RETENTION_DAYS BACKUP_MODE WORK_DIR LOG_FILE; do
    val="${!var:-}"
    [[ -z "$val" ]] && err "$var is not set" || ok "$var = $val"
done
ok "S3_BANDWIDTH_LIMIT = ${S3_BANDWIDTH_LIMIT:-no limit}"
ok "PARALLEL_JOBS = ${PARALLEL_JOBS:-1}"
ok "ENCRYPT_BACKUPS = ${ENCRYPT_BACKUPS:-false}"
ok "SCAN_DIRS = ${SCAN_DIRS:-(not set)}"
ok "NOTIFY_ON = ${NOTIFY_ON:-error}"
while IFS= read -r _l; do
    case "${_l%,}" in
        ""|success|warn|error) ;;
        *) err "NOTIFY_SILENT: unknown level '${_l}' (success, warn, error)" ;;
    esac
done < <(split_words "${NOTIFY_SILENT-success}")

if [[ ! "$RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
    err "RETENTION_DAYS must be an integer ≥ 0 (0 = rotation off)"
elif (( RETENTION_DAYS == 0 )) && [[ "${GFS_ENABLED:-false}" != "true" ]]; then
    warn "RETENTION_DAYS=0 — rotation is off: old backups are NOT deleted (watch the storage size)"
fi

# --- Rotation: the floor and GFS ---
if [[ ! "${KEEP_MIN_BACKUPS:-3}" =~ ^[0-9]+$ ]]; then
    err "KEEP_MIN_BACKUPS must be an integer (now: ${KEEP_MIN_BACKUPS:-})"
elif (( ${KEEP_MIN_BACKUPS:-3} == 0 )); then
    warn "KEEP_MIN_BACKUPS=0 — no floor: rotation may delete a project's last copy"
else
    ok "KEEP_MIN_BACKUPS = ${KEEP_MIN_BACKUPS:-3} (this many latest backups are never deleted)"
fi

if [[ "${GFS_ENABLED:-false}" == "true" ]]; then
    for gvar in GFS_DAILY GFS_WEEKLY GFS_MONTHLY; do
        gval="${!gvar:-}"
        [[ "$gval" =~ ^[0-9]+$ ]] || err "$gvar must be an integer (now: '$gval')"
    done
    ok "GFS enabled: ${GFS_DAILY:-7} d / ${GFS_WEEKLY:-4} w / ${GFS_MONTHLY:-6} m (RETENTION_DAYS is not used)"
else
    ok "GFS off — flat retention by RETENTION_DAYS"
fi

ok "CHECKSUM_MANIFEST = ${CHECKSUM_MANIFEST:-true}"
if [[ "${CHECKSUM_MANIFEST:-true}" == "true" ]] && ! command -v sha256sum >/dev/null 2>&1; then
    err "CHECKSUM_MANIFEST=true, but sha256sum not found (coreutils package)"
fi

# Database auto-dump without backing up the project folder = dumps are created but go nowhere
if [[ "${AUTO_DUMP_DATABASES:-true}" == "true" && "${BACKUP_PROJECT_DIR:-true}" != "true" ]]; then
    err "AUTO_DUMP_DATABASES=true with BACKUP_PROJECT_DIR=false: database dumps land in the project folder, but it doesn't go into the archive"
fi

case "$BACKUP_MODE" in
    stop|pause|hot) : ;;
    *) err "BACKUP_MODE must be stop, pause or hot (now: $BACKUP_MODE)" ;;
esac

if [[ "$BACKUP_MODE" == "hot" ]]; then
    warn "BACKUP_MODE=hot — database consistency is ensured by the database auto-dump + pre-backup-hook.sh"
fi

# A variable set twice: bash keeps the last one, so a "true" higher up silently loses to a template default lower
# down. This is how encryption was found switched off on a server with the passphrase in place.
dups="$(conf_duplicates "$CONFIG_FILE" "${SCRIPT_DIR}/backup.conf.example")"
if [[ -n "$dups" ]]; then
    section "Values set more than once"
    while IFS=$'\t' read -r name lline lval eline eval_ lost; do
        if [[ "$lost" == "1" ]]; then
            err "$name: your ${eval_} (line ${eline}) is overridden by the default ${lval} further down (line ${lline}) — ${lval} is used"
        else
            echo "  ${C_DIM}ℹ $name is set more than once; line ${lline} wins: ${lval}${C_RESET}"
        fi
    done <<< "$dups"
    grep -q $'\t1$' <<< "$dups" && echo "      💡 Delete the lower line (or keep one line per setting) in $CONFIG_FILE"
fi

# ==============================================================================
# 2. PERMISSIONS
# ==============================================================================
section "File permissions"

config_perms="$(stat -c '%a' "$CONFIG_FILE")"
if [[ "$config_perms" != "600" && "$config_perms" != "400" ]]; then
    warn "Permissions on $CONFIG_FILE: $config_perms (600 recommended — it holds secrets)"
    echo "    Fix: sudo chmod 600 $CONFIG_FILE"
else
    ok "$CONFIG_FILE: chmod $config_perms"
fi
# The config and the scripts run as root: whoever else can change them runs code as root. The config is an
# error; the scripts' folder a warning — a clone of a user's own, run with sudo, is theirs to judge.
for p in "$CONFIG_FILE" "$SCRIPT_DIR"; do
    st="$(stat -c '%u %a' "$p" 2>/dev/null)" || continue
    if [[ "${st% *}" != "$(id -u)" ]] || (( 8#${st#* } & 8#022 )); then
        msg="$p: owner uid ${st% *}, mode ${st#* }: someone besides root can change what runs as root. Fix: sudo chown -R root: $p; sudo chmod -R go-w $p"
        if [[ "$p" == "$CONFIG_FILE" ]]; then err "$msg"; else warn "$msg"; fi
    fi
done

for sh in "${SCRIPT_DIR}/docker-backup.sh" "${SCRIPT_DIR}/docker-restore.sh"; do
    if [[ -f "$sh" ]]; then
        if [[ -x "$sh" ]]; then
            ok "$(basename "$sh"): executable"
        else
            err "$(basename "$sh"): not executable. Fix: sudo chmod +x $sh"
        fi
        # CRLF check
        if file "$sh" 2>/dev/null | grep -q CRLF; then
            err "$(basename "$sh"): has Windows line endings (CRLF). Fix: sudo dos2unix $sh"
        fi
    else
        err "Not found: $sh"
    fi
done

# ==============================================================================
# 3. DEPENDENCIES
# ==============================================================================
section "Dependencies (binaries)"

declare -A DEPS=(
    [docker]="Docker Engine"
    [tar]="GNU tar"
    [gzip]="gzip"
    [aws]="AWS CLI"
    [jq]="jq"
    [flock]="util-linux (optional)"
    [curl]="curl"
)

for cmd in "${!DEPS[@]}"; do
    if command -v "$cmd" >/dev/null 2>&1; then
        path=$(command -v "$cmd")
        version=""
        case "$cmd" in
            docker) version=$(docker --version 2>&1 | head -1) ;;
            aws)    version=$(aws --version 2>&1 | head -1) ;;
            jq)     version=$(jq --version 2>&1) ;;
        esac
        ok "$cmd ($path) ${version:+— $version}"
    else
        err "$cmd is not installed (${DEPS[$cmd]})"
    fi
done

# Compose v2 (the docker CLI plugin): restore starts projects with it
if command -v docker >/dev/null 2>&1; then
    if docker compose version >/dev/null 2>&1; then
        ok "docker compose — $(docker compose version 2>&1 | head -1)"
    else
        err "docker compose (v2) is not installed — restore cannot start projects. Install the Docker Compose plugin"
    fi
fi

# AWS CLI must be v2
if command -v aws >/dev/null 2>&1; then
    aws_major=$(aws --version 2>&1 | sed -n 's#.*aws-cli/\([0-9][0-9]*\).*#\1#p' | head -1)
    aws_major="${aws_major:-0}"
    if [[ "$aws_major" -lt 2 ]]; then
        err "AWS CLI v$aws_major — v2 is required! Reinstall it: sudo $SCRIPT_DIR/install.sh"
    fi
else
    err "AWS CLI not found. Install v2: sudo $SCRIPT_DIR/install.sh"
fi

# GPG only if encryption is enabled
if [[ "${ENCRYPT_BACKUPS:-false}" == "true" ]]; then
    if command -v gpg >/dev/null 2>&1; then
        ok "gpg found (encryption enabled)"
        if gpg_pubkey; then
            # Public keys: each file holds a key that can encrypt and has not expired
            gpg_bad=false
            while IFS= read -r kf; do
                [[ -z "$kf" ]] && continue
                if [[ ! -r "$kf" ]]; then err "GPG_RECIPIENT_FILE: cannot read $kf"; gpg_bad=true; continue; fi
                kinfo="$(gpg --batch --with-colons --import-options show-only --import "$kf" 2>/dev/null)"
                kpub="$(awk -F: '$1 == "pub" { print $2 ":" $7 ":" $12; exit }' <<< "$kinfo")"
                kfpr="$(awk -F: '$1 == "fpr" { print $10; exit }' <<< "$kinfo")"
                kuid="$(awk -F: '$1 == "uid" { print $10; exit }' <<< "$kinfo")"
                if [[ -z "$kpub" ]]; then err "$kf is not an OpenPGP public key"; gpg_bad=true; continue; fi
                IFS=: read -r kval kexp kcap <<< "$kpub"
                if [[ "$kval" == e || ( -n "$kexp" && "$kexp" -lt "$(date +%s)" ) ]]; then
                    err "The key in $kf ($kfpr) has expired — new backups cannot be encrypted to it"; gpg_bad=true
                elif [[ "$kval" == r ]]; then
                    err "The key in $kf ($kfpr) is revoked"; gpg_bad=true
                elif [[ "$kcap" != *E* ]]; then
                    err "The key in $kf ($kfpr) has no encryption subkey"; gpg_bad=true
                else
                    ok "Public key: ${kuid:-?} (${kfpr: -16})$([[ -n "$kexp" ]] && echo ", expires $(date -u -d "@$kexp" +%Y-%m-%d)")"
                    [[ -n "$kexp" ]] && (( kexp - $(date +%s) < 30 * 86400 )) && warn "The key in $kf expires in less than 30 days: extend it, and give this host the updated public key"
                fi
            done < <(split_words "$GPG_RECIPIENT_FILE")
            if ! $gpg_bad; then
                gpg_tmp="$(mktemp -d)"
                echo "validate-config" > "$gpg_tmp/t"
                if gpg_out="$(gpg_enc -o "$gpg_tmp/t.gpg" "$gpg_tmp/t" 2>&1)"; then
                    ok "Test encryption to the public key works"
                    if gpg_can_decrypt; then
                        if gpg_dec -o "$gpg_tmp/t.out" "$gpg_tmp/t.gpg" >/dev/null 2>&1 && [[ "$(cat "$gpg_tmp/t.out" 2>/dev/null)" == "validate-config" ]]; then
                            ok "The secret key decrypts it (a full restore check is possible here)"
                        else
                            err "A secret key is set up here (${GPG_SECRET_KEY_FILE:-the root keyring}), but it does not decrypt: not the pair of GPG_RECIPIENT_FILE, or a passphrase is missing"
                        fi
                        echo "    The secret key is on this host: a break-in here exposes the backups. The host that makes them needs only the public key"
                    else
                        ok "This host cannot decrypt (no secret key here) — as intended; the restore check verifies the archives by sha256"
                    fi
                else
                    err "gpg cannot encrypt to the public key: $(printf '%s' "$gpg_out" | head -n 2 | tr '\n' ' ')"
                fi
                rm -rf "$gpg_tmp"
            fi
        elif [[ -f "${GPG_PASSPHRASE_FILE:-}" ]]; then
            pass_perms=$(stat -c '%a' "$GPG_PASSPHRASE_FILE")
            if [[ "$pass_perms" != "600" && "$pass_perms" != "400" ]]; then
                err "$GPG_PASSPHRASE_FILE: chmod $pass_perms — must be 600!"
            else
                ok "$GPG_PASSPHRASE_FILE: chmod $pass_perms"
            fi
            # A real round trip, the way the backup does it: gpg can be installed and still not work
            # (no gpg-agent with gnupg2-minimal, say)
            gpg_tmp="$(mktemp -d)"
            echo "validate-config" > "$gpg_tmp/t"
            if gpg_out="$(gpg_enc -o "$gpg_tmp/t.gpg" "$gpg_tmp/t" 2>&1 && gpg_dec -o "$gpg_tmp/t.out" "$gpg_tmp/t.gpg" 2>&1)" \
               && [[ "$(cat "$gpg_tmp/t.out" 2>/dev/null)" == "validate-config" ]]; then
                ok "Test encryption and decryption work"
            else
                err "gpg cannot encrypt here: $(printf '%s' "$gpg_out" | head -n 2 | tr '\n' ' ')"
                [[ "$gpg_out" == *gpg-agent* ]] && echo "      💡 Install the full gnupg (gpg-agent): e.g. dnf install --allowerasing gnupg2"
            fi
            rm -rf "$gpg_tmp"
        else
            err "GPG_PASSPHRASE_FILE does not exist: ${GPG_PASSPHRASE_FILE:-(not set)}"
        fi
    else
        err "ENCRYPT_BACKUPS=true, but gpg is not installed"
    fi
fi
if [[ "${ENCRYPT_BACKUPS:-false}" != "true" && -n "${GPG_RECIPIENT_FILE:-}" ]]; then
    warn "‼ ENCRYPTION IS OFF, but GPG_RECIPIENT_FILE is set: backups go to S3 unencrypted (ENCRYPT_BACKUPS=\"true\" to encrypt)"
elif [[ "${ENCRYPT_BACKUPS:-false}" != "true" && -f "${GPG_PASSPHRASE_FILE:-/root/.docker-backup-passphrase}" ]]; then
    warn "‼ ENCRYPTION IS OFF, but the passphrase file ${GPG_PASSPHRASE_FILE:-/root/.docker-backup-passphrase} exists"
    echo "      Backups go to S3 unencrypted. If that is not deliberate: ENCRYPT_BACKUPS=\"true\" in $CONFIG_FILE"
fi

# ==============================================================================
# 4. ACCESS TO THE STORAGES — the primary and every enabled copy
# ==============================================================================
# bucket_protection <role> — versioning and Object Lock of the current bucket (_aws_setup done), and whether
# the rotation can free space in it. Against ransomware: a key that leaks from this host can delete backups,
# but not the versions an Object Lock keeps.
#   In a versioned bucket a delete only adds a delete marker: the rotation and drop-project.sh hide old
#   backups, and the space is freed only by a lifecycle rule that expires noncurrent versions.
bucket_protection() {
    local role="$1" p="${1^^}_S3" b="$S3_CUR_BUCKET" out ver="" lock="" mode="" days="" lc="" rc
    out="$(aws_q s3api get-bucket-versioning --bucket "$b" --output json 2>&1)" && ver="$(jq -r '.Status // ""' <<< "$out" 2>/dev/null)"
    rc=0; out="$(aws_q s3api get-object-lock-configuration --bucket "$b" --output json 2>&1)" || rc=$?
    if (( rc == 0 )); then
        lock="$(jq -r '.ObjectLockConfiguration.ObjectLockEnabled // ""' <<< "$out" 2>/dev/null)"
        mode="$(jq -r '.ObjectLockConfiguration.Rule.DefaultRetention.Mode // ""' <<< "$out" 2>/dev/null)"
        days="$(jq -r '.ObjectLockConfiguration.Rule.DefaultRetention | if . == null then "" elif .Days then .Days elif .Years then .Years * 365 else "" end' <<< "$out" 2>/dev/null)"
    elif [[ "$out" != *ObjectLockConfigurationNotFound* ]]; then
        lock="?"
    fi
    rc=0; out="$(aws_q s3api get-bucket-lifecycle-configuration --bucket "$b" --output json 2>&1)" || rc=$?
    if (( rc == 0 )); then
        lc="$(jq -r '[.Rules[]? | select(.Status == "Enabled" and .NoncurrentVersionExpiration != null)
            | .NoncurrentVersionExpiration.NoncurrentDays] | first // ""' <<< "$out" 2>/dev/null)"
    elif [[ "$out" != *NoSuchLifecycleConfiguration* ]]; then
        lc="?"
    fi

    if [[ "$lock" == Enabled ]]; then
        if [[ -n "$mode" ]]; then
            ok "Object Lock: ${mode}, ${days} days by default — a leaked key cannot delete a backup younger than that"
            [[ "$mode" == GOVERNANCE ]] && echo "    (GOVERNANCE: a key with s3:BypassGovernanceRetention still can — give this host's key none)"
            if [[ "$(s3_var "$role" OBJECT_LOCK)" != "true" ]]; then
                err "${b} locks every new object, and such a bucket refuses an upload without a checksum: set ${p}_OBJECT_LOCK=\"true\""
            fi
            if [[ "$days" =~ ^[0-9]+$ ]] && (( days > ${RETENTION_DAYS:-30} )); then
                echo "    The lock (${days} d) outlasts RETENTION_DAYS (${RETENTION_DAYS:-30} d): backups older than that are hidden by the rotation, but kept — and paid for — until their lock ends"
            fi
        else
            ok "Object Lock is on, without a default retention: objects are not locked unless asked to"
            [[ "$(s3_var "$role" OBJECT_LOCK)" == "true" ]] || echo "    For locked uploads set a default retention on the bucket, and ${p}_OBJECT_LOCK=\"true\""
        fi
    elif [[ "$lock" == "?" ]]; then
        echo "    Object Lock: cannot read it with this key (s3:GetBucketObjectLockConfiguration) — not checked"
    elif [[ "$(s3_var "$role" OBJECT_LOCK)" == "true" ]]; then
        warn "${p}_OBJECT_LOCK=\"true\", but ${b} has no Object Lock: nothing protects the backups from a leaked key"
    fi

    if [[ "$ver" == Enabled || "$lock" == Enabled ]]; then
        if [[ "$lc" =~ ^[0-9]+$ ]]; then
            ok "Versioning on, and a lifecycle rule removes deleted backups after ${lc} more days"
        elif [[ "$lc" == "?" ]]; then
            echo "    Versioning is on; the lifecycle rules can't be read with this key — check that one expires noncurrent versions"
        else
            warn "Versioning is on, but no lifecycle rule expires noncurrent versions: the rotation only hides old backups, the storage keeps — and bills — them forever (README: Object Lock)"
        fi
    elif [[ "$ver" == Suspended ]]; then
        echo "    Versioning is suspended: versions made while it was on stay until a lifecycle rule removes them"
    fi
    return 0
}
for role in primary ${S3_COPIES[@]+"${S3_COPIES[@]}"}; do
    P="${role^^}_S3"
    section "Access: $(s3_label "$role")"
    if ! s3_complete "$role"; then
        err "Not all ${P}_* are filled in (keys, endpoint, bucket) — access cannot be checked"
        continue
    fi

    _aws_setup "$role"
    if aws_q s3 ls "s3://${S3_CUR_BUCKET}" >/dev/null 2>&1; then
        ok "Bucket ${S3_CUR_BUCKET} is reachable"

        # Write test
        test_key="${BACKUP_PREFIX}/.config-test-$(date +%s).tmp"
        if echo "test" | aws_q s3 cp - "s3://${S3_CUR_BUCKET}/${test_key}" >/dev/null 2>&1; then
            ok "Writing to the bucket works"
            aws_q s3 rm "s3://${S3_CUR_BUCKET}/${test_key}" >/dev/null 2>&1 \
                && ok "Deleting from the bucket works" \
                || err "Cannot delete the test file — check the key's permissions"
        else
            err "Cannot write to the bucket — check the key's permissions"
        fi
        bucket_protection "$role"
    else
        err "Cannot access bucket ${S3_CUR_BUCKET}"
        echo "    Check: the access key, that the bucket exists, endpoint ${S3_CUR_ENDPOINT}"
        cert_hint "${P}_OPTS_EXTRA" "$S3_CUR_BUCKET"
    fi

    # Read-only key, if set
    if [[ -n "$(s3_var "$role" RESTORE_ACCESS_KEY)" ]]; then
        _aws_setup "$role" read
        if aws_q s3 ls "s3://${S3_CUR_BUCKET}" >/dev/null 2>&1; then
            ok "The read-only restore key works (read)"
        else
            err "The read-only restore key (${P}_RESTORE_ACCESS_KEY) does not work"
        fi
    fi
done
_aws_setup primary

# ==============================================================================
# 5. DIRECTORIES
# ==============================================================================
section "Working directories"

_seen_dirs=""
for d in "$WORK_DIR" "$(dirname "$LOG_FILE")" "$(dirname "${LOCK_FILE:-/var/run/docker-backup.lock}")"; do
    # The log and the lock usually share a folder: one line for it
    [[ $'\n'"$_seen_dirs"$'\n' == *$'\n'"$d"$'\n'* ]] && continue
    _seen_dirs+="$d"$'\n'
    if [[ -d "$d" ]]; then
        if [[ -w "$d" ]]; then
            ok "$d (writable)"
        else
            err "$d is not writable"
        fi
    else
        warn "$d does not exist — it will be created on the first run"
    fi
done
if [[ -e "$WORK_DIR" || -L "$WORK_DIR" ]] && ! work_dir_ready; then err "$WORK_DIR_ERR"; fi

# Free space
if [[ -d "$WORK_DIR" ]]; then
    avail_mb=$(df --output=avail "$WORK_DIR" 2>/dev/null | tail -1 | tr -d ' ')
    avail_mb=$((avail_mb / 1024))
    if [[ "$avail_mb" -ge "${MIN_FREE_SPACE_MB:-1024}" ]]; then
        ok "Free in $WORK_DIR: ${avail_mb}MB (threshold ${MIN_FREE_SPACE_MB:-1024}MB)"
    else
        err "Free in $WORK_DIR: ${avail_mb}MB < ${MIN_FREE_SPACE_MB:-1024}MB threshold"
    fi
fi

# ==============================================================================
# 6. SCAN_DIRS
# ==============================================================================
section "Directories to look for projects in"

declare -a SCAN_DIR_LIST=()
mapfile -t SCAN_DIR_LIST < <(split_words "${SCAN_DIRS:-}")
for d in ${SCAN_DIR_LIST[@]+"${SCAN_DIR_LIST[@]}"}; do
    # A folder inside another one of the list is scanned twice — and usually meant as an exclusion
    for other in "${SCAN_DIR_LIST[@]}"; do
        if [[ "$other" != "$d" ]] && path_within "$d" "$other"; then
            warn "$d is inside $other, which is already scanned. SCAN_DIRS is where to LOOK for projects;"
            echo "      💡 to leave data out of the backup: BIND_BLACKLIST_REGEX (a whole bind mount, e.g. ...|^${d})"
            echo "         or BIND_EXCLUDE_PATHS='${d}' (a folder inside a bind mount)"
            break
        fi
    done
    if [[ -d "$d" ]]; then
        count=$(find "$d" -maxdepth 4 \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' -o -name 'compose.yml' -o -name 'compose.yaml' \) 2>/dev/null | wc -l)
        ok "$d (compose files found: $count)"
    else
        warn "$d does not exist"
    fi
done

# ==============================================================================
# 7. NOTIFICATIONS
# ==============================================================================
if notify_any || [[ -n "${TELEGRAM_BOT_TOKEN:-}" || -n "${EMAIL_TO:-}" || -n "${SMTP_HOST:-}" ]]; then
    section "Notifications"

    if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
        if ! [[ "$SLACK_WEBHOOK_URL" == https://hooks.slack.com/* ]]; then
            err "SLACK_WEBHOOK_URL must start with https://hooks.slack.com/ (for another receiver use NOTIFY_WEBHOOK_URL)"
        elif sl_err="$(notify_test slack 2>&1)"; then
            ok "Test message delivered to Slack"
        else
            err "Slack: $sl_err"
            case "$sl_err" in
                *"HTTP 403"*|*"HTTP 404"*|*"HTTP 410"*) echo "      💡 The webhook URL is wrong or was removed (or its channel archived) — add a new one in the Slack app" ;;
            esac
        fi
    fi

    if [[ -n "${TEAMS_WEBHOOK_URL:-}" ]]; then
        if ! [[ "$TEAMS_WEBHOOK_URL" == https://* ]]; then
            err "TEAMS_WEBHOOK_URL must start with https://"
        elif tm_err="$(notify_test teams 2>&1)"; then
            ok "Test message delivered to Teams"
        else
            err "Teams: $tm_err"
            case "$tm_err" in
                *"HTTP 400"*) echo "      💡 The workflow rejected the card: it must be \"Post to a channel when a webhook request is received\"" ;;
                *"HTTP 401"*|*"HTTP 403"*|*"HTTP 404"*) echo "      💡 The URL is wrong, or the workflow was turned off or deleted — copy its URL again" ;;
            esac
        fi
    fi

    if [[ -n "${PAGERDUTY_ROUTING_KEY:-}" ]]; then
        # Not a test incident: validate-config runs often, and an incident pages whoever is on call.
        # A change event checks the key and pages no one.
        if [[ "${PAGERDUTY_REGION:-us}" != us && "${PAGERDUTY_REGION:-us}" != eu ]]; then
            err "PAGERDUTY_REGION must be us or eu. Now: '${PAGERDUTY_REGION}'"
        else
            [[ "$PAGERDUTY_ROUTING_KEY" =~ ^[A-Za-z0-9]{32}$ ]] \
                || warn "PAGERDUTY_ROUTING_KEY has an unusual format (an Events API v2 integration key is 32 letters and digits)"
            if pd_err="$(pagerduty_check 2>&1)"; then
                ok "PagerDuty accepted a change event (${PAGERDUTY_REGION:-us}; it pages no one — see the service's Recent Changes)"
            else
                err "PagerDuty: $pd_err"
                case "$pd_err" in
                    *"HTTP 400"*) echo "      💡 The key is wrong: it is the Integration Key of an Events API V2 integration of the service" ;;
                    *"no response"*) echo "      💡 No answer from $(pagerduty_url enqueue | sed 's#^https://##; s#/.*##') — check outgoing HTTPS" ;;
                esac
            fi
            echo "    A test incident (resolved at once): sudo docker-backup-s3 → Notifications → PagerDuty"
        fi
    fi

    if [[ -n "${NTFY_URL:-}" ]]; then
        if ! [[ "$NTFY_URL" =~ ^https?://[^/]+/.*[^/]$ ]]; then
            err "NTFY_URL must be the topic's URL, like https://ntfy.sh/<topic>. Now: '$NTFY_URL'"
        elif nf_err="$(notify_test ntfy 2>&1)"; then
            ok "Test message delivered to ntfy (topic ${NTFY_URL##*/})"
        else
            err "ntfy: $nf_err"
            case "$nf_err" in
                *"HTTP 401"*|*"HTTP 403"*) echo "      💡 The topic is protected: set NTFY_TOKEN to an access token that may publish to it" ;;
                *"HTTP 429"*) echo "      💡 The server limits how often you publish — try again later" ;;
            esac
        fi
    fi

    if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
        # Token format check
        if ! [[ "$TELEGRAM_BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
            warn "TELEGRAM_BOT_TOKEN has an unusual format (expected '123:ABC...')"
        fi

        if [[ -z "${TELEGRAM_CHAT_ID:-}" ]]; then
            err "TELEGRAM_BOT_TOKEN is set, but TELEGRAM_CHAT_ID is empty"
        elif ! [[ "$TELEGRAM_CHAT_ID" =~ ^-?[0-9]+$ ]]; then
            err "TELEGRAM_CHAT_ID must be a number (negative for groups). Now: '$TELEGRAM_CHAT_ID'"
        else
            # 1) Test the token via getMe
            response=$(curl -s -m 10 -K <(curl_url_cfg "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe") 2>/dev/null || echo "")
            if echo "$response" | grep -q '"ok":true'; then
                bot_name=$(echo "$response" | jq -r '.result.username' 2>/dev/null || echo "?")
                ok "Telegram bot is valid: @$bot_name"

                # 2) A test message — the same one, in the same look, as every other notification
                if err_msg="$(notify_test telegram 2>&1)"; then
                    ok "Test message delivered to Telegram (chat_id: $TELEGRAM_CHAT_ID)"
                else
                    err "Cannot send to Telegram chat_id=$TELEGRAM_CHAT_ID: $err_msg"

                    case "$err_msg" in
                        *"chat not found"*)
                            echo "      💡 Possible reasons:"
                            echo "         • the chat_id is wrong — check it via @userinfobot"
                            echo "         • you haven't messaged the bot first — open @$bot_name → /start"
                            ;;
                        *"bot was blocked"*|*"Forbidden"*)
                            echo "      💡 The bot is blocked by the user — unblock it in Telegram"
                            ;;
                        *"bot is not a member"*)
                            echo "      💡 For groups: add the bot to the group as an admin"
                            ;;
                    esac
                fi
            else
                err_msg=$(echo "$response" | sed -n 's/.*"description":"\([^"]*\)".*/\1/p' || echo "no response")
                err "The Telegram bot token is invalid: $err_msg"
            fi
        fi
    fi

    if [[ -n "${NOTIFY_WEBHOOK_URL:-}" ]]; then
        if ! [[ "$NOTIFY_WEBHOOK_URL" =~ ^https?:// ]]; then
            err "NOTIFY_WEBHOOK_URL must start with http:// or https://"
        elif ! command -v curl >/dev/null 2>&1; then
            err "curl is not installed — the webhook can't be sent"
        elif wh_err="$(notify_test webhook 2>&1)"; then
            ok "Test message delivered to the webhook (format: $(webhook_format))"
        else
            err "Webhook (format: $(webhook_format)): $wh_err"
            case "$wh_err" in
                *"HTTP 400"*) echo "      💡 The receiver rejected the payload — check NOTIFY_WEBHOOK_FORMAT (discord / slack / json)" ;;
                *"HTTP 401"*|*"HTTP 403"*|*"HTTP 404"*) echo "      💡 The URL or its token is wrong, or the webhook was deleted" ;;
            esac
        fi
    fi

    if [[ -n "${EMAIL_TO:-}" || -n "${SMTP_HOST:-}" ]]; then
        if [[ -z "${EMAIL_TO:-}" ]]; then
            err "SMTP_HOST is set, but EMAIL_TO is empty"
        elif [[ -z "${SMTP_HOST:-}" ]]; then
            err "EMAIL_TO is set, but SMTP_HOST is empty"
        elif ! curl -V 2>/dev/null | grep -qw smtp; then
            err "This curl can't send mail (no smtp in 'curl -V')"
        else
            [[ "${SMTP_SECURITY:-starttls}" == "none" && -n "${SMTP_USER:-}" ]] \
                && warn "SMTP_SECURITY=none: the SMTP password goes over the network unencrypted"
            if mail_err="$(notify_test email 2>&1)"; then
                ok "Test email sent to ${EMAIL_TO} via ${SMTP_HOST} — check the inbox (and spam)"
            else
                err "Email via ${SMTP_HOST}: $mail_err"
                case "$mail_err" in
                    *"Login denied"*|*"535"*) echo "      💡 SMTP_USER / SMTP_PASSWORD are wrong (some providers need an app password)" ;;
                    *"Could not connect"*|*"Connection timed out"*|*"Failed to connect"*)
                        echo "      💡 The port is closed: check SMTP_SECURITY/SMTP_PORT; many hosting providers block outgoing 25" ;;
                    *"SSL"*|*"certificate"*) echo "      💡 TLS failed: tls is for port 465, starttls for 587" ;;
                esac
            fi
        fi
    fi

    if [[ -n "${APPRISE_URLS:-}" ]]; then
        if ! command -v apprise >/dev/null 2>&1; then
            err "APPRISE_URLS is set, but apprise is not installed (pip install apprise, or the distribution's package)"
        elif ap_err="$(notify_test apprise 2>&1)"; then
            ok "Test message sent through apprise ($(split_words "$APPRISE_URLS" | grep -c .) URL(s))"
        else
            err "Apprise: $ap_err"
        fi
    fi
fi

# ==============================================================================
# 7b. MONITORING: the monitor's ping, Prometheus metrics
# ==============================================================================
if [[ -n "${HEARTBEAT_URL:-}${VERIFY_HEARTBEAT_URL:-}${METRICS_DIR:-}" ]]; then
    section "Monitoring"
    for hb_var in HEARTBEAT_URL VERIFY_HEARTBEAT_URL; do
        HB_URL="${!hb_var:-}"
        [[ -z "$HB_URL" ]] && continue
        if ! [[ "$HB_URL" =~ ^https?:// ]]; then
            err "$hb_var must start with http:// or https://"; continue
        fi
        hb_fmt="$(heartbeat_format)"
        case "$hb_fmt" in
            healthchecks)
                # /log records the ping without changing the check's state: a "success" from here would
                # reset the monitor's timer while no backup ran
                hb_code="$(printf 'docker-backup-s3: configuration check' | curl -s -m 10 -o /dev/null -w '%{http_code}' \
                    -X POST --data-binary @- -K <(curl_url_cfg "${HB_URL%%\?*}/log") 2>/dev/null)" || true
                case "$hb_code" in
                    2??) ok "$hb_var: the monitor answered (a /log ping — its state is unchanged)" ;;
                    404) warn "$hb_var: the service has no /log — reachable, but not checked without changing its state" ;;
                    ""|000) err "$hb_var: no response from $(s3_host "$HB_URL")" ;;
                    *) err "$hb_var: the monitor replied HTTP $hb_code — check the URL" ;;
                esac ;;
            kuma) ok "$hb_var: an Uptime Kuma push URL (not pinged from here: it would mark the monitor up)" ;;
            *) err "HEARTBEAT_FORMAT must be auto, healthchecks or kuma. Now: '${HEARTBEAT_FORMAT}'" ;;
        esac
    done
    HB_URL=""
    if [[ -n "${METRICS_DIR:-}" ]]; then
        if [[ ! -d "$METRICS_DIR" ]]; then err "METRICS_DIR does not exist: $METRICS_DIR (node_exporter's --collector.textfile.directory)"
        elif [[ ! -w "$METRICS_DIR" ]]; then err "METRICS_DIR is not writable: $METRICS_DIR"
        else ok "METRICS_DIR: $METRICS_DIR (docker_backup_s3.prom, docker_backup_s3_verify.prom)"; fi
    fi
fi

# ==============================================================================
# 8. CRON
# ==============================================================================
section "Cron"

if crontab -l 2>/dev/null | grep -q "docker-backup.sh"; then
    cron_line=$(crontab -l 2>/dev/null | grep "docker-backup.sh" | head -1)
    ok "Cron job configured: $cron_line"

    # Which aws cron will find: it has its own trimmed PATH (the PATH= line in the crontab)
    cron_path="$(crontab -l 2>/dev/null | sed -n 's/^PATH=//p' | tail -1)"
    if [[ -z "$cron_path" ]]; then
        warn "No PATH= line in the crontab — cron only looks in /usr/bin:/bin, aws may not be found"
        echo "    Recreate the job: sudo $SCRIPT_DIR/setup-cron.sh"
    elif cron_aws="$(PATH="$cron_path" command -v aws 2>/dev/null)"; then
        ok "aws for cron: $cron_aws"
        if [[ "$cron_aws" == /snap/* ]]; then
            warn "cron uses aws from snap — it updates itself, and such updates have broken uploads before"
            echo "    Install the official aws (sudo $SCRIPT_DIR/install.sh) and recreate the job (setup-cron.sh)"
        fi
    else
        err "With the PATH from the crontab ($cron_path) aws is not found"
        echo "    Recreate the job: sudo $SCRIPT_DIR/setup-cron.sh"
    fi
else
    warn "No cron job configured. See the README section 'Scheduled runs (cron/systemd)'"
fi

# ==============================================================================
# 8. REMOTE DATABASES — the settings, then a login with them (the client image is pulled if missing)
# ==============================================================================
if [[ -n "$(remote_db_names)" ]]; then
    section "Remote databases"
    declare -A _rdb_keys=()
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        k="$(remote_db_key "$n")"
        if [[ -n "${_rdb_keys[$k]:-}" ]]; then
            err "REMOTE_DBS: $n and ${_rdb_keys[$k]} share the settings REMOTE_DB_${k}_* — give one another name"
            continue
        fi
        _rdb_keys[$k]="$n"
        if ! problems="$(remote_db_check "$n")"; then
            while IFS= read -r p; do err "$n: $p"; done <<< "$problems"
            continue
        fi
        pw="$(remote_db_password "$n")"
        if [[ -n "$pw" ]]; then ok "$n: $(remote_db_desc "$n"), password set (${#pw} characters, not shown)"
        else ok "$n: $(remote_db_desc "$n"), no password"; fi
        if answer="$(remote_db_probe "$n" 2>&1)"; then ok "$n: logged in — $answer"
        else err "$n: cannot log in — $(tr '\n' ' ' <<< "$answer")"; fi
    done < <(remote_db_names)
fi

# ==============================================================================
# SUMMARY
# ==============================================================================
echo
echo "${C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
if [[ "$ERRORS" -eq 0 ]]; then
    if [[ "$WARNINGS" -eq 0 ]]; then
        echo "${C_GREEN}${C_BOLD}✅ All good. docker-backup.sh is ready to run${C_RESET}"
    else
        echo "${C_YELLOW}${C_BOLD}⚠  ${WARNINGS} warning(s), but no critical errors${C_RESET}"
    fi
    echo "${C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    exit 0
else
    echo "${C_RED}${C_BOLD}❌ ${ERRORS} error(s) and ${WARNINGS} warning(s)${C_RESET}"
    echo "    Fix the errors before running a backup."
    echo "${C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    exit 1
fi
