#!/usr/bin/env bash
# ==============================================================================
# menu.sh — the docker-backup command: one entry point for the whole system
#
#   sudo docker-backup                 # the menu (whiptail; plain numbered prompts without it)
#   sudo docker-backup backup -p app   # a subcommand — runs the script with these arguments
#   sudo docker-backup help            # the list of subcommands
#
# install.sh links it as /usr/local/bin/docker-backup. Without a terminal (cron, pipes) there is
# no menu — use the subcommands or the scripts themselves, they work as before.
# ==============================================================================
set -uo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/backup.conf"

usage() {
    cat <<EOF
Usage: docker-backup [-c FILE] [command [arguments]]

Without a command — the interactive menu.

Commands (arguments go to the script as is; see "<command> --help"):
  backup      back up now                  (docker-backup.sh)
  restore     restore from a backup        (docker-restore.sh)
  status      one-screen overview          (status.sh)
  sync        synchronize the storages     (sync-s3.sh)
  verify      check that backups restore   (verify-restore.sh)
  validate    check the configuration      (validate-config.sh)
  diagnose    S3 access diagnostics        (diagnose-s3.sh)
  logs        view the logs                (logs.sh)
  schedule    scheduled runs               (setup-cron.sh)
  drop        remove a project's copies    (drop-project.sh)
  update      update the installation      (update.sh)
  uninstall   remove the system            (uninstall.sh)
  menu        the interactive menu
  version     the installed version
  help        this help

  -c FILE     config file for the menu (default: backup.conf next to the scripts)
EOF
}

if [[ "${1:-}" == "-c" || "${1:-}" == "--config" ]]; then
    CONFIG_FILE="${2:?-c needs a file}"; shift 2
fi

# --- Subcommands: straight to the script ---
cmd="${1:-menu}"
case "$cmd" in
    backup)    script=docker-backup.sh ;;
    restore)   script=docker-restore.sh ;;
    status)    script=status.sh ;;
    sync)      script=sync-s3.sh ;;
    verify)    script=verify-restore.sh ;;
    validate)  script=validate-config.sh ;;
    diagnose)  script=diagnose-s3.sh ;;
    logs)      script=logs.sh ;;
    schedule)  script=setup-cron.sh ;;
    drop)      script=drop-project.sh ;;
    update)    script=update.sh ;;
    uninstall) script=uninstall.sh ;;
    menu)      script="" ;;
    version|-V|--version)
        echo "docker-backup-s3 $(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null || echo unknown)"; exit 0 ;;
    help|-h|--help) usage; exit 0 ;;
    *) echo "Unknown command: $cmd" >&2; usage >&2; exit 1 ;;
esac
if [[ -n "$script" ]]; then
    shift
    exec "${SCRIPT_DIR}/${script}" "$@"
fi

