#!/usr/bin/env bash
# ==============================================================================
# setup-cron.sh
# Interactive setup of scheduled docker-backup runs via cron or a systemd timer
#
# Run as root: sudo ./setup-cron.sh
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/backup.conf"
BACKUP_SCRIPT="${SCRIPT_DIR}/docker-backup.sh"

# --- Arguments ---
NON_INTERACTIVE="false"
SCHEDULE_ARG=""
METHOD_ARG=""
REMOVE_MODE="false"
STATUS_MODE="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes) NON_INTERACTIVE="true"; shift ;;
        -s|--schedule) SCHEDULE_ARG="$2"; shift 2 ;;
        -m|--method) METHOD_ARG="$2"; shift 2 ;;
        --remove) REMOVE_MODE="true"; shift ;;
        --status) STATUS_MODE="true"; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [options]

Interactive setup of scheduled docker-backup.sh runs.

  -m, --method cron|systemd  pick the method (interactive choice by default)
  -s, --schedule PRESET      schedule preset: daily / twice / 6h / weekdays / weekly
                             or a specific cron expression, e.g. '0 3 * * *'
  -y, --yes                  no confirmations (an existing schedule is replaced)
  --remove                   remove the existing job
  --status                   show the current status (cron/systemd) and exit
  -h, --help                 this help

EXAMPLES:
  Interactively:          sudo $0
  Cron daily at 3:        sudo $0 -m cron -s daily -y
  Every 6 hours:          sudo $0 -m cron -s 6h -y
  Custom schedule:        sudo $0 -m cron -s '15 4 * * *' -y
  systemd timer at 4:30:  sudo $0 -m systemd -s '*-*-* 04:30:00' -y
  Remove:                 sudo $0 --remove
  Show status:            sudo $0 --status
EOF
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# Load the library for logging and colors
# shellcheck disable=SC1090
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE" 2>/dev/null || true
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

# --- Environment checks ---
if [[ "$EUID" -ne 0 ]]; then
    fail "The script must be run as root: sudo $0"
fi

if [[ ! -x "$BACKUP_SCRIPT" ]]; then
    fail "Executable not found: $BACKUP_SCRIPT"
fi

