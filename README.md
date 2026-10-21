<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo-light.svg" alt="docker-backup-s3" width="460">
  </picture>
</p>

<p align="center">
  <b>Back up Docker Compose projects — volumes, bind mounts and database dumps — to up to three S3-compatible storages.</b><br>
  Rotation, integrity checks, restore from any copy, and a menu for all of it. Plain Bash, no agents, no daemons.
</p>

<p align="center">
  <a href="CHANGELOG.md"><img src="https://img.shields.io/badge/version-1.0.1-2496ED" alt="version 1.0.1"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-22C55E" alt="license MIT"></a>
  <img src="https://img.shields.io/badge/bash-4%2B-4EAA25?logo=gnubash&logoColor=white" alt="bash 4+">
  <img src="https://img.shields.io/badge/platform-Linux-FCC624?logo=linux&logoColor=black" alt="Linux">
  <img src="https://img.shields.io/badge/Docker%20Compose-v1%20%7C%20v2-2496ED?logo=docker&logoColor=white" alt="Docker Compose v1 | v2">
  <img src="https://img.shields.io/badge/storage-S3--compatible-0EA5A4?logo=amazons3&logoColor=white" alt="S3-compatible">
</p>

<p align="center">
  <a href="#quick-start">Quick start</a> ·
  <a href="#the-docker-backup-command-menu">The menu</a> ·
  <a href="#configuration">Configuration</a> ·
  <a href="#multiple-storages-primary--secondary--tertiary">Multiple storages</a> ·
  <a href="#restoring-from-a-backup">Restore</a> ·
  <a href="#troubleshooting">Troubleshooting</a> ·
  <a href="CHANGELOG.md">Changelog</a>
</p>

---

Every night each compose project on the server becomes one archive: its named volumes, bind mounts,
project folder and fresh database dumps (PostgreSQL, MySQL/MariaDB, Redis, MongoDB — found automatically).
The archive goes to the **primary** storage first, then to an optional **secondary** and **tertiary** one —
for example, at other providers — and each upload is checked by size and `sha256`. Endpoints, regions, keys
and buckets are set by you, so any S3-compatible storage works.

```bash
sudo git clone https://github.com/KolosovV/docker-backup-s3.git /opt/docker-backup
sudo /opt/docker-backup/install.sh      # dependencies, storages, Telegram, schedule — in dialogs
sudo docker-backup                      # the menu: status, backup, restore, checks, storages
```

## Features

### Backup
- 📦 **Compose project auto-discovery** — via docker labels and directory scanning
- 🗄️ **Automatic database dump** — PostgreSQL, MySQL/MariaDB, Redis, MongoDB; custom hooks for non-standard databases
- 💾 **Full coverage** — named volumes, bind mounts, project folders with compose files
- ☁️ **Multiple storages** — primary + up to two copies (secondary, tertiary); one archive goes to all of them, rotation cleans all of them
- 🔄 **Storage synchronization** — `sync-s3.sh` aligns the copies with the primary if they drift apart
- ⚡ **Parallel volume backup**
- 🎯 **Single-project backup** with `-p NAME` for urgent jobs
- 🚦 **Bandwidth limit** for S3 uploads
- 🔐 **GPG encryption** of archives (optional)
- 🔍 **Integrity check** — size via S3 head-object plus a `sha256` manifest next to the archive (in every storage)
- ✅ **Completeness control** — if a volume or bind mount didn't make it into the archive, the project is marked as failed, not as a "success"
- 🗂 **GFS rotation** (day/week/month) and the `KEEP_MIN_BACKUPS` floor — the latest copies are never deleted
- 🔒 **Lock** against a double start (via an atomic mkdir)
- 📡 **Notifications** to Telegram and a webhook (Slack/Discord)
- 🧪 **Dry-run** for safe testing
- 🔑 **Read-only S3 key** for restore (protection against deletion from dev/staging)
- 🛟 **Restore from any storage** — `--from secondary|tertiary` (or the interactive choice) pulls from a copy if the primary is unavailable
- 🔬 **Partial restore** — `--contents`, `--extract-to`, `--only-volume`: get a single dump or volume without touching the running project

### Management
- 🧭 **`docker-backup`** — one command with a menu for everything below (whiptail; plain prompts without it), plus subcommands for scripts
- ⚙️ **`install.sh`** — installation from scratch with one command, supports in-place; its questions are whiptail dialogs too
- 🔄 **`update.sh`** — update with a backup copy and `--rollback`
- 🗑️ **`uninstall.sh`** — safe removal (backups in S3 are protected)
- 🧪 **`verify-restore.sh`** — automatic restore verification
- 📊 **`status.sh`** — a one-screen system overview
- 📜 **`logs.sh`** — log viewing with filters

## Contents

