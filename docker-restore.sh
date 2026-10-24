#!/usr/bin/env bash
# ==============================================================================
# docker-restore.sh
# Interactive restore of Docker projects from S3-compatible storage
#
# Features:
#   - multi-select of projects (1,3,5 / 1-7 / all)
#   - --list to look around without doing anything
#   - GPG decryption
#   - colored output
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/backup.conf"

# --- Arguments ---
PROJECT_ARG=""
TIMESTAMP_ARG=""
RESTORE_DIR=""
NON_INTERACTIVE="false"
SKIP_START="false"
LIST_MODE="false"
FROM_ROLE=""
CONTENTS_MODE="false"
EXTRACT_TO=""
ONLY_VOLUME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)     CONFIG_FILE="$2"; shift 2 ;;
        -p|--project)    PROJECT_ARG="$2"; shift 2 ;;
        -t|--timestamp)  TIMESTAMP_ARG="$2"; shift 2 ;;
        -d|--dir)        RESTORE_DIR="$2"; shift 2 ;;
        -y|--yes)        NON_INTERACTIVE="true"; shift ;;
        -l|--list)       LIST_MODE="true"; shift ;;
        --no-start)      SKIP_START="true"; shift ;;
        --from)          FROM_ROLE="$2"; shift 2 ;;
        --from-secondary) FROM_ROLE="secondary"; shift ;;
        --contents)      CONTENTS_MODE="true"; shift ;;
        --extract-to)    EXTRACT_TO="$2"; shift 2 ;;
        --only-volume)   ONLY_VOLUME="$2"; shift 2 ;;
        -h|--help)
            cat <<EOF
Usage: $0 [options]
  -c, --config FILE       config file (default: backup.conf next to the script)
  -p, --project NAME      project name (several, comma-separated)
                          without -p — pick from a list, supports 1,3,5 / 1-7 / all
  -t, --timestamp TIME    backup timestamp (without -t — pick from a list for each project)
  -d, --dir PATH          where to restore (single project only)
  -y, --yes               ask no questions
  -l, --list              show what is in S3, without restoring
      --no-start          restore, but do NOT run docker compose up
      --from ROLE         where to read from: primary (default), secondary, tertiary
                          without the flag, interactive mode asks for the source (if copies are enabled)
      --from-secondary    same as --from secondary
  -h, --help              this help

PARTIAL RESTORE (does not touch the running project):
      --contents          show what is inside the backup and exit
      --extract-to DIR    download and unpack the backup into DIR, restoring nothing.
                          From there you can take a single SQL dump or a single file.
      --only-volume NAME  restore ONLY the given named volume

EXAMPLES:
  Interactive restore:      $0
  List everything:          $0 --list
  List a project's backups: $0 --list -p myapp
  No questions:             $0 -p myapp -t 2026-05-06_03-00-00 -y
  Test in /tmp:             $0 -p myapp -d /tmp/test --no-start
  From the secondary S3:    $0 --from secondary -p myapp
  From the tertiary S3:     $0 --from tertiary -p myapp

  What is in a backup:      $0 -p myapp --contents
  Get a database dump:      $0 -p myapp --extract-to /tmp/dump -y
  One volume:               $0 -p myapp --only-volume myapp_pgdata -y
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

require_cmd docker tar gzip aws jq
[[ "${ENCRYPT_BACKUPS:-false}" == "true" ]] && require_cmd gpg

# A terminal to ask on. Without one (cron, a pipe) a question would fail on /dev/tty with a cryptic error —
# need_tty says which option answers it instead.
HAVE_TTY=false; { : </dev/tty; } 2>/dev/null && HAVE_TTY=true
need_tty() { $HAVE_TTY || fail "No terminal to ask on — $1"; }

