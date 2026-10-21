#!/usr/bin/env bash
# Runs the whole check on several Linux distributions, each in a fresh container:
# install.sh -y (it installs the dependencies itself) → the tools are there → setup-cron.sh → the tests →
# the integration test (with the host's Docker: its socket, network and /tmp are shared with the container).
#
# usage: tests/distros/run.sh [IMAGE…]      (no images — the default list below)
# Needs: Docker on a Linux host (Docker Desktop's VM does not share /tmp; use docker:dind there).
set -uo pipefail
IFS=$'\n\t'

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEFAULT_IMAGES=(
    debian:13 debian:12 ubuntu:24.04 ubuntu:22.04
    rockylinux:9 almalinux:8 fedora:41 amazonlinux:2023
    opensuse/leap:15.6 archlinux:latest alpine:3.20
)
(( $# )) && IMAGES=("$@") || IMAGES=("${DEFAULT_IMAGES[@]}")

# Static docker CLI and compose plugin for the containers (a distro's own docker may not exist or may not run there)
DOCKER_VER="27.5.1"; COMPOSE_VER="v2.33.0"
TOOLS="${DBT_TOOLS:-/tmp/dbt-tools}"
case "$(uname -m)" in
    x86_64)  arch=x86_64 ;;
    aarch64) arch=aarch64 ;;
    *) echo "Unsupported host architecture $(uname -m)"; exit 2 ;;
esac
if [[ ! -x "$TOOLS/docker" || ! -x "$TOOLS/docker-compose" ]]; then
    mkdir -p "$TOOLS"
    curl -fsSL "https://download.docker.com/linux/static/stable/${arch}/docker-${DOCKER_VER}.tgz" \
        | tar -xzf - -C "$TOOLS" --strip-components=1 docker/docker || { echo "cannot download docker"; exit 2; }
    curl -fsSL -o "$TOOLS/docker-compose" \
        "https://github.com/docker/compose/releases/download/${COMPOSE_VER}/docker-compose-linux-${arch}" \
        || { echo "cannot download compose"; exit 2; }
    chmod +x "$TOOLS/docker" "$TOOLS/docker-compose"
fi

declare -a RESULTS=()
failed=0
for img in "${IMAGES[@]}"; do
    echo
    echo "################ ${img} ################"
    log="/tmp/dbt-$(tr '/:' '__' <<< "$img").log"
    docker pull -q "$img" >/dev/null 2>&1
    docker run --rm --network host \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v /tmp:/tmp \
        -v "$TOOLS:/dbt-tools:ro" \
        -v "$REPO:/src:ro" \
        -e "DBT_IMAGE=$img" \
        "$img" sh /src/tests/distros/inside.sh 2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
    if (( rc == 0 )); then RESULTS+=("PASS  $img")
    else RESULTS+=("FAIL  $img  (log: $log)"); failed=$((failed + 1)); fi
done

echo
echo "================ Summary ================"
printf '%s\n' "${RESULTS[@]}"
(( failed == 0 ))
