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

# notify_try <channel> VAR=value… — a test message with these settings, via the installed lib.sh in a
# separate bash (so it doesn't replace the functions here). The error goes to stdout.
notify_try() {
    local ch="$1"; shift
    env "$@" bash -c 'source "$1" >/dev/null 2>&1 || { echo "cannot load lib.sh"; exit 1; }; notify_test "$2" 2>&1 >/dev/null' \
        _ "$TARGET_DIR/lib.sh" "$ch"
}

# Checks whether the minimum required fields in backup.conf hold real values
# usage: is_conf_filled <path-to-conf>
# returns: 0 if everything holds real values, 1 if something is a placeholder/empty
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

    # --- Base packages (package names differ between distros) ---
    install_base_deps() {
        case "$PKG_MGR" in
            apt-get)
                apt-get update -qq || true
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
                    jq tar gzip dos2unix curl gnupg coreutils util-linux cron ca-certificates unzip
                ;;
            dnf|yum)
                "$PKG_MGR" install -y \
                    jq tar gzip dos2unix curl gnupg2 coreutils util-linux cronie ca-certificates unzip
                ;;
            zypper)
                zypper --non-interactive install -y \
                    jq tar gzip dos2unix curl gpg2 coreutils util-linux cron ca-certificates unzip
                ;;
            pacman)
                pacman -Sy --noconfirm --needed \
                    jq tar gzip dos2unix curl gnupg coreutils util-linux cronie ca-certificates unzip
                ;;
            apk)
                apk add --no-cache \
                    bash jq tar gzip dos2unix curl gnupg coreutils util-linux dcron ca-certificates unzip
                ;;
            *) return 1 ;;
        esac
    }
    if [[ -n "$PKG_MGR" ]]; then
        log "  Base packages: jq, tar, gzip, dos2unix, curl, gpg, cron, coreutils…"
        if install_base_deps; then
            log_ok "Base packages installed"
        else
            log_warn "Some base packages did not install — check the output above"
        fi
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
    # only changes through update.sh / install.sh. On musl (Alpine) neither way works.

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
        if command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; then
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
            rm -rf "$tmp"; return 0
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
            log_warn "The official installer failed — trying snap"
        fi

        # 2) fallback — snap
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
        # A fresh repository clone: no working config yet, only the template
        cp -f "$CONF_TEMPLATE" "$TARGET_DIR/backup.conf"
        log_ok "backup.conf created from $(basename "$CONF_TEMPLATE") (needs filling in)"
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
        cp -f "$CONF_TEMPLATE" "$TARGET_DIR/backup.conf"
        log_ok "backup.conf created from the template (needs filling in)"
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
    ui_note "All other parameters can be edited later in $TARGET_DIR/backup.conf or with: sudo docker-backup"

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
    ui_note "  backups/$(hostname)/  — split by hostname automatically"
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
    SCAN_DIRS=$(ask_value "  Directories, space-separated" "/opt /home /root /srv")

    # ─── Notifications ───
    ui_title "Notifications (optional)"
    if ask_yn "  Set up Telegram notifications on errors?" "n"; then
        ui_title "Telegram"
        ui_note "Creating a bot: @BotFather → /newbot → name → username"
        ui_note "Getting the chat_id: @userinfobot → send /start, copy the ID"
        ui_note "⚠ IMPORTANT: once you have the token, open a chat with the bot and send it /start,"
        ui_note "  otherwise it can't message you first!"

        while true; do
            TG_TOKEN=$(ask_value "    Bot Token" ""); TG_TOKEN="$(trim "$TG_TOKEN")"

            if [[ -z "$TG_TOKEN" ]]; then
                log_warn "    The token is empty — skipping Telegram"
                break
            fi

            # Token format: a number:a string of Latin letters/digits/hyphens/underscores
            if ! [[ "$TG_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
                ui_note "⚠ The token has an unusual format."
                ui_note "Expected format: 123456789:ABCdef1234XYZ_abc-DEF"
                if ! ask_yn "    Use it as is?" "n"; then
                    continue
                fi
            fi

            # Check via getMe
            if command -v curl >/dev/null 2>&1; then
                [[ "$UI_MODE" == "plain" ]] && echo -n "    Checking the token via the Telegram API... "
                tg_response=$(curl -s -m 10 "https://api.telegram.org/bot${TG_TOKEN}/getMe" 2>/dev/null || echo "")
                if echo "$tg_response" | grep -q '"ok":true'; then
                    bot_name=$(echo "$tg_response" | sed -n 's/.*"username":"\([^"]*\)".*/\1/p' | head -1)
                    [[ "$UI_MODE" == "plain" ]] && echo "${C_GREEN}OK — @${bot_name}${C_RESET}"
                    ui_later "✓ The token works: @${bot_name}"
                    break
                fi
                [[ "$UI_MODE" == "plain" ]] && echo "${C_RED}FAIL${C_RESET}"
                if [[ -n "$tg_response" ]]; then
                    err_msg=$(echo "$tg_response" | sed -n 's/.*"description":"\([^"]*\)".*/\1/p' || echo "")
                    [[ -n "$err_msg" ]] && ui_note "✗ Telegram replied: $err_msg"
                else
                    ui_note "✗ No response from api.telegram.org (check the internet connection)"
                fi
                if ! ask_yn "    Try entering the token again?" "y"; then
                    TG_TOKEN=""
                    break
                fi
            else
                ui_note "Token check skipped (curl not found)"
                break
            fi
        done

        if [[ -n "$TG_TOKEN" ]]; then
            while true; do
                TG_CHAT=$(ask_value "    Chat ID" ""); TG_CHAT="$(trim "$TG_CHAT")"

                if [[ -z "$TG_CHAT" ]]; then
                    log_warn "    Chat ID is empty — skipping Telegram"
                    TG_TOKEN=""
                    break
                fi

                # Format: a number (negative for groups)
                if ! [[ "$TG_CHAT" =~ ^-?[0-9]+$ ]]; then
                    ui_note "⚠ Chat ID must be a number (negative for groups)"
                    if ! ask_yn "    Try again?" "y"; then
                        TG_TOKEN=""
                        TG_CHAT=""
                        break
                    fi
                    continue
                fi

                # Test message
                [[ "$UI_MODE" == "plain" ]] && echo -n "    Sending a test message... "
                test_msg="🧪 Test message from the installer on $(hostname). Installation succeeded!"
                send_response=$(curl -s -m 10 -X POST \
                    "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
                    --data-urlencode "chat_id=${TG_CHAT}" \
                    --data-urlencode "text=${test_msg}" 2>/dev/null || echo "")

                if echo "$send_response" | grep -q '"ok":true'; then
                    [[ "$UI_MODE" == "plain" ]] && echo "${C_GREEN}OK${C_RESET}"
                    ui_note "✓ Check Telegram — the test message should be there"
                    break
                fi
                [[ "$UI_MODE" == "plain" ]] && echo "${C_RED}FAIL${C_RESET}"
                err_msg=$(echo "$send_response" | sed -n 's/.*"description":"\([^"]*\)".*/\1/p' || echo "")
                if [[ -n "$err_msg" ]]; then
                    ui_note "✗ Telegram replied: $err_msg"
                    # Hints for common errors
                    case "$err_msg" in
                        *"chat not found"*)
                            ui_note "💡 Hint: the chat_id is wrong, OR you haven't messaged the bot yet."
                            ui_note "   Open Telegram → find your bot → press Start or send /start"
                            ;;
                        *"bot was blocked"*|*"Forbidden"*)
                            ui_note "💡 Hint: the bot is blocked by the user — unblock it in Telegram"
                            ;;
                        *"chat_id is empty"*)
                            ui_note "💡 Hint: Chat ID is empty or invalid"
                            ;;
                    esac
                fi
                if ! ask_yn "    Try another Chat ID?" "y"; then
                    TG_TOKEN=""
                    TG_CHAT=""
                    break
                fi
            done
        fi
    fi

    # Optional: webhook
    ui_title "Notifications (optional)"
    if ask_yn "  Set up a webhook (Discord/Slack/Mattermost/custom)?" "n"; then
        ui_title "Webhook"
        ui_note "Discord: channel settings → Integrations → Webhooks → Copy Webhook URL."
        ui_note "Slack: an app with Incoming Webhooks. Any other URL gets JSON with level, server, title, details."
        while true; do
            NOTIFY_URL=$(ask_value "    Webhook URL" ""); NOTIFY_URL="$(trim "$NOTIFY_URL")"
            [[ -z "$NOTIFY_URL" ]] && break
            if ! [[ "$NOTIFY_URL" =~ ^https?:// ]]; then
                ui_note "✗ The URL must start with http:// or https://"
                NOTIFY_URL=""
                [[ "$NON_INTERACTIVE" == "true" ]] && break
                continue
            fi
            if _t_err="$(notify_try webhook NOTIFY_WEBHOOK_URL="$NOTIFY_URL")"; then
                ui_note "✓ The test message was accepted — check the channel"
                break
            fi
            ui_note "✗ $_t_err"
            ask_yn "    Enter the URL again?" "y" || { ask_yn "    Keep this URL anyway?" "n" || NOTIFY_URL=""; break; }
        done
    fi

    # Optional: email
    ui_title "Notifications (optional)"
    if ask_yn "  Set up email notifications (your SMTP server)?" "n"; then
        ui_title "Email"
        ui_note "Any SMTP account works: your mail server, Gmail/Outlook (with an app password), a mail service."
        while true; do
            MAIL_TO=$(ask_value "    Send to (addresses, space-separated)" "${MAIL_TO:-}"); MAIL_TO="$(trim "$MAIL_TO")"
            [[ -z "$MAIL_TO" ]] && break
            SMTP_HOST_VAL=$(ask_value "    SMTP server" "${SMTP_HOST_VAL:-}"); SMTP_HOST_VAL="$(trim "$SMTP_HOST_VAL")"
            [[ -z "$SMTP_HOST_VAL" ]] && { MAIL_TO=""; break; }
            UI_DEFAULT="${SMTP_SEC_VAL:-starttls}"
            SMTP_SEC_VAL=$(ui_menu "    Connection security" \
                starttls "STARTTLS, port 587 (most servers)" \
                tls      "TLS, port 465" \
                none     "none, port 25 (unencrypted)") || SMTP_SEC_VAL="starttls"
            UI_DEFAULT=""
            case "$SMTP_SEC_VAL" in tls) _p=465 ;; none) _p=25 ;; *) _p=587 ;; esac
            SMTP_PORT_VAL=$(ask_value "    Port" "$_p"); SMTP_PORT_VAL="$(trim "$SMTP_PORT_VAL")"
            [[ "$SMTP_PORT_VAL" == "$_p" ]] && SMTP_PORT_VAL=""
            SMTP_USER_VAL=$(ask_value "    Login (empty — without login)" "${SMTP_USER_VAL:-}"); SMTP_USER_VAL="$(trim "$SMTP_USER_VAL")"
            SMTP_PASS_VAL=""
            [[ -n "$SMTP_USER_VAL" ]] && SMTP_PASS_VAL=$(ask_secret "    Password")
            SMTP_FROM_VAL=$(ask_value "    Sender address" "${SMTP_FROM_VAL:-$SMTP_USER_VAL}"); SMTP_FROM_VAL="$(trim "$SMTP_FROM_VAL")"
            [[ "$NON_INTERACTIVE" == "true" ]] && break
            if _t_err="$(notify_try email EMAIL_TO="$MAIL_TO" SMTP_HOST="$SMTP_HOST_VAL" SMTP_SECURITY="$SMTP_SEC_VAL" \
                    SMTP_PORT="$SMTP_PORT_VAL" SMTP_USER="$SMTP_USER_VAL" SMTP_PASSWORD="$SMTP_PASS_VAL" SMTP_FROM="$SMTP_FROM_VAL")"; then
                ui_note "✓ The test email was sent — check the inbox (and spam)"
                break
            fi
            ui_note "✗ $_t_err"
            ask_yn "    Enter the settings again?" "y" || { ask_yn "    Keep these settings anyway?" "n" || MAIL_TO=""; break; }
        done
    fi
    UI_TITLE=""

    # ─── Applying the settings to backup.conf ───
    log "  Applying the settings..."

    for _role in primary secondary tertiary; do
        store_save "$_role"
    done
    conf_set BACKUP_PREFIX  "$BACKUP_PREFIX_VAL"
    conf_set RETENTION_DAYS "$RETENTION_VAL" --raw
    conf_set SCAN_DIRS      "$SCAN_DIRS"
    conf_set TELEGRAM_BOT_TOKEN "${TG_TOKEN:-}"
    conf_set TELEGRAM_CHAT_ID   "${TG_CHAT:-}"
    conf_set NOTIFY_WEBHOOK_URL "${NOTIFY_URL:-}"
    conf_set EMAIL_TO      "${MAIL_TO:-}"
    if [[ -n "${MAIL_TO:-}" ]]; then
        conf_set SMTP_HOST     "${SMTP_HOST_VAL:-}"
        conf_set SMTP_SECURITY "${SMTP_SEC_VAL:-starttls}"
        conf_set SMTP_PORT     "${SMTP_PORT_VAL:-}"
        conf_set SMTP_USER     "${SMTP_USER_VAL:-}"
        conf_set SMTP_PASSWORD "${SMTP_PASS_VAL:-}"
        conf_set SMTP_FROM     "${SMTP_FROM_VAL:-}"
    fi

    log_ok "backup.conf configured"