# --- Choosing the restore source: the primary S3 or one of the copies ---
# Priority: the --from flag > interactive choice (if copies are enabled and there is a terminal) > primary
SRC_ROLE="${FROM_ROLE:-primary}"
if [[ -z "$FROM_ROLE" && ${#S3_COPIES[@]} -gt 0 && "$NON_INTERACTIVE" != "true" ]] && $HAVE_TTY; then
    _choices=(primary "${S3_COPIES[@]}")
    {
        echo
        echo "${C_BOLD}Where to restore from?${C_RESET}"
        for _i in "${!_choices[@]}"; do
            echo "  ${C_CYAN}$((_i + 1)))${C_RESET} $(s3_label "${_choices[$_i]}" title) ${C_DIM}($(s3_var "${_choices[$_i]}" ENDPOINT))${C_RESET}"
        done
    } >&2
    read -rp "Choice [1]: " _src </dev/tty
    if [[ "$_src" =~ ^[0-9]+$ ]] && (( _src >= 1 && _src <= ${#_choices[@]} )); then
        SRC_ROLE="${_choices[$((_src - 1))]}"
    fi
fi

s3_is_role "$SRC_ROLE" || fail "Unknown storage: $SRC_ROLE (available: $(s3_roles_txt))"
_var="${SRC_ROLE^^}_S3"
s3_enabled "$SRC_ROLE" \
    || fail "$(s3_label "$SRC_ROLE" title) is not enabled (${_var}_ENABLED != true in backup.conf)"
[[ -n "$(s3_var "$SRC_ROLE" BUCKET)" && -n "$(s3_var "$SRC_ROLE" ENDPOINT)" ]] \
    || fail "$(s3_label "$SRC_ROLE" title): fill in ${_var}_BUCKET and ${_var}_ENDPOINT in backup.conf"
[[ -n "$(s3_var "$SRC_ROLE" RESTORE_ACCESS_KEY)" || -n "$(s3_var "$SRC_ROLE" ACCESS_KEY)" ]] \
    || fail "$(s3_label "$SRC_ROLE" title): a key is needed — ${_var}_ACCESS_KEY or ${_var}_RESTORE_ACCESS_KEY"
# the storage's read-only key, if set; from here on the whole script reads from SRC_BUCKET
_aws_setup "$SRC_ROLE" read
SRC_BUCKET="$S3_CUR_BUCKET"
if [[ "$SRC_ROLE" != "primary" || ${#S3_COPIES[@]} -gt 0 ]]; then
    _ro=""; [[ -n "$(s3_var "$SRC_ROLE" RESTORE_ACCESS_KEY)" ]] && _ro=" (read-only key)"
    log_info "📥 Source: $(s3_label "$SRC_ROLE") — ${S3_CUR_ENDPOINT}${_ro}"
fi
SRC_S3_PREP="$(s3_label "$SRC_ROLE" in)"     # "in primary S3"
SRC_S3_GEN="$(s3_label "$SRC_ROLE" from)"    # "from primary S3"

: "${BIND_BLACKLIST_REGEX:=^/$|^/proc|^/sys|^/dev|^/var/run|^/run|^/var/lib/docker|^/lib/modules|^/etc/localtime|^/etc/timezone|\.sock$}"

# Modes that change nothing on the host
READONLY_MODE="false"
[[ "$CONTENTS_MODE" == "true" || -n "$EXTRACT_TO" ]] && READONLY_MODE="true"

if [[ "$CONTENTS_MODE" == "true" && -n "$EXTRACT_TO" ]]; then
    fail "--contents and --extract-to together make no sense: pick one mode"
fi

# clear_bind_target <path> — empty a bind mount's folder before unpacking its backup into it:
#  - the folder itself stays (it may be a mount point: rm -rf of it fails, or empties a whole disk image);
#  - BIND_EXCLUDE_PATHS inside it stay too — they are not in the backup, and wiping them would lose them.
clear_bind_target() {
    local target="${1%/}" x
    if [[ ! -d "$target" || -L "$target" ]]; then rm -rf "$target"; return; fi
    local -a excl=() keep=()
    mapfile -t excl < <(split_words "${BIND_EXCLUDE_PATHS:-}")
    for x in ${excl[@]+"${excl[@]}"}; do
        path_within "$x" "$target" && [[ "${x%/}" != "$target" ]] && keep+=(-path "${x%/}" -o)
    done
    if (( ${#keep[@]} )); then
        unset 'keep[${#keep[@]}-1]'   # the last -o
        log "      Keeping the excluded: $(split_words "${BIND_EXCLUDE_PATHS:-}" | while IFS= read -r x; do path_within "$x" "$target" && printf '%s ' "$x"; done)"
        # Everything but the excluded subtrees, then the folders left empty (the excluded ones' parents are not)
        find "$target" -mindepth 1 \( "${keep[@]}" \) -prune -o ! -type d -exec rm -f {} +
        find "$target" -mindepth 1 \( "${keep[@]}" \) -prune -o -type d -print | sort -r | while IFS= read -r x; do
            rmdir "$x" 2>/dev/null || true
        done
    else
        find "$target" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    fi
}

# bind_target_for <archive name without .tar.gz> — the original path of a bind archive, from BIND_MAP
# (safe name → path) of the caller. Projects name the archives bind_<n>_<path>, standalone containers
# bind_<container>_<n>_<path>: match by the path part, the longest match wins. Empty if none.
bind_target_for() {
    local name="$1" key best=""
    for key in "${!BIND_MAP[@]}"; do
        if [[ "$name" == bind_*"_${key}" && ${#key} -gt ${#best} ]]; then
            best="$key"
        fi
    done
    [[ -n "$best" ]] && printf '%s' "${BIND_MAP[$best]}"
    return 0
}

# ==============================================================================
# What is inside an unpacked backup (--contents)
# ==============================================================================
show_backup_contents() {
    local d="$1"
    local found v name

    {
        echo
        echo "${C_BOLD}📋 Metadata:${C_RESET}"
        if [[ -f "$d/metadata.txt" ]]; then
            sed 's/^/    /' "$d/metadata.txt"
        else
            echo "    (no metadata.txt)"
        fi

        echo
        echo "${C_BOLD}💾 Named volumes:${C_RESET}"
        found=false
        for v in "$d/volumes/"volume_*.tar.gz; do
            [[ -f "$v" ]] || continue
            found=true
            name="$(basename "$v" .tar.gz)"; name="${name#volume_}"
            printf '    • %-44s %s\n' "$name" "$(du -h "$v" | awk '{print $1}')"
        done
        $found || echo "    (none)"

        echo
        echo "${C_BOLD}📁 Bind-mounts:${C_RESET}"
        found=false
        for v in "$d/binds/"bind_*.tar.gz; do
            [[ -f "$v" ]] || continue
            found=true
            printf '    • %-44s %s\n' "$(basename "$v" .tar.gz)" "$(du -h "$v" | awk '{print $1}')"
        done
        $found || echo "    (none)"

        echo
        echo "${C_BOLD}🗄  Database dumps (inside project_dir.tar.gz):${C_RESET}"
        if [[ -f "$d/project_dir.tar.gz" ]]; then
            local dumps
            dumps="$(tar tzf "$d/project_dir.tar.gz" 2>/dev/null | grep -E '/db-dumps/[^/]+$' || true)"
            if [[ -n "$dumps" ]]; then
                while IFS= read -r line; do
                    [[ -z "$line" ]] && continue
                    echo "    • $line"
                done <<< "$dumps"
                echo
                echo "    ${C_DIM}Extract: $0 -p <project> -t <timestamp> --extract-to /tmp/restore -y${C_RESET}"
                echo "    ${C_DIM}then:    tar xzf /tmp/restore/project_dir.tar.gz -C /tmp/restore${C_RESET}"
            else
                echo "    (none)"
            fi
        else
            echo "    (no project_dir.tar.gz in the backup)"
        fi
        echo
    } >&2
}

# ==============================================================================
# 1. SCANNING
# ==============================================================================
list_projects() {
    aws_q s3api list-objects-v2 \
        --bucket "$SRC_BUCKET" \
        --prefix "${BACKUP_PREFIX}/" \
        --delimiter "/" \
        --query 'CommonPrefixes[].Prefix' \
        --output text 2>/dev/null \
        | tr '\t' '\n' \
        | sed "s|^${BACKUP_PREFIX}/||; s|/$||" \
        | grep -vx -e '' -e 'None' \
        | sort
}

list_timestamps() {
    local project="$1"
    aws_q s3api list-objects-v2 \
        --bucket "$SRC_BUCKET" \
        --prefix "${BACKUP_PREFIX}/${project}/" \
        --delimiter "/" \
        --query 'CommonPrefixes[].Prefix' \
        --output text 2>/dev/null \
        | tr '\t' '\n' \
        | sed "s|^${BACKUP_PREFIX}/${project}/||; s|/$||" \
        | grep -vx -e '' -e 'None' \
        | sort -r
}

# Get the archive size of a specific backup
get_archive_size() {
    local project="$1" timestamp="$2" size
    size="$(aws_q s3api list-objects-v2 \
        --bucket "$SRC_BUCKET" \
        --prefix "${BACKUP_PREFIX}/${project}/${timestamp}/" \
        --query 'Contents[0].Size' --output text 2>/dev/null)" || size=0
    # An empty result comes back as the text "None": only a number goes on, or the caller's arithmetic fails
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    echo "$size"
}

# ==============================================================================
# 2. --list MODE
# ==============================================================================
if [[ "$LIST_MODE" == "true" ]]; then
    log_step "🔍 Scanning s3://${SRC_BUCKET}/${BACKUP_PREFIX}/ ..."
    mapfile -t PROJECTS_LIST < <(list_projects)

    if [[ ${#PROJECTS_LIST[@]} -eq 0 ]]; then
        log_warn "There are no backups in S3"
        exit 0
    fi

    if [[ -n "$PROJECT_ARG" ]]; then
        # Given projects (-p a,b) — a list of backups with sizes for each
        IFS=',' read -ra LIST_ARGS <<< "$PROJECT_ARG"
        for LIST_PROJECT in "${LIST_ARGS[@]}"; do
            LIST_PROJECT="${LIST_PROJECT// /}"
            [[ -n "$LIST_PROJECT" ]] || continue
            echo
            echo "${C_BOLD}📅 Backups of project '${LIST_PROJECT}':${C_RESET}"
            echo "──────────────────────────────────────────────────────────────"
            printf "  %-25s  %-15s  %s\n" "Date" "Age" "Size"
            echo "──────────────────────────────────────────────────────────────"

            mapfile -t TIMESTAMPS_LIST < <(list_timestamps "$LIST_PROJECT")
            if ! printf '%s\n' "${PROJECTS_LIST[@]}" | grep -qxF -- "$LIST_PROJECT"; then
                # A compose project's name may differ from its folder (mailcow sets COMPOSE_PROJECT_NAME=mailcowdockerized
                # in /opt/mailcow-dockerized/.env): say which names the storage has
                echo "  ${C_YELLOW}No project '${LIST_PROJECT}' ${SRC_S3_PREP}.${C_RESET}"
                echo "  ${C_DIM}Projects there: $(join_list "${PROJECTS_LIST[@]}")${C_RESET}"
            elif [[ ${#TIMESTAMPS_LIST[@]} -eq 0 ]]; then
                echo "  ${C_DIM}(no backups)${C_RESET}"
            else
                for ts in "${TIMESTAMPS_LIST[@]}"; do
                    age="$(ts_age "$ts")" || age="—"
                    size=$(get_archive_size "$LIST_PROJECT" "$ts")
                    size_mb=$((size / 1048576))
                    printf "  %-25s  %-15s  %d MB\n" "$ts" "$age" "$size_mb"
                done
            fi
            echo "──────────────────────────────────────────────────────────────"
        done
    else
        # All projects — a compact overview
        echo
        echo "${C_BOLD}📦 Projects ${SRC_S3_PREP}:${C_RESET}"
        echo "──────────────────────────────────────────────────────────────"
        printf "  %-45s %-10s %s\n" "Project" "Backups" "Latest"
        echo "──────────────────────────────────────────────────────────────"
        for p in "${PROJECTS_LIST[@]}"; do
            mapfile -t ts_list < <(list_timestamps "$p")
            count="${#ts_list[@]}"
            if (( count > 0 )); then
                last_info="$(ts_age "${ts_list[0]}")" || last_info="${ts_list[0]}"
            else
                last_info="—"
            fi
            printf "  %-45s %-10s %s\n" "$p" "$count" "$last_info"
        done
        echo "──────────────────────────────────────────────────────────────"
        echo "${C_DIM}More on a specific project: $0 --list -p <name>${C_RESET}"
    fi
    exit 0
fi

# ==============================================================================
# 3. SINGLE CHOICE
# ==============================================================================
choose_one_from_list() {
    local prompt="$1"; shift
    local items=("$@")
    [[ ${#items[@]} -eq 0 ]] && return 1

    {
        echo
        echo "${C_BOLD}$prompt${C_RESET}"
        echo "──────────────────────────────────────────────"
        local i=1
        for item in "${items[@]}"; do
            printf "  ${C_CYAN}%2d)${C_RESET} %s\n" "$i" "$item"
            i=$((i + 1))
        done
        echo "──────────────────────────────────────────────"
    } >&2

    local choice
    while true; do
        read -rp "Enter a number [1-${#items[@]}]: " choice </dev/tty >&2
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#items[@]} )); then
            printf '%s\n' "${items[$((choice - 1))]}"
            return 0
        fi
        echo "${C_RED}Invalid choice, try again.${C_RESET}" >&2
    done
}

# ==============================================================================
# 4. MULTI-SELECT
# ==============================================================================
choose_many_from_list() {
    local prompt="$1"; shift
    local items=("$@")
    local n=${#items[@]}
    [[ $n -eq 0 ]] && return 1

    {
        echo
        echo "${C_BOLD}$prompt${C_RESET}"
        echo "──────────────────────────────────────────────"
        local i=1
        for item in "${items[@]}"; do
            printf "  ${C_CYAN}%2d)${C_RESET} %s\n" "$i" "$item"
            i=$((i + 1))
        done
        echo "──────────────────────────────────────────────"
        echo "${C_DIM}Allowed: one number (3), a list (1,3,5), a range (1-5),"
        echo "       a mix (1-3,5,7-9) or 'all' for everything.${C_RESET}"
    } >&2

    local input
    while true; do
        read -rp "Your choice [1-${n}, all]: " input </dev/tty >&2
        input="${input// /}"
        [[ -z "$input" ]] && { echo "${C_RED}Empty input${C_RESET}" >&2; continue; }

        if [[ "${input,,}" == "all" ]]; then
            for item in "${items[@]}"; do
                printf '%s\n' "$item"
            done
            return 0
        fi

        if [[ ! "$input" =~ ^[0-9,-]+$ ]]; then
            echo "${C_RED}Invalid format. Use digits, commas and hyphens.${C_RESET}" >&2
            continue
        fi

        declare -A picked=()
        local valid=true
        local part start end k
        IFS=',' read -ra parts <<< "$input"
        for part in "${parts[@]}"; do
            [[ -z "$part" ]] && { valid=false; break; }
            if [[ "$part" == *-* ]]; then
                start="${part%-*}"
                end="${part#*-}"
                if ! [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]]; then
                    valid=false; break
                fi
                if (( start < 1 || end > n || start > end )); then
                    valid=false; break
                fi
                for ((k=start; k<=end; k++)); do
                    picked[$k]=1
                done
            else
                if ! [[ "$part" =~ ^[0-9]+$ ]] || (( part < 1 || part > n )); then
                    valid=false; break
                fi
                picked[$part]=1
            fi
        done

        if [[ "$valid" != "true" ]]; then
            echo "${C_RED}Invalid range. Allowed numbers are 1-${n}.${C_RESET}" >&2
            continue
        fi

        for k in $(echo "${!picked[@]}" | tr ' ' '\n' | sort -n); do
            printf '%s\n' "${items[$((k - 1))]}"
        done
        return 0
    done
}

# ==============================================================================
# 5. CHOOSING PROJECTS
# ==============================================================================
log_step "🔍 Scanning projects ${SRC_S3_PREP}: s3://${SRC_BUCKET}/${BACKUP_PREFIX}/ ..."
mapfile -t PROJECTS_LIST < <(list_projects)
[[ ${#PROJECTS_LIST[@]} -eq 0 ]] && fail "Not a single backup found ${SRC_S3_PREP}"

declare -a SELECTED_PROJECTS=()

if [[ -z "$PROJECT_ARG" ]]; then
    declare -a PROJECT_PRETTY_LIST=()
    declare -A PRETTY_TO_NAME=()
    for p in "${PROJECTS_LIST[@]}"; do
        mapfile -t p_timestamps < <(list_timestamps "$p")
        p_count="${#p_timestamps[@]}"
        if (( p_count > 0 )); then
            if age="$(ts_age "${p_timestamps[0]}")"; then
                line="$p   [$p_count $(plural "$p_count" backup backups), latest $age]"
            else
                line="$p   [$p_count backups]"
            fi
        else
            line="$p   [no backups]"
        fi
        PROJECT_PRETTY_LIST+=("$line")
        PRETTY_TO_NAME["$line"]="$p"
    done

    need_tty "give the projects with -p"
    mapfile -t chosen_lines < <(choose_many_from_list "📦 Available projects:" "${PROJECT_PRETTY_LIST[@]}")
    for line in "${chosen_lines[@]}"; do
        SELECTED_PROJECTS+=("${PRETTY_TO_NAME[$line]}")
    done
else
    IFS=',' read -ra raw <<< "$PROJECT_ARG"
    for p in "${raw[@]}"; do
        p="${p// /}"
        [[ -z "$p" ]] && continue
        found=false
        for existing in "${PROJECTS_LIST[@]}"; do
            [[ "$existing" == "$p" ]] && { found=true; break; }
        done
        [[ "$found" == "true" ]] || fail "Project '$p' not found. Available: $(join_list "${PROJECTS_LIST[@]}")"
        SELECTED_PROJECTS+=("$p")
    done
fi

[[ ${#SELECTED_PROJECTS[@]} -eq 0 ]] && fail "No project selected"

log_ok "Projects selected: ${#SELECTED_PROJECTS[@]}  ($(join_list "${SELECTED_PROJECTS[@]}"))"

if [[ ${#SELECTED_PROJECTS[@]} -gt 1 && -n "$RESTORE_DIR" ]]; then
    log_warn "--dir is ignored with multi-select: each project is restored to its original path"
    RESTORE_DIR=""
fi

# ==============================================================================
# 6. CHOOSING A DATE FOR EACH
# ==============================================================================
declare -A PROJECT_TIMESTAMP=()
declare -A PROJECT_ARCHIVE_NAME=()  # file name (including .gpg if encrypted)

# Where the dump of a remote database (_db_<name>) is put: --extract-to, -d, or WORK_DIR/restored
remote_dump_dest() { printf '%s' "${EXTRACT_TO:-${RESTORE_DIR:-${WORK_DIR:-/var/tmp/docker-backup}/restored}}"; }

# Find the archive name for project/timestamp (allowing for a possible .gpg)
find_archive_name() {
    local project="$1" timestamp="$2"
    local listing
    listing="$(aws_q s3api list-objects-v2 \
        --bucket "$SRC_BUCKET" \
        --prefix "${BACKUP_PREFIX}/${project}/${timestamp}/" \
        --query 'Contents[].Key' --output text 2>/dev/null || true)"
    # Take the first file, skipping the checksum manifest
    echo "$listing" | tr '\t' '\n' | grep -v '\.sha256$' | head -n1 | xargs -I{} basename {}
}

for proj in "${SELECTED_PROJECTS[@]}"; do
    mapfile -t TIMESTAMPS_LIST < <(list_timestamps "$proj")
    if [[ ${#TIMESTAMPS_LIST[@]} -eq 0 ]]; then
        log_warn "No backups for '$proj' — skipping"
        continue
    fi

    if [[ -n "$TIMESTAMP_ARG" ]]; then
        found=false
        for ts in "${TIMESTAMPS_LIST[@]}"; do
            [[ "$ts" == "$TIMESTAMP_ARG" ]] && { found=true; break; }
        done
        if [[ "$found" != "true" ]]; then
            log_warn "No backup from '$TIMESTAMP_ARG' for '$proj' — skipping"
            continue
        fi
        PROJECT_TIMESTAMP["$proj"]="$TIMESTAMP_ARG"
    else
        declare -a PRETTY_LIST=()
        for ts in "${TIMESTAMPS_LIST[@]}"; do
            if age="$(ts_age "$ts")"; then
                PRETTY_LIST+=("$ts   ($age)")
            else
                PRETTY_LIST+=("$ts")
            fi
        done

        need_tty "give the timestamp with -t"
        chosen="$(choose_one_from_list "📅 Date for project '$proj':" "${PRETTY_LIST[@]}")"
        PROJECT_TIMESTAMP["$proj"]="$(echo "$chosen" | awk '{print $1}')"
    fi

    archive_name="$(find_archive_name "$proj" "${PROJECT_TIMESTAMP[$proj]}")"
    PROJECT_ARCHIVE_NAME["$proj"]="$archive_name"
    log_info "  → '$proj' will be restored from ${PROJECT_TIMESTAMP[$proj]} (${archive_name})"
done

[[ ${#PROJECT_TIMESTAMP[@]} -eq 0 ]] && fail "No valid project/date pair selected"

# ==============================================================================
# 7. CONFIRMATION
# ==============================================================================
{
    echo
    echo "${C_BOLD}${C_BLUE}═══════════════════════════════════════════════════════════════${C_RESET}"
    echo "${C_BOLD}  RESTORE PLAN:${C_RESET}"
    echo "${C_BOLD}${C_BLUE}═══════════════════════════════════════════════════════════════${C_RESET}"
    for proj in "${SELECTED_PROJECTS[@]}"; do
        ts="${PROJECT_TIMESTAMP[$proj]:-}"
        [[ -z "$ts" ]] && continue
        archive="${PROJECT_ARCHIVE_NAME[$proj]:-}"
        encrypted=""
        [[ "$archive" == *.gpg ]] && encrypted=" ${C_MAGENTA}🔐${C_RESET}"
        echo "  • $proj  ←  $ts${encrypted}"
        if [[ "$proj" == _db_* && "$CONTENTS_MODE" != "true" ]]; then
            echo "      ${C_CYAN}a remote database: its dump is saved to $(remote_dump_dest), nothing is loaded into a database${C_RESET}"
        fi
    done
    if [[ "$CONTENTS_MODE" == "true" ]]; then
        echo "  Mode:    ${C_CYAN}view contents only${C_RESET}"
    elif [[ -n "$EXTRACT_TO" ]]; then
        echo "  Mode:    ${C_CYAN}unpack into ${EXTRACT_TO}${C_RESET}"
    elif [[ -n "$ONLY_VOLUME" ]]; then
        echo "  Mode:    ${C_CYAN}volume '${ONLY_VOLUME}' only${C_RESET}"
    else
        echo "  Target:  ${RESTORE_DIR:-<original path from the metadata>}"
        echo "  Start:   $([[ "$SKIP_START" == "true" ]] && echo "${C_YELLOW}NO${C_RESET}" || echo "${C_GREEN}YES (docker compose up -d)${C_RESET}")"
    fi
    echo "${C_BOLD}${C_BLUE}═══════════════════════════════════════════════════════════════${C_RESET}"
    if [[ "$READONLY_MODE" == "true" ]]; then
        echo "  ${C_GREEN}✓  Data on the host is not changed — read-only from S3${C_RESET}"
    else
        echo "  ${C_YELLOW}⚠  Existing data on the host may be overwritten!${C_RESET}"
    fi
    echo "${C_BOLD}${C_BLUE}═══════════════════════════════════════════════════════════════${C_RESET}"
} >&2

# The --contents and --extract-to modes have no destructive effects, nothing to ask
if [[ "$NON_INTERACTIVE" != "true" && "$READONLY_MODE" != "true" ]]; then
    need_tty "confirm with -y"
    read -rp "Continue? [y/yes]: " confirm </dev/tty
    is_yes "$confirm" || { log "Cancelled."; exit 0; }
fi

# ==============================================================================
# 8. RESTORING ONE PROJECT
# ==============================================================================

# restore_remote_dump <name> <dump file, decrypted> — a remote database is not loaded: that would overwrite
# a live database on another server. Its dump is saved (mode 600), with the command that loads it.
restore_remote_dump() {
    local name="$1" file="$2" base dest kind type host port user db where head
    base="$(basename "$file")"
    type="$(remote_db_var "$name" TYPE)"
    case "$base" in
        *.rdb.gz)     kind=redis ;;
        *.archive.gz) kind=mongo ;;
        *.sql.gz)
            head="$(gunzip -c "$file" 2>/dev/null | head -n 20 || true)"
            if grep -qE 'PostgreSQL database (cluster )?dump' <<< "$head"; then kind=postgres
            else kind=mysql; fi ;;
        *) kind=unknown ;;
    esac
    if [[ "$CONTENTS_MODE" == "true" ]]; then
        {
            echo
            echo "${C_BOLD}🗄  The dump of the remote database ${name}${C_RESET}"
            echo "    ${base}  $(du -h "$file" | awk '{print $1}')  (${kind})"
            [[ -n "$type" ]] && echo "    In backup.conf now: $(remote_db_desc "$name")"
            if [[ "$kind" == postgres || "$kind" == mysql ]]; then
                echo "    ${C_DIM}It begins:${C_RESET}"
                gunzip -c "$file" 2>/dev/null | grep -v '^[[:space:]]*$' | head -n 5 | sed 's/^/      /' || true
            fi
        } >&2
        return 0
    fi
    dest="$(remote_dump_dest)"
    mkdir -p "$dest" || { log_err "Cannot create $dest"; return 1; }
    # Moved, not copied: the dump may be big. Its folder here (a mktemp -d) is private until then.
    chmod 600 "$file"
    mv -f "$file" "$dest/$base" || { log_err "Could not move the dump to $dest"; return 1; }
    log_done "The dump of the remote database $name is saved: $dest/$base (nothing was loaded into a database)"

    host="$(remote_db_var "$name" HOST)"; host="${host:-HOST}"
    port="$(remote_db_var "$name" PORT)"; user="$(remote_db_var "$name" USER)"; db="$(remote_db_var "$name" DATABASE)"
    [[ -n "$port" ]] || port="$(remote_db_default_port "${type:-$kind}")"
    where="-h ${host} -p ${port}"
    {
        echo "  To load it (the database is overwritten where the dump has the same objects; try a test server first):"
        case "$kind" in
            postgres)
                if [[ -n "$db" ]]; then echo "    gunzip -c $dest/$base | psql $where -U ${user:-postgres} -d $db"
                else echo "    gunzip -c $dest/$base | psql $where -U ${user:-postgres} -d postgres"; fi ;;
            mysql)
                local cl=mysql; [[ "$type" == mariadb ]] && cl=mariadb
                echo "    gunzip -c $dest/$base | $cl -h $host -P $port -u ${user:-root} -p" ;;
            mongo)
                if [[ "$host" == *://* ]]; then where="--uri=$host"; else where="--host $host --port $port"; fi
                echo "    mongorestore $where${user:+ --username $user --authenticationDatabase admin} --archive=$dest/$base --gzip --drop" ;;
            redis)
                echo "    Redis takes a dump as its RDB file: gunzip it, stop the server, put it in its data folder"
                echo "    as dump.rdb (CONFIG GET dir / dbfilename), start it. A managed Redis: the service's own import." ;;
            *)  echo "    (an unknown kind of dump: $base)" ;;
        esac
        echo "  Delete the file when done: it is the whole database, unencrypted."
    } >&2
    return 0
}
restore_one_project() {
    local PROJECT="$1"
    local TIMESTAMP="$2"
    local ARCHIVE_NAME="$3"

    log ""
    log "${C_BOLD}${C_BLUE}===================================================================${C_RESET}"
    log_step "Restoring: $PROJECT @ $TIMESTAMP"
    log "${C_BOLD}${C_BLUE}===================================================================${C_RESET}"

    local S3_KEY="${BACKUP_PREFIX}/${PROJECT}/${TIMESTAMP}/${ARCHIVE_NAME}"
    local S3_URL="s3://${SRC_BUCKET}/${S3_KEY}"

    aws_q s3 ls "$S3_URL" >/dev/null 2>&1 \
        || { log_err "Archive not found: $S3_URL"; return 1; }

    # In WORK_DIR, like the backup, not in /tmp: volume archives are mounted into a helper container from here,
    # and Docker from snap (and rootless or remote setups) does not see the host's /tmp
    local TMP_DIR work="${WORK_DIR:-/var/tmp/docker-backup}"
    mkdir -p "$work" || { log_err "Cannot create WORK_DIR $work"; return 1; }
    TMP_DIR="$(mktemp -d "${work}/restore.XXXXXX")" || { log_err "Cannot create a temporary folder in $work"; return 1; }
    # shellcheck disable=SC2064
    trap "rm -rf '$TMP_DIR'" RETURN

    log "  ⬇  Downloading the archive ${SRC_S3_GEN}..."
    # Progress on a terminal; in a log or a pipe a progress line per chunk is noise — errors only there
    local -a quiet=(); [[ -t 2 ]] || quiet=(--only-show-errors)
    aws_q s3 cp "$S3_URL" "${TMP_DIR}/${ARCHIVE_NAME}" ${quiet[@]+"${quiet[@]}"} \
        || { log_err "Could not download $S3_URL"; return 1; }

    # Check against the sha256 manifest, if there is one next to the archive. The size already matched
    # by the download itself — the hash checks that the content is not corrupted.
    if aws_q s3 cp "${S3_URL}.sha256" "${TMP_DIR}/${ARCHIVE_NAME}.sha256" >/dev/null 2>&1; then
        log "  🔢 Checking sha256..."
        if verify_checksum_file "${TMP_DIR}/${ARCHIVE_NAME}" "${TMP_DIR}/${ARCHIVE_NAME}.sha256"; then
            log_ok "    Checksum matches"
        else
            log_err "    sha256 does NOT match — the archive is corrupted, restore aborted"
            log_err "    Try another date or another storage (--from secondary|tertiary)"
            return 1
        fi
    else
        log_warn "    No sha256 manifest — nothing to check the content against, only the size was checked"
    fi

    # Decrypt if needed
    local backup_archive="${TMP_DIR}/${ARCHIVE_NAME}"
    if [[ "$ARCHIVE_NAME" == *.gpg ]]; then
        log "  🔐 Decrypting..."
        backup_archive="$(decrypt_file "$backup_archive")" \
            || { log_err "Decryption failed — check GPG_PASSPHRASE_FILE"; return 1; }
    fi

    if [[ "$PROJECT" == _db_* ]]; then
        restore_remote_dump "${PROJECT#_db_}" "$backup_archive"
        return
    fi

    log "  📂 Unpacking..."
    mkdir -p "${TMP_DIR}/extracted"
    tar xzf "$backup_archive" -C "${TMP_DIR}/extracted" \
        || { log_err "Could not unpack the archive"; return 1; }

    local PROJ_BACKUP_DIR="${TMP_DIR}/extracted/${PROJECT}"
    [[ -d "$PROJ_BACKUP_DIR" ]] || { log_err "The archive has no ${PROJECT} folder"; return 1; }

    # ─── Granular modes: change nothing on the host ───
    if [[ "$CONTENTS_MODE" == "true" ]]; then
        show_backup_contents "$PROJ_BACKUP_DIR"
        return 0
    fi

    if [[ -n "$EXTRACT_TO" ]]; then
        local dest="${EXTRACT_TO%/}"
        [[ ${#SELECTED_PROJECTS[@]} -gt 1 ]] && dest="${dest}/${PROJECT}"
        mkdir -p "$dest"
        cp -a "${PROJ_BACKUP_DIR}/." "${dest}/" \
            || { log_err "Could not copy to $dest"; return 1; }
        log_done "Unpacked into ${dest} — nothing changed on the host"
        log "  Inside: volumes/, binds/, project_dir.tar.gz, inspect/, metadata.txt"
        return 0
    fi

    local META="${PROJ_BACKUP_DIR}/metadata.txt"
    local ORIGINAL_DIR=""
    if [[ -f "$META" ]]; then
        log "  📋 Metadata:"
        sed 's/^/      /' "$META" >&2
        ORIGINAL_DIR="$(grep '^PROJECT_DIR=' "$META" | cut -d= -f2- || true)"
    fi

    local TARGET_DIR="${RESTORE_DIR:-$ORIGINAL_DIR}"

    # 8.1 — Project folder (left alone in --only-volume mode)
    if [[ -n "$ONLY_VOLUME" ]]; then
        log_info "  --only-volume mode: leaving the project folder and bind mounts alone"
    elif [[ -f "${PROJ_BACKUP_DIR}/project_dir.tar.gz" ]]; then
        if [[ -n "$TARGET_DIR" ]]; then
            log "  📂 Restoring the project folder to: $TARGET_DIR"
            local parent_dir; parent_dir="$(dirname "$TARGET_DIR")"
            mkdir -p "$parent_dir"

            if [[ -e "$TARGET_DIR" && "$NON_INTERACTIVE" != "true" ]]; then
                need_tty "confirm overwriting with -y"
                read -rp "    Directory $TARGET_DIR exists. Overwrite? [y/yes]: " ow </dev/tty
                is_yes "$ow" || { log "    Cancelled for $PROJECT"; return 1; }
            fi
            if [[ -e "$TARGET_DIR" ]]; then
                local backup_existing
                backup_existing="${TARGET_DIR}.before-restore-$(date +%s)"
                log "    📦 Saving the current folder to: $backup_existing"
                mv "$TARGET_DIR" "$backup_existing"
            fi

            tar xzf "${PROJ_BACKUP_DIR}/project_dir.tar.gz" -C "$parent_dir" \
                || { log_err "Could not unpack project_dir.tar.gz"; return 1; }

            local extracted_name
            extracted_name="$(tar tzf "${PROJ_BACKUP_DIR}/project_dir.tar.gz" | head -1 | cut -d/ -f1)"
            if [[ "$(basename "$TARGET_DIR")" != "$extracted_name" && -d "${parent_dir}/${extracted_name}" ]]; then
                mv "${parent_dir}/${extracted_name}" "$TARGET_DIR"
            fi
            log_ok "    Project folder restored"
        else
            log_warn "TARGET_DIR is not determined, skipping the folder restore"
        fi
    else
        log_info "No project_dir.tar.gz in the backup"
    fi

    # 8.2 — Named volumes
    #
    # Order matters: first make sure the archive is readable at all, then
    # unpack it into a TEMPORARY volume, and only after that succeeds replace
    # the working volume's contents. The data used to be deleted in the same command as the unpack
    # ("find -delete; tar xzf"), so a broken archive meant losing both the old and the
    # new — and it came out in the middle of an incident.
    # Every part that did not come back counts: the project is then reported as failed and not started
    # (Postgres on an empty volume would quietly make a new empty database, and it would look fine).
    local part_errors=0
    if [[ -d "${PROJ_BACKUP_DIR}/volumes" ]]; then
        log "  💾 Restoring named volumes..."
        local restored_vols=0
        for vol_archive in "${PROJ_BACKUP_DIR}/volumes/"volume_*.tar.gz; do
            [[ -f "$vol_archive" ]] || continue
            local vol_name; vol_name="$(basename "$vol_archive" .tar.gz | sed 's/^volume_//')"

            [[ -n "$ONLY_VOLUME" && "$vol_name" != "$ONLY_VOLUME" ]] && continue

            log "    💾 Volume: $vol_name"

            local vol_users
            vol_users="$(docker ps -q --filter "volume=${vol_name}" 2>/dev/null | wc -l)"
            if (( vol_users > 0 )); then
                log_warn "      The volume is used by ${vol_users} running container(s) — better stop them"
            fi

            # 1) Is the archive readable?
            if ! tar tzf "$vol_archive" >/dev/null 2>&1; then
                log_err "      The volume archive is corrupted — skipping, current data untouched"
                part_errors=$((part_errors + 1))
                continue
            fi

            # 2) Unpack into a temporary volume
            local tmp_vol="${vol_name}__restore_$$"
            if ! docker volume create "$tmp_vol" >/dev/null 2>&1; then
                log_err "      Could not create a temporary volume — skipping"
                part_errors=$((part_errors + 1))
                continue
            fi
            if ! docker run --rm \
                    -v "${tmp_vol}:/target" \
                    -v "${vol_archive}:/backup.tar.gz:ro" \
                    alpine:latest \
                    sh -c "gzip -dc /backup.tar.gz | tar -xf - -C /target"; then
                log_err "      Unpacking failed — the working volume is untouched"
                docker volume rm "$tmp_vol" >/dev/null 2>&1 || true
                part_errors=$((part_errors + 1))
                continue
            fi

            # 3) The data is verified — replace the working volume's contents
            docker volume create "$vol_name" >/dev/null
            if docker run --rm \
                    -v "${tmp_vol}:/from:ro" \
                    -v "${vol_name}:/to" \
                    alpine:latest \
                    sh -c 'find /to -mindepth 1 -delete && cp -a /from/. /to/'; then
                log_ok "      $vol_name restored"
                restored_vols=$((restored_vols + 1))
                docker volume rm "$tmp_vol" >/dev/null 2>&1 || true
            else
                # The working volume may be half-empty now — the verified data stays in the temporary
                # one: deleting it would leave no good copy on the host
                log_err "      Error moving data into $vol_name — the unpacked backup is kept in volume ${tmp_vol}"
                log_err "      Copy it over by hand: docker run --rm -v ${tmp_vol}:/from:ro -v ${vol_name}:/to alpine cp -a /from/. /to/"
                part_errors=$((part_errors + 1))
            fi
        done

        # Single-volume mode — that's all, leave the rest alone
        if [[ -n "$ONLY_VOLUME" ]]; then
            (( part_errors == 0 )) || return 1
            if (( restored_vols == 0 )); then
                log_err "Volume '$ONLY_VOLUME' not found in this backup"
                return 1
            fi
            log_done "Volume '$ONLY_VOLUME' restored (project folder and the other volumes untouched)"
            log "  Restart the project if it was running: docker compose restart"
            return 0
        fi
    elif [[ -n "$ONLY_VOLUME" ]]; then
        log_err "There is not a single named volume in the backup"
        return 1
    fi

    # 8.3 — Bind mounts (with the blacklist)
    if [[ -z "$ONLY_VOLUME" ]] && [[ -d "${PROJ_BACKUP_DIR}/binds" ]] && [[ -d "${PROJ_BACKUP_DIR}/inspect" ]]; then
        log "  📁 Restoring bind mounts..."
        declare -A BIND_MAP=()
        for ifile in "${PROJ_BACKUP_DIR}/inspect/"*.json; do
            [[ -f "$ifile" ]] || continue
            while IFS= read -r src; do
                [[ -z "$src" ]] && continue
                if echo "$src" | grep -Eq "$BIND_BLACKLIST_REGEX"; then
                    continue
                fi
                # Inside the project folder — restored with project_dir.tar.gz above
                path_within "$src" "${TARGET_DIR:-}" && continue
                path_within "$src" "${ORIGINAL_DIR:-}" && continue

                local safe_name; safe_name="$(echo "$src" | sed 's|/|_|g; s|^_||')"
                [[ -z "$safe_name" ]] && continue
                BIND_MAP["$safe_name"]="$src"
            done < <(jq -r '.[0].Mounts[]? | select(.Type=="bind") | .Source' "$ifile" 2>/dev/null || true)
        done

        for bind_archive in "${PROJ_BACKUP_DIR}/binds/"bind_*.tar.gz; do
            [[ -f "$bind_archive" ]] || continue
            local archive_basename; archive_basename="$(basename "$bind_archive" .tar.gz)"
            local target_path
            target_path="$(bind_target_for "$archive_basename")"
            if [[ -z "$target_path" ]]; then
                log_warn "Cannot determine the path for $archive_basename — skipping"
                continue
            fi
            log "    📁 Bind: $target_path"
            mkdir -p "$(dirname "$target_path")"
            if [[ -e "$target_path" && "$NON_INTERACTIVE" != "true" ]]; then
                need_tty "confirm overwriting with -y"
                read -rp "      $target_path exists. Overwrite? [y/yes]: " ow </dev/tty
                if ! is_yes "$ow"; then
                    log "      Skipped"; continue
                fi
            fi
            [[ -e "$target_path" ]] && clear_bind_target "$target_path"
            if ! tar xzf "$bind_archive" -C "$(dirname "$target_path")"; then
                log_err "      Error unpacking $archive_basename"
                part_errors=$((part_errors + 1))
            fi
        done
    fi

    # 8.4 — Images
    if [[ -z "$ONLY_VOLUME" ]] && [[ -d "${PROJ_BACKUP_DIR}/images" ]]; then
        log "  🐳 Loading Docker images..."
        for img_file in "${PROJ_BACKUP_DIR}/images/"*.tar.gz; do
            [[ -f "$img_file" ]] || continue
            log "    🐳 $(basename "$img_file")"
            gunzip -c "$img_file" | docker load || { log_err "    docker load error"; part_errors=$((part_errors + 1)); }
        done
    fi

    if (( part_errors > 0 )); then
        log_err "$PROJECT: restore INCOMPLETE — ${part_errors} part(s) did not come back (see above)."
        log_err "  The project is NOT started, so it does not come up on missing data."
        return 1
    fi

    # 8.5 — Start
    if [[ -z "$ONLY_VOLUME" && "$SKIP_START" != "true" && -n "$TARGET_DIR" && -d "$TARGET_DIR" ]]; then
        local compose_file=""
        for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
            [[ -f "${TARGET_DIR}/${f}" ]] && { compose_file="$f"; break; }
        done
        if [[ -n "$compose_file" ]]; then
            # -f: the file found above, whatever its name. -p in place: the project keeps
            # its own name (and so its restored volumes, PROJECT_*) even if it was not named after its folder.
            local -a up_args=(-f "$compose_file")
            [[ -z "$RESTORE_DIR" ]] && up_args=(-p "$PROJECT" "${up_args[@]}")
            log "  🚀 Starting: cd $TARGET_DIR && docker compose$(printf ' %q' "${up_args[@]}") up -d"
            local up_rc=0
            (cd "$TARGET_DIR" && docker_compose "${up_args[@]}" up -d) || up_rc=$?
            echo >&2
            log "  📊 Status of the project's containers:"
            docker ps -a --filter "label=com.docker.compose.project=$PROJECT" \
                --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' >&2
            if (( up_rc != 0 )); then
                log_err "$PROJECT: the data is restored, but docker compose up failed (exit ${up_rc})"
                return 1
            fi
        else
            log_warn "No compose file found in $TARGET_DIR — start skipped"
        fi
    fi

    log_done "$PROJECT restored successfully"
}

# ==============================================================================
# 9. MAIN LOOP
# ==============================================================================
SUCCESS=0
FAILED=0
declare -a FAILED_LIST=()

for proj in "${SELECTED_PROJECTS[@]}"; do
    ts="${PROJECT_TIMESTAMP[$proj]:-}"
    [[ -z "$ts" ]] && continue
    archive="${PROJECT_ARCHIVE_NAME[$proj]:-}"
    [[ -z "$archive" ]] && { log_warn "Archive for $proj not found"; FAILED=$((FAILED + 1)); FAILED_LIST+=("$proj"); continue; }

    if restore_one_project "$proj" "$ts" "$archive"; then
        SUCCESS=$((SUCCESS + 1))
    else
        FAILED=$((FAILED + 1))
        FAILED_LIST+=("$proj")
    fi
done

{
    echo
    echo "${C_BOLD}${C_BLUE}═══════════════════════════════════════════════════════════════${C_RESET}"
    echo "${C_BOLD}  RESTORE SUMMARY:${C_RESET}"
    echo "  ${C_GREEN}✅ Succeeded:  $SUCCESS${C_RESET}"
    echo "  ${C_RED}❌ Failed:     $FAILED${C_RESET}"
    [[ $FAILED -gt 0 ]] && echo "     Problematic: $(join_list "${FAILED_LIST[@]}")"
    echo "${C_BOLD}${C_BLUE}═══════════════════════════════════════════════════════════════${C_RESET}"
} >&2

# Exit code for scripts and the menu: 1 if any project failed
[[ "$FAILED" -eq 0 ]] || exit 1
