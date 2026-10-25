## What and why

<!-- What this changes, and the problem it solves. Link the issue: "Fixes #…" -->

## Checklist

- [ ] `tests/run.sh` passes; a test covers the change
- [ ] ShellCheck is clean (`shellcheck -x -P SCRIPTDIR -S warning ./*.sh tests/*.sh tests/*/*.sh`)
- [ ] No secret on a command line, in the log or in a notification
- [ ] CHANGELOG.md under `## [Unreleased]`; a new option is in `backup.conf.example` and the README
