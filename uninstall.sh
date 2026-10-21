#!/usr/bin/env bash
# ==============================================================================
# uninstall.sh
# Clean removal of Docker Backup System.
#
# What is removed:
#   ✓ Files in /opt/docker-backup-s3/ (or the given --target)
#   ✓ the cron job (if any)
#   ✓ the systemd timer and service (if any)
#   ✓ logrotate config
#   ✓ the docker-backup command link
#   ✓ the lock directory (/var/run/docker-backup.lock.d)
#   ✓ the temporary folder (/var/tmp/docker-backup)
#
# What is NOT removed automatically:
#   ✗ Backups in S3 (never!) — only with the explicit --purge-s3 flag
#   ✗ Logs (/var/log/docker-backup*.log) — a separate question
#   ✗ The GPG passphrase file (/root/.docker-backup-passphrase)
#   ✗ System dependencies (docker, aws-cli, jq, ...)
#   ✗ pre-backup-hook.sh in project folders
#   ✗ db-dumps/ in project folders
#
# Usage:
#   sudo ./uninstall.sh                    # interactive
#   sudo ./uninstall.sh -y                 # no questions, remove everything except logs and S3
#   sudo ./uninstall.sh -y --purge-logs    # + remove the logs
#   sudo ./uninstall.sh --target /opt/docker-backup-s3
#   sudo ./uninstall.sh --dry-run          # show what would be removed, do nothing
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

# --- Arguments ---
TARGET_DIR="/opt/docker-backup-s3"
NON_INTERACTIVE="false"
PURGE_LOGS="false"
PURGE_S3="false"
DRY_RUN="false"
KEEP_CONF="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--target)      TARGET_DIR="$2"; shift 2 ;;
        -y|--yes)         NON_INTERACTIVE="true"; shift ;;
        -n|--dry-run)     DRY_RUN="true"; shift ;;
        --purge-logs)     PURGE_LOGS="true"; shift ;;
        --purge-s3)       PURGE_S3="true"; shift ;;
        --keep-conf)      KEEP_CONF="true"; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [options]

Removes Docker Backup System.

  -t, --target DIR     what to remove (default: /opt/docker-backup-s3)
  -y, --yes            no confirmations (remove everything except logs and S3)
  -n, --dry-run        show what would be removed, do nothing
      --purge-logs     also remove /var/log/docker-backup*.log
      --purge-s3       ⚠️  DELETE ALL BACKUPS IN S3 — primary + every copy
                       (requires explicit confirmation)
      --keep-conf      keep backup.conf after removal (for a reinstall)
  -h, --help           this help

NOT REMOVED automatically:
  • System dependencies (docker, aws-cli, jq, gpg, ...)
  • GPG passphrase (/root/.docker-backup-passphrase)
  • pre-backup-hook.sh in compose project folders
  • db-dumps/ inside project folders

Backups in S3 are NOT DELETED unless --purge-s3 is given explicitly.

EXAMPLES:
  Safely remove the installation:        sudo $0
  Quiet mode, keep logs and S3:          sudo $0 -y
  Full cleanup except S3:                sudo $0 -y --purge-logs
  See what would be removed:             sudo $0 --dry-run
  ⚠ FULL CLEANUP (including S3):         sudo $0 --purge-s3 --purge-logs
EOF
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# --- Root check ---
if [[ "$EUID" -ne 0 && "$DRY_RUN" != "true" ]]; then
    echo "❌ The script must be run as root: sudo $0" >&2
    exit 1
fi

# --- Colors ---
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

log()      { echo "${C_DIM}[$(date '+%H:%M:%S')]${C_RESET} $*"; }
log_step() { echo; echo "${C_BOLD}${C_CYAN}━━━ $* ━━━${C_RESET}"; }
log_ok()   { echo "  ${C_GREEN}✓${C_RESET} $*"; }
log_skip() { echo "  ${C_DIM}○ $*${C_RESET}"; }
log_warn() { echo "  ${C_YELLOW}⚠${C_RESET} $*"; }
log_err()  { echo "  ${C_RED}✗ $*${C_RESET}"; }
log_dry()  { echo "  ${C_BLUE}[DRY]${C_RESET} ${C_DIM}$*${C_RESET}"; }
fail()     { log_err "$*"; exit 1; }

