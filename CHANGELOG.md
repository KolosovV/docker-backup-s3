# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/): a new **major** version means an action is needed
on update (a config change that `update.sh` can't do for you), **minor** — new features,
**patch** — fixes.

The installed version: `docker-backup-s3 version` (or the `VERSION` file).

## [Unreleased]

### Changed — action needed
- **The command is `docker-backup-s3`**: `sudo docker-backup-s3`, `sudo docker-backup-s3 backup -p app`.
  `update.sh` and `install.sh` link it and remove the old name. The scripts' file names, the logs
  (`/var/log/docker-backup*.log`), `WORK_DIR` and the schedule stay as they are.
- **The label is `docker-backup-s3.skip=true`.** `update.sh` lists the containers that still carry the old one:
  rename it in their compose file or `docker run`, and recreate them.

### Added
- **Projects to leave out.** `EXCLUDE_PROJECTS` — not backed up at all; their backups already in the storages stay
  (rotation keeps their last copies, it does not take them for projects gone from the server), and `-p NAME` still
  backs one up. `DB_DUMP_EXCLUDE_PROJECTS` — backed up without database dumps. Both take names or globs (`test-*`);
  the menu has a new section, **Projects**, to tick them in a list. The dry run shows both.
- The label `docker-backup-s3.skip=true` on a database container in a compose project turns off its dump (before,
  the label worked only for containers started without compose).
- **Remote databases** — Postgres, MySQL, MariaDB, MongoDB and Redis that are not containers on this host (a managed
  service, another server): `REMOTE_DBS` and `REMOTE_DB_<NAME>_*` in `backup.conf`, or the menu's new section
  **Remote databases**, which checks the login at once. A throwaway client container dumps each one, and the dump
  goes straight into the primary storage through a pipe (gzip, gpg, upload), then from the primary into the copies:
  nothing is written to this disk, so the size of the database does not matter here. A dump that fails half-way
  leaves no object behind; a transient storage error starts it again. Each one is the project `_db_<name>` in the
  storages: rotation, sync and `status.sh` handle it, `-p db:NAME` backs up one, `verify-restore.sh` streams it back
  and checks it, `docker-restore.sh` saves it and prints the command to load it. `validate-config.sh` logs in to
  each. The password reaches the client through its environment or stdin, never its command line.

### Security
- **Database passwords no longer go on a command line.** `docker exec -e PGPASSWORD=…`, `-e MYSQL_PWD=…`,
  `redis-cli -a …` and `mongodump --password …` put them in the arguments of a process, where any user of the
  host sees them (`ps aux`) while a dump runs. Now each dump runs a short `sh` script inside the database
  container that reads the password there, from the image's own variables, and hands it to the tool in its
  environment or on its stdin. The password is not even copied to the host. A Redis password that exists only
  as `--requirepass` in the container's command reaches `docker exec` through the environment.
- The Telegram bot token and the webhook URL (Discord and Slack keep their secret in it) went to `curl` as an
  argument; the menu's test of a channel passed the token and the SMTP password to `env` as arguments, and the
  storage check passed the S3 keys the same way. They now go through a curl config on a pipe and the
  environment.
- A run's working folder (`WORK_DIR/<time>`: archives with `.env` files, `docker inspect` with the containers'
  environment, dumps) was readable by every user of the host while the backup ran. It is now `700`, and
  everything in it `600`.
- `verify-restore.sh` decrypted into `/tmp/verify-restore-<PID>`: a predictable name that another user could
  create in advance, and the decrypted data would land in their folder. It now uses a private folder with a
  random name in `WORK_DIR`.
