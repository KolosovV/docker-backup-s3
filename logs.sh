#!/usr/bin/env bash
# ==============================================================================
# logs.sh
# Convenient viewing of docker-backup logs with filters and highlighting.
#
# Usage:
#   sudo ./logs.sh                    # the last 50 lines of all logs
#   sudo ./logs.sh -f                 # follow (like tail -f)
#   sudo ./logs.sh --errors           # errors only
#   sudo ./logs.sh --last-run         # the whole last run
#   sudo ./logs.sh --project foo      # only entries about a specific project
#   sudo ./logs.sh --since '2 hours ago'
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/backup.conf"

# --- Arguments ---
N_LINES=50
FOLLOW="false"
ERRORS_ONLY="false"
LAST_RUN="false"
PROJECT_FILTER=""
SINCE=""
LOG_TYPE="all"   # all | backup | cron

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--lines)     N_LINES="$2"; shift 2 ;;
        -f|--follow)    FOLLOW="true"; shift ;;
        -e|--errors)    ERRORS_ONLY="true"; shift ;;
        -l|--last-run)  LAST_RUN="true"; shift ;;
        -p|--project)   PROJECT_FILTER="$2"; shift 2 ;;
        -s|--since)     SINCE="$2"; shift 2 ;;
        -b|--backup)    LOG_TYPE="backup"; shift ;;
        -C|--cron)      LOG_TYPE="cron"; shift ;;
        -c|--config)    CONFIG_FILE="$2"; shift 2 ;;
        -h|--help)
            cat <<EOF
Usage: $0 [options]

Viewing and filtering docker-backup logs.

  -n, --lines N        number of last lines (default 50, 0 = all)
  -f, --follow         follow the log in real time (like tail -f)
  -e, --errors         errors and warnings only
  -l, --last-run       the whole last run (from 🚀 to ✅/❌)
  -p, --project NAME   only entries about a specific project
  -s, --since EXPR     only entries after the given time
                       formats: '2 hours ago', '2026-05-08', 'today', '1 day ago'
  -b, --backup         only the /var/log/docker-backup.log log
  -C, --cron           only the /var/log/docker-backup-cron.log log
  -c, --config FILE    config file

  -h, --help           this help

EXAMPLES:
  The last 50 lines:            sudo $0
  Follow the log:               sudo $0 -f
  All errors for the day:       sudo $0 -e -s today
  The last run:                 sudo $0 -l
  Project foo for 2 hours:      sudo $0 -p foo -s '2 hours ago'
  All errors, everything:       sudo $0 -e -n 0
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

# ==============================================================================
# Determine the list of log files
# ==============================================================================
LOG_FILES=()

case "$LOG_TYPE" in
    all)
        [[ -f "${LOG_FILE:-/var/log/docker-backup.log}" ]] && LOG_FILES+=("${LOG_FILE:-/var/log/docker-backup.log}")
        [[ -f /var/log/docker-backup-cron.log ]] && LOG_FILES+=("/var/log/docker-backup-cron.log")
        ;;
    backup)
        LOG_FILES=("${LOG_FILE:-/var/log/docker-backup.log}")
        ;;
    cron)
        LOG_FILES=("/var/log/docker-backup-cron.log")
        ;;
esac

# Check that the log files exist
existing_logs=()
for f in "${LOG_FILES[@]}"; do
    if [[ -f "$f" ]]; then
        existing_logs+=("$f")
    fi
done

