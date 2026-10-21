# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/): a new **major** version means an action is needed
on update (a config change that `update.sh` can't do for you), **minor** — new features,
**patch** — fixes.

The installed version: `docker-backup version` (or the `VERSION` file).

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

[1.0.0]: https://github.com/KolosovV/docker-backup-s3/releases/tag/v1.0.0
