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
# The URL may come in a config (-K): the Telegram token and webhook URLs are kept off the command line
if [[ -f "$MOCK_DIR/cfg.$n" ]]; then
    u="$(sed -n 's/^url = "\(.*\)"$/\1/p' "$MOCK_DIR/cfg.$n")"; [[ -n "$u" ]] && url="$u"
fi
echo "$n $url" >> "$MOCK_DIR/calls"
case "$url" in
    *api.telegram.org*)
        for a in "$@"; do [[ "$a" == text=* ]] && printf '%s' "${a#text=}" > "$MOCK_DIR/tg.$n"; done
        # silent: no answer at all (a timeout); silent1: only the first call gets none
        if [[ "${MOCK_TG:-}" == silent || ( "${MOCK_TG:-}" == silent1 && "$n" == 1 ) ]]; then exit 28; fi
        if [[ "${MOCK_TG:-ok}" == ok || "${MOCK_TG:-}" == silent1 ]]; then echo '{"ok":true}'
        else echo '{"ok":false,"description":"Bad Request: chat not found"}'; fi ;;
    smtp*://*)
        [[ "${MOCK_SMTP:-ok}" == ok ]] && exit 0
        echo "curl: (67) Login denied" >&2; exit 67 ;;
    *pagerduty.com*)
        # The answer as curl -w '\n%{http_code}' prints it: the body, a newline, the code
        if [[ "${MOCK_PD:-ok}" == ok ]]; then printf '{"status":"success","message":"Event processed"}\n202'
        else printf '{"status":"invalid event","message":"Event object is invalid","errors":["Length of '"'"'routing_key'"'"' is incorrect (should be 32 characters)"]}\n400'; fi ;;
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
check "the bot token is not on curl's command line" bash -c '! grep -q "1:abc" "$1"' _ "$MOCK_DIR/args.1"
check "it is in the config curl reads" grep -q 'url = "https://api.telegram.org/bot1:abc/sendMessage"' "$MOCK_DIR/cfg.1"
reset; notify error "long" "$LONG"
check "a long message goes straight as plain text" test "$(calls)" == 1
check "cut to ≤ 4000 characters" test "$(wc -m < "$MOCK_DIR/tg.1")" -le 4000
check "ends with …" grep -q '…$' "$MOCK_DIR/tg.1"
if grep -q '<b>' "$MOCK_DIR/tg.1"; then bad "tags left in plain text"; else ok "no tags in plain text"; fi
export MOCK_TG=fail; reset; notify error "x" "y" >>"$LOG_FILE" 2>&1; unset MOCK_TG
check "a failure is logged with Telegram's reason" grep -q "to telegram: Bad Request: chat not found" "$LOG_FILE"
check "a refusal is not tried again (HTML, then plain text)" test "$(calls)" == 2
# The pauses between tries: a sleep stub that only records them
printf '#!/bin/sh\necho "$1" >> "$MOCK_DIR/sleeps"\n' > "$W/bin/sleep"; chmod +x "$W/bin/sleep"
export MOCK_TG=silent1; reset; notify error "backup with errors" "$BODY" >>"$LOG_FILE" 2>&1; unset MOCK_TG
check "no answer: tried again after 5 s, and sent" bash -c '[[ "$(cat "$1/sleeps")" == 5 && $(wc -l < "$1/calls") == 2 ]] && grep -q "^🔴 <b>Server" "$1/tg.2"' _ "$MOCK_DIR"
check "and nothing about a failure in the log" bash -c '! grep -q "to telegram" "$1"' _ "$LOG_FILE"
export MOCK_TG=silent; reset; notify error "x" "y" >>"$LOG_FILE" 2>&1; unset MOCK_TG
check "never an answer: 3 tries, pauses 5 and 15 s" bash -c '[[ "$(tr "\n" " " < "$1/sleeps")" == "5 15 " && $(wc -l < "$1/calls") == 3 ]]' _ "$MOCK_DIR"
check "then logged as no response" grep -q "to telegram: no response from api.telegram.org" "$LOG_FILE"
rm -f "$W/bin/sleep"

