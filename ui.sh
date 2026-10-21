#!/usr/bin/env bash
# ==============================================================================
# ui.sh — dialogs and config helpers shared by install.sh and menu.sh
#
# Dialogs: whiptail when it is installed and there is a terminal, plain prompts otherwise
# (or with UI_PLAIN=true). With NON_INTERACTIVE=true nothing is asked: every question
# returns its default. Prompts and dialogs go to the terminal (UI_TTY, /dev/tty by default),
# answers go to stdout, so  value=$(ui_input "Bucket" "")  works in both modes.
#
# Config helpers: conf_set, normalize_endpoint, the S3 certificate check (s3_cert_check).
# They log through log/log_ok/log_warn, which the sourcing script defines.
# ==============================================================================

UI_TTY="${UI_TTY:-/dev/tty}"
UI_BACKTITLE="${UI_BACKTITLE:-Docker Backup System}"
UI_TITLE=""      # title of the following dialogs (ui_title sets it)
# Text shown at the top of the next dialog (ui_note adds to it). A file, not a variable: dialogs run
# inside $(…), and a variable cleared there would stay set in the script. Created by ui_init with
# mktemp (a random name, owned by us — the scripts run as root, and a guessable /tmp path could be
# a symlink planted by someone else), emptied rather than deleted, removed on exit.
UI_NOTE_FILE=""
UI_MODE=""       # whiptail | plain | none — set by ui_init

ui_init() {
    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
        UI_MODE="none"
    elif [[ "${UI_PLAIN:-false}" != "true" && "${TERM:-dumb}" != "dumb" ]] \
         && command -v whiptail >/dev/null 2>&1 && { : <"$UI_TTY"; } 2>/dev/null; then
        UI_MODE="whiptail"
    else
        UI_MODE="plain"
    fi
    if [[ "$UI_MODE" == "whiptail" ]]; then
        if UI_NOTE_FILE="$(mktemp "${TMPDIR:-/tmp}/docker-backup-ui.XXXXXX" 2>/dev/null)"; then
            # Our own EXIT trap only if the script has none (it would replace the script's one)
            [[ -z "$(trap -p EXIT)" ]] && trap 'rm -f "$UI_NOTE_FILE"' EXIT
        else
            UI_MODE="plain"   # no temp file — no notes in dialogs; plain prompts print them right away
        fi
    fi
    # Plain prompts read from one descriptor, opened once: answers typed ahead (or a file in tests)
    # are read line by line instead of the first line every time
    if [[ "$UI_MODE" != "none" ]] && { exec {UI_IN}<"$UI_TTY"; } 2>/dev/null; then :
    else UI_IN=0; fi
}

# "\n" written in a text becomes a line break (so callers can write "line one\n\nline two")
_ui_nl() {
    printf '%s' "${1//\\n/$'\n'}"
}

# Text without ANSI colors and leading spaces (prompts in the scripts are indented for plain mode)
_ui_clean() {
    _ui_nl "$1" | sed -e 's/\x1b\[[0-9;]*m//g' -e '1s/^[[:space:]]*//'
}

# Dialog size: enough for the text, no more than the terminal. usage: _ui_size <text> [list rows]
_ui_size() {
    local text="$1" rows="${2:-0}" lines cols
    lines="$(tput lines 2>/dev/null <"$UI_TTY" || echo 24)"; cols="$(tput cols 2>/dev/null <"$UI_TTY" || echo 80)"
    UI_W=$(( cols - 4 < 76 ? cols - 4 : 76 ))
    local n; n="$(printf '%s\n' "$text" | fold -w $(( UI_W - 4 )) | wc -l)"
    UI_H=$(( n + rows + 8 ))
    (( UI_H > lines - 2 )) && UI_H=$(( lines - 2 ))
    UI_LIST=$(( rows < UI_H - n - 7 ? rows : UI_H - n - 7 ))
    (( UI_LIST < 1 )) && UI_LIST=1
    return 0
}

# Text of the next dialog: pending notes, then the prompt itself
_ui_text() {
    local t; t="$(_ui_clean "$1")"
    if [[ -n "$UI_NOTE_FILE" && -s "$UI_NOTE_FILE" ]]; then
        t="$(cat "$UI_NOTE_FILE")"$'\n\n'"${t}"
        : > "$UI_NOTE_FILE"
    fi
    printf '%s' "$t"
}

