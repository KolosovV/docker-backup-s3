#!/usr/bin/env bash
# install.sh and update.sh must keep every value of an existing backup.conf — the old S3_* names become
# PRIMARY_S3_*, and nothing else changes. (Encryption silently switched off after a reinstall is the case.)
# install.sh changes the system (/usr/local/bin/docker-backup-s3, logrotate): it runs only in a container or in CI.
if [[ ! -f /.dockerenv && -z "${CI:-}" ]]; then
    echo "   SKIP: install.sh changes the system — runs only in a container or in CI"
    exit 0
fi
if [[ "$EUID" -ne 0 ]]; then
    if sudo -n true 2>/dev/null; then exec sudo -E env "PATH=$PATH" bash "$0" "$@"; fi
    echo "   SKIP: install.sh needs root"
    exit 0
fi
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# An old-style config: the primary storage as S3_*, encryption on, a server name, own exclusions
old_conf() {
    sed -e 's/^PRIMARY_S3_/S3_/' "$REPO/backup.conf.example" > "$1"
    sed -i -e 's|^S3_ACCESS_KEY=.*|S3_ACCESS_KEY="AKIAOLDKEY123"|' \
           -e 's|^S3_SECRET_KEY=.*|S3_SECRET_KEY="old+secret/with=chars"|' \
           -e 's|^S3_ENDPOINT=.*|S3_ENDPOINT="https://s3.old.example"|' \
           -e 's|^S3_BUCKET=.*|S3_BUCKET="old-bucket"|' \
           -e 's|^ENCRYPT_BACKUPS=.*|ENCRYPT_BACKUPS="true"|' \
           -e 's|^NOTIFY_NAME=.*|NOTIFY_NAME="web-1"|' \
           -e 's|^NOTIFY_ON=.*|NOTIFY_ON="always"|' \
           -e "s|^BIND_EXCLUDE_PATHS=.*|BIND_EXCLUDE_PATHS='/srv/files/nobackup'|" \
           -e 's|^RETENTION_DAYS=.*|RETENTION_DAYS=45|' \
           -e 's|^SECONDARY_S3_OPTS_EXTRA=.*|SECONDARY_S3_OPTS_EXTRA="--ca-bundle /etc/ssl/certs/ca-certificates.crt"|' "$1"
}
val() { bash -c 'source "$1" 2>/dev/null; printf "%s" "${!2-}"' _ "$1" "$2"; }
same_values() {   # same_values <conf> <label>
    local c="$1" l="$2"
    check "$l: ENCRYPT_BACKUPS stays true" test "$(val "$c" ENCRYPT_BACKUPS)" == true
    check "$l: NOTIFY_NAME stays" test "$(val "$c" NOTIFY_NAME)" == web-1
    check "$l: NOTIFY_ON stays" test "$(val "$c" NOTIFY_ON)" == always
    check "$l: RETENTION_DAYS stays" test "$(val "$c" RETENTION_DAYS)" == 45
    check "$l: BIND_EXCLUDE_PATHS stays" test "$(val "$c" BIND_EXCLUDE_PATHS)" == /srv/files/nobackup
    check "$l: the secret key, special characters and all" test "$(val "$c" PRIMARY_S3_SECRET_KEY)" == 'old+secret/with=chars'
    check "$l: S3_BUCKET became PRIMARY_S3_BUCKET" test "$(val "$c" PRIMARY_S3_BUCKET)" == old-bucket
    check "$l: no old S3_* names left" bash -c '! grep -qE "^S3_(ACCESS_KEY|SECRET_KEY|ENDPOINT|BUCKET)=" "$1"' _ "$c"
    check "$l: the secondary ca-bundle stays" test "$(val "$c" SECONDARY_S3_OPTS_EXTRA)" == "--ca-bundle /etc/ssl/certs/ca-certificates.crt"
    check "$l: no setting given twice" test -z "$(bash -c 'source "$1" >/dev/null 2>&1; conf_duplicates "$2"' _ "$REPO/lib.sh" "$c")"
}