# ==============================================================================
# Helper: read y/n with a default
# ==============================================================================
ask_yn() {
    local prompt="$1" default="${2:-n}"
    local yn_hint
    [[ "$default" == "y" ]] && yn_hint="[Y/n]" || yn_hint="[y/N]"

    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        [[ "$default" == "y" ]] && return 0 || return 1
    fi

    local ans
    read -rp "$prompt $yn_hint: " ans </dev/tty
    ans="${ans:-$default}"
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

# ==============================================================================
# Schedule presets
# ==============================================================================
declare -A CRON_PRESETS=(
    [daily]="0 3 * * *"
    [twice]="0 4,16 * * *"
    [6h]="0 */6 * * *"
    [weekdays]="0 2 * * 1-5"
    [weekly]="0 3 * * 0"
)

declare -A SYSTEMD_PRESETS=(
    [daily]="*-*-* 03:00:00"
    [twice]="*-*-* 04,16:00:00"
    [6h]="*-*-* 00,06,12,18:00:00"
    [weekdays]="Mon..Fri *-*-* 02:00:00"
    [weekly]="Sun *-*-* 03:00:00"
)

declare -A PRESET_NAMES=(
    [daily]="Every day at 03:00"
    [twice]="Twice a day — 04:00 and 16:00"
    [6h]="Every 6 hours (00, 06, 12, 18)"
    [weekdays]="Weekdays at 02:00"
    [weekly]="Once a week — Sunday 03:00"
)

# ==============================================================================
# Current status
# ==============================================================================
get_cron_line() {
    crontab -l 2>/dev/null | grep -E "$BACKUP_SCRIPT|docker-backup\.sh" | head -1 || true
}

show_status() {
    log "${C_BOLD}${C_CYAN}━━━ Current scheduled-run status ━━━${C_RESET}"
    echo

    # Cron
    local cron_line
    cron_line="$(get_cron_line)"
    if [[ -n "$cron_line" ]]; then
        echo "${C_BOLD}Cron:${C_RESET} ${C_GREEN}configured${C_RESET}"
        echo "  $cron_line"
    else
        echo "${C_BOLD}Cron:${C_RESET} ${C_DIM}not configured${C_RESET}"
    fi
    echo

    # Systemd timer
    if systemctl list-unit-files docker-backup.timer >/dev/null 2>&1 && \
       systemctl is-enabled docker-backup.timer >/dev/null 2>&1; then
        echo "${C_BOLD}systemd timer:${C_RESET} ${C_GREEN}configured and active${C_RESET}"
        # When it fires next
        systemctl list-timers docker-backup.timer --no-pager 2>/dev/null \
            | sed -n '2p' \
            | awk '{print "  Next run: " $1 " " $2 " " $3 " (in " $4 ")"}'
        # Last run
        local last_result
        last_result=$(systemctl show docker-backup.service --property=Result --value 2>/dev/null || echo "?")
        echo "  Last result: $last_result"
    else
        echo "${C_BOLD}systemd timer:${C_RESET} ${C_DIM}not configured${C_RESET}"
    fi
    echo

    # Backup logs
    if [[ -f /var/log/docker-backup-cron.log ]]; then
        local last_log_line
        last_log_line=$(tail -1 /var/log/docker-backup-cron.log 2>/dev/null)
        if [[ -n "$last_log_line" ]]; then
            echo "${C_BOLD}Last entry in /var/log/docker-backup-cron.log:${C_RESET}"
            echo "  $last_log_line"
        fi
    fi
}

if [[ "$STATUS_MODE" == "true" ]]; then
    show_status
    exit 0
fi

# ==============================================================================
# Removal
# ==============================================================================
# The current crontab without our job and our "# === Docker backup ===" block (SHELL, PATH, MAILTO).
# Through a variable with "|| true": when nothing else is left, grep -v exits 1, and under
# pipefail + set -e that used to stop the script halfway.
crontab_without_ours() {
    local rest
    rest="$(crontab -l 2>/dev/null | grep -vE "$BACKUP_SCRIPT|docker-backup\.sh" \
        | sed '/^# === Docker backup ===/,/^# === \/Docker backup ===/d' || true)"
    printf '%s\n' "$rest"
}

remove_cron() {
    local cron_line
    cron_line="$(get_cron_line)"
    if [[ -z "$cron_line" ]]; then
        log_info "No cron job for docker-backup found"
        return 0
    fi

    log "Cron job found:"
    log "  $cron_line"

    if ask_yn "Remove it?" "y"; then
        # Remove our job and its block, keeping the rest
        crontab_without_ours | crontab -
        log_ok "Cron job removed"
    fi
}

remove_systemd() {
    # By the unit file: without systemd as init (containers) some systemctl versions still answer 0 here
    if [[ ! -f /etc/systemd/system/docker-backup.timer ]]; then
        log_info "No systemd timer for docker-backup found"
        return 0
    fi

    log "systemd timer found: docker-backup.timer"

    if ask_yn "Stop and remove it?" "y"; then
        systemctl disable --now docker-backup.timer 2>/dev/null || true
        rm -f /etc/systemd/system/docker-backup.service /etc/systemd/system/docker-backup.timer
        systemctl daemon-reload 2>/dev/null || true
        log_ok "systemd timer removed"
    fi
}

if [[ "$REMOVE_MODE" == "true" ]]; then
    log "${C_BOLD}${C_YELLOW}Removing scheduled runs${C_RESET}"
    echo
    remove_cron
    remove_systemd
    exit 0
fi

# ==============================================================================
# Interactive schedule choice
# ==============================================================================
choose_schedule() {
    local method="$1"  # cron or systemd

    echo >&2
    echo "${C_BOLD}📅 Choose a schedule:${C_RESET}" >&2
    echo "──────────────────────────────────────────────" >&2
    local i=1
    local -a keys=(daily twice 6h weekdays weekly custom)
    for k in "${keys[@]}"; do
        if [[ "$k" == "custom" ]]; then
            printf "  ${C_CYAN}%d)${C_RESET} ${C_BOLD}Custom schedule${C_RESET} (enter it manually)\n" "$i" >&2
        else
            local spec
            if [[ "$method" == "cron" ]]; then
                spec="${CRON_PRESETS[$k]}"
            else
                spec="${SYSTEMD_PRESETS[$k]}"
            fi
            printf "  ${C_CYAN}%d)${C_RESET} ${PRESET_NAMES[$k]}  ${C_DIM}($spec)${C_RESET}\n" "$i" >&2
        fi
        i=$((i + 1))
    done
    echo "──────────────────────────────────────────────" >&2

    while true; do
        local choice
        read -rp "Enter a number [1-${#keys[@]}]: " choice </dev/tty >&2
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#keys[@]} )); then
            local key="${keys[$((choice - 1))]}"
            if [[ "$key" == "custom" ]]; then
                echo >&2
                if [[ "$method" == "cron" ]]; then
                    echo "Cron format: '<minute> <hour> <day_of_month> <month> <day_of_week>'" >&2
                    echo "Example: 15 4 * * *  (every day at 04:15)" >&2
                else
                    echo "systemd OnCalendar format: '<DOW> *-*-* HH:MM:SS'" >&2
                    echo "Example: '*-*-* 04:30:00' (every day at 04:30)" >&2
                fi
                local spec
                read -rp "Enter the schedule: " spec </dev/tty >&2
                printf '%s\n' "$spec"
                return 0
            else
                if [[ "$method" == "cron" ]]; then
                    printf '%s\n' "${CRON_PRESETS[$key]}"
                else
                    printf '%s\n' "${SYSTEMD_PRESETS[$key]}"
                fi
                return 0
            fi
        fi
        echo "${C_RED}Invalid choice${C_RESET}" >&2
    done
}

# ==============================================================================
# Cron setup
# ==============================================================================
install_cron() {
    local schedule="$1"
    local cron_log="/var/log/docker-backup-cron.log"

    log_step "Setting up the cron job..."

    # Validate the cron expression (5 fields)
    local field_count
    field_count=$(echo "$schedule" | awk '{print NF}')
    if [[ "$field_count" -ne 5 ]]; then
        fail "Invalid cron format: '$schedule' (5 fields expected)"
    fi

    # The current crontab without our old job and block
    local current_cron
    current_cron="$(crontab_without_ours)"

    # The backup must not get in the way of production containers: tar and gzip saturate CPU and disk,
    # and S3_BANDWIDTH_LIMIT only limits the upload to S3, not this stage.
    local nice_prefix=""
    command -v nice   >/dev/null 2>&1 && nice_prefix="nice -n 10 "
    command -v ionice >/dev/null 2>&1 && nice_prefix="${nice_prefix}ionice -c2 -n7 "
    [[ -n "$nice_prefix" ]] && log_info "It will run at lowered priority: ${nice_prefix}"

    # Build the new crontab
    local new_cron
    new_cron="$current_cron

# === Docker backup ===
# Installed by setup-cron.sh ($(date '+%Y-%m-%d %H:%M:%S'))
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin
MAILTO=\"\"
$schedule ${nice_prefix}$BACKUP_SCRIPT >> $cron_log 2>&1
# === /Docker backup ==="

    echo "$new_cron" | crontab -

    log_ok "Cron job installed"
    echo
    log "${C_BOLD}Current crontab:${C_RESET}"
    crontab -l | sed 's/^/  /'

    # ─── Check that cron works ───────────────────────────────────────────────
    # Guard against set -e — every check may return exit≠0, which is fine
    set +e
    set +o pipefail

    cron_found=false
    cron_running=false
    cron_systemd_active=false

    # 1) Look for the binary by absolute paths (the PATH in the cron environment is trimmed)
    for cmd_path in /usr/sbin/cron /usr/sbin/crond /usr/bin/cron /usr/bin/crond; do
        if [[ -x "$cmd_path" ]]; then
            cron_found=true
            break
        fi
    done
    # Not found by absolute paths — try via PATH
    if ! $cron_found; then
        if command -v cron >/dev/null 2>&1 || command -v crond >/dev/null 2>&1; then
            cron_found=true
        fi
    fi

    # 2) The cron process is running (usually on Ubuntu: the /usr/sbin/cron process)
    if pgrep -x cron >/dev/null 2>&1; then cron_running=true; fi
    if ! $cron_running && pgrep -x crond >/dev/null 2>&1; then cron_running=true; fi
    # Extra check: a process with the full path
    if ! $cron_running && pgrep -f '/usr/sbin/cron' >/dev/null 2>&1; then cron_running=true; fi

    # 3) The systemd unit is active
    for u in cron cron.service crond crond.service cronie cronie.service; do
        if systemctl is-active --quiet "$u" 2>/dev/null; then
            cron_systemd_active=true
            break
        fi
    done

    set -e
    set -o pipefail

    if $cron_running || $cron_systemd_active; then
        # Cron works — all OK, print nothing
        log_ok "Cron is running"
    elif ! $cron_found; then
        log_warn "Cron is not installed on the system"
        log "  Install it: sudo apt install -y cron        (Debian/Ubuntu)"
        log "          or: sudo dnf install -y cronie     (RHEL/Rocky/Fedora)"
        log "  Then:       sudo systemctl enable --now cron"
    else
        # The binary is there but not active — try to bring it up
        log_warn "Cron is installed, but the service is not active — trying to start it..."
        cron_unit=""
        for u in cron crond cronie; do
            # systemctl cat fails for a unit that does not exist; list-unit-files answers 0 on systemd 239
            if systemctl cat "${u}.service" >/dev/null 2>&1; then
                cron_unit="$u"
                break
            fi
        done
        if command -v rc-service >/dev/null 2>&1 && ! command -v systemctl >/dev/null 2>&1; then
            # OpenRC (Alpine): the service is crond
            if rc-update add crond default >/dev/null 2>&1 && rc-service crond start >/dev/null 2>&1; then
                log_ok "Service crond started and enabled (OpenRC)"
            else
                log "  Could not do it automatically. Start it manually:"
                log "    sudo rc-update add crond default && sudo rc-service crond start"
            fi
        elif [[ -n "$cron_unit" ]]; then
            if systemctl enable --now "$cron_unit" 2>/dev/null; then
                log_ok "Service $cron_unit started and enabled"
            else
                log "  Could not do it automatically. Start it manually:"
                log "    sudo systemctl enable --now $cron_unit"
            fi
        else
            log "  Start it manually: sudo systemctl enable --now cron"
        fi
    fi
    # ────────────────────────────────────────────────────────────────────────

    # Tell right away when it fires
    echo
    log "${C_BOLD}Next run:${C_RESET}"
    if command -v systemd-analyze >/dev/null 2>&1; then
        # Convert the cron schedule to OnCalendar for nicer output
        local minute hour
        read -r minute hour _ <<< "$schedule"
        # The simple case — a specific hour and minute
        if [[ "$minute" =~ ^[0-9]+$ && "$hour" =~ ^[0-9]+$ ]]; then
            local cal="*-*-* ${hour}:${minute}:00"
            systemd-analyze calendar --iterations=1 "$cal" 2>/dev/null \
                | grep -E "Next elapse|From now" | sed 's/^/  /' || true
        else
            log "  $schedule (use 'systemd-analyze calendar' to check)"
        fi
    fi
}

# ==============================================================================
# systemd timer setup
# ==============================================================================
install_systemd() {
    local oncalendar="$1"

    log_step "Setting up the systemd timer..."

    cat > /etc/systemd/system/docker-backup.service <<EOF
[Unit]
Description=Docker Backup to S3
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin
# The log through the shell, not StandardOutput=append: — systemd before 240 (RHEL 8) has no append:
ExecStart=/bin/bash -c 'exec $BACKUP_SCRIPT >> /var/log/docker-backup-cron.log 2>&1'

# The backup is a background task: tar and gzip must not take CPU and disk away from production
# containers. S3_BANDWIDTH_LIMIT only limits the upload, not this stage.
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF

    cat > /etc/systemd/system/docker-backup.timer <<EOF
[Unit]
Description=Docker Backup Timer

[Timer]
OnCalendar=$oncalendar
Persistent=true
Unit=docker-backup.service

# Start spread of up to 5 minutes. If several servers write to one storage on
# the same schedule, at exactly 03:00 they compete for the provider's bandwidth and quotas.
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now docker-backup.timer

    log_ok "systemd timer installed and activated"
    echo
    log "${C_BOLD}Timer info:${C_RESET}"
    systemctl status docker-backup.timer --no-pager 2>/dev/null | head -10 | sed 's/^/  /' || true
    echo
    log "${C_BOLD}Next run:${C_RESET}"
    systemctl list-timers docker-backup.timer --no-pager 2>/dev/null \
        | sed -n '2p' | sed 's/^/  /'
}

# ==============================================================================
# logrotate setup
# ==============================================================================
setup_logrotate() {
    if [[ ! -d /etc/logrotate.d ]]; then
        log_warn "logrotate is not installed (no /etc/logrotate.d) — the logs will not be rotated"
        return 0
    fi
    if [[ -f /etc/logrotate.d/docker-backup ]]; then
        log_info "Logrotate is already configured (/etc/logrotate.d/docker-backup)"
        return 0
    fi

    if ! ask_yn "Set up log rotation via logrotate?" "y"; then
        return 0
    fi

    cat > /etc/logrotate.d/docker-backup <<'EOF'
/var/log/docker-backup.log /var/log/docker-backup-cron.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF

    log_ok "Logrotate configured (/etc/logrotate.d/docker-backup)"
    log "  Logs will be rotated weekly, keeping 8 archives (≈2 months)"
}

# ==============================================================================
# MAIN FLOW
# ==============================================================================
log "${C_BOLD}${C_BLUE}═══════════════════════════════════════════════════════════════${C_RESET}"
log "${C_BOLD}🛠  Setting up scheduled docker-backup runs${C_RESET}"
log "${C_BOLD}${C_BLUE}═══════════════════════════════════════════════════════════════${C_RESET}"
echo

# Check existing setups
local_existing_cron="$(get_cron_line)"
local_existing_systemd=""
if systemctl list-unit-files docker-backup.timer >/dev/null 2>&1 && \
   systemctl is-enabled docker-backup.timer >/dev/null 2>&1; then
    local_existing_systemd="yes"
fi

# Scheduled runs are already set up. With -y they are replaced without asking (-y used to silently cancel the replacement:
# ask_yn in non-interactive mode answers with the default "no", and the schedule did not change).
# Without -y — ask. The old setup is removed only after "Apply?" below: a refusal or
# an invalid schedule must not leave the server without scheduled runs at all.
OLD_SETUP=""
if [[ -n "$local_existing_cron" || -n "$local_existing_systemd" ]]; then
    [[ -n "$local_existing_cron" ]] && OLD_SETUP="cron: $(printf '%s' "$local_existing_cron" | awk '{print $1, $2, $3, $4, $5}')"
    if [[ -n "$local_existing_systemd" ]]; then
        _oncal="$(systemctl cat docker-backup.timer 2>/dev/null | sed -n 's/^OnCalendar=//p' | head -1)"
        OLD_SETUP="${OLD_SETUP:+$OLD_SETUP; }systemd: ${_oncal:-?}"
    fi
    log_warn "Scheduled runs are already set up:"
    [[ -n "$local_existing_cron" ]] && echo "  Cron: $local_existing_cron"
    [[ -n "$local_existing_systemd" ]] && echo "  systemd timer active (${_oncal:-could not read the schedule})"
    echo
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        log "  -y: the old setup will be replaced with the new one"
    elif ! ask_yn "Reconfigure (the old setup will be replaced)?" "n"; then
        log "Cancelled."
        exit 0
    fi
fi

# Remove the old scheduled runs — right before installing the new ones
remove_existing_setup() {
    if [[ -n "$local_existing_cron" ]]; then
        crontab_without_ours | crontab -
    fi
    if [[ -n "$local_existing_systemd" ]]; then
        systemctl disable --now docker-backup.timer 2>/dev/null || true
        rm -f /etc/systemd/system/docker-backup.service /etc/systemd/system/docker-backup.timer
        systemctl daemon-reload
    fi
    return 0
}

# 1. Choosing the method
METHOD="${METHOD_ARG:-}"
if [[ -z "$METHOD" ]]; then
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        METHOD="cron"  # default for non-interactive
    else
        echo "${C_BOLD}Choose how to schedule runs:${C_RESET}"
        echo "──────────────────────────────────────────────"
        echo "  ${C_CYAN}1)${C_RESET} ${C_BOLD}cron${C_RESET}  — simple and familiar"
        echo "  ${C_CYAN}2)${C_RESET} ${C_BOLD}systemd timer${C_RESET}  — catches up on missed runs (if the server was off)"
        echo "──────────────────────────────────────────────"

        while true; do
            read -rp "Choice [1/2]: " choice </dev/tty
            case "$choice" in
                1) METHOD="cron"; break ;;
                2) METHOD="systemd"; break ;;
                *) echo "${C_RED}Enter 1 or 2${C_RESET}" ;;
            esac
        done
    fi
