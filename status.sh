#!/usr/bin/env bash
# ==============================================================================
# status.sh
# A quick one-screen overview of the docker-backup-s3 system state.
#
# Usage: sudo ./status.sh
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/backup.conf"

# --- Arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config) CONFIG_FILE="$2"; shift 2 ;;
        -h|--help)
            cat <<EOF
Usage: $0 [options]

A quick status overview of the docker-backup-s3 system.

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

require_cmd docker aws jq
_aws_setup primary read

# ==============================================================================
# Status helpers
# ==============================================================================
status_dot() {
    case "$1" in
        ok) printf "${C_GREEN}●${C_RESET}" ;;
        warn) printf "${C_YELLOW}●${C_RESET}" ;;
        err) printf "${C_RED}●${C_RESET}" ;;
        *) printf "${C_DIM}○${C_RESET}" ;;
    esac
}

human_size() {
    local bytes="${1:-0}"
    if (( bytes < 1024 )); then
        echo "${bytes}B"
    elif (( bytes < 1048576 )); then
        echo "$((bytes / 1024))KB"
    elif (( bytes < 1073741824 )); then
        echo "$((bytes / 1048576))MB"
    else
        local gb=$((bytes * 100 / 1073741824))
        echo "$((gb / 100)).$((gb % 100))GB"
    fi
}

age_human() {
    local epoch="${1:-0}"
    local now; now=$(date +%s)
    local diff=$((now - epoch))
    if (( diff < 60 )); then
        echo "${diff}s ago"
    elif (( diff < 3600 )); then
        echo "$((diff / 60))min ago"
    elif (( diff < 86400 )); then
        echo "$((diff / 3600))h ago"
    else
        echo "$((diff / 86400))d ago"
    fi
}

# ==============================================================================
# HEADER
# ==============================================================================
clear 2>/dev/null || true
cat <<EOF
${C_BOLD}${C_BLUE}╔═══════════════════════════════════════════════════════════════╗
║   📊  docker-backup-s3 — Status                               ║
╚═══════════════════════════════════════════════════════════════╝${C_RESET}
${C_DIM}  Version: $(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null || echo unknown)    Host: $(uname -n)    Date: $(date '+%Y-%m-%d %H:%M:%S')${C_RESET}

EOF

# ==============================================================================
# 1. LOCAL PROJECTS
# ==============================================================================
echo "${C_BOLD}${C_CYAN}━━━ Compose projects on this host ━━━${C_RESET}"

# Find projects (as in backup.sh)
declare -A LOCAL_PROJECTS=()
while IFS=$'\t' read -r project workdir; do
    [[ -z "$project" ]] && continue
    [[ -z "$workdir" || "$workdir" == "<no value>" ]] && continue
    [[ -d "$workdir" ]] || continue
    LOCAL_PROJECTS["$project"]="$workdir"
done < <(docker ps -a --format '{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.project.working_dir"}}' 2>/dev/null | sort -u)

# bash under set -u needs special handling of empty associative arrays
# rule N — N "─" (a table's underline). Not printf %-Ns: it pads by bytes, and "─" takes three.
rule() { local s; printf -v s '%*s' "$1" ''; printf '%s' "${s// /─}"; }

