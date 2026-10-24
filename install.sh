#!/usr/bin/env bash
# ==============================================================================
# install.sh
# Installs Docker Backup System from scratch on a clean server.
#
# What it does:
#   1. Installs dependencies (the distro's package manager); aws-cli v2 — with the official
#      AWS installer, and if that fails — via snap (fallback)
#   2. Copies the files to /opt/docker-backup-s3/ (or the given path)
#   3. Sets permissions (chmod 600 on the conf, +x on scripts, dos2unix)
#   4. Fills in backup.conf interactively (S3 keys, bucket, schedule)
#   5. Optionally: installs logrotate, cron
#   6. Runs validate-config.sh as a check
#
# Usage:
#   sudo ./install.sh                 # interactive mode
#   sudo ./install.sh --non-interactive --target /opt/docker-backup-s3 --no-cron
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Arguments ---
TARGET_DIR="/opt/docker-backup-s3"
NON_INTERACTIVE="false"
SKIP_DEPS="false"
SKIP_CRON="false"
SKIP_LOGROTATE="false"
SKIP_VALIDATE="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--target) TARGET_DIR="$2"; shift 2 ;;
        -y|--yes|--non-interactive) NON_INTERACTIVE="true"; shift ;;
        --skip-deps) SKIP_DEPS="true"; shift ;;
        --no-cron|--skip-cron) SKIP_CRON="true"; shift ;;
        --skip-logrotate) SKIP_LOGROTATE="true"; shift ;;
        --skip-validate) SKIP_VALIDATE="true"; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [options]

  -t, --target DIR        where to install (default: /opt/docker-backup-s3)
  -y, --yes               no interactive questions (everything on defaults)
      --skip-deps         skip installing system packages and aws-cli
      --no-cron           do not set up scheduled runs
      --skip-logrotate    skip installing logrotate
      --skip-validate     skip the final validation

  -h, --help              this help
EOF
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# --- Root check ---
if [[ "$EUID" -ne 0 ]]; then
    echo "❌ The script must be run as root: sudo $0" >&2
    exit 1
fi

# --- Colors (minimal, not depending on lib.sh — it's not installed yet) ---
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

log()      { echo "${C_DIM}[$(date '+%H:%M:%S')]${C_RESET} $*"; }
log_step() { echo; echo "${C_BOLD}${C_CYAN}━━━ $* ━━━${C_RESET}"; }
log_ok()   { echo "  ${C_GREEN}✓${C_RESET} $*"; }
log_warn() { echo "  ${C_YELLOW}⚠${C_RESET} $*"; }
log_err()  { echo "  ${C_RED}✗ $*${C_RESET}"; }
fail()     { log_err "$*"; exit 1; }

# Dialogs (whiptail with a terminal, plain prompts otherwise) and config helpers: conf_set,
# normalize_endpoint, s3_cert_check — shared with menu.sh, see ui.sh. Taken from the source folder:
# the target one may not exist yet.
[[ -f "$SOURCE_DIR/ui.sh" ]] || { echo "❌ Not found: $SOURCE_DIR/ui.sh — run install.sh from the unpacked archive" >&2; exit 1; }
# shellcheck source=ui.sh
source "$SOURCE_DIR/ui.sh"
ui_init
CONF_FILE="$TARGET_DIR/backup.conf"

# The installer's questions. Cancel in a dialog stops the installation.
ask_yn()     { ui_yesno "$@"; }
ask_value()  { ui_input "$@"    || { echo "Cancelled." >&2; exit 130; }; }
ask_secret() { ui_password "$@" || { echo "Cancelled." >&2; exit 130; }; }