# ==============================================================================
# THE MENU
# ==============================================================================
[[ "$EUID" -eq 0 ]] || { echo "❌ The menu needs root: sudo docker-backup" >&2; exit 1; }
[[ -f "$CONFIG_FILE" ]] || { echo "❌ Config not found: $CONFIG_FILE — run install.sh first" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG_FILE"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=ui.sh
source "${SCRIPT_DIR}/ui.sh"
NON_INTERACTIVE="false"
ui_init
CONF_FILE="$CONFIG_FILE"
if ! { : <"$UI_TTY"; } 2>/dev/null; then
    echo "❌ No terminal — the menu is interactive. Use a subcommand instead:" >&2
    usage >&2
    exit 1
fi

# Ctrl+C stops the running script, not the menu
trap ':' INT

# Runs a script in the terminal and waits for Enter. usage: run_tool <script> [arguments]
run_tool() {
    local script="$1" rc; shift
    [[ "$UI_MODE" == "whiptail" ]] && clear
    echo "${C_BOLD}▶ ${script} $*${C_RESET}"
    echo
    "${SCRIPT_DIR}/${script}" "$@"; rc=$?
    echo
    if (( rc == 0 )); then echo "${C_GREEN}✓ Done${C_RESET}"; else echo "${C_RED}✗ Finished with exit code ${rc}${C_RESET}"; fi
    ui_pause
    return 0
}

# Re-reads the config after an edit (values and the list of enabled copies)
reload_conf() {
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    s3_refresh
}

# One copy of backup.conf per menu session, before the first edit
CONF_BACKED_UP=""
backup_conf_once() {
    [[ -n "$CONF_BACKED_UP" ]] && return 0
    CONF_BACKED_UP="${CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    cp -p "$CONFIG_FILE" "$CONF_BACKED_UP"
    ui_note "A copy of the config before the changes: $CONF_BACKED_UP"
}

# "primary + secondary" — which storages are in use
storages_summary() {
    local s="primary" r
    for r in ${S3_COPIES[@]+"${S3_COPIES[@]}"}; do s+=" + $r"; done
    printf '%s' "$s"
}

# Picks a storage: primary or an enabled copy. Without copies — primary, no question.
# usage: role=$(pick_storage "<text>") || cancelled
pick_storage() {
    local text="$1" r
    if (( ${#S3_COPIES[@]} == 0 )); then printf 'primary'; return 0; fi
    local -a items=(primary "$(s3_label primary title) — $(s3_host "$(s3_var primary ENDPOINT)")")
    for r in "${S3_COPIES[@]}"; do items+=("$r" "$(s3_label "$r" title) — $(s3_host "$(s3_var "$r" ENDPOINT)")"); done
    UI_DEFAULT=primary ui_menu "$text" "${items[@]}"
}

# Folders under a prefix in a storage (projects, timestamps), one per line.
# usage: s3_folders <role> <prefix ending with />
s3_folders() {
    local role="$1" prefix="$2"
    _aws_setup "$role" read || return 1
    aws_q s3api list-objects-v2 --bucket "$S3_CUR_BUCKET" --prefix "$prefix" --delimiter "/" \
        --query 'CommonPrefixes[].Prefix' --output text 2>/dev/null \
        | tr '\t' '\n' | grep -v '^None$' | sed -e "s|^${prefix}||" -e 's|/$||' | grep -v '^$' || true
    _aws_setup primary
}

# ==============================================================================
# BACKUP
# ==============================================================================
menu_backup() {
    local choice list picked
    while true; do
        UI_TITLE="Back up now"
        choice="$(ui_menu "What to back up?" \
            all     "All projects on this host" \
            pick    "Choose projects…" \
            dryall  "Dry run — all projects (shows the plan, changes nothing)" \
            drypick "Dry run — chosen projects")" || return 0
        case "$choice" in
            all)    run_tool docker-backup.sh -c "$CONFIG_FILE" ;;
            dryall) run_tool docker-backup.sh -c "$CONFIG_FILE" --dry-run ;;
            pick|drypick)
                list="$("${SCRIPT_DIR}/docker-backup.sh" -c "$CONFIG_FILE" --list)"
                if [[ -z "$list" ]]; then ui_msg "No compose projects found on this host."; continue; fi
                local -a items=(); local p
                while IFS= read -r p; do [[ -n "$p" ]] && items+=("$p" "" off); done <<< "$list"
                picked="$(ui_checklist "Projects to back up (Space to select):" "${items[@]}")" || continue
                [[ -z "$picked" ]] && { ui_msg "Nothing selected."; continue; }
                picked="$(printf '%s' "$picked" | paste -sd, -)"
                if [[ "$choice" == "pick" ]]; then run_tool docker-backup.sh -c "$CONFIG_FILE" -p "$picked"
                else run_tool docker-backup.sh -c "$CONFIG_FILE" -p "$picked" --dry-run; fi
                ;;
        esac
    done
}

# ==============================================================================
# RESTORE
# ==============================================================================
menu_restore() {
    local role proj ts action list p dir vol
    UI_TITLE="Restore"
    role="$(pick_storage "Restore from which storage?")" || return 0

    list="$(s3_folders "$role" "${BACKUP_PREFIX}/")"
    if [[ -z "$list" ]]; then ui_msg "No backups found $(s3_label "$role" in)."; return 0; fi
    local -a items=()
    while IFS= read -r p; do [[ -n "$p" ]] && items+=("$p" ""); done <<< "$list"
    proj="$(ui_menu "Project $(s3_label "$role" in):" "${items[@]}")" || return 0

    list="$(s3_folders "$role" "${BACKUP_PREFIX}/${proj}/" | sort -r)"
    if [[ -z "$list" ]]; then ui_msg "No backups of ${proj} found."; return 0; fi
    items=()
    while IFS= read -r p; do [[ -n "$p" ]] && items+=("$p" ""); done <<< "$list"
    ts="$(ui_menu "Backup of ${proj} (newest first):" "${items[@]}")" || return 0

    action="$(ui_menu "What to do with ${proj} @ ${ts}?" \
        full     "Restore in place and start it (overwrites the current data)" \
        nostart  "Restore in place, do not start (--no-start)" \
        dir      "Restore into another folder, do not start" \
        volume   "Restore one named volume only" \
        extract  "Unpack into a folder — changes nothing on the host" \
        contents "Show what is inside")" || return 0

    local -a args=(-c "$CONFIG_FILE" --from "$role" -p "$proj" -t "$ts" -y)
    case "$action" in
        full)
            ui_yesno "Restore ${proj} from ${ts} in place?\n\nExisting data of the project on this host will be overwritten, then it is started (docker compose up -d)." n || return 0 ;;
        nostart)
            ui_yesno "Restore ${proj} from ${ts} in place without starting it?\n\nExisting data of the project on this host will be overwritten." n || return 0
            args+=(--no-start) ;;
        dir)
            dir="$(ui_input "Folder to restore the project into" "/tmp/restore-${proj}")" || return 0
            [[ -z "$dir" ]] && return 0
            ui_note "Named volumes are restored under their real names — they overwrite the existing ones."
            ui_yesno "Restore ${proj} from ${ts} into ${dir}, without starting?" n || return 0
            args+=(-d "$dir" --no-start) ;;
        volume)
            vol="$(ui_input "Named volume to restore (see \"Show what is inside\")" "")" || return 0
            [[ -z "$vol" ]] && return 0
            ui_yesno "Replace the contents of volume ${vol} with the one from ${ts}?" n || return 0
            args+=(--only-volume "$vol") ;;
        extract)
            dir="$(ui_input "Folder to unpack the backup into" "/tmp/restore-${proj}-${ts}")" || return 0
            [[ -z "$dir" ]] && return 0
            args+=(--extract-to "$dir") ;;
        contents)
            args+=(--contents) ;;
    esac
    run_tool docker-restore.sh "${args[@]}"
}