# Storages for the report — without lib.sh (it is sourced only for deleting from S3)
COPY_ROLES=()
_store_name() {
    case "$1" in
        primary) printf 'Primary' ;; secondary) printf 'Secondary' ;; tertiary) printf 'Tertiary' ;; *) printf '%s' "$1" ;;
    esac
}
_store_var() { local n="${1^^}_S3_$2"; printf '%s' "${!n:-?}"; }

ask_yn() {
    local prompt="$1" default="${2:-n}"
    local hint
    [[ "$default" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        [[ "$default" == "y" ]] && return 0 || return 1
    fi
    local ans
    read -rp "$prompt $hint: " ans </dev/tty
    ans="${ans:-$default}"
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

# Helper that runs an action with dry-run support
do_action() {
    local description="$1"; shift
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "$description"
    else
        if "$@" 2>/dev/null; then
            log_ok "$description"
        else
            log_err "$description (error)"
        fi
    fi
}

# ==============================================================================
# BANNER AND PRELIMINARY REPORT
# ==============================================================================
clear 2>/dev/null || true
cat <<EOF
${C_BOLD}${C_BLUE}╔═══════════════════════════════════════════════════════════════╗
║   Docker Backup System — Uninstaller                          ║
╚═══════════════════════════════════════════════════════════════╝${C_RESET}

EOF

[[ "$DRY_RUN" == "true" ]] && {
    echo "${C_YELLOW}${C_BOLD}🧪 DRY-RUN: nothing will actually be removed${C_RESET}"
    echo
}

# ==============================================================================
# 1. RECONNAISSANCE — what is installed at all
# ==============================================================================
log_step "What was found on the system"

FOUND_TARGET="false"
FOUND_CRON="false"
FOUND_SYSTEMD="false"
FOUND_LOGROTATE="false"
FOUND_CMD="false"
FOUND_LOGS="false"
FOUND_LOCK="false"
FOUND_WORK_DIR="false"

# Installation files
if [[ -d "$TARGET_DIR" ]]; then
    FOUND_TARGET="true"
    file_count=$(find "$TARGET_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l)
    log_ok "Installation: $TARGET_DIR ($file_count files)"
else
    log_skip "Directory $TARGET_DIR not found"
fi

# Cron
if crontab -l 2>/dev/null | grep -qE 'docker-backup\.sh|/docker-backup'; then
    FOUND_CRON="true"
    cron_line=$(crontab -l 2>/dev/null | grep -E 'docker-backup\.sh|/docker-backup' | head -1)
    log_ok "Cron job: $cron_line"
else
    log_skip "No cron job found"
fi

# Systemd
if systemctl list-unit-files 2>/dev/null | grep -q "docker-backup.timer"; then
    FOUND_SYSTEMD="true"
    timer_state=$(systemctl is-active docker-backup.timer 2>/dev/null || echo "unknown")
    log_ok "Systemd timer: docker-backup.timer ($timer_state)"
else
    log_skip "No systemd timer found"
fi

# Logrotate
if [[ -f /etc/logrotate.d/docker-backup ]]; then
    FOUND_LOGROTATE="true"
    log_ok "Logrotate: /etc/logrotate.d/docker-backup"
else
    log_skip "No logrotate config found"
fi

# The docker-backup command — only our symlink into this installation
if [[ -L /usr/local/bin/docker-backup && "$(readlink /usr/local/bin/docker-backup)" == "$TARGET_DIR/menu.sh" ]]; then
    FOUND_CMD="true"
    log_ok "Command: /usr/local/bin/docker-backup → $TARGET_DIR/menu.sh"
else
    log_skip "No docker-backup command link found"
fi

# Logs
log_files=()
[[ -f /var/log/docker-backup.log ]] && log_files+=(/var/log/docker-backup.log)
[[ -f /var/log/docker-backup-cron.log ]] && log_files+=(/var/log/docker-backup-cron.log)
# Rotated ones too
shopt -s nullglob
for f in /var/log/docker-backup*.log.* /var/log/docker-backup*.gz; do
    [[ -f "$f" ]] && log_files+=("$f")
done
shopt -u nullglob

if [[ ${#log_files[@]} -gt 0 ]]; then
    FOUND_LOGS="true"
    log_size=$(du -ch "${log_files[@]}" 2>/dev/null | tail -1 | awk '{print $1}')
    log_ok "Logs: ${#log_files[@]} file(s), $log_size in total"
else
    log_skip "No logs found"
fi

# Lock — an atomic .d directory with the PID inside
LOCK_DIR="/var/run/docker-backup.lock.d"
if [[ -d "$LOCK_DIR" ]]; then
    FOUND_LOCK="true"
    lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")

    if [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
        log_warn "The lock is active — A BACKUP IS RUNNING NOW (PID: $lock_pid)"
        log_warn "  Wait for it to finish or kill $lock_pid before removing"
    else
        log_ok "Lock (stale, PID $lock_pid): $LOCK_DIR"
    fi
else
    log_skip "No lock found"
fi

# Work dir
if [[ -d /var/tmp/docker-backup ]]; then
    FOUND_WORK_DIR="true"
    wd_size=$(du -sh /var/tmp/docker-backup 2>/dev/null | awk '{print $1}')
    log_ok "Temporary folder: /var/tmp/docker-backup ($wd_size)"
else
    log_skip "No temporary folder found"
fi

# Nothing found — exit
if [[ "$FOUND_TARGET" == "false" && "$FOUND_CRON" == "false" && \
      "$FOUND_SYSTEMD" == "false" && "$FOUND_LOGROTATE" == "false" && \
      "$FOUND_CMD" == "false" && "$FOUND_LOGS" == "false" && \
      "$FOUND_LOCK" == "false" && "$FOUND_WORK_DIR" == "false" ]]; then
    echo
    log "${C_GREEN}Docker Backup System does not seem to be installed. Nothing to remove.${C_RESET}"
    exit 0
fi

# ==============================================================================
# 2. PROTECTION AGAINST REMOVAL DURING A BACKUP
# ==============================================================================
if [[ -d "$LOCK_DIR" ]]; then
    lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
    if [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
        echo
        log_err "A backup is running right now (PID: $lock_pid)"
        log "  Wait for it to finish or: sudo kill $lock_pid"
        if ! ask_yn "Continue the removal anyway (RISKY)?" "n"; then
            log "Cancelled."
            exit 0
        fi
    fi
fi

# ==============================================================================
# 3. ABOUT S3 — what is definitely NOT TOUCHED
# ==============================================================================
if [[ -f "$TARGET_DIR/backup.conf" ]]; then
    # Source it for an informative report
    # shellcheck disable=SC1090,SC1091
    source "$TARGET_DIR/backup.conf" 2>/dev/null || true

    # An old backup.conf (from older versions) calls the primary storage plain S3_*
    : "${PRIMARY_S3_BUCKET:=${S3_BUCKET:-}}"
    : "${PRIMARY_S3_ENDPOINT:=${S3_ENDPOINT:-}}"

    # A copy counts as "configured" if its bucket/keys/endpoint are set — regardless
    # of <ROLE>_S3_ENABLED: copies may remain even after the duplicate was turned off,
    # and --purge-s3 must remove them too. COPY_ROLES — such roles, in order.
    COPY_ROLES=()
    for _role in secondary tertiary; do
        _p="${_role^^}_S3"; _b="${_p}_BUCKET"; _k="${_p}_ACCESS_KEY"; _s="${_p}_SECRET_KEY"; _e="${_p}_ENDPOINT"
        [[ -n "${!_b:-}" && -n "${!_k:-}" && -n "${!_s:-}" && -n "${!_e:-}" ]] && COPY_ROLES+=("$_role")
    done

    log_step "Backups in S3"

    if [[ "$PURGE_S3" == "true" ]]; then
        log "${C_RED}${C_BOLD}⚠️  --purge-s3 given — ALL BACKUPS WILL BE DELETED${C_RESET}"
        log "    $(_store_name primary):  s3://${PRIMARY_S3_BUCKET:-?}/${BACKUP_PREFIX:-?}/  (${PRIMARY_S3_ENDPOINT:-?})"
        for _role in ${COPY_ROLES[@]+"${COPY_ROLES[@]}"}; do
            log "${C_RED}    $(_store_name "$_role"): s3://$(_store_var "$_role" BUCKET)/${BACKUP_PREFIX:-?}/  ($(_store_var "$_role" ENDPOINT))${C_RESET}"
        done
        (( ${#COPY_ROLES[@]} > 0 )) && log "${C_RED}    ALL these storages are wiped.${C_RESET}"
    else
        log "${C_GREEN}✓ Backups will be KEPT:${C_RESET}"
        log "    $(_store_name primary):  s3://${PRIMARY_S3_BUCKET:-?}/${BACKUP_PREFIX:-?}/"
        for _role in ${COPY_ROLES[@]+"${COPY_ROLES[@]}"}; do
            log "    $(_store_name "$_role"): s3://$(_store_var "$_role" BUCKET)/${BACKUP_PREFIX:-?}/"
        done
        log "    To delete them — run with --purge-s3 (requires explicit confirmation)"
    fi
fi

# ==============================================================================
# 4. CONFIRMATION
# ==============================================================================
echo
log_step "Removal plan"

[[ "$FOUND_TARGET" == "true" ]]    && echo "  • Files: $TARGET_DIR/$([[ "$KEEP_CONF" == "true" ]] && echo "*.sh (backup.conf is kept)" || echo "*")"
[[ "$FOUND_CRON" == "true" ]]      && echo "  • Cron job"
[[ "$FOUND_SYSTEMD" == "true" ]]   && echo "  • Systemd timer + service"
[[ "$FOUND_LOGROTATE" == "true" ]] && echo "  • /etc/logrotate.d/docker-backup"
[[ "$FOUND_CMD" == "true" ]]       && echo "  • /usr/local/bin/docker-backup (the command link)"
[[ "$FOUND_LOCK" == "true" ]]      && echo "  • $LOCK_DIR"
[[ "$FOUND_WORK_DIR" == "true" ]]  && echo "  • /var/tmp/docker-backup"

if [[ "$FOUND_LOGS" == "true" ]]; then
    if [[ "$PURGE_LOGS" == "true" ]]; then
        echo "  • ${C_YELLOW}Logs (--purge-logs)${C_RESET}: ${#log_files[@]} files"
    else
        echo "  • ${C_DIM}Logs are KEPT${C_RESET} (use --purge-logs to remove them)"
    fi
fi

if [[ "$PURGE_S3" == "true" ]]; then
    if (( ${#COPY_ROLES[@]} > 0 )); then
        echo "  • ${C_RED}${C_BOLD}ALL BACKUPS IN S3 (primary + copies: $(IFS=' '; printf '%s' "${COPY_ROLES[*]}"))${C_RESET}"
    else
        echo "  • ${C_RED}${C_BOLD}ALL BACKUPS IN THE PRIMARY S3${C_RESET}"
    fi
fi

echo
echo "${C_DIM}NOT removed: system dependencies, the GPG passphrase, pre-backup hooks, db-dumps in projects${C_RESET}"
echo

if [[ "$DRY_RUN" != "true" ]]; then
    if ! ask_yn "Continue the removal?" "y"; then
        log "Cancelled."
        exit 0
    fi

    # Extra confirmation for S3
    if [[ "$PURGE_S3" == "true" ]]; then
        echo
        if (( ${#COPY_ROLES[@]} > 0 )); then
            echo "${C_RED}${C_BOLD}⚠️  WARNING: --purge-s3 will delete ALL backups from ALL storages, irreversibly!${C_RESET}"
            echo "${C_RED}    $(_store_name primary):  s3://${PRIMARY_S3_BUCKET:-?}/${BACKUP_PREFIX:-?}/${C_RESET}"
            for _role in "${COPY_ROLES[@]}"; do
                echo "${C_RED}    $(_store_name "$_role"): s3://$(_store_var "$_role" BUCKET)/${BACKUP_PREFIX:-?}/${C_RESET}"
            done
        else
            echo "${C_RED}${C_BOLD}⚠️  WARNING: --purge-s3 will delete ALL backups from the PRIMARY S3, irreversibly!${C_RESET}"
        fi
        echo "${C_RED}This cannot be undone. S3 usually has no recycle bin.${C_RESET}"
        echo
        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            read -rp "Type 'DELETE ALL BACKUPS' to confirm: " confirm </dev/tty
            if [[ "$confirm" != "DELETE ALL BACKUPS" ]]; then
                log "No confirmation received — S3 is left alone"
                PURGE_S3="false"
            fi
        fi
    fi
fi

# ==============================================================================
# 5. REMOVAL — CRON
# ==============================================================================
if [[ "$FOUND_CRON" == "true" ]]; then
    log_step "Removing the cron job"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "crontab without the docker-backup lines"
    else
        # Remove the lines + our markers (if it was installed via setup-cron.sh). Through a variable
        # with "|| true": when nothing else is left, grep -v exits 1 and the pipe would report a failure.
        cron_rest="$(crontab -l 2>/dev/null | grep -vE 'docker-backup\.sh|/docker-backup' \
            | sed '/^# === Docker backup ===/,/^# === \/Docker backup ===/d' || true)"
        if printf '%s\n' "$cron_rest" | crontab - 2>/dev/null; then
            log_ok "Cron job removed"
        else
            log_err "Could not update the crontab"
        fi
    fi
fi

# ==============================================================================
# 6. REMOVAL — SYSTEMD
# ==============================================================================
if [[ "$FOUND_SYSTEMD" == "true" ]]; then
    log_step "Removing the systemd timer"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "systemctl disable --now docker-backup.timer"
        log_dry "rm /etc/systemd/system/docker-backup.{service,timer}"
        log_dry "systemctl daemon-reload"
    else
        systemctl disable --now docker-backup.timer 2>/dev/null && \
            log_ok "Timer stopped and disabled" || log_warn "The timer was not active"

        rm -f /etc/systemd/system/docker-backup.timer && log_ok "Removed docker-backup.timer"
        rm -f /etc/systemd/system/docker-backup.service && log_ok "Removed docker-backup.service"
        systemctl daemon-reload 2>/dev/null && log_ok "systemctl daemon-reload"
    fi
fi

# ==============================================================================
# 7. REMOVAL — LOGROTATE
# ==============================================================================
if [[ "$FOUND_LOGROTATE" == "true" ]]; then
    log_step "Removing logrotate"
    do_action "rm /etc/logrotate.d/docker-backup" rm -f /etc/logrotate.d/docker-backup
fi

# ==============================================================================
# 8. REMOVAL — THE docker-backup COMMAND
# ==============================================================================
if [[ "$FOUND_CMD" == "true" ]]; then
    log_step "Removing the docker-backup command"
    do_action "rm /usr/local/bin/docker-backup" rm -f /usr/local/bin/docker-backup
fi

# ==============================================================================
# 9. REMOVAL — LOCK + WORK DIR
# ==============================================================================
if [[ "$FOUND_LOCK" == "true" ]]; then
    log_step "Removing the lock"
    do_action "rm -rf $LOCK_DIR" rm -rf "$LOCK_DIR"
fi

if [[ "$FOUND_WORK_DIR" == "true" ]]; then
    log_step "Removing the temporary folder"
    do_action "rm -rf /var/tmp/docker-backup" rm -rf /var/tmp/docker-backup
fi

# ==============================================================================
# 10. REMOVAL — BACKUPS IN S3 (only with --purge-s3)
#     Wipes ALL storages: the primary and every configured copy.
# ==============================================================================
if [[ "$PURGE_S3" == "true" && -f "$TARGET_DIR/backup.conf" ]]; then
    log_step "${C_RED}${C_BOLD}Deleting backups in S3${C_RESET}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "aws s3 rm s3://${PRIMARY_S3_BUCKET}/${BACKUP_PREFIX}/ --recursive  ($(_store_name primary))"
        for _role in ${COPY_ROLES[@]+"${COPY_ROLES[@]}"}; do
            log_dry "aws --endpoint-url $(_store_var "$_role" ENDPOINT) s3 rm s3://$(_store_var "$_role" BUCKET)/${BACKUP_PREFIX}/ --recursive  ($(_store_name "$_role"))"
        done
    elif [[ -f "$TARGET_DIR/lib.sh" ]]; then
        # shellcheck disable=SC1091
        source "$TARGET_DIR/lib.sh"

        # Deleting from one storage: $1 = role
        _purge_store() {
            local role="$1" prep
            prep="$(s3_label "$role" in)"
            _aws_setup "$role" 2>/dev/null || true
            log "  Deleting ${prep}: s3://${S3_CUR_BUCKET}/${BACKUP_PREFIX}/"
            if aws_q s3 rm "s3://${S3_CUR_BUCKET}/${BACKUP_PREFIX}/" --recursive 2>&1 | tail -20; then
                log_ok "Backups ${prep} deleted"
            else
                log_err "Error deleting $(s3_label "$role" from) (continuing with the rest)"
            fi
        }

        for _role in primary ${COPY_ROLES[@]+"${COPY_ROLES[@]}"}; do
            _purge_store "$_role"
        done
        _aws_setup primary 2>/dev/null || true
    else
        log_warn "lib.sh not found — cannot delete backups from S3"
        log "    Delete manually ($(_store_name primary)): aws --endpoint-url ${PRIMARY_S3_ENDPOINT} s3 rm s3://${PRIMARY_S3_BUCKET}/${BACKUP_PREFIX}/ --recursive"
        for _role in ${COPY_ROLES[@]+"${COPY_ROLES[@]}"}; do
            log "    Delete manually ($(_store_name "$_role")): aws --endpoint-url $(_store_var "$_role" ENDPOINT) s3 rm s3://$(_store_var "$_role" BUCKET)/${BACKUP_PREFIX}/ --recursive"
        done
    fi
fi

# ==============================================================================
# 11. REMOVAL — TARGET FILES (last, because lib.sh is needed for S3)
# ==============================================================================
if [[ "$FOUND_TARGET" == "true" ]]; then
    log_step "Removing the installation files"

    if [[ "$KEEP_CONF" == "true" ]]; then
        # Keep backup.conf separately
        if [[ -f "$TARGET_DIR/backup.conf" ]]; then
            BACKUP_CONF_SAVED="${TARGET_DIR}.backup.conf.saved.$(date +%Y%m%d_%H%M%S)"
            if [[ "$DRY_RUN" == "true" ]]; then
                log_dry "Save backup.conf to $BACKUP_CONF_SAVED"
            else
                cp -p "$TARGET_DIR/backup.conf" "$BACKUP_CONF_SAVED"
                log_ok "backup.conf saved to $BACKUP_CONF_SAVED"
            fi
        fi
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "rm -rf $TARGET_DIR"
    else
        rm -rf "$TARGET_DIR" && log_ok "Removed $TARGET_DIR" || log_err "Could not remove $TARGET_DIR"
    fi
fi

# ==============================================================================
# 12. REMOVAL — LOGS (if requested)
# ==============================================================================
if [[ "$PURGE_LOGS" == "true" && "$FOUND_LOGS" == "true" ]]; then
    log_step "Removing the logs"
    for f in "${log_files[@]}"; do
        do_action "rm $f" rm -f "$f"
    done
fi

# ==============================================================================
# 13. SUMMARY
# ==============================================================================
echo
echo "${C_BOLD}${C_GREEN}╔═══════════════════════════════════════════════════════════════╗"
if [[ "$DRY_RUN" == "true" ]]; then
    echo "║                  🧪  DRY-RUN complete                          ║"
else
    echo "║                  ✅  Removal complete                          ║"
fi
echo "╚═══════════════════════════════════════════════════════════════╝${C_RESET}"
echo

echo "${C_BOLD}What is left on the system:${C_RESET}"

# Check the dependencies
deps_left=()
for cmd in docker aws jq dos2unix curl gpg flock; do
    command -v "$cmd" >/dev/null 2>&1 && deps_left+=("$cmd")
done

if [[ ${#deps_left[@]} -gt 0 ]]; then
    echo "  ${C_DIM}• System packages (not removed automatically):${C_RESET}"
    echo "    $(IFS=' '; echo "${deps_left[*]}")"
fi

# GPG passphrase
if [[ -f /root/.docker-backup-passphrase ]]; then
    echo "  ${C_DIM}• GPG passphrase:${C_RESET} /root/.docker-backup-passphrase"
    echo "    ${C_DIM}(needed to decrypt encrypted backups in S3)${C_RESET}"
fi

# Logs (if not removed)
if [[ "$PURGE_LOGS" != "true" && "$FOUND_LOGS" == "true" ]]; then
    echo "  ${C_DIM}• Logs (${#log_files[@]} file(s)):${C_RESET}"
    for f in "${log_files[@]}"; do
        echo "    $f"
    done
fi

# pre-backup hooks in projects
hooks_found=()
shopt -s nullglob
for hook in /opt/*/pre-backup-hook.sh /home/*/pre-backup-hook.sh /srv/*/pre-backup-hook.sh; do
    [[ -f "$hook" ]] && hooks_found+=("$hook")
done
shopt -u nullglob
if [[ ${#hooks_found[@]} -gt 0 ]]; then
    echo "  ${C_DIM}• pre-backup hooks in projects:${C_RESET}"
    for h in "${hooks_found[@]}"; do
        echo "    $h"
    done
fi

# db-dumps in projects
dumps_found=()
shopt -s nullglob
for d in /opt/*/db-dumps /home/*/db-dumps /srv/*/db-dumps; do
    [[ -d "$d" ]] && dumps_found+=("$d")
done
shopt -u nullglob
if [[ ${#dumps_found[@]} -gt 0 ]]; then
    echo "  ${C_DIM}• db-dumps folders in projects:${C_RESET}"
    for d in "${dumps_found[@]}"; do
        size=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
        echo "    $d ($size)"
    done
fi

# Backups in S3 (shown as "kept" only if they were not purged)
if [[ "$PURGE_S3" != "true" && -n "${PRIMARY_S3_BUCKET:-}" ]]; then
    echo "  ${C_GREEN}• Backups KEPT ($(_store_name primary)):${C_RESET} s3://${PRIMARY_S3_BUCKET}/${BACKUP_PREFIX:-backups}/"
    for _role in ${COPY_ROLES[@]+"${COPY_ROLES[@]}"}; do
        echo "  ${C_GREEN}• Backups KEPT ($(_store_name "$_role")):${C_RESET} s3://$(_store_var "$_role" BUCKET)/${BACKUP_PREFIX:-backups}/"
    done
    echo "    ${C_DIM}(use --purge-s3 to delete — it wipes all storages)${C_RESET}"
fi

# Saved conf
if [[ "$KEEP_CONF" == "true" && -n "${BACKUP_CONF_SAVED:-}" ]]; then
    echo "  ${C_GREEN}• backup.conf saved:${C_RESET} $BACKUP_CONF_SAVED"
fi

echo

if [[ "$DRY_RUN" == "true" ]]; then
    echo "${C_YELLOW}That was a dry run — for a real removal run without -n / --dry-run${C_RESET}"
else
    echo "${C_DIM}To reinstall: run install.sh from the folder with the files${C_RESET}"
fi
echo