# Runs whiptail: dialog on the terminal, answer to stdout. Exit code is whiptail's (0 OK, 1 Cancel, 255 Esc).
_ui_whiptail() {
    # An array, not ${UI_TITLE:+--title "$UI_TITLE"}: with IFS=$'\n\t' that would be one word
    local -a title=()
    [[ -n "$UI_TITLE" ]] && title=(--title "$UI_TITLE")
    whiptail --backtitle "$UI_BACKTITLE" ${title[@]+"${title[@]}"} "$@" 2>&1 >"$UI_TTY" <"$UI_TTY"
}

# ui_title <text> — section heading: a title for the next dialogs, a bold line in plain mode
ui_title() {
    UI_TITLE="$(_ui_clean "$1")"
    [[ "$UI_MODE" == "plain" ]] && printf '%s\n' "${C_BOLD:-}${UI_TITLE}${C_RESET:-}"
    return 0
}

# ui_note <text> — an explanation for the next question: printed dimmed in plain mode,
# shown above the question in whiptail
ui_note() {
    case "$UI_MODE" in
        plain) printf '%s\n' "${C_DIM:-}$*${C_RESET:-}" ;;
        whiptail) printf '%s\n' "$(_ui_clean "$*")" >> "$UI_NOTE_FILE" ;;
    esac
    return 0
}

# ui_later <text> — like ui_note, but only for dialogs: in plain mode the text has already been
# printed by the log line next to it, so it is not repeated
ui_later() {
    [[ "$UI_MODE" == "whiptail" ]] && ui_note "$@"
    return 0
}

# ui_msg <text> — a message to read and confirm
ui_msg() {
    case "$UI_MODE" in
        whiptail) local t; t="$(_ui_text "$1")"; _ui_size "$t"; _ui_whiptail --scrolltext --msgbox "$t" "$UI_H" "$UI_W" ;;
        plain)    printf '%s\n' "$(_ui_nl "$1")" ;;
    esac
    return 0
}

# ui_yesno <question> [y|n] — 0 yes, 1 no
ui_yesno() {
    local prompt="$1" default="${2:-n}" ans
    case "$UI_MODE" in
        none) [[ "$default" == "y" ]]; return ;;
        whiptail)
            local t; t="$(_ui_text "$prompt")"; _ui_size "$t"
            if [[ "$default" == "y" ]]; then _ui_whiptail --yesno "$t" "$UI_H" "$UI_W" >/dev/null
            else _ui_whiptail --defaultno --yesno "$t" "$UI_H" "$UI_W" >/dev/null; fi
            return ;;
    esac
    local hint="[y/N]"; [[ "$default" == "y" ]] && hint="[Y/n]"
    read -r -u "$UI_IN" -p "$(_ui_nl "$prompt") $hint: " ans
    ans="${ans:-$default}"
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

# ui_input <prompt> [default] — a line of text. Exit code 1 if the dialog was cancelled.
ui_input() {
    local prompt="$1" default="${2:-}" var
    case "$UI_MODE" in
        none) printf '%s' "$default"; return 0 ;;
        whiptail)
            local t; t="$(_ui_text "$prompt")"; _ui_size "$t"
            var="$(_ui_whiptail --inputbox "$t" "$UI_H" "$UI_W" "$default")" || return 1
            printf '%s' "$var"; return 0 ;;
    esac
    if [[ -n "$default" ]]; then read -r -u "$UI_IN" -p "$prompt [${default}]: " var
    else read -r -u "$UI_IN" -p "$prompt: " var; fi
    printf '%s' "${var:-$default}"
}

# ui_password <prompt> — hidden input. Exit code 1 if cancelled.
ui_password() {
    local prompt="$1" var
    case "$UI_MODE" in
        none) return 0 ;;
        whiptail)
            local t; t="$(_ui_text "$prompt")"; _ui_size "$t"
            var="$(_ui_whiptail --passwordbox "$t" "$UI_H" "$UI_W")" || return 1
            printf '%s' "$var"; return 0 ;;
    esac
    read -rs -u "$UI_IN" -p "$prompt: " var
    echo >&2
    printf '%s' "$var"
}