section "a fresh clone with the old config copied in (install.sh in place)"
T="$W/opt/docker-backup-s3"
mkdir -p "$T"; cp -a "$REPO/." "$T/"; rm -rf "$T/.git"
old_conf "$T/backup.conf"; chmod 600 "$T/backup.conf"
mkdir -p /usr/local/bin; ln -sfn "$T/menu.sh" /usr/local/bin/docker-backup   # the command's name before 1.5.1
if bash "$T/install.sh" -y --skip-deps --no-cron --skip-validate --target "$T" > "$W/install.log" 2>&1; then ok "install.sh exit 0"
else bad "install.sh failed"; tail -n 20 "$W/install.log"; fi
same_values "$T/backup.conf" "install"
check "the command is docker-backup-s3" test "$(readlink /usr/local/bin/docker-backup-s3)" == "$T/menu.sh"
check "the old name docker-backup is gone" test ! -e /usr/local/bin/docker-backup

section "update.sh over an installation with the old config"
U="$W/opt/upd"
mkdir -p "$U"; cp -a "$REPO/." "$U/"; rm -rf "$U/.git"
old_conf "$U/backup.conf"; chmod 600 "$U/backup.conf"
if bash "$REPO/update.sh" -y --skip-validate --target "$U" --source "$REPO" > "$W/update.log" 2>&1; then ok "update.sh exit 0"
else bad "update.sh failed"; tail -n 20 "$W/update.log"; fi
same_values "$U/backup.conf" "update"

section "update.sh in a git clone, after git checkout (the files are in place already)"
G="$W/opt/git"
mkdir -p "$G"; cp -a "$REPO/." "$G/"; rm -rf "$G/.git"; mkdir "$G/.git"
old_conf "$G/backup.conf"; chmod 600 "$G/backup.conf"
rm -f /usr/local/bin/docker-backup-s3; ln -sfn "$G/menu.sh" /usr/local/bin/docker-backup
if bash "$G/update.sh" -y --skip-validate --target "$G" > "$W/upd-git.log" 2>&1; then ok "update.sh exit 0"
else bad "update.sh failed"; tail -n 20 "$W/upd-git.log"; fi
same_values "$G/backup.conf" "in place"
check "the command is docker-backup-s3" test "$(readlink /usr/local/bin/docker-backup-s3)" == "$G/menu.sh"
check "the old name docker-backup is gone" test ! -e /usr/local/bin/docker-backup
check "no backup copy of the folder (git has the history)" bash -c '! ls -d "$1".bak.* >/dev/null 2>&1' _ "$G"
rm -rf "$W/nogit"; mkdir -p "$W/nogit"; cp -a "$REPO/." "$W/nogit/"; rm -rf "$W/nogit/.git"
check "the same folder without git is still refused" bash -c 'bash "$1/update.sh" -y --skip-validate --target "$1" 2>&1 | grep -q "Source and target are the same"' _ "$W/nogit"
rm -f /usr/local/bin/docker-backup-s3

section "install.sh speaks up about a setting given twice and about encryption off"
D="$W/opt/dup"
mkdir -p "$D"; cp -a "$REPO/." "$D/"; rm -rf "$D/.git"
old_conf "$D/backup.conf"
printf 'ENCRYPT_BACKUPS="false"\n' >> "$D/backup.conf"      # the template default lower down wins
touch "$W/pass"; sed -i "s|^GPG_PASSPHRASE_FILE=.*|GPG_PASSPHRASE_FILE=\"$W/pass\"|" "$D/backup.conf"
bash "$D/install.sh" -y --skip-deps --no-cron --skip-validate --target "$D" > "$W/dup.log" 2>&1
check "it says the user's ENCRYPT_BACKUPS is overridden by the default" grep -q 'ENCRYPT_BACKUPS: your "true" (line [0-9]*) is overridden by the default "false"' "$W/dup.log"
check "it warns that encryption is off with a passphrase in place" grep -q 'Encryption is OFF' "$W/dup.log"

section "a new install takes over the settings of an earlier one in /opt/docker-backup"
mkdir -p /opt/docker-backup; old_conf /opt/docker-backup/backup.conf
N="$W/opt/new"; mkdir -p "$N"; cp -a "$REPO/." "$N/"; rm -rf "$N/.git" "$N/backup.conf"
bash "$N/install.sh" -y --skip-deps --no-cron --skip-validate --target "$N" > "$W/new.log" 2>&1
check "it says it took them over" grep -q 'taken over from /opt/docker-backup/backup.conf' "$W/new.log"
check "a copy as it was stays next to it" bash -c 'ls "$1"/backup.conf.imported-* >/dev/null 2>&1' _ "$N"
same_values "$N/backup.conf" "take-over"
rm -rf /opt/docker-backup

