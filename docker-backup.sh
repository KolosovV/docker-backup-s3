#!/usr/bin/env bash
# ==============================================================================
# docker-backup.sh
# Backs up all Docker containers, their volumes and compose projects to S3-compatible storage.
#
# Features:
#   - parallel volume backup
#   - pre/post hooks in the project folder (for pg_dump and the like)
#   - GPG encryption of archives
#   - integrity check after upload
#   - lock against a double start
#   - free space check
#   - bandwidth limit
#   - notifications (Telegram + webhook)
#   - dry-run mode
#   - colored output
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/backup.conf"
# DRY_RUN=true in the environment works like --dry-run (as --help says)
DRY_RUN="${DRY_RUN:-false}"
PROJECT_FILTER=""
LIST_ONLY="false"

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config) CONFIG_FILE="$2"; shift 2 ;;
        -n|--dry-run) DRY_RUN="true"; shift ;;
        -p|--project) PROJECT_FILTER="$2"; shift 2 ;;
        -l|--list) LIST_ONLY="true"; DRY_RUN="true"; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [options]
  -c, --config FILE   path to the config file (default: backup.conf next to the script)
  -n, --dry-run       run without real actions (shows the plan, does nothing)
  -p, --project NAME  back up only the given project (several, comma-separated);
                      db:NAME — a remote database from REMOTE_DBS
  -l, --list          print the names of the compose projects found on this host and exit
  -h, --help          this help

ENV variables (for debugging):
  DRY_RUN=true        same as --dry-run

EXAMPLES:
  Back up all projects:    $0
  Only one project:        $0 -p myapp
  Several projects:        $0 -p myapp,otherapp
  One remote database:     $0 -p db:shop
  Dry run:                 $0 --dry-run
  One project, dry run:    $0 -p myapp --dry-run
EOF
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

[[ -f "$CONFIG_FILE" ]] || { echo "❌ Config not found: $CONFIG_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Load the library
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

# --- Logging to a file ---
# --list only prints project names (for the menu) — it does not belong in the backup log,
# and its scan messages are not shown
if [[ "$LIST_ONLY" == "true" ]]; then
    exec 2>/dev/null
else
    mkdir -p "$(dirname "$LOG_FILE")"
    # Duplicate stderr (logs) to the file, filtering out SSL warnings.
    # --line-buffered, and _on_exit waits for this pipe: under systemd the service's leftover processes are
    # killed the moment the script exits, and whatever grep still held in its buffer (the summary) was lost.
    # The pipe runs in its own session (setsid): Ctrl+C reaches the whole process group, and the pipe used to die
    # first — then the "interrupted" lines went nowhere, and the write killed the handler. "trap ''" alone does not
    # protect it: bash 5.3 lets the signal kill tee anyway. It ends on its own when the script closes stderr.
    _log_noise='InsecureRequestWarning|urllib3/connectionpool|certificate verification is strongly advised'
    _setsid=(); command -v setsid >/dev/null 2>&1 && _setsid=(setsid)
    exec 2> >(exec ${_setsid[@]+"${_setsid[@]}"} bash -c 'trap "" INT TERM HUP
        tee -a >(grep --line-buffered -v -E "$1" >> "$2") | grep --line-buffered -v -E "$1" >&2' _ "$_log_noise" "$LOG_FILE")
    LOG_PIPE_PID=$!
    # A spare handle on the log pipe: a signal can arrive while stderr is redirected elsewhere for one
    # command (aws_q sends aws's stderr through its own filter, which Ctrl+C kills). _on_exit goes back to this
    # handle, or its "interrupted" lines would go nowhere.
    exec {LOG_FD}>&2
fi

# --- Dependency check ---
require_cmd docker tar gzip aws jq
[[ "${ENCRYPT_BACKUPS:-false}" == "true" ]] && require_cmd gpg

# Settings that silently do the wrong thing — in the log now and in this run's notification (CONF_WARNINGS, HTML).
# Encryption found off with the passphrase in place is the case this is here for.
CONF_WARNINGS=""
if [[ "${ENCRYPT_BACKUPS:-false}" != "true" && -f "${GPG_PASSPHRASE_FILE:-/root/.docker-backup-passphrase}" ]]; then
    log_warn "Encryption is OFF (ENCRYPT_BACKUPS=${ENCRYPT_BACKUPS:-}), but ${GPG_PASSPHRASE_FILE:-/root/.docker-backup-passphrase} exists — backups go unencrypted"
    CONF_WARNINGS+="${CONF_WARNINGS:+$'\n'}⚠️ <b>Encryption is off</b> (ENCRYPT_BACKUPS=$(html_esc "${ENCRYPT_BACKUPS:-}")), although the passphrase file <code>$(html_esc "${GPG_PASSPHRASE_FILE:-/root/.docker-backup-passphrase}")</code> exists: these backups are not encrypted."
fi
# A setting of the user's overridden by a template default further down (see conf_duplicates)
while IFS=$'\t' read -r _dup _ll _lv _el _ev _lost; do
    [[ "$_lost" == "1" ]] || continue
    log_warn "$_dup: your ${_ev} (line ${_el} of $CONFIG_FILE) is overridden by the default ${_lv} further down (line ${_ll})"
    CONF_WARNINGS+="${CONF_WARNINGS:+$'\n'}⚠️ <code>$(html_esc "$_dup")</code>: your <code>$(html_esc "$_ev")</code> (line ${_el} of backup.conf) is overridden by the default <code>$(html_esc "$_lv")</code> further down (line ${_ll}), so the default is used."
done < <(conf_duplicates "$CONFIG_FILE" "${SCRIPT_DIR}/backup.conf.example")
{ notify_configured telegram || notify_configured webhook || notify_configured email; } && require_cmd curl

# --- Emergency exit ---
# Which project is currently stopped/paused. Needed to bring its containers back
# on any exit: on error, on Ctrl+C, on kill/OOM. There used to be
# a "trap ... ERR" inside backup_project, but it never fired — the function
# is called inside an "if" condition, where set -e is suppressed, and so is the ERR trap.
PAUSED_PROJECT=""
PAUSED_DIR=""

_resume_paused_project() {
    [[ -z "$PAUSED_PROJECT" ]] && return 0
    log_warn "Bringing back the containers of project $PAUSED_PROJECT after an emergency exit"
    resume_project "$PAUSED_PROJECT" "$PAUSED_DIR" || true
    PAUSED_PROJECT=""
    PAUSED_DIR=""
}

# The backup broke off (script error, Ctrl+C, kill, server shutdown) — say so right away. Otherwise
# only an external monitor would notice, a day later, as "did not run", and an interrupted run would look
# like a hanging one. A failed pre-start check (space, S3 access) reports on its own; a signal during the
# checks does not, so a signal is reported at any stage.
_on_exit() {
    # No death by SIGPIPE while cleaning up, and stderr back on the log pipe — before writing anything
    trap '' PIPE
    [[ -n "${LOG_FD:-}" ]] && exec 2>&"$LOG_FD"
    _resume_paused_project
    # A remote database's client container, if the run broke off during its dump
    [[ -n "${RDB_CNAME:-}" ]] && { docker rm -f "$RDB_CNAME" >/dev/null 2>&1 || true; }
    release_lock
    if [[ "${RUN_DONE:-false}" != "true" ]] && [[ "${RUN_STARTED:-false}" == "true" || -n "${INTERRUPT_SIGNAL:-}" ]]; then
        RUN_DONE=true
        local body="" step="${LAST_STEP:-}"
        step="${step#"${step%%[![:space:]]*}"}"
        if [[ -n "${INTERRUPT_SIGNAL:-}" ]]; then
            body+="Stopped by signal ${INTERRUPT_SIGNAL} (Ctrl+C, a shutdown or a kill)${step:+ at: $(html_esc "$step")}."$'\n'
        fi
        case "${CURRENT_PROJECT:-}" in
            "") ;;
            "database "*) body+="Interrupted on the remote <b>$(html_esc "$CURRENT_PROJECT")</b>: its dump of this run is not complete (the next full run clears what was uploaded of it)."$'\n' ;;
            *) body+="Interrupted on project <b>$(html_esc "$CURRENT_PROJECT")</b>, its containers were brought back."$'\n' ;;
        esac
        if [[ "${RUN_STARTED:-false}" == "true" ]]; then body+="Some projects were not saved."
        else body+="It stopped before the first project: nothing was saved in this run."; fi
        log_err "Backup interrupted${INTERRUPT_SIGNAL:+ (signal ${INTERRUPT_SIGNAL})}${step:+ at: ${step}}"
        notify error "backup interrupted" "${body}"$'\n'"$(notify_log_hint)"
    fi
    # Half-made archives of this run are of no use, and they take space
    [[ -n "${BACKUP_ROOT:-}" && -d "$BACKUP_ROOT" ]] && rm -rf "$BACKUP_ROOT"
    # Let the log pipe finish writing: close our end, wait for it (see "Logging to a file")
    # Up to 5 s, not a plain "wait": after a signal bash may still hold another copy of the pipe (seen as fd 11),
    # so the pipe never sees its end and the two would wait for each other forever. Lines are passed on one
    # at a time, so by now they are written; the pipe ends by itself once this process is gone.
    if [[ -n "${LOG_PIPE_PID:-}" ]]; then
        exec 2>&- {LOG_FD}>&-
        local _i
        for _i in $(seq 1 50); do
            kill -0 "$LOG_PIPE_PID" 2>/dev/null || break
            sleep 0.1
        done
    fi
}

_on_signal() {
    INTERRUPT_SIGNAL="$1"   # _on_exit (the EXIT trap) logs it and sends the notification
    # The signal may have come while stderr went into one command's own filter, which Ctrl+C just killed:
    # the next write there would kill the script by SIGPIPE (bash 5.3 does) before the EXIT trap ever runs
    trap '' PIPE
    [[ -n "${LOG_FD:-}" ]] && exec 2>&"$LOG_FD"
    _resume_paused_project
    release_lock
    exit 130
}