# ==============================================================================
# SYNC
# ==============================================================================
menu_sync() {
    local choice role
    if (( ${#S3_COPIES[@]} == 0 )); then
        ui_msg "No copies are enabled — there is nothing to synchronize.\n\nSet up a secondary or tertiary S3 in \"Storage settings\"."
        return 0
    fi
    while true; do
        UI_TITLE="Synchronize storages"
        choice="$(ui_menu "The primary is the source of truth; copies are brought in line with it." \
            plan    "Show the plan (dry run, all copies)" \
            sync    "Synchronize all copies now" \
            one     "Synchronize one copy…" \
            prune   "Synchronize and delete extras in the copies (--prune, irreversible)" \
            reverse "Restore the primary from a copy (disaster recovery)…")" || return 0
        case "$choice" in
            plan)  run_tool sync-s3.sh -c "$CONFIG_FILE" --dry-run ;;
            sync)  run_tool sync-s3.sh -c "$CONFIG_FILE" ;;
            one)
                local -a items=(); local r
                for r in "${S3_COPIES[@]}"; do items+=("$r" "$(s3_label "$r" title) — $(s3_host "$(s3_var "$r" ENDPOINT)")"); done
                role="$(ui_menu "Which copy?" "${items[@]}")" || continue
                run_tool sync-s3.sh -c "$CONFIG_FILE" --to "$role" ;;
            prune)
                ui_yesno "Objects in the copies that are no longer in the primary (e.g. after rotation) will be deleted for good.\n\nContinue? The script will show the plan and ask once more." n || continue
                run_tool sync-s3.sh -c "$CONFIG_FILE" --prune ;;
            reverse)
                local -a items=(); local r
                for r in "${S3_COPIES[@]}"; do items+=("$r" "$(s3_label "$r" title) — $(s3_host "$(s3_var "$r" ENDPOINT)")"); done
                role="$(ui_menu "Copy the missing objects FROM which copy into the primary?" "${items[@]}")" || continue
                run_tool sync-s3.sh -c "$CONFIG_FILE" --reverse --from "$role" --dry-run
                ui_yesno "Apply this plan to the PRIMARY S3?\n\nUse it only if the primary lost data. The script asks for \"yes\" once more." n || continue
                run_tool sync-s3.sh -c "$CONFIG_FILE" --reverse --from "$role" ;;
        esac
    done
}

