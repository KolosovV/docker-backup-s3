#!/usr/bin/env bash
# ==============================================================================
# setup-cron.sh
# Interactive setup of scheduled docker-backup-s3 runs via cron or a systemd timer
#
# Run as root: sudo ./setup-cron.sh
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/backup.conf"
BACKUP_SCRIPT="${SCRIPT_DIR}/docker-backup.sh"
VERIFY_SCRIPT="${SCRIPT_DIR}/verify-restore.sh"
LOGROTATE_DIR="${LOGROTATE_DIR:-/etc/logrotate.d}"   # another folder only in the tests

# --- Arguments ---
NON_INTERACTIVE="false"
SCHEDULE_ARG=""
METHOD_ARG=""
VERIFY_ARG=""
REMOVE_MODE="false"
STATUS_MODE="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes) NON_INTERACTIVE="true"; shift ;;
        -s|--schedule) SCHEDULE_ARG="$2"; shift 2 ;;
        -m|--method) METHOD_ARG="$2"; shift 2 ;;
        -v|--verify) VERIFY_ARG="$2"; shift 2 ;;
        --remove) REMOVE_MODE="true"; shift ;;
        --status) STATUS_MODE="true"; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [options]

Interactive setup of scheduled docker-backup.sh runs, and of the restore check (verify-restore.sh).

  -m, --method cron|systemd  pick the method (interactive choice by default)
  -s, --schedule PRESET      schedule preset: daily / twice / 6h / weekdays / weekly
                             or a specific cron expression, e.g. '0 3 * * *'
  -v, --verify PRESET        when to check that the latest backups restore: daily / weekly / off,
                             or an expression in the method's format. Not given: the current check
                             schedule stays, a new setup gets weekly. Given alone, with scheduled
                             runs already set up: only the check changes, the backups keep theirs
  -y, --yes                  no confirmations (an existing schedule is replaced)
  --remove                   remove the existing jobs
  --status                   show the current status (cron/systemd) and exit
  -h, --help                 this help

EXAMPLES:
  Interactively:          sudo $0
  Cron daily at 3:        sudo $0 -m cron -s daily -y
  Every 6 hours:          sudo $0 -m cron -s 6h -y
  Custom schedule:        sudo $0 -m cron -s '15 4 * * *' -y
  systemd timer at 4:30:  sudo $0 -m systemd -s '*-*-* 04:30:00' -y
  Check restores daily:   sudo $0 -v '30 5 * * *' -y
  No restore check:       sudo $0 -v off -y
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

# The restore check: some hours after the default backup time, so it checks the night's copy
# (it also waits for a backup still under way). It downloads every project's latest archive.
declare -A CRON_VERIFY_PRESETS=(
    [daily]="0 6 * * *"
    [weekly]="0 6 * * 0"
)
declare -A SYSTEMD_VERIFY_PRESETS=(
    [daily]="*-*-* 06:00:00"
    [weekly]="Sun *-*-* 06:00:00"
)
declare -A VERIFY_PRESET_NAMES=(
    [daily]="Every day at 06:00"
    [weekly]="Once a week — Sunday 06:00"
)

# ==============================================================================
# Current status
# ==============================================================================
get_cron_line() {
    crontab -l 2>/dev/null | grep -E "$BACKUP_SCRIPT|docker-backup\.sh" | head -1 || true
}

# Ours only inside our block: a verify-restore.sh line of the admin's own (with --quick, say, as an older
# README suggested) is theirs, and stays as it is
get_verify_cron_line() {
    crontab -l 2>/dev/null | sed -n '/^# === Docker backup ===/,/^# === \/Docker backup ===/p' \
        | grep -v '^[[:space:]]*#' | grep -F "$VERIFY_SCRIPT" | head -1 || true
}

# The restore-check timer is there (by the unit file, as remove_systemd explains)
verify_timer_exists() { [[ -f /etc/systemd/system/docker-backup-verify.timer ]]; }