# Checks whether the minimum required fields in backup.conf hold real values
# usage: is_conf_filled <path-to-conf>
# returns: 0 if everything holds real values, 1 if something is a placeholder/empty
# The settings of an earlier installation elsewhere: older versions lived in /opt/docker-backup, and
# uninstall.sh leaves a copy in /root. Prints the path; 1 if there is none.
find_previous_conf() {
    local c
    for c in /opt/docker-backup/backup.conf $(ls -t /root/docker-backup.conf.saved-* 2>/dev/null); do
        [[ -f "$c" && "$(realpath -m "$c")" != "$(realpath -m "$TARGET_DIR/backup.conf")" ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

# create_conf — a working backup.conf where there is none: the earlier installation's settings if found
# (a copy of them stays next to it as backup.conf.imported-<time>), otherwise the template.
# Starting from the template when settings exist loses whatever the wizard does not ask about —
# that is how a reinstall once left encryption switched off.
create_conf() {
    local prev
    if prev="$(find_previous_conf)"; then
        log_step "Settings of an earlier installation"
        if ask_yn "Found $prev — take these settings over (keys, encryption, notifications, everything)?" "y"; then
            cp -p "$prev" "$TARGET_DIR/backup.conf"
            cp -p "$prev" "$TARGET_DIR/backup.conf.imported-$(date +%Y%m%d_%H%M%S)"
            chmod 600 "$TARGET_DIR"/backup.conf "$TARGET_DIR"/backup.conf.imported-* 2>/dev/null || true
            EXISTING_CONF="true"
            log_ok "backup.conf taken over from $prev (a copy as it was: backup.conf.imported-*)"
            return 0
        fi
    fi
    cp -f "$CONF_TEMPLATE" "$TARGET_DIR/backup.conf"
    log_ok "backup.conf created from $(basename "$CONF_TEMPLATE") (needs filling in)"
}

is_conf_filled() {
    local conf="$1"
    [[ -f "$conf" ]] || return 1

    # Source it in a helper subshell so the environment isn't polluted
    (
        # shellcheck disable=SC1090
        source "$conf" 2>/dev/null || exit 1

        # Minimum required fields of the primary storage (an old config called them S3_*)
        local key="${PRIMARY_S3_ACCESS_KEY:-${S3_ACCESS_KEY:-}}"
        local secret="${PRIMARY_S3_SECRET_KEY:-${S3_SECRET_KEY:-}}"
        local bucket="${PRIMARY_S3_BUCKET:-${S3_BUCKET:-}}"
        [[ -n "$key" && -n "$secret" && -n "$bucket" ]] || exit 1

        # Placeholder check (YOUR_ACCESS_KEY; older templates had a non-English prefix with the same suffix)
        case "$key" in YOUR_*|*_ACCESS_KEY) exit 1 ;; esac
        case "$secret" in YOUR_*|*_SECRET_KEY) exit 1 ;; esac

        exit 0
    )
}

# ==============================================================================
# 0. BANNER
# ==============================================================================
clear 2>/dev/null || true
cat <<EOF
${C_BOLD}${C_BLUE}╔═══════════════════════════════════════════════════════════════╗
║   Docker Backup System — Installer                            ║
║   Backup of compose projects to S3 with database auto-dump    ║
╚═══════════════════════════════════════════════════════════════╝${C_RESET}

EOF

log "Source:          $SOURCE_DIR"
log "Target dir:      $TARGET_DIR"
log "Mode:            $([[ "$NON_INTERACTIVE" == "true" ]] && echo "non-interactive" || echo "interactive")"
echo

if ! ask_yn "Continue the installation?" "y"; then
    log "Cancelled."
    exit 0
fi

# ==============================================================================
# 1. CHECKING THE SOURCE FILES
# ==============================================================================
log_step "Checking the source files"

REQUIRED_FILES=(
    docker-backup.sh
    docker-restore.sh
    lib.sh
    ui.sh
    menu.sh
    validate-config.sh
    setup-cron.sh
)

for f in "${REQUIRED_FILES[@]}"; do
    if [[ -f "$SOURCE_DIR/$f" ]]; then
        log_ok "$f"
    else
        log_err "Not found: $SOURCE_DIR/$f"
        fail "Required files are missing. Make sure install.sh is run from the unpacked archive."
    fi
done

# Config template. The working backup.conf is not in the repository — it holds keys.
CONF_TEMPLATE="$SOURCE_DIR/backup.conf.example"
[[ -f "$CONF_TEMPLATE" ]] || fail "Not found: $CONF_TEMPLATE"
log_ok "backup.conf.example (config template)"

# ==============================================================================
# 2. INSTALLING DEPENDENCIES
# ==============================================================================
if [[ "$SKIP_DEPS" != "true" ]]; then
    log_step "Installing dependencies"

    # --- Detect the distro's package manager ---
    PKG_MGR=""
    for _pm in apt-get dnf yum zypper pacman apk; do
        if command -v "$_pm" >/dev/null 2>&1; then PKG_MGR="$_pm"; break; fi
    done
    if [[ -n "$PKG_MGR" ]]; then
        log "  Package manager: ${PKG_MGR}"
    else
        log_warn "Could not recognize the package manager (apt/dnf/yum/zypper/pacman/apk)."
        log "    Install manually: jq tar gzip dos2unix curl gpg cron, and aws-cli."
    fi

    # --- Base packages: only what is missing, names per distro ---
    # pkg_for <command> — the package that provides it with this package manager
    pkg_for() {
        case "$PKG_MGR:$1" in
            apt-get:gpg)              echo gnupg ;;
            dnf:gpg|yum:gpg)          echo gnupg2 ;;
            zypper:gpg)               echo gpg2 ;;
            *:gpg)                    echo gnupg ;;
            apt-get:gpg-agent)        echo gpg-agent ;;
            dnf:gpg-agent|yum:gpg-agent) echo gnupg2 ;;      # replaces gnupg2-minimal (it has no agent)
            zypper:gpg-agent)         echo gpg2 ;;
            *:gpg-agent)              echo gnupg ;;
            apt-get:crontab|zypper:crontab) echo cron ;;
            apk:crontab)              echo dcron ;;
            *:crontab)                echo cronie ;;
            apt-get:whiptail)         echo whiptail ;;
            pacman:whiptail)          echo libnewt ;;
            *:whiptail)               echo newt ;;
            *:flock)                  echo util-linux ;;
            *:find)                   echo findutils ;;
            apt-get:pgrep|apk:pgrep|zypper:pgrep) echo procps ;;
            *:pgrep)                  echo procps-ng ;;
            *)                        echo "$1" ;;
        esac
    }
    # pm_install <package…> — exit code of the package manager. Its output (dpkg prints pages even with -qq) is
    # shown only when it fails: the last lines, which say why.
    pm_install() {
        local out rc=0
        out="$(case "$PKG_MGR" in
            # Wait for the lock: right after boot unattended-upgrades often holds it
            apt-get) DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -qq "$@" ;;
            dnf|yum) "$PKG_MGR" install -y -q "$@" ;;
            zypper)  zypper --non-interactive -q install -y "$@" ;;
            pacman)  pacman -S --noconfirm --needed "$@" ;;
            apk)     apk add --no-cache -q "$@" ;;
            *)       exit 1 ;;
        esac 2>&1)" || rc=$?
        (( rc == 0 )) || printf '%s\n' "$out" | tail -n 15 | sed 's/^/    /' >&2
        return "$rc"
    }
    install_base_deps() {
        local -a want=() failed=()
        local c p
        for c in jq tar gzip dos2unix curl gpg gpg-agent crontab whiptail flock unzip find pgrep logrotate; do
            command -v "$c" >/dev/null 2>&1 && continue
            p="$(pkg_for "$c")"
            # gpg and gpg-agent are one package on most systems — once in the list
            local w dup=false
            for w in ${want[@]+"${want[@]}"}; do [[ "$w" == "$p" ]] && dup=true; done
            $dup || want+=("$p")
        done
        [[ -e /etc/ssl/certs/ca-certificates.crt || -e /etc/pki/tls/certs/ca-bundle.crt ]] || want+=(ca-certificates)
        # Alpine: busybox has date/stat/sed/grep/find, but not the GNU options the scripts use (date -d, stat -c…)
        [[ "$PKG_MGR" == "apk" ]] && want+=(coreutils findutils grep sed tar gzip util-linux procps)
        (( ${#want[@]} )) || { log_ok "Base packages are already there"; return 0; }
        log "  Installing: $(IFS=' '; printf '%s' "${want[*]}")"
        case "$PKG_MGR" in
            apt-get) apt-get -o DPkg::Lock::Timeout=300 update -qq || true ;;
            pacman)  pacman -Sy --noconfirm >/dev/null || true ;;
        esac
        # A package manager busy right after boot (dnf-makecache, unattended-upgrades, packagekit) fails
        # the first try: wait and try again before going package by package
        local try
        for try in 1 2 3 4 5 6; do
            pm_install "${want[@]}" && { log_ok "Base packages installed"; return 0; }
            (( try < 6 )) && { log "  The package manager failed or is busy — trying again in 20 s ($try/6)..."; sleep 20; }
        done
        # One bad name (or a conflict, like curl with curl-minimal) fails the whole list — one by one
        for p in "${want[@]}"; do
            pm_install "$p" >/dev/null 2>&1 && continue
            # dnf: a -minimal variant (gnupg2-minimal on Amazon Linux) blocks the full package — swap it
            [[ "$PKG_MGR" == "dnf" ]] && dnf install -y -q --allowerasing "$p" >/dev/null 2>&1 && continue
            failed+=("$p")
        done
        if (( ${#failed[@]} )); then
            log_warn "Could not install: $(IFS=' '; printf '%s' "${failed[*]}") — install them by hand"
            return 1
        fi
        log_ok "Base packages installed"
    }
    if [[ -n "$PKG_MGR" ]]; then
        install_base_deps || true
    fi

    # --- snapd — only a fallback path for aws-cli (see below) ---
    ensure_snapd() {
        if command -v snap >/dev/null 2>&1; then
            log_ok "snapd is already installed"
            return 0
        fi
        log "  Installing snapd..."
        case "$PKG_MGR" in
            apt-get) apt-get install -y -qq snapd ;;
            dnf|yum) "$PKG_MGR" install -y snapd ;;
            zypper)
                zypper --non-interactive install -y snapd 2>/dev/null || {
                    log_warn "snapd is not in the openSUSE repositories — no snap fallback"
                    return 1
                }
                ;;
            pacman)
                log_warn "On Arch snapd is only in the AUR — no snap fallback"
                return 1
                ;;
            apk)
                log_warn "Alpine does not support snap — no snap fallback"
                return 1
                ;;
            *) return 1 ;;
        esac || { log_warn "Could not install snapd via ${PKG_MGR}"; return 1; }

        # Outside Ubuntu snapd has to be enabled manually
        if command -v systemctl >/dev/null 2>&1; then
            systemctl enable --now snapd.socket   2>/dev/null || true
            systemctl enable --now snapd.apparmor 2>/dev/null || true
        fi
        # The /snap symlink is needed for classic confinement outside Ubuntu
        [[ -e /snap ]] || ln -s /var/lib/snapd/snap /snap 2>/dev/null || true
        # Wait until snapd is seeded (otherwise 'snap install' fails with 'too early')
        command -v snap >/dev/null 2>&1 && snap wait system seed.loaded 2>/dev/null || true
        command -v snap >/dev/null 2>&1
    }
    # --- AWS CLI v2 ---
    # First — the official AWS installer into /usr/local/bin, snap — only if that failed.
    # aws-cli from snap updates itself in the background, and that has broken uploads: a new version
    # started sending checksums some S3-compatible storages do not accept (see lib.sh), and its CA bundle turned out
    # to lack GlobalSign Root R46 (see s3_cert_check in ui.sh). The official version
    # only changes through update.sh / install.sh. Where it does not run (musl: Alpine), the distro package is used if it is v2.

    # Portable version parsing (no grep -P): "aws-cli/2.15.0 …" -> "2"
    aws_major_ver() { aws --version 2>&1 | sed -n 's#.*aws-cli/\([0-9][0-9]*\).*#\1#p' | head -1; }
    _curr_aws_major="$(command -v aws >/dev/null 2>&1 && aws_major_ver || echo 0)"
    _curr_aws_major="${_curr_aws_major:-0}"

    # Remove an old awscli v1 from the system packages (it gets in the way of v2)
    remove_aws_v1() {
        command -v aws >/dev/null 2>&1 || return 0
        [[ "$(aws_major_ver || echo 0)" -lt 2 ]] || return 0
        log_warn "Found AWS CLI v1 — removing the packaged version before installing v2"
        case "$PKG_MGR" in
            apt-get) apt-get remove -y -qq awscli 2>/dev/null || true ;;
            dnf|yum) "$PKG_MGR" remove -y awscli 2>/dev/null || true ;;
            zypper)  zypper --non-interactive remove -y aws-cli 2>/dev/null || true ;;
            pacman)  pacman -R --noconfirm aws-cli 2>/dev/null || true ;;
            apk)     apk del aws-cli 2>/dev/null || true ;;
        esac
    }

    # The official AWS CLI v2 installer (glibc bundle, x86_64/aarch64)
    install_aws_official() {
        local arch url tmp
        arch="$(uname -m)"
        case "$arch" in
            x86_64|amd64)  url="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" ;;
            aarch64|arm64) url="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" ;;
            *) log_warn "The official AWS CLI v2 bundle exists only for x86_64/aarch64 (yours: ${arch})"; return 1 ;;
        esac
        # The official bundle is built for glibc — it won't run on musl (Alpine)
        # (ldd is not always there; the musl loader is)
        if compgen -G '/lib/ld-musl-*' >/dev/null || { command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; }; then
            log_warn "The system uses musl libc — the official AWS CLI v2 bundle (glibc) does not work."
            log "    Install the gcompat compatibility layer, or use a glibc-based distro."
            return 1
        fi
        command -v curl  >/dev/null 2>&1 || { log_warn "curl is needed for the official installer"; return 1; }
        command -v unzip >/dev/null 2>&1 || { log_warn "unzip is needed for the official installer"; return 1; }

        tmp="$(mktemp -d)" || return 1
        log "  Downloading the official AWS CLI v2 (${arch})..."
        if ! curl -fsSL "$url" -o "${tmp}/awscliv2.zip"; then
            log_warn "Could not download ${url}"; rm -rf "$tmp"; return 1
        fi
        if ! unzip -q "${tmp}/awscliv2.zip" -d "$tmp"; then
            log_warn "Could not unpack the installer"; rm -rf "$tmp"; return 1
        fi
        # --update in case a version is already installed; otherwise a normal install
        if "${tmp}/aws/install" --update >/dev/null 2>&1 || "${tmp}/aws/install" >/dev/null 2>&1; then
            rm -rf "$tmp"
            # Installed is not the same as working: check that it runs here
            if /usr/local/bin/aws --version >/dev/null 2>&1; then return 0; fi
            log_warn "The official AWS CLI v2 installed but does not run on this system — removing it"
            rm -rf /usr/local/aws-cli /usr/local/bin/aws /usr/local/bin/aws_completer
            return 1
        fi
        rm -rf "$tmp"; return 1
    }

    if command -v aws >/dev/null 2>&1 && [[ "$_curr_aws_major" -ge 2 ]]; then
        log_ok "AWS CLI v2 is already installed ($(aws --version 2>&1))"
        # Installed from snap (older versions of this installer did that) — offer to switch to the official one:
        # snap updates aws-cli by itself, and that has broken uploads (see below).
        if [[ "$(command -v aws)" == /snap/* ]]; then
            log_warn "aws-cli is installed from snap — it updates itself, and such updates have broken uploads before"
            if ask_yn "  Install the official aws-cli and remove the snap version?" "y"; then
                if install_aws_official; then
                    hash -r 2>/dev/null || true
                    case ":$PATH:" in *":/usr/local/bin:"*) ;; *) export PATH="/usr/local/bin:$PATH" ;; esac
                    if ! snap remove aws-cli >/dev/null 2>&1; then
                        log_warn "Could not remove the snap version: sudo snap remove aws-cli"
                        log "    While it is there, the old cron job (with /snap/bin first in its PATH) uses it — recreate it: setup-cron.sh"
                    fi
                    hash -r 2>/dev/null || true
                    log_ok "aws is now: $(command -v aws) ($(aws --version 2>&1))"
                else
                    log_warn "The official installer failed — aws from snap stays"
                fi
            fi
        fi
    else
        remove_aws_v1
        aws_installed="false"

        # 1) main path — the official AWS CLI v2 installer
        if install_aws_official; then
            hash -r 2>/dev/null || true
            case ":$PATH:" in *":/usr/local/bin:"*) ;; *) export PATH="/usr/local/bin:$PATH" ;; esac
            aws_installed="true"
        else
            log_warn "The official installer did not work here — trying the distro package, then snap"
        fi

        # 2) the distro's own package — where it is v2 (Alpine, Arch, Fedora); a v1 package is removed again
        if [[ "$aws_installed" != "true" ]]; then
            _aws_pkg=""
            case "$PKG_MGR" in
                apk)    _aws_pkg="aws-cli" ;;
                pacman) _aws_pkg="aws-cli-v2" ;;
                dnf)    _aws_pkg="awscli2" ;;
            esac
            if [[ -n "$_aws_pkg" ]] && pm_install "$_aws_pkg" >/dev/null 2>&1; then
                hash -r 2>/dev/null || true
                if [[ "$(aws_major_ver || echo 0)" -ge 2 ]]; then
                    aws_installed="true"
                    log_ok "AWS CLI v2 from the ${PKG_MGR} package ${_aws_pkg}"
                else
                    remove_aws_v1
                fi
            fi
        fi

        # 3) fallback — snap
        if [[ "$aws_installed" != "true" ]] && ensure_snapd; then
            log "  Installing AWS CLI v2 via snap (snap install aws-cli --classic)..."
            if snap install aws-cli --classic; then
                case ":$PATH:" in *":/snap/bin:"*) ;; *) export PATH="/snap/bin:$PATH" ;; esac
                aws_installed="true"
            else
                log_warn "snap could not install aws-cli either"
            fi
        fi

        if [[ "$aws_installed" == "true" ]]; then
            log_ok "AWS CLI v2 installed ($(aws --version 2>&1 || echo 'aws'))"
        else
            log_warn "Could not install AWS CLI v2 automatically."
            log "    Manually (v2): https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
            log "    Or via snap: sudo snap install aws-cli --classic"
        fi
    fi

    # --- Docker — NOT installed automatically, only checked ---
    if command -v docker >/dev/null 2>&1; then
        log_ok "Docker found ($(docker --version 2>&1 | head -1))"
        if docker compose version >/dev/null 2>&1; then
            log_ok "docker compose found ($(docker compose version 2>&1 | head -1))"
        else
            log_warn "docker compose (v2) is not installed — restore cannot start projects."
            log "    Install the Docker Compose plugin: https://docs.docker.com/compose/install/linux/"
        fi
    else
        log_err "Docker not found!"
        log "    Install Docker for your distro: https://docs.docker.com/engine/install/"
        if ! ask_yn "Continue without Docker (backups won't work)?" "n"; then
            fail "Install Docker and run install.sh again"
        fi
    fi
else
    log_step "Dependencies (--skip-deps — skipping)"
fi

# ==============================================================================
# 3. COPYING FILES
# ==============================================================================
log_step "Copying files to $TARGET_DIR"

# Normalize paths for comparison (drop the trailing slash)
NORM_SOURCE="$(realpath -m "$SOURCE_DIR")"
NORM_TARGET="$(realpath -m "$TARGET_DIR")"

if [[ "$NORM_SOURCE" == "$NORM_TARGET" ]]; then
    # In-place: already in the right directory, no copying needed
    log_ok "In-place installation (source = target = $NORM_TARGET)"
    log "    The files are already in place, no copying needed"

    if [[ -f "$TARGET_DIR/backup.conf" ]]; then
        EXISTING_CONF="true"
        # The message about the conf comes later, after the is_conf_filled check
    else
        # A fresh repository clone: no working config yet — an earlier installation's, or the template
        create_conf
    fi
else
    # Normal mode: copy from source to target

    # Back up existing files if there are any
    if [[ -d "$TARGET_DIR" ]]; then
        if [[ -f "$TARGET_DIR/backup.conf" ]]; then
            BACKUP_CONF_BAK="${TARGET_DIR}/backup.conf.bak.$(date +%Y%m%d_%H%M%S)"
            cp -p "$TARGET_DIR/backup.conf" "$BACKUP_CONF_BAK"
            log_ok "Existing backup.conf saved to $BACKUP_CONF_BAK"
            EXISTING_CONF="true"
        fi
    fi

    mkdir -p "$TARGET_DIR"

    # Copy the files
    for f in "${REQUIRED_FILES[@]}"; do
        cp -f "$SOURCE_DIR/$f" "$TARGET_DIR/$f"
        log_ok "$f"
    done

    # Optional files — copy if present
    for f in pre-backup-hook.example.sh README.md CHANGELOG.md LICENSE VERSION status.sh logs.sh uninstall.sh update.sh verify-restore.sh sync-s3.sh drop-project.sh diagnose-s3.sh diagnose-cron.sh; do
        if [[ -f "$SOURCE_DIR/$f" ]]; then
            cp -f "$SOURCE_DIR/$f" "$TARGET_DIR/$f"
            log_ok "$f (optional)"
        fi
    done

    # The config template is always copied — it shows which options have appeared.
    cp -f "$CONF_TEMPLATE" "$TARGET_DIR/backup.conf.example"
    log_ok "backup.conf.example (template)"

    # The working backup.conf is created ONLY if it doesn't exist yet: overwriting it
    # with the template means losing the configured keys and buckets.
    if [[ -f "$TARGET_DIR/backup.conf" ]]; then
        log_ok "backup.conf already exists — keeping yours (not overwriting)"
    else
        create_conf
    fi
fi

# ==============================================================================
# 4. CRLF conversion and permissions
# ==============================================================================
log_step "CRLF conversion and setting permissions"

if command -v dos2unix >/dev/null 2>&1; then
    dos2unix -q "$TARGET_DIR"/*.sh "$TARGET_DIR"/*.conf "$TARGET_DIR"/*.example 2>/dev/null || true
    log_ok "dos2unix applied to all .sh/.conf/.example"
else
    sed -i 's/\r$//' "$TARGET_DIR"/*.sh "$TARGET_DIR"/*.conf "$TARGET_DIR"/*.example 2>/dev/null || true
    log_ok "CRLF removed via sed"
fi

chmod +x "$TARGET_DIR"/*.sh
log_ok "Scripts made executable (chmod +x)"

# ==============================================================================
# 5. FILLING IN backup.conf
# ==============================================================================
# Logic:
#   - conf does not exist → copied during installation, then filled in
#   - conf exists and is FILLED IN (not placeholders) → left alone
#   - conf exists but is NOT filled in (placeholders) → offer to fill it in
# ==============================================================================

# Old names of the primary storage (S3_*, from older versions) → PRIMARY_S3_*. The edit itself is
# s3_conf_migrate from lib.sh, in a separate bash, so lib.sh doesn't replace the log functions here.
if [[ -f "$TARGET_DIR/backup.conf" ]]; then
    _mig_rc=0
    _mig_out="$(bash -c 'source "$1" && s3_conf_migrate "$2"' _ "$TARGET_DIR/lib.sh" "$TARGET_DIR/backup.conf" 2>&1)" || _mig_rc=$?
    if [[ -n "$_mig_out" ]]; then
        log_step "Storage names in backup.conf"
        while IFS= read -r _l; do
            if (( _mig_rc == 0 )); then log_ok "$_l"; else log_warn "$_l"; fi
        done <<< "$_mig_out"
    fi
fi

# Decide what to do with the config
NEED_FILL_CONF="false"

if [[ "${EXISTING_CONF:-false}" == "true" ]]; then
    if is_conf_filled "$TARGET_DIR/backup.conf"; then
        log_step "Existing backup.conf"
        log_ok "backup.conf holds real values — leaving it as is"
        log "    To reconfigure — edit: $TARGET_DIR/backup.conf"
        # A kept config can still silently do the wrong thing: a setting given twice (the last line wins),
        # or encryption off with its passphrase file in place
        _chk="$(bash -c 'source "$1" >/dev/null 2>&1 || exit 0; source "$2" >/dev/null 2>&1
            conf_duplicates "$2" "$3" | awk -F "\t" "\$6 == 1 { printf \"lost\t%s: your %s (line %s) is overridden by the default %s further down (line %s)\n\", \$1, \$5, \$4, \$3, \$2 }"
            [[ "${ENCRYPT_BACKUPS:-false}" != "true" && -f "${GPG_PASSPHRASE_FILE:-/root/.docker-backup-passphrase}" ]] \
                && printf "encoff\t%s\n" "${GPG_PASSPHRASE_FILE:-/root/.docker-backup-passphrase}"
            true' _ "$TARGET_DIR/lib.sh" "$TARGET_DIR/backup.conf" "$TARGET_DIR/backup.conf.example")"
        while IFS=$'\t' read -r _k _v; do
            case "$_k" in
                lost)   log_warn "    ‼ $_v — delete the lower line" ;;
                encoff) log_warn "    ‼ Encryption is OFF, although the passphrase file $_v exists: ENCRYPT_BACKUPS=\"true\" if that is not deliberate" ;;
            esac
        done <<< "$_chk"
        if [[ -n "${BACKUP_CONF_BAK:-}" ]]; then
            log "    The old copy is saved in: $BACKUP_CONF_BAK"
        fi
    else
        log_step "backup.conf is not filled in"
        log_warn "backup.conf has placeholder values (YOUR_ACCESS_KEY and the like)"
        echo
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
            log_warn "Non-interactive mode — leaving it as is"
            log "    Fill it in manually: sudo nano $TARGET_DIR/backup.conf"
        else
            if ask_yn "Fill in the settings now?" "y"; then
                NEED_FILL_CONF="true"
            else
                log "  Fill it in manually later: sudo nano $TARGET_DIR/backup.conf"
            fi
        fi
    fi
elif [[ "$NON_INTERACTIVE" == "true" ]]; then
    log_step "Config (non-interactive mode)"
    log_warn "backup.conf left with placeholder values"
    log "    Edit it: $TARGET_DIR/backup.conf"
else
    NEED_FILL_CONF="true"
fi

if [[ "$NEED_FILL_CONF" == "true" ]]; then
    log_step "Filling in backup.conf"
    ui_title "Filling in backup.conf"
    ui_note "Now let's set the minimum required settings."
    ui_note "All other parameters can be edited later in $TARGET_DIR/backup.conf or with: sudo docker-backup-s3"

    # ─── Storages: the primary and the copies ───
    # Answers go to ST["role:FIELD"] (store_wizard, ui.sh); written to backup.conf below, by store_save.
    ui_title "Primary S3 — connection settings"
    store_wizard primary "Primary S3" "https://s3.example.com" || { echo "Cancelled." >&2; exit 130; }

    # Copies: secondary and tertiary — each receives every archive after the primary
    for _role in secondary tertiary; do
        case "$_role" in
            secondary) _title="Secondary S3"; _low="the secondary S3"; _what="second" ;;
            tertiary)  _title="Tertiary S3";  _low="the tertiary S3";  _what="third" ;;
        esac
        ui_title "${_title} — a ${_what} copy of every archive (optional)"
        ui_note "The archive is uploaded to the primary S3 first, then duplicated here."
        ST["$_role:ENABLED"]="false"; ST["$_role:REQUIRED"]="false"
        ask_yn "  Enable ${_low}?" "n" || continue
        ST["$_role:ENABLED"]="true"
        store_wizard "$_role" "$_title" "https://s3.other.com" || { echo "Cancelled." >&2; exit 130; }

        ui_note "If the primary upload succeeded but ${_low} failed:"
        ui_note "  no   — just a warning, the backup counts as successful"
        ui_note "  yes  — the backup is marked as failed (this copy is needed too)"
        ask_yn "  Make ${_low} REQUIRED?" "n" && ST["$_role:REQUIRED"]="true"
    done

    # ─── BACKUP_PREFIX ───
    ui_title "Prefix (folder) in the bucket"
    ui_note "Useful if one bucket holds backups from several servers:"
    ui_note "  backups/         — a common prefix (default)"
    ui_note "  backups/srv1/    — a separate folder for this server"
    ui_note "  backups/$(uname -n)/  — split by hostname automatically"
    BACKUP_PREFIX_VAL=$(ask_value "  Prefix" "backups"); BACKUP_PREFIX_VAL="$(trim "$BACKUP_PREFIX_VAL")"
    # Strip slashes on both ends if any
    BACKUP_PREFIX_VAL="${BACKUP_PREFIX_VAL#/}"
    BACKUP_PREFIX_VAL="${BACKUP_PREFIX_VAL%/}"

    # ─── RETENTION_DAYS ───
    ui_title "Backup retention (days)"
    while true; do
        ui_note "Backups older than this will be deleted from S3 automatically:"
        ui_note "  7 — a week,  30 — a month (default),  90 — three months,  365 — a year"
        RETENTION_VAL=$(ask_value "  Keep (days)" "30")
        if [[ "$RETENTION_VAL" =~ ^[0-9]+$ ]] && (( RETENTION_VAL >= 1 )); then
            break
        fi
        ui_note "⚠ Must be a positive number."
        # In non-interactive mode just take the default and move on
        [[ "$NON_INTERACTIVE" == "true" ]] && RETENTION_VAL=30 && break
    done

    # ─── SCAN_DIRS ───
    ui_title "Where to look for compose projects"
    ui_note "Folders to LOOK in for docker-compose projects (projects with running containers are found anyway)."
    ui_note "Not for exclusions: data to leave out goes to BIND_BLACKLIST_REGEX / BIND_EXCLUDE_PATHS in backup.conf."
    SCAN_DIRS=$(ask_value "  Directories, space-separated" "/opt /home /root /srv")

    # ─── Encryption ───
    # Asked, not left at the template's "false": a passphrase file already on the server means backups were
    # encrypted before, and starting unencrypted without a word is the thing this tool must never do.
    ui_title "Encryption"
    PASS_FILE="/root/.docker-backup-passphrase"
    ENC_VAL="false"
    if [[ -f "$PASS_FILE" ]]; then
        ui_note "A passphrase file is already here: $PASS_FILE (backups were encrypted with it)."
        ask_yn "  Encrypt backups with it (GPG, AES-256)?" "y" && ENC_VAL="true"
    else
        ui_note "GPG encryption with a passphrase file. The storages then hold only ciphertext."
        ui_note "⚠ Without the passphrase the backups cannot be restored: keep a copy OFF this server."
        if ask_yn "  Encrypt backups (a new passphrase is generated into $PASS_FILE)?" "y"; then
            if (umask 077; head -c 48 /dev/urandom | base64 | tr -d '\n' > "$PASS_FILE") && chmod 600 "$PASS_FILE"; then
                ENC_VAL="true"
                ui_later "🔐 A new passphrase is in $PASS_FILE — copy it to your password manager now: sudo cat $PASS_FILE"
                log_ok "Passphrase generated: $PASS_FILE — copy it off the server: sudo cat $PASS_FILE"
            else
                log_warn "Could not create $PASS_FILE — encryption stays off"
            fi
        fi
    fi

    # ─── The server's name in messages ───
    ui_title "Server name"
    NAME_VAL=$(ask_value "  Name of this server in notifications" "$(uname -n)"); NAME_VAL="$(trim "$NAME_VAL")"
    [[ "$NAME_VAL" == "$(uname -n)" ]] && NAME_VAL=""   # empty = the hostname, as the template says

    # ─── Notifications (wizards in ui.sh, each sends a test message) ───
    NOTIFY_LIB="$TARGET_DIR/lib.sh"
    NOTIFY_SET=""
    notify_load   # the template defaults (auto, starttls) stay if a wizard is skipped
    ui_title "Notifications (optional)"
    if ask_yn "  Set up Telegram notifications?" "n"; then tg_wizard && NOTIFY_SET=1; fi
    ui_title "Notifications (optional)"
    if ask_yn "  Set up a webhook (Discord/Slack/Mattermost/custom)?" "n"; then webhook_wizard && NOTIFY_SET=1; fi
    ui_title "Notifications (optional)"
    if ask_yn "  Set up email notifications (your SMTP server)?" "n"; then email_wizard && NOTIFY_SET=1; fi
    UI_TITLE=""

    # ─── Applying the settings to backup.conf ───
    log "  Applying the settings..."

    for _role in primary secondary tertiary; do
        store_save "$_role"
    done
    conf_set BACKUP_PREFIX  "$BACKUP_PREFIX_VAL"
    conf_set RETENTION_DAYS "$RETENTION_VAL" --raw
    conf_set SCAN_DIRS      "$SCAN_DIRS"
    conf_set ENCRYPT_BACKUPS "$ENC_VAL"
    conf_set GPG_PASSPHRASE_FILE "$PASS_FILE"
    conf_set NOTIFY_NAME    "$NAME_VAL" --allow-empty
    [[ -n "$NOTIFY_SET" ]] && notify_save

    log_ok "backup.conf configured"
fi

# Protect the conf
chmod 600 "$TARGET_DIR/backup.conf"
log_ok "chmod 600 on backup.conf (it holds secrets)"

# ==============================================================================
# 6. LOGROTATE
# ==============================================================================
if [[ "$SKIP_LOGROTATE" != "true" ]]; then
    if [[ ! -d /etc/logrotate.d ]]; then
        log_step "Logrotate"
        log_warn "logrotate is not installed (no /etc/logrotate.d) — the logs will not be rotated"
    elif [[ -f /etc/logrotate.d/docker-backup ]]; then
        log_step "Logrotate"
        log_ok "Already configured (/etc/logrotate.d/docker-backup)"
    else
        log_step "Setting up logrotate"
        if ask_yn "Set up log rotation?" "y"; then
            cat > /etc/logrotate.d/docker-backup <<'EOF'
/var/log/docker-backup.log /var/log/docker-backup-cron.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF
            log_ok "Logrotate configured"
        fi
    fi
fi

# ==============================================================================
# 6b. THE docker-backup-s3 COMMAND (menu.sh)
# ==============================================================================
# A symlink, so the command always runs the installed version. A foreign file with the same name
# is not overwritten.
log_step "The docker-backup-s3 command"
CMD_LINK="/usr/local/bin/docker-backup-s3"
if [[ -L "$CMD_LINK" || ! -e "$CMD_LINK" ]]; then
    ln -sfn "$TARGET_DIR/menu.sh" "$CMD_LINK"
    log_ok "$CMD_LINK → $TARGET_DIR/menu.sh  (the menu: sudo docker-backup-s3)"
else
    log_warn "$CMD_LINK already exists and is not our link — leaving it; the menu: sudo $TARGET_DIR/menu.sh"
fi
# Before 2.0.0 the command was called docker-backup: our old link goes
if [[ -L /usr/local/bin/docker-backup && "$(readlink /usr/local/bin/docker-backup)" == "$TARGET_DIR/menu.sh" ]]; then
    rm -f /usr/local/bin/docker-backup && log_ok "The old command name docker-backup is removed"
fi

# ==============================================================================
# 7. VALIDATION
# ==============================================================================
if [[ "$SKIP_VALIDATE" != "true" ]]; then
    log_step "Validating the configuration"
    if "$TARGET_DIR/validate-config.sh"; then
        log_ok "Validation passed"
    else
        log_warn "Validation found errors — that's expected if the S3 keys aren't filled in yet"
        log "    Fill in backup.conf and run: sudo $TARGET_DIR/validate-config.sh"
    fi
fi

# ==============================================================================
# 8. CRON / SYSTEMD
# ==============================================================================
# Without questions (-y) existing scheduled runs are left alone: setup-cron.sh -y would replace them with
# the default daily one, while the server may have its own schedule. To change it — run setup-cron.sh explicitly.
_cron_exists="false"
if crontab -l 2>/dev/null | grep -q "docker-backup\.sh" \
   || systemctl is-enabled docker-backup.timer >/dev/null 2>&1; then
    _cron_exists="true"
fi
if [[ "$SKIP_CRON" != "true" && "$NON_INTERACTIVE" == "true" && "$_cron_exists" == "true" ]]; then
    log_step "Scheduled runs"
    log_ok "Already configured — leaving as is. To change: sudo $TARGET_DIR/setup-cron.sh"
elif [[ "$SKIP_CRON" != "true" ]]; then
    echo
    if ask_yn "Set up scheduled runs (cron / systemd timer)?" "y"; then
        # An array: with IFS=$'\n\t' "$(echo -y -m …)" would reach setup-cron.sh as one argument
        _cron_args=()
        [[ "$NON_INTERACTIVE" == "true" ]] && _cron_args=(-y -m cron -s daily)
        "$TARGET_DIR/setup-cron.sh" ${_cron_args[@]+"${_cron_args[@]}"}
    else
        log "  Skipped. To set up later: sudo $TARGET_DIR/setup-cron.sh"
    fi
fi

# ==============================================================================
# 9. SUMMARY
# ==============================================================================
echo
echo "${C_BOLD}${C_GREEN}╔═══════════════════════════════════════════════════════════════╗"
echo "║                  ✅  Installation complete                    ║"
echo "╚═══════════════════════════════════════════════════════════════╝${C_RESET}"
echo

echo "${C_BOLD}Installed to:${C_RESET} $TARGET_DIR"
echo

echo "${C_BOLD}Next steps:${C_RESET}"
echo
echo "  ${C_CYAN}•${C_RESET} ${C_BOLD}Menu for everything below:  sudo docker-backup-s3${C_RESET}"
if [[ "${EXISTING_CONF:-false}" != "true" && "$NON_INTERACTIVE" == "true" ]]; then
    echo "  ${C_YELLOW}•${C_RESET} ${C_BOLD}First, fill in the S3 keys, the region and the bucket:${C_RESET}"
    echo "       sudo nano $TARGET_DIR/backup.conf"
    echo
fi
echo "  ${C_CYAN}•${C_RESET} Check the settings:       sudo $TARGET_DIR/validate-config.sh"
echo "  ${C_CYAN}•${C_RESET} Dry run:                  sudo $TARGET_DIR/docker-backup.sh --dry-run"
echo "  ${C_CYAN}•${C_RESET} Real backup:              sudo $TARGET_DIR/docker-backup.sh"
echo "  ${C_CYAN}•${C_RESET} Restore:                  sudo $TARGET_DIR/docker-restore.sh"
[[ -f "$TARGET_DIR/status.sh" ]] && \
echo "  ${C_CYAN}•${C_RESET} Current status:           sudo $TARGET_DIR/status.sh"
[[ -f "$TARGET_DIR/logs.sh" ]] && \
echo "  ${C_CYAN}•${C_RESET} View logs:                sudo $TARGET_DIR/logs.sh"
echo "  ${C_CYAN}•${C_RESET} Cron setup:               sudo $TARGET_DIR/setup-cron.sh"
[[ -f "$TARGET_DIR/uninstall.sh" ]] && \
echo "  ${C_DIM}•${C_RESET} ${C_DIM}Uninstall:                sudo $TARGET_DIR/uninstall.sh${C_RESET}"
echo
echo "${C_DIM}Documentation: $TARGET_DIR/README.md${C_RESET}"
echo
