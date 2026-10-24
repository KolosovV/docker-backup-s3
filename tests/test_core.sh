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

section "sync-s3.sh listing: aws warnings are not object keys"
eval "$(sed -n '/^_clean_aws_err() {/,/^}/p; /^list_bucket() {/,/^}/p' "$REPO/sync-s3.sh")"
S3_OPTS=(); BACKUP_PREFIX=it
aws() { echo "Invalid -W option ignored: invalid module name: 'urllib3.exceptions'" >&2
        printf 'it/p/1/a.tar.gz\t10\nit/p/1/\t0\n'; }
check "only the real key, no warning, no folder marker" test "$(list_bucket b)" == $'it/p/1/a.tar.gz\t10'
aws() { echo "An error occurred (NoSuchBucket) when calling ListObjectsV2" >&2; return 254; }
list_bucket b > "$W/lb" 2>&1; rc=$?
check "a listing error keeps its exit code" test "$rc" -eq 254
check "and says why" grep -q 'NoSuchBucket' "$W/lb"
unset -f aws

section "conf_duplicates: a setting given twice"
printf 'A=1\nENCRYPT_BACKUPS="true"\n# ENCRYPT_BACKUPS="no, a comment"\nexport ENCRYPT_BACKUPS="false"  # tail\nNOTIFY_NAME="v"\nNOTIFY_NAME=""\n' > "$W/dup.conf"
printf 'SCAN_DIRS="/opt /srv"\nSCAN_DIRS="/a b"\n' >> "$W/dup.conf"
d="$(conf_duplicates "$W/dup.conf" "$REPO/backup.conf.example")"
check "ENCRYPT_BACKUPS: the user's true lost to the default false further down" \
    grep -qx $'ENCRYPT_BACKUPS\t4\t"false"\t2\t"true"\t1' <<< "$d"
check "NOTIFY_NAME: the user's name lost to the default empty one" grep -qx $'NOTIFY_NAME\t6\t""\t5\t"v"\t1' <<< "$d"
check "an override at the end is a duplicate, not a lost value" grep -qx $'SCAN_DIRS\t8\t"/a b"\t7\t"/opt /srv"\t0' <<< "$d"
check "a single setting is not reported" bash -c '! grep -q "^A" <<< "$1"' _ "$d"
check "the template has no duplicates" test -z "$(conf_duplicates "$REPO/backup.conf.example")"

section "verify-restore.sh: what made a DB dump"
eval "$(sed -n '/^dump_kind() {/,/^}/p' "$REPO/verify-restore.sh")"
big() { yes "INSERT INTO t VALUES (1,'some row to make the dump big');" | head -n 60000; }
{ printf '/*M!999999\\- enable the sandbox mode */ \n-- MariaDB dump 10.19  Distrib 10.11.19-MariaDB, for debian-linux-gnu (x86_64)\n--\n'; big; } | gzip > "$W/mariadb_new.sql.gz"
{ printf -- '-- MySQL dump 10.13  Distrib 8.0.36, for Linux (x86_64)\n--\n-- Host: localhost\n'; big; } | gzip > "$W/mysql.sql.gz"
{ printf -- '--\n-- PostgreSQL database cluster dump\n--\n'; big; } | gzip > "$W/pg.sql.gz"
{ printf 'hello\nnot a dump\n'; big; } | gzip > "$W/junk.sql.gz"
check "MariaDB 10.11.8+ (the sandbox line first, a 2 MB dump)" test "$(dump_kind "$W/mariadb_new.sql.gz")" == mysql
check "MySQL" test "$(dump_kind "$W/mysql.sql.gz")" == mysql
check "PostgreSQL (pg_dumpall)" test "$(dump_kind "$W/pg.sql.gz")" == postgres
check "something else" test "$(dump_kind "$W/junk.sql.gz")" == unknown

section "aws_upload: transient storage errors are retried, parts are cleaned up"
S3_OPTS=(); S3_UPLOAD_RETRY_DELAY=0; echo data > "$W/up.bin"
: > "$W/aws.calls"
# The fake aws: "s3 cp" fails while $W/fails holds a count above 0, with the message in $W/msg
aws() {
    echo "$1 $2 ${*: -1}" >> "$W/aws.calls"
    case "$1 $2" in
        "s3 cp")
            local left; left="$(cat "$W/fails")"
            if (( left > 0 )); then echo $((left - 1)) > "$W/fails"; cat "$W/msg" >&2; return 1; fi ;;
        "s3api list-multipart-uploads")
            echo '{"Uploads":[{"Key":"p/k.tar.gz","UploadId":"U1"},{"Key":"p/k.tar.gz.sha256","UploadId":"U2"}]}' ;;
    esac
    return 0
}
abort_ids() { grep -c '^s3api abort-multipart-upload' "$W/aws.calls"; }
cps() { grep -c '^s3 cp' "$W/aws.calls"; }
echo 'upload failed: An error occurred (OperationAborted) when calling the UploadPart operation: A conflicting conditional operation is currently in progress against this resource. Try again.' > "$W/msg"

