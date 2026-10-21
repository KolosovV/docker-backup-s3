#!/usr/bin/env bash
# Runs tests/systemd/check.sh in containers where systemd really is PID 1 (privileged, the host's cgroups),
# sharing the host's Docker (socket, network, one folder) like tests/distros/run.sh.
# On a real VM run check.sh directly instead: sudo tests/systemd/check.sh (CI does that on its runner too).
#
# usage: tests/systemd/run.sh [IMAGE…]      (no images — the default list below)
set -uo pipefail
IFS=$'\n\t'

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEFAULT_IMAGES=(debian:12 ubuntu:24.04 rockylinux:9 almalinux:8 fedora:41 opensuse/leap:15.6 archlinux:latest)
(( $# )) && IMAGES=("$@") || IMAGES=("${DEFAULT_IMAGES[@]}")
TOOLS="$("$REPO/tests/distros/run.sh" --tools-only)" || exit 2
SHARE="${DBT_WORK:-/var/tmp/dbt-share}"
mkdir -p "$SHARE"; chmod 1777 "$SHARE"

# What a server image has but a container image does not: systemd itself (and procps for ps/pgrep)
systemd_setup() {
    case "$1" in
        debian:*|ubuntu:*) echo 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq systemd systemd-sysv procps >/dev/null' ;;
        rockylinux:*|almalinux:*|fedora:*|amazonlinux:*)
            # authselect: a real RHEL-family server has a PAM profile, the container image does not (crond needs one)
            echo 'dnf install -y -q systemd procps-ng authselect >/dev/null && (authselect select local --force >/dev/null 2>&1 || authselect select minimal --force >/dev/null)' ;;
        opensuse/*) echo 'zypper --non-interactive -q install -y systemd systemd-sysvinit procps >/dev/null' ;;
        archlinux:*) echo 'pacman -Syu --noconfirm --needed systemd procps-ng >/dev/null' ;;
        *) return 1 ;;
    esac
}

declare -a RESULTS=()
failed=0
for img in "${IMAGES[@]}"; do
    echo
    echo "################ systemd: ${img} ################"
    tag="dbsd-$(tr '/:.' '___' <<< "$img")"
    setup="$(systemd_setup "$img")" || { RESULTS+=("SKIP  $img (no recipe)"); continue; }
    # The container shares the host's network: its own resolved/networkd would fight the host's — no DNS, and then
    # even crond's PAM (pam_access) refuses root's jobs
    printf 'FROM %s\nRUN %s\nRUN systemctl mask systemd-resolved.service systemd-networkd.service systemd-networkd.socket >/dev/null 2>&1; true\nSTOPSIGNAL SIGRTMIN+3\nCMD ["/sbin/init"]\n' "$img" "$setup" \
        | docker build -q -t "$tag" - >/dev/null || { RESULTS+=("FAIL  $img (image build)"); failed=$((failed + 1)); continue; }
    cid="$(docker run -d --label docker-backup.skip=true --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        --tmpfs /run --tmpfs /run/lock --network host \
        -v /var/run/docker.sock:/var/run/docker.sock -v "$SHARE:$SHARE" -e "DBT_WORK=$SHARE" \
        -v "$TOOLS:/dbt-tools:ro" -v "$REPO:/src:ro" "$tag")"
    # Wait for systemd to finish booting (degraded is fine: some units do not start in a container)
    for _ in $(seq 1 60); do
        st="$(docker exec "$cid" systemctl is-system-running 2>/dev/null)"
        [[ "$st" == running || "$st" == degraded ]] && break
        sleep 1
    done
    docker exec "$cid" sh -c 'mkdir -p /usr/local/bin /usr/local/lib/docker/cli-plugins
        ln -sf /dbt-tools/docker /usr/local/bin/docker
        ln -sf /dbt-tools/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose'
    docker exec -e DBT_SRC=/src "$cid" bash /src/tests/systemd/check.sh
    rc=$?
    docker rm -f "$cid" >/dev/null
    if (( rc == 0 )); then RESULTS+=("PASS  $img"); else RESULTS+=("FAIL  $img"); failed=$((failed + 1)); fi
done

echo
echo "================ Summary (systemd) ================"
printf '%s\n' "${RESULTS[@]}"
(( failed == 0 ))