# --- Lock ---
if [[ "$DRY_RUN" != "true" ]]; then
    acquire_lock "$LOCK_FILE"
    trap '_on_exit' EXIT
    trap '_on_signal INT' INT
    trap '_on_signal TERM' TERM
    trap '_on_signal HUP' HUP
fi

# --- AWS CLI ---
_aws_setup primary

# --- Default bind-mount blacklist ---
: "${BIND_BLACKLIST_REGEX:=^/$|^/proc|^/sys|^/dev|^/var/run|^/run|^/var/lib/docker|^/lib/modules|^/etc/localtime|^/etc/timezone|\.sock$}"
# --- Subfolders inside a bind mount NOT to back up (the bind itself is backed up) ---
: "${BIND_EXCLUDE_PATHS:=}"

# --- Compression level (1-9) for every archive this script creates ---
[[ "${COMPRESS_LEVEL:-6}" =~ ^[1-9]$ ]] || COMPRESS_LEVEL=6

# tar_gz <archive> <tar arguments…> — tar | gzip at COMPRESS_LEVEL. A pipe rather than
# --use-compress-program="gzip -N": tar before 1.27 (RHEL 7) can't pass options to the program.
# Returns tar's code (0 ok, 1 files changed while being read, ≥2 error); a gzip failure counts as 2.
# Sockets can't be archived (a program recreates them on start): "socket ignored" is noise in the log, and
# --errors showed it. GNU tar is told not to say it; a tar without --warning just says it.
TAR_QUIET=()
tar --warning=no-file-ignored -cf /dev/null --files-from /dev/null 2>/dev/null && TAR_QUIET=(--warning=no-file-ignored)
tar_gz() {
    local out="$1"; shift
    local -a st
    tar ${TAR_QUIET[@]+"${TAR_QUIET[@]}"} -cf - "$@" | gzip -"$COMPRESS_LEVEL" > "$out"
    st=("${PIPESTATUS[@]}")
    (( st[1] == 0 )) || return 2
    return "${st[0]}"
}

# --- Timestamp for all files of this session ---
TIMESTAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
BACKUP_ROOT="${WORK_DIR}/${TIMESTAMP}"
SESSION_START=$(date +%s)

# Global statistics
TOTAL_PROJECTS=0
TOTAL_SUCCESS=0
TOTAL_FAILED=0
declare -a FAILED_PROJECTS=()
TOTAL_UPLOADED_BYTES=0
# For the final message: what did not reach each copy (secondary, tertiary) when it is optional
# (this used to be only in the log — the second storage could silently stay empty), and why.
# COPY_FAILED[role] — projects, newline-separated; COPY_DOWN[role] — why the copy is unavailable altogether.
declare -A COPY_FAILED=()
declare -A COPY_DOWN=()
declare -A ORPHAN_DROPPED=()   # project no longer on the server → how many of its objects rotation deleted
CURRENT_PROJECT=""
RUN_STARTED=false
RUN_DONE=false

# Everything this run writes is the projects' data: .env files, docker inspect with the containers'
# environment (their passwords too), database dumps. Only root reads it: files 600, folders 700.
umask 077
work_dir_ready || { log_err "$WORK_DIR_ERR"; exit 1; }
mkdir -p "$BACKUP_ROOT"
chmod 700 "$BACKUP_ROOT"

log "${C_BOLD}${C_BLUE}===================================================================${C_RESET}"
log "${C_BOLD}🚀 Starting Docker backup. Timestamp: ${TIMESTAMP}${C_RESET}"
[[ "$DRY_RUN" == "true" ]] && log "${C_YELLOW}${C_BOLD}🧪 DRY-RUN: no real actions are performed${C_RESET}"
[[ -n "$PROJECT_FILTER" ]] && log "${C_CYAN}${C_BOLD}🎯 Filter: $PROJECT_FILTER${C_RESET}"

# The work folders of earlier runs. A run removes its own on exit, but not when it is killed with -9 or the
# server goes down mid-run: then the folder stays, with archives of every project in it. Only a backup makes
# such folders, and it holds the lock, so no other run is using them. The folders of a restore, a check, a sync
# and a remote database dump (restore.*, verify.*, sync.*, remote-db.*) may be in use right now: those go only
# after a day.
if [[ "$DRY_RUN" != "true" ]]; then
    while IFS= read -r -d '' stale; do
        log_warn "Removing the work folder of an unfinished run: $stale ($(du -sh "$stale" 2>/dev/null | cut -f1))"
        rm -rf "$stale"
    done < <(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d \
        \( -name '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]-[0-9][0-9]-[0-9][0-9]' ! -path "$BACKUP_ROOT" \
           -o \( -name 'restore.*' -o -name 'verify.*' -o -name 'sync.*' -o -name 'remote-db.*' \) -mmin +1440 \) \
        -print0 2>/dev/null)
fi
log "${C_BOLD}${C_BLUE}===================================================================${C_RESET}"

# ==============================================================================
# Helper: bind-mount blacklist check
# ==============================================================================
is_bind_blacklisted() {
    local path="$1"
    [[ -z "${BIND_BLACKLIST_REGEX:-}" ]] && return 1
    echo "$path" | grep -Eq "$BIND_BLACKLIST_REGEX"
}

# ==============================================================================
# 1. FINDING ALL COMPOSE PROJECTS
# ==============================================================================
declare -A PROJECTS=()

log_step "🔍 Scanning compose projects..."

# 1a) Via docker labels
while IFS=$'\t' read -r project workdir; do
    [[ -z "$project" ]] && continue
    [[ -z "$workdir" || "$workdir" == "<no value>" ]] && continue
    [[ -d "$workdir" ]] || { log_warn "Project directory of '$project' does not exist: $workdir"; continue; }
    PROJECTS["$project"]="$workdir"
    log_ok "From labels: $project -> $workdir"
done < <(docker ps -a --format '{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.project.working_dir"}}' | sort -u)

