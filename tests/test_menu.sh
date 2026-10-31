#!/usr/bin/env bash
# The docker-backup-s3 menu end to end, in plain mode: answers come from a file in place of the terminal.
# Covers the notification section (the wizards are the ones install.sh uses). The menu needs root.
if [[ "$EUID" -ne 0 ]]; then
    if sudo -n true 2>/dev/null; then exec sudo -E env "PATH=$PATH" bash "$0" "$@"; fi
    echo "   SKIP: the menu needs root (run as root, or with passwordless sudo)"
    exit 0
fi
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# --- the curl stub (smtp, webhook 204, Telegram by MOCK_TG) ---
mkdir -p "$W/bin" "$W/m"
cat > "$W/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""; prev=""
for a in "$@"; do
    case "$prev" in
        --url) url="$a" ;;
        -K) u="$(sed -n 's/^url = "\(.*\)"$/\1/p' "$a")"; [[ -n "$u" ]] && url="$u" ;;
    esac
    case "$a" in http*://*) url="$a" ;; @-) cat > "$MOCK_DIR/body" ;; esac
    prev="$a"
done
echo "$url" >> "$MOCK_DIR/calls"
case "$url" in
    *api.telegram.org*)
        if [[ "${MOCK_TG:-ok}" == ok ]]; then echo '{"ok":true}'
        else echo '{"ok":false,"description":"Bad Request: chat not found"}'; fi ;;
    smtp*://*) exit 0 ;;
    *) printf '204' ;;
esac
EOF
chmod +x "$W/bin/curl"
export PATH="$W/bin:$PATH" MOCK_DIR="$W/m"

CONF="$W/backup.conf"
cp "$REPO/backup.conf.example" "$CONF"
# run_menu <answers…> — one answer per line, as typed
run_menu() {
    printf '%s\n' "$@" > "$W/answers"
    UI_PLAIN=true UI_TTY="$W/answers" bash "$REPO/menu.sh" -c "$CONF" > "$W/out" 2>&1
}
conf_val() { bash -c 'source "$1" 2>/dev/null; printf "%s" "${!2}"' _ "$CONF" "$1"; }

section "email: set up, test"
# notifications: 1 when, 2 name, 3 email, 4 slack, 5 pagerduty, 6 webhook, 7 telegram, 8 test all, 9 quiet
# main: 11 notifications → 3 email → wizard (to, server, 1 starttls, port default, login, password, sender default)
#   → 2 send a test → q back; 1 when → 2 every run; q; 12 exit
run_menu 11 3 ops@example.com smtp.example.com 1 "" bk@example.com 'pa"ss$1' "" 2 q 1 2 q 12
check "the menu exits cleanly" grep -q 'saved to' "$W/out"
check "EMAIL_TO saved" test "$(conf_val EMAIL_TO)" == ops@example.com
check "SMTP_HOST saved" test "$(conf_val SMTP_HOST)" == smtp.example.com
check "SMTP_SECURITY starttls" test "$(conf_val SMTP_SECURITY)" == starttls
check "the default port is left empty" test -z "$(conf_val SMTP_PORT)"
check "the password survives quoting" test "$(conf_val SMTP_PASSWORD)" == 'pa"ss$1'
check "SMTP_FROM defaults to the login" test "$(conf_val SMTP_FROM)" == bk@example.com
check "NOTIFY_ON=always" test "$(conf_val NOTIFY_ON)" == always
check "the wizard sent a test email" grep -q 'test message was sent' "$W/out"
check "the test item worked" grep -q '✓ Email: the test message was sent' "$W/out"
check "the webhook format kept its default" test "$(conf_val NOTIFY_WEBHOOK_FORMAT)" == auto
check "a copy of the config was made" bash -c 'ls "$1".bak.* >/dev/null 2>&1' _ "$CONF"
check "smtp was called" grep -q '^smtp://smtp.example.com:587$' "$MOCK_DIR/calls"