# ==============================================================================
# CHECKS
# ==============================================================================
menu_checks() {
    local choice role proj list p
    while true; do
        UI_TITLE="Checks and diagnostics"
        choice="$(ui_menu "What to check?" \
            validate "Configuration and access to every storage (validate-config.sh)" \
            quick    "Backups restore — quick: objects are there (all projects)" \
            full     "Backups restore — full: download, unpack, check dumps (all projects)" \
            one      "Backups restore — one project, full…" \
            s3       "S3 diagnostics: keys, addressing style, test write (diagnose-s3.sh)" \
            cron     "Cron diagnostics (diagnose-cron.sh)")" || return 0
        case "$choice" in
            validate) run_tool validate-config.sh -c "$CONFIG_FILE" ;;
            quick|full|one)
                role="$(pick_storage "Check the backups of which storage?")" || continue
                if [[ "$choice" == "quick" ]]; then run_tool verify-restore.sh -c "$CONFIG_FILE" --from "$role" --quick --no-notify
                elif [[ "$choice" == "full" ]]; then run_tool verify-restore.sh -c "$CONFIG_FILE" --from "$role" --no-notify
                else
                    list="$(s3_folders "$role" "${BACKUP_PREFIX}/")"
                    [[ -z "$list" ]] && { ui_msg "No backups found $(s3_label "$role" in)."; continue; }
                    local -a items=()
                    while IFS= read -r p; do [[ -n "$p" ]] && items+=("$p" ""); done <<< "$list"
                    proj="$(ui_menu "Which project?" "${items[@]}")" || continue
                    run_tool verify-restore.sh -c "$CONFIG_FILE" --from "$role" -p "$proj" --no-notify
                fi ;;
            s3)   run_tool diagnose-s3.sh ;;
            cron) run_tool diagnose-cron.sh ;;
        esac
    done
}

# ==============================================================================
# LOGS
# ==============================================================================
menu_logs() {
    local choice proj
    while true; do
        UI_TITLE="Logs"
        choice="$(ui_menu "Which part of the logs?" \
            last    "The last 50 lines" \
            errors  "Errors and warnings" \
            lastrun "The whole last run" \
            today   "Errors today" \
            project "Entries about one project…" \
            follow  "Follow live (Ctrl+C to stop)")" || return 0
        case "$choice" in
            last)    run_tool logs.sh -c "$CONFIG_FILE" ;;
            errors)  run_tool logs.sh -c "$CONFIG_FILE" -e ;;
            lastrun) run_tool logs.sh -c "$CONFIG_FILE" -l ;;
            today)   run_tool logs.sh -c "$CONFIG_FILE" -e -s today ;;
            project)
                proj="$(ui_input "Project name" "")" || continue
                [[ -n "$proj" ]] && run_tool logs.sh -c "$CONFIG_FILE" -p "$proj" ;;
            follow)  run_tool logs.sh -c "$CONFIG_FILE" -f ;;
        esac
    done
}