# 1b) By scanning directories
if [[ -n "${SCAN_DIRS:-}" ]]; then
    # split_words, not "for dir in $SCAN_DIRS": IFS=$'\n\t' has no space,
    # so the string "/opt /home /root /srv" would arrive as a single "directory"
    # and the scan would silently find nothing.
    declare -a SCAN_DIR_LIST=()
    mapfile -t SCAN_DIR_LIST < <(split_words "$SCAN_DIRS")
    for dir in ${SCAN_DIR_LIST[@]+"${SCAN_DIR_LIST[@]}"}; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r -d '' compose_file; do
            project_dir="$(dirname "$compose_file")"
            project_name="$(basename "$project_dir")"
            # The folder was already found by labels — don't take it again, even under another name. mailcow
            # names the project mailcowdockerized (COMPOSE_PROJECT_NAME), while the folder is mailcow-dockerized:
            # matching by name only gave a second archive of the same folder, without a single container.
            known_dir=false
            for p in "${!PROJECTS[@]}"; do
                if [[ "$(realpath -m "${PROJECTS[$p]}")" == "$(realpath -m "$project_dir")" ]]; then
                    known_dir=true
                    break
                fi
            done
            $known_dir && continue
            if [[ -z "${PROJECTS[$project_name]:-}" ]]; then
                PROJECTS["$project_name"]="$project_dir"
                log_ok "Found by scanning: $project_name -> $project_dir"
            fi
        done < <(find "$dir" -maxdepth 4 \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' -o -name 'compose.yml' -o -name 'compose.yaml' \) -print0 2>/dev/null)
    done
fi

# 1c) Standalone containers (BACKUP_STANDALONE=false — none; the label docker-backup-s3.skip=true — not this one)
STANDALONE_CONTAINERS=()
if [[ "${BACKUP_STANDALONE:-true}" == "true" ]]; then
    while IFS= read -r cid; do
        [[ -z "$cid" ]] && continue
        labels="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}|{{ index .Config.Labels "docker-backup-s3.skip" }}' "$cid" 2>/dev/null || true)"
        [[ -n "${labels%%|*}" ]] && continue
        if [[ "${labels#*|}" == "true" ]]; then
            log "  ⊘ Skipped (label docker-backup-s3.skip=true): $(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's#^/##')"
            continue
        fi
        STANDALONE_CONTAINERS+=("$cid")
    done < <(docker ps -aq)
fi

log "📦 Compose projects found: ${C_BOLD}${#PROJECTS[@]}${C_RESET}"
log "📦 Standalone containers: ${C_BOLD}${#STANDALONE_CONTAINERS[@]}${C_RESET}"

# 1d) Remote databases (REMOTE_DBS). A name given twice, or two names with the same settings (shop-db and
# shop_db both read REMOTE_DB_SHOP_DB_*), are backed up once.
declare -a REMOTE_LIST=()
declare -A _rdb_seen=()
while IFS= read -r n; do
    [[ -z "$n" ]] && continue
    k="$(remote_db_key "$n")"
    if [[ -n "${_rdb_seen[$k]:-}" ]]; then
        [[ "${_rdb_seen[$k]}" != "$n" ]] && log_warn "REMOTE_DBS: $n and ${_rdb_seen[$k]} share the settings REMOTE_DB_${k}_* — backing up ${_rdb_seen[$k]} only"
        continue
    fi
    _rdb_seen[$k]="$n"
    REMOTE_LIST+=("$n")
done < <(remote_db_names)
(( ${#REMOTE_LIST[@]} )) && log "🗄  Remote databases: ${C_BOLD}${#REMOTE_LIST[@]}${C_RESET}"

# --- Apply the --project filter if given ---
if [[ -n "$PROJECT_FILTER" ]]; then
    log "${C_CYAN}🎯 Project filter: ${C_BOLD}$PROJECT_FILTER${C_RESET}"

    # Parse the comma-separated project list
    # db:NAME (or _db_NAME, as in the storage) — a remote database
    declare -A REQUESTED=() REQUESTED_DB=()
    IFS=',' read -ra _requested_arr <<< "$PROJECT_FILTER"
    for p in "${_requested_arr[@]}"; do
        p="${p// /}"  # trim spaces
        case "$p" in
            "") ;;
            db:*)  REQUESTED_DB["${p#db:}"]=1 ;;
            _db_*) REQUESTED_DB["${p#_db_}"]=1 ;;
            *)     REQUESTED["$p"]=1 ;;
        esac
    done

    # Filter PROJECTS — keep only the requested ones
    declare -A FILTERED_PROJECTS=()
    for proj in "${!PROJECTS[@]}"; do
        if [[ -n "${REQUESTED[$proj]:-}" ]]; then
            FILTERED_PROJECTS["$proj"]="${PROJECTS[$proj]}"
        fi
    done

    # Check that all requested projects were found
    declare -a NOT_FOUND=()
    for p in "${!REQUESTED[@]}"; do
        if [[ -z "${PROJECTS[$p]:-}" ]]; then
            NOT_FOUND+=("$p")
        fi
    done
    declare -a FILTERED_REMOTE=()
    for p in ${REMOTE_LIST[@]+"${REMOTE_LIST[@]}"}; do
        [[ -n "${REQUESTED_DB[$p]:-}" ]] && FILTERED_REMOTE+=("$p")
    done
    for p in "${!REQUESTED_DB[@]}"; do
        printf '%s\n' ${REMOTE_LIST[@]+"${REMOTE_LIST[@]}"} | grep -qxF -- "$p" || NOT_FOUND+=("db:$p")
    done

    if [[ ${#NOT_FOUND[@]} -gt 0 ]]; then
        log_err "Projects not found: $(join_list "${NOT_FOUND[@]}")"
        log "    Projects available on this host:"
        if [[ ${#PROJECTS[@]} -gt 0 ]]; then
            for p in "${!PROJECTS[@]}"; do
                log "      • $p"
            done
        else
            log "      (no compose projects on this host)"
        fi
        for p in ${REMOTE_LIST[@]+"${REMOTE_LIST[@]}"}; do log "      • db:$p  (remote database)"; done
        fail "Stopping — the requested projects were not found"
    fi
    REMOTE_LIST=(${FILTERED_REMOTE[@]+"${FILTERED_REMOTE[@]}"})

    # Replace PROJECTS with the filtered list
    unset PROJECTS
    declare -A PROJECTS=()
    for proj in "${!FILTERED_PROJECTS[@]}"; do
        PROJECTS["$proj"]="${FILTERED_PROJECTS[$proj]}"
    done

    # Standalone containers are skipped when filtering
    STANDALONE_CONTAINERS=()

    log_ok "After filtering — projects to back up: ${C_BOLD}${#PROJECTS[@]}${C_RESET}, remote databases: ${C_BOLD}${#REMOTE_LIST[@]}${C_RESET}"
fi

# --list: project names, one per line, and exit
if [[ "$LIST_ONLY" == "true" ]]; then
    ((${#PROJECTS[@]})) && printf '%s\n' "${!PROJECTS[@]}" | sort
    rm -rf "$BACKUP_ROOT"
    exit 0
fi

# --- EXCLUDE_PROJECTS: left out of this run (after --list: the menu offers every project found) ---
# Asked for by name with -p — backed up anyway. Their backups stay in the storages: rotation counts them as
# live projects (EXCLUDED goes into ROTATION_LIVE_PROJECTS), so their last copies are never deleted.
declare -A EXCLUDED=()
if [[ -n "${EXCLUDE_PROJECTS:-}" ]]; then
    for proj in "${!PROJECTS[@]}"; do
        in_project_list "$proj" "$EXCLUDE_PROJECTS" || continue
        if [[ -n "$PROJECT_FILTER" ]]; then
            log_info "$proj is in EXCLUDE_PROJECTS, but asked for with -p: backing it up"
            continue
        fi
        EXCLUDED["$proj"]="${PROJECTS[$proj]}"
        unset 'PROJECTS[$proj]'
    done
    if (( ${#EXCLUDED[@]} )); then
        mapfile -t _excluded < <(printf '%s\n' "${!EXCLUDED[@]}" | sort)
        log "⊘ Left out (EXCLUDE_PROJECTS): $(join_list "${_excluded[@]}")"
    fi
fi

# ==============================================================================
# DRY-RUN: show the plan and exit
# ==============================================================================
if [[ "$DRY_RUN" == "true" ]]; then
    log ""
    log "${C_YELLOW}${C_BOLD}━━━━━━━━━━━━━━━ PLAN (not executed) ━━━━━━━━━━━━━━━${C_RESET}"
    if (( ${#PROJECTS[@]} == 0 )); then
        log "${C_DIM}No compose projects found on this host${C_RESET}"
    else
    for proj in "${!PROJECTS[@]}"; do
        log ""
        log "${C_CYAN}📦 ${proj}${C_RESET}  (${PROJECTS[$proj]})"

        # Volumes
        local_vols="$(docker ps -aq --filter "label=com.docker.compose.project=$proj" \
            | xargs -r docker inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' \
            | sort -u | grep -v '^$' || true)"
        if [[ -n "$local_vols" ]]; then
            log "   Volumes:"
            while IFS= read -r v; do log "     - $v"; done <<< "$local_vols"
        fi

        # Bind-mounts
        local_binds="$(docker ps -aq --filter "label=com.docker.compose.project=$proj" \
            | xargs -r docker inspect --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{"\n"}}{{end}}{{end}}' \
            | sort -u | grep -v '^$' || true)"
        if [[ -n "$local_binds" ]]; then
            log "   Bind-mounts:"
            while IFS= read -r b; do
                if is_bind_blacklisted "$b" || path_within "$b" "${PROJECTS[$proj]}"; then
                    log "     ${C_DIM}- $b (skipped)${C_RESET}"
                else
                    # BIND_EXCLUDE_PATHS that fall inside this bind — shown, so the plan says what really goes in
                    plan_excl=(); plan_in=()
                    mapfile -t plan_excl < <(split_words "${BIND_EXCLUDE_PATHS:-}")
                    for x in ${plan_excl[@]+"${plan_excl[@]}"}; do path_within "$x" "$b" && plan_in+=("$x"); done
                    if (( ${#plan_in[@]} )); then
                        log "     - $b ${C_DIM}(without $(printf '%s, ' "${plan_in[@]}" | sed 's/, $//'))${C_RESET}"
                    else
                        log "     - $b"
                    fi
                fi
            done <<< "$local_binds"
        fi

        # Hook
        for h in pre-backup-hook.sh post-backup-hook.sh; do
            [[ -x "${PROJECTS[$proj]}/$h" ]] || continue
            if hook_trusted "${PROJECTS[$proj]}/$h"; then log "   ${C_GREEN}↳ $h will be run${C_RESET}"
            else log_warn "   $h will NOT be run: $HOOK_ERR"; fi
        done

        # Database auto-dump
        if [[ "${AUTO_DUMP_DATABASES:-true}" == "true" ]] && in_project_list "$proj" "${DB_DUMP_EXCLUDE_PROJECTS:-}"; then
            log "   ${C_DIM}Database dumps: off for this project (DB_DUMP_EXCLUDE_PROJECTS)${C_RESET}"
        elif [[ "${AUTO_DUMP_DATABASES:-true}" == "true" ]]; then
            local_dbs=()
            while IFS= read -r cid; do
                [[ -z "$cid" ]] && continue
                cimg=$(docker inspect --format '{{.Config.Image}}' "$cid" 2>/dev/null || true)
                cname=$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||' || true)
                cstate=$(docker inspect --format '{{.State.Status}}' "$cid" 2>/dev/null || true)
                dtype=$(detect_db_type "$cimg")
                if [[ -n "$dtype" ]]; then
                    if db_dump_skipped "$cid"; then
                        local_dbs+=("     ${C_DIM}🗄  $dtype: $cname (label docker-backup-s3.skip=true, no dump)${C_RESET}")
                    elif [[ "$cstate" == "running" ]]; then
                        local_dbs+=("     ${C_MAGENTA}🗄${C_RESET}  $dtype: $cname (image: $cimg)")
                    else
                        local_dbs+=("     ${C_DIM}🗄  $dtype: $cname (state=$cstate, dump skipped)${C_RESET}")
                    fi
                fi
            done < <(docker ps -aq --filter "label=com.docker.compose.project=$proj")
            if (( ${#local_dbs[@]} )); then
                log "   Database auto-dump:"
                for l in "${local_dbs[@]}"; do log "$l"; done
            fi
        fi
    done
    fi  # if PROJECTS not empty

    if [[ ${#STANDALONE_CONTAINERS[@]} -gt 0 ]]; then
        log ""
        log "${C_CYAN}📦 Standalone containers:${C_RESET}"
        for cid in "${STANDALONE_CONTAINERS[@]}"; do
            cname="$(docker inspect --format '{{.Name}}' "$cid" | sed 's|^/||')"
            log "   - $cname"
        done
    fi

    if (( ${#REMOTE_LIST[@]} )); then
        log ""
        log "${C_CYAN}🗄  Remote databases (dumped straight into the primary S3):${C_RESET}"
        for n in "${REMOTE_LIST[@]}"; do
            if problems="$(remote_db_check "$n")"; then
                log "   - $n: $(remote_db_desc "$n")"
            else
                log "   ${C_RED}- $n: the settings are not complete${C_RESET}"
                while IFS= read -r p; do log "       $p"; done <<< "$problems"
            fi
        done
    fi

    log ""
    log "Encryption:    ${ENCRYPT_BACKUPS}"
    log "Bandwidth:     ${S3_BANDWIDTH_LIMIT:-no limit}"
    log "Parallel jobs: ${PARALLEL_JOBS}"
    log "Retention:     ${RETENTION_DAYS} days"
    log "Primary S3:    ${PRIMARY_S3_ENDPOINT:-?}, bucket=${PRIMARY_S3_BUCKET:-?}"
    for role in "${S3_ROLES[@]:1}"; do
        if s3_enabled "$role"; then
            log "$(printf '%-15s' "$(s3_label "$role" title):")enabled ($(s3_var "$role" ENDPOINT)), bucket=$(s3_var "$role" BUCKET), required=$(s3_var "$role" REQUIRED)"
        else
            log "$(printf '%-15s' "$(s3_label "$role" title):")disabled"
        fi
    done
    log "DB auto-dump:  ${AUTO_DUMP_DATABASES:-true} (Pg=${AUTO_DUMP_POSTGRES:-true}, MySQL=${AUTO_DUMP_MYSQL:-true}, Redis=${AUTO_DUMP_REDIS:-true}, Mongo=${AUTO_DUMP_MONGO:-true})"

    log ""
    log "${C_YELLOW}${C_BOLD}━━━━━━━━━━━━━━━ DRY-RUN END ━━━━━━━━━━━━━━━${C_RESET}"
    rm -rf "$BACKUP_ROOT"
    exit 0
fi

# ==============================================================================
# Free space check
# ==============================================================================
check_free_space "$WORK_DIR" "${MIN_FREE_SPACE_MB:-1024}" \
    || { notify error "backup did not start" "Low disk space in $(html_esc "$WORK_DIR"): at least ${MIN_FREE_SPACE_MB:-1024} MB free is required. Check: <code>df -h $(html_esc "$WORK_DIR")</code>."; fail "Not enough space"; }

# ==============================================================================
# S3 access check
# ==============================================================================
log_step "🔌 Checking access to the primary S3..."
aws_q s3 ls "s3://${PRIMARY_S3_BUCKET}" >/dev/null 2>&1 \
    || { notify error "backup did not start" "No access to the primary storage $(html_esc "$(s3_host "$PRIMARY_S3_ENDPOINT")"), bucket $(html_esc "$PRIMARY_S3_BUCKET"). Check the key and bucket: <code>$(html_esc "$SCRIPT_DIR")/diagnose-s3.sh</code>."; fail "Cannot access bucket ${PRIMARY_S3_BUCKET}. Create the bucket in your S3 provider's panel and check the key/endpoint."; }
log_ok "Primary S3 is reachable"

# Copies (secondary, tertiary), if enabled. A required one unavailable — the backup does not start;
# an optional one — remember why (COPY_DOWN) and upload whatever works.
for role in ${S3_COPIES[@]+"${S3_COPIES[@]}"}; do
    label="$(s3_label "$role" title)"; var="${role^^}_S3"
    if ! s3_complete "$role"; then
        msg="${label} is enabled, but not all ${var}_* are filled in"
        if s3_required "$role"; then
            notify error "backup did not start" "${label} is required (${var}_REQUIRED=true), but some of its ${var}_* settings in backup.conf are empty."
            fail "$msg (and ${var}_REQUIRED=true)"
        fi
        COPY_DOWN[$role]="is not configured: some of its ${var}_* settings in backup.conf are empty"
        log_warn "$msg — uploads $(s3_label "$role" to) will be skipped"
        continue
    fi
    log_step "🔌 Checking access: ${label}..."
    _aws_setup "$role"
    if aws_q s3 ls "s3://${S3_CUR_BUCKET}" >/dev/null 2>&1; then
        log_ok "${label} is reachable"
    else
        msg="${label}: no access to bucket ${S3_CUR_BUCKET}. Create the bucket in the provider's panel and check the key/endpoint."
        if s3_required "$role"; then
            notify error "backup did not start" "No access to storage $(html_esc "$(s3_host "$S3_CUR_ENDPOINT")") (${label}), bucket $(html_esc "$S3_CUR_BUCKET"), and it is required (${var}_REQUIRED=true). Check: <code>$(html_esc "$SCRIPT_DIR")/diagnose-s3.sh</code>."
            fail "$msg"
        fi
        COPY_DOWN[$role]="did not respond to the access check before the backup"
        log_warn "$msg — uploads $(s3_label "$role" to) will be skipped or fail"
    fi
    _aws_setup primary
done

# ==============================================================================
# 2. PAUSE/RESUME FUNCTIONS
# ==============================================================================
pause_project() {
    local proj="$1"   # $2 (the folder) is not needed: containers are found by the label
    case "$BACKUP_MODE" in
        stop)
            # By the project's label, like pause — not "cd dir && compose stop": that misses a project started
            # under another name (-p, name:) — "compose stop" in the folder would act on another project. Only the containers
            # that were running are stopped, and exactly those are started again.
            log "  ${C_YELLOW}⏸${C_RESET}  docker stop on the running containers of project $proj"
            STOPPED_CONTAINERS="$(docker ps -q --filter "label=com.docker.compose.project=$proj" | tr '\n' ' ')"
            if [[ -n "${STOPPED_CONTAINERS// /}" ]]; then
                # shellcheck disable=SC2086 # container IDs, one word each
                (IFS=' '; docker stop $STOPPED_CONTAINERS >/dev/null) || log_warn "Some containers did not stop"
            fi
            ;;
        pause)
            log "  ${C_YELLOW}⏸${C_RESET}  docker pause on the containers of project $proj"
            docker ps -q --filter "label=com.docker.compose.project=$proj" | xargs -r docker pause >/dev/null || log_warn "Some containers did not pause"
            ;;
        hot) : ;;
    esac
}

resume_project() {
    local proj="$1"
    case "$BACKUP_MODE" in
        stop)
            log "  ${C_GREEN}▶${C_RESET}  docker start on the containers stopped for the backup"
            if [[ -n "${STOPPED_CONTAINERS// /}" ]]; then
                # shellcheck disable=SC2086
                (IFS=' '; docker start $STOPPED_CONTAINERS >/dev/null) || log_warn "Some containers did not start"
            fi
            STOPPED_CONTAINERS=""
            ;;
        pause)
            log "  ${C_GREEN}▶${C_RESET}  docker unpause"
            docker ps -q --filter "label=com.docker.compose.project=$proj" --filter "status=paused" | xargs -r docker unpause >/dev/null || true
            ;;
        hot) : ;;
    esac
}

# ==============================================================================
# 3. BACKUP OF ONE VOLUME (run in parallel)
# ==============================================================================
# tar exit codes: 0 — all good, 1 — "files changed while being read"
# (normal for a hot backup, the archive is still created), ≥2 — a real
# error. Any outcome used to be muted with "2>/dev/null" and "|| true", so
# a project with a half-empty archive counted as a success.
# usage: backup_volume <volume> <dest_dir> [fail_marker]
backup_volume() {
    local volume_name="$1" dest_dir="$2" fail_marker="${3:-}"
    log "    💾 Volume: $volume_name"
    local rc=0
    # tar | gzip, and the exit code is tar's (kept in a file — not relying on pipefail in busybox sh),
    # so a tar error is not hidden behind gzip's; a gzip failure counts as 2. The level falls back to
    # gzip's default if this busybox gzip has no -1..-9. "socket ignored" is dropped from tar's
    # messages, as on the host (TAR_QUIET): busybox tar has no option to stay quiet about sockets.
    docker run --rm \
        -v "${volume_name}:/source:ro" \
        -v "${dest_dir}:/backup" \
        -e "LVL=${COMPRESS_LEVEL:-6}" -e "OUT=/backup/volume_${volume_name}.tar.gz" \
        alpine:latest \
        sh -c 'gzip -"$LVL" </dev/null >/dev/null 2>&1 || LVL=""
               cd /source || exit 2
               { tar -cf - . 2>/tmp/tar_err; echo $? > /tmp/tar_rc; } | gzip ${LVL:+-$LVL} > "$OUT" || exit 2
               grep -v ": socket ignored$" /tmp/tar_err >&2
               exit "$(cat /tmp/tar_rc)"' \
        || rc=$?

    case "$rc" in
        0) return 0 ;;
        1)
            log_warn "    Volume $volume_name: files changed while being read — archive created, but the snapshot is not atomic"
            [[ -n "$fail_marker" ]] && echo "warn:volume:${volume_name}" >> "$fail_marker"
            return 0
            ;;
        *)
            log_err "    Could not back up volume $volume_name (tar rc=$rc)"
            [[ -n "$fail_marker" ]] && echo "fail:volume:${volume_name}" >> "$fail_marker"
            return 1
            ;;
    esac
}
export -f backup_volume log log_warn log_err _ts
export C_RESET C_DIM C_YELLOW C_BOLD C_RED C_GREEN C_BLUE C_CYAN C_MAGENTA

# ==============================================================================
# 4. BIND-MOUNT BACKUP
# ==============================================================================
backup_bind_mount() {
    local src="$1" dest_dir="$2" idx="$3" fail_marker="${4:-}"
    if [[ ! -e "$src" ]]; then
        log_err "    Bind source does not exist: $src"
        [[ -n "$fail_marker" ]] && echo "fail:bind_missing:${src}" >> "$fail_marker"
        return 1
    fi
    local safe_name; safe_name="$(echo "$src" | sed 's|/|_|g; s|^_||')"
    local archive="${dest_dir}/bind_${idx}_${safe_name}.tar.gz"
    log "    📁 Bind-mount: $src"
    # Subfolders from BIND_EXCLUDE_PATHS that lie inside this bind: the blacklist only looks at
    # the bind root, and one disk can hold both documents and gigabytes of rebuildable packages.
    local -a excl=() excl_paths=()
    local p base; base="$(basename "$src")"
    # split_words, not "for p in $BIND_EXCLUDE_PATHS": IFS=$'\n\t' has no space (as with SCAN_DIRS)
    mapfile -t excl_paths < <(split_words "${BIND_EXCLUDE_PATHS:-}")
    for p in ${excl_paths[@]+"${excl_paths[@]}"}; do
        p="${p%/}"
        if [[ "$p" == "$src/"* ]]; then
            excl+=(--exclude="${base}/${p#"$src"/}")
            log "      ${C_DIM}⊘ without subfolder: $p${C_RESET}"
        fi
    done
    local rc=0
    tar_gz "$archive" --anchored ${excl[@]+"${excl[@]}"} -C "$(dirname "$src")" "$base" || rc=$?
    case "$rc" in
        0) return 0 ;;
        1)
            log_warn "    Bind $src: files changed while being read — archive created"
            [[ -n "$fail_marker" ]] && echo "warn:bind:${src}" >> "$fail_marker"
            return 0
            ;;
        *)
            log_err "    Could not back up bind $src (tar rc=$rc)"
            [[ -n "$fail_marker" ]] && echo "fail:bind:${src}" >> "$fail_marker"
            return 1
            ;;
    esac
}

# ==============================================================================
# 5. PRE/POST HOOK EXECUTION
# ==============================================================================
# hook_trusted <hook> — a hook runs as root, so only one that no one but root can change: the file and its
# folder are root's, and neither is writable by the group or others. SCAN_DIRS includes /home: without this,
# any user of the host could put a compose file and a pre-backup-hook.sh in their home folder and have it run as
# root that night. On failure: HOOK_ERR.
HOOK_ERR=""
hook_trusted() {
    local hook="$1" p st me
    me="$(id -u)"; HOOK_ERR=""
    for p in "$hook" "$(dirname "$hook")"; do
        st="$(stat -L -c '%u %a' "$p" 2>/dev/null)" || { HOOK_ERR="cannot stat $p"; return 1; }
        if [[ "${st% *}" != "$me" ]]; then
            HOOK_ERR="$p belongs to uid ${st% *}, not root"; return 1
        fi
        if (( 8#${st#* } & 8#022 )); then
            HOOK_ERR="$p is writable by the group or others (mode ${st#* })"; return 1
        fi
    done
    [[ -L "$hook" ]] && { HOOK_ERR="$hook is a symbolic link"; return 1; }
    return 0
}

run_hook() {
    local dir="$1" hook_name="$2" proj="$3"
    local hook="${dir}/${hook_name}"
    if [[ -x "$hook" ]] && ! hook_trusted "$hook"; then
        log_warn "  Not running $hook_name for $proj: $HOOK_ERR. A hook runs as root: sudo chown root: $hook $dir; sudo chmod go-w $hook $dir"
        return 1
    fi
    if [[ -x "$hook" ]]; then
        log "  ${C_MAGENTA}🪝${C_RESET}  Running $hook_name for $proj"
        (
            cd "$dir"
            # A hook is foreign code in the project folder. It doesn't need the S3 keys, yet would inherit
            # them from the environment: that's a key to every backup of every project
            # in every storage. Strip them for the hook run.
            env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
                -u AWS_DEFAULT_REGION -u AWS_S3_ADDRESSING_STYLE -u AWS_CONFIG_FILE \
                COMPOSE_PROJECT="$proj" \
                PROJECT_DIR="$dir" \
                BACKUP_TIMESTAMP="$TIMESTAMP" \
                "$hook"
        ) || { log_warn "Hook $hook_name returned an error for $proj"; return 1; }
        log_ok "Hook $hook_name done"
    fi
    return 0
}

# ==============================================================================
# 6. BACKUP OF ONE PROJECT
# ==============================================================================
backup_project() {
    local proj="$1" dir="$2"
    local proj_start; proj_start=$(date +%s)
    log ""
    log "${C_BOLD}${C_BLUE}──────────────────────────────────────────────────${C_RESET}"
    log "${C_BOLD}📦 Project: $proj${C_RESET}  ($dir)"
    log "${C_BOLD}${C_BLUE}──────────────────────────────────────────────────${C_RESET}"

    local proj_dir="${BACKUP_ROOT}/${proj}"
    mkdir -p "$proj_dir"

    # Failures of individual volumes/bind mounts are collected here. A file, not
    # a variable: parallel jobs under xargs run in child processes,
    # and a variable's value would not come back from them.
    local fail_marker="${BACKUP_ROOT}/.failed_${proj//\//_}"
    rm -f "$fail_marker"

    # 6.1 — Automatic database dump (PostgreSQL/MySQL/MariaDB/Redis/MongoDB).
    # DUMP_RECORD — which dumps this run made and which are older (see _db_done in lib.sh)
    local DUMP_RECORD="${BACKUP_ROOT}/.dumps_${proj//\//_}" dumps_archived=false
    rm -f "$DUMP_RECORD"
    auto_dump_databases "$proj" "$dir" "$TIMESTAMP" || log_warn "Database auto-dump finished with an error, continuing..."

    # 6.2 — Pre-backup hook (your custom one — for non-standard databases, cleanup etc.)
    if ! run_hook "$dir" "pre-backup-hook.sh" "$proj"; then
        log_warn "pre-backup-hook failed, continuing the backup..."
    fi

    # 6.3 — Metadata
    log "  📝 Saving metadata..."
    {
        echo "PROJECT_NAME=$proj"
        echo "PROJECT_DIR=$dir"
        echo "BACKUP_TIMESTAMP=$TIMESTAMP"
        echo "BACKUP_MODE=$BACKUP_MODE"
        echo "DOCKER_VERSION=$(docker --version)"
        echo "HOSTNAME=$(uname -n)"
        echo "ENCRYPTED=${ENCRYPT_BACKUPS:-false}"
    } > "${proj_dir}/metadata.txt"

    docker ps -a --filter "label=com.docker.compose.project=$proj" \
        --format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}' \
        > "${proj_dir}/containers.tsv"

    mkdir -p "${proj_dir}/inspect"
    while IFS= read -r cid; do
        [[ -z "$cid" ]] && continue
        local cname; cname="$(docker inspect --format '{{.Name}}' "$cid" | sed 's|^/||')"
        docker inspect "$cid" > "${proj_dir}/inspect/${cname}.json" 2>/dev/null || true
    done < <(docker ps -aq --filter "label=com.docker.compose.project=$proj")

    # 6.4 — Stop/pause (unless the mode is hot)
    pause_project "$proj" "$dir"
    PAUSED_PROJECT="$proj"
    PAUSED_DIR="$dir"

    # 6.5 — Volume backup (parallel)
    if [[ "$BACKUP_VOLUMES" == "true" ]]; then
        mkdir -p "${proj_dir}/volumes"
        log "  💾 Backing up volumes (${C_BOLD}parallel=$PARALLEL_JOBS${C_RESET})..."
        local volumes
        volumes="$(docker ps -aq --filter "label=com.docker.compose.project=$proj" \
            | xargs -r docker inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' \
            | sort -u | grep -v '^$' || true)"
        if [[ -n "$volumes" ]]; then
            if [[ "${PARALLEL_JOBS:-1}" -gt 1 ]]; then
                # Parallel mode
                echo "$volumes" | xargs -I {} -P "$PARALLEL_JOBS" \
                    bash -c 'backup_volume "$@" || true' _ {} "${proj_dir}/volumes" "$fail_marker"
            else
                while IFS= read -r vol; do
                    backup_volume "$vol" "${proj_dir}/volumes" "$fail_marker" || true
                done <<< "$volumes"
            fi

            # Completeness check: how many volumes were expected and how many archives came out.
            # Also catches the silent cases where an archive was not created at all.
            local expected_vols produced_vols
            expected_vols="$(grep -c . <<< "$volumes" || true)"
            produced_vols="$(find "${proj_dir}/volumes" -maxdepth 1 -name 'volume_*.tar.gz' 2>/dev/null | wc -l)"
            if (( produced_vols < expected_vols )); then
                log_err "  Volumes backed up: ${produced_vols} of ${expected_vols}"
                echo "fail:volumes_missing:$((expected_vols - produced_vols))" >> "$fail_marker"
            else
                log_ok "  Volumes backed up: ${produced_vols}/${expected_vols}"
            fi
        else
            log_info "    (no named volumes)"
        fi
    fi

    # 6.6 — Bind-mount backup
    if [[ "$BACKUP_BIND_MOUNTS" == "true" ]]; then
        mkdir -p "${proj_dir}/binds"
        log "  📁 Backing up bind mounts..."
        local binds idx=0
        binds="$(docker ps -aq --filter "label=com.docker.compose.project=$proj" \
            | xargs -r docker inspect --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{"\n"}}{{end}}{{end}}' \
            | sort -u | grep -v '^$' || true)"
        if [[ -n "$binds" ]]; then
            while IFS= read -r bind_src; do
                # Inside the project folder — it goes into project_dir.tar.gz (see 6.9)
                path_within "$bind_src" "$dir" && continue
                if is_bind_blacklisted "$bind_src"; then
                    log "    ${C_DIM}⊘ Skipped (blacklist): $bind_src${C_RESET}"
                    continue
                fi
                idx=$((idx + 1))
                backup_bind_mount "$bind_src" "${proj_dir}/binds" "$idx" "$fail_marker" || true
            done <<< "$binds"
        else
            log_info "    (no bind mounts)"
        fi
    fi

    # 6.7 — Resume the containers
    resume_project "$proj" "$dir"
    PAUSED_PROJECT=""
    PAUSED_DIR=""

    # 6.8 — Post-backup hook (e.g. cleanup of temporary dump files)
    run_hook "$dir" "post-backup-hook.sh" "$proj" || true

    # 6.9 — Backup of the whole project folder
    if [[ "$BACKUP_PROJECT_DIR" == "true" && -d "$dir" ]]; then
        log "  📂 Backing up the whole project folder: $dir"

        # Nested compose projects (e.g. /opt/app/remote-desk inside
        # /opt/app) are backed up on their own, in their own archives. Without excluding them
        # they would go to S3 a second time, and restoring the outer project
        # would silently roll the nested one's files back to its archive date — while
        # the nested project's named volumes would stay current.
        local -a tar_excludes=()
        local other other_dir base_name
        base_name="$(basename "$dir")"
        for other in "${!PROJECTS[@]}"; do
            [[ "$other" == "$proj" ]] && continue
            other_dir="${PROJECTS[$other]}"
            if [[ "$other_dir" == "$dir"/* ]]; then
                tar_excludes+=(--exclude="${base_name}/${other_dir#"$dir"/}")
                log "    ${C_DIM}⊘ Excluding nested project: $other_dir (backed up separately)${C_RESET}"
            fi
        done
        # Earlier database dumps kept on the server are already in earlier archives: only this run's go in
        local kind path
        if [[ -f "$DUMP_RECORD" ]]; then
            while IFS=$'\t' read -r kind path _; do
                [[ "$kind" == old && "$path" == "$dir"/* ]] && tar_excludes+=(--exclude="${base_name}/${path#"$dir"/}")
            done < "$DUMP_RECORD"
        fi

        local pd_rc=0
        tar_gz "${proj_dir}/project_dir.tar.gz" \
            ${tar_excludes[@]+"${tar_excludes[@]}"} \
            -C "$(dirname "$dir")" "$base_name" || pd_rc=$?
        case "$pd_rc" in
            0) dumps_archived=true ;;
            1) dumps_archived=true
               log_warn "  Project folder: files changed while being read — archive created"
               echo "warn:project_dir:$dir" >> "$fail_marker" ;;
            *) log_err "  Could not back up the project folder (tar rc=$pd_rc)"
               echo "fail:project_dir:$dir" >> "$fail_marker" ;;
        esac
    fi

    # 6.10 — Image backup (optional)
    if [[ "$BACKUP_IMAGES" == "true" ]]; then
        mkdir -p "${proj_dir}/images"
        log "  🐳 Saving Docker images..."
        local images
        images="$(docker ps -aq --filter "label=com.docker.compose.project=$proj" \
            | xargs -r docker inspect --format '{{.Config.Image}}' | sort -u)"
        while IFS= read -r img; do
            [[ -z "$img" ]] && continue
            local safe_img; safe_img="$(echo "$img" | tr '/:' '__')"
            docker save "$img" | gzip -"$COMPRESS_LEVEL" > "${proj_dir}/images/${safe_img}.tar.gz" \
                || log_warn "Could not save image $img"
        done <<< "$images"
    fi

    # 6.11 — Final assembly into one archive
    log "  📦 Packing the project into a single archive..."
    local final_archive="${BACKUP_ROOT}/${proj}__${TIMESTAMP}.tar.gz"
    tar_gz "$final_archive" -C "$BACKUP_ROOT" "$proj" \
        || { log_err "Could not pack project $proj"; return 1; }
    rm -rf "${proj_dir}"

    # 6.12 — Encryption (if enabled)
    local archive_to_upload="$final_archive"
    if [[ "${ENCRYPT_BACKUPS:-false}" == "true" ]]; then
        log "  🔐 Encrypting the archive..."
        archive_to_upload="$(encrypt_file "$final_archive")" \
            || { log_err "Encryption failed for $proj"; return 1; }
    fi

    # 6.12b — sha256 manifest. An object's size in S3 only proves the upload
    # wasn't cut short; a hash catches data corruption — including damage that appears
    # after the upload. It also lets sync-s3 and verify-restore tell "same
    # size" from "same content".
    local checksum_file="" checksum_key=""
    if [[ "${CHECKSUM_MANIFEST:-true}" == "true" ]]; then
        checksum_file="$(write_checksum_file "$archive_to_upload")" || checksum_file=""
        [[ -n "$checksum_file" ]] && log_ok "  sha256: $(awk '{print $1}' "$checksum_file")"
    fi

    # 6.13 — Upload to S3
    local archive_basename; archive_basename="$(basename "$archive_to_upload")"
    local s3_key="${BACKUP_PREFIX}/${proj}/${TIMESTAMP}/${archive_basename}"
    local s3_url="s3://${PRIMARY_S3_BUCKET}/${s3_key}"
    log "  ☁  Uploading to the primary S3: $s3_url"
    local local_size; local_size="$(stat -c %s "$archive_to_upload")"
    aws_upload "$archive_to_upload" "$s3_url" \
        || { log_err "Could not upload $archive_to_upload to S3"; rm -f "$checksum_file"; return 1; }

    if [[ -n "$checksum_file" ]]; then
        checksum_key="${s3_key}.sha256"
        if ! aws_upload "$checksum_file" "s3://${PRIMARY_S3_BUCKET}/${checksum_key}"; then
            log_warn "  The sha256 manifest did not upload — hash verification will not be available for this backup"
            checksum_key=""
        fi
    fi

    # 6.14 — Integrity check via head-object
    log "  🔍 Checking the integrity of the uploaded object..."
    local s3_size
    s3_size="$(aws_q s3api head-object --bucket "$PRIMARY_S3_BUCKET" --key "$s3_key" --query ContentLength --output text 2>/dev/null || echo 0)"
    if [[ "$s3_size" != "$local_size" ]]; then
        log_err "Size in S3 ($s3_size) != local ($local_size). Possible corruption."
        return 1
    fi
    log_ok "Size in S3 matches: ${local_size} bytes"

    # 6.14b — The database dumps are in the storage now: on the server keep only DB_DUMPS_RETENTION_COUNT of them.
    # Not in the archive (BACKUP_PROJECT_DIR off, the folder not archived) — then they stay: no other copy.
    if $dumps_archived; then keep_local_dumps "$DUMP_RECORD"; fi
    rm -f "$DUMP_RECORD"

    # 6.15 — Upload to the copies (secondary, tertiary), if enabled
    if ! upload_copies "$proj" "$archive_to_upload" "$s3_key" "$local_size" "$checksum_file" "$checksum_key"; then
        rm -f "$archive_to_upload" "$checksum_file"
        return 1
    fi

    local size_human; size_human="$(du -h "$archive_to_upload" | awk '{print $1}')"
    local proj_dur=$(($(date +%s) - proj_start))
    rm -f "$archive_to_upload" "$checksum_file"
    TOTAL_UPLOADED_BYTES=$((TOTAL_UPLOADED_BYTES + local_size))

    # 6.16 — Completeness verdict.
    # The archive is already in S3 — an incomplete copy beats a missing one. But if part of the data
    # didn't make it in, the project MUST count as failed: otherwise a "green" backup
    # with a hole is indistinguishable from a complete one, and nobody would ever know.
    if [[ -f "$fail_marker" ]] && grep -q '^fail:' "$fail_marker"; then
        log_err "$proj: backup INCOMPLETE, part of the data did not make it into the archive:"
        sed -n 's/^fail:/    • /p' "$fail_marker" >&2
        log_err "  The archive was uploaded anyway ($size_human) — but a restore will be partial"
        return 1
    fi
    if [[ -f "$fail_marker" ]] && grep -q '^warn:' "$fail_marker"; then
        log_warn "$proj: the snapshot is not fully atomic (files changed while being read):"
        sed -n 's/^warn:/    • /p' "$fail_marker" >&2
    fi

    log_done "$proj  (size: $size_human, time: $(fmt_duration $proj_dur))"
    return 0
}

# Upload an archive already verified in the primary S3 to every enabled copy.
# usage: upload_copies <project> <archive> <s3_key> <size> [<sha256 file> <sha256 key>]
# Writes failures to COPY_FAILED. Returns 1 if at least one REQUIRED copy failed —
# then the project counts as failed (it is still in the primary, the final message tells these apart).
upload_copies() {
    local proj="$1" archive="$2" key="$3" size="$4" sum_file="${5:-}" sum_key="${6:-}"
    local role label rc=0
    for role in ${S3_COPIES[@]+"${S3_COPIES[@]}"}; do
        label="$(s3_label "$role" title)"
        if upload_to_copy "$role" "$archive" "$key" "$size"; then
            if [[ -n "$sum_key" ]]; then
                upload_to_copy "$role" "$sum_file" "$sum_key" "$(stat -c %s "$sum_file")" \
                    || log_warn "  The sha256 manifest did not reach $(s3_label "$role")"
            fi
            continue
        fi
        COPY_FAILED[$role]+="${proj}"$'\n'
        if s3_required "$role"; then
            log_err "${label} is required (${role^^}_S3_REQUIRED=true) — ${proj} marked as failed"
            rc=1
        else
            log_warn "${label} did not accept ${proj}, but it is optional — the primary backup is in place, continuing"
        fi
    done
    return $rc
}

# ==============================================================================
# 7. BACKUP OF STANDALONE CONTAINERS
# ==============================================================================
backup_standalone() {
    [[ ${#STANDALONE_CONTAINERS[@]} -eq 0 ]] && return 0
    log ""
    log "${C_BOLD}${C_BLUE}──────────────────────────────────────────────────${C_RESET}"
    log "${C_BOLD}📦 Standalone containers (no compose)${C_RESET}"
    log "${C_BOLD}${C_BLUE}──────────────────────────────────────────────────${C_RESET}"

    local proj="_standalone_${HOSTNAME}"
    local proj_dir="${BACKUP_ROOT}/${proj}"
    mkdir -p "${proj_dir}/inspect" "${proj_dir}/volumes" "${proj_dir}/binds"

    local fail_marker="${BACKUP_ROOT}/.failed_standalone"
    rm -f "$fail_marker"

    {
        echo "PROJECT_NAME=$proj"
        echo "BACKUP_TIMESTAMP=$TIMESTAMP"
        echo "TYPE=standalone_containers"
        echo "ENCRYPTED=${ENCRYPT_BACKUPS:-false}"
    } > "${proj_dir}/metadata.txt"

    for cid in "${STANDALONE_CONTAINERS[@]}"; do
        local cname; cname="$(docker inspect --format '{{.Name}}' "$cid" | sed 's|^/||')"
        log "  📦 Container: $cname"
        docker inspect "$cid" > "${proj_dir}/inspect/${cname}.json"

        if [[ "$BACKUP_MODE" == "pause" ]]; then
            docker pause "$cid" >/dev/null 2>&1 || true
        elif [[ "$BACKUP_MODE" == "stop" ]]; then
            docker stop "$cid" >/dev/null 2>&1 || true
        fi

        if [[ "$BACKUP_VOLUMES" == "true" ]]; then
            while IFS= read -r vol; do
                [[ -z "$vol" ]] && continue
                backup_volume "$vol" "${proj_dir}/volumes" "$fail_marker" || true
            done < <(docker inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' "$cid")
        fi
        if [[ "$BACKUP_BIND_MOUNTS" == "true" ]]; then
            local idx=0
            while IFS= read -r bsrc; do
                [[ -z "$bsrc" ]] && continue
                if is_bind_blacklisted "$bsrc"; then
                    log "    ${C_DIM}⊘ Skipped (blacklist): $bsrc${C_RESET}"
                    continue
                fi
                idx=$((idx + 1))
                backup_bind_mount "$bsrc" "${proj_dir}/binds" "${cname}_${idx}" "$fail_marker" || true
            done < <(docker inspect --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{"\n"}}{{end}}{{end}}' "$cid")
        fi

        if [[ "$BACKUP_MODE" == "pause" ]]; then
            docker unpause "$cid" >/dev/null 2>&1 || true
        elif [[ "$BACKUP_MODE" == "stop" ]]; then
            docker start "$cid" >/dev/null 2>&1 || true
        fi
    done

    local final_archive="${BACKUP_ROOT}/${proj}__${TIMESTAMP}.tar.gz"
    tar_gz "$final_archive" -C "$BACKUP_ROOT" "$proj" \
        || { log_err "Standalone: could not pack the archive"; return 1; }
    rm -rf "$proj_dir"

    local archive_to_upload="$final_archive"
    if [[ "${ENCRYPT_BACKUPS:-false}" == "true" ]]; then
        archive_to_upload="$(encrypt_file "$final_archive")" \
            || { log_err "Standalone: encryption failed"; return 1; }
    fi
    # The same sha256 manifest as for projects
    local checksum_file="" checksum_key=""
    if [[ "${CHECKSUM_MANIFEST:-true}" == "true" ]]; then
        checksum_file="$(write_checksum_file "$archive_to_upload")" || checksum_file=""
    fi
    local archive_basename; archive_basename="$(basename "$archive_to_upload")"
    local s3_key="${BACKUP_PREFIX}/${proj}/${TIMESTAMP}/${archive_basename}"
    local local_size; local_size="$(stat -c %s "$archive_to_upload")"

    aws_upload "$archive_to_upload" "s3://${PRIMARY_S3_BUCKET}/${s3_key}" \
        || { log_err "Could not upload standalone to S3"; rm -f "$archive_to_upload" "$checksum_file"; return 1; }
    if [[ -n "$checksum_file" ]]; then
        checksum_key="${s3_key}.sha256"
        if ! aws_upload "$checksum_file" "s3://${PRIMARY_S3_BUCKET}/${checksum_key}"; then
            log_warn "  Standalone: the sha256 manifest did not upload"
            checksum_key=""
        fi
    fi

    local s3_size
    s3_size="$(aws_q s3api head-object --bucket "$PRIMARY_S3_BUCKET" --key "$s3_key" --query ContentLength --output text 2>/dev/null || echo 0)"
    if [[ "$s3_size" != "$local_size" ]]; then
        log_err "Standalone: size mismatch"
        return 1
    fi

    # Upload to the copies (secondary, tertiary), if enabled
    if ! upload_copies "containers outside compose" "$archive_to_upload" "$s3_key" "$local_size" "$checksum_file" "$checksum_key"; then
        rm -f "$archive_to_upload" "$checksum_file"
        return 1
    fi

    rm -f "$archive_to_upload" "$checksum_file"
    TOTAL_UPLOADED_BYTES=$((TOTAL_UPLOADED_BYTES + local_size))

    if [[ -f "$fail_marker" ]] && grep -q '^fail:' "$fail_marker"; then
        log_err "Standalone: backup INCOMPLETE, part of the data did not make it into the archive:"
        sed -n 's/^fail:/    • /p' "$fail_marker" >&2
        return 1
    fi
    log_ok "Standalone done"
}

# ==============================================================================
# 7b. REMOTE DATABASES (REMOTE_DBS)
# The dump goes from a client container straight into the primary storage, without a file on this disk
# (remote_db_stream, lib.sh); the copies read it back from the primary. In the storages it is the project
# _db_<name>: one dump per timestamp, next to it the .sha256 manifest, as with an archive.
# ==============================================================================
backup_remote_db() {
    local name="$1" start problems p
    start=$(date +%s)
    log ""
    log "${C_BOLD}${C_BLUE}──────────────────────────────────────────────────${C_RESET}"
    log "${C_BOLD}🗄  Remote database: $name${C_RESET}  ($(remote_db_desc "$name"))"
    log "${C_BOLD}${C_BLUE}──────────────────────────────────────────────────${C_RESET}"
    if ! problems="$(remote_db_check "$name")"; then
        log_err "  The settings of $name are not complete:"
        while IFS= read -r p; do log_err "    $p"; done <<< "$problems"
        return 1
    fi
    if [[ "${ENCRYPT_BACKUPS:-false}" == "true" && ! -r "${GPG_PASSPHRASE_FILE:-}" ]]; then
        log_err "  Cannot read the passphrase file ${GPG_PASSPHRASE_FILE:-}: no dump is made, it would go unencrypted"
        return 1
    fi
    _remote_db_build "$name" dump
    remote_db_image_ready || return 1

    local folder="_db_${name}" file key
    file="${folder}__${TIMESTAMP}.${RDB_EXT}"
    [[ "${ENCRYPT_BACKUPS:-false}" == "true" ]] && file+=".gpg"
    key="${BACKUP_PREFIX}/${folder}/${TIMESTAMP}/${file}"
    log "  ☁  Dumping straight into the primary S3$([[ "${ENCRYPT_BACKUPS:-false}" == "true" ]] && echo ", encrypted"): s3://${PRIMARY_S3_BUCKET}/${key}"
    remote_db_stream "$name" "$key" || return 1
    log_ok "Size in S3 matches: ${RDB_SIZE} bytes"

    local checksum_file="" checksum_key=""
    if [[ "${CHECKSUM_MANIFEST:-true}" == "true" && -n "$RDB_SHA256" ]]; then
        log_ok "  sha256: ${RDB_SHA256}"
        checksum_file="${BACKUP_ROOT}/${file}.sha256"
        printf '%s  %s\n' "$RDB_SHA256" "$file" > "$checksum_file"
        if aws_upload "$checksum_file" "s3://${PRIMARY_S3_BUCKET}/${key}.sha256"; then
            checksum_key="${key}.sha256"
        else
            log_warn "  The sha256 manifest did not upload — hash verification will not be available for this dump"
        fi
    fi

    if ! upload_copies "database $name" "s3://${PRIMARY_S3_BUCKET}/${key}" "$key" "$RDB_SIZE" "$checksum_file" "$checksum_key"; then
        rm -f "$checksum_file"
        return 1
    fi
    rm -f "$checksum_file"
    TOTAL_UPLOADED_BYTES=$((TOTAL_UPLOADED_BYTES + RDB_SIZE))
    log_done "database $name  (size: $(awk -v b="$RDB_SIZE" 'BEGIN { split("B KB MB GB TB", u, " "); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ } printf(i == 1 ? "%d %s" : "%.1f %s", b, u[i]) }'), time: $(fmt_duration $(($(date +%s) - start))))"
    return 0
}

# ==============================================================================
# 8. ROTATION
# ==============================================================================
cleanup_old_backups() {
    local role="${1:-primary}"   # a role from S3_ROLES
    local bucket label

    s3_enabled "$role" || return 0
    if [[ -z "$(s3_var "$role" BUCKET)" ]]; then
        log_warn "Rotation skipped ($(s3_label "$role")) — ${role^^}_S3_BUCKET is not set"
        return 0
    fi
    _aws_setup "$role"
    bucket="$S3_CUR_BUCKET"
    label="$(s3_label "$role" in)"

    local scheme
    if [[ "${GFS_ENABLED:-false}" == "true" ]]; then
        scheme="GFS ${GFS_DAILY:-7} d / ${GFS_WEEKLY:-4} w / ${GFS_MONTHLY:-6} m"
    else
        scheme="older than ${RETENTION_DAYS} days"
    fi

    log ""
    log "${C_BOLD}${C_BLUE}===================================================================${C_RESET}"
    log "${C_BOLD}🧹 Cleanup ${label}: ${scheme}, keeping the last ${KEEP_MIN_BACKUPS:-3}${C_RESET}"
    log "${C_BOLD}${C_BLUE}===================================================================${C_RESET}"

    # Leftovers of multipart uploads — before the file listing: they're not in it, yet they take space.
    local aborted; aborted="$(abort_stale_uploads "$bucket")"
    (( aborted > 0 )) && log "  Unfinished uploads aborted: ${C_BOLD}$aborted${C_RESET}"

    local objects
    objects="$(aws_q s3api list-objects-v2 \
        --bucket "$bucket" \
        --prefix "${BACKUP_PREFIX}/" \
        --query 'Contents[].[Key,LastModified]' \
        --output text 2>/dev/null || true)"

    if [[ -z "$objects" ]]; then
        log_info "No backups found ${label}."
        _aws_setup primary
        return 0
    fi

    # The decision is made by plan_rotation (lib.sh) — the same function that
    # status.sh uses for its forecast. Otherwise forecast and reality drift apart.
    local plan
    plan="$(printf '%s\n' "$objects" | plan_rotation)"

    local deleted=0 kept=0 decision key
    local kproj
    while IFS=$'\t' read -r decision key; do
        [[ -z "$key" ]] && continue
        if [[ "$decision" == "DELETE" ]]; then
            log "  🗑  Deleting: $key"
            if aws_rm "s3://${bucket}/${key}"; then
                deleted=$((deleted + 1))
                kproj="${key#"${BACKUP_PREFIX}/"}"; kproj="${kproj%%/*}"
                if ! grep -qxF -- "$kproj" <<< "$ROTATION_LIVE_PROJECTS"; then
                    ORPHAN_DROPPED["$kproj"]=$(( ${ORPHAN_DROPPED[$kproj]:-0} + 1 ))
                fi
            else
                log_warn "Could not delete $key"
            fi
        else
            kept=$((kept + 1))
        fi
    done <<< "$plan"

    log "  Deleted: ${C_BOLD}$deleted${C_RESET}, kept: ${C_BOLD}$kept${C_RESET}"

    # Restore the primary credentials after working with a copy
    _aws_setup primary
    return 0
}

# ==============================================================================
# 9. MAIN FLOW
# ==============================================================================
TOTAL_PROJECTS=$(( ${#PROJECTS[@]} + ${#REMOTE_LIST[@]} ))

RUN_STARTED=true
if (( ${#PROJECTS[@]} > 0 )); then
    for proj in "${!PROJECTS[@]}"; do
        CURRENT_PROJECT="$proj"
        if backup_project "$proj" "${PROJECTS[$proj]}"; then
            TOTAL_SUCCESS=$((TOTAL_SUCCESS + 1))
        else
            TOTAL_FAILED=$((TOTAL_FAILED + 1))
            FAILED_PROJECTS+=("$proj")
            log_err "Project $proj finished with an error"
        fi
    done
elif (( ${#REMOTE_LIST[@]} == 0 )); then
    log_warn "No compose projects found on this host"
fi

# Standalone
CURRENT_PROJECT="containers outside compose"
if backup_standalone; then
    :
else
    TOTAL_FAILED=$((TOTAL_FAILED + 1))
    FAILED_PROJECTS+=("containers outside compose")
fi
CURRENT_PROJECT=""

# Remote databases
for n in ${REMOTE_LIST[@]+"${REMOTE_LIST[@]}"}; do
    CURRENT_PROJECT="database $n"
    if backup_remote_db "$n"; then
        TOTAL_SUCCESS=$((TOTAL_SUCCESS + 1))
    else
        TOTAL_FAILED=$((TOTAL_FAILED + 1))
        FAILED_PROJECTS+=("database $n")
        log_err "Remote database $n finished with an error"
    fi
    RDB_CNAME=""
done
CURRENT_PROJECT=""

# Rotation — skipped if there was a project filter (deleting others' backups is dangerous)
if [[ -n "$PROJECT_FILTER" ]]; then
    log ""
    log "${C_DIM}🧹 Rotation skipped (run with --project)${C_RESET}"
elif (( TOTAL_SUCCESS == 0 )); then
    # Not a single project was backed up — something is broken system-wide (S3, disk,
    # docker). Deleting old copies in that situation is not allowed: they're all
    # we have left.
    log ""
    log_warn "🧹 Rotation skipped: not a single successful backup in this run"
else
    # Live projects — for rotation: for them it protects the last copies, for the rest it doesn't (plan_rotation).
    # Left out by EXCLUDE_PROJECTS counts as live: the project is still here, only not backed up.
    ROTATION_LIVE_PROJECTS="$(printf '%s\n' "${!PROJECTS[@]}" ${EXCLUDED[@]+"${!EXCLUDED[@]}"} "_standalone_${HOSTNAME}" \
        ${REMOTE_LIST[@]+"${REMOTE_LIST[@]/#/_db_}"})"
    export ROTATION_LIVE_PROJECTS
    for role in primary ${S3_COPIES[@]+"${S3_COPIES[@]}"}; do
        cleanup_old_backups "$role" || log_warn "Rotation ($(s3_label "$role")) finished with an error"
    done
fi

# Cleanup
rm -rf "$BACKUP_ROOT"

# ==============================================================================
# 10. SUMMARY
# ==============================================================================
SESSION_END=$(date +%s)
TOTAL_DURATION=$((SESSION_END - SESSION_START))
TOTAL_MB=$((TOTAL_UPLOADED_BYTES / 1048576))

log ""
log "${C_BOLD}${C_BLUE}===================================================================${C_RESET}"
if [[ "$TOTAL_FAILED" -eq 0 ]]; then
    log_done "Backup finished. Timestamp: ${TIMESTAMP}"
    log "    Projects:  ${TOTAL_SUCCESS}/${TOTAL_PROJECTS}"
    log "    Uploaded:  ${TOTAL_MB} MB"
    log "    Time:      $(fmt_duration $TOTAL_DURATION)"
else
    log_err "Backup finished with errors. Timestamp: ${TIMESTAMP}"
    log "    Succeeded: ${TOTAL_SUCCESS}/${TOTAL_PROJECTS}"
    log "    Errors:    ${TOTAL_FAILED}  ($(join_list "${FAILED_PROJECTS[@]}"))"
    log "    Time:      $(fmt_duration $TOTAL_DURATION)"
fi
log "${C_BOLD}${C_BLUE}===================================================================${C_RESET}"

# Run summary — one line in a file (LAST_RUN_FILE). The backup reports its own errors to Telegram,
# but it can't report that it never started (cron broken, the server down at the scheduled time) — an external
# monitor can see that by this file's age. A separate file rather than the log:
# the monitor doesn't need access to /var/log, which holds other logs too.
LAST_RUN_FILE="${LAST_RUN_FILE:-/var/lib/docker-backup/last-run.json}"
if mkdir -p "$(dirname "$LAST_RUN_FILE")" 2>/dev/null; then
    printf '{"finished":"%s","ok":%s,"projects":%d,"failed":%d,"label":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$([[ "$TOTAL_FAILED" -eq 0 ]] && echo true || echo false)" \
        "$TOTAL_PROJECTS" "$TOTAL_FAILED" "$TIMESTAMP" > "${LAST_RUN_FILE}.tmp" && mv "${LAST_RUN_FILE}.tmp" "$LAST_RUN_FILE"
    chmod 644 "$LAST_RUN_FILE" 2>/dev/null || true
fi

# Summary to Telegram: what was saved, where, and what is missing. After last-run.json — a failure here must not
# leave the monitor without a summary.
RUN_DONE=true
_join() { html_esc "$(join_list "$@")"; }
size_txt="${TOTAL_MB} MB"
(( TOTAL_MB >= 1024 )) && size_txt="$(awk -v m="$TOTAL_MB" 'BEGIN { printf "%.1f GB", m/1024 }')"
primary_host="$(html_esc "$(s3_host "$PRIMARY_S3_ENDPOINT")")"
# Saved nowhere — the run's failures minus those that failed only on a copy
# (with <ROLE>_S3_REQUIRED=true those count as failures too, but they are in the primary).
declare -A IN_COPY_FAILED=()
for role in ${S3_COPIES[@]+"${S3_COPIES[@]}"}; do
    while IFS= read -r x; do [[ -n "$x" ]] && IN_COPY_FAILED["$x"]=1; done <<< "${COPY_FAILED[$role]:-}"
done
declare -a LOST=()
for f in ${FAILED_PROJECTS[@]+"${FAILED_PROJECTS[@]}"}; do
    [[ -n "${IN_COPY_FAILED[$f]:-}" ]] || LOST+=("$f")
done
saved=$(( TOTAL_SUCCESS + ${#FAILED_PROJECTS[@]} - ${#LOST[@]} ))
check_hint="Check: <code>$(html_esc "$SCRIPT_DIR")/diagnose-s3.sh</code>."
copy_lines=""; copy_bad=0; copy_bad_required=false; copy_bad_role=""
for role in ${S3_COPIES[@]+"${S3_COPIES[@]}"}; do
    host="$(html_esc "$(s3_host "$(s3_var "$role" ENDPOINT)")")"
    line=""
    if [[ -n "${COPY_DOWN[$role]:-}" ]]; then
        line="$(s3_label "$role" title) (${host}) received nothing: the storage $(html_esc "${COPY_DOWN[$role]}"). ${check_hint}"
    elif [[ -n "${COPY_FAILED[$role]:-}" ]]; then
        mapfile -t failed_list <<< "${COPY_FAILED[$role]%$'\n'}"
        line="$(s3_label "$role" title) (${host}) did not accept: <b>$(_join "${failed_list[@]}")</b> (they are in the primary storage). ${check_hint}"
    fi
    [[ -z "$line" ]] && continue
    copy_bad=$((copy_bad + 1)); copy_bad_role="$role"
    s3_required "$role" && copy_bad_required=true
    copy_lines+="${copy_lines:+$'\n'}${line}"
done
stats="${size_txt} in $(fmt_duration $TOTAL_DURATION), timestamp <code>${TIMESTAMP}</code>."
if (( ${#ORPHAN_DROPPED[@]} > 0 )); then
    stats+=$'\n'"Deleted copies older than ${RETENTION_DAYS:-30} days of projects no longer on the server: <b>$(_join "${!ORPHAN_DROPPED[@]}")</b>."
fi
[[ -n "$CONF_WARNINGS" ]] && stats+=$'\n'"${CONF_WARNINGS}"
in_primary="In the primary storage (${primary_host}): ${saved} $(plural "$saved" project projects)."
if (( ${#LOST[@]} > 0 )); then
    body="Saved nowhere: <b>$(_join "${LOST[@]}")</b>."$'\n'"${in_primary}"
    [[ -n "$copy_lines" ]] && body+=$'\n'"$copy_lines"
    body+=$'\n'"${stats}"$'\n'"$(notify_log_hint)"
    notify error "backup with errors" "$body"
elif [[ -n "$copy_lines" ]]; then
    level=warn
    $copy_bad_required && level=error   # a required copy — so it's an error
    title="copies did not accept everything"
    (( copy_bad == 1 )) && title="$(s3_label "$copy_bad_role") did not accept everything"
    notify "$level" "$title" "${in_primary}"$'\n'"${copy_lines}"$'\n'"${stats}"
else
    stores=$(( 1 + ${#S3_COPIES[@]} ))
    case "$stores" in
        1) where="in the primary storage (${primary_host})" ;;
        2) where="in both storages" ;;
        *) where="in all ${stores} storages" ;;
    esac
    # Saved, but a setting silently does the wrong thing — not a plain "done" (and it reaches NOTIFY_ON=error too)
    if [[ -n "$CONF_WARNINGS" ]]; then
        notify warn "backup done, but check the settings" "Saved ${saved} $(plural "$saved" project projects) ${where}."$'\n'"${stats^}"
    else
        notify success "backup done" "Saved ${saved} $(plural "$saved" project projects) ${where}."$'\n'"${stats^}"
    fi
fi

[[ "$TOTAL_FAILED" -eq 0 ]] && exit 0 || exit 1
