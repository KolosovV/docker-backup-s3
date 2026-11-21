#!/usr/bin/env bash
# shellcheck disable=SC2034 # the variables are read by the code under test (sourced)
# The proxy on the way to a storage (<ROLE>_S3_PROXY, S3_PROXY): which one a storage gets, which values
# pass, that the password is never printed, and that only aws sees it — not curl, not a hook, not the shell.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# A stub aws: writes the proxy variables it was started with, one per line. Nothing else is needed from it.
mkdir -p "$W/bin"
cat > "$W/bin/aws" <<'EOF'
#!/usr/bin/env bash
{ for v in HTTPS_PROXY https_proxy HTTP_PROXY http_proxy; do printf '%s=%s\n' "$v" "${!v:-}"; done; } > "$AWS_STUB_OUT"
EOF
chmod 755 "$W/bin/aws"
export PATH="$W/bin:$PATH" AWS_STUB_OUT="$W/aws.env"
unset HTTPS_PROXY https_proxy HTTP_PROXY http_proxy

source "$REPO/lib.sh"
source "$REPO/ui.sh"
LOG_FILE="$W/log"
# Our own WORK_DIR: _aws_setup stops at a WORK_DIR that is not ours (work_dir_ready), and in CI the default
# /var/tmp/docker-backup is left by the tests that ran as root before this one
WORK_DIR="$W/work"

section "s3_proxy: the storage's own, else S3_PROXY, none — straight"
S3_PROXY=""; PRIMARY_S3_PROXY=""; SECONDARY_S3_PROXY=""; TERTIARY_S3_PROXY=""
check "nothing set — straight" test -z "$(s3_proxy primary)"
PRIMARY_S3_PROXY="http://p1:3128"
check "the storage's own" test "$(s3_proxy primary)" == "http://p1:3128"
check "another storage is not touched by it" test -z "$(s3_proxy secondary)"
S3_PROXY="http://common:8080"
check "the own one wins over S3_PROXY" test "$(s3_proxy primary)" == "http://p1:3128"
check "without its own — S3_PROXY" test "$(s3_proxy secondary)" == "http://common:8080"
TERTIARY_S3_PROXY="none"
check "none — straight even with S3_PROXY" test -z "$(s3_proxy tertiary)"
S3_PROXY="none"
check "S3_PROXY=none — straight" test -z "$(s3_proxy secondary)"

section "proxy_valid: what aws-cli can use"
for v in "" none "http://proxy:3128" "https://proxy.example.com:443" "http://user:p%40ss@10.0.0.1:3128" \
         "http://proxy.example.com" "http://proxy:3128/" "http://[2001:db8::1]:3128"; do
    check "accepted: '${v}'" proxy_valid "$v"
done
for v in "proxy:3128" "socks5://proxy:1080" "socks5h://proxy:1080" "http://" "http://pro xy:3128" \
         "http://proxy:3128/path" "ftp://proxy:21" "http://proxy:port"; do
    if proxy_valid "$v"; then bad "accepted, though aws can't use it: '${v}'"; else ok "rejected: '${v}'"; fi
done

section "proxy_masked: the password is never printed"
check "user:password → user:***" test "$(proxy_masked 'http://user:s3cret@proxy:3128')" == 'http://user:***@proxy:3128'
check "a password with : and @ inside" test "$(proxy_masked 'http://u:a:b@c@proxy:3128')" == 'http://u:***@proxy:3128'
check "no password — as is" test "$(proxy_masked 'http://proxy:3128')" == 'http://proxy:3128'
check "a user without a password — as is" test "$(proxy_masked 'http://user@proxy:3128')" == 'http://user@proxy:3128'

