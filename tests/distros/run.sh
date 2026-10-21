#!/usr/bin/env bash
# Runs the whole check on several Linux distributions, each in a fresh container:
# install.sh -y (it installs the dependencies itself) → the tools are there → setup-cron.sh → the tests →
# the integration test (with the host's Docker: its socket and network, and one folder at the same path,
# /var/tmp/dbt-share, are shared with the container; never the whole /tmp).
#
# usage: tests/distros/run.sh [IMAGE…]      (no images — the default list below)
#        DBT_PLATFORM=linux/arm64 tests/distros/run.sh …   another architecture, emulated by QEMU (binfmt)
#        tests/distros/run.sh --tools-only     only fetch the docker CLI for the containers, print its folder
# Needs: Docker on a Linux host (with Docker Desktop, run it inside docker:dind).
set -uo pipefail
IFS=$'\n\t'

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEFAULT_IMAGES=(
    debian:13 debian:12 ubuntu:24.04 ubuntu:22.04
    rockylinux:9 almalinux:8 fedora:41 amazonlinux:2023
    opensuse/leap:15.6 archlinux:latest alpine:3.20
)
TOOLS_ONLY=false
[[ "${1:-}" == "--tools-only" ]] && { TOOLS_ONLY=true; shift; }
(( $# )) && IMAGES=("$@") || IMAGES=("${DEFAULT_IMAGES[@]}")

# The containers' architecture: the host's, or DBT_PLATFORM's
PLATFORM="${DBT_PLATFORM:-}"
case "${PLATFORM:-$(uname -m)}" in
    x86_64|linux/amd64)  arch=x86_64 ;;
    aarch64|linux/arm64) arch=aarch64 ;;
    *) echo "Unsupported architecture ${PLATFORM:-$(uname -m)}"; exit 2 ;;
esac
declare -a PLAT=()
[[ -n "$PLATFORM" ]] && PLAT=(--platform "$PLATFORM")

# Static docker CLI and compose plugin for the containers (a distro's own docker may not exist or may not run there)
DOCKER_VER="27.5.1"; COMPOSE_VER="v2.33.0"
TOOLS="${DBT_TOOLS:-/var/tmp/dbt-tools-${arch}}"
# Bind mounts in the tests must resolve to the same path for the daemon: one shared folder, not /tmp
# (a container with systemd cleans its /tmp at boot — a shared /tmp would be the host's)
SHARE="${DBT_WORK:-/var/tmp/dbt-share}"
mkdir -p "$SHARE"; chmod 1777 "$SHARE"
if [[ ! -x "$TOOLS/docker" || ! -x "$TOOLS/docker-compose" ]]; then
    mkdir -p "$TOOLS"
    curl -fsSL "https://download.docker.com/linux/static/stable/${arch}/docker-${DOCKER_VER}.tgz" \
        | tar -xzf - -C "$TOOLS" --strip-components=1 docker/docker || { echo "cannot download docker" >&2; exit 2; }
    curl -fsSL -o "$TOOLS/docker-compose" \
        "https://github.com/docker/compose/releases/download/${COMPOSE_VER}/docker-compose-linux-${arch}" \
        || { echo "cannot download compose" >&2; exit 2; }
    chmod +x "$TOOLS/docker" "$TOOLS/docker-compose"
fi
$TOOLS_ONLY && { echo "$TOOLS"; exit 0; }

declare -a RESULTS=()
failed=0
for img in "${IMAGES[@]}"; do
    echo
    echo "################ ${img} ################"
    log="/tmp/dbt-$(tr '/:' '__' <<< "$img").log"
    docker pull -q ${PLAT[@]+"${PLAT[@]}"} "$img" >/dev/null 2>&1
    docker run --rm ${PLAT[@]+"${PLAT[@]}"} --network host \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "$SHARE:$SHARE" -e "DBT_WORK=$SHARE" \
        -v "$TOOLS:/dbt-tools:ro" \
        -v "$REPO:/src:ro" \
        -e "DBT_IMAGE=$img${PLATFORM:+ ($PLATFORM)}" \
        "$img" sh /src/tests/distros/inside.sh 2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
    if (( rc == 0 )); then RESULTS+=("PASS  $img")
    else RESULTS+=("FAIL  $img  (log: $log)"); failed=$((failed + 1)); fi
done

echo
echo "================ Summary (${arch}) ================"
printf '%s\n' "${RESULTS[@]}"
(( failed == 0 ))
