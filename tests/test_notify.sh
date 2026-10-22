#!/usr/bin/env bash
# Notifications: Telegram, webhook formats, email — with curl replaced by a stub that records what it got.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# --- the curl stub: answers by MOCK_TG / MOCK_CODE / MOCK_SMTP ---
mkdir -p "$W/bin" "$W/m"
cat > "$W/bin/curl" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$MOCK_DIR/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$MOCK_DIR/n"
printf '%s\n' "$@" > "$MOCK_DIR/args.$n"
url=""; prev=""
for a in "$@"; do
    case "$prev" in
        --upload-file) cp "$a" "$MOCK_DIR/mail.$n" ;;
        -K)            cp "$a" "$MOCK_DIR/cfg.$n" ;;
        --url)         url="$a" ;;
    esac
    case "$a" in http*://*) url="$a" ;; @-) cat > "$MOCK_DIR/body.$n" ;; esac
    prev="$a"
done
echo "$n $url" >> "$MOCK_DIR/calls"
case "$url" in
    *api.telegram.org*)
        for a in "$@"; do [[ "$a" == text=* ]] && printf '%s' "${a#text=}" > "$MOCK_DIR/tg.$n"; done
        if [[ "${MOCK_TG:-ok}" == ok ]]; then echo '{"ok":true}'
        else echo '{"ok":false,"description":"Bad Request: chat not found"}'; fi ;;
    smtp*://*)
        [[ "${MOCK_SMTP:-ok}" == ok ]] && exit 0
        echo "curl: (67) Login denied" >&2; exit 67 ;;
    *)
        printf '%s' "${MOCK_CODE:-204}"; [[ "${MOCK_CODE:-204}" == 000 ]] && exit 7; exit 0 ;;
esac
EOF
chmod +x "$W/bin/curl"
export PATH="$W/bin:$PATH" MOCK_DIR="$W/m"
reset() { rm -rf "$MOCK_DIR"; mkdir -p "$MOCK_DIR"; : > "$LOG_FILE"; }
calls() { [[ -f "$MOCK_DIR/calls" ]] && wc -l < "$MOCK_DIR/calls" || echo 0; }

source "$REPO/lib.sh"
LOG_FILE="$W/log"; NOTIFY_NAME="web-1"; NOTIFY_ON=error
BODY="Saved nowhere: <b>app&amp;db</b>."$'\n'"Details: <code>tail -n 80 /var/log/docker-backup.log</code>"
LONG="$(for i in $(seq 1 300); do echo "• <b>project-$i</b>: something went wrong here"; done)"

section "filters"
reset; notify error "backup with errors" "$BODY"
check "no channels — nothing sent" test "$(calls)" == 0
TELEGRAM_BOT_TOKEN="1:abc"; TELEGRAM_CHAT_ID="42"
reset; notify success "backup done" "x"
check "NOTIFY_ON=error drops success" test "$(calls)" == 0
NOTIFY_ON=none; reset; notify error "x" "y"
check "NOTIFY_ON=none sends nothing" test "$(calls)" == 0
NOTIFY_ON=error

section "telegram"
reset; notify error "backup with errors" "$BODY"
check "HTML head line" grep -q '^🔴 <b>Server web-1: backup with errors</b>' "$MOCK_DIR/tg.1"
check "one call" test "$(calls)" == 1
reset; notify error "long" "$LONG"
check "a long message goes straight as plain text" test "$(calls)" == 1
check "cut to ≤ 4000 characters" test "$(wc -m < "$MOCK_DIR/tg.1")" -le 4000
check "ends with …" grep -q '…$' "$MOCK_DIR/tg.1"
if grep -q '<b>' "$MOCK_DIR/tg.1"; then bad "tags left in plain text"; else ok "no tags in plain text"; fi
export MOCK_TG=fail; reset; notify error "x" "y" >>"$LOG_FILE" 2>&1; unset MOCK_TG
check "a failure is logged with Telegram's reason" grep -q "to telegram: Bad Request: chat not found" "$LOG_FILE"
TELEGRAM_BOT_TOKEN=""; TELEGRAM_CHAT_ID=""