- `validate-config.sh` showed the first and last four characters of the S3 secret key; now only its length.
- README: a new section, [Where your keys and passwords live](README.md#where-your-keys-and-passwords-live) — what
  leaves the server and where to (only your storages and your notification channels; no telemetry), where each
  secret is kept and who can read it.

### Fixed
- **A Telegram message lost to one network hiccup.** With no answer from api.telegram.org (a timeout, a dropped
  connection) it is now sent again after 5 and then 15 seconds; a refusal from Telegram is not retried.
- **`update.sh` in a git clone.** Installed with `git clone` and switched with `git checkout`, the installation is
  its own source, and `update.sh` refused to run: so the new `docker-backup-s3` command was not linked and the old
  label was not looked for. Now it copies nothing there and does the rest (the command, the config's old names,
  the old label, the options you don't set, `validate-config.sh`). README: after `git checkout`, run `update.sh`.
- **Database dumps, checked on real servers** (a new test, `tests/databases/run.sh`: 3 Postgres, 3 MySQL, 2 MariaDB,
  Redis 6 and 7, Valkey, KeyDB, 3 MongoDB):
  - `*_FILE` secrets (`POSTGRES_PASSWORD_FILE`, `MARIADB_ROOT_PASSWORD_FILE`, `MONGO_INITDB_ROOT_PASSWORD_FILE`…)
    were not read, and such a database was dumped without a password, or not at all.
  - MySQL/MariaDB with a random root password (`MYSQL_RANDOM_ROOT_PASSWORD`) failed: the app user's password was
    tried as root's. Now each account is tried with a login first — root, then the app user (its database), then
    root without a password — and the log says which one made the dump. Events are dumped too (`--events`).
  - A Redis password from a config file (`redis-server /etc/redis.conf` with `requirepass`), a port other than
    6379, Valkey (`valkey/valkey` was not recognised at all) and `valkey-cli` / `keydb-cli` are handled. A password
    variable the server does not use no longer breaks the dump: no password is tried first. BGSAVE now waits for
    the save to finish rather than for the save time to change (two saves within one second waited for the whole
    timeout), and a failed save is reported.
  - Percona Server for MongoDB was taken for MySQL.
  - An exporter or an admin UI whose image name matched (`postgres-exporter`, `redis_exporter`, `mongo-express`)
    counted as a failed dump. It is skipped now, with a note: the container must run the database server.
  - A failed dump said only "pg_dumpall failed": the tool's own error was thrown away. The log now has the
    reason (`Access denied for user…`, `WRONGPASS…`, a timeout).
  - The MongoDB dump was named `.tar.gz` although it is a mongodump archive; it is `.archive.gz` now (old ones
    are removed with the first new dump), and `verify-restore.sh` checks the archive's magic number.
  - `verify-restore.sh` stopped the whole check on a Redis dump bigger than 64 KB (a SIGPIPE under `pipefail`),
    and took a Valkey 9 RDB for a broken one.
- README: restoring Redis by `docker cp` into a running server lost the restored data — Redis saves its memory
  over the file on shutdown. The instructions now stop it first; the MySQL instruction no longer puts the password
  on the command line; MongoDB has one.

- **`logs.sh --since` failed on Debian and Ubuntu** ("awk: … must contain complete functions or rules"): it was
  written for gawk, and they ship mawk. It now compares the log's timestamps as text in plain awk (no `date` call
  per line), and a line without a timestamp (aws's own error text) goes with the line before it. `--since today`
  means from midnight: it used to mean "from now" and showed nothing.
- **`logs.sh --errors` showed lines that are not errors:** "Auto-dump: 2 succeeded, 0 failed" and tar's "socket
  ignored" for a path with "error" in it. It now matches our ❌/⚠ lines and what aws prints on a failure. No
  match is no longer an error exit.
- **Deleting old backups was not retried** on a storage's transient error (`OperationAborted` on `DeleteObject`):
  the backup stayed until the next run. Deletes are now retried like uploads (`S3_UPLOAD_TRIES`), in the rotation,
  `sync-s3.sh --prune` and `drop-project.sh`.
- tar no longer logs "socket ignored": a socket cannot be archived, and the program recreates it on start.
- The menu showed the command it runs one word per line. The same slip — a list joined with the scripts' newline
  `IFS` — split the installer's "Installing: …", the run summary's "Errors: N (project, project)" and the
  restore's project lists over several lines. Lists are now joined on one line everywhere.
- The installer printed the package manager's whole output (pages of dpkg); it now shows it only when it fails.
- aws's "upload: <file> to <url>" after every successful upload and a progress line per chunk on a download no
  longer fill the log (`verify-restore.sh` from cron wrote hundreds of them into one line). Errors still show,
  and a download on a terminal still shows its progress.
- `docker-restore.sh` without a terminal (cron, a pipe) asked "Where to restore from?" and died on `/dev/tty`:
  `--list` now reads the primary, and a question that needs an answer says which option gives it (`-p`, `-t`,
  `-y`). "0 days ago" reads "today", "1 backups" reads "1 backup".
- `status.sh` counted each backup twice (the archive and its `.sha256`), read the latest log lines from
  `/var/log/docker-backup.log` even when `LOG_FILE` points elsewhere, and its tables were misaligned.
- `diagnose-s3.sh` ignored `-c` and `--help`; `diagnose-cron.sh` ran its checks on `--help`, printed stray "?"
  lines, and took itself for a running cron process.
- `drop-project.sh --help` ended with a stray rule and did not mention `-c`.
- MariaDB is called MariaDB in the log (it said "Mariadb"), PostgreSQL — PostgreSQL. The dry run's database lines
  carry a timestamp like the rest. `validate-config.sh` lists a folder once when the log and the lock share it.
- The boxes around the installer's, the updater's, the uninstaller's and `status.sh`'s titles were one column
  too wide: an emoji takes two.

### Changed
- Menus and lists get wider when a line needs it (a long endpoint), up to the terminal's width; the storage list
  no longer repeats the storage's name after its tag (in whiptail, where the tag is shown).
- The menu and the installer look the same on every distribution: classic blue whiptail. Ubuntu's own palette
  made them magenta. A palette of your own (`NEWT_COLORS`, `NEWT_COLORS_FILE`) is kept.

## [1.5.0] — 2026-10-22

Encryption must never end up off without a word. On a server set up again from scratch, `install.sh` built
`backup.conf` from the template and its questions never touched encryption. Backups were then made unencrypted,
although the passphrase file was right there.

### Added
- **The installer asks about encryption.** If `/root/.docker-backup-passphrase` already exists, the default is to
  encrypt with it. If it does not, the installer offers to generate one and tells you to copy it off the server.
  It also asks for the server's name in notifications (`NOTIFY_NAME`).
- **A loud warning when the passphrase file exists but `ENCRYPT_BACKUPS` is not "true"**: in `validate-config.sh`,
  in `install.sh`, in the backup log, and in every backup notification. The notification then comes as
  "backup done, but check the settings" (🟠), so it reaches `NOTIFY_ON=error` too.
- **A setting of yours overridden by a template default further down** in `backup.conf` (a variable given twice;
  bash uses the last line) is reported the same way: `ENCRYPT_BACKUPS: your "true" (line 12) is overridden by the
  default "false" further down (line 290)`. In `validate-config.sh` it is an error. A value appended at the end on
  purpose is noted, not flagged.
- **`install.sh` offers to take over the settings of an earlier installation**: `/opt/docker-backup/backup.conf`,
  or the copy `uninstall.sh` leaves. A copy as it was stays next to it as `backup.conf.imported-<time>`.
- `tests/test_install.sh`: install and update keep every value of an existing config (old `S3_*` names included),
  the take-over, uninstall and reinstall, and the warnings. The integration test makes a real backup with
  encryption switched off by a second line and checks the warning.

### Fixed
- **An interrupted backup was silent.** Ctrl+C (or a kill) during the checks before the first project left no
  trace: nothing in the log, no notification. The log pipe died with the signal, and notifications were sent only
  for runs that had started. Now the log says "Backup interrupted (signal INT) at: <the step>" and an error
  notification goes out at any stage ("nothing was saved in this run" before the first project). HUP is handled
  too, and the run's half-made work folder is removed. The log pipe now runs in its own session: under bash 5.3
  (Arch) Ctrl+C killed it despite `trap ''`, and the handler died on its first write, with exit code 1.
- **A storage's transient error failed the whole upload.** A storage answered a 1.4 GB upload with `OperationAborted`
  ("a conflicting conditional operation is currently in progress … Try again"). aws's own retries are per request
  and do not cover that, so the project failed, and with a required copy the run did too. Now a whole file upload
  is retried on transient errors (OperationAborted, SlowDown, InternalError, RequestTimeout, 5xx, a broken
  connection), up to `S3_UPLOAD_TRIES` (3) with growing pauses, and the log says "trying again in 15 s (2/3)".
  Wrong keys or a missing bucket are not retried. The same applies to the primary, the copies and `sync-s3.sh`.
  The unfinished multipart upload of that file is aborted before each retry and after a final failure, so no
  billed parts are left behind.
- **A false "doesn't look like mysqldump" on every MariaDB dump** in `verify-restore.sh`. MariaDB 10.11.8+/11.x
  dumps start with a sandbox line before "-- MariaDB dump", which the check did not accept. Also, on a big dump the
  header was read through a pipeline that failed under `pipefail`. A false warning on every run trains people to
  ignore the real one.

- **`BACKUP_MODE=stop` stopped and started the project through `cd <folder> && docker compose stop`.** That acts on a
  project named after the folder, so a project started under another name (`-p`, `name:`) was not stopped. Now
  the project's running containers are found by its label (as `pause` always did), and exactly those are started
  again.
- **After a restore in place the project was started without its name.** A project not named after its folder
  came up as a new project on empty volumes, next to its restored ones. It is now started with its own name
  (`-p`) and the compose file that was found (`-f`).

- **No SQL dump of MariaDB 11.** Its images have no `mysqldump`, so the auto-dump failed, and only the raw volume
  went into the backup. The dump now runs `mariadb-dump` where the image has it, and `mysqldump` otherwise. The
  integration test now has a MariaDB 11 database next to Postgres.
- **A copy with an empty region silently used the primary's.** Requests are signed for the region, and a storage
  of another provider may reject that one. The region is now required for every enabled storage: the menu asks
  for it, `validate-config.sh` reports an empty one as an error, and a storage without it does not count as set
  up. Install and update write the primary's region into an enabled copy that had none (what it used before),
  keep a copy of the config and say so — check that it is right for that storage.

### Changed
- The error notification after a run is titled "backup with errors" (it was "nightly backup with errors"), and the
  docs and the menu say "scheduled" rather than "nightly": the schedule is yours.
- **Docker Compose v2 only.** The fallback to the standalone `docker-compose` v1, which Docker ended in 2023, is
  removed: it was never tested. `install.sh` and `validate-config.sh` check that the `docker compose` plugin is
  there.
- `uninstall.sh` always keeps a copy of `backup.conf` as `/root/docker-backup.conf.saved-<time>` (mode 600) and
  does not remove the installation if it cannot save it. `--keep-conf` is gone; it is what always happens now.

## [1.4.4] — 2026-10-22

### Fixed
- With `S3_BANDWIDTH_LIMIT` set, AWS CLI 2.3x warned on every upload that its new 'crt' transfer client does not
  support `max_bandwidth`, and that a future version would use 'crt' by default and ignore the limit. The
  'classic' client is now pinned for every run. The limit keeps working after aws updates, uploads to
  S3-compatible storages go the same, tested way, and the warning is gone.

## [1.4.3] — 2026-10-22

### Fixed
- **Restoring a bind mount wiped its `BIND_EXCLUDE_PATHS`.** The restore deleted the whole folder and unpacked the
  backup, so excluded subfolders (which are not in the backup) were lost. The folder was also deleted itself, which
  fails, or empties a disk, when it is a mount point. Now the folder stays, only its contents are cleared, and the
  excluded subfolders are left as they are.

### Added
- The dry-run plan shows exclusions inside a bind mount: `/srv/files (without /srv/files/nobackup)`.

## [1.4.2] — 2026-10-22

### Fixed
- `validate-config.sh` sent its own bare Telegram test ("🧪 validate-config test from host [time]"). It now sends the
  same test message, in the same look, as the menu and the installer.
- Notification texts reworded: "Saved 7 projects in both storages." with the size, time and timestamp on the next
  line; "some of its SECONDARY_S3_* settings in backup.conf are empty" in place of "not all … are filled in in
  backup.conf"; "Checked 3 of 3 projects (quick mode) in 2m 10s."
- In the dry-run plan the database lines came before their "Database auto-dump:" heading and did not reach the log
  (they went to stdout).
- `validate-config.sh` warns about a `SCAN_DIRS` folder inside another one of the list. That is usually an
  exclusion typed in the wrong place, and the warning says where exclusions go (`BIND_BLACKLIST_REGEX`,
  `BIND_EXCLUDE_PATHS`). `install.sh` now says plainly that `SCAN_DIRS` is where to look for projects.

## [1.4.1] — 2026-10-22

### Fixed
- The test message sent from the menu (and from `install.sh`) said "Sent by _" in place of the program's name.
- Emails now come from "docker-backup-s3", the project's name. They used to come from "docker-backup".

## [1.4.0] — 2026-10-21

### Fixed
- **A restore reported success when volumes did not come back.** If a volume (or a bind mount, or an image) failed
  to unpack, the restore logged the error, started the project anyway and ended with "restored successfully",
  exit code 0. Postgres then came up on an empty volume with a new empty database. Now any part that does not come
  back fails the project's restore, and the project is not started. The same applies when `docker compose up`
  fails after the data is back. Volume archives are now unpacked with an explicit `gzip -dc | tar -x`, because
  busybox `tar -z` failed under emulation (an aarch64 helper image on an x86 host).
- **Restoring volumes failed with Docker from snap** (and rootless or remote Docker). The restore downloaded and
  unpacked the archive in `/tmp` and mounted volume archives from there into a helper container, but snap's Docker
  has its own `/tmp`, so the container saw an empty folder. The restore now works in `WORK_DIR`
  (`/var/tmp/docker-backup`), as the backup always has.
- **Under systemd the end of the log was lost.** Log lines go through a filter (`grep`), which held them in a
  buffer. When the service ended, systemd killed what was left of it, and the run's last lines (the summary) never
  reached `/var/log/docker-backup.log` or the service log. Lines are now passed on one at a time, and the script
  waits for the log to be written before it exits.
- **The systemd service wrote no log on RHEL/AlmaLinux/Rocky 8** (systemd 239 has no `StandardOutput=append:`).
  The service now writes its log through the shell. If you already use the systemd timer, run
  `setup-cron.sh -m systemd -y` once to rewrite the unit.
- `setup-cron.sh` could not start the cron service on systemd 239: `systemctl list-unit-files` answers "found" there
  even for a unit that does not exist, so a wrong name was picked.
- `install.sh` failed on a freshly booted machine when the package manager was busy (unattended-upgrades on Ubuntu,
  dnf-makecache on Fedora/RHEL). apt now waits for its lock, and the others are retried for up to 2 minutes.
  `setup-cron.sh` says plainly that `crontab` is missing instead of failing with "command not found".
- `uninstall.sh -y` during a running backup removed nothing (correctly) but exited 0, so a script calling it took
  it for done. It now exits 1.
- The logo was unreadable on GitHub's light theme when the system theme was dark. There is now one logo, readable
  on both.

### Added
- `BACKUP_STANDALONE=false` leaves containers started without compose out of the backup, and the label
  `docker-backup.skip=true` leaves out a single one (`docker run --label docker-backup.skip=true …`).
- Scheduling is tested on a real init. On the CI VM and in containers where systemd is PID 1 (Debian, Ubuntu,
  Rocky 9, AlmaLinux 8, Fedora, openSUSE, Arch), the test runs `install.sh`, then checks that the cron service is
  active and enabled and that the timer is enabled with a next run. The service itself makes a real backup, cron
  starts one on its own, and everything is removed at the end (`tests/systemd/`).
- aarch64 is tested under QEMU: Debian 12, Ubuntu 24.04, Rocky 9 and Alpine get the install, the tests and the
  integration test (`DBT_PLATFORM=linux/arm64 tests/distros/run.sh`).
- CI: every push runs ShellCheck, the tests, the integration test and the real-VM test. Release tags, a weekly run
  and manual runs also run the distributions, systemd and aarch64.

## [1.3.0] — 2026-10-21

Tested on 11 Linux distributions. On each one CI now runs `install.sh -y` on a fresh system, then the tests and
the full integration test: Debian 12 and 13, Ubuntu 22.04 and 24.04, Rocky Linux 9, AlmaLinux 8, Fedora 41,
Amazon Linux 2023, openSUSE Leap 15.6, Arch Linux and Alpine 3.20.

### Fixed
- **`hostname` is not installed on minimal Fedora, Arch, Amazon Linux and openSUSE.** On those systems
  notifications had an empty server name (and an error mixed into the message), `install.sh` stopped halfway, and
  the server names in the menu and in `status.sh` were empty. The scripts now use `uname -n`, which is always there.
- **`install.sh` stopped on systems without logrotate** (Fedora, Arch) before it created the `docker-backup`
  command. It now installs logrotate, and it skips log rotation with a warning when logrotate cannot be installed.
  `setup-cron.sh` does the same.
- **Encryption failed on Amazon Linux 2023:** its `gnupg2-minimal` has no `gpg-agent`. The installer now replaces it
  with the full `gnupg2`. `validate-config.sh` now encrypts and decrypts a test file for real, so a gpg that is
  installed but cannot work shows up before the night's backup.
- **Alpine:** the official AWS CLI was installed but could not run (it needs glibc). The musl check did not work
  without `ldd`. Now it works, and the installer checks that the installed aws actually runs. On Alpine aws comes
  from the `aws-cli` package (v2), and so do GNU `tar`, `date`, `stat` and `grep`, in place of busybox ones that lack
  options the scripts use. `crond` is enabled through OpenRC.
- **AWS CLI v2 from the distro package** is tried when the official installer cannot be used: `aws-cli` on Alpine,
  `aws-cli-v2` on Arch, `awscli2` on Fedora. Before, the next step was straight to snap.
- `install.sh` installs only what is missing, and one package at a time if the whole list fails. On RHEL 9 one
  conflict (curl with curl-minimal) used to fail the whole list.
- `whiptail` is now installed (`newt`, `libnewt`): before, the dialogs fell back to plain prompts on most systems
  other than Debian and Ubuntu.
- `setup-cron.sh --remove` failed in containers and on hosts without systemd as init: it found a systemd timer that
  was not there. It now checks for the unit file.
- `update.sh` no longer needs `cmp` (no diffutils on minimal Rocky and Fedora).

## [1.2.1] — 2026-10-21

### Fixed
- **`sync-s3.sh` took aws warnings for object names.** The object listing was read together with aws's stderr, so
  any warning aws printed became a "key" that sync tried to copy and failed on, and the sync ended with an error.
  This happened on every run on systems where aws prints such warnings (Alpine, for one). Now the listing ignores
  stderr, and stderr is read only to explain a listing error.
- The template no longer has `export PYTHONWARNINGS="ignore::urllib3…"`. It was the source of those warnings on such
  systems, and it never helped: the warning it muted appears only with `--no-verify-ssl`, which the project does
  not use. Remove the line from your `backup.conf` too.

### Added
- An integration test (`tests/integration/run.sh`, also in CI) on real Docker and S3: backup → contents →
  verify-restore → sync → wipe the project → restore from the secondary → compare the data, plus a run with S3 down.
  It also checks the notification of each step.

## [1.2.0] — 2026-10-21

### Added
- **Notifications in the menu**: `docker-backup` → Notifications. There you set when to notify and the server name
  in messages, set up, test or turn off Telegram, the webhook and email, or send a test message to every channel.
  The wizards are shared with `install.sh`, and each one checks the settings with a test message.
- Tests in `tests/` (`tests/run.sh`) need no Docker, S3 or network. GitHub Actions runs them on every push
  together with ShellCheck, and the README has a CI badge.

### Fixed
- `install.sh -y` passed the schedule options to `setup-cron.sh` as one argument, so scheduled runs were not
  set up.

### Removed
- `status.sh --detailed`, which did nothing.

## [1.1.0] — 2026-10-21

### Added
- **Email notifications** over your own SMTP server (`EMAIL_TO`, `SMTP_HOST`, `SMTP_SECURITY`
  starttls/tls/none, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `SMTP_FROM`). curl sends them, so the host needs
  no mail server. The subject is the notification line, and the body has a plain-text and an HTML part. The
  password goes to curl in a temporary file, not on the command line.
- `NOTIFY_WEBHOOK_FORMAT`: `discord`, `slack` (also Mattermost, Rocket.Chat) or `json` (`text`, `level`, `server`,
  `title`, `details`, `time`). `auto` (the default) picks it from the URL.
- `install.sh` asks for the webhook and email settings and sends a test message right away.
  `validate-config.sh` also sends a test message to the webhook and by email.

### Changed
- The default installation folder is `/opt/docker-backup-s3` (it was `/opt/docker-backup`), the same as the
  repository name.
- Bash completion is removed: the `docker-backup` menu and `docker-backup help` list every command.

### Fixed
- **Discord webhooks received nothing.** They were sent `{"text"}`, which Discord rejects.
- A webhook that answered with an HTTP error counted as sent. Now any reply other than 2xx is logged as a
  failure.
- A Telegram message over 4096 characters (a long list of failed projects) was lost. Now it is sent as plain
  text, cut at a whole line.
- A value with `"`, `$`, `` ` `` or `\` (a password, say) written by the installer or the menu broke `backup.conf`,
  which bash reads. Such values are now written in single quotes.
- The unused `export AWS_S3_ADDRESSING_STYLE` line is removed from the template.

## [1.0.1] — 2026-10-21

A code review pass: two data-safety bugs and a few smaller ones.

### Fixed
- **Bind mounts next to the project folder were not backed up.** A bind such as `/opt/app-data` of a
  project in `/opt/app` was taken for a part of the project folder (a plain string-prefix test) and went
  into no archive at all. Now only paths that really lie inside the folder are skipped — in the backup,
  the dry-run plan and the restore.
- **A failed volume restore could destroy the only good copy.** If copying the verified data into the
  working volume failed after it had been emptied, the temporary volume with that data was removed too.
  Now it is kept, and the restore prints its name and the command to finish the copy.
- `DRY_RUN=true` from the environment now works as `--help` says; before, it was ignored and a real
  backup (with rotation) ran.
- `BIND_EXCLUDE_PATHS` with several space-separated paths excluded nothing.
- Bind mounts of standalone containers could not be matched to their paths on restore.
- The restored project is started with the `docker compose` / `docker-compose` wrapper, so hosts with
  Compose v1 work too.
- `verify-restore.sh` no longer mistakes gpg warnings for the decrypted file name.
- The standalone-containers archive now has a `sha256` manifest like every project archive, and a
  failure to pack it is reported.
- `COMPRESS_LEVEL` now applies to every archive, not only to saved images.
- The dialogs' notes file is created with `mktemp` instead of a predictable `/tmp` name.
- `setup-cron.sh --remove` also removes its `SHELL`/`PATH`/`MAILTO` block, and neither it nor
  `uninstall.sh` stops halfway (or reports a false error) when the crontab held only this job.
- Encryption and decryption failures are reported as such instead of a later upload/unpack error.

## [1.0.0] — 2026-10-21

The first public release.

### Backup
- Auto-discovery of Docker Compose projects (labels and directory scanning) and standalone containers.
- Named volumes, bind mounts and the whole project folder in one archive per project;
  nested compose projects are excluded from the outer one.
- Automatic database dumps before the backup: PostgreSQL, MySQL/MariaDB, Redis, MongoDB;
  `pre-backup-hook.sh` for anything else.
- Up to three S3-compatible storages — primary, secondary, tertiary — each copy optional or required.
- Integrity: size via `head-object` plus a `sha256` manifest next to every archive;
  completeness control — a missing volume or bind mount fails the project.
- Rotation by age or GFS (day/week/month) with a `KEEP_MIN_BACKUPS` floor; abandoned
  multipart uploads are aborted nightly.
- Optional GPG encryption, bandwidth limit, hot/pause/stop modes, Telegram and webhook notifications.

### Restore and maintenance
- `docker-restore.sh` from any storage: full, into another folder, a single volume, extract only, contents.
- `sync-s3.sh` aligns the copies with the primary (or the primary with a copy, for disaster recovery).
- `verify-restore.sh`, `status.sh`, `logs.sh`, `validate-config.sh`, `diagnose-s3.sh`, `drop-project.sh`.

### Installation and the menu
- `install.sh` with whiptail dialogs: dependencies, the official AWS CLI v2 installer (snap only as a
  fallback), a bucket and certificate check (`--ca-bundle` is set only when it is needed), scheduled runs.
- `update.sh` with a backup copy, `--rollback` and config migration (`S3_*` → `PRIMARY_S3_*`).
- The `docker-backup` command: a menu for everything above, plus subcommands for scripts.

[1.5.0]: https://github.com/KolosovV/docker-backup-s3/releases/tag/v1.5.0
[1.4.4]: https://github.com/KolosovV/docker-backup-s3/releases/tag/v1.4.4
[1.4.3]: https://github.com/KolosovV/docker-backup-s3/releases/tag/v1.4.3
[1.4.2]: https://github.com/KolosovV/docker-backup-s3/releases/tag/v1.4.2
[1.4.1]: https://github.com/KolosovV/docker-backup-s3/releases/tag/v1.4.1
[1.4.0]: https://github.com/KolosovV/docker-backup-s3/releases/tag/v1.4.0
[1.3.0]: https://github.com/KolosovV/docker-backup-s3/releases/tag/v1.3.0
[1.2.1]: https://github.com/KolosovV/docker-backup-s3/releases/tag/v1.2.1
[1.2.0]: https://github.com/KolosovV/docker-backup-s3/releases/tag/v1.2.0
[1.1.0]: https://github.com/KolosovV/docker-backup-s3/releases/tag/v1.1.0
[1.0.1]: https://github.com/KolosovV/docker-backup-s3/releases/tag/v1.0.1
[1.0.0]: https://github.com/KolosovV/docker-backup-s3/releases/tag/v1.0.0