show_status() {
    log "${C_BOLD}${C_CYAN}━━━ Current scheduled-run status ━━━${C_RESET}"
    echo

    # Cron
    local cron_line verify_line
    cron_line="$(get_cron_line)"
    verify_line="$(get_verify_cron_line)"
    if [[ -n "$cron_line" ]]; then
        echo "${C_BOLD}Cron:${C_RESET} ${C_GREEN}configured${C_RESET}"
        echo "  $cron_line"
    else
        echo "${C_BOLD}Cron:${C_RESET} ${C_DIM}not configured${C_RESET}"
    fi
    if [[ -n "$verify_line" ]]; then
        echo "${C_BOLD}Restore check (cron):${C_RESET} ${C_GREEN}configured${C_RESET}"
        echo "  $verify_line"
    elif [[ -n "$cron_line" ]]; then
        echo "${C_BOLD}Restore check:${C_RESET} ${C_DIM}not scheduled${C_RESET} (sudo $0 -v weekly)"
    fi
    echo

    if verify_timer_exists; then
        echo "${C_BOLD}Restore check (systemd timer):${C_RESET} ${C_GREEN}configured${C_RESET}"
        echo "  OnCalendar: $(sed -n 's/^OnCalendar=//p' /etc/systemd/system/docker-backup-verify.timer | head -1)"
        echo
    fi

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

# Remove the restore-check units
remove_verify_units() {
    verify_timer_exists || return 0
    systemctl disable --now docker-backup-verify.timer 2>/dev/null || true
    rm -f /etc/systemd/system/docker-backup-verify.service /etc/systemd/system/docker-backup-verify.timer
    systemctl daemon-reload 2>/dev/null || true
}

remove_cron() {
    local cron_line
    cron_line="$(get_cron_line)"
    if [[ -z "$cron_line" ]]; then
        log_info "No cron job for docker-backup-s3 found"
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
    if [[ ! -f /etc/systemd/system/docker-backup.timer ]] && ! verify_timer_exists; then
        log_info "No systemd timer for docker-backup-s3 found"
        return 0
    fi

    log "systemd timer found: $( [[ -f /etc/systemd/system/docker-backup.timer ]] && printf 'docker-backup.timer ')$(verify_timer_exists && printf 'docker-backup-verify.timer')"

    if ask_yn "Stop and remove it?" "y"; then
        systemctl disable --now docker-backup.timer 2>/dev/null || true
        rm -f /etc/systemd/system/docker-backup.service /etc/systemd/system/docker-backup.timer
        systemctl daemon-reload 2>/dev/null || true
        remove_verify_units
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

# choose_verify <method> <current, may be empty> — the restore-check schedule, "off" for none
choose_verify() {
    local method="$1" current="$2"
    local -a keys=()
    [[ -n "$current" ]] && keys+=(keep)
    keys+=(weekly daily custom off)
    echo >&2
    echo "${C_BOLD}🧪 Check that the latest backups restore (verify-restore.sh), on a schedule:${C_RESET}" >&2
    echo "   It downloads each project's latest archive, unpacks it and checks the database dumps." >&2
    echo "──────────────────────────────────────────────" >&2
    local i=1 k spec
    for k in "${keys[@]}"; do
        case "$k" in
            keep)   printf "  ${C_CYAN}%d)${C_RESET} Keep the current one  ${C_DIM}(%s)${C_RESET}\n" "$i" "$current" >&2 ;;
            custom) printf "  ${C_CYAN}%d)${C_RESET} ${C_BOLD}Custom schedule${C_RESET} (in the same format as the backups)\n" "$i" >&2 ;;
            off)    printf "  ${C_CYAN}%d)${C_RESET} No scheduled check\n" "$i" >&2 ;;
            *)
                if [[ "$method" == "cron" ]]; then spec="${CRON_VERIFY_PRESETS[$k]}"; else spec="${SYSTEMD_VERIFY_PRESETS[$k]}"; fi
                printf "  ${C_CYAN}%d)${C_RESET} %s  ${C_DIM}(%s)${C_RESET}\n" "$i" "${VERIFY_PRESET_NAMES[$k]}" "$spec" >&2 ;;
        esac
        i=$((i + 1))
    done
    echo "──────────────────────────────────────────────" >&2
    local choice
    while true; do
        read -rp "Enter a number [1-${#keys[@]}]: " choice </dev/tty >&2
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#keys[@]} )); then
            k="${keys[$((choice - 1))]}"
            case "$k" in
                keep)   printf '%s\n' "$current" ;;
                off)    printf 'off\n' ;;
                custom) read -rp "Enter the schedule: " spec </dev/tty >&2; printf '%s\n' "${spec:-off}" ;;
                *)      if [[ "$method" == "cron" ]]; then printf '%s\n' "${CRON_VERIFY_PRESETS[$k]}"
                        else printf '%s\n' "${SYSTEMD_VERIFY_PRESETS[$k]}"; fi ;;
            esac
            return 0
        fi
        echo "${C_RED}Invalid choice${C_RESET}" >&2
    done
}