section "telegram: without a sound"
NOTIFY_ON=always
reset; notify success "backup done" "x"
check "success is silent by default" grep -qx 'disable_notification=true' "$MOCK_DIR/args.1"
reset; notify error "backup with errors" "$BODY"
check "an error rings" bash -c '! grep -q disable_notification "$1"' _ "$MOCK_DIR/args.1"
reset; notify warn "check the settings" "x"
check "a warning rings by default" bash -c '! grep -q disable_notification "$1"' _ "$MOCK_DIR/args.1"
NOTIFY_SILENT="success warn"; reset; notify warn "check the settings" "x"
check "NOTIFY_SILENT=\"success warn\" — a warning is silent too" grep -qx 'disable_notification=true' "$MOCK_DIR/args.1"
NOTIFY_SILENT=""; reset; notify success "backup done" "x"
check "NOTIFY_SILENT empty — success rings" bash -c '! grep -q disable_notification "$1"' _ "$MOCK_DIR/args.1"
unset NOTIFY_SILENT
reset; notify success "long" "$LONG"
check "the plain-text fallback is silent as well" grep -qx 'disable_notification=true' "$MOCK_DIR/args.1"
reset; notify_test telegram >/dev/null 2>&1
check "a test message rings (it checks that an alert is heard)" bash -c '! grep -q disable_notification "$1"' _ "$MOCK_DIR/args.1"
check "and NOTIFY_SILENT is back afterwards" test "${NOTIFY_SILENT-unset}" == unset
NOTIFY_ON=error
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
check "the webhook URL (its secret) is not on curl's command line" bash -c '! grep -q "webhooks/1/abc" "$1"' _ "$MOCK_DIR/args.1"
reset; notify error "long" "$LONG"
check "≤ 2000 characters" test "$(jq -r .content "$MOCK_DIR/body.1" | wc -m)" -le 2000
check "an error has no flags (it rings)" test "$(jq -c .flags "$MOCK_DIR/body.1")" == null
NOTIFY_ON=always; reset; notify success "backup done" "x"; NOTIFY_ON=error
check "success goes with SUPPRESS_NOTIFICATIONS" test "$(jq -c .flags "$MOCK_DIR/body.1")" == 4096

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

EMAIL_TO=""; SMTP_HOST=""

section "slack"
SLACK_WEBHOOK_URL="https://hooks.slack.com/services/T/B/SECRET"
reset; notify error "backup with errors" "$BODY"
s="$(jq -r .text "$MOCK_DIR/body.1")"
check "its own channel, Slack markup" test "${s%%$'\n'*}" == "🔴 *Server web-1: backup with errors*"
check "the URL (its secret) is not on curl's command line" bash -c '! grep -q SECRET "$1"' _ "$MOCK_DIR/args.1"
check "it is in the config curl reads" grep -q 'url = "https://hooks.slack.com/services/T/B/SECRET"' "$MOCK_DIR/cfg.1"
reset; notify error "long" "$LONG"
check "a long message is cut on a line, under 3900 characters" test "$(jq -r .text "$MOCK_DIR/body.1" | wc -m)" -le 3900
NOTIFY_WEBHOOK_URL="https://discord.com/api/webhooks/1/abc"
reset; notify error "x" "y"
check "Slack and a Discord webhook at once" test "$(calls)" == 2
NOTIFY_WEBHOOK_URL=""
export MOCK_CODE=404; reset; notify error "x" "y" >>"$LOG_FILE" 2>&1; unset MOCK_CODE
check "a refusal is logged with the code" grep -q "to slack: Slack replied HTTP 404" "$LOG_FILE"
reset; notify_test slack >/dev/null 2>&1
check "the test message goes to Slack" test "$(jq -r '.text|split("\n")[0]' "$MOCK_DIR/body.1")" == "🟢 *Server web-1: test message*"
SLACK_WEBHOOK_URL=""