local_count=${#LOCAL_PROJECTS[@]}
if (( local_count == 0 )); then
    echo "  ${C_DIM}(none found)${C_RESET}"
else
    printf "  %-45s %-12s %s\n" "Project" "Containers" "Volumes"
    echo "  $(rule 45) $(rule 12) $(rule 7)"
    for proj in "${!LOCAL_PROJECTS[@]}"; do
        # Count containers
        running=$(docker ps -q --filter "label=com.docker.compose.project=$proj" 2>/dev/null | wc -l)
        total=$(docker ps -aq --filter "label=com.docker.compose.project=$proj" 2>/dev/null | wc -l)

        # Count volumes
        volumes_count=$(docker ps -aq --filter "label=com.docker.compose.project=$proj" 2>/dev/null \
            | xargs -r docker inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' 2>/dev/null \
            | sort -u | { grep -v '^$' || true; } | wc -l)

        # Find database containers
        db_types=()
        while IFS= read -r cid; do
            [[ -z "$cid" ]] && continue
            img=$(docker inspect --format '{{.Config.Image}}' "$cid" 2>/dev/null || true)
            dt=$(detect_db_type "$img")
            [[ -n "$dt" ]] && db_types+=("$dt")
        done < <(docker ps -q --filter "label=com.docker.compose.project=$proj" 2>/dev/null)
        db_info=""
        if [[ ${#db_types[@]} -gt 0 ]]; then
            db_info=" ${C_MAGENTA}🗄${C_RESET} $(join_list "${db_types[@]}")"
        fi

        # Status color
        if (( running == total )); then
            color_dot=$(status_dot ok)
        elif (( running > 0 )); then
            color_dot=$(status_dot warn)
        else
            color_dot=$(status_dot err)
        fi

        printf "  %s %-43s %-12s %d%s\n" \
            "$color_dot" "$proj" "${running}/${total}" "$volumes_count" "$db_info"
    done
fi
echo

# Remote databases (REMOTE_DBS): dumped straight into the storages, as the projects _db_<name>
declare -A REMOTE_HERE=()
while IFS= read -r n; do
    [[ -z "$n" ]] && continue
    if (( ${#REMOTE_HERE[@]} == 0 )); then echo "${C_BOLD}${C_CYAN}━━━ Remote databases ━━━${C_RESET}"; fi
    REMOTE_HERE["_db_$n"]=1
    if problems="$(remote_db_check "$n")"; then
        echo "  $(status_dot ok) $(printf '%-24s' "$n") $(remote_db_desc "$n")"
    else
        echo "  $(status_dot err) $(printf '%-24s' "$n") ${C_RED}$(head -n 1 <<< "$problems")${C_RESET}"
    fi
done < <(remote_db_names)
(( ${#REMOTE_HERE[@]} )) && echo

# ==============================================================================
# 2. BACKUPS IN THE STORAGES — the primary and every enabled copy
# ==============================================================================
# show_store <role> — storage summary. Sets STORE_OK (true/false), STORE_OBJECTS and
# STORE_LISTING (lines "key<TAB>size<TAB>date") — the rotation below is computed from the primary's.
show_store() {
    local role="$1" label listing="" key size lm proj epoch dot latest_age here_marker
    local -A latest=() count=() total=()
    local objects=0 bytes=0 newest=0 oldest last_age last_status now
    label="$(s3_label "$role" in)"
    STORE_OK=false; STORE_OBJECTS=0; STORE_LISTING=""

    if (( ${#S3_COPIES[@]} > 0 )); then
        echo "${C_BOLD}${C_CYAN}━━━ Backups ${label} ━━━${C_RESET}"
    else
        echo "${C_BOLD}${C_CYAN}━━━ Backups in S3 ━━━${C_RESET}"
    fi

    if [[ "$role" != "primary" ]] && ! s3_complete "$role"; then
        echo "  $(status_dot warn) ${C_YELLOW}Enabled, but not configured${C_RESET}"
        echo "    Fill in ${role^^}_S3_* in backup.conf"
        echo
        return 0
    fi

    _aws_setup "$role" read
    if listing=$(aws_q s3api list-objects-v2 \
        --bucket "$S3_CUR_BUCKET" --prefix "${BACKUP_PREFIX}/" \
        --query 'Contents[].[Key,Size,LastModified]' --output text 2>/dev/null); then
        STORE_OK=true
    fi
    # aws with --query may return "None\n" for an empty result; trimming and filtering turn it into nothing
    listing="$(echo "$listing" | sed 's/^None$//' | grep -v '^[[:space:]]*$' || true)"

    if [[ "$STORE_OK" != "true" ]]; then
        echo "  $(status_dot err) ${C_RED}Cannot access: $(s3_label "$role")${C_RESET}"
        echo "    Endpoint: $S3_CUR_ENDPOINT"
        echo "    Bucket:   $S3_CUR_BUCKET"
        echo "    Check:    sudo $SCRIPT_DIR/validate-config.sh"
        echo
        _aws_setup primary read
        return 0
    fi
    STORE_LISTING="$listing"

    oldest=$(date +%s)
    while IFS=$'\t' read -r key size lm; do
        [[ -z "$key" ]] && continue
        # key: backups/PROJECT/TIMESTAMP/file
        proj=$(echo "$key" | sed "s|^${BACKUP_PREFIX}/||" | cut -d/ -f1)
        [[ -z "$proj" ]] && continue
        epoch=$(date -d "$lm" +%s 2>/dev/null || echo 0)
        size=${size:-0}
        objects=$((objects + 1))
        bytes=$((bytes + size))
        # A backup is its archive; the .sha256 next to it is not another one
        [[ "$key" == *.sha256 ]] || count["$proj"]=$((${count["$proj"]:-0} + 1))
        total["$proj"]=$((${total["$proj"]:-0} + size))
        (( epoch > ${latest["$proj"]:-0} )) && latest["$proj"]=$epoch
        (( epoch < oldest )) && oldest=$epoch
        (( epoch > newest )) && newest=$epoch
    done <<< "$listing"
    STORE_OBJECTS=$objects

    if (( objects == 0 )); then
        echo "  $(status_dot warn) ${C_YELLOW}The bucket is empty${C_RESET}"
        [[ "$role" == "primary" ]] && echo "    No backups. Run: sudo $SCRIPT_DIR/docker-backup.sh"
        echo "    Bucket:   s3://$S3_CUR_BUCKET/$BACKUP_PREFIX/"
        echo
        _aws_setup primary read
        return 0
    fi

    now=$(date +%s)
    last_age=$((now - newest))
    if (( last_age < 86400 )); then last_status=$(status_dot ok)
    elif (( last_age < 86400 * 2 )); then last_status=$(status_dot warn)
    else last_status=$(status_dot err); fi

    echo "  $last_status Latest backup:       $(date -d "@$newest" '+%Y-%m-%d %H:%M:%S')  ($(age_human "$newest"))"
    echo "    Oldest:              $(date -d "@$oldest" '+%Y-%m-%d %H:%M:%S')  ($(age_human "$oldest"))"
    echo "    Objects:             $objects"
    echo "    Total size:          $(human_size $bytes)"
    echo "    Bucket:              s3://$S3_CUR_BUCKET/$BACKUP_PREFIX/"
    echo

    # Per project
    echo "  ${C_BOLD}Per project:${C_RESET}"
    printf "    %-45s %-10s %-12s %s\n" "Project" "Backups" "Size" "Latest"
    echo "    $(rule 45) $(rule 10) $(rule 12) $(rule 10)"
    for proj in $(printf '%s\n' "${!latest[@]}" | sort); do
        latest_age=$((now - ${latest[$proj]}))
        if (( latest_age < 86400 )); then dot=$(status_dot ok)
        elif (( latest_age < 86400 * 2 )); then dot=$(status_dot warn)
        else dot=$(status_dot err); fi

        # Does the project exist locally?
        if [[ -n "${LOCAL_PROJECTS[$proj]:-}" ]]; then
            here_marker=""
        elif [[ -n "${REMOTE_HERE[$proj]:-}" ]]; then
            here_marker=" ${C_DIM}(remote database)${C_RESET}"
        elif [[ "$proj" == _db_* ]]; then
            here_marker=" ${C_DIM}(a remote database no longer in REMOTE_DBS)${C_RESET}"
        else
            here_marker=" ${C_DIM}(not found locally)${C_RESET}"
        fi

        printf "    %s %-43s %-10d %-12s %s%s\n" \
            "$dot" "$proj" "${count[$proj]}" \
            "$(human_size "${total[$proj]}")" \
            "$(age_human "${latest[$proj]}")" \
            "$here_marker"
    done
    echo

    # Whether the copy is in sync with the primary (if the primary is reachable)
    if [[ "$role" != "primary" && "${S3_OK:-false}" == "true" ]]; then
        if (( objects == ${TOTAL_OBJECTS:-0} )); then
            echo "  $(status_dot ok) In sync with the primary ($objects objects in both)"
        else
            echo "  $(status_dot warn) Mismatch: primary=${TOTAL_OBJECTS:-0}, $(s3_label "$role")=$objects objects"
            echo "    ${C_DIM}To align: sudo $SCRIPT_DIR/sync-s3.sh --to $role${C_RESET}"
        fi
        echo
    fi
    _aws_setup primary read
    return 0
}

show_store primary
S3_OK="$STORE_OK"; TOTAL_OBJECTS="$STORE_OBJECTS"; S3_LISTING="$STORE_LISTING"
for role in ${S3_COPIES[@]+"${S3_COPIES[@]}"}; do
    show_store "$role"
done

# ==============================================================================
# 3. ROTATION — what will be deleted on the next run
# ==============================================================================
if [[ "$S3_OK" == "true" && -n "$S3_LISTING" ]]; then
    # Skip the rotation section if there are no backups (TOTAL_OBJECTS is set above)
    if [[ "${TOTAL_OBJECTS:-0}" -gt 0 ]]; then
    if [[ "${GFS_ENABLED:-false}" == "true" ]]; then
        echo "${C_BOLD}${C_CYAN}━━━ Rotation (GFS ${GFS_DAILY:-7}/${GFS_WEEKLY:-4}/${GFS_MONTHLY:-6}, minimum ${KEEP_MIN_BACKUPS:-3}) ━━━${C_RESET}"
    else
        echo "${C_BOLD}${C_CYAN}━━━ Rotation (RETENTION_DAYS=$RETENTION_DAYS, minimum ${KEEP_MIN_BACKUPS:-3}) ━━━${C_RESET}"
    fi

    if [[ "${GFS_ENABLED:-false}" != "true" ]] && { ! [[ "${RETENTION_DAYS:-}" =~ ^[0-9]+$ ]] || (( RETENTION_DAYS <= 0 )); }; then
        echo "  $(status_dot ok) Rotation is off — old backups are not deleted"
        echo
    else
    # The forecast is computed by THE SAME function as the actual deletion (lib.sh).
    # There used to be a separate calculation by LastModified here, while rotation went by
    # the timestamp in the key — after sync-s3 the numbers drifted apart.
    declare -A OBJ_SIZE=()
    while IFS=$'\t' read -r key size lm; do
        [[ -z "$key" ]] && continue
        OBJ_SIZE["$key"]="${size:-0}"
    done <<< "$S3_LISTING"

    expired_count=0
    expired_size=0
    while IFS=$'\t' read -r decision key; do
        [[ "$decision" == "DELETE" ]] || continue
        expired_count=$((expired_count + 1))
        expired_size=$((expired_size + ${OBJ_SIZE[$key]:-0}))
    done < <(awk -F'\t' 'NF>=3 {print $1"\t"$3}' <<< "$S3_LISTING" | plan_rotation)

    if (( expired_count > 0 )); then
        echo "  $(status_dot warn) Will be deleted on the next run:"
        echo "    Objects:   $expired_count"
        echo "    Size:      $(human_size $expired_size)"
    else
        echo "  $(status_dot ok) No backups due for deletion"
    fi
    echo
    fi
    fi
fi

# ==============================================================================
# 4. SCHEDULED RUNS (cron / systemd)
# ==============================================================================
echo "${C_BOLD}${C_CYAN}━━━ Scheduled runs ━━━${C_RESET}"

# Cron
CRON_LINE=$(crontab -l 2>/dev/null | grep -E "${SCRIPT_DIR}/docker-backup\.sh|/docker-backup\.sh" | head -1 || true)

if [[ -n "$CRON_LINE" ]]; then
    cron_schedule=$(echo "$CRON_LINE" | awk '{print $1, $2, $3, $4, $5}')
    echo "  $(status_dot ok) Cron:    $cron_schedule"
fi

# Systemd
if systemctl list-unit-files docker-backup.timer >/dev/null 2>&1 && \
   systemctl is-enabled docker-backup.timer >/dev/null 2>&1; then
    timer_state=$(systemctl is-active docker-backup.timer 2>/dev/null || echo "?")
    next_run=$(systemctl list-timers docker-backup.timer --no-pager 2>/dev/null \
        | sed -n '2p' | awk '{for(i=1;i<=4;i++) printf "%s ",$i; print ""}')

    if [[ "$timer_state" == "active" ]]; then
        echo "  $(status_dot ok) Systemd timer:  active"
    else
        echo "  $(status_dot warn) Systemd timer:  $timer_state"
    fi
    [[ -n "$next_run" && "$next_run" != "  " ]] && echo "    Next: $next_run"

    last_result=$(systemctl show docker-backup.service --property=Result --value 2>/dev/null || echo "?")
    [[ -n "$last_result" && "$last_result" != "?" ]] && echo "    Last run: $last_result"
    has_systemd=true
else
    has_systemd=false
fi

if [[ -z "$CRON_LINE" && "$has_systemd" != "true" ]]; then
    echo "  $(status_dot err) Scheduled runs are not set up"
    echo "    Set up: sudo $SCRIPT_DIR/setup-cron.sh"
fi
echo

# ==============================================================================
# 5. CONFIGURATION
# ==============================================================================
echo "${C_BOLD}${C_CYAN}━━━ Configuration ━━━${C_RESET}"
printf "  %-22s %s\n" "Backup mode:" "$BACKUP_MODE"
printf "  %-22s %s\n" "Retention:" "${RETENTION_DAYS} days"
for role in "${S3_ROLES[@]:1}"; do
    if s3_enabled "$role"; then
        printf "  %-22s %s\n" "$(s3_label "$role" title):" "${C_GREEN}ON${C_RESET} (required=$(s3_var "$role" REQUIRED))"
    else
        printf "  %-22s %s\n" "$(s3_label "$role" title):" "${C_DIM}OFF${C_RESET}"
    fi
done
printf "  %-22s %s\n" "Bandwidth limit:" "${S3_BANDWIDTH_LIMIT:-no limit}"
printf "  %-22s %s\n" "Parallel jobs:" "${PARALLEL_JOBS:-1}"
printf "  %-22s %s\n" "GPG encryption:" "$([[ "${ENCRYPT_BACKUPS:-false}" == "true" ]] && echo "${C_GREEN}ON${C_RESET}" || echo "${C_DIM}OFF${C_RESET}")"
printf "  %-22s %s\n" "DB auto-dump:" "$([[ "${AUTO_DUMP_DATABASES:-true}" == "true" ]] && echo "${C_GREEN}ON${C_RESET}" || echo "${C_DIM}OFF${C_RESET}")"
printf "  %-22s %s\n" "Notifications:" "${NOTIFY_ON:-error}"

# A short notification checklist
notif_setup=""
notify_configured telegram && notif_setup+=" Telegram"
notify_configured webhook  && notif_setup+=" Webhook($(webhook_format))"
notify_configured email    && notif_setup+=" Email"
[[ -n "$notif_setup" ]] && printf "  %-22s %s\n" "  Channels:" "$notif_setup"

echo

# ==============================================================================
# 6. HOST RESOURCES
# ==============================================================================
echo "${C_BOLD}${C_CYAN}━━━ Resources ━━━${C_RESET}"

# Disk
if [[ -d "${WORK_DIR:-/var/tmp/docker-backup}" ]]; then
    disk_info=$(df -h "${WORK_DIR}" 2>/dev/null | tail -1)
    avail=$(echo "$disk_info" | awk '{print $4}')
    used_pct=$(echo "$disk_info" | awk '{print $5}' | tr -d '%')

    if (( used_pct < 80 )); then
        dot=$(status_dot ok)
    elif (( used_pct < 90 )); then
        dot=$(status_dot warn)
    else
        dot=$(status_dot err)
    fi
    echo "  $dot Free ($WORK_DIR):  $avail (${used_pct}% used)"
fi

# Lock — an atomic .d directory with the PID inside
_LOCK_DIR="${LOCK_FILE:-/var/run/docker-backup.lock}.d"
_lock_pid=""
[[ -d "$_LOCK_DIR" ]] && _lock_pid=$(cat "$_LOCK_DIR/pid" 2>/dev/null || echo "")

if [[ "$_lock_pid" =~ ^[0-9]+$ ]]; then
    if kill -0 "$_lock_pid" 2>/dev/null; then
        echo "  $(status_dot warn) The lock is active — a backup IS RUNNING NOW (PID: $_lock_pid)"
    else
        echo "  $(status_dot warn) A lock is left from a previous run (PID: $_lock_pid is not running)"
        echo "    Remove: sudo rm -rf $_LOCK_DIR"
    fi
fi

# Active docker-backup-s3 processes (excluding the current status.sh process)
# pgrep returns exit 1 if nothing is found — hence the || true
set +e +o pipefail
active_procs=$(pgrep -f "docker-backup\.sh" 2>/dev/null | wc -l)
set -e -o pipefail
active_procs="${active_procs:-0}"
if (( active_procs > 0 )); then
    echo "  $(status_dot warn) Active docker-backup-s3 processes: $active_procs"
fi

echo

# ==============================================================================
# 7. LOGS — the last lines
# ==============================================================================
echo "${C_BOLD}${C_CYAN}━━━ Latest log entries ━━━${C_RESET}"

for log_path in "${LOG_FILE:-/var/log/docker-backup.log}" /var/log/docker-backup-cron.log; do
    if [[ -f "$log_path" ]]; then
        size=$(stat -c %s "$log_path" 2>/dev/null || echo 0)
        last_modified=$(stat -c %Y "$log_path" 2>/dev/null || echo 0)
        # Right after logrotate the log is empty: the last run is in the part moved aside (log_generations)
        # Separators and empty lines say nothing; a finished run is shown by its result line, not by "Time: …"
        last_line=$(log_generations "$log_path" | sed 's/\x1b\[[0-9;]*m//g' \
            | grep -vE '^(\[[0-9: -]+\])?[[:space:]=━─]*$' | tail -n 5 \
            | awk '/Backup finished/ { r = $0; next } !/^\[[^]]*\]     [A-Z][a-z]+: / { r = "" } { l = $0 }
                   END { print (r != "" ? r : l) }' || true)
        rotated=""
        [[ "$size" -eq 0 && ( -f "$log_path.1" || -f "$log_path.1.gz" ) ]] \
            && rotated=", just rotated: the lines below are from ${log_path##*/}.1"

        echo "  ${C_BOLD}$log_path${C_RESET}  ($(human_size "$size"), modified $(age_human "$last_modified")${rotated})"
        if [[ -n "$last_line" ]]; then
            # Trim a long line
            if (( ${#last_line} > 90 )); then
                last_line="${last_line:0:87}..."
            fi
            echo "    ${C_DIM}└ $last_line${C_RESET}"
        fi

        # Recent errors (last 100 lines). Not a bare "fail": "2 succeeded, 0 failed" is not an error.
        recent_errors=$(log_generations "$log_path" | tail -100 | grep -E -- "$LOG_ERRORS_RE" | tail -3 || true)
        if [[ -n "$recent_errors" ]]; then
            echo "    ${C_RED}Recent errors:${C_RESET}"
            while IFS= read -r line; do
                if (( ${#line} > 90 )); then
                    line="${line:0:87}..."
                fi
                echo "      ${C_RED}$line${C_RESET}"
            done <<< "$recent_errors"
        fi
    fi
done

echo
echo "${C_DIM}More: sudo $SCRIPT_DIR/logs.sh${C_RESET}"
echo