section "proxy_build / proxy_split: entered in parts, kept as one URL"
check "host:port → http://" test "$(proxy_build 'proxy.example.com:3128')" == 'http://proxy.example.com:3128'
check "spaces and a trailing slash dropped" test "$(proxy_build '  http://proxy:3128/ ')" == 'http://proxy:3128'
check "https:// kept, scheme lowercased" test "$(proxy_build 'HTTPS://proxy:443')" == 'https://proxy:443'
check "empty address — no proxy" test -z "$(proxy_build '' user pass)"
check "login and password" test "$(proxy_build proxy:3128 user secret)" == 'http://user:secret@proxy:3128'
check "a login without a password" test "$(proxy_build proxy:3128 user '')" == 'http://user@proxy:3128'
u="$(proxy_build proxy:3128 'dom\user' 'p@ss:w/rd %+é')"
check "special characters percent-encoded ($u)" test "$u" == 'http://dom%5Cuser:p%40ss%3Aw%2Frd%20%25%2B%C3%A9@proxy:3128'
check "the encoded URL is a valid proxy" proxy_valid "$u"
proxy_split "$u"
check "split: the address" test "$PROXY_ADDR" == 'http://proxy:3128'
check "split: the login decoded" test "$PROXY_USER" == 'dom\user'
check "split: the password decoded" test "$PROXY_PASS" == 'p@ss:w/rd %+é'
check "a pasted URL with a login, login field empty — kept" \
    test "$(proxy_build 'http://u:p@proxy:3128' '' '')" == 'http://u:p@proxy:3128'
check "the login fields win over one typed into the address" \
    test "$(proxy_build 'http://old@proxy:3128' new pw)" == 'http://new:pw@proxy:3128'
proxy_split ""
check "split of nothing — empty parts" test -z "$PROXY_ADDR$PROXY_USER$PROXY_PASS"

section "proxy_wizard (answers from a file, as typed)"
UI_MODE=plain; UI_IN=9
printf 'proxy.example.com:3128\nuser\n' > "$W/answers"; printf 'secret\n' >> "$W/answers"
exec 9<"$W/answers"; proxy_wizard "" 2>/dev/null; rc=$?; exec 9<&-
check "address, login, password → one URL (rc $rc)" test "$PROXY_URL" == 'http://user:secret@proxy.example.com:3128'
printf '\n\n\n' > "$W/answers"
exec 9<"$W/answers"; proxy_wizard "http://user:secret@proxy.example.com:3128" 2>/dev/null; exec 9<&-
check "Enter on every question keeps the address, the login and the password" \
    test "$PROXY_URL" == 'http://user:secret@proxy.example.com:3128'
printf 'socks5://p:1080\n\nproxy:8080\n\n' > "$W/answers"
exec 9<"$W/answers"; proxy_wizard "" 2>/dev/null; exec 9<&-
check "a SOCKS address is asked again, the next one taken" test "$PROXY_URL" == 'http://proxy:8080'
printf '\n' > "$W/answers"
exec 9<"$W/answers"; proxy_wizard "" 2>/dev/null; exec 9<&-
check "an empty address — no proxy" test -z "$PROXY_URL"
UI_MODE=""

section "s3_proxy_route: what the screens say"
S3_PROXY="http://common:8080"; PRIMARY_S3_PROXY=""; SECONDARY_S3_PROXY="none"; TERTIARY_S3_PROXY="http://own:3128"
check "empty → common" test "$(s3_proxy_route primary)" == common
check "none → direct" test "$(s3_proxy_route secondary)" == direct
check "a URL → own" test "$(s3_proxy_route tertiary)" == own
S3_PROXY=""
check "no common proxy → direct" test "$(s3_proxy_route primary)" == direct
check "the line says it" test "$(proxy_route_line own 'http://u:pw@own:3128')" == 'through its own proxy http://u:***@own:3128'