- [Quick start](#quick-start)
- [The docker-backup command (menu)](#the-docker-backup-command-menu)
- [File structure](#file-structure)
- [Installation](#installation)
- [Updating](#updating)
- [Configuration](#configuration)
- [Multiple storages (primary / secondary / tertiary)](#multiple-storages-primary--secondary--tertiary)
- [Automatic database dump](#automatic-database-dump)
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
- [Bash completion](#bash-completion)
- [Uninstalling](#uninstalling)
- [Security](#security)
- [Troubleshooting](#troubleshooting)
- [Versioning](#versioning)
- [License](#license)

---

## Quick start

```bash
# 1. Get the files onto the server
sudo git clone https://github.com/KolosovV/docker-backup-s3.git /opt/docker-backup
#    (or copy them: sudo mkdir -p /opt/docker-backup && sudo cp -r . /opt/docker-backup/)

# 2. Run the installer right from there (in-place is supported)
sudo /opt/docker-backup/install.sh

# 3. Everything else — from the menu (status, backup, restore, checks, schedule, storages)
sudo docker-backup

# …or the same with the scripts directly
sudo /opt/docker-backup/validate-config.sh        # settings check
sudo /opt/docker-backup/docker-backup.sh --dry-run # dry run
sudo /opt/docker-backup/docker-backup.sh           # real backup
sudo /opt/docker-backup/status.sh                 # system overview
```

If the installer set up cron — from here on everything runs by itself.

---

## The docker-backup command (menu)

The installer links `/usr/local/bin/docker-backup` → `menu.sh`. Without arguments it opens a menu:

| Item | What it does |
|---|---|
| Status overview | `status.sh` |
| Back up now | all projects or the ones you tick in a list; a dry run of either |
| Restore | pick the storage, the project and the backup from lists, then: restore in place (with or without starting), into another folder, one named volume, unpack only, or show the contents |
| Synchronize storages | the plan, all copies, one copy, with `--prune`, or restoring the primary from a copy |
| Checks and diagnostics | `validate-config.sh`, quick/full restore verification (of any storage, all projects or one), `diagnose-s3.sh`, `diagnose-cron.sh` |
| Logs | the last lines, errors, the last run, today's errors, one project, follow live |
| Scheduled runs | the current setup, a method (cron / systemd timer) and a preset or your own schedule, removal |
| Storage settings | for each storage: the connection wizard (keys, endpoint, bucket, addressing — with the bucket and certificate check), enable/disable and required/optional for copies, an access check, the read-only restore key |

Destructive actions (an in-place restore, `--prune`, writing to the primary from a copy) ask for confirmation first;
the scripts themselves keep their own confirmations too. Before the first change in **Storage settings** the menu
saves a copy `backup.conf.bak.<time>`; if the config still uses the old `S3_*` names, it offers to rename them first.

The menu uses `whiptail` (it is in Debian/Ubuntu by default; on RHEL — the `newt` package). Without it, or with
`UI_PLAIN=true`, the same menu works as numbered prompts. Without a terminal (cron, pipes) there is no menu — use
the subcommands, they pass their arguments to the script as is:

```bash
sudo docker-backup backup -p myapp          # = docker-backup.sh -p myapp
sudo docker-backup restore --list           # = docker-restore.sh --list
sudo docker-backup sync --to tertiary       # = sync-s3.sh --to tertiary
sudo docker-backup help                     # all subcommands
```

`install.sh` asks its questions in the same dialogs; with `-y` it asks nothing, as before.

---

## File structure

After installation in `/opt/docker-backup/`:

```
install.sh                       # installer from scratch
update.sh                        # update with rollback
uninstall.sh                     # clean removal (leaves S3 alone)
docker-backup.sh                 # the main backup script
docker-restore.sh                # the restore script
lib.sh                           # shared library (sourced by the scripts)
ui.sh                            # dialogs (whiptail / plain prompts) and config helpers for install.sh and the menu
menu.sh                          # the docker-backup command: the menu and subcommands
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
docker-backup-completion.bash    # bash completion (Tab completion)
README.md                        # this documentation
CHANGELOG.md                     # release notes
VERSION                          # the installed version (docker-backup version)
LICENSE                          # MIT
```

Only `backup.conf.example` is in the repository; the working `backup.conf` is created from it during installation and is in `.gitignore`, because it holds the S3 keys and the Telegram token. If you deploy from git:

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

Works on any modern Linux distribution with systemd:

- **Debian / Ubuntu** (apt), **CentOS / RHEL / AlmaLinux / Rocky** 7+ (yum/dnf),
  **Fedora** (dnf), **openSUSE** (zypper), **Arch** (pacman).
- Requires **bash 4+** (associative arrays), GNU coreutils (`stat`, `date`, `sed`, `grep`) — present by default in all of the above.
- **Docker** + Compose: both v2 (the `docker compose` plugin) and v1 (`docker-compose`) are supported — picked automatically.
- **AWS CLI v2** — installed with the official AWS installer into `/usr/local/bin`; snap is only a fallback.

> The installer itself installs the dependencies and AWS CLI for your package manager. On CentOS/RHEL the `dos2unix` package lives in the EPEL repository; if it didn't install, that's not critical (the scripts normalize line endings via `sed`).

### With `install.sh`

The installer does everything itself:
1. Installs dependencies via the system package manager — `apt`/`dnf`/`yum`/`zypper`/`pacman` (`jq`, `tar`, `gzip`, `dos2unix`, `curl`, `gpg`, `unzip`, `cron`)
2. Installs AWS CLI v2 with the official AWS installer into `/usr/local/bin`; if that fails — via snap. If aws is already installed from snap, it offers to switch to the official one: snap updates aws-cli by itself, and such updates have broken uploads (new checksums some storages reject, a CA bundle without the GlobalSign root)
3. Checks that Docker is present
4. Copies the files (or works in-place if source = target)
5. `dos2unix` + `chmod +x` + `chmod 600 backup.conf`
6. Asks for the settings interactively (in whiptail dialogs if whiptail is installed, plain prompts otherwise):
   - **Primary S3**: Access/Secret/Endpoint/Region/Bucket + addressing style (path/virtual); then checks the bucket and certificate trust itself (see below)
   - **Secondary and tertiary S3** — whether to enable, keys/endpoint/region/bucket, addressing style, whether required; the same check
   - **Prefix in the bucket** (`BACKUP_PREFIX`)
   - **Retention** (`RETENTION_DAYS`)
   - Directories to scan (`SCAN_DIRS`)
   - Telegram token and chat_id, with a real check via a test message
   - Webhook URL (optional)
7. Optionally sets up logrotate and bash completion; links the `docker-backup` command
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
# → copies the files to /opt/docker-backup/
```

#### Scenario 2: in-place installation (source = target)

```bash
# The files are already in /opt/docker-backup/
sudo /opt/docker-backup/install.sh
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
| **Does not exist** | Creates it from the template and offers to fill it in interactively |
| **Exists and is filled in** | Leaves it as is, no questions |
| **Exists, but with placeholder values** (`YOUR_ACCESS_KEY`, an empty bucket/endpoint) | Interactive: asks "Fill in the settings now?" → runs the wizard. With `-y`: a warning + a hint |

What counts as a "placeholder":
- `PRIMARY_S3_ACCESS_KEY` or `PRIMARY_S3_SECRET_KEY` equal to `YOUR_...` or empty
- `PRIMARY_S3_BUCKET` empty

(in an old config — the same fields named `S3_*`; the installer renames them itself).

This lets you work with a single command: put the files into `/opt/docker-backup`, run `install.sh` from there — and it either finishes the installation or asks for whatever is missing.

#### Options

```
-t, --target DIR       where to install (default: /opt/docker-backup)
-y, --yes              no interactive questions
    --skip-deps        don't install system packages and AWS CLI
    --no-cron          don't set up scheduled runs
    --skip-logrotate   don't install logrotate
    --skip-completion  don't install bash completion
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

Optional: a second, read-only key for a restore server — `<ROLE>_S3_RESTORE_ACCESS_KEY` / `<ROLE>_S3_RESTORE_SECRET_KEY` for each storage (`PRIMARY`, `SECONDARY`, `TERTIARY`). If set, `docker-restore.sh` reads with these keys, and backups cannot be deleted/overwritten with them.

For each copy, get keys from its provider and put them into `SECONDARY_S3_ACCESS_KEY` / `SECONDARY_S3_SECRET_KEY` (or `TERTIARY_…`), plus `_ENDPOINT` and `_BUCKET`.

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

If `/opt/docker-backup` itself is a git clone, `git pull` there updates the scripts (your `backup.conf` is in
`.gitignore` and stays untouched); then run `sudo /opt/docker-backup/update.sh --migrate-conf` once, so an old
config gets the new storage names.

What it does:
- Compares file versions and shows what will actually change
- Checks the syntax of the new files **before** replacing them (won't break the system with a broken script)
- Backs up the current installation to `/opt/docker-backup.bak.<timestamp>/`
- Does not overwrite your `backup.conf`: shows which new options appeared in the template, and renames the old primary storage names `S3_*` → `PRIMARY_S3_*` (see below)
- Refuses to update while a backup is running (checks the lock)
- Runs `validate-config.sh` after the update

### Rolling back to the previous version

```bash
sudo /opt/docker-backup/update.sh --rollback
```

Rolls back to the latest backup copy. The current state (before the rollback) is also saved to `/opt/docker-backup.reverted.<timestamp>/`.

### update.sh options

```
-t, --target DIR     where (default: /opt/docker-backup)
-s, --source DIR     from where (default: next to the script)
-y, --yes            no questions
    --rollback       roll back to the latest backup copy
    --skip-validate  skip validation
    --skip-backup    do NOT make a backup copy (dangerous)
    --migrate-conf   only rename S3_* → PRIMARY_S3_* in backup.conf and exit
```

### Renaming the primary storage in `backup.conf`

Older versions named the primary storage in the config plain `S3_*` (`S3_BUCKET`, `S3_ENDPOINT`…), and
the secondary — `SECONDARY_S3_*`. Now all storages share one scheme: `PRIMARY_S3_*`, `SECONDARY_S3_*`,
`TERTIARY_S3_*`.

- An old config keeps working: if `PRIMARY_S3_<field>` is not set, the scripts take `S3_<field>`.
- After replacing the scripts, `update.sh` renames the lines itself: `S3_ACCESS_KEY` → `PRIMARY_S3_ACCESS_KEY`
  and so on, together with references like `${S3_ADDRESSING_STYLE}` inside the file. It puts a copy
  `backup.conf.bak.<time>` alongside; if the file doesn't parse after the edit, it puts the copy back.
- `install.sh` does the same with an existing config. To only rename: `sudo ./update.sh --migrate-conf`.
- General aws settings (`S3_BANDWIDTH_LIMIT`, `S3_MULTIPART_THRESHOLD`, `S3_MAX_ATTEMPTS`) are not renamed —
  they don't belong to a single storage.

### Cleaning up old backup copies

After several updates `*.bak.*` folders pile up on disk:
```bash
ls -d /opt/docker-backup.bak.* /opt/docker-backup.reverted.* 2>/dev/null
# Delete the old ones:
sudo rm -rf /opt/docker-backup.bak.* /opt/docker-backup.reverted.*
```

---

## Configuration

The file is `/opt/docker-backup/backup.conf`. The minimum needed:

```bash
PRIMARY_S3_ACCESS_KEY="your_key"
PRIMARY_S3_SECRET_KEY="your_secret"
PRIMARY_S3_ENDPOINT="https://s3.example.com"
PRIMARY_S3_BUCKET="your-bucket-name"
SCAN_DIRS="/opt /home /root /srv"
```

Everything else has sensible defaults.

| Variable | Default | What it does |
|---|---|---|
| `PRIMARY_S3_ACCESS_KEY`, `_SECRET_KEY` | — | the primary storage key (full permissions) |
| `PRIMARY_S3_ENDPOINT` | empty | S3 endpoint URL (fill in manually, e.g. `https://s3.example.com`) |
| `PRIMARY_S3_REGION` | `us-east-1` | signing region (many S3s accept any) |
| `PRIMARY_S3_BUCKET` | empty | bucket name (create it beforehand) |
| `PRIMARY_S3_OPTS_EXTRA` | empty | extra aws options; `--ca-bundle /etc/ssl/certs/ca-certificates.crt` if aws doesn't trust a valid certificate (the installer checks and sets it itself) |
| `PRIMARY_S3_ADDRESSING_STYLE` | `path` | path/virtual |
| `PRIMARY_S3_RESTORE_ACCESS_KEY`, `_SECRET_KEY` | empty | optional read-only key for restore, status, verify-restore |
| `SECONDARY_S3_*`, `TERTIARY_S3_*` | — | copies: the same fields as `PRIMARY_S3_*` (an empty region — same as the primary) |
| `SECONDARY_S3_ENABLED`, `TERTIARY_S3_ENABLED` | `false` | enable the copy |
| `SECONDARY_S3_REQUIRED`, `TERTIARY_S3_REQUIRED` | `false` | `true` = a failed upload to this copy makes the project fail |
| `S3_BANDWIDTH_LIMIT` | empty | upload speed limit (shared by all storages) |
| `S3_MULTIPART_THRESHOLD` | empty | smaller files go in one request rather than in parts (shared) |
| `S3_MAX_ATTEMPTS` | `8` | aws attempts per request (shared) |
| `BACKUP_PREFIX` | `backups` | prefix (folder) in the bucket |
| `RETENTION_DAYS` | `30` | how many days to keep |
| `BACKUP_MODE` | `hot` | hot/pause/stop |
| `BACKUP_VOLUMES` | `true` | back up named volumes |
| `BACKUP_BIND_MOUNTS` | `true` | back up bind mounts |
| `BACKUP_PROJECT_DIR` | `true` | back up the whole project folder |
| `BACKUP_IMAGES` | `false` | save docker images |
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
| `DB_DUMPS_RETENTION_COUNT` | `3` | how many dumps to keep locally |
| `DB_DUMP_TIMEOUT` | `1800` | timeout for each dump (sec) |
| `ENCRYPT_BACKUPS` | `false` | GPG encryption |
| `GPG_PASSPHRASE_FILE` | `/root/.docker-backup-passphrase` | passphrase file |
| `NOTIFY_ON` | `error` | none/error/always |
| `TELEGRAM_BOT_TOKEN` | empty | bot token |
| `TELEGRAM_CHAT_ID` | empty | recipient ID |
| `NOTIFY_WEBHOOK_URL` | empty | webhook URL |
| `COLOR_OUTPUT` | `auto` | auto/on/off |
| `LOCK_FILE` | `/var/run/docker-backup.lock` | base path for the lock; the lock itself is a `<LOCK_FILE>.d` directory with the PID inside (atomic `mkdir`) |
| `WORK_DIR` | `/var/tmp/docker-backup` | temporary folder |
| `LOG_FILE` | `/var/log/docker-backup.log` | log path |

### Backup modes (`BACKUP_MODE`)

| Mode | Downtime | Database consistency | When to use |
|---|---|---|---|
| `hot` | none | via the database auto-dump | **default** — no downtime |
| `pause` | milliseconds | medium | general purpose |
| `stop` | seconds to minutes | perfect | for critical databases without auto-dump |

### Checking the settings

```bash
sudo /opt/docker-backup/validate-config.sh
```

The script checks:
- That the required fields are filled in and the value formats
- File permissions and CRLF
- Whether the dependencies are installed (including the AWS CLI v2 check)
- Access to each storage — the primary and the enabled copies (a test write + read + delete); on `CERTIFICATE_VERIFY_FAILED` — a check with the system CA bundle and a ready line for `backup.conf`
- Each storage's read-only key, if set
- Old `S3_*` names in the config (suggests `update.sh --migrate-conf`)
- Free space
- **Telegram bot** — by actually sending a test message, with error diagnostics
- Webhook URL
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
SECONDARY_S3_REGION=""                         # empty — same as the primary
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
sudo /opt/docker-backup/sync-s3.sh --dry-run

# Copy what's missing + re-upload objects with a wrong size — into all copies
sudo /opt/docker-backup/sync-s3.sh

# Into the tertiary S3 only
sudo /opt/docker-backup/sync-s3.sh --to tertiary

# Same + delete objects in the copies that are no longer in the primary (IRREVERSIBLE)
sudo /opt/docker-backup/sync-s3.sh --prune

# No confirmations (for cron)
sudo /opt/docker-backup/sync-s3.sh --prune -y
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
sudo /opt/docker-backup/sync-s3.sh --reverse --dry-run                 # see the plan
sudo /opt/docker-backup/sync-s3.sh --reverse                           # bring the data back to the primary
sudo /opt/docker-backup/sync-s3.sh --reverse --from tertiary           # the same from the tertiary
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
   - `postgres`, `postgis`, `timescale*` → `pg_dumpall`
   - `mysql`, `percona` → `mysqldump --all-databases --single-transaction`
   - `mariadb` → the same
   - `redis`, `keydb` → `BGSAVE` + copying the RDB
   - `mongo` → `mongodump --archive --gzip`
3. Saves the dump into the `db-dumps/` subfolder inside the project
4. These files automatically end up in the archive (since the whole project folder is archived)

### What ends up in S3

```
backups/myapp/2026-05-12_03-00-00/myapp__2026-05-12_03-00-00.tar.gz
└── myapp/
    ├── project_dir.tar.gz         # the whole folder with docker-compose.yml
    │   └── myapp/
    │       ├── docker-compose.yml
    │       ├── .env
    │       └── db-dumps/                              ← the dumps are here
    │           ├── postgres_myapp-postgres-1_...sql.gz
    │           └── redis_myapp-redis-1_...rdb.gz
    └── volumes/                   # the databases' raw data directories
        ├── volume_myapp_postgres_data.tar.gz
        └── volume_myapp_redis_data.tar.gz
```

Each archive will contain **both an SQL dump** (for a reliable restore) **and the raw volume** (for a fast restore).

### Credentials

They are read from the container's env variables via `docker exec`:

| Database | Variables |
|---|---|
| Postgres | `POSTGRES_USER` (`postgres` by default) |
| MySQL | `MYSQL_ROOT_PASSWORD`, `MYSQL_PASSWORD` |
| MariaDB | `MARIADB_ROOT_PASSWORD`, `MYSQL_ROOT_PASSWORD` |
| Redis | not needed (BGSAVE inside the container) |
| MongoDB | `MONGO_INITDB_ROOT_USERNAME`, `MONGO_INITDB_ROOT_PASSWORD` |

### Restoring a database from a dump

After a restore, the project folder will have `db-dumps/postgres_*.sql.gz`. Loading it manually:

```bash
# PostgreSQL
gunzip -c /opt/myapp/db-dumps/postgres_*.sql.gz \
    | docker exec -i myapp-postgres-1 psql -U postgres

# MySQL
gunzip -c /opt/myapp/db-dumps/mysql_*.sql.gz \
    | docker exec -i myapp-mysql-1 mysql -u root -p"$MYSQL_ROOT_PASSWORD"

# Redis
gunzip -c /opt/myapp/db-dumps/redis_*.rdb.gz > /tmp/dump.rdb
docker cp /tmp/dump.rdb myapp-redis-1:/data/dump.rdb
docker compose restart redis
```

### Custom hooks

For non-standard databases (ClickHouse, Elasticsearch, InfluxDB and the like) create `pre-backup-hook.sh` in the project folder:

```bash
cd /opt/myapp
sudo cp /opt/docker-backup/pre-backup-hook.example.sh pre-backup-hook.sh
sudo chmod +x pre-backup-hook.sh
sudo nano pre-backup-hook.sh
```

The hook runs **after** the auto-dump of the standard databases. Available variables:
- `COMPOSE_PROJECT` — project name
- `PROJECT_DIR` — path to the folder
- `BACKUP_TIMESTAMP` — timestamp

---

## First run

### Dry-run first (recommended)

```bash
sudo /opt/docker-backup/docker-backup.sh --dry-run
```

Shows the plan without real actions — which projects were found, which volumes will be backed up, which bind mounts are blacklisted, whether there are databases to auto-dump.

### Real run

```bash
sudo /opt/docker-backup/docker-backup.sh
```

You should see:
```
🚀 Starting Docker backup. Timestamp: 2026-05-12_10-32-50
🔍 Scanning compose projects...
   ✓ From labels: myapp -> /opt/myapp
📦 Compose projects found: 1
🔌 Checking access to the primary S3...
   ✓ Primary S3 is reachable
📦 Project: myapp  (/opt/myapp)
   🐘 PostgreSQL: myapp-postgres-1 -> postgres_..._.sql.gz
   ✓ Postgres dump done: 4.2M
   💾 Backing up volumes (parallel=2)...
   📦 Packing the project into a single archive...
   ☁  Uploading to the primary S3...
   🔍 Checking the integrity of the uploaded object...
   ✓ Size in S3 matches: 14647301 bytes
   ✅ myapp  (size: 14M, time: 2m 15s)
🧹 Cleanup in primary S3: older than 30 days, keeping the last 3
✅ Backup finished. Timestamp: 2026-05-12_10-32-50
```

---

## Backing up a single project

For urgent jobs (before a migration, after a critical change and the like) you can back up one or several specific projects:

```bash
# Only one project
sudo /opt/docker-backup/docker-backup.sh -p myapp

# Several projects, comma-separated
sudo /opt/docker-backup/docker-backup.sh -p myapp,otherapp

# Dry-run for one project
sudo /opt/docker-backup/docker-backup.sh -p myapp --dry-run

# Just the names of the projects found on this host (the menu builds its list from this)
sudo /opt/docker-backup/docker-backup.sh --list
```

### Behavior with `-p`

- Only the given projects are backed up
- Standalone containers (no compose) are skipped
- **Rotation of old backups is skipped** (protection against accidentally deleting others')
- If a requested project is not found — the script prints an error with a hint about what is on the host

### Examples

```bash
# Before an application update — an urgent backup
sudo /opt/docker-backup/docker-backup.sh -p my-critical-app

# After a big migration — a backup of two related projects
sudo /opt/docker-backup/docker-backup.sh -p users-service,payments-service

# Check that a new project shows up in the plan
sudo /opt/docker-backup/docker-backup.sh -p new-project --dry-run
```

---

## Restore verification

A backup that was never checked is a hope, not insurance. Use `verify-restore.sh`:

```bash
# Quick check (head-object: the object is there and non-empty, no download)
sudo /opt/docker-backup/verify-restore.sh --quick

# Standard — downloads, unpacks, checks the SQL dumps (default)
sudo /opt/docker-backup/verify-restore.sh

# One project in detail
sudo /opt/docker-backup/verify-restore.sh -p myapp

# No notifications (for interactive use)
sudo /opt/docker-backup/verify-restore.sh --no-notify

# Check the copy in the tertiary S3 rather than the primary
sudo /opt/docker-backup/verify-restore.sh --from tertiary
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
  - MySQL: gzip + magic (`mysqldump`/`MySQL dump`)
  - Redis: gzip + RDB magic (`REDIS`)
  - MongoDB: gzip

### Setting up a regular check

Once a week via cron:

```cron
0 4 * * 0  /opt/docker-backup/verify-restore.sh --quick >> /var/log/docker-backup-verify.log 2>&1
```

Or once a month with a detailed check:
```cron
0 5 1 * *  /opt/docker-backup/verify-restore.sh >> /var/log/docker-backup-verify.log 2>&1
```

On an error it sends a Telegram notification (if configured).

---

## GPG encryption

Archives are encrypted symmetrically (GPG, AES-256) **before** being uploaded to S3. This protects the data even if the S3 keys or the bucket itself leak — without the passphrase an archive is a random set of bytes.

### How it works (lifecycle)

Encryption is end-to-end and the same for all storages:

1. **Creation** — the project is packed into a `tar.gz`, then (if `ENCRYPT_BACKUPS="true"`) encrypted into `*.tar.gz.gpg`. Only the encrypted file goes to S3.
2. **Upload** — the `.gpg` is uploaded to the primary S3, its size is checked via `head-object` on the `.gpg` key.
3. **Copies (secondary, tertiary S3)** — the very same `.gpg` with the same key is uploaded there, its size checked the same way.
4. **Restore** — `docker-restore.sh` recognizes an encrypted file by the `.gpg` extension, downloads it and decrypts it on the fly before unpacking (the same `GPG_PASSPHRASE_FILE` is needed).
5. **Checks** — `validate-config.sh` checks that `gpg` is present, that the passphrase file exists and its permissions (600); `verify-restore.sh` runs the full download→decrypt→unpack cycle.
6. **Rotation/deletion** — expired objects are deleted by key in every bucket, whether they are encrypted or not.

### Enabling it

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
sudo /opt/docker-backup/validate-config.sh
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

### Webhook (Slack, Discord, custom)

```bash
NOTIFY_WEBHOOK_URL="https://hooks.slack.com/services/T00.../B00.../XXX"
```

For Discord: `https://discord.com/api/webhooks/.../...?wait=true`

### Notification levels

- `none` — never
- `error` — errors only (recommended)
- `always` — every run

---

## Scheduled runs (cron/systemd)

```bash
sudo /opt/docker-backup/setup-cron.sh
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
sudo /opt/docker-backup/setup-cron.sh -m cron -s daily -y
sudo /opt/docker-backup/setup-cron.sh -m systemd -s '*-*-* 04:30:00' -y
sudo /opt/docker-backup/setup-cron.sh --status    # current status
sudo /opt/docker-backup/setup-cron.sh --remove    # remove
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
0 3 * * * /opt/docker-backup/docker-backup.sh >> /var/log/docker-backup-cron.log 2>&1
# === /Docker backup ===
```

### Testing the cron environment

```bash
sudo env -i \
    SHELL=/bin/bash \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin \
    HOME=/root \
    /opt/docker-backup/docker-backup.sh
```

### Diagnosing cron problems

If `setup-cron.sh` or `install.sh` warns "Cron is not installed" although it works (e.g. on Ubuntu 24.04), run:

```bash
sudo /opt/docker-backup/diagnose-cron.sh
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
sudo /opt/docker-backup/docker-restore.sh --list
sudo /opt/docker-backup/docker-restore.sh --list --project myapp
```

### Interactive mode

```bash
sudo /opt/docker-backup/docker-restore.sh
```

1. Shows the list of projects with details (backups / latest / age)
2. Accepts a multi-select: `3` / `1,3,5` / `1-7` / `1-3,5,7-9` / `all`
3. Asks for the date for each selected project
4. Shows the plan + an overwrite warning
5. Downloads, decrypts, unpacks, restores
6. Runs `docker compose up -d`

### Non-interactively

```bash
# One project
sudo /opt/docker-backup/docker-restore.sh \
    -p myapp \
    -t 2026-05-12_03-00-00 \
    -y

# Several projects with the same date
sudo /opt/docker-backup/docker-restore.sh \
    -p myapp,otherapp \
    -t 2026-05-12_03-00-00 \
    -y
```

### A test in /tmp without starting

```bash
sudo /opt/docker-backup/docker-restore.sh \
    --dir /tmp/test-restore \
    --no-start
```

⚠️ Volumes are restored under their real names — they will overwrite the existing ones. For a fully isolated test use a separate server with a read-only S3 key, or `verify-restore.sh`.

### Partial restore

The most common scenario is not "the server burned down" but "the wrong table was dropped at 15:00". There's no need to deploy the whole project and overwrite the running production for that.

**See what is inside a backup:**

```bash
sudo /opt/docker-backup/docker-restore.sh -p myapp --contents
```

Shows the metadata, the list of named volumes with sizes, bind mounts and the database dumps inside `project_dir.tar.gz`. Downloads nothing to the host beyond a temporary folder and changes nothing.

**Get a single database dump (restoring nothing):**

```bash
sudo /opt/docker-backup/docker-restore.sh -p myapp --extract-to /tmp/restore -y
tar xzf /tmp/restore/project_dir.tar.gz -C /tmp/restore
ls /tmp/restore/myapp/db-dumps/
```

Then load the dump manually — e.g. `gunzip -c dump.sql.gz | docker exec -i myapp-db-1 psql -U postgres`.

**Restore a single volume only:**

```bash
sudo /opt/docker-backup/docker-restore.sh -p myapp --only-volume myapp_pgdata -y
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
sudo /opt/docker-backup/docker-restore.sh --from tertiary --list

# Restore a project from the secondary S3
sudo /opt/docker-backup/docker-restore.sh --from secondary -p myapp -t 2026-05-12_03-00-00 -y
```

Source priority: the `--from` flag → the interactive choice → the primary S3 by default. The copy must be enabled (`<ROLE>_S3_ENABLED="true"`) and filled in. Reading uses the storage's read-only key (`<ROLE>_S3_RESTORE_*`) if set, otherwise that storage's main key. Since the object key is the same in every storage, the restore is fully transparent.

`verify-restore.sh --from ROLE` likewise checks that a copy can be restored, rather than the primary.

---

## System status

```bash
sudo /opt/docker-backup/status.sh
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
sudo /opt/docker-backup/logs.sh

# Follow in real time
sudo /opt/docker-backup/logs.sh -f

# Errors only
sudo /opt/docker-backup/logs.sh -e

# The whole last run (from 🚀 to ✅)
sudo /opt/docker-backup/logs.sh -l

# Entries about a specific project
sudo /opt/docker-backup/logs.sh -p myapp

# For the last 2 hours
sudo /opt/docker-backup/logs.sh -s '2 hours ago'

# All errors for today
sudo /opt/docker-backup/logs.sh -e -s today

# The main log only
sudo /opt/docker-backup/logs.sh -b

# The cron log only
sudo /opt/docker-backup/logs.sh -C

# No limit
sudo /opt/docker-backup/logs.sh -n 0
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
sudo nano /opt/docker-backup/backup.conf
# RETENTION_DAYS=90  # three months
```

To see what will be deleted on the next run, without deleting anything:

```bash
sudo /opt/docker-backup/status.sh
```

### Checksums

```bash
CHECKSUM_MANIFEST="true"
```

A `.sha256` file is placed next to every archive in S3. Matching sizes only prove that the upload wasn't cut short — a corrupted object of the same length doesn't show in its size. The manifest lets `docker-restore.sh` (before a restore), `verify-restore.sh` (during regular checks) and `sync-s3.sh` (before copying an object to a copy — otherwise the corruption spreads there and is taken as normal) catch corruption.

Backups made before manifests existed are checked as before, by size.

### What is in S3

```bash
source /opt/docker-backup/backup.conf
export AWS_ACCESS_KEY_ID="$PRIMARY_S3_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$PRIMARY_S3_SECRET_KEY"

aws --endpoint-url "$PRIMARY_S3_ENDPOINT" $PRIMARY_S3_OPTS_EXTRA \
    s3api list-objects-v2 --bucket "$PRIMARY_S3_BUCKET" --prefix "backups/" \
    --query 'Contents[].[LastModified,Size,Key]' --output table
```

---

## Bash completion

If you installed via `install.sh`, it asks. Otherwise manually:

```bash
sudo cp /opt/docker-backup/docker-backup-completion.bash /etc/bash_completion.d/docker-backup
```

After logging in again:
```bash
docker-restore.sh --pro<TAB>          # → --project
docker-restore.sh -p <TAB>            # → project list from S3
```

---

## Uninstalling

```bash
# Safely (S3 is KEPT)
sudo /opt/docker-backup/uninstall.sh

# No questions
sudo /opt/docker-backup/uninstall.sh -y

# See what would happen
sudo /opt/docker-backup/uninstall.sh --dry-run

# Keep backup.conf for a reinstall
sudo /opt/docker-backup/uninstall.sh --keep-conf

# Remove + logs
sudo /opt/docker-backup/uninstall.sh -y --purge-logs

# ⚠ FULL cleanup (including S3 — every storage whose keys and bucket are filled in; irreversible)
sudo /opt/docker-backup/uninstall.sh --purge-s3 --purge-logs
# Asks you to type 'DELETE ALL BACKUPS'
```

### What is removed

- ✅ Files in `/opt/docker-backup/`
- ✅ The cron job
- ✅ Systemd timer + service
- ✅ `/etc/logrotate.d/docker-backup`
- ✅ `/etc/bash_completion.d/docker-backup`
- ✅ `/usr/local/bin/docker-backup` (only if it is the link to this installation)
- ✅ The lock file
- ✅ The temporary folder

### What is NOT removed

- ❌ **Backups in S3** (only with `--purge-s3`)
- ❌ Logs (only with `--purge-logs`)
- ❌ GPG passphrase
- ❌ Dependencies (docker, aws-cli, jq, ...)
- ❌ `pre-backup-hook.sh` in projects
- ❌ `db-dumps/` folders in projects

### Safeguards

- Shows what was found when it starts
- Warns if a backup is running (an active lock pid)
- `--purge-s3` requires typing `DELETE ALL BACKUPS`
- `--dry-run` shows the plan without executing it

---

## Security

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
- An integrity check after upload (head-object)
- In `uninstall.sh` — S3 is not touched without explicit confirmation
- In `update.sh` — the syntax of the new files is checked before replacing
- In `docker-backup.sh -p` — rotation is skipped so others' backups aren't deleted

---

## Troubleshooting

### `bash: $'\r': command not found`

CRLF from Windows:
```bash
sudo dos2unix /opt/docker-backup/*.sh /opt/docker-backup/*.conf
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
sudo /opt/docker-backup/diagnose-cron.sh
```

The script shows exactly what auto-detection sees. Most likely the `cron` binary is in `/usr/sbin/cron` and the process is running (`pgrep -x cron` finds it) — then there should be no warning. If it shows up anyway — please open an issue with the output of `diagnose-cron.sh`.

### `install.sh` in-place doesn't offer to fill in the conf

This depends on the state of `backup.conf`:
- If `PRIMARY_S3_ACCESS_KEY`, `PRIMARY_S3_SECRET_KEY`, `PRIMARY_S3_BUCKET` (in an old config — `S3_*`) hold real values (not `YOUR_...`, not empty) — the installer considers the conf ready and doesn't ask
- If at least one field is a placeholder — in interactive mode it offers "Fill in the settings now?"
- If run with `-y` — it only warns and doesn't intervene

Check manually:
```bash
sudo grep -E "^(PRIMARY_)?S3_(ACCESS_KEY|SECRET_KEY|BUCKET)=" /opt/docker-backup/backup.conf
```

If you want to force a fresh fill-in — remove the conf and run install:
```bash
sudo mv /opt/docker-backup/backup.conf /opt/docker-backup/backup.conf.old
sudo /opt/docker-backup/install.sh
```

### The backup hangs on a huge `tar`

Some container has mounted a big path:
```bash
sudo /opt/docker-backup/logs.sh -e | tail -10
```

Add it to `BIND_BLACKLIST_REGEX`. The edit is idempotent — running it again breaks nothing,
so it can be sent to all servers at once (a path that isn't on a server costs the regex
nothing). The check looks at the variable's line specifically, not the whole file: the path
may appear in a neighboring comment, and then the edit would silently not apply.

```bash
grep -q "^BIND_BLACKLIST_REGEX=.*your/path" /opt/docker-backup/backup.conf || \
  sed -i "s#^\(BIND_BLACKLIST_REGEX='.*\)'#\1|^/your/path'#" /opt/docker-backup/backup.conf
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
sudo /opt/docker-backup/validate-config.sh
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
sudo /opt/docker-backup/update.sh --rollback
```

### S3 keys were accidentally published

1. Your S3 provider's panel → access keys → change the key
2. Put the new one into `backup.conf`
3. `sudo /opt/docker-backup/validate-config.sh`

---

## Versioning

The project follows [Semantic Versioning](https://semver.org/); every release is a git tag `vX.Y.Z`
with notes in [CHANGELOG.md](CHANGELOG.md). The installed version: `docker-backup version`.
`update.sh` shows which version it updates from and to.

## License

[MIT](LICENSE). Use it, change it, ship it — just keep the copyright notice.
