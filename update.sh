#!/usr/bin/env bash
# ==============================================================================
# update.sh
# Updates Docker Backup System in place, keeping backup.conf and pre/post hooks.
#
# What it does:
#   1. Backs up all current files to /opt/docker-backup-s3.bak.<timestamp>/
#   2. Copies the new script versions over the old ones
#   3. Does not overwrite backup.conf: shows new options and renames
#      the old primary storage names S3_* → PRIMARY_S3_* (with a copy alongside)
#   4. dos2unix + chmod +x
#   5. Runs validate-config.sh
#
# What is NOT updated:
#   - backup.conf (your settings are kept; only the names S3_* → PRIMARY_S3_* change)
#   - the cron job (stays as it was)
#   - logrotate config
#   - backups in S3
#
# Usage:
#   sudo ./update.sh                          # from the unpacked archive
#   sudo ./update.sh --target /opt/docker-backup-s3
#   sudo ./update.sh --rollback               # roll back to the previous version
#   sudo ./update.sh --migrate-conf           # only rename S3_* → PRIMARY_S3_* in backup.conf
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Arguments ---
TARGET_DIR="/opt/docker-backup-s3"
NON_INTERACTIVE="false"
ROLLBACK="false"
SKIP_VALIDATE="false"
SKIP_BACKUP="false"
MIGRATE_ONLY="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--target)        TARGET_DIR="$2"; shift 2 ;;
        -s|--source)        SOURCE_DIR="$2"; shift 2 ;;
        -y|--yes)           NON_INTERACTIVE="true"; shift ;;
        --rollback)         ROLLBACK="true"; shift ;;
        --skip-validate)    SKIP_VALIDATE="true"; shift ;;
        --skip-backup)      SKIP_BACKUP="true"; shift ;;
        --migrate-conf)     MIGRATE_ONLY="true"; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [options]

Updates an installed Docker Backup System (in place).

  -t, --target DIR     where to install (default: /opt/docker-backup-s3)
  -s, --source DIR     where to take the new files from (default: next to the script)
  -y, --yes            no interactive questions
      --rollback       roll back to the latest backup copy
      --skip-validate  skip the final validation
      --skip-backup    do NOT make a backup copy (dangerous)
      --migrate-conf   only rename S3_* → PRIMARY_S3_* in backup.conf and exit

  -h, --help           this help

EXAMPLES:
  sudo $0                                # update from the current folder
  sudo $0 -s /tmp/new-version            # update from /tmp/new-version
  sudo $0 --rollback                     # roll back
EOF
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# --- Root check ---
if [[ "$EUID" -ne 0 ]]; then
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
log_warn() { echo "  ${C_YELLOW}⚠${C_RESET} $*"; }
log_err()  { echo "  ${C_RED}✗ $*${C_RESET}"; }
fail()     { log_err "$*"; exit 1; }

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

# Rename the primary storage in backup.conf: S3_* → PRIMARY_S3_* (names from older versions).
# The edit itself is s3_conf_migrate from lib.sh next to this update.sh (the new version), in a separate bash,
# so lib.sh doesn't replace the log functions here. It also makes the config copy.
migrate_conf() {
    local conf="$TARGET_DIR/backup.conf" lib="$SOURCE_DIR/lib.sh" out rc=0 line
    [[ -f "$conf" ]] || return 0
    [[ -f "$lib" ]] || { log_warn "No $lib — skipping the S3_* rename in backup.conf"; return 0; }
    out="$(bash -c 'source "$1" && s3_conf_migrate "$2"' _ "$lib" "$conf" 2>&1)" || rc=$?
    if [[ -z "$out" ]]; then
        (( rc == 0 )) && return 0
        log_err "Renaming S3_* in backup.conf failed (code $rc)"; return 1
    fi
    while IFS= read -r line; do
        if (( rc == 0 )); then log_ok "$line"; else log_err "$line"; fi
    done <<< "$out"
    return "$rc"
}

# ==============================================================================
# BANNER
# ==============================================================================
cat <<EOF
${C_BOLD}${C_BLUE}╔═══════════════════════════════════════════════════════════════╗
║   Docker Backup System — Updater                              ║
╚═══════════════════════════════════════════════════════════════╝${C_RESET}

EOF