# ui_menu <text> <tag> <item> [<tag> <item>…] — one choice; prints the tag. 1 if cancelled.
# UI_DEFAULT=<tag> preselects an item.
ui_menu() {
    local text="$1"; shift
    local n=$(( $# / 2 )) choice i
    case "$UI_MODE" in
        none) printf '%s' "${UI_DEFAULT:-$1}"; return 0 ;;
        whiptail)
            local t; t="$(_ui_text "$text")"; _ui_size "$t" "$n"
            local -a def=()
            [[ -n "${UI_DEFAULT:-}" ]] && def=(--default-item "$UI_DEFAULT")
            _ui_whiptail ${def[@]+"${def[@]}"} --menu "$t" "$UI_H" "$UI_W" "$UI_LIST" "$@"
            return ;;
    esac
    local -a tags=() items=()
    while (( $# >= 2 )); do tags+=("$1"); items+=("$2"); shift 2; done
    [[ -n "$text" ]] && printf '%s\n' "$(_ui_nl "$text")" >&2
    for i in "${!tags[@]}"; do printf '  %2d) %s\n' "$((i + 1))" "${items[$i]}" >&2; done
    while true; do
        read -r -u "$UI_IN" -p "Choice [1-${n}, q = back]: " choice || return 1
        [[ "$choice" == "q" || "$choice" == "Q" ]] && return 1
        if [[ -z "$choice" && -n "${UI_DEFAULT:-}" ]]; then printf '%s' "$UI_DEFAULT"; return 0; fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= n )); then
            printf '%s' "${tags[$((choice - 1))]}"; return 0
        fi
        printf 'Enter a number from 1 to %d.\n' "$n" >&2
    done
}