section "uninstall.sh keeps a copy, and a reinstall takes it over"
rm -f /root/docker-backup.conf.saved-*
bash "$N/uninstall.sh" -y --target "$N" > "$W/uninst.log" 2>&1
saved="$(ls -t /root/docker-backup.conf.saved-* 2>/dev/null | head -n 1)"
check "the installation is removed" test ! -e "$N/docker-backup.sh"
check "a copy of backup.conf is in /root ($saved)" test -f "$saved"
check "the copy is mode 600" test "$(stat -c %a "$saved" 2>/dev/null)" == 600
R="$W/opt/again"; mkdir -p "$R"; cp -a "$REPO/." "$R/"; rm -rf "$R/.git" "$R/backup.conf"
bash "$R/install.sh" -y --skip-deps --no-cron --skip-validate --target "$R" > "$W/again.log" 2>&1
check "the reinstall takes the saved copy over" grep -q "taken over from $saved" "$W/again.log"
same_values "$R/backup.conf" "reinstall"
rm -f /root/docker-backup.conf.saved-*

section "the wizard (a fresh install, answered prompt by prompt)"
# wizard_run <dir> <answers…> — install.sh without -y, plain prompts, answers from a file
wizard_run() {
    local d="$1"; shift
    mkdir -p "$d"; cp -a "$REPO/." "$d/"; rm -rf "$d/.git" "$d/backup.conf"
    printf '%s\n' "$@" > "$W/answers"
    UI_PLAIN=true UI_TTY="$W/answers" bash "$d/install.sh" --skip-deps --no-cron --skip-validate --target "$d" > "$W/wizard.log" 2>&1
}
#  continue?, access, secret, endpoint, region, bucket, addressing, secondary?, tertiary?, prefix, retention, scan dirs,
#  encrypt?, server name, telegram?, webhook?, email?, logrotate?
answers=(y AKIAWIZARD123 wizard-secret https://s3.wizard.example "" wiz-bucket path n n "" "" "" y web-7 n n n y)
PASS_FILE=/root/.docker-backup-passphrase
had_pass=false; [[ -f "$PASS_FILE" ]] && { had_pass=true; cp -p "$PASS_FILE" "$W/pass.keep"; }

echo "an existing passphrase" > "$PASS_FILE"; chmod 600 "$PASS_FILE"
wizard_run "$W/opt/wiz1" "${answers[@]}"
c="$W/opt/wiz1/backup.conf"
check "a passphrase on the server: the wizard says it is there" grep -q "A passphrase file is already here" "$W/wizard.log"
check "ENCRYPT_BACKUPS=true written" test "$(val "$c" ENCRYPT_BACKUPS)" == true
check "GPG_PASSPHRASE_FILE written" test "$(val "$c" GPG_PASSPHRASE_FILE)" == "$PASS_FILE"
check "the passphrase itself untouched" grep -qx 'an existing passphrase' "$PASS_FILE"
check "the server name written" test "$(val "$c" NOTIFY_NAME)" == web-7
check "the storage written" test "$(val "$c" PRIMARY_S3_BUCKET)" == wiz-bucket

rm -f "$PASS_FILE"
wizard_run "$W/opt/wiz2" "${answers[@]}"
c="$W/opt/wiz2/backup.conf"
check "no passphrase: the wizard warns what it means" grep -q "Without the passphrase the backups cannot be restored" "$W/wizard.log"
check "and does: mode 600, not empty" test "$(stat -c %a "$PASS_FILE" 2>/dev/null)" == 600 -a -s "$PASS_FILE"
check "it says to copy it off the server" grep -q 'copy it off the server' "$W/wizard.log"
check "ENCRYPT_BACKUPS=true written" test "$(val "$c" ENCRYPT_BACKUPS)" == true

rm -f "$PASS_FILE"; $had_pass && cp -p "$W/pass.keep" "$PASS_FILE"
rm -f /usr/local/bin/docker-backup-s3 /etc/logrotate.d/docker-backup
finish