echo 1 > "$W/fails"; : > "$W/aws.calls"
aws_upload "$W/up.bin" s3://b/p/k.tar.gz 2> "$W/up.err"; rc=$?
check "OperationAborted once, then fine: success" test "$rc" -eq 0
check "two attempts" test "$(cps)" -eq 2
check "it says it tries again" grep -q 'OperationAborted) — trying again in 0 s (2/3)' "$W/up.err"
check "the unfinished upload of THIS key was aborted (U1), not the other key's (U2)" \
    test "$(grep '^s3api abort-multipart-upload' "$W/aws.calls" | tr '\n' ' ')" == "s3api abort-multipart-upload U1 "

echo 9 > "$W/fails"; : > "$W/aws.calls"
aws_upload "$W/up.bin" s3://b/p/k.tar.gz 2> "$W/up.err"; rc=$?
check "always busy: fails after 3 attempts" test "$rc:$(cps)" == "1:3"
check "and leaves no parts behind (aborted after each try)" test "$(abort_ids)" -eq 3

echo 'An error occurred (AccessDenied) when calling the PutObject operation: Access Denied' > "$W/msg"
echo 1 > "$W/fails"; : > "$W/aws.calls"
aws_upload "$W/up.bin" s3://b/p/k.tar.gz 2> "$W/up.err"; rc=$?
check "AccessDenied is not retried" test "$rc:$(cps)" == "1:1"

# aws_rm: the same fake, "s3 rm" fails while $W/fails is above 0
aws() {
    echo "$1 $2 ${*: -1}" >> "$W/aws.calls"
    if [[ "$1 $2" == "s3 rm" ]]; then
        local left; left="$(cat "$W/fails")"
        if (( left > 0 )); then echo $((left - 1)) > "$W/fails"; cat "$W/msg" >&2; return 1; fi
        echo "delete: ${*: -1}"
    fi
    return 0
}
rms() { grep -c '^s3 rm' "$W/aws.calls"; }
echo 'delete failed: s3://b/p/old.tar.gz An error occurred (OperationAborted) when calling the DeleteObject operation: A conflicting conditional operation is currently in progress against this resource. Try again.' > "$W/msg"
echo 1 > "$W/fails"; : > "$W/aws.calls"
aws_rm s3://b/p/old.tar.gz > "$W/rm.out" 2> "$W/rm.err"; rc=$?
check "aws_rm: OperationAborted once, then deleted" test "$rc:$(rms)" == "0:2"
check "aws_rm: quiet on success" test ! -s "$W/rm.out" -a ! -s "$W/rm.err"
echo 9 > "$W/fails"; : > "$W/aws.calls"
aws_rm s3://b/p/old.tar.gz 2> "$W/rm.err"; rc=$?
check "aws_rm: always busy — fails after 3 attempts" test "$rc:$(rms)" == "1:3"
check "aws_rm: and says why" grep -q 'OperationAborted' "$W/rm.err"
echo 'An error occurred (AccessDenied) when calling the DeleteObject operation: Access Denied' > "$W/msg"
echo 1 > "$W/fails"; : > "$W/aws.calls"
aws_rm s3://b/p/old.tar.gz 2>/dev/null; rc=$?
check "aws_rm: AccessDenied is not retried" test "$rc:$(rms)" == "1:1"
unset -f aws

check "transient: SlowDown" s3_transient "An error occurred (SlowDown) when calling the PutObject operation"
check "transient: connection reset" s3_transient "Connection was closed before we received a valid response"
check "transient: 503" s3_transient "An error occurred (503) when calling the UploadPart operation: Service Unavailable"
if s3_transient "An error occurred (NoSuchBucket) when calling the PutObject operation"; then bad "NoSuchBucket taken as transient"
else ok "not transient: NoSuchBucket"; fi
if s3_transient "An error occurred (SignatureDoesNotMatch) when calling the PutObject operation"; then bad "a bad key taken as transient"
else ok "not transient: SignatureDoesNotMatch"; fi

