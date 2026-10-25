# Contributing

Thanks for taking the time. Bug reports, fixes and new database or distribution support are all welcome.
Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Before you start

- **A security problem** — not an issue: see [SECURITY.md](SECURITY.md).
- **A bug** — open an issue with the form. `sudo /opt/docker-backup-s3/validate-config.sh` and
  `sudo /opt/docker-backup-s3/logs.sh -e -s today` usually show what's wrong; remove keys, passwords and hostnames
  from what you paste.
- **A bigger change** (a new option, a new storage feature, a change of behaviour) — open an issue first, so we
  agree on the shape before you write it.

The project is Linux only: Windows and macOS are not supported.

## Making a change

1. Fork, branch from `main`, keep one change per pull request.
2. Write it the way the scripts already are: Bash with `set -euo pipefail`, every variable quoted, no secret on a
   command line (use the environment, stdin or a `600` file), messages that say what happened and what to do.
3. Add or change a test for it (see below).
4. Note it in [CHANGELOG.md](CHANGELOG.md) under `## [Unreleased]`, in plain words for the people who run it.
   An option goes into `backup.conf.example` and the README's table too.
5. Texts, comments and commit messages are in English. Files use LF line endings.

## Tests

```bash
tests/run.sh                    # unit tests: bash, jq, python3, coreutils; no Docker, no network
sudo tests/integration/run.sh   # the real thing: Docker, a compose project, S3 in a container
```

ShellCheck must be clean at warning level, with both the version CI uses (0.9.0) and the latest:

```bash
shellcheck -x -P SCRIPTDIR -S warning ./*.sh tests/*.sh tests/*/*.sh
```

What each test covers, and the distribution, database and systemd tests: [README → Tests](README.md#tests).
GitHub Actions runs ShellCheck, the unit, integration and systemd tests on every pull request (it starts once a
maintainer approves it); they must pass before it is merged. Pull requests are squash-merged.

## Releases

The maintainer releases: [Semantic Versioning](https://semver.org/), a tag `vX.Y.Z` and the CHANGELOG section as
the release notes. A major version means an action is needed on update.