# ==============================================================================
# Cron setup
# ==============================================================================
install_cron() {
    local schedule="$1" verify="${2:-off}"
    local cron_log="/var/log/docker-backup-cron.log"

    log_step "Setting up the cron job..."
    command -v crontab >/dev/null 2>&1 || fail "crontab is not installed: install cron (Debian/Ubuntu, openSUSE), cronie (RHEL, Fedora, Arch) or dcron (Alpine), or use -m systemd"

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
    local new_cron verify_line=""
    [[ "$verify" != "off" ]] && verify_line=$'\n'"$verify ${nice_prefix}$VERIFY_SCRIPT >> $cron_log 2>&1"
    new_cron="$current_cron

# === Docker backup ===
# Installed by setup-cron.sh ($(date '+%Y-%m-%d %H:%M:%S'))
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin
MAILTO=\"\"
$schedule ${nice_prefix}$BACKUP_SCRIPT >> $cron_log 2>&1${verify_line}
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
    local oncalendar="$1" verify="${2:-off}"

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

    remove_verify_units
    if [[ "$verify" != "off" ]]; then
        cat > /etc/systemd/system/docker-backup-verify.service <<EOF
[Unit]
Description=docker-backup-s3: check that the latest backups restore
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin
ExecStart=/bin/bash -c 'exec $VERIFY_SCRIPT >> /var/log/docker-backup-cron.log 2>&1'
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF
        cat > /etc/systemd/system/docker-backup-verify.timer <<EOF
[Unit]
Description=docker-backup-s3: restore check timer

[Timer]
OnCalendar=$verify
Persistent=true
Unit=docker-backup-verify.service
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF
    fi

    systemctl daemon-reload
    systemctl enable --now docker-backup.timer
    [[ "$verify" != "off" ]] && systemctl enable --now docker-backup-verify.timer

    log_ok "systemd timer installed and activated"
    echo
    log "${C_BOLD}Timer info:${C_RESET}"
    systemctl status docker-backup.timer --no-pager 2>/dev/null | head -10 | sed 's/^/  /' || true
    echo
    log "${C_BOLD}Next run:${C_RESET}"
    systemctl list-timers docker-backup.timer --no-pager 2>/dev/null \
        | sed -n '2p' | sed 's/^/  /'
    if [[ "$verify" != "off" ]]; then
        log "${C_BOLD}Next restore check:${C_RESET}"
        systemctl list-timers docker-backup-verify.timer --no-pager 2>/dev/null \
            | sed -n '2p' | sed 's/^/  /'
    fi
    return 0
}

# ==============================================================================
# logrotate setup
# ==============================================================================
setup_logrotate() {
    if [[ ! -d "$LOGROTATE_DIR" ]]; then
        log_warn "logrotate is not installed (no ${LOGROTATE_DIR}) — the logs will not be rotated"
        return 0
    fi
    if [[ -f "$LOGROTATE_DIR/docker-backup" ]]; then
        log_info "Logrotate is already configured (${LOGROTATE_DIR}/docker-backup)"
        return 0
    fi

    if ! ask_yn "Set up log rotation via logrotate?" "y"; then
        return 0
    fi

    cat > "$LOGROTATE_DIR/docker-backup" <<'EOF'
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

    log_ok "Logrotate configured (${LOGROTATE_DIR}/docker-backup)"
    log "  Logs will be rotated weekly, keeping 8 archives (≈2 months)"
}

# ==============================================================================
# MAIN FLOW
# ==============================================================================
log "${C_BOLD}${C_BLUE}═══════════════════════════════════════════════════════════════${C_RESET}"
log "${C_BOLD}🛠  Setting up scheduled docker-backup-s3 runs${C_RESET}"
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
OLD_METHOD=""; OLD_SCHEDULE=""; OLD_VERIFY=""   # what is set up now; OLD_VERIFY empty — no restore check
if [[ -n "$local_existing_cron" || -n "$local_existing_systemd" ]]; then
    if [[ -n "$local_existing_cron" ]]; then
        OLD_METHOD="cron"
        OLD_SCHEDULE="$(printf '%s' "$local_existing_cron" | awk '{print $1, $2, $3, $4, $5}')"
        _v="$(get_verify_cron_line)"
        [[ -n "$_v" ]] && OLD_VERIFY="$(printf '%s' "$_v" | awk '{print $1, $2, $3, $4, $5}')"
        OLD_SETUP="cron: ${OLD_SCHEDULE}"
    fi
    if [[ -n "$local_existing_systemd" ]]; then
        _oncal="$(systemctl cat docker-backup.timer 2>/dev/null | sed -n 's/^OnCalendar=//p' | head -1)"
        OLD_METHOD="systemd"; OLD_SCHEDULE="$_oncal"; OLD_VERIFY=""
        verify_timer_exists && OLD_VERIFY="$(sed -n 's/^OnCalendar=//p' /etc/systemd/system/docker-backup-verify.timer | head -1)"
        OLD_SETUP="${OLD_SETUP:+$OLD_SETUP; }systemd: ${_oncal:-?}"
    fi
    OLD_SETUP+=", restore check: ${OLD_VERIFY:-off}"
fi