# ==============================================================================
# SCHEDULED RUNS
# ==============================================================================
menu_schedule() {
    local choice method preset spec
    while true; do
        UI_TITLE="Scheduled runs"
        choice="$(ui_menu "Nightly backups run from cron or a systemd timer." \
            status "Show the current setup" \
            set    "Set up or change the schedule…" \
            remove "Remove scheduled runs")" || return 0
        case "$choice" in
            status) run_tool setup-cron.sh --status ;;
            set)
                method="$(UI_DEFAULT=cron ui_menu "How to run it?" \
                    cron    "cron — simple and familiar" \
                    systemd "systemd timer — catches up on runs missed while the server was off")" || continue
                preset="$(UI_DEFAULT=daily ui_menu "When?" \
                    daily    "Every day at 03:00" \
                    twice    "Twice a day — 04:00 and 16:00" \
                    6h       "Every 6 hours (00, 06, 12, 18)" \
                    weekdays "Weekdays at 02:00" \
                    weekly   "Once a week — Sunday 03:00" \
                    custom   "Custom…")" || continue
                if [[ "$preset" == "custom" ]]; then
                    if [[ "$method" == "cron" ]]; then
                        spec="$(ui_input "Cron expression: <minute> <hour> <day of month> <month> <day of week>" "30 3 * * *")" || continue
                    else
                        spec="$(ui_input "systemd OnCalendar: <DOW> *-*-* HH:MM:SS" "*-*-* 03:30:00")" || continue
                    fi
                    [[ -z "$spec" ]] && continue
                    preset="$spec"
                fi
                ui_yesno "Set up ${method} with schedule: ${preset}?\n\nAn existing setup (cron or timer) is replaced." y || continue
                run_tool setup-cron.sh -m "$method" -s "$preset" -y ;;
            remove)
                run_tool setup-cron.sh --remove ;;
        esac
    done
}

# ==============================================================================
# STORAGE SETTINGS
# ==============================================================================
# Current values of a role into ST (the wizard offers them as defaults)
load_store() {
    local role="$1" f
    for f in ACCESS_KEY SECRET_KEY ENDPOINT REGION BUCKET ADDRESSING_STYLE OPTS_EXTRA ENABLED REQUIRED; do
        ST["$role:$f"]="$(s3_var "$role" "$f")"
    done
    [[ "$role" == "primary" ]] && ST["$role:ENABLED"]="true"
    return 0
}

# One line about a storage for the list
store_line() {
    local role="$1" ep bucket
    ep="$(s3_host "$(s3_var "$role" ENDPOINT)")"; bucket="$(s3_var "$role" BUCKET)"
    if ! s3_enabled "$role"; then printf '%s — disabled' "$(s3_label "$role" title)"; return; fi
    printf '%s — %s / %s%s' "$(s3_label "$role" title)" "${ep:-no endpoint}" "${bucket:-no bucket}" \
        "$( [[ "$role" != "primary" && "$(s3_var "$role" REQUIRED)" == "true" ]] && echo ', required')"
}

menu_storages() {
    local role
    while true; do
        UI_TITLE="Storage settings"
        role="$(ui_menu "Every archive goes to the primary first, then to each enabled copy." \
            primary   "$(store_line primary)" \
            secondary "$(store_line secondary)" \
            tertiary  "$(store_line tertiary)")" || return 0
        menu_store "$role"
    done
}

menu_store() {
    local role="$1" title choice p v key secret
    title="$(s3_label "$role" title)"; p="${role^^}_S3"
    while true; do
        UI_TITLE="$title"
        local -a items=(conn "Connection: keys, endpoint, bucket — with a check")
        if [[ "$role" != "primary" ]]; then
            if s3_enabled "$role"; then items+=(toggle "Disable this copy")
            else items+=(toggle "Enable this copy"); fi
            if [[ "$(s3_var "$role" REQUIRED)" == "true" ]]; then items+=(required "Make it optional (a failure here is only a warning)")
            else items+=(required "Make it required (a failure here fails the backup)"); fi
        fi
        items+=(check "Check access now" rokey "Read-only key for restore…")
        choice="$(ui_menu "$(store_line "$role")
Options: $(s3_var "$role" OPTS_EXTRA)" "${items[@]}")" || return 0
        case "$choice" in
            conn)
                load_store "$role"
                store_wizard "$role" "$title" "https://s3.example.com" || continue
                backup_conf_once
                if [[ "$role" != "primary" && "${ST[$role:ENABLED]}" != "true" ]]; then
                    ui_yesno "Enable ${title} now?" y && ST["$role:ENABLED"]="true"
                fi
                if [[ "$role" != "primary" && "${ST[$role:ENABLED]}" != "true" ]]; then
                    # store_save writes only ENABLED=false for a disabled copy — save the fields too
                    local f; for f in ACCESS_KEY SECRET_KEY ENDPOINT REGION BUCKET ADDRESSING_STYLE; do conf_set "${p}_${f}" "${ST[$role:$f]}"; done
                    conf_set "${p}_OPTS_EXTRA" "${ST[$role:OPTS_EXTRA]}" --allow-empty
                else
                    store_save "$role"
                fi
                reload_conf
                ui_msg "${title}: saved to ${CONFIG_FILE}." ;;
            toggle)
                backup_conf_once
                if s3_enabled "$role"; then conf_set "${p}_ENABLED" "false"
                else
                    s3_complete "$role" || { ui_msg "Fill in the connection first (keys, endpoint, bucket)."; continue; }
                    conf_set "${p}_ENABLED" "true"
                fi
                reload_conf ;;
            required)
                backup_conf_once
                if [[ "$(s3_var "$role" REQUIRED)" == "true" ]]; then conf_set "${p}_REQUIRED" "false"
                else conf_set "${p}_REQUIRED" "true"; fi
                reload_conf ;;
            check)
                if ! s3_complete "$role"; then ui_msg "Fill in the connection first (keys, endpoint, bucket)."; continue; fi
                s3_cert_check "$title" "$(s3_var "$role" ACCESS_KEY)" "$(s3_var "$role" SECRET_KEY)" "$(s3_var "$role" REGION)" \
                    "$(s3_var "$role" ENDPOINT)" "$(s3_var "$role" BUCKET)" "$(s3_var "$role" ADDRESSING_STYLE)" 2>/dev/null >/dev/null
                if [[ -n "$CERT_OPTS" && "$(s3_var "$role" OPTS_EXTRA)" != *--ca-bundle* ]]; then
                    if ui_yesno "${CERT_REPORT}