section "the region is required"
PRIMARY_S3_ACCESS_KEY=k; PRIMARY_S3_SECRET_KEY=s; PRIMARY_S3_ENDPOINT=https://s3.example.com; PRIMARY_S3_BUCKET=b
PRIMARY_S3_REGION=""
if s3_complete primary; then bad "a storage without a region counted as complete"; else ok "no region: not complete"; fi
PRIMARY_S3_REGION=eu-1
check "with a region: complete" s3_complete primary

section "Ctrl+C stops a script (aws-cli catches it and exits with an ordinary error)"
if command -v setsid >/dev/null 2>&1; then
    # The child stands in for aws: it catches SIGINT and exits 1. Ctrl+C reaches the whole process group.
    cat > "$W/int.sh" <<'EOF'
touch "$1/int.conf"; source "$1/int.conf"; source "$2/lib.sh"
( sleep 0.3; kill -INT -$$ ) &
sh -c 'trap "exit 1" INT; sleep 3 & wait'
echo "went on"
EOF
    out="$(setsid bash "$W/int.sh" "$W" "$REPO" 2>&1)"; rc=$?
    check "the script stops (code 130)" test "$rc" -eq 130
    check "and does not go on to the next check" test -z "$out"
else
    ok "SKIP: no setsid"
fi

section "a backup's age, by the calendar"
check "this morning: today" test "$(ts_age "$(date +%F)_00-00-01")" == today
check "late last night, nearly a day ago: 1 day ago" test "$(ts_age "$(date -d yesterday +%F)_23-59-59")" == "1 day ago"
check "early yesterday: 1 day ago" test "$(ts_age "$(date -d yesterday +%F)_00-00-01")" == "1 day ago"
check "a week ago: 7 days ago" test "$(ts_age "$(date -d '7 days ago' +%F)_12-00-00")" == "7 days ago"
check "not a date: code 1" bash -c 'source "$1/lib.sh"; ! ts_age None' _ "$REPO"

section "logs.sh filters (plain awk)"
y="$(date -d yesterday +%Y-%m-%d)"; t="$(date +%Y-%m-%d)"
cat > "$W/b.log" <<EOF
[$y 22:00:01] 🚀 Starting Docker backup. Timestamp: old
delete failed: s3://b/old An error occurred (OperationAborted) when calling the DeleteObject operation
[$y 22:00:02] ⚠ Could not delete backups/old
[$t 00:00:01] 🚀 Starting Docker backup. Timestamp: new
[$t 00:01:00]   📊 Auto-dump: 2 succeeded, 0 failed
tar: ./private/error: socket ignored
upload failed: x to s3://b/new An error occurred (UploadPart)
[$t 00:02:00] ❌   Upload to secondary S3 failed
EOF
printf 'LOG_FILE="%s"\n' "$W/b.log" > "$W/logs.conf"
out="$(bash "$REPO/logs.sh" -c "$W/logs.conf" -b -e -s today 2>&1)"; rc=$?
check "-e -s today runs" test "$rc" -eq 0
check "today's error and the aws text under it" grep -q 'upload failed: x' <<< "$out"
check "not yesterday's" bash -c '! grep -q "backups/old" <<< "$1"' _ "$out"
check "\"0 failed\" and \"socket ignored\" are not errors" bash -c '! grep -qE "0 failed|socket ignored" <<< "$1"' _ "$out"
out="$(bash "$REPO/logs.sh" -c "$W/logs.conf" -b -e -p nothing-like-this 2>&1)"; rc=$?
check "no matches is not a failure" test "$rc" -eq 0

section "helpers"
check "join_list: one line, comma-separated (IFS has a newline here)" test "$(join_list a b 'c d')" == "a, b, c d"
check "join_list: one item" test "$(join_list solo)" == "solo"
check "plural 1" test "$(plural 1 project projects)" == project
check "plural 2" test "$(plural 2 project projects)" == projects
check "html_esc" test "$(html_esc 'a<b>&c')" == 'a&lt;b&gt;&amp;c'
check "html_plain" test "$(html_plain '<b>a&amp;b</b> &lt;x&gt;')" == 'a&b <x>'
check "s3_host" test "$(s3_host https://s3.example.com/path)" == s3.example.com
check "fmt_duration 59" test "$(fmt_duration 59)" == 59s
check "fmt_duration 3725" test "$(fmt_duration 3725)" == "1h 02m 05s"
check "s3_label secondary title" test "$(s3_label secondary title)" == "Secondary S3"

finish