section "store_save writes the route only when there is one"
CONF_FILE="$W/conf"; : > "$CONF_FILE"
log() { :; }; log_ok() { :; }; log_warn() { :; }
declare -A ST=([primary:ACCESS_KEY]=k [primary:SECRET_KEY]=s [primary:ENDPOINT]=e [primary:REGION]=r [primary:BUCKET]=b)
store_save primary
if grep -q '^PRIMARY_S3_PROXY=' "$CONF_FILE"; then bad "an old config got an empty PRIMARY_S3_PROXY line"
else ok "no route — no new line in an old config"; fi
ST[primary:PROXY]="none"; store_save primary
check "a route is written" grep -qx 'PRIMARY_S3_PROXY="none"' "$CONF_FILE"
ST[primary:PROXY]=""; store_save primary
check "and reset back to empty once the line exists" grep -qx 'PRIMARY_S3_PROXY=""' "$CONF_FILE"
S3_PROXY=""; PRIMARY_S3_PROXY=""; SECONDARY_S3_PROXY=""; TERTIARY_S3_PROXY=""

section "aws() hands the proxy to aws alone"
check "type -P still finds the aws binary, not the function" test "$(type -P aws)" == "$W/bin/aws"
S3_CUR_PROXY="http://u:pw@proxy:3128"
aws s3 ls
check "aws got HTTPS_PROXY" grep -qx 'HTTPS_PROXY=http://u:pw@proxy:3128' "$AWS_STUB_OUT"
check "aws got https_proxy" grep -qx 'https_proxy=http://u:pw@proxy:3128' "$AWS_STUB_OUT"
check "aws got HTTP_PROXY" grep -qx 'HTTP_PROXY=http://u:pw@proxy:3128' "$AWS_STUB_OUT"
check "the shell itself has no HTTPS_PROXY after the call (curl goes straight)" test -z "${HTTPS_PROXY:-}${https_proxy:-}"
if env | grep -qE '^(HTTPS?_PROXY|https?_proxy)='; then bad "a proxy variable is in the environment of other programs"
else ok "other programs (curl, a hook) see no proxy"; fi
if env | grep -q 'S3_CUR_PROXY'; then bad "S3_CUR_PROXY is exported"; else ok "S3_CUR_PROXY is not exported"; fi
S3_CUR_PROXY=""
aws s3 ls
check "no proxy — aws gets none" grep -qx 'HTTPS_PROXY=' "$AWS_STUB_OUT"

section "_aws_setup picks the storage's proxy"
PRIMARY_S3_ACCESS_KEY=k; PRIMARY_S3_SECRET_KEY=s; PRIMARY_S3_REGION=r; PRIMARY_S3_BUCKET=b; PRIMARY_S3_ENDPOINT=https://s3.test
SECONDARY_S3_ACCESS_KEY=k; SECONDARY_S3_SECRET_KEY=s; SECONDARY_S3_REGION=r; SECONDARY_S3_BUCKET=b2; SECONDARY_S3_ENDPOINT=https://s3b.test
PRIMARY_S3_PROXY="http://p1:3128"; SECONDARY_S3_PROXY=""; S3_PROXY=""
_aws_setup primary >/dev/null 2>&1
check "primary — its proxy" test "$S3_CUR_PROXY" == "http://p1:3128"
_aws_setup secondary >/dev/null 2>&1
check "secondary without one — straight" test -z "$S3_CUR_PROXY"
aws s3 ls
check "after switching to a storage without a proxy aws goes straight" grep -qx 'HTTPS_PROXY=' "$AWS_STUB_OUT"
# The read side of a copy from the primary runs in a subshell with the primary's settings: the copy's
# proxy in this shell must stay as it was (aws_upload with an s3:// source)
( _aws_setup primary read >/dev/null 2>&1; aws s3 ls )
check "the subshell read through the primary's proxy" grep -qx 'HTTPS_PROXY=http://p1:3128' "$AWS_STUB_OUT"
check "this shell kept the copy's setting" test -z "$S3_CUR_PROXY"

section "the template documents every storage's proxy"
for r in PRIMARY SECONDARY TERTIARY; do
    check "${r}_S3_PROXY in backup.conf.example" grep -q "^${r}_S3_PROXY=\"\"" "$REPO/backup.conf.example"
done
check "S3_PROXY in backup.conf.example" grep -q '^S3_PROXY=""' "$REPO/backup.conf.example"

finish