if [[ ${#existing_logs[@]} -eq 0 ]]; then
    echo "${C_YELLOW}⚠ No log files found yet:${C_RESET}"
    for f in "${LOG_FILES[@]}"; do
        echo "    $f"
    done
    echo
    echo "If the backup has not run yet — that's fine. Run:"
    echo "  sudo ${SCRIPT_DIR}/docker-backup.sh"
    exit 0
fi

# ==============================================================================
# Line highlighting function
# ==============================================================================
colorize() {
    # Use sed with ANSI codes embedded via bash escapes
    local red green yellow blue cyan magenta dim bold reset
    red=$'\033[31m'; green=$'\033[32m'; yellow=$'\033[33m'
    blue=$'\033[34m'; cyan=$'\033[36m'; magenta=$'\033[35m'
    dim=$'\033[2m'; bold=$'\033[1m'; reset=$'\033[0m'

    if [[ ! -t 1 ]]; then
        # Not a TTY — no colors
        cat
        return
    fi

    sed -E \
        -e "s/(❌|FAIL|ERROR)/${red}${bold}\1${reset}/gi" \
        -e "s/(⚠|WARN|warning)/${yellow}\1${reset}/gi" \
        -e "s/(✅|✓|OK|done|succeeded)/${green}\1${reset}/gi" \
        -e "s/(🚀|Starting)/${cyan}${bold}\1${reset}/g" \
        -e "s/(📦|Project:)/${blue}${bold}\1${reset}/g" \
        -e "s/(🐘|🐬|🟥|🍃|🗄)/${magenta}\1${reset}/g" \
        -e "s/(▶|🧹|☁|💾|📁|📂|🔐|🔍|🪝)/${cyan}\1${reset}/g" \
        -e "s/(\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\])/${dim}\1${reset}/g" \
        -e "s/(\[[0-9]{2}:[0-9]{2}:[0-9]{2}\])/${dim}\1${reset}/g"
}

# ==============================================================================
# Filters (optional)
# ==============================================================================
# An error or a warning: our ❌/⚠/✗ lines and what aws and other tools print when they fail. Not a bare
# "fail"/"error": "2 succeeded, 0 failed" and a path such as ./private/error are not errors.
ERRORS_RE='❌|⚠|✗|ERROR|WARN|[Ff]ailed:|An error occurred|[Ff]atal error|Traceback|No space left'

# --since: the log's timestamps ([YYYY-MM-DD HH:MM:SS]) sort as text, so they are compared as text —
# plain POSIX awk (mawk on Debian/Ubuntu, busybox), no date call per line. A line without a timestamp
# (aws's own error text, tar) belongs to the timestamped line before it.
SINCE_TS=""
if [[ -n "$SINCE" ]]; then
    # date -d today is this very moment; "since today" means from midnight
    case "$SINCE" in today|yesterday) SINCE="$SINCE 00:00" ;; esac
    SINCE_TS="$(date -d "$SINCE" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" || {
        echo "${C_RED}❌ Cannot parse the time: '$SINCE'${C_RESET}" >&2
        echo "   Examples: '2 hours ago', '2026-05-08', 'today', '1 day ago'" >&2
        exit 1
    }
fi

since_filter() {
    awk -v cutoff="$SINCE_TS" -v today="$(date +%Y-%m-%d)" '
        /^\[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\]/ { inside = (substr($0, 2, 19) >= cutoff) }
        /^\[[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\]/ { inside = ((today " " substr($0, 2, 8)) >= cutoff) }
        inside
    '
}

# filter_lines < log — the chosen filters; no matches is not an error
filter_lines() {
    if [[ -n "$SINCE_TS" ]]; then since_filter; else cat; fi \
        | if [[ "$ERRORS_ONLY" == "true" ]]; then grep -E -- "$ERRORS_RE" || true; else cat; fi \
        | if [[ -n "$PROJECT_FILTER" ]]; then grep -F -- "$PROJECT_FILTER" || true; else cat; fi
}

# ==============================================================================
# Mode: the last run
# ==============================================================================
extract_last_run() {
    local log="$1"
    [[ -f "$log" ]] || return 1

    # Find the last "🚀 ... Docker" start marker from the end of the file (new and old logs alike)
    # awk keeps lines from the start and resets on every start
    awk '
        /🚀 .*Docker/ { buffer = ""; collecting = 1 }
        collecting { buffer = buffer $0 "\n" }
        END { printf "%s", buffer }
    ' "$log"
}

if [[ "$LAST_RUN" == "true" ]]; then
    echo "${C_BOLD}${C_CYAN}━━━ Last run ━━━${C_RESET}"
    echo
    for log in "${existing_logs[@]}"; do
        content=$(extract_last_run "$log")
        if [[ -n "$content" ]]; then
            echo "${C_BOLD}${log}:${C_RESET}"
            echo "$content" | colorize
            echo
            exit 0
        fi
    done
    echo "${C_YELLOW}⚠ No run marker found in the logs. Perhaps the backup has not run yet.${C_RESET}"
    exit 0
fi

# ==============================================================================
# Follow mode
# ==============================================================================
if [[ "$FOLLOW" == "true" ]]; then
    echo "${C_BOLD}${C_CYAN}━━━ Following the logs (Ctrl+C to exit) ━━━${C_RESET}"
    for log in "${existing_logs[@]}"; do
        echo "  ${C_DIM}$log${C_RESET}"
    done
    echo

    if [[ ${#existing_logs[@]} -gt 1 ]]; then
        # Multi-tail showing the file name
        tail -n 5 -f "${existing_logs[@]}" 2>/dev/null | colorize
    else
        tail -n 20 -f "${existing_logs[0]}" 2>/dev/null | colorize
    fi
    exit 0
fi

# ==============================================================================
# Normal mode: the last N lines with filters
# ==============================================================================

# Header
desc="last $N_LINES lines"
[[ "$N_LINES" == "0" ]] && desc="all lines"
[[ "$ERRORS_ONLY" == "true" ]] && desc="$desc, errors only"
[[ -n "$PROJECT_FILTER" ]] && desc="$desc, project=$PROJECT_FILTER"
[[ -n "$SINCE" ]] && desc="$desc, since $SINCE"

echo "${C_BOLD}${C_CYAN}━━━ docker-backup logs ($desc) ━━━${C_RESET}"
echo

for log in "${existing_logs[@]}"; do
    echo "${C_BOLD}${log}:${C_RESET}"
    echo "${C_DIM}─────────────────────────────────────────────────────${C_RESET}"
    if [[ "$N_LINES" == "0" ]]; then
        filter_lines < "$log" | colorize
    else
        filter_lines < "$log" | tail -n "$N_LINES" | colorize
    fi
    echo
done