section "pagerduty"
PAGERDUTY_ROUTING_KEY="0123456789abcdef0123456789abcdef"
reset; notify error "backup with errors" "$BODY"
p="$MOCK_DIR/body.1"
check "an error triggers an incident" test "$(jq -r .event_action "$p")" == trigger
check "to the US endpoint by default" grep -q ' https://events.pagerduty.com/v2/enqueue$' "$MOCK_DIR/calls"
check "one incident per server and script" test "$(jq -r .dedup_key "$p")" == "docker-backup-s3/web-1/$(basename "$0" .sh)"
check "severity error, the summary is the message line" \
    test "$(jq -r '[.payload.severity, .payload.summary, .payload.source] | join("|")' "$p")" == "error|Server web-1: backup with errors|web-1"
check "the details in plain text" test "$(jq -r .payload.custom_details.details "$p")" == "Saved nowhere: app&db."$'\n'"Details: tail -n 80 /var/log/docker-backup.log"
check "the routing key is in the body" test "$(jq -r .routing_key "$p")" == "$PAGERDUTY_ROUTING_KEY"
check "and on no command line (curl's)" bash -c '! grep -q "$2" "$1"' _ "$MOCK_DIR/args.1" "$PAGERDUTY_ROUTING_KEY"
reset; notify warn "check the settings" "x"
check "a warning — severity warning" test "$(jq -r .payload.severity "$MOCK_DIR/body.1")" == warning
reset; notify success "backup done" "x"
check "a success resolves it, even with NOTIFY_ON=error" \
    test "$(jq -c '[.event_action, .dedup_key, has("payload")]' "$MOCK_DIR/body.1")" == "[\"resolve\",\"docker-backup-s3/web-1/$(basename "$0" .sh)\",false]"
check "and only PagerDuty hears of it" test "$(calls)" == 1
NOTIFY_ON=always; TELEGRAM_BOT_TOKEN="1:abc"; TELEGRAM_CHAT_ID="42"
reset; notify success "backup done" "x"
check "NOTIFY_ON=always: one resolve, and the message to the others" \
    test "$(grep -c pagerduty "$MOCK_DIR/calls"):$(calls)" == "1:2"
TELEGRAM_BOT_TOKEN=""; TELEGRAM_CHAT_ID=""
NOTIFY_ON=none; reset; notify error "x" "y"; notify success "x" "y"
check "NOTIFY_ON=none: nothing, PagerDuty included" test "$(calls)" == 0
NOTIFY_ON=error
PAGERDUTY_REGION=eu; reset; notify error "x" "y"
check "PAGERDUTY_REGION=eu → the EU endpoint" grep -q ' https://events.eu.pagerduty.com/v2/enqueue$' "$MOCK_DIR/calls"
PAGERDUTY_REGION=mars; reset; notify error "x" "y" >>"$LOG_FILE" 2>&1
check "an unknown region is reported" grep -q "to pagerduty: PAGERDUTY_REGION must be us or eu" "$LOG_FILE"
check "and nothing is sent" test "$(calls)" == 0
unset PAGERDUTY_REGION
reset; notify_test pagerduty >/dev/null 2>&1
check "the test: a test incident, opened and resolved" \
    test "$(jq -r '[.event_action, .dedup_key, .payload.severity] | join(" ")' "$MOCK_DIR/body.1")|$(jq -r '[.event_action, .dedup_key] | join(" ")' "$MOCK_DIR/body.2")" \
    == "trigger docker-backup-s3/web-1/test info|resolve docker-backup-s3/web-1/test"
check "PD_TEST does not stay set" test "${PD_TEST-unset}" == unset
export MOCK_PD=bad; reset; notify_test pagerduty 2>"$W/e" >/dev/null; rc=$?; unset MOCK_PD
check "a refusal: rc 1 with PagerDuty's own reason" \
    bash -c '[[ $2 == 1 ]] && grep -q "PagerDuty replied HTTP 400 (Event object is invalid: Length of .routing_key. is incorrect" "$1"' _ "$W/e" "$rc"
