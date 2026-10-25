# Security policy

## Supported versions

Fixes go into the latest release only. Update with `update.sh` (see the README) before reporting.

| Version | Supported |
| ------- | --------- |
| 2.0.x   | ✅        |
| < 2.0   | ❌        |

## Reporting a vulnerability

**Do not open a public issue.** Report it privately:
[Security → Report a vulnerability](https://github.com/KolosovV/docker-backup-s3/security/advisories/new).

Please include:

- the version (`docker-backup-s3 version`) and the distribution;
- what an attacker needs (a local user? access to the storage? to the network?) and what they get;
- the steps or a script that shows it.

You will get an answer within a week. Once a fix is released, the advisory is published with credit to you,
unless you would rather stay unnamed.

## What counts

The scripts run as root and hold the keys to every backup, so these are in scope:

- a way for a user of the host who is not root (and not in the `docker` group) to run code as root, read the
  backups, the keys or the passwords, or change what goes into a backup;
- a secret reaching a command line, the log, a notification or a file others can read;
- an archive or a storage answer that makes a restore write outside the place it should, or run code;
- anything that sends data anywhere other than the storages and channels set in `backup.conf`.

Not in scope: anything that needs root or the `docker` group already (they are root on the host), a storage or a
notification channel you don't trust with the data you send it, and a `backup.conf` or install folder that others
can write to (`validate-config.sh` reports that).

How the scripts handle keys and passwords: [README → Security](README.md#security).