Write ${p}_OPTS_EXTRA=\"${CERT_OPTS}\" to the config?" y; then
                        backup_conf_once
                        v="$(s3_var "$role" OPTS_EXTRA)"
                        conf_set "${p}_OPTS_EXTRA" "${v:+$v }${CERT_OPTS}"
                        reload_conf
                    fi
                else
                    ui_msg "${CERT_REPORT:-No result — is aws installed?}"
                fi ;;
            rokey)
                ui_note "A key that can only read — for a restore server: backups can't be deleted or overwritten with it."
                ui_note "Empty Access Key — remove the read-only key (restore then uses the main key)."
                key="$(ui_input "Read-only Access Key" "$(s3_var "$role" RESTORE_ACCESS_KEY)")" || continue
                key="$(trim "$key")"
                backup_conf_once
                if [[ -z "$key" ]]; then
                    conf_set "${p}_RESTORE_ACCESS_KEY" "" --allow-empty
                    conf_set "${p}_RESTORE_SECRET_KEY" "" --allow-empty
                else
                    secret="$(ui_password "Read-only Secret Key (empty — keep the current one)")" || continue
                    secret="$(trim "$secret")"
                    conf_set "${p}_RESTORE_ACCESS_KEY" "$key"
                    [[ -n "$secret" ]] && conf_set "${p}_RESTORE_SECRET_KEY" "$secret"
                fi
                reload_conf ;;
        esac
    done
}

# ==============================================================================
# NOTIFICATIONS
# ==============================================================================
# One line about a channel for the list
notify_line() {
    if ! notify_configured "$1"; then printf 'off'; return 0; fi
    case "$1" in
        telegram) printf 'chat %s' "$TELEGRAM_CHAT_ID" ;;
        webhook)  printf '%s (%s)' "$(s3_host "$NOTIFY_WEBHOOK_URL")" "$(webhook_format)" ;;
        email)    printf 'to %s via %s' "$EMAIL_TO" "$SMTP_HOST" ;;
    esac
}

notify_when() {
    case "${NOTIFY_ON:-error}" in
        none)   printf 'never' ;;
        always) printf 'every run' ;;
        *)      printf 'problems only' ;;
    esac
}