reset; pagerduty_check 2>/dev/null
check "the config check is a change event (it pages no one)" \
    bash -c 'grep -q " https://events.pagerduty.com/v2/change/enqueue$" "$1" && [[ "$(jq -c "[has(\"event_action\"), .payload.source]" "$2")" == "[false,\"web-1\"]" ]]' _ "$MOCK_DIR/calls" "$MOCK_DIR/body.1"
PAGERDUTY_ROUTING_KEY=""

section "teams"
TEAMS_WEBHOOK_URL="https://prod.example.test/workflows/SECRET"
reset; notify error "backup with errors" "$BODY"
t="$MOCK_DIR/body.1"
check "an Adaptive Card in a message" test "$(jq -r '[.type, .attachments[0].contentType, .attachments[0].content.type] | join(" ")' "$t")" \
    == "message application/vnd.microsoft.card.adaptive AdaptiveCard"
check "the title in red (Attention)" test "$(jq -r '.attachments[0].content.body[0] | [.text, .color] | join("|")' "$t")" == "Server web-1: backup with errors|Attention"
check "one plain text block a line" test "$(jq -r '[.attachments[0].content.body[1:][].text] | join("|")' "$t")" == "Saved nowhere: app&db.|Details: tail -n 80 /var/log/docker-backup.log"
check "the URL is not on curl's command line" bash -c '! grep -q SECRET "$1"' _ "$MOCK_DIR/args.1"
reset; notify warn "x" "y"
check "a warning is orange (Warning)" test "$(jq -r '.attachments[0].content.body[0].color' "$MOCK_DIR/body.1")" == Warning
TEAMS_WEBHOOK_URL=""

section "ntfy"
NTFY_URL="https://ntfy.example.test/backups-7f3/"
reset; notify error "backup with errors" "$BODY"
n1="$MOCK_DIR/body.1"
check "to the server's root" grep -q '^1 https://ntfy.example.test/$' "$MOCK_DIR/calls"
check "JSON: topic, title, details, high priority, a red tag" \
    test "$(jq -c '[.topic, .title, .priority, .tags[0]]' "$n1")" == '["backups-7f3","Server web-1: backup with errors",4,"red_circle"]'
check "the details in plain text" test "$(jq -r .message "$n1")" == "Saved nowhere: app&db."$'\n'"Details: tail -n 80 /var/log/docker-backup.log"
check "no token — no Authorization header" bash -c '! grep -q Authorization "$1"' _ "$MOCK_DIR/cfg.1"
NOTIFY_ON=always NTFY_TOKEN="tk_secret"; reset; notify success "backup done" "x"
check "a silent level goes at low priority" test "$(jq -r '[.priority, .tags[0]] | join(" ")' "$MOCK_DIR/body.1")" == "2 green_circle"
check "the token in a header, in the config curl reads" grep -qx 'header = "Authorization: Bearer tk_secret"' "$MOCK_DIR/cfg.1"
check "and not on the command line" bash -c '! grep -q tk_secret "$1"' _ "$MOCK_DIR/args.1"
NOTIFY_ON=error; NTFY_TOKEN=""
reset; notify_test ntfy >/dev/null 2>&1
check "the test message rings (priority 3)" test "$(jq -r .priority "$MOCK_DIR/body.1")" == 3
NTFY_URL=""

section "apprise"
cat > "$W/bin/apprise" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_DIR/apprise.args"
prev=""; for a in "$@"; do [[ "$prev" == -c ]] && cp "$a" "$MOCK_DIR/apprise.cfg"; prev="$a"; done
[[ "${MOCK_APPRISE:-ok}" == ok ]] && exit 0
echo "ERROR - Unsupported URL: bad://x" >&2; exit 1
EOF
chmod +x "$W/bin/apprise"
APPRISE_URLS="pover://user@SECRET  matrixs://u:p@m.example.test/#room"
reset; notify error "backup with errors" "$BODY"
check "the type is failure, the title and the plain details" \
    bash -c 'a="$(tr "\n" "|" < "$1")"; [[ "$a" == *"-n|failure|"* && "$a" == *"-t|🔴 Server web-1: backup with errors|"* && "$a" == *"Saved nowhere: app&db."* ]]' _ "$MOCK_DIR/apprise.args"