section "email off, webhook on"
: > "$MOCK_DIR/calls"
# 11 → 3 email (configured) → 3 off → y; 6 webhook → URL → 1 auto; q (webhook menu) q (notifications) 12
run_menu 11 3 3 y 6 https://discord.com/api/webhooks/1/x 1 q q 12
check "email is off" test -z "$(conf_val EMAIL_TO)$(conf_val SMTP_HOST)$(conf_val SMTP_PASSWORD)"
check "the webhook is saved" test "$(conf_val NOTIFY_WEBHOOK_URL)" == https://discord.com/api/webhooks/1/x
check "the test went as Discord content" test "$(jq -r '.content|split("\n")[0]' "$MOCK_DIR/body")" == "🟢 **Server $(uname -n): test message**"
check "it names the program that sent it (not \"_\")" grep -q '^Sent by menu.sh at ' <<< "$(jq -r '.content|split("\n")[1]' "$MOCK_DIR/body")"
check "the list shows the webhook" grep -q 'Webhook — discord.com (discord)' "$W/out"

section "telegram: a failed test, not kept"
export MOCK_TG=fail
# 11 → 7 telegram → token, chat → ✗ → enter again? n → keep anyway? n → off; q; 12
run_menu 11 7 1:abc 42 n n q 12
unset MOCK_TG
check "Telegram's reason is shown" grep -q 'Bad Request: chat not found' "$W/out"
check "with a hint" grep -q 'nobody has started the bot' "$W/out"
check "the settings are not kept" test -z "$(conf_val TELEGRAM_BOT_TOKEN)"
check "the webhook is untouched" test "$(conf_val NOTIFY_WEBHOOK_URL)" == https://discord.com/api/webhooks/1/x

section "server name and test-all"
# 11 → 2 name → web-9; 8 test all; q; 12
: > "$MOCK_DIR/calls"
run_menu 11 2 web-9 8 q 12
check "NOTIFY_NAME saved" test "$(conf_val NOTIFY_NAME)" == web-9
check "test-all reports the webhook" grep -q '✓ webhook: sent' "$W/out"
check "the new name is in the message" grep -q 'Server web-9: test message' <<< "$(jq -r .content "$MOCK_DIR/body")"

section "slack"
# 11 → 4 slack → a URL that is not Slack's → again → the right one (a test goes) → q; q; 12
: > "$MOCK_DIR/calls"
run_menu 11 4 https://example.com/x https://hooks.slack.com/services/T/B/X q q 12
check "a URL that is not Slack's is refused" grep -q 'starts with https://hooks.slack.com/' "$W/out"
check "SLACK_WEBHOOK_URL saved" test "$(conf_val SLACK_WEBHOOK_URL)" == https://hooks.slack.com/services/T/B/X
check "the test went in Slack markup" test "$(jq -r '.text|split("\n")[0]' "$MOCK_DIR/body")" == "🟢 *Server web-9: test message*"
check "the list shows Slack" grep -q 'Slack — incoming webhook' "$W/out"

section "pagerduty"
PDKEY="0123456789abcdef0123456789abcdef"
# 11 → 5 pagerduty → key → 2 eu → send a test incident? y → q; q; 12
: > "$MOCK_DIR/calls"
run_menu 11 5 "$PDKEY" 2 y q q 12
check "the key and the region saved" test "$(conf_val PAGERDUTY_ROUTING_KEY):$(conf_val PAGERDUTY_REGION)" == "$PDKEY:eu"
check "a test incident opened and resolved, in the EU region" \
    test "$(grep -c '^https://events.eu.pagerduty.com/v2/enqueue$' "$MOCK_DIR/calls")" == 2
check "the last event resolves the test incident" \
    test "$(jq -r '[.event_action, .dedup_key] | join(" ")' "$MOCK_DIR/body")" == "resolve docker-backup-s3/web-9/test"
check "the list shows the key's end and the region" grep -q 'PagerDuty — integration …cdef, eu' "$W/out"
# test all: PagerDuty asks first; n — it is left out
: > "$MOCK_DIR/calls"
run_menu 11 8 n q 12
check "test-all skips PagerDuty when told so" bash -c '! grep -q pagerduty "$1"' _ "$MOCK_DIR/calls"
check "and tests the others" grep -q '✓ slack: sent' "$W/out"