menu_notify() {
    local choice v ch err out
    while true; do
        UI_TITLE="Notifications"
        choice="$(ui_menu "Where messages about backups go. Any channels can be on at once." \
            when     "When: $(notify_when)" \
            name     "Server name in messages: ${NOTIFY_NAME:-$(hostname) (the hostname)}" \
            telegram "Telegram — $(notify_line telegram)" \
            webhook  "Webhook — $(notify_line webhook)" \
            email    "Email — $(notify_line email)" \
            test     "Send a test message to every channel")" || return 0
        case "$choice" in
            when)
                v="$(UI_DEFAULT="${NOTIFY_ON:-error}" ui_menu "When to send a message?" \
                    error  "Problems only (recommended)" \
                    always "Every run, the successful ones too" \
                    none   "Never")" || continue
                backup_conf_once; conf_set NOTIFY_ON "$v"; reload_conf ;;
            name)
                v="$(ui_input "Server name in messages (empty — the hostname)" "${NOTIFY_NAME:-}")" || continue
                backup_conf_once; conf_set NOTIFY_NAME "$(trim "$v")" --allow-empty; reload_conf ;;
            telegram|webhook|email)
                menu_channel "$choice" ;;
            test)
                out=""
                notify_load
                for ch in telegram webhook email; do
                    notify_configured "$ch" || continue
                    if err="$(notify_probe "$ch")"; then out+="✓ ${ch}: sent"$'\n'
                    else out+="✗ ${ch}: ${err:-unknown error}"$'\n'; notify_hint "$ch" "$err"; fi
                done
                ui_msg "${out:-No channel is set up.}" ;;
        esac
    done
}

menu_channel() {
    local ch="$1" label choice err
    case "$ch" in telegram) label="Telegram" ;; webhook) label="Webhook" ;; *) label="Email" ;; esac
    while true; do
        UI_TITLE="$label"
        if notify_configured "$ch"; then
            choice="$(ui_menu "${label}: $(notify_line "$ch")" \
                edit "Change the settings…" \
                test "Send a test message" \
                off  "Turn ${label} off")" || return 0
        else
            choice="edit"
        fi
        case "$choice" in
            edit)
                notify_load
                case "$ch" in
                    telegram) tg_wizard ;;
                    webhook)  webhook_wizard ;;
                    email)    email_wizard ;;
                esac || return 0
                backup_conf_once; notify_save; reload_conf
                if notify_configured "$ch"; then ui_msg "${label}: saved to ${CONFIG_FILE}."
                else ui_msg "${label}: off."; return 0; fi ;;
            test)
                notify_load
                if err="$(notify_probe "$ch")"; then ui_msg "✓ ${label}: the test message was sent."
                else notify_hint "$ch" "$err"; ui_msg "✗ ${label}: ${err:-unknown error}"; fi ;;
            off)
                ui_yesno "Turn ${label} off? Its settings are removed from the config." n || continue
                notify_load; _nt_clear "$ch"
                backup_conf_once; notify_save; reload_conf
                return 0 ;;
        esac
    done
}

# ==============================================================================
# MAIN
# ==============================================================================
# Old names of the primary storage — offer the rename right away: the editor writes the new ones
if grep -qE '^S3_(ACCESS_KEY|SECRET_KEY|ENDPOINT|BUCKET)=' "$CONFIG_FILE"; then
    UI_TITLE="Old config names"
    if ui_yesno "backup.conf names the primary storage the old way (S3_BUCKET…).\n\nRename it to PRIMARY_S3_* now? A copy is kept next to it." y; then
        ui_msg "$(s3_conf_migrate "$CONFIG_FILE")"
        reload_conf
    fi
fi

choice="status"
while true; do
    UI_TITLE="docker-backup-s3 $(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null) — $(hostname)"
    UI_DEFAULT="$choice"
    choice="$(ui_menu "Storages: $(storages_summary)" \
        status   "Status overview" \
        backup   "Back up now…" \
        restore  "Restore…" \
        sync     "Synchronize storages…" \
        checks   "Checks and diagnostics…" \
        logs     "Logs…" \
        schedule "Scheduled runs…" \
        storages "Storage settings…" \
        notify   "Notifications…" \
        quit     "Exit")" || break
    UI_DEFAULT=""
    case "$choice" in
        status)   run_tool status.sh -c "$CONFIG_FILE" ;;
        backup)   menu_backup ;;
        restore)  menu_restore ;;
        sync)     menu_sync ;;
        checks)   menu_checks ;;
        logs)     menu_logs ;;
        schedule) menu_schedule ;;
        storages) menu_storages ;;
        notify)   menu_notify ;;
        quit)     break ;;
    esac
done
[[ "$UI_MODE" == "whiptail" ]] && clear
exit 0
