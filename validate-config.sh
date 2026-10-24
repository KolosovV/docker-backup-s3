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
# Old names (S3_BUCKET etc., from older versions) work, but update.sh renames them
if grep -qE '^S3_(ACCESS_KEY|SECRET_KEY|ENDPOINT|BUCKET)=' "$CONFIG_FILE"; then
    section "Configuration — old names"
    warn "backup.conf names the primary storage the old way (S3_ACCESS_KEY, S3_BUCKET…)."
    echo "    It works, but better rename to PRIMARY_S3_*: sudo $SCRIPT_DIR/update.sh --migrate-conf"
fi

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
        if [[ -f "${GPG_PASSPHRASE_FILE:-}" ]]; then
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
            if gpg_out="$(gpg --batch --yes --quiet --passphrase-file "$GPG_PASSPHRASE_FILE" --symmetric --cipher-algo AES256 \
                    -o "$gpg_tmp/t.gpg" "$gpg_tmp/t" 2>&1 \
                 && gpg --batch --yes --quiet --passphrase-file "$GPG_PASSPHRASE_FILE" -d -o "$gpg_tmp/t.out" "$gpg_tmp/t.gpg" 2>&1)" \
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
if [[ "${ENCRYPT_BACKUPS:-false}" != "true" && -f "${GPG_PASSPHRASE_FILE:-/root/.docker-backup-passphrase}" ]]; then
    warn "‼ ENCRYPTION IS OFF, but the passphrase file ${GPG_PASSPHRASE_FILE:-/root/.docker-backup-passphrase} exists"
    echo "      Backups go to S3 unencrypted. If that is not deliberate: ENCRYPT_BACKUPS=\"true\" in $CONFIG_FILE"
fi

# ==============================================================================
# 4. ACCESS TO THE STORAGES — the primary and every enabled copy
# ==============================================================================
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
if [[ -n "${TELEGRAM_BOT_TOKEN:-}" || -n "${NOTIFY_WEBHOOK_URL:-}" || -n "${EMAIL_TO:-}" || -n "${SMTP_HOST:-}" ]]; then
    section "Notifications"

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