section "projects: what to leave out"
# docker and aws stubs: two compose projects on "this host"
mkdir -p "$W/p1" "$W/p2"
cat > "$W/bin/docker" <<EOF
#!/usr/bin/env bash
[[ "\$1 \$2" == "ps -a" && "\$*" == *working_dir* ]] && printf 'app1\t%s\napp2\t%s\n' "$W/p1" "$W/p2"
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$W/bin/aws"; chmod +x "$W/bin/docker" "$W/bin/aws"
sed -i 's/^EXCLUDE_PROJECTS=.*/EXCLUDE_PROJECTS="old-*"/' "$CONF"
# 3 projects → 1 not backed up → tick 2 (app2); 2 without dumps → tick 1,2; q; 12
run_menu 3 1 2 2 1,2 q 12
check "EXCLUDE_PROJECTS: the ticked project, and the glob kept" test "$(conf_val EXCLUDE_PROJECTS)" == "old-* app2"
check "DB_DUMP_EXCLUDE_PROJECTS: both" test "$(conf_val DB_DUMP_EXCLUDE_PROJECTS)" == "app1 app2"
check "the menu said the glob is kept" grep -q 'Kept as written (not a project here now): old-\*' "$W/out"
check "the section shows the lists" grep -q 'Not backed up: old-\*, app2' "$W/out"
rm -f "$W/bin/docker" "$W/bin/aws"

section "remote databases: add, change, take off"
# The docker stub answers the login check like psql would
cat > "$W/bin/docker" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == run ]] && { printf '%s\n' "$@" >> "$MOCK_DIR/docker-args"; echo "PostgreSQL 17.6 on x86_64"; }
exit 0
EOF
chmod +x "$W/bin/docker"
# 4 remote → 1 add → name, 1 postgres, host, port default, user, password, database, TLS y → (the check)
#   → 1 shop → 2 change: type kept, host kept, port 6432, user kept, password kept, database kept, TLS kept
#   → q → q; 12
run_menu 4 1 shop 1 db.example.test "" bk 'p"w$1 x' shop y 1 2 "" "" 6432 "" "" "" "" q q 12
check "REMOTE_DBS has it" test "$(conf_val REMOTE_DBS)" == shop
check "its type, host, user, database, TLS" test "$(conf_val REMOTE_DB_SHOP_TYPE):$(conf_val REMOTE_DB_SHOP_HOST):$(conf_val REMOTE_DB_SHOP_USER):$(conf_val REMOTE_DB_SHOP_DATABASE):$(conf_val REMOTE_DB_SHOP_SSL)" == "postgres:db.example.test:bk:shop:true"
check "the password survives quoting, and an edit that left it empty" test "$(conf_val REMOTE_DB_SHOP_PASSWORD)" == 'p"w$1 x'
check "the port from the edit" test "$(conf_val REMOTE_DB_SHOP_PORT)" == 6432
check "the login was checked, the answer shown" grep -q 'saved, and it logs in — PostgreSQL 17.6' "$W/out"
check "the password is not among docker's arguments" bash -c '! grep -qF -- "p\"w\$1 x" "$1"' _ "$MOCK_DIR/docker-args"
check "the main menu lists it" grep -q 'Remote databases: shop' "$W/out"
# 4 remote → 1 shop → 4 take off → y → q; 12
run_menu 4 1 4 y q 12
check "taken off: REMOTE_DBS is empty" test -z "$(conf_val REMOTE_DBS)"
check "and its settings are gone, the password too" bash -c '! grep -q "^REMOTE_DB_SHOP_" "$1"' _ "$CONF"
rm -f "$W/bin/docker"

section "whiptail colors"
# A whiptail stub and a terminal stand-in: ui_init picks whiptail mode and sets the palette
printf '#!/bin/sh\nexit 0\n' > "$W/bin/whiptail"; chmod +x "$W/bin/whiptail"; : > "$W/tty"
colors() { env -u NEWT_COLORS -u NEWT_COLORS_FILE "$@" TERM=xterm UI_TTY="$W/tty" \
    bash -c 'source "$1/ui.sh"; ui_init; printf "%s|%s" "$UI_MODE" "${NEWT_COLORS:-}"' _ "$REPO"; }
out="$(colors)"
check "whiptail mode gets blue, not the distribution's magenta" grep -q '^whiptail|root=white,blue ' <<< "$out"
out="$(colors NEWT_COLORS='root=white,black')"
check "the admin's own palette is kept" test "$out" == 'whiptail|root=white,black'
out="$(colors NEWT_COLORS_FILE=/etc/my-palette)"
check "and so is a palette file" test "$out" == 'whiptail|'

finish