section "webhook: discord"
NOTIFY_WEBHOOK_URL="https://discord.com/api/webhooks/1/abc"
check "auto → discord" test "$(webhook_format)" == discord
reset; notify error "backup with errors" "$BODY"
c="$(jq -r .content "$MOCK_DIR/body.1")"
check "bold head" test "${c%%$'\n'*}" == "🔴 **Server web-1: backup with errors**"
check "entities decoded" grep -q 'app&db' <<< "$c"
check "code in backticks" grep -q '`tail -n 80' <<< "$c"
check "mentions disabled" test "$(jq -c .allowed_mentions "$MOCK_DIR/body.1")" == '{"parse":[]}'
reset; notify error "long" "$LONG"
check "≤ 2000 characters" test "$(jq -r .content "$MOCK_DIR/body.1" | wc -m)" -le 2000

section "webhook: slack"
NOTIFY_WEBHOOK_URL="https://hooks.slack.com/services/T/B/X"
check "auto → slack" test "$(webhook_format)" == slack
reset; notify warn "secondary S3 did not accept everything" "$BODY"
s="$(jq -r .text "$MOCK_DIR/body.1")"
check "bold head" test "${s%%$'\n'*}" == "🟠 *Server web-1: secondary S3 did not accept everything*"
check "& stays escaped" grep -q 'app&amp;db' <<< "$s"
check "only the text field" test "$(jq -r 'keys|join(",")' "$MOCK_DIR/body.1")" == text

section "webhook: json"
NOTIFY_WEBHOOK_URL="https://example.com/hook"
check "auto → json" test "$(webhook_format)" == json
reset; notify error "backup with errors" "$BODY"
j="$MOCK_DIR/body.1"
check "level/server/title" test "$(jq -r '[.level,.server,.title]|join("|")' "$j")" == "error|web-1|backup with errors"
check "details in plain text" test "$(jq -r .details "$j")" == "Saved nowhere: app&db."$'\n'"Details: tail -n 80 /var/log/docker-backup.log"
check "time in UTC" grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' <<< "$(jq -r .time "$j")"
NOTIFY_WEBHOOK_FORMAT=discord
check "an explicit format wins" test "$(webhook_format)" == discord
NOTIFY_WEBHOOK_FORMAT=teams
if notify_test webhook 2>"$W/e"; then bad "an unknown format was accepted"; else check "an unknown format is reported" grep -q "must be auto" "$W/e"; fi
NOTIFY_WEBHOOK_FORMAT=auto

section "webhook: failures"
export MOCK_CODE=400; reset; notify error "x" "y" >>"$LOG_FILE" 2>&1
check "HTTP 400 is a failure" grep -q "the webhook replied HTTP 400" "$LOG_FILE"
export MOCK_CODE=000; reset; notify error "x" "y" >>"$LOG_FILE" 2>&1
check "no response is a failure" grep -q "no response from the webhook URL" "$LOG_FILE"
unset MOCK_CODE; NOTIFY_WEBHOOK_URL=""

