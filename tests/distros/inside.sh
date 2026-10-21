#!/bin/sh
# Runs inside a fresh distro container (see run.sh). Plain sh: some distros (Alpine) have no bash yet,
# and install.sh needs it — the one thing a user installs by hand there.
set -u
if ! command -v bash >/dev/null 2>&1; then
    if command -v apk >/dev/null 2>&1; then apk add --no-cache -q bash >/dev/null || exit 1
    else echo "no bash and no known way to install it"; exit 1; fi
fi
exec bash /src/tests/distros/check.sh