# ==============================================================================
# CONFIG RENAME ONLY
# ==============================================================================
if [[ "$MIGRATE_ONLY" == "true" ]]; then
    log_step "Renaming storages in backup.conf"
    [[ -f "$TARGET_DIR/backup.conf" ]] || fail "Not found: $TARGET_DIR/backup.conf"
    migrate_conf || exit 1
    grep -qE '^S3_(ACCESS_KEY|BUCKET)=' "$TARGET_DIR/backup.conf" || log_ok "Storage names in backup.conf are the new ones (PRIMARY_S3_*)"
    exit 0
fi

# ==============================================================================
# ROLLBACK MODE
# ==============================================================================
if [[ "$ROLLBACK" == "true" ]]; then
    log_step "Rolling back to the previous version"

    # Find the newest backup copy
    LATEST_BAK=$(ls -dt "${TARGET_DIR}.bak."* 2>/dev/null | head -1 || true)

    if [[ -z "$LATEST_BAK" ]]; then
        fail "No backup copies ${TARGET_DIR}.bak.* found"
    fi

    log "Backup copy found: $LATEST_BAK"
    log "Date: $(stat -c %y "$LATEST_BAK" 2>/dev/null | cut -d. -f1)"
    echo

    if ! ask_yn "Roll ${TARGET_DIR} back to this version?" "y"; then
        log "Cancelled."
        exit 0
    fi

    # Back up the current state before rolling back
    REVERSED_BAK="${TARGET_DIR}.reverted.$(date +%Y%m%d_%H%M%S)"
    log "  Saving the current state to $REVERSED_BAK"
    mv "$TARGET_DIR" "$REVERSED_BAK"

    # Restore
    log "  Restoring from $LATEST_BAK"
    cp -a "$LATEST_BAK" "$TARGET_DIR"
    chmod +x "$TARGET_DIR"/*.sh 2>/dev/null || true

    log_ok "Rollback done"
    log "  The current state (before the rollback) is saved in: $REVERSED_BAK"
    log "  To delete old backup copies: sudo rm -rf ${TARGET_DIR}.bak.* ${TARGET_DIR}.reverted.*"

    exit 0
fi

# ==============================================================================
# NORMAL MODE: UPDATE
# ==============================================================================

# --- Checks ---
if [[ ! -d "$TARGET_DIR" ]]; then
    fail "Target directory not found: $TARGET_DIR. Use install.sh for the initial installation."
fi

if [[ "$SOURCE_DIR" == "$TARGET_DIR" ]]; then
    fail "Source and target are the same ($SOURCE_DIR). Put the new files into a separate folder and pass it with --source"
fi

# Check the required files in SOURCE
REQUIRED_FILES=(
    docker-backup.sh
    docker-restore.sh
    lib.sh
    ui.sh
    menu.sh
    validate-config.sh
)

log_step "Checking the source"
log "Source: $SOURCE_DIR"
log "Target: $TARGET_DIR"
echo

for f in "${REQUIRED_FILES[@]}"; do
    if [[ -f "$SOURCE_DIR/$f" ]]; then
        # Syntax check
        if bash -n "$SOURCE_DIR/$f" 2>/dev/null; then
            log_ok "$f"
        else
            log_err "$f has syntax errors!"
            fail "Not updating — the new $f is broken"
        fi
    else
        log_err "Not found: $SOURCE_DIR/$f"
        fail "The source is incomplete"
    fi
done

# ==============================================================================
# COMPARISON — what will actually change
# ==============================================================================
log_step "Comparing versions"
OLD_VERSION="$(cat "$TARGET_DIR/VERSION" 2>/dev/null || echo "before 1.0.0")"
NEW_VERSION="$(cat "$SOURCE_DIR/VERSION" 2>/dev/null || echo "unknown")"
log "Version: ${C_BOLD}${OLD_VERSION}${C_RESET} → ${C_BOLD}${NEW_VERSION}${C_RESET}  (changes: CHANGELOG.md)"

declare -a CHANGED_FILES=()
declare -a UNCHANGED_FILES=()
declare -a NEW_FILES=()

ALL_FILES=(
    docker-backup.sh
    docker-restore.sh
    lib.sh
    ui.sh
    menu.sh
    validate-config.sh
    setup-cron.sh
    install.sh
    uninstall.sh
    update.sh
    status.sh
    logs.sh
    verify-restore.sh
    diagnose-cron.sh
    diagnose-s3.sh
    sync-s3.sh
    drop-project.sh
    pre-backup-hook.example.sh
    backup.conf.example
    README.md
    CHANGELOG.md
    LICENSE
    VERSION
)

for f in "${ALL_FILES[@]}"; do
    if [[ ! -f "$SOURCE_DIR/$f" ]]; then
        continue
    fi
    if [[ ! -f "$TARGET_DIR/$f" ]]; then
        NEW_FILES+=("$f")
    elif [[ "$(sha256sum < "$SOURCE_DIR/$f")" == "$(sha256sum < "$TARGET_DIR/$f")" ]]; then   # not cmp: no diffutils on minimal systems
        UNCHANGED_FILES+=("$f")
    else
        CHANGED_FILES+=("$f")
    fi
done

if [[ ${#CHANGED_FILES[@]} -gt 0 ]]; then
    echo "  ${C_BOLD}Will be updated (${#CHANGED_FILES[@]}):${C_RESET}"
    for f in "${CHANGED_FILES[@]}"; do
        # Show the sizes
        s_lines=$(wc -l < "$SOURCE_DIR/$f")
        t_lines=$(wc -l < "$TARGET_DIR/$f")
        printf "    %-32s %4d → %4d lines\n" "$f" "$t_lines" "$s_lines"
    done
fi

if [[ ${#NEW_FILES[@]} -gt 0 ]]; then
    echo "  ${C_BOLD}Will be added (${#NEW_FILES[@]}):${C_RESET}"
    for f in "${NEW_FILES[@]}"; do
        echo "    $f"
    done
fi

if [[ ${#UNCHANGED_FILES[@]} -gt 0 ]]; then
    echo "  ${C_DIM}Unchanged (${#UNCHANGED_FILES[@]}):${C_RESET}"
    for f in "${UNCHANGED_FILES[@]}"; do
        echo "    ${C_DIM}$f${C_RESET}"
    done
fi

# backup.conf — separately. Never overwritten, but checked for new fields
echo
log_step "Checking backup.conf"
# The reference list of options is backup.conf.example; the working backup.conf is not in the repository
CONF_TEMPLATE="$SOURCE_DIR/backup.conf.example"

if [[ -f "$CONF_TEMPLATE" && -f "$TARGET_DIR/backup.conf" ]]; then
    # Get the variable names from both files
    NEW_VARS=$(grep -oE '^[A-Z_][A-Z0-9_]*=' "$CONF_TEMPLATE" | tr -d '=' | sort -u)
    # The old primary storage names (S3_BUCKET…) will become PRIMARY_S3_* after the update —
    # compare against those, so as not to scare with "missing" and "new" options
    OLD_VARS=$(grep -oE '^[A-Z_][A-Z0-9_]*=' "$TARGET_DIR/backup.conf" | tr -d '=' \
        | sed -E 's/^S3_(ACCESS_KEY|SECRET_KEY|ENDPOINT|REGION|BUCKET|OPTS_EXTRA|ADDRESSING_STYLE|RESTORE_ACCESS_KEY|RESTORE_SECRET_KEY)$/PRIMARY_S3_\1/' \
        | sort -u)
    if grep -qE '^S3_(ACCESS_KEY|SECRET_KEY|ENDPOINT|BUCKET)=' "$TARGET_DIR/backup.conf"; then
        echo "  ${C_YELLOW}⚠ The primary storage in backup.conf uses the old names (S3_*).${C_RESET}"
        echo "  ${C_DIM}The update renames them to PRIMARY_S3_*, with a copy of the config alongside (backup.conf.bak.<time>).${C_RESET}"
    fi

    ADDED_VARS=$(comm -23 <(echo "$NEW_VARS") <(echo "$OLD_VARS") || true)
    REMOVED_VARS=$(comm -13 <(echo "$NEW_VARS") <(echo "$OLD_VARS") || true)

    if [[ -n "$ADDED_VARS" ]]; then
        echo "  ${C_YELLOW}⚠ The new backup.conf has variables you don't have:${C_RESET}"
        echo "$ADDED_VARS" | sed 's/^/    + /'
        echo "  ${C_DIM}They will use the defaults. To adopt them — edit backup.conf manually.${C_RESET}"
    fi
    if [[ -n "$REMOVED_VARS" ]]; then
        echo "  ${C_DIM}Not in the new backup.conf (but you have them, they stay):${C_RESET}"
        echo "$REMOVED_VARS" | sed 's/^/    - /' | sed "s/.*/${C_DIM}&${C_RESET}/"
    fi
    if [[ -z "$ADDED_VARS" && -z "$REMOVED_VARS" ]]; then
        log_ok "The variable structure matches — nothing to change"
    fi

    log "  ${C_GREEN}Your values in backup.conf are kept${C_RESET}"
