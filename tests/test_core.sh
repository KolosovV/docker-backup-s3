#!/usr/bin/env bash
# shellcheck disable=SC2034 # the variables are read by the code under test (sourced or eval-ed)
# Pure functions of lib.sh / docker-backup.sh that need no Docker: paths, packing, bind names.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
source "$REPO/lib.sh"
LOG_FILE="$W/log"

section "path_within"
check "the directory itself" path_within /opt/app /opt/app
check "a path inside" path_within /opt/app/data /opt/app
check "a trailing slash" path_within /opt/app/ /opt/app
if path_within /opt/app-data /opt/app; then bad "/opt/app-data counted as inside /opt/app"; else ok "a sibling is outside"; fi
if path_within /x ""; then bad "an empty dir matched"; else ok "an empty dir matches nothing"; fi

section "tar_gz: compression level and exit codes"
eval "$(sed -n '/^tar_gz() {/,/^}/p' "$REPO/docker-backup.sh")"
mkdir -p "$W/src/a"
head -c 200000 /dev/urandom > "$W/src/a/f"
yes hello | head -c 2000000 > "$W/src/a/text"
COMPRESS_LEVEL=1; tar_gz "$W/l1.tar.gz" -C "$W/src" a; rc1=$?
COMPRESS_LEVEL=9; tar_gz "$W/l9.tar.gz" -C "$W/src" a; rc9=$?
check "exit code 0 at levels 1 and 9" test "$rc1$rc9" == "00"
s1=$(stat -c %s "$W/l1.tar.gz"); s9=$(stat -c %s "$W/l9.tar.gz")
check "level 9 ($s9) is smaller than level 1 ($s1)" test "$s9" -lt "$s1"
tar tzf "$W/l9.tar.gz" > "$W/list"
check "the archive is readable" grep -qx 'a/text' "$W/list"
COMPRESS_LEVEL=6; tar_gz "$W/miss.tar.gz" -C "$W/src" nope 2>/dev/null; rc=$?
check "a missing path is an error (rc $rc)" test "$rc" -ge 2

section "BIND_EXCLUDE_PATHS with two paths"
eval "$(sed -n '/^backup_bind_mount() {/,/^}/p' "$REPO/docker-backup.sh")"
mkdir -p "$W/bind/keep" "$W/bind/skip1" "$W/bind/skip2" "$W/out"
echo k > "$W/bind/keep/x"; echo s > "$W/bind/skip1/x"; echo s > "$W/bind/skip2/x"
BIND_EXCLUDE_PATHS="$W/bind/skip1 $W/bind/skip2"
backup_bind_mount "$W/bind" "$W/out" 1 "" >/dev/null 2>&1
tar tzf "$W"/out/bind_1_*.tar.gz > "$W/blist"
check "the kept folder is archived" grep -q 'bind/keep/x' "$W/blist"
if grep -q 'skip1\|skip2' "$W/blist"; then bad "excluded folders were archived"; else ok "both excluded folders left out"; fi

section "bind archive name → path (docker-restore.sh)"
# The matching rule from docker-restore.sh: the longest BIND_MAP key the archive name ends with.
eval "$(sed -n '/^bind_target_for() {/,/^}/p' "$REPO/docker-restore.sh")"
declare -A BIND_MAP=([srv_www]=/srv/www [data]=/data [srv_www_html]=/srv/www/html)
check "project bind_1_srv_www" test "$(bind_target_for bind_1_srv_www)" == /srv/www
check "standalone bind_nginx_2_srv_www" test "$(bind_target_for bind_nginx_2_srv_www)" == /srv/www
check "the longest match wins" test "$(bind_target_for bind_3_srv_www_html)" == /srv/www/html
check "an unknown name stays unknown" test -z "$(bind_target_for bind_1_other)"

section "helpers"
check "plural 1" test "$(plural 1 project projects)" == project
check "plural 2" test "$(plural 2 project projects)" == projects
check "html_esc" test "$(html_esc 'a<b>&c')" == 'a&lt;b&gt;&amp;c'
check "html_plain" test "$(html_plain '<b>a&amp;b</b> &lt;x&gt;')" == 'a&b <x>'
check "s3_host" test "$(s3_host https://s3.example.com/path)" == s3.example.com
check "fmt_duration 59" test "$(fmt_duration 59)" == 59s
check "fmt_duration 3725" test "$(fmt_duration 3725)" == "1h 02m 05s"
check "s3_label secondary title" test "$(s3_label secondary title)" == "Secondary S3"

finish