# -v alone, with scheduled runs set up: only the restore check changes, the backups keep their method and schedule
VERIFY_ONLY="false"
if [[ -n "$VERIFY_ARG" && -z "$SCHEDULE_ARG" && -z "$METHOD_ARG" && -n "$OLD_METHOD" && -n "$OLD_SCHEDULE" ]]; then
    VERIFY_ONLY="true"
    METHOD_ARG="$OLD_METHOD"; SCHEDULE_ARG="$OLD_SCHEDULE"
    log "Only the restore check changes; the backups keep ${OLD_METHOD}: ${OLD_SCHEDULE}"
elif [[ -n "$OLD_SETUP" ]]; then
    log_warn "Scheduled runs are already set up:"
    [[ -n "$local_existing_cron" ]] && echo "  Cron: $local_existing_cron"
    [[ -n "$local_existing_systemd" ]] && echo "  systemd timer active (${_oncal:-could not read the schedule})"
    echo "  Restore check: ${OLD_VERIFY:-not scheduled}"
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
    remove_verify_units
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

# 2b. The restore check
VERIFY=""
if [[ -n "$VERIFY_ARG" ]]; then
    case "$VERIFY_ARG" in
        off|none|no) VERIFY="off" ;;
        *)
            if [[ -n "${CRON_VERIFY_PRESETS[$VERIFY_ARG]:-}" ]]; then
                if [[ "$METHOD" == "cron" ]]; then VERIFY="${CRON_VERIFY_PRESETS[$VERIFY_ARG]}"
                else VERIFY="${SYSTEMD_VERIFY_PRESETS[$VERIFY_ARG]}"; fi
            else
                VERIFY="$VERIFY_ARG"
            fi ;;
    esac
elif [[ "$NON_INTERACTIVE" == "true" ]]; then
    # Not given: a setup that has a check keeps it (a new method can't take an expression of the old one —
    # then the weekly preset); a setup without one stays without; a new setup gets the weekly one
    if [[ -n "$OLD_VERIFY" && "$METHOD" == "$OLD_METHOD" ]]; then VERIFY="$OLD_VERIFY"
    elif [[ -n "$OLD_METHOD" && -z "$OLD_VERIFY" ]]; then VERIFY="off"
    elif [[ "$METHOD" == "cron" ]]; then VERIFY="${CRON_VERIFY_PRESETS[weekly]}"
    else VERIFY="${SYSTEMD_VERIFY_PRESETS[weekly]}"; fi
else
    _cur=""; [[ "$METHOD" == "$OLD_METHOD" ]] && _cur="$OLD_VERIFY"
    VERIFY="$(choose_verify "$METHOD" "$_cur")"
fi
[[ -z "$VERIFY" ]] && VERIFY="off"
if [[ "$VERIFY" != "off" ]]; then
    if [[ "$METHOD" == "cron" && "$(echo "$VERIFY" | awk '{print NF}')" -ne 5 ]]; then
        fail "Invalid cron format for the restore check: '$VERIFY' (5 fields expected). The old scheduled runs are untouched."
    fi
    if [[ "$METHOD" == "systemd" ]] && command -v systemd-analyze >/dev/null 2>&1 \
       && ! systemd-analyze calendar "$VERIFY" >/dev/null 2>&1; then
        fail "Invalid OnCalendar for the restore check: '$VERIFY'. The old scheduled runs are untouched."
    fi
    [[ -x "$VERIFY_SCRIPT" ]] || fail "Executable not found: $VERIFY_SCRIPT"
fi
log_ok "Restore check: $VERIFY"

# 3. Confirmation
echo
log "${C_BOLD}Will be installed:${C_RESET}"
log "  Method:        $METHOD"
log "  Schedule:      $SCHEDULE"
log "  Script:        $BACKUP_SCRIPT"
if [[ "$VERIFY" == "off" ]]; then
    log "  Restore check: off"
else
    log "  Restore check: $VERIFY ($VERIFY_SCRIPT; waits for a backup still running)"
fi
log "  Log:           /var/log/docker-backup-cron.log"
echo

if ! ask_yn "Apply?" "y"; then
    log "Cancelled."
    exit 0
fi

# 4. Installation
[[ -n "$OLD_SETUP" ]] && remove_existing_setup
case "$METHOD" in
    cron) install_cron "$SCHEDULE" "$VERIFY" ;;
    systemd) install_systemd "$SCHEDULE" "$VERIFY" ;;
esac
[[ -n "$OLD_SETUP" ]] && log_ok "Scheduled runs replaced: was ${OLD_SETUP} → now ${METHOD}: ${SCHEDULE}, restore check: ${VERIFY}"

# 5. Logrotate
echo
setup_logrotate

# 6. Test run (optional)
echo
if [[ "$VERIFY_ONLY" != "true" ]] && ask_yn "Run a test backup right now (synchronously)?" "n"; then
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
log "  ${C_CYAN}sudo $VERIFY_SCRIPT${C_RESET}  — check the restores now"