fi

if [[ ${#CHANGED_FILES[@]} -eq 0 && ${#NEW_FILES[@]} -eq 0 ]]; then
    echo
    log_ok "Everything is up to date — nothing to update"
    migrate_conf || true
    exit 0
fi

# ==============================================================================
# CONFIRMATION
# ==============================================================================
echo
if ! ask_yn "Apply the update?" "y"; then
    log "Cancelled."
    exit 0
fi

# ==============================================================================
# BACKUP COPY
# ==============================================================================
if [[ "$SKIP_BACKUP" != "true" ]]; then
    log_step "Backup copy"
    BACKUP_DIR="${TARGET_DIR}.bak.$(date +%Y%m%d_%H%M%S)"
    cp -a "$TARGET_DIR" "$BACKUP_DIR"
    log_ok "Saved to $BACKUP_DIR"
    log "  To roll back: sudo $0 --rollback"
fi

# ==============================================================================
# UPDATE
# ==============================================================================
log_step "Updating files"

# Make sure no backup is running right now
if [[ -d /var/run/docker-backup.lock.d ]]; then
    lock_pid=$(cat /var/run/docker-backup.lock.d/pid 2>/dev/null || echo "")
    if [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
        fail "A backup is running right now (PID $lock_pid). Wait for it to finish."
    fi
fi

# Copy the changed and new files
for f in "${CHANGED_FILES[@]}" "${NEW_FILES[@]}"; do
    cp -f "$SOURCE_DIR/$f" "$TARGET_DIR/$f"
    log_ok "$f"
done

# CRLF + permissions
if command -v dos2unix >/dev/null 2>&1; then
    dos2unix -q "$TARGET_DIR"/*.sh 2>/dev/null || true
else
    sed -i 's/\r$//' "$TARGET_DIR"/*.sh 2>/dev/null || true
fi
chmod +x "$TARGET_DIR"/*.sh 2>/dev/null || true
log_ok "dos2unix + chmod +x applied"

# The docker-backup command (the menu) — older installations don't have it
if [[ ! -e /usr/local/bin/docker-backup && -f "$TARGET_DIR/menu.sh" ]]; then
    ln -sfn "$TARGET_DIR/menu.sh" /usr/local/bin/docker-backup && log_ok "New command: sudo docker-backup (the menu)"
fi

# Storage names in backup.conf — after the new scripts: the old scripts don't understand PRIMARY_S3_*
migrate_conf || log_warn "backup.conf left with the old S3_* names — the new scripts understand them too"

# ==============================================================================
# VALIDATION
# ==============================================================================
if [[ "$SKIP_VALIDATE" != "true" ]]; then
    log_step "Validation after the update"
    if "$TARGET_DIR/validate-config.sh"; then
        log_ok "Validation passed"
    else
        log_warn "Validation found errors — check the output above"
    fi
fi

# ==============================================================================
# SUMMARY
# ==============================================================================
echo
echo "${C_BOLD}${C_GREEN}╔═══════════════════════════════════════════════════════════════╗"
echo "║                  ✅  Update complete                           ║"
echo "╚═══════════════════════════════════════════════════════════════╝${C_RESET}"
echo

echo "${C_BOLD}What's next:${C_RESET}"
echo "  ${C_CYAN}•${C_RESET} Menu:               sudo docker-backup"
echo "  ${C_CYAN}•${C_RESET} Dry run:            sudo $TARGET_DIR/docker-backup.sh --dry-run"
echo "  ${C_CYAN}•${C_RESET} Current status:     sudo $TARGET_DIR/status.sh"
[[ "$SKIP_BACKUP" != "true" ]] && \
echo "  ${C_CYAN}•${C_RESET} Roll back (if needed): sudo $0 --rollback"

# Info about new variables in the conf
if [[ -n "${ADDED_VARS:-}" ]]; then
    echo
    echo "${C_YELLOW}⚠ New options appeared in backup.conf:${C_RESET}"
    echo "$ADDED_VARS" | sed 's/^/    /'
    echo "  Consider using them: nano $TARGET_DIR/backup.conf"
fi

echo
