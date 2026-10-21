#!/usr/bin/env bash
# The docker-backup menu end to end, in plain mode: answers come from a file in place of the terminal.
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
    case "$prev" in --url) url="$a" ;; esac
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
# main: 9 notifications → 5 email → wizard (to, server, 1 starttls, port default, login, password, sender default)
#   → 2 send a test → q back; 1 when → 2 every run; q; 10 exit
run_menu 9 5 ops@example.com smtp.example.com 1 "" bk@example.com 'pa"ss$1' "" 2 q 1 2 q 10
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
# 9 → 5 email (configured) → 3 off → y; 4 webhook → URL → 1 auto; q (webhook menu) q (notifications) 10
run_menu 9 5 3 y 4 https://discord.com/api/webhooks/1/x 1 q q 10
check "email is off" test -z "$(conf_val EMAIL_TO)$(conf_val SMTP_HOST)$(conf_val SMTP_PASSWORD)"
check "the webhook is saved" test "$(conf_val NOTIFY_WEBHOOK_URL)" == https://discord.com/api/webhooks/1/x
check "the test went as Discord content" test "$(jq -r '.content|split("\n")[0]' "$MOCK_DIR/body")" == "🟢 **Server $(hostname): test message**"
check "the list shows the webhook" grep -q 'Webhook — discord.com (discord)' "$W/out"

section "telegram: a failed test, not kept"
export MOCK_TG=fail
# 9 → 3 telegram → token, chat → ✗ → enter again? n → keep anyway? n → off; q; 10
run_menu 9 3 1:abc 42 n n q 10
unset MOCK_TG
check "Telegram's reason is shown" grep -q 'Bad Request: chat not found' "$W/out"
check "with a hint" grep -q 'nobody has started the bot' "$W/out"
check "the settings are not kept" test -z "$(conf_val TELEGRAM_BOT_TOKEN)"
check "the webhook is untouched" test "$(conf_val NOTIFY_WEBHOOK_URL)" == https://discord.com/api/webhooks/1/x

section "server name and test-all"
# 9 → 2 name → web-9; 6 test all; q; 10
: > "$MOCK_DIR/calls"
run_menu 9 2 web-9 6 q 10
check "NOTIFY_NAME saved" test "$(conf_val NOTIFY_NAME)" == web-9
check "test-all reports the webhook" grep -q '✓ webhook: sent' "$W/out"
check "the new name is in the message" grep -q 'Server web-9: test message' <<< "$(jq -r .content "$MOCK_DIR/body")"

finish
