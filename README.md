<p align="center">
  <img src="assets/logo.svg" alt="docker-backup-s3" width="460">
</p>

<p align="center">
  <b>Back up Docker Compose projects — volumes, bind mounts and database dumps — to up to three S3-compatible storages.</b><br>
  Rotation, integrity checks, restore from any copy, and a menu for all of it. Plain Bash, no agents, no daemons.
</p>

<p align="center">
  <a href="https://github.com/KolosovV/docker-backup-s3/actions/workflows/ci.yml"><img src="https://github.com/KolosovV/docker-backup-s3/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="CHANGELOG.md"><img src="https://img.shields.io/badge/version-2.0.0-2496ED" alt="version 2.0.0"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-22C55E" alt="license MIT"></a>
  <img src="https://img.shields.io/badge/bash-4.4%2B-4EAA25?logo=gnubash&logoColor=white" alt="bash 4.4+">
  <img src="https://img.shields.io/badge/platform-Linux%20%C2%B7%20x86__64%20%7C%20arm64-FCC624?logo=linux&logoColor=black" alt="Linux · x86_64 | arm64">
  <img src="https://img.shields.io/badge/Docker%20Compose-v2-2496ED?logo=docker&logoColor=white" alt="Docker Compose v2">
  <img src="https://img.shields.io/badge/storage-S3--compatible-0EA5A4?logo=amazons3&logoColor=white" alt="S3-compatible">
</p>

<p align="center">
  <a href="#quick-start">Quick start</a> ·
  <a href="#the-docker-backup-s3-command-menu">The menu</a> ·
  <a href="#configuration">Configuration</a> ·
  <a href="#multiple-storages-primary--secondary--tertiary">Multiple storages</a> ·
  <a href="#restoring-from-a-backup">Restore</a> ·
  <a href="#troubleshooting">Troubleshooting</a> ·
  <a href="CHANGELOG.md">Changelog</a>
</p>

---

On the schedule you set (cron or a systemd timer: daily, several times a day, weekdays, your own time), each
compose project on the server becomes one archive: its named volumes, bind mounts,
project folder and fresh database dumps (PostgreSQL, MySQL/MariaDB, Redis, MongoDB — found automatically).
The archive goes to the **primary** storage first, then to an optional **secondary** and **tertiary** one —
for example, at other providers — and each upload is checked by size and `sha256`. Endpoints, regions, keys
and buckets are set by you, so any S3-compatible storage works.