fi

if [[ "$METHOD" != "cron" && "$METHOD" != "systemd" ]]; then
    fail "Invalid method: $METHOD (must be cron or systemd)"
fi

log_ok "Method: $METHOD"

# 2. Choosing the schedule
SCHEDULE=""
if [[ -n "$SCHEDULE_ARG" ]]; then
    if [[ -n "${CRON_PRESETS[$SCHEDULE_ARG]:-}" ]]; then
        # It's a preset
        if [[ "$METHOD" == "cron" ]]; then
            SCHEDULE="${CRON_PRESETS[$SCHEDULE_ARG]}"
        else
            SCHEDULE="${SYSTEMD_PRESETS[$SCHEDULE_ARG]}"
        fi
    else
        # It's a ready expression
        SCHEDULE="$SCHEDULE_ARG"
    fi
elif [[ "$NON_INTERACTIVE" == "true" ]]; then
    # Default
    if [[ "$METHOD" == "cron" ]]; then
        SCHEDULE="${CRON_PRESETS[daily]}"
    else
        SCHEDULE="${SYSTEMD_PRESETS[daily]}"
    fi
else
    SCHEDULE="$(choose_schedule "$METHOD")"
fi

[[ -z "$SCHEDULE" ]] && fail "No schedule given"
# Check the cron format before replacing the old job, not inside install_cron: otherwise an invalid schedule
# with -y would first remove the working job and then fail
if [[ "$METHOD" == "cron" && "$(echo "$SCHEDULE" | awk '{print NF}')" -ne 5 ]]; then
    fail "Invalid cron format: '$SCHEDULE' (5 fields expected). The old scheduled runs are untouched."