check "the URLs in a config, one a line" test "$(cat "$MOCK_DIR/apprise.cfg")" == "pover://user@SECRET"$'\n'"matrixs://u:p@m.example.test/#room"
check "and not on its command line" bash -c '! grep -q SECRET "$1"' _ "$MOCK_DIR/apprise.args"
reset; notify warn "x" "y"
check "a warning is warning" grep -qx warning "$MOCK_DIR/apprise.args"
export MOCK_APPRISE=bad; reset; notify error "x" "y" >>"$LOG_FILE" 2>&1; unset MOCK_APPRISE
check "a failure is logged with apprise's words" grep -q 'to apprise: ERROR - Unsupported URL: bad://x' "$LOG_FILE"
rm -f "$W/bin/apprise"
reset; notify_test apprise 2>"$W/e" >/dev/null
check "no apprise on the host — said so" grep -q 'apprise is not installed' "$W/e"
APPRISE_URLS=""

section "heartbeat: healthchecks"
HB_URL="https://hc.example.test/ping/SECRET"
reset; heartbeat start; rid="$HB_RID"
check "a run id is made" test -n "$rid"
check "start → /start with the run id" grep -q "^1 https://hc.example.test/ping/SECRET/start?rid=${rid}\$" "$MOCK_DIR/calls"
check "the URL is not on curl's command line" bash -c '! grep -q SECRET "$1"' _ "$MOCK_DIR/args.1"
reset; notify error "backup with errors" "$BODY" >/dev/null 2>&1
check "an error notification pings /fail, the same run id" grep -q "^1 https://hc.example.test/ping/SECRET/fail?rid=${rid}\$" "$MOCK_DIR/calls"
check "with the message as the body, in plain text" test "$(head -n 1 "$MOCK_DIR/body.1")" == "Server web-1: backup with errors"
reset; NOTIFY_ON=none notify success "backup done" "x"
check "success pings the URL itself, whatever NOTIFY_ON says" grep -q "^1 https://hc.example.test/ping/SECRET?rid=${rid}\$" "$MOCK_DIR/calls"
check "and only that" test "$(calls)" == 1
reset; NOTIFY_ON=none notify warn "check the settings" "x"
check "a warning counts as a run that happened" grep -q "SECRET?rid=" "$MOCK_DIR/calls"
HB_URL="https://hc.example.test/ping/abc?create=1"
reset; heartbeat fail "x"
check "a query in the URL is kept, the run id added" grep -q "^1 https://hc.example.test/ping/abc/fail?create=1&rid=${rid}\$" "$MOCK_DIR/calls"
HEARTBEAT_START=false; reset; heartbeat start
check "HEARTBEAT_START=false: no /start" test "$(calls)" == 0
unset HEARTBEAT_START
export MOCK_CODE=000; reset; heartbeat success "x" >>"$LOG_FILE" 2>&1; rc=$?; unset MOCK_CODE
check "an unreachable monitor is logged, not fatal" bash -c '[[ $2 == 0 ]] && grep -q "Could not ping the monitor (success): no response" "$1"' _ "$LOG_FILE" "$rc"