> 🔒 **Your keys and passwords stay with you.** No server of ours, no account, no telemetry: the scripts talk
> only to your storages and the notification channels you set. S3 keys, tokens and database passwords are
> never put on a command line, in the log or in a notification; database passwords are not even copied out
> of their containers. [Where everything lives →](#where-your-keys-and-passwords-live)

```bash
sudo git clone https://github.com/KolosovV/docker-backup-s3.git /opt/docker-backup-s3
sudo /opt/docker-backup-s3/install.sh      # dependencies, storages, notifications, schedule — in dialogs
sudo docker-backup-s3                      # the menu: status, backup, restore, checks, storages
```

## Features

### Backup
- 📦 **Compose project auto-discovery** — via docker labels and directory scanning
- 🗄️ **Automatic database dump** — PostgreSQL, MySQL/MariaDB, Redis, MongoDB; custom hooks for non-standard databases
- 🌐 **Remote databases** — a managed service or another server, streamed straight into the storages: no local copy, so its size does not matter ([details](#remote-databases))
- 💾 **Full coverage** — named volumes, bind mounts, project folders with compose files
- ☁️ **Multiple storages** — primary + up to two copies (secondary, tertiary); one archive goes to all of them, rotation cleans all of them
- 🔄 **Storage synchronization** — `docker-backup-s3 sync` aligns the copies with the primary if they drift apart
- ⚡ **Parallel volume backup**
- 🎯 **Single-project backup** with `-p NAME` for urgent jobs
- 🚦 **Bandwidth limit** for S3 uploads
- 🔐 **GPG encryption** of archives (optional)
- 🔒 **Secrets stay on your server** — no telemetry; keys and passwords never go on a command line, in the log or in a notification ([details](#where-your-keys-and-passwords-live))
- 🔍 **Integrity check** — size via S3 head-object plus a `sha256` manifest next to the archive (in every storage)
- 🔁 **Upload retries** — a transient storage error (OperationAborted, SlowDown, 5xx, a broken connection) is retried, and the failed upload's parts are aborted
- ✅ **Completeness control** — if a volume or bind mount didn't make it into the archive, the project is marked as failed, not as a "success"
- 🗂 **GFS rotation** (day/week/month) and the `KEEP_MIN_BACKUPS` floor — the latest copies are never deleted
- 🔒 **Lock** against a double start (via an atomic mkdir)
- 📡 **Notifications** to Telegram, email (your SMTP) and a webhook (Discord, Slack, Mattermost or your own JSON receiver) — an interrupted run (Ctrl+C, a kill, a shutdown) is reported too
- 🧪 **Dry-run** for safe testing
- 🔑 **Read-only S3 key** for restore (protection against deletion from dev/staging)
- 🛟 **Restore from any storage** — `--from secondary|tertiary` (or the interactive choice) pulls from a copy if the primary is unavailable
- 🔬 **Partial restore** — `--contents`, `--extract-to`, `--only-volume`: get a single dump or volume without touching the running project

### Management
- ⚙️ **`install.sh`** — installation from scratch with one command, supports in-place; its questions are whiptail dialogs too
- 🧭 **`docker-backup-s3`** — the command it installs. Without arguments it opens a menu for everything (whiptail; plain prompts without it); with a subcommand it runs that one job: `docker-backup-s3 backup`, `restore`, `sync` and the ones below
- 🔄 **`docker-backup-s3 update`** — update with a backup copy and `--rollback`
- 🗑️ **`docker-backup-s3 uninstall`** — safe removal (backups in S3 are protected)
- 🧪 **`docker-backup-s3 verify`** — automatic restore verification
- 📊 **`docker-backup-s3 status`** — a one-screen system overview
- 📜 **`docker-backup-s3 logs`** — log viewing with filters

## Contents

- [Quick start](#quick-start)
- [The docker-backup-s3 command (menu)](#the-docker-backup-s3-command-menu)
- [File structure](#file-structure)
- [Installation](#installation)
- [Updating](#updating)
- [Configuration](#configuration)
- [Multiple storages (primary / secondary / tertiary)](#multiple-storages-primary--secondary--tertiary)
- [Automatic database dump](#automatic-database-dump)
- [Remote databases](#remote-databases)
- [First run](#first-run)
- [Backing up a single project](#backing-up-a-single-project)
- [Restore verification](#restore-verification)
- [GPG encryption](#gpg-encryption)
- [Notifications](#notifications)
- [Scheduled runs (cron/systemd)](#scheduled-runs-cronsystemd)
- [Restoring from a backup](#restoring-from-a-backup)
- [System status](#system-status)
- [Logs](#logs)
- [Backup rotation](#backup-rotation)
- [Uninstalling](#uninstalling)
- [Security](#security)
- [Troubleshooting](#troubleshooting)
- [Tests](#tests)
- [Versioning](#versioning)
- [License](#license)

---

## Quick start

```bash
# 1. Get the files onto the server
sudo git clone https://github.com/KolosovV/docker-backup-s3.git /opt/docker-backup-s3
#    (or copy them: sudo mkdir -p /opt/docker-backup-s3 && sudo cp -r . /opt/docker-backup-s3/)

# 2. Run the installer right from there (in-place is supported)
sudo /opt/docker-backup-s3/install.sh

# 3. Everything else — from the menu (status, backup, restore, checks, schedule, storages)
sudo docker-backup-s3

# …or the same with the scripts directly
sudo /opt/docker-backup-s3/validate-config.sh        # settings check
sudo /opt/docker-backup-s3/docker-backup.sh --dry-run # dry run
sudo /opt/docker-backup-s3/docker-backup.sh           # real backup
sudo /opt/docker-backup-s3/status.sh                 # system overview
```

If the installer set up scheduled runs (cron or a systemd timer), from here on everything runs by itself.

---

## The docker-backup-s3 command (menu)

The installer links `/usr/local/bin/docker-backup-s3` → `menu.sh`. Without arguments it opens a menu:

| Item | What it does |
|---|---|
| Status overview | `status.sh` |
| Back up now | all projects or the ones you tick in a list; a dry run of either |
| Projects | which projects not to back up (`EXCLUDE_PROJECTS`), and which to back up without database dumps (`DB_DUMP_EXCLUDE_PROJECTS`): ticked in a list of the projects on this host |
| Remote databases | add one (type, host, user, password, TLS — the login is checked at once), change it, test the login, back it up now, take it off |
| Restore | pick the storage, the project and the backup from lists, then: restore in place (with or without starting), into another folder, one named volume, unpack only, or show the contents |
| Synchronize storages | the plan, all copies, one copy, with `--prune`, or restoring the primary from a copy |
| Checks and diagnostics | `validate-config.sh`, quick/full restore verification (of any storage, all projects or one), `diagnose-s3.sh`, `diagnose-cron.sh` |
| Logs | the last lines, errors, the last run, today's errors, one project, follow live |
| Scheduled runs | the current setup, a method (cron / systemd timer) and a preset or your own schedule, removal |
| Storage settings | for each storage: the connection wizard (keys, endpoint, bucket, addressing — with the bucket and certificate check), enable/disable and required/optional for copies, an access check, the read-only restore key |
| Notifications | when to notify (problems only / every run / never), the server name in messages, and Telegram, the webhook and email: set up, test, turn off; every change is checked with a test message |

Destructive actions (an in-place restore, `--prune`, writing to the primary from a copy) ask for confirmation first;
the scripts themselves keep their own confirmations too. Before the first change to the config the menu
saves a copy `backup.conf.bak.<time>`.

The menu uses `whiptail` (`install.sh` installs it: the `whiptail`, `newt` or `libnewt` package). Without it, or with
`UI_PLAIN=true`, the same menu works as numbered prompts. Without a terminal (cron, pipes) there is no menu — use
the subcommands, they pass their arguments to the script as is:

```bash
sudo docker-backup-s3 backup -p myapp          # = docker-backup.sh -p myapp
sudo docker-backup-s3 restore --list           # = docker-restore.sh --list
sudo docker-backup-s3 sync --to tertiary       # = sync-s3.sh --to tertiary
sudo docker-backup-s3 help                     # all subcommands
```

`install.sh` asks its questions in the same dialogs; with `-y` it asks nothing, as before.

---

## File structure

After installation in `/opt/docker-backup-s3/`:

```
install.sh                       # installer from scratch
update.sh                        # update with rollback
uninstall.sh                     # clean removal (leaves S3 alone)
docker-backup.sh                 # the main backup script
docker-restore.sh                # the restore script
lib.sh                           # shared library (sourced by the scripts)
ui.sh                            # dialogs (whiptail / plain prompts) and config helpers for install.sh and the menu
menu.sh                          # the docker-backup-s3 command: the menu and subcommands
validate-config.sh               # configuration check
verify-restore.sh                # automatic backup restore verification
setup-cron.sh                    # interactive setup of scheduled runs
diagnose-cron.sh                 # cron diagnostics (for debugging)
diagnose-s3.sh                   # access diagnostics for every S3 storage
sync-s3.sh                       # synchronizes the copies (secondary, tertiary) with the primary
status.sh                        # a one-screen system overview
logs.sh                          # log viewing with filters
backup.conf                      # settings (chmod 600, not committed to git)
backup.conf.example              # settings template without secrets
pre-backup-hook.example.sh       # hook template for non-standard databases
README.md                        # this documentation
CHANGELOG.md                     # release notes
VERSION                          # the installed version (docker-backup-s3 version)
LICENSE                          # MIT
```

Only `backup.conf.example` is in the repository; the working `backup.conf` is created from it during installation and is in `.gitignore`, because it holds the S3 keys, the Telegram token and the SMTP password. If you deploy from git:

```bash
cp backup.conf.example backup.conf && chmod 600 backup.conf
```

In each compose project folder (optional):
```
/opt/myapp/
├── docker-compose.yml
├── .env
├── pre-backup-hook.sh           # runs BEFORE the backup (chmod +x)
└── db-dumps/                    # database dumps are put here automatically
```

---

## Installation

### Supported systems

Tested in CI on every release and once a month. On each of these systems CI runs `install.sh -y` on a fresh
install, then the tests and the full integration test (backup → restore → compare), see `tests/distros/`:

| Distribution | Package manager | AWS CLI v2 from |
|---|---|---|
| Debian 12, 13 | apt | the official installer |
| Ubuntu 22.04, 24.04 | apt | the official installer |
| Rocky Linux 9, AlmaLinux 8 (RHEL family) | dnf | the official installer |
| Fedora 41 | dnf | the official installer |
| Amazon Linux 2023 | dnf | the official installer |
| openSUSE Leap 15.6 | zypper | the official installer |
| Arch Linux | pacman | the official installer |
| Alpine 3.20 | apk | the `aws-cli` package (the official build needs glibc) |

- **bash 4.4+** (tested 4.4 to 5.3). On Alpine, install it first: `apk add bash`. Everything else, `install.sh` installs itself: only
  what is missing, under each distro's own package names. That includes the GNU versions of `date`, `stat`, `tar`
  and `grep` on Alpine and the full `gnupg` (with `gpg-agent`) on Amazon Linux.
- **Docker** with **Compose v2** (the `docker compose` plugin, part of every current Docker install). The standalone
  `docker-compose` v1 is not supported: Docker ended it in 2023. The installer does not install Docker.
- **Scheduling:** cron (cronie, cron or dcron) or a systemd timer. Without systemd (Alpine with OpenRC) cron is
  used and `crond` is enabled through OpenRC.
- **AWS CLI v2:** the official AWS installer into `/usr/local/bin` comes first. Where it does not run (musl), the
  distro package is used if it is v2, and snap is the last fallback.
- **x86_64 and aarch64.** aarch64 is tested under QEMU on Debian 12, Ubuntu 24.04, Rocky 9 and Alpine.
- **Scheduling on a real init:** the cron service, the systemd timer and service, and cron starting a backup on its
  own are tested on a VM and with systemd as PID 1 on Debian, Ubuntu, Rocky 9, AlmaLinux 8, Fedora, openSUSE and
  Arch (systemd 239 to 25x).
- Other Linux distributions with bash 4.4+ and these tools should work too; they are just not in CI.
- **Linux only.** Windows and macOS (Docker Desktop) are not supported: Docker runs there in a hidden Linux VM,
  so volumes and folder paths are not where the scripts look, and a laptop that sleeps at night misses its backups.

> On CentOS/RHEL `dos2unix` lives in EPEL. If it did not install, that is not critical: the scripts fix line
> endings with `sed`.

### With `install.sh`

The installer does everything itself:
1. Installs the missing dependencies via the system package manager — `apt`/`dnf`/`yum`/`zypper`/`pacman`/`apk`:
   `jq`, `tar`, `gzip`, `dos2unix`, `curl`, `gpg` (with `gpg-agent`), `unzip`, cron, `whiptail`, `logrotate`,
   `util-linux`, `findutils`, `procps` (on Alpine also the GNU `coreutils`, `grep`, `sed`, `tar`). Only what is missing,
   one package at a time if the whole list fails; a package manager busy right after boot is waited for
2. Installs AWS CLI v2 with the official AWS installer into `/usr/local/bin` and checks that it runs; where it cannot
   (musl: Alpine), the distro's package if it is v2; snap is the last fallback. If aws is already installed from snap,
   it offers to switch to the official one: snap updates aws-cli by itself, and such updates have broken uploads
   (new checksums some storages reject, a CA bundle without the GlobalSign root)
3. Checks that Docker and the `docker compose` (v2) plugin are present (it does not install them)
4. Copies the files (or works in-place if source = target). If there is no `backup.conf` yet but `uninstall.sh`
   kept a copy of one in `/root`, it offers to take those settings over, and keeps a copy as it was
   (`backup.conf.imported-<time>`)
5. `dos2unix` + `chmod +x` + `chmod 600 backup.conf`
6. Asks for the settings interactively (in whiptail dialogs if whiptail is installed, plain prompts otherwise):
   - **Primary S3**: Access/Secret/Endpoint/Region/Bucket + addressing style (path/virtual); then checks the bucket and certificate trust itself (see below)
   - **Secondary and tertiary S3** — whether to enable, keys/endpoint/region/bucket, addressing style, whether required; the same check
   - **Prefix in the bucket** (`BACKUP_PREFIX`)
   - **Retention** (`RETENTION_DAYS`)
   - Directories to scan (`SCAN_DIRS`)
   - **Encryption**: with the passphrase file already on the server, if there is one; otherwise it offers to
     generate one (copy it off the server: without it the backups cannot be restored)
   - The server's name in notifications (`NOTIFY_NAME`)
   - Telegram token and chat_id, with a real check via a test message
   - Webhook URL (optional), with a test message
   - Email: recipients, SMTP server, security, login, sender (optional), with a test email
7. Optionally sets up logrotate; links the `docker-backup-s3` command
8. Runs `validate-config.sh`
9. Optionally runs `setup-cron.sh` for scheduled runs

#### S3 certificate check during installation

The installer doesn't ask about the certificate — the answer is unknown at install time (a wrong "no" leaves
a copy that silently stops accepting archives). Instead of asking, after the
keys, endpoint, bucket and addressing style are entered it runs `aws s3api head-bucket` — with the same keys
and `AWS_REQUEST_CHECKSUM_CALCULATION`/`AWS_RESPONSE_CHECKSUM_VALIDATION` as the backup, without `~/.aws`:
- passed — no options needed, `<ROLE>_S3_OPTS_EXTRA` stays empty;
- `CERTIFICATE_VERIFY_FAILED` — retries with `--ca-bundle` of the system CA bundle
  (`/etc/ssl/certs/ca-certificates.crt`, on RHEL — `/etc/pki/tls/certs/ca-bundle.crt`).
  Passed — writes the option to `<ROLE>_S3_OPTS_EXTRA` and says so in one line;
  failed even so — warns and writes nothing (see [`CERTIFICATE_VERIFY_FAILED`](#ssl-certificate_verify_failed));
- another error (key, bucket, addressing) — a warning with the reason from aws, to sort out later with `validate-config.sh`.

The installer never sets `--no-verify-ssl`. If aws isn't installed yet at this step or the fields are empty,
the check is skipped quietly. The option goes into `<ROLE>_S3_OPTS_EXTRA` of the storage that was checked (`PRIMARY_S3_OPTS_EXTRA`, `SECONDARY_S3_OPTS_EXTRA`, `TERTIARY_S3_OPTS_EXTRA`).

#### Scenario 1: installing from a separate folder

```bash
# The files are in /tmp/install/
sudo /tmp/install/install.sh
# → copies the files to /opt/docker-backup-s3/
```

#### Scenario 2: in-place installation (source = target)

```bash
# The files are already in /opt/docker-backup-s3/
sudo /opt/docker-backup-s3/install.sh
# → does NOT copy, only sets up permissions, the config, cron
```

install.sh detects this automatically, and in in-place mode it:
- Does not copy the files (they're already in place)
- Runs `dos2unix` + `chmod` to be safe
- **Checks** whether `backup.conf` holds real values

#### How `backup.conf` is handled

The installer handles the config carefully:

| Config state | Behavior |
|---|---|
| **Does not exist** | If `uninstall.sh` kept a copy of the settings in `/root`, offers to take them over; otherwise creates it from the template and runs the wizard |
| **Exists and is filled in** | Leaves it as is, no questions |
| **Exists, but with placeholder values** (`YOUR_ACCESS_KEY`, an empty bucket/endpoint) | Interactive: asks "Fill in the settings now?" → runs the wizard. With `-y`: a warning + a hint |

What counts as a "placeholder":
- `PRIMARY_S3_ACCESS_KEY` or `PRIMARY_S3_SECRET_KEY` equal to `YOUR_...` or empty
- `PRIMARY_S3_BUCKET` empty

This lets you work with a single command: put the files into `/opt/docker-backup-s3`, run `install.sh` from there — and it either finishes the installation or asks for whatever is missing.

#### Options

```
-t, --target DIR       where to install (default: /opt/docker-backup-s3)
-y, --yes              no interactive questions
    --skip-deps        don't install system packages and AWS CLI
    --no-cron          don't set up scheduled runs
    --skip-logrotate   don't install logrotate
    --skip-validate    skip the final validation
-h, --help             help
```

### Creating a bucket

⚠️ AWS CLI often cannot create a bucket on S3-compatible storages. Create it by hand beforehand:
1. Open your S3 provider's control panel
2. The object storage (S3) section → create a bucket
3. Remember the bucket name — you need it for `PRIMARY_S3_BUCKET` in the config

If you use copies (secondary, tertiary S3), create a bucket beforehand in each provider's panel the same way. The script does not create buckets — it only uses existing ones.

### Getting S3 keys

In your S3 provider's panel:
- The access / S3 keys section (Access keys)
- Copy the **Access Key** and **Secret Key**, put them into `PRIMARY_S3_ACCESS_KEY` / `PRIMARY_S3_SECRET_KEY`
- Find out the storage **endpoint** (e.g. `https://s3.example.com`) → `PRIMARY_S3_ENDPOINT`
- and its **region** (from the provider's docs or panel: `us-east-1`, `ru-1`, `default`, …) → `PRIMARY_S3_REGION`: it is required

Optional: a second, read-only key for a restore server — `<ROLE>_S3_RESTORE_ACCESS_KEY` / `<ROLE>_S3_RESTORE_SECRET_KEY` for each storage (`PRIMARY`, `SECONDARY`, `TERTIARY`). If set, `docker-restore.sh` reads with these keys, and backups cannot be deleted/overwritten with them.

For each copy, get keys from its provider and put them into `SECONDARY_S3_ACCESS_KEY` / `SECONDARY_S3_SECRET_KEY` (or `TERTIARY_…`), plus `_ENDPOINT`, `_REGION` and `_BUCKET`.

---

## Updating

To update an installed system without losing `backup.conf`, use `update.sh`:

```bash
# 1. Put the new version into a separate folder
sudo git clone https://github.com/KolosovV/docker-backup-s3.git /tmp/new-version
#    (or copy the files: sudo mkdir -p /tmp/new-version && sudo cp -r . /tmp/new-version/)

# 2. Run the update
sudo /tmp/new-version/update.sh
```

If `/opt/docker-backup-s3` itself is a git clone (installed with `git clone --branch vX.Y.Z`), switch it to the new
release there, then run its `update.sh`; your `backup.conf` is in `.gitignore` and stays untouched:

```bash
sudo git -C /opt/docker-backup-s3 fetch --tags --force
sudo git -C /opt/docker-backup-s3 checkout v2.0.0          # the release you want; not while a backup runs
sudo /opt/docker-backup-s3/update.sh                       # finishes it: the command, new options, a check
```

In a git clone `update.sh` copies nothing (the checkout has done that) and makes no backup copy (git has every
version: to go back, check out the previous tag and run it again). It does the rest: links the `docker-backup-s3`
command if it is missing, lists the options you don't set, and runs `validate-config.sh`.

What it does:
- Compares file versions and shows what will actually change
- Checks the syntax of the new files **before** replacing them (won't break the system with a broken script)
- Backs up the current installation to `/opt/docker-backup-s3.bak.<timestamp>/`
- Does not overwrite your `backup.conf`: shows which new options appeared in the template (an option you don't set takes its default from `backup.conf.example`)
- Refuses to update while a backup is running (checks the lock)
- Runs `validate-config.sh` after the update

### Rolling back to the previous version

```bash
sudo /opt/docker-backup-s3/update.sh --rollback
```

Rolls back to the latest backup copy. The current state (before the rollback) is also saved to `/opt/docker-backup-s3.reverted.<timestamp>/`.

### update.sh options

```
-t, --target DIR     where (default: /opt/docker-backup-s3)
-s, --source DIR     from where (default: next to the script)
-y, --yes            no questions
    --rollback       roll back to the latest backup copy
    --skip-validate  skip validation
    --skip-backup    do NOT make a backup copy (dangerous)
```

### Cleaning up old backup copies

After several updates `*.bak.*` folders pile up on disk:
```bash
ls -d /opt/docker-backup-s3.bak.* /opt/docker-backup-s3.reverted.* 2>/dev/null
# Delete the old ones:
sudo rm -rf /opt/docker-backup-s3.bak.* /opt/docker-backup-s3.reverted.*
```

---

## Configuration

The file is `/opt/docker-backup-s3/backup.conf`. The minimum needed:

```bash
PRIMARY_S3_ACCESS_KEY="your_key"
PRIMARY_S3_SECRET_KEY="your_secret"
PRIMARY_S3_ENDPOINT="https://s3.example.com"
PRIMARY_S3_REGION="us-east-1"        # your provider's region: required
PRIMARY_S3_BUCKET="your-bucket-name"
SCAN_DIRS="/opt /home /root /srv"
```

Everything else has sensible defaults.

| Variable | Default | What it does |
|---|---|---|
| `PRIMARY_S3_ACCESS_KEY`, `_SECRET_KEY` | — | the primary storage key (full permissions) |
| `PRIMARY_S3_ENDPOINT` | empty | S3 endpoint URL (fill in manually, e.g. `https://s3.example.com`) |
| `PRIMARY_S3_REGION` | `us-east-1` | **required**: the storage's region as the provider names it; every request is signed for it, and many storages reject a wrong one |
| `PRIMARY_S3_BUCKET` | empty | bucket name (create it beforehand) |
| `PRIMARY_S3_OPTS_EXTRA` | empty | extra aws options; `--ca-bundle /etc/ssl/certs/ca-certificates.crt` if aws doesn't trust a valid certificate (the installer checks and sets it itself) |
| `PRIMARY_S3_ADDRESSING_STYLE` | `path` | path/virtual |
| `PRIMARY_S3_RESTORE_ACCESS_KEY`, `_SECRET_KEY` | empty | optional read-only key for restore, status, verify-restore |
| `SECONDARY_S3_*`, `TERTIARY_S3_*` | — | copies: the same fields as `PRIMARY_S3_*`, the region required too |
| `SECONDARY_S3_ENABLED`, `TERTIARY_S3_ENABLED` | `false` | enable the copy |
| `SECONDARY_S3_REQUIRED`, `TERTIARY_S3_REQUIRED` | `false` | `true` = a failed upload to this copy makes the project fail |
| `S3_BANDWIDTH_LIMIT` | empty | upload speed limit (shared by all storages) |
| `S3_MULTIPART_THRESHOLD` | empty | smaller files go in one request rather than in parts (shared) |
| `S3_MAX_ATTEMPTS` | `8` | aws attempts per request (shared) |
| `S3_UPLOAD_TRIES` | `3` | attempts of a whole file upload, or of deleting an old backup, on a transient storage error (OperationAborted, SlowDown, 5xx, a broken connection); a failed attempt's multipart parts are aborted, and the rotation step of every full run aborts any older leftovers |
| `S3_UPLOAD_RETRY_DELAY` | `15` | the first pause between those attempts, in seconds; it triples |
| `BACKUP_PREFIX` | `backups` | prefix (folder) in the bucket |
| `RETENTION_DAYS` | `30` | how many days to keep |
| `KEEP_MIN_BACKUPS` | `3` | this many latest backups of each project are never deleted |
| `GFS_ENABLED` | `false` | GFS rotation instead of `RETENTION_DAYS` (see [Backup rotation](#backup-rotation)) |
| `GFS_DAILY`, `GFS_WEEKLY`, `GFS_MONTHLY` | `7`, `4`, `6` | how many daily, weekly and monthly backups GFS keeps |
| `CHECKSUM_MANIFEST` | `true` | a `.sha256` file next to every archive |
| `SCAN_DIRS` | `/opt /home /root /srv` | folders to look for compose projects in (not exclusions) |
| `EXCLUDE_PROJECTS` | empty | projects not to back up: names or globs (`test-*`), space- or comma-separated. Their backups already in the storages are kept (rotation treats them as live projects); `-p NAME` still backs one up |
| `DB_DUMP_EXCLUDE_PROJECTS` | empty | projects backed up without database dumps (volumes, bind mounts and the folder only) |
| `BACKUP_MODE` | `hot` | hot/pause/stop |
| `BACKUP_VOLUMES` | `true` | back up named volumes |
| `BACKUP_BIND_MOUNTS` | `true` | back up bind mounts |
| `BACKUP_PROJECT_DIR` | `true` | back up the whole project folder |
| `BACKUP_IMAGES` | `false` | save docker images |
| `BACKUP_STANDALONE` | `true` | back up containers started without compose (one extra archive); a single container is left out with the label `docker-backup-s3.skip=true` (in a compose project the same label turns off its database dump) |
| `PARALLEL_JOBS` | `2` | volume backup parallelism |
| `COMPRESS_LEVEL` | `6` | gzip level for every archive: 1 — fastest, 9 — smallest |
| `MIN_FREE_SPACE_MB` | `1024` | minimum free space |
| `BIND_BLACKLIST_REGEX` | `^/$\|^/proc\|...` | path blacklist |
| `BIND_EXCLUDE_PATHS` | empty | subfolders inside a bind not to back up (space-separated), e.g. `/srv/files/nobackup` |
| `AUTO_DUMP_DATABASES` | `true` | database auto-dump |
| `AUTO_DUMP_POSTGRES` | `true` | Postgres auto-dump |
| `AUTO_DUMP_MYSQL` | `true` | MySQL/MariaDB auto-dump |
| `AUTO_DUMP_REDIS` | `true` | Redis auto-dump |
| `AUTO_DUMP_MONGO` | `true` | MongoDB auto-dump |
| `DB_DUMPS_DIR` | `db-dumps` | subfolder for the dumps |
| `DB_DUMPS_RETENTION_COUNT` | `0` | how many dumps of each database stay on the server after the upload (`0` — none) |
| `DB_DUMP_TIMEOUT` | `1800` | timeout for each dump (sec) |
| `REMOTE_DBS`, `REMOTE_DB_<NAME>_*` | empty | databases not on this host (see [Remote databases](#remote-databases)) |
| `ENCRYPT_BACKUPS` | `false` | GPG encryption |
| `GPG_PASSPHRASE_FILE` | `/root/.docker-backup-passphrase` | passphrase file |
| `NOTIFY_ON` | `error` | none / error (errors and warnings) / always |
| `NOTIFY_NAME` | empty | the server's name in messages; empty — the hostname |
| `TELEGRAM_BOT_TOKEN` | empty | bot token |
| `TELEGRAM_CHAT_ID` | empty | recipient ID |
| `NOTIFY_WEBHOOK_URL` | empty | webhook URL |
| `NOTIFY_WEBHOOK_FORMAT` | `auto` | auto/discord/slack/json — the payload shape |
| `EMAIL_TO` | empty | email recipients, space- or comma-separated |
| `SMTP_HOST` | empty | SMTP server |
| `SMTP_SECURITY` | `starttls` | starttls (587) / tls (465) / none (25) |
| `SMTP_PORT` | empty | port; empty — the one of `SMTP_SECURITY` |
| `SMTP_USER` / `SMTP_PASSWORD` | empty | SMTP login; empty — without login |
| `SMTP_FROM` | empty | sender address; empty — `SMTP_USER` |
| `COLOR_OUTPUT` | `auto` | auto/on/off |
| `LOCK_FILE` | `/var/run/docker-backup.lock` | base path for the lock; the lock itself is a `<LOCK_FILE>.d` directory with the PID inside (atomic `mkdir`) |
| `WORK_DIR` | `/var/tmp/docker-backup` | temporary folder |
| `LOG_FILE` | `/var/log/docker-backup.log` | log path |
| `LAST_RUN_FILE` | `/var/lib/docker-backup/last-run.json` | the last run's result, for an external monitor |

### Backup modes (`BACKUP_MODE`)

| Mode | Downtime | Database consistency | When to use |
|---|---|---|---|
| `hot` | none | via the database auto-dump | **default** — no downtime |
| `pause` | milliseconds | medium | general purpose |
| `stop` | seconds to minutes | perfect | for critical databases without auto-dump; the project's running containers are stopped and started again |

### Checking the settings

```bash
sudo /opt/docker-backup-s3/validate-config.sh
```

The script checks:
- That the required fields are filled in and the value formats
- File permissions and CRLF
- Whether the dependencies are installed (including the AWS CLI v2 check and the `docker compose` plugin)
- A setting of yours overridden by a template default further down in `backup.conf` (a setting given twice)
- `SCAN_DIRS` folders inside one another (usually an exclusion typed in the wrong place)
- Encryption: that `gpg` really encrypts and decrypts a test file, and a loud warning when the passphrase file exists
  but `ENCRYPT_BACKUPS` is not `true`
- Access to each storage — the primary and the enabled copies (a test write + read + delete); on `CERTIFICATE_VERIFY_FAILED` — a check with the system CA bundle and a ready line for `backup.conf`
- Each storage's read-only key, if set
- Free space
- **Telegram bot** — by actually sending a test message, with error diagnostics
- **Webhook** and **email** — by sending a test message, with hints for the common errors
- The cron job and which `aws` it will find with its `PATH` (warns if it's from snap)

---

## Multiple storages (primary / secondary / tertiary)

The system writes every archive to the primary storage and to every enabled copy. The flow for each project:

```
build archive → upload to the primary S3   → check the size
              → upload to the secondary S3 → check the size   (if enabled)
              → upload to the tertiary S3  → check the size   (if enabled)
```

The object key (`<BACKUP_PREFIX>/<project>/<timestamp>/<file>`) is **the same** in every
bucket, so a restore from a copy works transparently. Automatic rotation
(`RETENTION_DAYS` / GFS) is applied to **each** storage independently.

### Setting it up in `backup.conf`

All storages share one scheme: `<ROLE>_S3_<FIELD>`. Copies also have `_ENABLED` and `_REQUIRED`:

```bash
# --- PRIMARY: the primary S3 ---
PRIMARY_S3_ACCESS_KEY="..."
PRIMARY_S3_SECRET_KEY="..."
PRIMARY_S3_ENDPOINT="https://s3.example.com"   # your provider's endpoint
PRIMARY_S3_REGION="us-east-1"
PRIMARY_S3_BUCKET="my-backups"                 # create the bucket beforehand
PRIMARY_S3_ADDRESSING_STYLE="path"             # path or virtual
PRIMARY_S3_OPTS_EXTRA=""                       # "--ca-bundle …" — the installer sets it itself if needed

# --- SECONDARY: the secondary S3 (another provider/region) ---
SECONDARY_S3_ENABLED="true"                    # enable duplication
SECONDARY_S3_REQUIRED="false"                  # see the table below
SECONDARY_S3_ACCESS_KEY="..."
SECONDARY_S3_SECRET_KEY="..."
SECONDARY_S3_ENDPOINT="https://s3.other-provider.com"
SECONDARY_S3_REGION="..."                      # required: this provider's region
SECONDARY_S3_BUCKET="..."
SECONDARY_S3_ADDRESSING_STYLE="path"
SECONDARY_S3_OPTS_EXTRA=""

# --- TERTIARY: the tertiary S3 — the same fields ---
TERTIARY_S3_ENABLED="false"
# TERTIARY_S3_ACCESS_KEY, _SECRET_KEY, _ENDPOINT, _REGION, _BUCKET, _ADDRESSING_STYLE, _OPTS_EXTRA, _REQUIRED
```

The list of roles is defined in one place — `S3_ROLES` in `lib.sh`; every script walks it. To
add a fourth storage, it is enough to add the role there, its labels in `s3_label` and a block in
`backup.conf.example`.

### What to do if a copy did not upload

Controlled by each copy's `<ROLE>_S3_REQUIRED` flag:

| Value | Behavior on "primary OK, copy failed" |
|---|---|
| `false` (default) | ⚠ a warning in the log/notification, the backup counts as **successful** (the main thing — the copy in the primary S3 is there) |
| `true` | ❌ the project is marked as **failed** (this copy is needed too) |

> If the primary S3 failed — the project always fails, regardless of these flags. A required copy
> that is unreachable before the backup stops the whole run; an optional one doesn't, and the final
> notification shows, for each copy, what it did not receive.

### About the addressing style

There are two ways to address a bucket: **path-style** (`endpoint/bucket`) and
**virtual-hosted** (`bucket.endpoint`). By default every storage uses
`path` — it works on most S3-compatible storages. The addressing style
is asked in the installation wizard and written to `<ROLE>_S3_ADDRESSING_STYLE`.
You can change it any time by editing this value in `backup.conf`
(`path` or `virtual`).

If your bucket is reachable only in virtual-hosted mode and you get access
errors — set `virtual`. The `diagnose-s3.sh` diagnostics try both
variants for each storage and tell you which one works.

### Synchronizing copies (`sync-s3.sh`)

The primary storage and a copy can drift apart if the copy was
added after several backups, if uploads to it failed for a while,
or if an object uploaded partially. `status.sh` shows such a
mismatch (`Mismatch: primary=…, secondary S3=…`) and suggests the command.

`sync-s3.sh` aligns the copies with the primary. The primary is the source
of truth, so by default synchronization is **one-way**: primary → each
enabled copy in turn (`--to ROLE` — into one only):

- objects missing in the copy → copied from the primary;
- object size mismatch → the object is re-uploaded from the primary;
- objects missing in the primary (e.g. after rotation) → **not touched** without `--prune`.

Copying goes through a temporary file (download from the source → upload to the
destination → check the size, and if there is a `.sha256` — check the hash first), since
these are different providers and a server-side copy between them is impossible.

```bash
# See what drifted apart (changes nothing)
sudo /opt/docker-backup-s3/sync-s3.sh --dry-run

# Copy what's missing + re-upload objects with a wrong size — into all copies
sudo /opt/docker-backup-s3/sync-s3.sh

# Into the tertiary S3 only
sudo /opt/docker-backup-s3/sync-s3.sh --to tertiary

# Same + delete objects in the copies that are no longer in the primary (IRREVERSIBLE)
sudo /opt/docker-backup-s3/sync-s3.sh --prune

# No confirmations (for cron)
sudo /opt/docker-backup-s3/sync-s3.sh --prune -y
```

| Option | What it does |
|---|---|
| (no options) | primary → each enabled copy: copy what's missing + re-upload objects whose size differs |
| `--to ROLE` | into this copy only (`secondary`, `tertiary`) |
| `--from ROLE` | where to read from (`primary` by default; `secondary` with `--reverse`) |
| `--dry-run` | only show the plan, change nothing |
| `--prune` | also delete objects in the destination that are not in the source |
| `--reverse` | reverse direction: copy → primary (disaster recovery) |
| `-y`, `--yes` | don't ask for confirmation (for `--prune`/`--reverse` and cron) |

Synchronization needs the destination's **full** keys (`<ROLE>_S3_ACCESS_KEY`/`SECRET_KEY`): for the
forward direction — the copy's, for the reverse — the primary's. A read-only key is not enough. If one of the pairs
fails (e.g. the storage didn't respond), the rest are still synchronized, and the script
exits with an error. If you like, the forward synchronization can go into cron, e.g.
weekly with `--prune -y`.

#### Reverse synchronization (restoring the primary)

```bash
# If the PRIMARY lost data, and an intact copy remains in the secondary:
sudo /opt/docker-backup-s3/sync-s3.sh --reverse --dry-run                 # see the plan
sudo /opt/docker-backup-s3/sync-s3.sh --reverse                           # bring the data back to the primary
sudo /opt/docker-backup-s3/sync-s3.sh --reverse --from tertiary           # the same from the tertiary
```

`--reverse` inverts the direction: a copy becomes the source (the secondary S3
by default), and the primary becomes the destination. This is a **disaster recovery** scenario for when
the primary bucket is lost (a provider failure, an accidental deletion, recreation).
Since the operation overwrites the "source of truth", the script always asks for
confirmation (type `yes`), and `--prune` in the reverse direction (deleting
**in the primary** S3) needs a separate consent. Without `--prune` the reverse
synchronization only copies what's missing and re-uploads objects with a wrong
size — deleting nothing.

### Disabling a copy

Set `SECONDARY_S3_ENABLED="false"` (or `TERTIARY_S3_ENABLED="false"`) — the system
stops uploading to this copy and cleaning it. The copy's other fields can stay empty.

---

## Automatic database dump

Data consistency with `BACKUP_MODE=hot` is ensured automatically — the script finds and dumps all standard database containers itself.

### How it works

When a backup runs, for each project the script:
1. Goes through all running containers of the project
2. Determines the database type from the container image:
   - `postgres`, `postgis`, `timescale*` → `pg_dumpall` (all databases, roles, tablespaces)
   - `mysql`, `percona`, `mariadb` → `mariadb-dump` where the image has it (MariaDB 11 has no `mysqldump`), otherwise
     `mysqldump`; `--all-databases --single-transaction --routines --triggers --events`
   - `redis`, `valkey`, `keydb` → `BGSAVE`, waiting for it to finish, then a copy of the RDB file
   - `mongo` (and `percona-server-mongodb`) → `mongodump --archive --gzip`
3. Checks that the container really runs that database server and has its dump tool: an exporter,
   an admin UI or a backup sidecar whose image name matched (`postgres-exporter`, `redis_exporter`,
   `mongo-express`…) is skipped with a note, not counted as a failure
4. Saves the dump into the `db-dumps/` subfolder inside the project (`700`, the files `600`)
5. The dump goes into the archive with the project folder — only this run's: earlier dumps kept on the server
   are left out, they are in earlier archives already
6. Once the archive is in the storage, deletes the dumps on the server, or keeps the last
   `DB_DUMPS_RETENTION_COUNT` of each database for a quick rollback. A dump is all the data in plain form, and
   a local copy on the same disk does not survive the loss of the server. If the upload fails, this run's
   dump stays until the next run. With `BACKUP_PROJECT_DIR="false"` the dumps are not in the archive, and
   nothing is deleted.

When a dump fails, the log says why — the last lines of the tool's own error (`Access denied for user…`,
`WRONGPASS…`, a timeout) — and the raw volume still goes into the archive.

### What ends up in S3

```
backups/myapp/2026-05-12_03-00-00/myapp__2026-05-12_03-00-00.tar.gz          (.tar.gz.gpg if encrypted)
backups/myapp/2026-05-12_03-00-00/myapp__2026-05-12_03-00-00.tar.gz.sha256   # the manifest
└── myapp/
    ├── project_dir.tar.gz         # the whole folder with docker-compose.yml
    │   └── myapp/
    │       ├── docker-compose.yml
    │       ├── .env
    │       └── db-dumps/                              ← the dumps are here
    │           ├── postgres_myapp-postgres-1_...sql.gz
    │           └── redis_myapp-redis-1_...rdb.gz
    ├── volumes/                   # named volumes (the databases' raw data directories too)
    │   ├── volume_myapp_postgres_data.tar.gz
    │   └── volume_myapp_redis_data.tar.gz
    ├── binds/                     # bind mounts outside the project folder
    └── inspect/                   # docker inspect of every container (paths, for the restore)
```

Each archive will contain **both an SQL dump** (for a reliable restore) **and the raw volume** (for a fast restore).

### Credentials

Nothing to configure: the dump uses the credentials the database container already has. They are read
**inside the container**, at dump time, from the same variables the image itself uses — or from the file
the `*_FILE` variant points to (Docker secrets) — and never leave it: they are not copied to the host,
not put on a command line, not written to the log
([more](#where-your-keys-and-passwords-live)).

| Database | Where the credentials come from (the first one set wins) |
|---|---|
| PostgreSQL | `POSTGRES_USER` (`postgres` by default) + `POSTGRES_PASSWORD`; Bitnami: `POSTGRESQL_POSTGRES_PASSWORD`, or `POSTGRESQL_USERNAME` + `POSTGRESQL_PASSWORD`. The official image trusts the local socket, so the password matters only with `scram`/`md5` on the socket |
| MySQL / MariaDB | `MYSQL_ROOT_PASSWORD` / `MARIADB_ROOT_PASSWORD` (mailcow: `DBROOT`) → all databases. With a random or unknown root password: `MYSQL_USER` + `MYSQL_PASSWORD` (`MARIADB_…`) → that user's `MYSQL_DATABASE`. With neither: root without a password. Each account is tried with a login first; the log says which one made the dump |
| Redis / Valkey / KeyDB | No password, or the one the server really uses: `--requirepass` in the container's command, `requirepass` in the config file given to it, `REDIS_PASSWORD` (`REDISPASS`, `VALKEY_PASSWORD`…) — each is tried with `PING` first. The port comes from `--port` / the config file. The RDB file's folder and name — from the server (`CONFIG GET`) |
| MongoDB | `MONGO_INITDB_ROOT_USERNAME` + `MONGO_INITDB_ROOT_PASSWORD` (Bitnami: `MONGODB_ROOT_USER` + `MONGODB_ROOT_PASSWORD`); without them — no authentication |

A database whose credentials are not in the container's environment (set by hand, kept in a vault) can't be
dumped automatically: use a [hook](#custom-hooks), or turn its dump off — its raw volume is still backed up:

- one container: the label `docker-backup-s3.skip=true` on it (`labels:` in the compose file);
- a whole project: `DB_DUMP_EXCLUDE_PROJECTS` in `backup.conf`, or the menu → **Projects**.

### Restoring a database from a dump

After a restore, the project folder has the dumps in `db-dumps/`. Loading one by hand (the passwords are
read inside the container, as during the backup):

```bash
# PostgreSQL
gunzip -c /opt/myapp/db-dumps/postgres_*.sql.gz \
    | docker exec -i myapp-postgres-1 psql -U postgres

# MySQL / MariaDB
gunzip -c /opt/myapp/db-dumps/mariadb_*.sql.gz \
    | docker exec -i myapp-db-1 sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -u root'
#   (MySQL: mysql_*.sql.gz, $MYSQL_ROOT_PASSWORD and the mysql client)

# Redis — stop it first: on shutdown Redis saves its memory over the file you put in
docker compose stop redis
gunzip -c /opt/myapp/db-dumps/redis_*.rdb.gz > /tmp/dump.rdb
docker cp /tmp/dump.rdb myapp-redis-1:/data/dump.rdb
docker compose start redis

# MongoDB — mongorestore asks for the password itself (it is not on the command line)
docker cp /opt/myapp/db-dumps/mongo_myapp-mongo-1_2026-05-12_03-00-00.archive.gz myapp-mongo-1:/tmp/dump.archive.gz
docker exec -it myapp-mongo-1 mongorestore --archive=/tmp/dump.archive.gz --gzip --drop \
    -u root --authenticationDatabase admin      # without authentication: drop the -u … part
docker exec myapp-mongo-1 rm /tmp/dump.archive.gz
```

If the Redis server uses AOF (`appendonly yes`), it loads the AOF, not the RDB, on start: turn AOF off for
that start, or restore the raw volume instead.

### Custom hooks

For non-standard databases (ClickHouse, Elasticsearch, InfluxDB and the like) create `pre-backup-hook.sh` in the project folder:

```bash
cd /opt/myapp
sudo cp /opt/docker-backup-s3/pre-backup-hook.example.sh pre-backup-hook.sh
sudo chmod +x pre-backup-hook.sh
sudo nano pre-backup-hook.sh
```

The hook runs **after** the auto-dump of the standard databases. Available variables:
- `COMPOSE_PROJECT` — project name
- `PROJECT_DIR` — path to the folder
- `BACKUP_TIMESTAMP` — timestamp

---

## Remote databases

A database that is not a container on this host — a managed service, a server elsewhere — can be backed
up too. It is dumped by a throwaway client container, and the dump goes straight into the primary storage
through a pipe:

```
docker run --rm postgres:18-alpine pg_dump …  |  gzip  |  gpg (if ENCRYPT_BACKUPS)  |  aws s3 cp - s3://…
```

The dump is never written to this disk, so its size does not matter here: a 300 GB database needs no
300 GB of free space. The checksum and the size are counted on the way. The copies (secondary, tertiary)
get the object from the primary the same way, as a stream. If the dump fails half-way, the half-uploaded
object is removed, not left looking like a backup; a transient storage error starts the dump again
(`S3_UPLOAD_TRIES`).

**Redis is the exception**: `redis-cli --rdb` cannot write a clean stream to stdout, so the client keeps the
RDB inside its container (in Docker's own storage on this host) until it is sent, then the container is
removed.

### Setting one up

In the menu: `sudo docker-backup-s3` → **Remote databases** → add. It asks for the type, the host, the
port, the user, the password, the database and TLS, saves them to `backup.conf` and checks the login at
once. The same in `backup.conf` by hand:

```bash
REMOTE_DBS="shop cache"                     # the names: lower-case letters, digits, - and _
REMOTE_DB_SHOP_TYPE="postgres"              # postgres, mysql, mariadb, mongo, redis
REMOTE_DB_SHOP_HOST="db.example.com"
REMOTE_DB_SHOP_USER="backup"
REMOTE_DB_SHOP_PASSWORD="…"                 # or REMOTE_DB_SHOP_PASSWORD_FILE=/root/shop.pass
REMOTE_DB_SHOP_DATABASE="shop"              # empty — all databases
REMOTE_DB_SHOP_SSL="true"
REMOTE_DB_CACHE_TYPE="redis"
REMOTE_DB_CACHE_HOST="10.0.0.5"
REMOTE_DB_CACHE_PASSWORD_FILE="/root/cache.pass"
```

| Field (`REMOTE_DB_<NAME>_…`) | Default | What it does |
|---|---|---|
| `TYPE` | — | **required**: `postgres`, `mysql`, `mariadb`, `mongo` or `redis` |
| `HOST` | — | **required**: a name or an address; for mongo a `mongodb://` or `mongodb+srv://` URI works too (without the password in it) |
| `PORT` | the type's own | 5432, 3306, 27017, 6379 |
| `USER` | `postgres` / `root`; mongo and redis: none | the login |
| `PASSWORD` / `PASSWORD_FILE` | empty | the password, or a file holding it (the first line); not both |
| `DATABASE` | empty — all | one database (`pg_dump`, `--databases`, `--db`); empty — `pg_dumpall`, `--all-databases`, everything in mongo |
| `SSL` | `false` | `true` — an encrypted connection; most managed services require it |
| `IMAGE` | `postgres:18-alpine`, `mysql:8.4`, `mariadb:11.4`, `mongo:8`, `redis:7-alpine` | the client image; it must not be older than the server (`pg_dump` refuses that) |
| `NETWORK` | `host` | the client container's Docker network |
| `ARGS` | empty | more arguments for the dump tool, e.g. `--no-owner` |
| `TIMEOUT` | `14400` | seconds for the whole dump |
| `MAX_SIZE` | empty | the compressed dump's rough size, e.g. `200G`: needed past 50 GB, since an upload from a stream is cut into at most 10000 parts and their size is picked from this |

`<NAME>` is the name in capitals with `-` as `_` (`shop-db` → `SHOP_DB`). The user needs read access to
everything it dumps: `pg_dumpall` wants a superuser (a managed service may not give one — set `DATABASE`
then); `mysqldump`/`mariadb-dump` need `SELECT`, `SHOW VIEW` and `TRIGGER`; Redis needs the right to start
a replication sync, which some managed services do not allow.

`validate-config.sh` (and the menu's **Test** item) checks every field and logs in with the same client:
`logged in — PostgreSQL 17.6 …` or `cannot log in — password authentication failed …`.

### In the storages and in the tools

Each one is a project named `_db_<name>`:

```
backups/_db_shop/2026-05-12_03-00-00/_db_shop__2026-05-12_03-00-00.sql.gz          (.gpg if encrypted)
backups/_db_shop/2026-05-12_03-00-00/_db_shop__2026-05-12_03-00-00.sql.gz.sha256
backups/_db_cache/2026-05-12_03-00-00/_db_cache__2026-05-12_03-00-00.rdb.gz
```

(MongoDB: `.archive.gz`, from `mongodump --archive --gzip`.) Rotation, sync and `status.sh` treat it like
any other project; `drop-project.sh` refuses to remove it while the name is still in `REMOTE_DBS`.

- **Back up one now**: `sudo docker-backup-s3 backup -p db:shop` (`-p db:shop,myapp` mixes them). A full run
  dumps them all after the compose projects; a failed one is reported like a failed project.
- **Check one**: `verify-restore.sh -p _db_shop` streams the dump back, checks the checksum, decrypts and
  unpacks it without saving it, and says what it is (`PostgreSQL dump, intact`).
- **Restore**: `docker-restore.sh` saves the dump (`600`) and loads nothing — the database is not on this host,
  and overwriting it should be your decision. It prints the command to load it, e.g.:

  ```bash
  sudo docker-restore.sh -p _db_shop --extract-to /root/restore
  gunzip -c /root/restore/_db_shop__….sql.gz | psql -h db.example.com -U backup -d shop   # asks for the password
  ```

**Very large managed databases.** A logical dump of a multi-terabyte database takes hours and loads the
server while it runs; restoring it takes longer still. For such a database your provider's own snapshots
or point-in-time recovery are the main backup: they are taken in seconds and restored as a whole. A dump
here is then a second, independent copy — in your own storages, readable without the provider.

---

## First run

### Dry-run first (recommended)

```bash
sudo /opt/docker-backup-s3/docker-backup.sh --dry-run
```

Shows the plan without real actions — which projects were found, which volumes will be backed up, which bind mounts are blacklisted, whether there are databases to auto-dump.

### Real run

```bash
sudo /opt/docker-backup-s3/docker-backup.sh
```

You should see (shortened):
```
[2026-05-12 10:32:50] 🚀 Starting Docker backup. Timestamp: 2026-05-12_10-32-50
[2026-05-12 10:32:50] ▶ 🔍 Scanning compose projects...
[2026-05-12 10:32:50] ✓ From labels: myapp -> /opt/myapp
[2026-05-12 10:32:50] 📦 Compose projects found: 1
[2026-05-12 10:32:50] 📦 Standalone containers: 0
[2026-05-12 10:32:51] ▶ 🔌 Checking access to the primary S3...
[2026-05-12 10:32:52] ✓ Primary S3 is reachable
[2026-05-12 10:32:52] 📦 Project: myapp  (/opt/myapp)
[2026-05-12 10:32:52]     🐘 PostgreSQL: myapp-postgres-1 -> postgres_myapp-postgres-1_2026-05-12_10-32-50.sql.gz
[2026-05-12 10:32:52]       user postgres
[2026-05-12 10:32:56] ✓     PostgreSQL dump done: 4.2M
[2026-05-12 10:32:56]   📊 Auto-dump: 1 succeeded, 0 failed
[2026-05-12 10:32:56]   💾 Backing up volumes (parallel=2)...
[2026-05-12 10:32:56]     💾 Volume: myapp_pgdata
[2026-05-12 10:33:40] ✓   Volumes backed up: 1/1
[2026-05-12 10:33:40]   📂 Backing up the whole project folder: /opt/myapp
[2026-05-12 10:33:41]   📦 Packing the project into a single archive...
[2026-05-12 10:33:41]   🔐 Encrypting the archive...
[2026-05-12 10:33:43]   ☁  Uploading to the primary S3: s3://my-backups/backups/myapp/2026-05-12_10-32-50/myapp__2026-05-12_10-32-50.tar.gz.gpg
[2026-05-12 10:35:02]   🔍 Checking the integrity of the uploaded object...
[2026-05-12 10:35:03] ✓ Size in S3 matches: 14647301 bytes
[2026-05-12 10:35:05] ✅ myapp  (size: 14M, time: 2m 13s)
[2026-05-12 10:35:05] 🧹 Cleanup in primary S3: older than 30 days, keeping the last 3
[2026-05-12 10:35:06]   Deleted: 1, kept: 9
[2026-05-12 10:35:06] ✅ Backup finished. Timestamp: 2026-05-12_10-32-50
[2026-05-12 10:35:06]     Projects:  1/1
[2026-05-12 10:35:06]     Uploaded:  14 MB
[2026-05-12 10:35:06]     Time:      2m 16s
```

---

## Backing up a single project

For urgent jobs (before a migration, after a critical change and the like) you can back up one or several specific projects:

```bash
# Only one project
sudo /opt/docker-backup-s3/docker-backup.sh -p myapp

# Several projects, comma-separated
sudo /opt/docker-backup-s3/docker-backup.sh -p myapp,otherapp

# Dry-run for one project
sudo /opt/docker-backup-s3/docker-backup.sh -p myapp --dry-run

# Just the names of the projects found on this host (the menu builds its list from this)
sudo /opt/docker-backup-s3/docker-backup.sh --list
```

### Behavior with `-p`

- Only the given projects are backed up
- Standalone containers (no compose) are skipped
- **Rotation of old backups is skipped** (protection against accidentally deleting others')
- If a requested project is not found — the script prints an error with a hint about what is on the host

### Examples

```bash
# Before an application update — an urgent backup
sudo /opt/docker-backup-s3/docker-backup.sh -p my-critical-app

# After a big migration — a backup of two related projects
sudo /opt/docker-backup-s3/docker-backup.sh -p users-service,payments-service

# Check that a new project shows up in the plan
sudo /opt/docker-backup-s3/docker-backup.sh -p new-project --dry-run
```

---

## Restore verification

A backup that was never checked is a hope, not insurance. Use `verify-restore.sh`:

```bash
# Quick check (head-object: the object is there and non-empty, no download)
sudo /opt/docker-backup-s3/verify-restore.sh --quick

# Standard — downloads, unpacks, checks the SQL dumps (default)
sudo /opt/docker-backup-s3/verify-restore.sh

# One project in detail
sudo /opt/docker-backup-s3/verify-restore.sh -p myapp

# No notifications (for interactive use)
sudo /opt/docker-backup-s3/verify-restore.sh --no-notify

# Check the copy in the tertiary S3 rather than the primary
sudo /opt/docker-backup-s3/verify-restore.sh --from tertiary
```

### What the standard mode checks

- ✅ The object exists in S3 (head-object)
- ✅ The downloaded size matches S3
- ✅ The checksum matches the `.sha256` manifest
- ✅ GPG decryption works (if encrypted)
- ✅ tar.gz integrity via `tar tzf`
- ✅ The archive structure (the expected subfolders are there)
- ✅ The integrity of every volume inside
- ✅ The integrity of the DB dumps:
  - PostgreSQL: gzip + magic header (`PostgreSQL database dump`)
  - MySQL/MariaDB: gzip + the `mysqldump`/`mariadb-dump` header (MariaDB 10.11.8+/11 start with a sandbox line first)
  - Redis: gzip + RDB magic (`REDIS`)
  - MongoDB: gzip

### Setting up a regular check

Once a week via cron:

```cron
0 4 * * 0  /opt/docker-backup-s3/verify-restore.sh --quick >> /var/log/docker-backup-verify.log 2>&1
```

Or once a month with a detailed check:
```cron
0 5 1 * *  /opt/docker-backup-s3/verify-restore.sh >> /var/log/docker-backup-verify.log 2>&1
```

On an error it sends a notification to the configured channels.

---

## GPG encryption

Archives are encrypted symmetrically (GPG, AES-256) **before** being uploaded to S3. This protects the data even if the S3 keys or the bucket itself leak — without the passphrase an archive is a random set of bytes.

### How it works (lifecycle)

Encryption is end-to-end and the same for all storages:

1. **Creation** — the project is packed into a `tar.gz`, then (if `ENCRYPT_BACKUPS="true"`) encrypted into `*.tar.gz.gpg`. Only the encrypted file goes to S3.
2. **Upload** — the `.gpg` is uploaded to the primary S3, its size is checked via `head-object` on the `.gpg` key.
3. **Copies (secondary, tertiary S3)** — the very same `.gpg` with the same key is uploaded there, its size checked the same way.
4. **Restore** — `docker-restore.sh` recognizes an encrypted file by the `.gpg` extension, downloads it and decrypts it on the fly before unpacking (the same `GPG_PASSPHRASE_FILE` is needed).
5. **Checks** — `validate-config.sh` checks that the passphrase file exists, its permissions (600), and that `gpg` really encrypts and decrypts a test file; `verify-restore.sh` runs the full download→decrypt→unpack cycle.
6. **Rotation/deletion** — expired objects are deleted by key in every bucket, whether they are encrypted or not.

### Enabling it

The installer asks about it: it offers to encrypt with a passphrase file already on the server, or to generate one.
By hand:

**1.** Install `gpg` (the installer installs it automatically; manually — `apt install gnupg`).

**2.** Create the passphrase file (this is the "key" for symmetric GPG):
```bash
sudo bash -c 'openssl rand -base64 32 > /root/.docker-backup-passphrase'
sudo chmod 600 /root/.docker-backup-passphrase
```
`openssl rand -base64 32` generates a strong random passphrase. `chmod 600` is required — otherwise `validate-config.sh` flags it as an error.

**3.** Save the passphrase somewhere safe OFF the server — without it a restore is **impossible**:
```bash
sudo cat /root/.docker-backup-passphrase
# Put it into Bitwarden / 1Password / a password manager / a safe
```

**4.** In `backup.conf`:
```bash
ENCRYPT_BACKUPS="true"
GPG_PASSPHRASE_FILE="/root/.docker-backup-passphrase"
```

**5.** Run the backup. Archives in every storage will be `*.tar.gz.gpg`. Restore decrypts them automatically.

### Manual decryption (disaster recovery)

If you need the data without the scripts (e.g. on another machine) — download the `.gpg` from S3 and decrypt it directly with the same passphrase:
```bash
# with the passphrase file
gpg --batch --yes --passphrase-file /root/.docker-backup-passphrase \
    -o myapp__2026-05-12.tar.gz -d myapp__2026-05-12.tar.gz.gpg

# or entering the passphrase manually
gpg -o myapp__2026-05-12.tar.gz -d myapp__2026-05-12.tar.gz.gpg

tar xzf myapp__2026-05-12.tar.gz
```

### ⚠️ Important about losing the passphrase

Without the passphrase, encrypted backups are lost for good. **Keep a copy of the passphrase in at least two places off the server.** After a passphrase change, old archives still decrypt only with the old passphrase — the new one won't work.

---

## Notifications

The easiest way: `sudo docker-backup-s3` → **Notifications**. Each channel is set up there with a test message, and
the same wizards run in `install.sh`. By hand, in `backup.conf`:

### Telegram

**1.** Create a bot via [@BotFather](https://t.me/BotFather):
- `/newbot` → name → username
- Get the token: `123456:ABC-DEF...`

**2.** Find out your chat_id via [@userinfobot](https://t.me/userinfobot):
- Send it `/start` → you get `Id: 123456789`

**3. CRITICAL** — Open a chat with your bot and send `/start`. Without this the bot can't message you.

**4.** In `backup.conf`:
```bash
TELEGRAM_BOT_TOKEN="123456:ABC-DEF..."
TELEGRAM_CHAT_ID="123456789"
NOTIFY_ON="error"   # or "always"
```

**5.** Check:
```bash
sudo /opt/docker-backup-s3/validate-config.sh
```

The script sends a test message and shows the result, with diagnostics if something is wrong.

### If Telegram doesn't work

| Error | Cause | Fix |
|---|---|---|
| `chat not found` | You didn't send the bot `/start` | Open the bot → Start |
| `chat not found` | Wrong chat_id | Check it via `@userinfobot` |
| `Forbidden: bot was blocked` | The bot was blocked | Unblock it |
| `bot is not a member` | A group without the bot | Add it as an admin |
| `Unauthorized` | Invalid token | Get a new one via `@BotFather` |

### Webhook (Discord, Slack, Mattermost, custom)

```bash
NOTIFY_WEBHOOK_URL="https://discord.com/api/webhooks/123/abc"
NOTIFY_WEBHOOK_FORMAT="auto"
```

The payload depends on `NOTIFY_WEBHOOK_FORMAT`. With `auto`, Discord and Slack URLs are recognized and everything else
gets `json`:

| Format | Payload | For |
|---|---|---|
| `discord` | `{"content": "..."}` with **bold** and `code` | Discord |
| `slack` | `{"text": "..."}` with Slack markup | Slack, Mattermost, Rocket.Chat |
| `json` | `{"text", "level", "server", "title", "details", "time"}` | your own receiver |

`level` is `error`, `warn` or `success`, and `time` is UTC. A reply other than 2xx counts as a failure and goes to the log;
the other channels are still sent.

### Email (SMTP)

curl sends the message straight to your SMTP server, so no mail server is needed on the host. Any account works: your
own mail server, a mail service, Gmail or Outlook with an app password.

```bash
EMAIL_TO="admin@example.com ops@example.com"
SMTP_HOST="smtp.example.com"
SMTP_SECURITY="starttls"     # starttls (587), tls (465) or none (25)
SMTP_USER="backup@example.com"
SMTP_PASSWORD="..."
SMTP_FROM="backup@example.com"
```

The subject is the notification line (`🔴 Server web-1: backup with errors`), and the body has a plain-text and an
HTML part. The password goes to curl in a temporary file, not on the command line. `validate-config.sh` sends a test
email. Many hosting providers block outgoing port 25, so use 587 or 465.

### Notification levels

- `none` — never
- `error` — problems only: errors and warnings (recommended)
- `always` — every run

---

## Scheduled runs (cron/systemd)

```bash
sudo /opt/docker-backup-s3/setup-cron.sh
```

An interactive wizard: you pick the method (cron / systemd timer) and a schedule preset.

### Presets

| Preset | Schedule |
|---|---|
| `daily` | Every day at 03:00 |
| `twice` | Twice a day (04:00 and 16:00) |
| `6h` | Every 6 hours |
| `weekdays` | Weekdays at 02:00 |
| `weekly` | Sunday 03:00 |

### Without interaction

```bash
sudo /opt/docker-backup-s3/setup-cron.sh -m cron -s daily -y
sudo /opt/docker-backup-s3/setup-cron.sh -m systemd -s '*-*-* 04:30:00' -y
sudo /opt/docker-backup-s3/setup-cron.sh --status    # current status
sudo /opt/docker-backup-s3/setup-cron.sh --remove    # remove
```

If scheduled runs are already set up (cron or a systemd timer — either one):

- **without `-y`** — the script shows the current setup and asks whether to replace it;
- **with `-y`** — it replaces it without asking and finally prints "Scheduled runs replaced: was … → now …".

The old job is removed only after the new schedule has been checked and confirmed:
an invalid cron format or a "no" to "Apply?" leaves the previous scheduled runs as they were. The method can
be changed at the same time: `-m systemd` over a cron job removes cron and installs the timer, and vice versa.

`install.sh -y` leaves already configured scheduled runs alone (otherwise they would be replaced with the default
daily one) — the schedule changes only with an explicit `setup-cron.sh` call.

### What goes into the crontab under the hood

```cron
# === Docker backup ===
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin
MAILTO=""
0 3 * * * /opt/docker-backup-s3/docker-backup.sh >> /var/log/docker-backup-cron.log 2>&1
# === /Docker backup ===
```

### Testing the cron environment

```bash
sudo env -i \
    SHELL=/bin/bash \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin \
    HOME=/root \
    /opt/docker-backup-s3/docker-backup.sh
```

### Diagnosing cron problems

If `setup-cron.sh` or `install.sh` warns "Cron is not installed" although it works (e.g. on Ubuntu 24.04), run:

```bash
sudo /opt/docker-backup-s3/diagnose-cron.sh
```

It shows:
- Which paths to the cron binary the script sees
- What `pgrep` shows for different process name variants
- The state of the systemd units (cron, cron.service, crond, crond.service, cronie, cronie.service)
- The list of processes with "cron" in the name
- The current crontab

Useful for debugging if cron auto-detection works incorrectly.

---

## Restoring from a backup

### See what is in S3

```bash
sudo /opt/docker-backup-s3/docker-restore.sh --list
sudo /opt/docker-backup-s3/docker-restore.sh --list --project myapp
```

### Interactive mode

```bash
sudo /opt/docker-backup-s3/docker-restore.sh
```

1. Shows the list of projects with details (backups / latest / age)
2. Accepts a multi-select: `3` / `1,3,5` / `1-7` / `1-3,5,7-9` / `all`
3. Asks for the date for each selected project
4. Shows the plan + an overwrite warning
5. Downloads, decrypts, unpacks, restores
6. Starts the project (`docker compose -p <project> -f <file> up -d`), only if every volume and folder came back

### Non-interactively

```bash
# One project
sudo /opt/docker-backup-s3/docker-restore.sh \
    -p myapp \
    -t 2026-05-12_03-00-00 \
    -y

# Several projects with the same date
sudo /opt/docker-backup-s3/docker-restore.sh \
    -p myapp,otherapp \
    -t 2026-05-12_03-00-00 \
    -y
```

### A test in /tmp without starting

```bash
sudo /opt/docker-backup-s3/docker-restore.sh \
    --dir /tmp/test-restore \
    --no-start
```

⚠️ Volumes are restored under their real names — they will overwrite the existing ones. For a fully isolated test use a separate server with a read-only S3 key, or `verify-restore.sh`.

### Partial restore

The most common scenario is not "the server burned down" but "the wrong table was dropped at 15:00". There's no need to deploy the whole project and overwrite the running production for that.

**See what is inside a backup:**

```bash
sudo /opt/docker-backup-s3/docker-restore.sh -p myapp --contents
```

Shows the metadata, the list of named volumes with sizes, bind mounts and the database dumps inside `project_dir.tar.gz`. Downloads nothing to the host beyond a temporary folder and changes nothing.

**Get a single database dump (restoring nothing):**

```bash
sudo /opt/docker-backup-s3/docker-restore.sh -p myapp --extract-to /tmp/restore -y
tar xzf /tmp/restore/project_dir.tar.gz -C /tmp/restore
ls /tmp/restore/myapp/db-dumps/
```

Then load the dump manually — e.g. `gunzip -c dump.sql.gz | docker exec -i myapp-db-1 psql -U postgres`.

**Restore a single volume only:**

```bash
sudo /opt/docker-backup-s3/docker-restore.sh -p myapp --only-volume myapp_pgdata -y
```

The project folder, bind mounts and the other volumes are not touched, `docker compose up` is not run. If the volume is used by running containers — the script warns; better stop them.

The `--contents` and `--extract-to` modes change nothing on the host and ask for no confirmation.

### How volumes are restored

A restore goes in three steps, and the destructive one is the last:

1. the archive is checked for readability (`tar tzf`);
2. it is unpacked into a **temporary** volume;
3. and only after that succeeds, the working volume's contents are replaced.

If the archive turns out to be broken or the disk runs out of space, the working volume stays untouched. The data used to be deleted by the same command that unpacked the archive, so a damaged archive meant losing both the old copy and the new one — and it came out in the middle of an incident.

### Restoring from a copy (secondary, tertiary)

If the primary S3 is unavailable, read the same copy from the secondary or tertiary S3. The source can be picked in two ways:

- **Interactively** — if at least one copy is enabled, `docker-restore.sh` in interactive mode asks where to restore from:
  ```
  Where to restore from?
    1) Primary S3 (https://s3.example.com)
    2) Secondary S3 (https://s3.other-provider.com)
    3) Tertiary S3 (https://s3.third-provider.com)
  Choice [1]:
  ```
- **With the `--from ROLE` flag** — forced from the storage you need (handy for scripts and `-y` mode); `--from-secondary` is a short form of `--from secondary`:

```bash
# List the backups in the tertiary S3
sudo /opt/docker-backup-s3/docker-restore.sh --from tertiary --list

# Restore a project from the secondary S3
sudo /opt/docker-backup-s3/docker-restore.sh --from secondary -p myapp -t 2026-05-12_03-00-00 -y
```

Source priority: the `--from` flag → the interactive choice → the primary S3 by default. The copy must be enabled (`<ROLE>_S3_ENABLED="true"`) and filled in. Reading uses the storage's read-only key (`<ROLE>_S3_RESTORE_*`) if set, otherwise that storage's main key. Since the object key is the same in every storage, the restore is fully transparent.

`verify-restore.sh --from ROLE` likewise checks that a copy can be restored, rather than the primary.

---

## System status

```bash
sudo /opt/docker-backup-s3/status.sh
```

Shows on one screen:
- **Compose projects on the host** — list, container states, databases for auto-dump
- **Backups in each storage** — latest, oldest, size, per project; for copies — the object count compared with the primary
- **Rotation** — what will be deleted on the next run
- **Scheduled runs** — whether cron / a systemd timer is set up, when it fires
- **Configuration** — mode, retention, encryption, auto-dump
- **Resources** — free space, the lock file, active processes
- **Latest log entries** — a preview + errors

Color markers:
- ● green — OK
- ● yellow — attention (backup older than 24h, disk > 80%)
- ● red — a problem (no scheduled runs, S3 unreachable)

---

## Logs

Two files:
- `/var/log/docker-backup.log` — the script's own log
- `/var/log/docker-backup-cron.log` — stdout/stderr of cron/systemd runs

### With `logs.sh`

```bash
# The last 50 lines, highlighted
sudo /opt/docker-backup-s3/logs.sh

# Follow in real time
sudo /opt/docker-backup-s3/logs.sh -f

# Errors only
sudo /opt/docker-backup-s3/logs.sh -e

# The whole last run (from 🚀 to ✅)
sudo /opt/docker-backup-s3/logs.sh -l

# Entries about a specific project
sudo /opt/docker-backup-s3/logs.sh -p myapp

# For the last 2 hours
sudo /opt/docker-backup-s3/logs.sh -s '2 hours ago'

# All errors for today
sudo /opt/docker-backup-s3/logs.sh -e -s today

# The main log only
sudo /opt/docker-backup-s3/logs.sh -b

# The cron log only
sudo /opt/docker-backup-s3/logs.sh -C

# No limit
sudo /opt/docker-backup-s3/logs.sh -n 0
```

### Viewing directly

```bash
sudo tail -50 /var/log/docker-backup.log
sudo tail -f /var/log/docker-backup.log
sudo grep -iE 'ERROR|❌|FAIL' /var/log/docker-backup.log
```

### Log rotation

Via logrotate (installed automatically by `install.sh` or `setup-cron.sh`):
- Weekly rotation
- 8 archives (≈2 months of history)

Check:
```bash
cat /etc/logrotate.d/docker-backup
sudo logrotate -d /etc/logrotate.d/docker-backup  # dry-run
```

---

## Backup rotation

At the end of every successful backup, expired objects are deleted. What to delete is decided by a single function (`plan_rotation` in `lib.sh`) — the same one `status.sh` uses for its forecast, so "N objects will be deleted" always matches what actually happens.

### The floor: `KEEP_MIN_BACKUPS`

```bash
KEEP_MIN_BACKUPS=3
```

This many latest backups of each project are **never** deleted, regardless of age. Without it, this scenario plays out: a project is renamed or decommissioned, no new backups are written under the old name, the old ones quietly age — and on day 31 rotation deletes its entire history, which from the script's point of view is normal operation. The same happens if backups failed for longer than `RETENTION_DAYS`.

In addition, rotation is **skipped entirely** if the run has not a single successful backup: since something system-wide is broken (S3, disk, docker), the old copies are all that's left.

### Retention scheme

**Flat** (default) — everything younger than `RETENTION_DAYS`:

```bash
GFS_ENABLED="false"
RETENTION_DAYS=30
```

**GFS (grandfather-father-son)** — one backup per day, week and month:

```bash
GFS_ENABLED="true"
GFS_DAILY=7      # 7 daily
GFS_WEEKLY=4     # 4 weekly
GFS_MONTHLY=6    # 6 monthly
```

With `GFS_ENABLED="true"`, `RETENTION_DAYS` is not used — retention is set by these three numbers. The point is to have a copy half a year old without keeping 180 daily archives: with daily backups the 7/4/6 scheme keeps about 15 copies instead of 180. This matters when data corruption is not noticed right away — with a flat 30 days there is simply nothing older than a month.

A slot is taken by the newest backup of the day/week/month; weeks are ISO weeks (Monday is the start).

### Details

- Age is taken from the **timestamp in the key** (`…/YYYY-MM-DD_HH-MM-SS/…`) — that is, the real backup date, not the object's `LastModified`. Thanks to that, all storages rotate the same even if an object was uploaded to a copy later (e.g. filled in by `sync-s3.sh`). If no timestamp is found in the key, `LastModified` is the fallback.
- The unit of deletion is **the whole backup**: the archive and its `.sha256` file live and are deleted together.
- Runs **only after a successful backup**
- Cleans **all** storages — the primary and every enabled copy
- Deletion is **irreversible** — most S3s have no recycle bin
- With `--project NAME` rotation is **skipped** (protection against accidentally deleting others')

### Changing the retention

```bash
sudo nano /opt/docker-backup-s3/backup.conf
# RETENTION_DAYS=90  # three months
```

To see what will be deleted on the next run, without deleting anything:

```bash
sudo /opt/docker-backup-s3/status.sh
```

### Checksums

```bash
CHECKSUM_MANIFEST="true"
```

A `.sha256` file is placed next to every archive in S3. Matching sizes only prove that the upload wasn't cut short — a corrupted object of the same length doesn't show in its size. The manifest lets `docker-restore.sh` (before a restore), `verify-restore.sh` (during regular checks) and `sync-s3.sh` (before copying an object to a copy — otherwise the corruption spreads there and is taken as normal) catch corruption.

Backups made before manifests existed are checked as before, by size.

### What is in S3

```bash
source /opt/docker-backup-s3/backup.conf
export AWS_ACCESS_KEY_ID="$PRIMARY_S3_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$PRIMARY_S3_SECRET_KEY"

aws --endpoint-url "$PRIMARY_S3_ENDPOINT" $PRIMARY_S3_OPTS_EXTRA \
    s3api list-objects-v2 --bucket "$PRIMARY_S3_BUCKET" --prefix "backups/" \
    --query 'Contents[].[LastModified,Size,Key]' --output table
```

---

## Uninstalling

```bash
# Safely (S3 is KEPT)
sudo /opt/docker-backup-s3/uninstall.sh

# No questions
sudo /opt/docker-backup-s3/uninstall.sh -y

# See what would happen
sudo /opt/docker-backup-s3/uninstall.sh --dry-run

# Remove + logs
sudo /opt/docker-backup-s3/uninstall.sh -y --purge-logs

# ⚠ FULL cleanup (including S3 — every storage whose keys and bucket are filled in; irreversible)
sudo /opt/docker-backup-s3/uninstall.sh --purge-s3 --purge-logs
# Asks you to type 'DELETE ALL BACKUPS'
```

### What is removed

- ✅ Files in `/opt/docker-backup-s3/`
- ✅ The cron job
- ✅ Systemd timer + service
- ✅ `/etc/logrotate.d/docker-backup`
- ✅ `/usr/local/bin/docker-backup-s3` (only if it is the link to this installation)
- ✅ The lock file
- ✅ The temporary folder

### What is NOT removed

- ❌ **A copy of `backup.conf`**: it stays as `/root/docker-backup.conf.saved-<time>` (mode 600), and `install.sh`
  offers to take it over on a reinstall. Delete it yourself once it is not needed: it holds the S3 keys.
- ❌ **Backups in S3** (only with `--purge-s3`)
- ❌ Logs (only with `--purge-logs`)
- ❌ GPG passphrase
- ❌ Dependencies (docker, aws-cli, jq, ...)
- ❌ `pre-backup-hook.sh` in projects
- ❌ `db-dumps/` folders in projects

### Safeguards

- Shows what was found when it starts
- Refuses while a backup is running (an active lock pid): nothing is removed, exit code 1
- `--purge-s3` requires typing `DELETE ALL BACKUPS`
- `--dry-run` shows the plan without executing it

---

## Security

### Where your keys and passwords live

**Everything stays on your server and in your own storages.** docker-backup-s3 has no server of its own,
no account, no telemetry, no update checks and no "phone home": it is a set of Bash scripts that talk
only to the addresses you put into `backup.conf`.

**What leaves the server, and where to**

| Where to | What | When |
|---|---|---|
| Your S3 storages (the endpoints you set) | The backup archives (encrypted with your passphrase if `ENCRYPT_BACKUPS=true`), their `.sha256` manifests | Backup, rotation, sync, restore, checks |
| Your Telegram bot, webhook or SMTP server — only the ones you set | The text of a notification: project names, sizes, times, error reasons. Never a key, a password or file contents | After a run, when a notification is due |
| `awscli.amazonaws.com`, your distribution's package mirrors | Nothing of yours: `install.sh` downloads aws-cli and packages from there | Installation |

Nothing else. You can check it: `grep -rnoE 'https?://[a-zA-Z0-9.-]+' *.sh` lists every address in the code.

**Where each secret is kept on the server, and who reads it**

| Secret | Where | Who can read it |
|---|---|---|
| S3 keys, the Telegram token, the webhook URL, the SMTP password | `backup.conf` | root only (`chmod 600`, set by `install.sh`; `validate-config.sh` warns if it is not) |
| The GPG passphrase | `GPG_PASSPHRASE_FILE` (`/root/.docker-backup-passphrase`) | root only (`600`); gpg reads it from the file, never from an argument |
| Database passwords | Where they already are: your containers' environment and secret files | Read **inside** the database container at dump time (see below); never copied to the host |
| Remote database passwords | `backup.conf`, or the file `REMOTE_DB_<NAME>_PASSWORD_FILE` points to | root only (`600`) |
| Database dumps | `<project>/db-dumps/` | root only: the folder is `700`, the dumps are `600` |
| An archive being built, downloaded or checked | `WORK_DIR` (`/var/tmp/docker-backup`) | root only: each run works in its own `700` folder, removed afterwards |

**Never on a command line.** Any user of a Linux host can see every process's command line (`ps aux`),
so no secret is ever passed as an argument:

- S3 keys go to `aws` through its environment (readable by root only), not as options.
- The Telegram token and the webhook URL (Discord and Slack put their secret in it) go to `curl` as a config
  on a pipe (`curl -K <(…)`); the SMTP password — in a temporary `600` config file, removed right after.
- Database passwords are read and used **inside the database container**, by a short `sh` script run with
  `docker exec`: from the same variables the image uses (`POSTGRES_PASSWORD`, `MYSQL_ROOT_PASSWORD`,
  `MONGO_INITDB_ROOT_PASSWORD`…) or the files their `*_FILE` twins point to (Docker secrets), and handed to
  the dump tool in its environment (`PGPASSWORD`, `MYSQL_PWD`, `REDISCLI_AUTH`) or on its stdin (`mongodump`).
  A Redis password given only as `redis-server --requirepass …` is taken from the container's settings and
  passed to `docker exec` through the environment (`-e NAME` without a value), not as an argument.
- A remote database's password goes to its client container through the environment: exported in a subshell
  and passed as `-e PGPASSWORD` (`MYSQL_PWD`, `REDISCLI_AUTH`) without a value; `mongodump` reads it on its stdin.
  The container runs with `--log-driver none`, so the dump passing through it is not kept in Docker's log either.
- Hooks (`pre-backup-hook.sh`) run without the S3 keys in their environment.

**Never in the log or in a notification.** Messages say which account a dump used (`user app`) and why
something failed (`Access denied`, `WRONGPASS`), never a password. `validate-config.sh` shows the first and
last four characters of an access key and only the length of a secret key.

**Keep in mind**

- **The archive contains your project as it is**: its `.env`, its compose files, the database dumps, and
  `docker inspect` of each container — with the containers' environment, passwords included (the restore
  needs it). That is what a backup is; so the storage keys are as sensitive as the server itself.
  Turn on [GPG encryption](#gpg-encryption): then the storage only ever sees ciphertext, and a leaked
  storage key does not leak the data.
- **Restore servers** should get a read-only key (`<ROLE>_S3_RESTORE_ACCESS_KEY`): it can read backups,
  but cannot delete them.
- The **test** of a channel or a storage in the menu sends exactly what a real run would, to the same place.

The tests check this: [`tests/databases/run.sh`](tests/databases/run.sh) watches the command line of every
process on the host while it dumps real Postgres, MySQL, MariaDB, Redis, Valkey, KeyDB and MongoDB servers,
and fails if any password shows up there or in the log.

### Recommendations

1. **`chmod 600` on `backup.conf`** — required, it holds secrets (install.sh does it automatically)
2. **A read-only key for the restore server** in `<ROLE>_S3_RESTORE_ACCESS_KEY` (`PRIMARY_…`, `SECONDARY_…`, `TERTIARY_…`) — protection against deletion from dev/staging
3. **GPG encryption** for critical data
4. **A backup copy of the GPG passphrase** in bitwarden/1password — without it a restore is impossible
5. **If a key leaks** — reissue it in the provider's panel right away

### What the script protects against

- A double start (lock via mkdir — an atomic operation)
- A bind-mount blacklist against accidentally backing up `/`
- Renaming the folder to `.before-restore-EPOCH` before a restore
- An integrity check after upload (size via head-object, the `sha256` manifest) and retries of transient upload errors
- In `uninstall.sh` — S3 is not touched without explicit confirmation
- In `update.sh` — the syntax of the new files is checked before replacing
- In `docker-backup.sh -p` — rotation is skipped so others' backups aren't deleted

---

## Troubleshooting

### `bash: $'\r': command not found`

CRLF from Windows:
```bash
sudo dos2unix /opt/docker-backup-s3/*.sh /opt/docker-backup-s3/*.conf
```

### `SSL: CERTIFICATE_VERIFY_FAILED`

Usually it doesn't come to this: the installer checks the bucket itself and sets `--ca-bundle` on this error
(see [S3 certificate check during installation](#s3-certificate-check-during-installation)), and
`validate-config.sh`, on this error for a bucket, tries the system CA bundle and, if that
works, prints a ready line for `backup.conf`. Manually:

First check whether the system trusts the certificate: `curl -sS -o /dev/null -w "%{ssl_verify_result}\n" "$PRIMARY_S3_ENDPOINT"`.
`0` — the certificate is valid, and aws (especially from snap) has its own outdated CA bundle. Give it the system one
(for copies — `SECONDARY_S3_OPTS_EXTRA`, `TERTIARY_S3_OPTS_EXTRA`):
```bash
PRIMARY_S3_OPTS_EXTRA="--ca-bundle /etc/ssl/certs/ca-certificates.crt"
```
That happens with storages whose certificate chains to the GlobalSign Root R46 root: it is in Ubuntu, but not in the aws bundle.

Do not set `--no-verify-ssl`: without verification the storage can be spoofed, and "file accepted" would be
a lie. If curl doesn't trust it either — the certificate really is self-signed: add its root to the
system bundle (`/usr/local/share/ca-certificates/` + `update-ca-certificates`) instead of disabling verification.

### `SSL: UNEXPECTED_EOF_WHILE_READING` on `?uploads` or an empty `An error occurred () when calling the PutObject operation`

Newer aws-cli (since 2.23) sends a new-style checksum with every upload, and some
S3-compatible storages (it has been seen) drop the connection on it. The scripts set
`AWS_REQUEST_CHECKSUM_CALCULATION=when_required` and `AWS_RESPONSE_CHECKSUM_VALIDATION=when_required`
themselves (`lib.sh`, `diagnose-s3.sh`). If the error is still there — update the scripts (`update.sh`).

### `make_bucket failed: argument of type 'NoneType' is not a container or iterable`

AWS CLI often cannot create a bucket on S3-compatible storages. Create the bucket by hand in the provider's panel.

### `aws: command not found` in cron

The crontab has no `PATH=` line (by default cron only looks in `/usr/bin:/bin`). Use `setup-cron.sh` — it writes `PATH` itself: `/usr/local/bin` (the official aws) before `/snap/bin`. `validate-config.sh` shows which `aws` cron will find.

### False warning "Cron is not installed"

If `setup-cron.sh` or `install.sh` says cron is not installed — while it actually works (typical on Ubuntu 24.04):

```bash
sudo /opt/docker-backup-s3/diagnose-cron.sh
```

The script shows exactly what auto-detection sees. Most likely the `cron` binary is in `/usr/sbin/cron` and the process is running (`pgrep -x cron` finds it) — then there should be no warning. If it shows up anyway — please open an issue with the output of `diagnose-cron.sh`.

### `install.sh` in-place doesn't offer to fill in the conf

This depends on the state of `backup.conf`:
- If `PRIMARY_S3_ACCESS_KEY`, `PRIMARY_S3_SECRET_KEY`, `PRIMARY_S3_BUCKET` hold real values (not `YOUR_...`, not empty) — the installer considers the conf ready and doesn't ask
- If at least one field is a placeholder — in interactive mode it offers "Fill in the settings now?"
- If run with `-y` — it only warns and doesn't intervene

Check manually:
```bash
sudo grep -E "^PRIMARY_S3_(ACCESS_KEY|SECRET_KEY|BUCKET)=" /opt/docker-backup-s3/backup.conf
```

If you want to force a fresh fill-in — remove the conf and run install:
```bash
sudo mv /opt/docker-backup-s3/backup.conf /opt/docker-backup-s3/backup.conf.old
sudo /opt/docker-backup-s3/install.sh
```

### The backup hangs on a huge `tar`

Some container has mounted a big path:
```bash
sudo /opt/docker-backup-s3/logs.sh -e | tail -10
```

Add it to `BIND_BLACKLIST_REGEX`. The edit is idempotent — running it again breaks nothing,
so it can be sent to all servers at once (a path that isn't on a server costs the regex
nothing). The check looks at the variable's line specifically, not the whole file: the path
may appear in a neighboring comment, and then the edit would silently not apply.

```bash
grep -q "^BIND_BLACKLIST_REGEX=.*your/path" /opt/docker-backup-s3/backup.conf || \
  sed -i "s#^\(BIND_BLACKLIST_REGEX='.*\)'#\1|^/your/path'#" /opt/docker-backup-s3/backup.conf
```

`update.sh` doesn't change the values in the working `backup.conf`, so such an edit won't spread via an update:
it has to be sent to existing servers, while new ones get it from `backup.conf.example`.

Before restarting:
```bash
sudo pkill -9 tar
docker ps --filter "status=paused" -q | xargs -r docker unpause
sudo rm -rf /var/tmp/docker-backup/*
sudo rm -rf /var/run/docker-backup.lock.d
```

### `Another instance is already running (PID: ...)`

The lock is held by another process:
```bash
ps -p <PID>  # check whether it's alive
```

If the process is dead — remove the lock:
```bash
sudo rm -rf /var/run/docker-backup.lock.d
```

### Telegram messages don't arrive

```bash
sudo /opt/docker-backup-s3/validate-config.sh
```

Sends a test message with diagnostics. The most common cause — you didn't send the bot `/start`.

### With encryption: `gpg: decryption failed`

```bash
sudo cat /root/.docker-backup-passphrase
sudo stat /root/.docker-backup-passphrase  # must be 600
```

### A restore broke in the middle

The script renames the existing folder to `<dir>.before-restore-EPOCH`:
```bash
sudo rm -rf /opt/myapp
sudo mv /opt/myapp.before-restore-1736171200 /opt/myapp
cd /opt/myapp && sudo docker compose up -d
```

### Rolling back to the previous version after an update

```bash
sudo /opt/docker-backup-s3/update.sh --rollback
```

### S3 keys were accidentally published

1. Your S3 provider's panel → access keys → change the key
2. Put the new one into `backup.conf`
3. `sudo /opt/docker-backup-s3/validate-config.sh`

---

## Tests

```bash
tests/run.sh            # all tests
tests/run.sh -v notify  # one file, every check printed
```

They need only bash, jq, python3 and the usual coreutils: no Docker, no S3 and no network, because curl is
replaced by a stub that records what it was given. `test_repo` checks that every script parses, has LF line endings and
the executable bit, and that `VERSION`, the changelog and the badge agree. `test_core` covers paths, archiving,
restore name matching, upload retries (a fake aws that fails with OperationAborted), DB dump recognition and settings
given twice. `test_dbdump` runs the database dump scripts against a `docker` stub and fake database tools (in the
system's own `sh`: dash, busybox): which account and password each one picks, the skips, the reasons in the log, and
that no password reaches the log or a command line. `test_remotedb` covers remote databases against `docker` and
`aws` stubs: the settings checks, the client's command line (never a password in it), the stream, encryption, the
part size, a failed dump that must leave nothing, the retries and the copies. `test_notify` covers every notification channel and format, `test_menu` drives the menu's notification,
project and remote database sections end to end from a file of answers, and `test_install` checks that install, update, uninstall and a reinstall
keep every value of a config, and that the installer's wizard asks about encryption. `test_menu` and `test_install`
need root (they use `sudo` or skip themselves), and `test_install` runs only in a container or in CI.

The integration test runs everything for real: Docker, a compose project with Postgres, MariaDB 11, named volumes
and bind mounts (one with an excluded folder), not named after its folder, and S3 in a container (Versity Gateway):

```bash
sudo tests/integration/run.sh       # -k keeps the containers and files for a look
```

It checks the config, makes an encrypted backup to the primary, shows its contents, runs `verify-restore.sh` and
syncs to the secondary. Then it wipes out the project (containers, volumes, folders), restores it from the
secondary and compares both databases, the volume, the bind mounts and the project folder with what was there.
It also runs a backup in `stop` mode, one with encryption switched off by a second line (a warning must come), a
Ctrl+C during the S3 access check (it must be logged and reported), and a backup with S3 down, which must fail. Remote databases: Postgres, MariaDB, MongoDB and Redis (with a password),
each in its own container, are dumped straight into both storages, checked, saved back with `docker-restore.sh`,
loaded into the emptied servers and compared; one with a wrong password must fail and be reported.
Every step's notification is checked. It needs Docker with Compose v2, AWS CLI v2, jq, python3 and gpg, and it
removes everything it created.

The distro test repeats all of that on each supported distribution, in a fresh container that shares the host's
Docker. In each one it runs `install.sh -y`, checks that every tool is there (and is the GNU one where it matters),
sets up and removes the cron job, then runs the tests and the integration test:

```bash
tests/distros/run.sh                    # all of them (a Linux host with Docker)
tests/distros/run.sh alpine:3.20        # one
```

Another architecture runs under QEMU: `DBT_PLATFORM=linux/arm64 tests/distros/run.sh debian:12`.

The database test dumps real servers: PostgreSQL 13, 16 (`scram` on the socket, the password in a `*_FILE`
secret) and 17; MySQL 8.0, 8.4 (a random root password: the app user's database) and 9; MariaDB 10.11 (the root
password in a secret, with quotes in it) and 11.4 (the app user; no password at all); Redis 6 and 7 (no password,
`--requirepass` on the command line, a config file with its own port and RDB name, the password in a variable),
Valkey 8, KeyDB; MongoDB 4.4, 7 and 8 (the password in a secret). Each dump must contain the marker written
before it, and one of each kind is loaded into a fresh server. Two exporters whose image names say
`postgres` and `redis` must be skipped, and a wrong password must fail with the reason in the log. All the
while it watches the command line of every process on the host: a password showing up there, or in the log,
fails the test.

```bash
tests/databases/run.sh              # all (pulls about 20 images)
tests/databases/run.sh 'redis*'     # some
```

The systemd test checks scheduling on a real init. It runs `install.sh` as a user would, then checks that the
cron service is active and enabled at boot and has our job. It switches to the systemd timer and checks that it
is enabled and has a next run. It starts the service itself, which must make a real backup, then sets cron to
"every minute" and waits until cron starts a backup on its own. Last, it removes the schedule and runs
`uninstall.sh`. It changes the machine it runs on, so give it a throwaway VM, or let it start containers where
systemd is PID 1:

```bash
sudo tests/systemd/check.sh             # on a throwaway VM
tests/systemd/run.sh rockylinux:9       # systemd in a container (privileged)
```

On every push GitHub Actions runs ShellCheck (warnings and errors), the tests, the integration test and the
systemd test on its own VM. The tag of the current release (the one matching `VERSION` on main), a monthly run and
manual runs also run the distro test for each distribution, the systemd test in each distribution's container, the database test and
aarch64: see `.github/workflows/ci.yml`.

---

## Versioning

The project follows [Semantic Versioning](https://semver.org/); every release is a git tag `vX.Y.Z`
with notes in [CHANGELOG.md](CHANGELOG.md). The installed version: `docker-backup-s3 version`.
`update.sh` shows which version it updates from and to.

## License

[MIT](LICENSE). Use it, change it, ship it — just keep the copyright notice.