section "email"
EMAIL_TO="a@example.com, b@example.com"; SMTP_HOST="smtp.example.com"
SMTP_USER='bk@example.com'; SMTP_PASSWORD='p"a$s\w'"'"'d'
reset; notify error "backup with errors" "$BODY"
a="$(cat "$MOCK_DIR/args.1")"
check "starttls → smtp://…:587" grep -qx 'smtp://smtp.example.com:587' <<< "$a"
check "--ssl-reqd" grep -qx -- '--ssl-reqd' <<< "$a"
check "two recipients" test "$(grep -cx -- '--mail-rcpt' <<< "$a")" == 2
if grep -q 'p"a\$s' <<< "$a"; then bad "the password is on the command line"; else ok "the password is not on the command line"; fi
check "the curl config is escaped" test "$(cat "$MOCK_DIR/cfg.1")" == 'user = "bk@example.com:p\"a$s\\w'"'"'d"'
m="$MOCK_DIR/mail.1"
check "CRLF line endings" grep -q $'\r$' "$m"
subj="$(grep '^Subject:' "$m" | tr -d '\r')"; enc="${subj#Subject: =?UTF-8?B?}"; enc="${enc%\?=}"
check "the subject decodes" test "$(printf '%s' "$enc" | base64 -d)" == "🔴 Server web-1: backup with errors"
check "To" grep -q '^To: a@example.com, b@example.com' "$m"
check "From = SMTP_USER, named docker-backup-s3" grep -q '^From: docker-backup-s3 <bk@example.com>' "$m"
check "Auto-Submitted" grep -q '^Auto-Submitted: auto-generated' "$m"
tr -d '\r' < "$m" > "$W/mail.lf"
PYTHONIOENCODING=utf-8 python3 -I - "$W/mail.lf" > "$W/parts" <<'PY'
import email, sys
msg = email.message_from_binary_file(open(sys.argv[1], 'rb'))
for p in msg.walk():
    if p.get_content_maintype() == 'text':
        print('==', p.get_content_type())
        print(p.get_payload(decode=True).decode())
PY
check "plain and HTML parts" grep -c '^== text/' "$W/parts" -q
check "the plain part" grep -q '^Saved nowhere: app&db.$' "$W/parts"
check "the HTML part with <br>" grep -q '<b>Server web-1: backup with errors</b><br>' "$W/parts"
check "styled code" grep -q '<code style=' "$W/parts"
SMTP_SECURITY=tls; reset; notify_send error t b email; a="$(cat "$MOCK_DIR/args.1")"
check "tls → smtps://…:465" grep -qx 'smtps://smtp.example.com:465' <<< "$a"
if grep -qx -- '--ssl-reqd' <<< "$a"; then bad "--ssl-reqd with tls"; else ok "no --ssl-reqd with tls"; fi
SMTP_SECURITY=none; SMTP_PORT=2525; SMTP_USER=""; SMTP_FROM="noreply@example.com"
reset; notify_send error t b email; a="$(cat "$MOCK_DIR/args.1")"
check "none with its own port" grep -qx 'smtp://smtp.example.com:2525' <<< "$a"
if grep -qx -- '-K' <<< "$a"; then bad "login sent without SMTP_USER"; else ok "no login without SMTP_USER"; fi
SMTP_SECURITY=bogus; notify_test email 2>"$W/e"
check "an unknown security is reported" grep -q "must be starttls" "$W/e"
SMTP_SECURITY=starttls; SMTP_PORT=""; SMTP_USER=u; export MOCK_SMTP=fail; reset
notify_test email 2>"$W/e"; rc=$?
check "an SMTP failure: rc 1 with curl's reason" test "$rc:$(cat "$W/e")" == "1:(67) Login denied"
unset MOCK_SMTP

section "all channels, one failing"
TELEGRAM_BOT_TOKEN="1:abc"; TELEGRAM_CHAT_ID="42"; NOTIFY_WEBHOOK_URL="https://example.com/hook"
export MOCK_CODE=500; reset; notify error "x" "y" >>"$LOG_FILE" 2>&1; unset MOCK_CODE
check "all 3 channels tried" test "$(calls)" == 3
check "only the webhook failure logged" test "$(grep -c 'Could not send' "$LOG_FILE")" == 1

section "conf_set quoting"
source "$REPO/ui.sh" 2>/dev/null
CONF_FILE="$W/c.conf"; printf 'SMTP_PASSWORD=""\nA="x"\n' > "$CONF_FILE"
conf_set SMTP_PASSWORD 'p"a$s`x`\w'"'"'d&|z'
conf_set A 'plain&|value'
conf_set NEWV 'n$ew'
check "values survive being sourced" bash -c 'source "$1"; [[ "$SMTP_PASSWORD" == "p\"a\$s\`x\`\\w'"'"'d&|z" && "$A" == "plain&|value" && "$NEWV" == "n\$ew" ]]' _ "$CONF_FILE"
check "a plain value stays in double quotes" grep -qx 'A="plain&|value"' "$CONF_FILE"

finish
