# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/): a new **major** version means an action is needed
on update (a config change that `update.sh` can't do for you), **minor** — new features,
**patch** — fixes.

The installed version: `docker-backup version` (or the `VERSION` file).

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

[1.0.1]: https://github.com/KolosovV/docker-backup-s3/releases/tag/v1.0.1
[1.0.0]: https://github.com/KolosovV/docker-backup-s3/releases/tag/v1.0.0