fi

# Protect the conf
chmod 600 "$TARGET_DIR/backup.conf"
log_ok "chmod 600 on backup.conf (it holds secrets)"

# ==============================================================================
# 6. LOGROTATE
# ==============================================================================
if [[ "$SKIP_LOGROTATE" != "true" ]]; then
    if [[ -f /etc/logrotate.d/docker-backup ]]; then
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
# 6b. THE docker-backup COMMAND (menu.sh)
# ==============================================================================
# A symlink, so the command always runs the installed version. A foreign file with the same name
# is not overwritten.
log_step "The docker-backup command"
CMD_LINK="/usr/local/bin/docker-backup"
if [[ -L "$CMD_LINK" || ! -e "$CMD_LINK" ]]; then
    ln -sfn "$TARGET_DIR/menu.sh" "$CMD_LINK"
    log_ok "$CMD_LINK → $TARGET_DIR/menu.sh  (the menu: sudo docker-backup)"
else
    log_warn "$CMD_LINK already exists and is not our link — leaving it; the menu: sudo $TARGET_DIR/menu.sh"
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
echo "║                  ✅  Installation complete                     ║"
echo "╚═══════════════════════════════════════════════════════════════╝${C_RESET}"
echo

echo "${C_BOLD}Installed to:${C_RESET} $TARGET_DIR"
echo

echo "${C_BOLD}Next steps:${C_RESET}"
echo
echo "  ${C_CYAN}•${C_RESET} ${C_BOLD}Menu for everything below:  sudo docker-backup${C_RESET}"
if [[ "${EXISTING_CONF:-false}" != "true" && "$NON_INTERACTIVE" == "true" ]]; then
    echo "  ${C_YELLOW}1.${C_RESET} Fill in the S3 keys and the bucket:"
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