# ui_checklist <text> <tag> <item> <on|off> […] — several choices; prints tags, one per line.
# 1 if cancelled.
ui_checklist() {
    local text="$1"; shift
    local n=$(( $# / 3 )) input i part a b
    case "$UI_MODE" in
        none)
            while (( $# >= 3 )); do [[ "$3" == "on" ]] && printf '%s\n' "$1"; shift 3; done; return 0 ;;
        whiptail)
            local t; t="$(_ui_text "$text")"; _ui_size "$t" "$n"
            _ui_whiptail --separate-output --checklist "$t" "$UI_H" "$UI_W" "$UI_LIST" "$@"
            return ;;
    esac
    local -a tags=() items=()
    while (( $# >= 3 )); do tags+=("$1"); items+=("$2"); shift 3; done
    [[ -n "$text" ]] && printf '%s\n' "$(_ui_nl "$text")" >&2
    for i in "${!tags[@]}"; do printf '  %2d) %s\n' "$((i + 1))" "${items[$i]}" >&2; done
    while true; do
        read -r -u "$UI_IN" -p "Choice (3 / 1,3,5 / 1-4 / all, q = back): " input || return 1
        [[ "$input" == "q" || "$input" == "Q" ]] && return 1
        [[ "$input" == "all" ]] && { printf '%s\n' "${tags[@]}"; return 0; }
        local -a picked=() parts=()
        local ok=true
        IFS=',' read -ra parts <<< "${input// /}"
        for part in "${parts[@]}"; do
            if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
            elif [[ "$part" =~ ^[0-9]+$ ]]; then a="$part"; b="$part"
            else ok=false; break; fi
            (( a >= 1 && b <= n && a <= b )) || { ok=false; break; }
            for (( i = a; i <= b; i++ )); do picked+=("${tags[$((i - 1))]}"); done
        done
        if $ok && (( ${#picked[@]} )); then printf '%s\n' "${picked[@]}" | awk '!seen[$0]++'; return 0; fi
        printf 'Use numbers 1-%d, commas and hyphens, or all.\n' "$n" >&2
    done
}

# ui_pause — wait for Enter after a script has printed its output
ui_pause() {
    [[ "$UI_MODE" == "none" ]] && return 0
    local _
    read -r -u "$UI_IN" -p "Press Enter to return to the menu..." _ || true
}

# ==============================================================================
# CONFIG HELPERS
# ==============================================================================

# Normalizes an endpoint: trims whitespace, adds https:// if no scheme is
# given, removes the trailing slash. Prints the result to stdout.
# usage: ep=$(normalize_endpoint "$ep")
normalize_endpoint() {
    local url="$1"
    # trim whitespace on both ends
    url="${url#"${url%%[![:space:]]*}"}"; url="${url%"${url##*[![:space:]]}"}"
    [[ -z "$url" ]] && { printf ''; return; }
    # add the scheme if missing (s3.domain.com -> https://s3.domain.com)
    if [[ ! "$url" =~ ^https?:// ]]; then
        url="https://${url}"
    fi
    # remove the trailing slash (https://s3.x.com/ -> https://s3.x.com)
    url="${url%/}"
    printf '%s' "$url"
}

# Trims whitespace on both ends (a common copy-paste mistake). usage: v=$(trim "$v")
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Writes a variable's value to the config (CONF_FILE).
# usage: conf_set VAR VALUE [--raw|--allow-empty]
#   --raw          write without quotes (for numbers)
#   --allow-empty  write even an empty value (to "reset the option")
#
# The value is escaped before substitution: there used to be a bare
# "sed -i "s|^VAR=.*|VAR=\"$VALUE\"|"" here, and any "&" in the value inserted
# the whole matched text into the config, while "|" broke the sed expression itself. This bit
# on webhook URLs, where "&" is common.
conf_set() {
    local var="$1" val="$2" mode="${3:-}"
    local conf="${CONF_FILE:?CONF_FILE is not set}"

    [[ -z "$val" && "$mode" != "--allow-empty" ]] && return 0
    [[ -f "$conf" ]] || return 0

    # The line is missing (config older than the template) — sed would silently do nothing and the value would be lost
    if ! grep -q "^${var}=" "$conf"; then
        if [[ "$mode" == "--raw" ]]; then
            printf '%s=%s\n' "$var" "$val" >> "$conf"
        else
            printf '%s="%s"\n' "$var" "$val" >> "$conf"
        fi
        return 0
    fi

    # Escape what sed treats specially in the right-hand side of s|…|…|
    local esc="$val"
    esc="${esc//\\/\\\\}"     # backslash
    esc="${esc//|/\\|}"       # delimiter
    esc="${esc//&/\\&}"       # "the whole matched text"

    if [[ "$mode" == "--raw" ]]; then
        sed -i "s|^${var}=.*|${var}=${esc}|" "$conf"
    else
        sed -i "s|^${var}=.*|${var}=\"${esc}\"|" "$conf"
    fi
}

# System CA bundle: Debian/Ubuntu, then the RHEL family. Prints the path.
system_ca_bundle() {
    local f
    for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
        [[ -s "$f" ]] && { printf '%s' "$f"; return 0; }
    done
    return 1
}

# One head-bucket the way the backup will do it: only these keys and options, no ~/.aws and no stray
# AWS_* from the environment. Prints aws output (stderr); the exit code is aws's.
# usage: _s3_probe <access> <secret> <region> <endpoint> <bucket> <addressing> [aws options…]
_s3_probe() {
    local access="$1" secret="$2" region="$3" endpoint="$4" bucket="$5" addressing="$6"
    shift 6
    local -a cmd=(aws --endpoint-url "$endpoint" "$@" --cli-connect-timeout 10 --cli-read-timeout 20
                  s3api head-bucket --bucket "$bucket")
    command -v timeout >/dev/null 2>&1 && cmd=(timeout 60 "${cmd[@]}")
    env -u AWS_PROFILE -u AWS_SESSION_TOKEN -u AWS_CA_BUNDLE \
        AWS_ACCESS_KEY_ID="$access" AWS_SECRET_ACCESS_KEY="$secret" \
        AWS_DEFAULT_REGION="${region:-us-east-1}" AWS_S3_ADDRESSING_STYLE="$addressing" \
        AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_MAX_ATTEMPTS=2 \
        AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}" \
        AWS_RESPONSE_CHECKSUM_VALIDATION="${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}" \
        "${cmd[@]}" 2>&1 >/dev/null
}

# The last meaningful line of aws output (without urllib3 SSL warnings)
_s3_probe_reason() {
    printf '%s\n' "$1" | grep -v -E 'InsecureRequestWarning|urllib3|^[[:space:]]*$' | tail -1
}

# ==============================================================================
# STORAGE WIZARD — shared by the installer and the menu
# ==============================================================================
# store_wizard <role> <label> <example endpoint> [current values from ST] — asks for one storage's
# connection settings, checks the bucket and the certificate, keeps the answers in ST["role:FIELD"].
# Current ST values are offered as defaults (the secret too: empty input keeps it).
# store_save <role> — writes ST["role:*"] to CONF_FILE.
declare -A ST=()
store_wizard() {
    local role="$1" title="$2" example="$3" key secret ep ep_raw region bucket addr
    ui_note "Access/Secret are issued by the S3 provider in its storage control panel."
    key="$(ui_input "  Access Key" "${ST[$role:ACCESS_KEY]:-}")" || return 1
    if [[ -n "${ST[$role:SECRET_KEY]:-}" ]]; then
        secret="$(ui_password "  Secret Key (hidden input; empty — keep the current one)")" || return 1
        [[ -z "$secret" ]] && secret="${ST[$role:SECRET_KEY]}"
    else
        secret="$(ui_password "  Secret Key (hidden input)")" || return 1
    fi
    ep="$(ui_input "  Endpoint (e.g. ${example})" "${ST[$role:ENDPOINT]:-}")" || return 1
    region="$(ui_input "  Region" "${ST[$role:REGION]:-us-east-1}")" || return 1
    bucket="$(ui_input "  Bucket name (create it beforehand in the provider's panel)" "${ST[$role:BUCKET]:-}")" || return 1

    key="$(trim "$key")"; secret="$(trim "$secret")"; bucket="$(trim "$bucket")"
    # Normalize the endpoint (add https:// if no scheme is given)
    ep_raw="$ep"
    ep="$(normalize_endpoint "$ep")"
    [[ -n "$ep_raw" && "$ep_raw" != "$ep" ]] && ui_note "Endpoint normalized to: ${ep}"

    ui_note "Bucket addressing style: path = endpoint/bucket (universal), virtual = bucket.endpoint. If unsure — keep path."
    if [[ "$UI_MODE" == "whiptail" ]]; then
        local cur="${ST[$role:ADDRESSING_STYLE]:-path}"
        addr="$(UI_DEFAULT="$cur" ui_menu "Addressing style" path "endpoint/bucket (universal)" virtual "bucket.endpoint")" || return 1
    else
        addr="$(ui_input "  Addressing style (path/virtual)" "${ST[$role:ADDRESSING_STYLE]:-path}")" || return 1
    fi
    case "$addr" in path|virtual) ;; *) addr="path" ;; esac

    if [[ -z "$key" || -z "$secret" || -z "$ep" || -z "$bucket" ]]; then
        log_warn "${title}: some fields are empty — fill in ${role^^}_S3_* later in ${CONF_FILE}"
        ui_later "⚠ ${title}: some fields are empty — fill in ${role^^}_S3_* later in ${CONF_FILE}"
    fi

    # Whether aws trusts the certificate — checked, not asked (see s3_cert_check)
    s3_cert_check "$title" "$key" "$secret" "$region" "$ep" "$bucket" "$addr"
    [[ -n "$CERT_REPORT" ]] && ui_later "$CERT_REPORT"

    ST["$role:ACCESS_KEY"]="$key"; ST["$role:SECRET_KEY"]="$secret"; ST["$role:ENDPOINT"]="$ep"
    ST["$role:REGION"]="$region"; ST["$role:BUCKET"]="$bucket"; ST["$role:ADDRESSING_STYLE"]="$addr"
    # Other options the user put into OPTS_EXTRA stay; only --ca-bundle follows the check, and only
    # when the check reached a verdict (a timeout says nothing about the certificate)
    local opts="${ST[$role:OPTS_EXTRA]:-}"
    if [[ -n "$CERT_DECIDED" ]]; then
        opts="$(printf '%s' "$opts" | sed -E 's/--ca-bundle[ =]+[^ ]+//g; s/  +/ /g')"
        opts="$(trim "${opts} ${CERT_OPTS}")"
    fi
    ST["$role:OPTS_EXTRA"]="$opts"
    return 0
}

store_save() {
    local role="$1" p="${1^^}_S3" f
    if [[ "$role" != "primary" ]]; then
        # Disabled — write that explicitly instead of keeping what was in the config
        if [[ "${ST[$role:ENABLED]:-false}" != "true" ]]; then
            conf_set "${p}_ENABLED" "false"
            return 0
        fi
        conf_set "${p}_ENABLED"  "true"
        conf_set "${p}_REQUIRED" "${ST[$role:REQUIRED]:-false}"
    fi
    for f in ACCESS_KEY SECRET_KEY ENDPOINT REGION BUCKET ADDRESSING_STYLE; do
        conf_set "${p}_${f}" "${ST[$role:$f]:-}"
    done
    conf_set "${p}_OPTS_EXTRA" "${ST[$role:OPTS_EXTRA]:-}" --allow-empty
}

# A line of the certificate check report: logged now and collected in CERT_REPORT,
# so a dialog can show it afterwards. usage: _cert_say ok|warn|info <text>
_cert_say() {
    local level="$1"; shift
    case "$level" in
        ok)   log_ok "$*";   CERT_REPORT+="✓ $*"$'\n' ;;
        warn) log_warn "$*"; CERT_REPORT+="⚠ $*"$'\n' ;;
        *)    log "    $*";   CERT_REPORT+="  $*"$'\n' ;;
    esac
    return 0
}

# Checks whether aws trusts the S3 certificate and picks the option for *_OPTS_EXTRA.
# Asking about it is pointless: the answer is unknown at install time (answering "no" once left
# a copy at one S3-compatible provider broken: aws from snap lacks the GlobalSign Root R46 root, while the system
# bundle has it). So we try: without options, on CERTIFICATE_VERIFY_FAILED —
# with the system CA bundle. --no-verify-ssl is never set: without verification the storage can be
# spoofed. A truly self-signed one — put its root into /usr/local/share/ca-certificates/.
# No aws or empty fields — skip quietly (stays empty, as by default).
# usage: s3_cert_check <label> <access> <secret> <region> <endpoint> <bucket> <addressing>
# Result — in CERT_OPTS (empty — no options needed); the report — in CERT_REPORT;
# CERT_DECIDED=yes when the check reached a verdict (reachable, with or without the system bundle).
s3_cert_check() {
    local label="$1" access="$2" secret="$3" region="$4" endpoint="$5" bucket="$6" addressing="$7"
    local out rc bundle
    CERT_OPTS=""; CERT_REPORT=""; CERT_DECIDED=""
    command -v aws >/dev/null 2>&1 || return 0
    [[ -n "$access" && -n "$secret" && -n "$endpoint" && -n "$bucket" ]] || return 0

    out="$(_s3_probe "$access" "$secret" "$region" "$endpoint" "$bucket" "$addressing")" && rc=0 || rc=$?
    if (( rc == 0 )); then
        CERT_DECIDED="yes"
        _cert_say ok "${label}: bucket ${bucket} is reachable"
        return 0
    fi
    if [[ "$out" != *CERTIFICATE_VERIFY_FAILED* ]]; then
        if (( rc == 124 )); then
            _cert_say warn "${label}: endpoint ${endpoint} did not respond within 60 s"
        else
            _cert_say warn "${label}: bucket check failed — $(_s3_probe_reason "$out")"
        fi
        _cert_say info "Check the keys, endpoint, bucket and addressing style; later — validate-config.sh"
        return 0
    fi

    if ! bundle="$(system_ca_bundle)"; then
        _cert_say warn "${label}: aws does not trust the certificate, and no system CA bundle was found"
        _cert_say info "Install the ca-certificates package and add --ca-bundle <bundle> to backup.conf"
        return 0
    fi
    out="$(_s3_probe "$access" "$secret" "$region" "$endpoint" "$bucket" "$addressing" --ca-bundle "$bundle")" && rc=0 || rc=$?
    if [[ "$out" == *CERTIFICATE_VERIFY_FAILED* ]]; then
        _cert_say warn "${label}: the certificate is rejected even with the system CA bundle — not writing the option"
        _cert_say info "If the certificate is self-signed: its root into /usr/local/share/ca-certificates/, then"
        _cert_say info "update-ca-certificates and --ca-bundle ${bundle} in backup.conf"
        return 0
    fi
    CERT_OPTS="--ca-bundle ${bundle}"; CERT_DECIDED="yes"
    _cert_say ok "${label}: aws does not trust the certificate out of the box, it does with the system CA bundle; writing ${CERT_OPTS}"
    if (( rc != 0 )); then
        _cert_say warn "${label}: but the bucket check itself failed — $(_s3_probe_reason "$out")"
        _cert_say info "Check the keys, bucket and addressing style; later — validate-config.sh"
    fi
    return 0
}