section "heartbeat: uptime kuma"
HB_URL="https://kuma.example.test/api/push/TOKEN?status=up&msg=OK&ping="
reset; heartbeat start
check "kuma has no start" test "$(calls)" == 0
reset; heartbeat fail "backup with errors" "$BODY"
a="$(tr '\n' '|' < "$MOCK_DIR/args.1")"
check "down, to the URL without its query" bash -c '[[ "$1" == *"-G|"* && "$1" == *"status=down|"* ]] && grep -q "^1 https://kuma.example.test/api/push/TOKEN$" "$2"' _ "$a" "$MOCK_DIR/calls"
check "msg is the first line" grep -qx 'msg=Server web-1: backup with errors' "$MOCK_DIR/args.1"
reset; heartbeat success "backup done"
check "success is up" grep -qx 'status=up' "$MOCK_DIR/args.1"
HEARTBEAT_FORMAT=healthchecks; reset; heartbeat success "x"
check "HEARTBEAT_FORMAT overrides the guess" grep -q '^1 https://kuma.example.test/api/push/TOKEN?' "$MOCK_DIR/calls"
HEARTBEAT_FORMAT=bogus; reset; heartbeat success "x" >>"$LOG_FILE" 2>&1
check "an unknown format: nothing sent" test "$(calls)" == 0
check "and it is logged" grep -q "HEARTBEAT_FORMAT must be" "$LOG_FILE"
unset HEARTBEAT_FORMAT; HB_URL=""; unset HB_RID
reset; heartbeat fail "x"
check "no URL — no ping" test "$(calls)" == 0

section "metrics"
METRICS_DIR="$W/prom"; mkdir -p "$METRICS_DIR"
metrics_write t demo 1 projects 3 uploaded_bytes 1024
f="$METRICS_DIR/t.prom"
check "the gauges are written" bash -c 'grep -qx "demo_last_run_success 1" "$1" && grep -qx "demo_projects 3" "$1" && grep -qx "demo_uploaded_bytes 1024" "$1"' _ "$f"
check "each with its TYPE" test "$(grep -c '^# TYPE demo_.* gauge$' "$f")" == 5
ok_ts="$(awk '$1 == "demo_last_success_timestamp_seconds" { print $2 }' "$f")"
check "the success time is the run's" test "$ok_ts" == "$(awk '$1 == "demo_last_run_timestamp_seconds" { print $2 }' "$f")"
sed -i "s/^demo_last_success_timestamp_seconds .*/demo_last_success_timestamp_seconds 1700000000/" "$f"
metrics_write t demo 0 projects 3
check "a failed run: success 0, the last success kept" \
    bash -c 'grep -qx "demo_last_run_success 0" "$1" && grep -qx "demo_last_success_timestamp_seconds 1700000000" "$1"' _ "$f"
check "no temporary file left" test "$(ls "$METRICS_DIR" | wc -l)" == 1
check "readable by the collector (644)" test "$(stat -c %a "$f")" == 644
rm -f "$f"; metrics_write t demo 0
check "never a success — no last-success line" bash -c '! grep -q last_success_timestamp "$1" && grep -qx "demo_last_run_success 0" "$1"' _ "$f"
METRICS_DIR="$W/nope"; metrics_write t demo 1 >>"$LOG_FILE" 2>&1; rc=$?
check "a missing folder: a warning, not a failure" bash -c '[[ $2 == 0 ]] && grep -q "METRICS_DIR does not exist" "$1"' _ "$LOG_FILE" "$rc"
METRICS_DIR=""

section "notify_any, backup_running_pid"
if notify_any; then bad "notify_any with nothing set up"; else ok "notify_any: nothing set up"; fi
SLACK_WEBHOOK_URL="https://hooks.slack.com/services/T/B/X"
check "notify_any: Slack alone counts" notify_any
SLACK_WEBHOOK_URL=""
LOCK_FILE="$W/lock"
if backup_running_pid >/dev/null; then bad "a backup without a lock"; else ok "no lock — no backup"; fi
mkdir -p "$W/lock.d"; echo $$ > "$W/lock.d/pid"
check "a lock of a live process — its PID" test "$(backup_running_pid)" == "$$"
echo 999999 > "$W/lock.d/pid"
if backup_running_pid >/dev/null; then bad "a stale lock counted"; else ok "a stale lock does not count"; fi
rm -rf "$W/lock.d"; unset LOCK_FILE

EMAIL_TO="a@example.com, b@example.com"; SMTP_HOST="smtp.example.com"; SMTP_SECURITY=starttls
SMTP_USER=u; SMTP_FROM="noreply@example.com"

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