fi

log_ok "Schedule: $SCHEDULE"

# 3. Confirmation
echo
log "${C_BOLD}Will be installed:${C_RESET}"
log "  Method:      $METHOD"
log "  Schedule:    $SCHEDULE"
log "  Script:      $BACKUP_SCRIPT"
log "  Log:         /var/log/docker-backup-cron.log"
echo

if ! ask_yn "Apply?" "y"; then
    log "Cancelled."
    exit 0
fi

# 4. Installation
[[ -n "$OLD_SETUP" ]] && remove_existing_setup
case "$METHOD" in
    cron) install_cron "$SCHEDULE" ;;
    systemd) install_systemd "$SCHEDULE" ;;
esac
[[ -n "$OLD_SETUP" ]] && log_ok "Scheduled runs replaced: was ${OLD_SETUP} → now ${METHOD}: ${SCHEDULE}"

# 5. Logrotate
echo
setup_logrotate

# 6. Test run (optional)
echo
if ask_yn "Run a test backup right now (synchronously)?" "n"; then
    log_step "Running $BACKUP_SCRIPT ..."
    if "$BACKUP_SCRIPT"; then
        log_done "Test run succeeded"
    else
        log_err "The test run finished with an error — check /var/log/docker-backup.log"
    fi
fi

# 7. Final status
echo
show_status

echo
log "${C_BOLD}${C_GREEN}✅ Scheduled-run setup complete${C_RESET}"
log ""
log "Useful commands:"
log "  ${C_CYAN}sudo $0 --status${C_RESET}     — current status"
log "  ${C_CYAN}sudo $0 --remove${C_RESET}     — remove scheduled runs"
log "  ${C_CYAN}sudo tail -f /var/log/docker-backup-cron.log${C_RESET}  — follow the log"
log "  ${C_CYAN}sudo $BACKUP_SCRIPT --dry-run${C_RESET}  — test what will be backed up"
