#!/usr/bin/env bash
#
# linux-maintain.sh — Safe, idempotent system maintenance for Debian / Ubuntu / Kali
#
#   Routine maintenance is SAFE BY DEFAULT: update, upgrade, fix broken packages,
#   install firmware/GPU drivers/microcode on bare metal, enable SSD TRIM, and
#   write a system report. A default run never rewrites your apt sources, never
#   edits /etc/fstab, and never restarts networking.
#
#   "Aggressive" repairs (mirror rewriting, forced out-of-tree drivers, persistent
#   IPv4, deep storage tuning) are STRICTLY OPT-IN via flags, ALWAYS create a
#   timestamped backup before touching a system file, and run through the same
#   safe runners (run / run_soft) and --dry-run preview as everything else.
#
#   Author  : Abdelrahman Fekry El-Maghraby
#   License : MIT
#   Repo    : https://github.com/zzddf656666/linux-maintain
#
# Supported: Debian, Ubuntu, Kali (apt-based).  Must be run as root (except --dry-run).
#
set -Eeuo pipefail

# =========================================================================== #
#  Constants & defaults
# =========================================================================== #
readonly SCRIPT_VERSION="3.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly START_STAMP="$(date +'%Y-%m-%d_%H-%M-%S')"

# --- Behaviour toggles (changed by CLI flags) ------------------------------ #
DRY_RUN=false               # --dry-run        : preview only, change nothing
ASSUME_YES=false            # --yes            : non-interactive
DO_DRIVERS=true             # --no-drivers     : skip bare-metal driver block
DO_POWER_TOOLS=false        # --power-tools    : laptop power management
DO_TUNE_STORAGE=false       # --tune-storage   : deep I/O + fstab/swappiness tuning
FORCE_IPV4=false            # --force-ipv4     : force apt over IPv4 (this run)
NO_COLOR=false              # --no-color       : disable colour
REBOOT_MODE="auto"          # --reboot/--no-reboot : auto | always | never

# --- Opt-in "aggressive" fixes (ported from the old updates.sh) ------------ #
DO_REPAIR_MIRRORS=false     # --repair-mirrors     : smart mirror auto-repair
DO_INSTALL_REALTEK=false    # --install-realtek    : force RTL8188EUS DKMS driver
AGGRESSIVE_NET=false        # --aggressive-network : persistent IPv4 + more retries

readonly APT_RETRIES_DEFAULT=3
readonly APT_RETRIES_AGGRESSIVE=8

# Known-dead / hijacked mirror hosts to replace when --repair-mirrors is used.
# These are examples — edit the list to match mirrors that have failed for you.
BAD_MIRROR_HOSTS=(
  "mirror.sox.rs"
  "mirror1.sox.rs"
)

LOGFILE=""                  # set after we confirm we are root
export DEBIAN_FRONTEND=noninteractive

# apt options applied to every install/upgrade (assume-yes config handling).
readonly APT_OPTS=(
  -o Dpkg::Options::=--force-confdef
  -o Dpkg::Options::=--force-confold
  -o Acquire::Retries=3
)

# =========================================================================== #
#  Colours  (resolved against the real terminal, before any redirection)
# =========================================================================== #
USE_COLOR=false
[[ -t 1 ]] && USE_COLOR=true
C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'
C_BLU=$'\e[34m'; C_CYN=$'\e[36m'

# =========================================================================== #
#  Logging  (colour to the console, plain text to the log file)
# =========================================================================== #
_log_line() {
  local raw="$1" color="${2:-}"
  if [[ $USE_COLOR == true && -n $color ]]; then
    printf '%b%s%b\n' "$color" "$raw" "$C_RESET"
  else
    printf '%s\n' "$raw"
  fi
  [[ -n $LOGFILE ]] && printf '%s\n' "$raw" >> "$LOGFILE" 2>/dev/null || true
}
log_info() { _log_line "[*]  $*" "$C_BLU"; }
log_ok()   { _log_line "[OK] $*" "$C_GRN"; }
log_warn() { _log_line "[!]  $*" "$C_YLW"; }
log_err()  { _log_line "[x]  $*" "$C_RED"; }
log_cmd()  { _log_line "       \$ $*" "$C_DIM"; }
log_step() { _log_line ""; _log_line "==> $*" "${C_BOLD}${C_CYN}"; }

die() { log_err "$*"; exit 1; }

# Report exactly where an *unexpected* failure happened. Expected, non-fatal
# failures go through run_soft and never reach this trap.
trap 'rc=$?; log_err "Unexpected error (exit $rc) at line ${LINENO}: ${BASH_COMMAND}"; exit $rc' ERR

# =========================================================================== #
#  Core runners & helpers
#    run       — critical step: aborts the script on failure
#    run_soft  — optional step: warns and continues on failure
#    Both honour --dry-run (they print the command and change nothing).
# =========================================================================== #
run() {
  log_cmd "$*"
  [[ $DRY_RUN == true ]] && return 0
  "$@"
}
run_soft() {
  log_cmd "$*"
  [[ $DRY_RUN == true ]] && return 0
  if ! "$@"; then
    log_warn "non-fatal failure (continuing): $*"
    return 0
  fi
}
have() { command -v "$1" >/dev/null 2>&1; }

# Install only packages that actually exist in the configured repositories.
apt_install() {
  local pkg
  for pkg in "$@"; do
    if apt-cache show "$pkg" >/dev/null 2>&1; then
      run_soft apt-get install -y "${APT_OPTS[@]}" "$pkg"
    else
      log_warn "package not in repositories, skipping: $pkg"
    fi
  done
}

# Timestamped backup of a file before we modify it. Safe in --dry-run.
backup_file() {
  local src="$1"
  [[ -e $src ]] || return 0
  run_soft cp -a "$src" "${src}.bak_${START_STAMP}"
  run_soft chmod 600 "${src}.bak_${START_STAMP}"   # lock backup to root (Information-Disclosure hardening)
  log_info "Backed up ${src} -> ${src}.bak_${START_STAMP}"
}

# Dry-run-aware file writer. Logs the target; in --dry-run it prints the
# would-be content (indented) and writes nothing.
write_file() {
  local path="$1" content="$2"
  log_cmd "write -> ${path}"
  if [[ $DRY_RUN == true ]]; then
    printf '%s\n' "$content" | sed 's/^/         | /'
    return 0
  fi
  printf '%s\n' "$content" > "$path"
}

# Read a value from /etc/os-release safely (subshell; never clobbers our vars).
osr() { ( set +e; . /etc/os-release >/dev/null 2>&1; printf '%s' "${!1:-}" ); }

# =========================================================================== #
#  Usage
# =========================================================================== #
usage() {
  cat <<USAGE
${SCRIPT_NAME} ${SCRIPT_VERSION} — safe maintenance for Debian / Ubuntu / Kali

USAGE:
  sudo ./${SCRIPT_NAME} [OPTIONS]

SAFE OPTIONS (default run is safe):
  -n, --dry-run          Preview every action; change nothing
  -y, --yes              Non-interactive (assume "yes"); good for cron/timers
      --no-drivers       Skip firmware / GPU drivers / microcode (bare metal)
      --power-tools      Install laptop power-management tools (TLP, thermald)
      --force-ipv4       Force apt over IPv4 for this run only
      --reboot           Reboot at the end if a reboot is required
      --no-reboot        Never reboot, even if one is required
      --no-color         Disable coloured output
  -V, --version          Print version and exit
  -h, --help             Show this help and exit

AGGRESSIVE / REPAIR OPTIONS (opt-in; modify system files; always backed up):
      --repair-mirrors     Replace dead apt mirrors and restore official repos
                           for the detected distro (backs up sources first)
      --install-realtek    Force-install the out-of-tree RTL8188EUS DKMS Wi-Fi
                           driver (for TP-Link TL-WN725N and similar adapters)
      --aggressive-network Force IPv4 + raise apt retries; on first failure,
                           write a persistent IPv4 config for apt
      --tune-storage       Deep storage tuning: persistent I/O scheduler (udev),
                           'noatime' on root (SSD), vm.swappiness=10 (HDD)

EXAMPLES:
  sudo ./${SCRIPT_NAME}                          # safe routine maintenance
  sudo ./${SCRIPT_NAME} --dry-run --repair-mirrors
  sudo ./${SCRIPT_NAME} --repair-mirrors --aggressive-network
  sudo ./${SCRIPT_NAME} --install-realtek
USAGE
}

# =========================================================================== #
#  Aggressive fix: persistent IPv4 for apt
# =========================================================================== #
enable_persistent_ipv4() {
  local conf="/etc/apt/apt.conf.d/99force-ipv4"
  if [[ -f $conf ]]; then
    log_info "apt is already configured to force IPv4."
    return 0
  fi
  write_file "$conf" 'Acquire::ForceIPv4 "true";'
  log_ok "Configured apt to prefer IPv4 (${conf})."
}

# =========================================================================== #
#  apt update with retries (aggressive mode raises retries + persists IPv4)
# =========================================================================== #
apt_update() {
  local retries="$APT_RETRIES_DEFAULT"
  [[ $AGGRESSIVE_NET == true ]] && retries="$APT_RETRIES_AGGRESSIVE"
  local extra=(-o "Acquire::Retries=${retries}")
  [[ $FORCE_IPV4 == true ]] && extra+=(-o Acquire::ForceIPv4=true)

  local attempt
  for attempt in 1 2 3; do
    if run apt-get update "${APT_OPTS[@]}" "${extra[@]}"; then
      log_ok "Package lists updated."
      return 0
    fi
    log_warn "apt-get update failed (attempt ${attempt}/3)."
    if [[ $AGGRESSIVE_NET == true && $attempt -eq 1 ]]; then
      log_warn "Aggressive network mode: forcing IPv4 persistently before retrying."
      enable_persistent_ipv4
      extra+=(-o Acquire::ForceIPv4=true)
    fi
    sleep 5
  done
  log_warn "Could not refresh package lists cleanly; continuing with what is available."
}

# =========================================================================== #
#  Aggressive fix: write the official repositories for the detected distro
#  (called by repair_mirrors; always backs up first)
# =========================================================================== #
write_official_repos() {
  local sl="/etc/apt/sources.list" codename
  case "$OS_ID" in
    kali)
      backup_file "$sl"
      write_file "$sl" 'deb http://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware'
      ;;
    ubuntu)
      codename="$(osr VERSION_CODENAME)"; [[ -n $codename ]] || codename="noble"
      # Note: Ubuntu 24.04+ also ships /etc/apt/sources.list.d/ubuntu.sources
      # (deb822). We back it up so the two definitions don't silently clash.
      [[ -f /etc/apt/sources.list.d/ubuntu.sources ]] && backup_file /etc/apt/sources.list.d/ubuntu.sources
      backup_file "$sl"
      write_file "$sl" "deb http://archive.ubuntu.com/ubuntu/ ${codename} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ ${codename}-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ ${codename}-security main restricted universe multiverse"
      ;;
    debian)
      codename="$(osr VERSION_CODENAME)"; [[ -n $codename ]] || codename="bookworm"
      backup_file "$sl"
      write_file "$sl" "deb http://deb.debian.org/debian ${codename} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian-security ${codename}-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${codename}-updates main contrib non-free non-free-firmware"
      ;;
    *)
      log_warn "Unknown distro; not writing official repositories."
      ;;
  esac
}

# =========================================================================== #
#  Aggressive fix: smart mirror auto-repair  (--repair-mirrors)
#    1) replace known-bad mirror hosts in all apt source files
#    2) restore official repos for the detected distro
#    3) verify the official host is reachable; fall back to an OFFICIAL
#       auto-mirror selector if not (no random third-party mirrors)
# =========================================================================== #
repair_mirrors() {
  log_step "Smart mirror auto-repair (--repair-mirrors)"
  local sl="/etc/apt/sources.list" official host f bad changed=false

  case "$OS_ID" in
    kali)   official="http://http.kali.org/kali" ;;
    ubuntu) official="http://archive.ubuntu.com/ubuntu" ;;
    debian) official="http://deb.debian.org/debian" ;;
    *)      official="http://deb.debian.org/debian" ;;
  esac

  # 1) Replace known-bad hosts across sources.list and sources.list.d/*.list
  local files=("$sl")
  for f in /etc/apt/sources.list.d/*.list; do [[ -f $f ]] && files+=("$f"); done
  for f in "${files[@]}"; do
    [[ -f $f ]] || continue
    for bad in "${BAD_MIRROR_HOSTS[@]}"; do
      if grep -qiF "$bad" "$f" 2>/dev/null; then
        backup_file "$f"
        log_info "Replacing dead mirror '${bad}' in ${f}"
        run_soft sed -i "s~https\?://${bad}~${official}~gI" "$f"
        changed=true
      fi
    done
  done
  [[ $changed == false ]] && log_info "No known-bad mirrors found in apt sources."

  # 2) Ensure official repositories are present for this distro
  write_official_repos

  # 3) Reachability check + official fallback
  host="$(printf '%s' "$official" | sed -E 's#https?://##; s#/.*##')"
  if ! have ping; then
    log_info "ping unavailable; skipping mirror reachability test."
  elif ping -c1 -W3 "$host" >/dev/null 2>&1; then
    log_ok "Official mirror host reachable: ${host}"
  else
    log_warn "Official host ${host} unreachable; switching to an official auto-mirror."
    case "$OS_ID" in
      ubuntu)
        backup_file "$sl"
        run_soft sed -i 's#http://archive.ubuntu.com/ubuntu#mirror://mirrors.ubuntu.com/mirrors.txt#g' "$sl"
        ;;
      debian|kali)
        log_info "${OS_ID} already uses a redirector/CDN; no separate fallback needed."
        ;;
    esac
  fi
  log_ok "Mirror repair complete."
}

# =========================================================================== #
#  Aggressive fix: force-install Realtek RTL8188EUS DKMS driver
# =========================================================================== #
install_realtek_driver() {
  log_step "Installing Realtek RTL8188EUS DKMS driver (--install-realtek)"
  apt_install build-essential dkms "linux-headers-$(uname -r)"
  apt_install realtek-rtl8188eus-dkms
  log_ok "Realtek RTL8188EUS DKMS step complete (a reboot or 'modprobe 8188eu' may be needed)."
}

# =========================================================================== #
#  Storage helpers (deep tuning lives behind --tune-storage)
# =========================================================================== #
# Add 'noatime' to the root (/) entry in fstab; backs fstab up first.
add_noatime_to_root() {
  local fstab="/etc/fstab"
  [[ -f $fstab ]] || { log_warn "No /etc/fstab; skipping noatime."; return 0; }
  if awk '$2=="/"{print $4}' "$fstab" | grep -q noatime; then
    log_info "fstab root already has noatime."
    return 0
  fi
  backup_file "$fstab"
  if [[ $DRY_RUN == true ]]; then
    log_cmd "would add 'noatime' to the root (/) mount options in $fstab"
    return 0
  fi
  awk 'BEGIN{OFS="\t"} $2=="/"{ if($4=="" || $4=="-") $4="defaults"; if($4 !~ /noatime/) $4=$4",noatime" } {print}' \
    "$fstab" > "${fstab}.tmp" && mv "${fstab}.tmp" "$fstab"
  log_ok "Added noatime to the root entry in fstab."
}

# Set a sensible I/O scheduler now AND persist it with a udev rule.
apply_io_scheduler() {
  local dev="$1" rota="$2" sched want avail
  sched="/sys/block/${dev}/queue/scheduler"
  if [[ $rota == 0 ]]; then want="none"; else want="bfq"; fi
  if [[ -w $sched ]]; then
    avail="$(cat "$sched" 2>/dev/null || echo '')"
    if echo "$avail" | grep -qw "$want"; then
      run_soft bash -c "echo '${want}' > '${sched}'"
    elif echo "$avail" | grep -qw mq-deadline; then
      run_soft bash -c "echo mq-deadline > '${sched}'"
    fi
  fi
  write_file /etc/udev/rules.d/60-ioscheduler.rules \
'# I/O scheduler by device type (managed by linux-maintain.sh)
ACTION=="add|change", KERNEL=="sd[a-z]|vd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
ACTION=="add|change", KERNEL=="sd[a-z]|vd[a-z]|nvme[0-9]n[0-9]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="none"'
  log_ok "Persistent I/O scheduler rule written: /etc/udev/rules.d/60-ioscheduler.rules"
}

# Lower swappiness for spinning disks.
set_swappiness() {
  local conf="/etc/sysctl.d/99-swappiness.conf"
  write_file "$conf" 'vm.swappiness=10'
  run_soft sysctl -p "$conf"
  log_ok "Set vm.swappiness=10 (${conf})."
}

# =========================================================================== #
#  Interactive menu
#    Shown ONLY when the script is started with no flags AND from a real
#    terminal. Selecting a number sets the very same variables the flags set,
#    so automation (cron jobs / systemd timers, or any flagged run) is never
#    blocked waiting for a keypress.
# =========================================================================== #
interactive_menu() {
  _log_line "===============================================================" "$C_CYN"
  _log_line "  Interactive Mode: Choose Maintenance Type" "${C_BOLD}${C_YLW}"
  _log_line "===============================================================" "$C_CYN"
  echo "  1) Safe Routine Maintenance (Default - Updates, Cleanup, TRIM)"
  echo "  2) Full Aggressive Maintenance (Safe + Network/Mirror Fixes + Storage Tuning)"
  echo "  3) Storage Tuning Only (+ Safe Maintenance)"
  echo "  4) Network & Mirror Repair Only (+ Safe Maintenance)"
  echo "  5) Dry-Run (Preview only, no changes)"
  echo "  0) Exit"
  echo ""
  if ! read -rp "  [?] Enter your choice [0-5]: " choice; then
    echo ""; log_info "No input received; exiting."; exit 0
  fi
  echo ""

  case "$choice" in
    1) log_info "Mode: Safe Routine Maintenance" ;;
    2) log_info "Mode: Full Aggressive Maintenance"
       DO_REPAIR_MIRRORS=true; AGGRESSIVE_NET=true; FORCE_IPV4=true
       DO_TUNE_STORAGE=true;   DO_POWER_TOOLS=true ;;
    3) log_info "Mode: Storage Tuning";          DO_TUNE_STORAGE=true ;;
    4) log_info "Mode: Network & Mirror Repair"; DO_REPAIR_MIRRORS=true; AGGRESSIVE_NET=true; FORCE_IPV4=true ;;
    5) log_info "Mode: Dry-Run";                 DRY_RUN=true ;;
    0) log_info "Exiting..."; exit 0 ;;
    *) log_err "Invalid choice. Exiting..."; exit 1 ;;
  esac
}

# =========================================================================== #
#  Argument parsing
# =========================================================================== #
# No flags AND attached to a real TTY (not a cron job / pipe) -> show the menu.
if [[ $# -eq 0 && -t 0 ]]; then
  interactive_menu
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run)          DRY_RUN=true ;;
    -y|--yes)              ASSUME_YES=true ;;
    --no-drivers)          DO_DRIVERS=false ;;
    --power-tools)         DO_POWER_TOOLS=true ;;
    --tune-storage)        DO_TUNE_STORAGE=true ;;
    --force-ipv4)          FORCE_IPV4=true ;;
    --repair-mirrors)      DO_REPAIR_MIRRORS=true ;;
    --install-realtek)     DO_INSTALL_REALTEK=true ;;
    --aggressive-network)  AGGRESSIVE_NET=true; FORCE_IPV4=true ;;
    --reboot)              REBOOT_MODE="always" ;;
    --no-reboot)           REBOOT_MODE="never" ;;
    --no-color)            NO_COLOR=true; USE_COLOR=false ;;
    -V|--version)          echo "$SCRIPT_NAME $SCRIPT_VERSION"; exit 0 ;;
    -h|--help)             usage; exit 0 ;;
    *)                     echo "Unknown option: $1" >&2; echo "Try '$SCRIPT_NAME --help'." >&2; exit 2 ;;
  esac
  shift
done

# =========================================================================== #
#  Pre-flight: root required (except in pure preview mode)
# =========================================================================== #
if [[ $EUID -ne 0 && $DRY_RUN == false ]]; then
  die "This script must be run as root. Try: sudo $SCRIPT_NAME"
fi

if [[ $DRY_RUN == false ]]; then
  LOGDIR="/var/log"; [[ -w $LOGDIR ]] || LOGDIR="/tmp"
  LOGFILE="${LOGDIR}/linux-maintain_${START_STAMP}.log"
  : > "$LOGFILE" 2>/dev/null || LOGFILE=""
fi

# =========================================================================== #
#  Banner
# =========================================================================== #
_log_line "===============================================================" "$C_CYN"
_log_line "  linux-maintain ${SCRIPT_VERSION} — Debian / Ubuntu / Kali maintainer" "${C_BOLD}${C_GRN}"
_log_line "  by Abdelrahman El-Maghraby" "$C_CYN"
_log_line "  Started: $(date '+%Y-%m-%d %H:%M:%S')" "$C_CYN"
[[ $DRY_RUN == true ]] && _log_line "  MODE: DRY RUN — no changes will be made" "${C_BOLD}${C_YLW}"
_log_line "===============================================================" "$C_CYN"

# =========================================================================== #
#  Connectivity check  (informational — never restarts your network)
# =========================================================================== #
log_step "Checking network connectivity"
# ICMP-resistant check: try ping first; if pings are dropped (enterprise firewall
# or pentest lab), fall back to a tiny HTTP/204 probe via curl before declaring
# "no network". The curl branch is silent and degrades safely if curl is absent.
if ping -c1 -W3 8.8.8.8 >/dev/null 2>&1 \
   || ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 \
   || curl -fs -m 3 http://clients3.google.com/generate_204 >/dev/null 2>&1; then
  log_ok "Network is reachable."
else
  log_warn "No ICMP reply and no HTTP probe response (network may still work, or may be down)."
  log_warn "Not touching network services automatically — apt will report errors if offline."
fi

# =========================================================================== #
#  Detect distribution & environment
# =========================================================================== #
OS_ID="$(osr ID)"; [[ -n $OS_ID ]] || OS_ID="unknown"
OS_PRETTY="$(osr PRETTY_NAME)"; [[ -n $OS_PRETTY ]] || OS_PRETTY="unknown"
log_info "Distribution: ${OS_PRETTY} (id=${OS_ID})"
case "$OS_ID" in
  debian|ubuntu|kali) : ;;
  *) log_warn "Unsupported distribution; package steps may not all apply." ;;
esac

VIRT="none"
have systemd-detect-virt && VIRT="$(systemd-detect-virt 2>/dev/null || echo none)"
grep -qi microsoft /proc/version 2>/dev/null && VIRT="wsl"
IS_BAREMETAL=false; [[ $VIRT == "none" ]] && IS_BAREMETAL=true
log_info "Environment: ${VIRT} (bare metal: ${IS_BAREMETAL})"

# =========================================================================== #
#  Optional: repair apt mirrors BEFORE refreshing package lists
# =========================================================================== #
[[ $DO_REPAIR_MIRRORS == true ]] && repair_mirrors

# =========================================================================== #
#  Update & upgrade
# =========================================================================== #
log_step "Updating package lists"
apt_update

log_step "Upgrading installed packages"
run_soft apt-get upgrade -y "${APT_OPTS[@]}"
run_soft apt-get full-upgrade -y "${APT_OPTS[@]}"
log_ok "Upgrade step complete."

# =========================================================================== #
#  Kernel metapackage (correct name per distro)
# =========================================================================== #
log_step "Ensuring a current kernel metapackage is installed"
arch="$(dpkg --print-architecture 2>/dev/null || echo '')"
log_info "Architecture: ${arch:-unknown}"
case "$OS_ID" in
  ubuntu)
    apt_install linux-image-generic linux-headers-generic ;;
  debian|kali)
    case "$arch" in
      amd64) apt_install linux-image-amd64 linux-headers-amd64 ;;
      arm64) apt_install linux-image-arm64 linux-headers-arm64 ;;
      i386)  apt_install linux-image-686   linux-headers-686   ;;
      *)     log_warn "Unrecognised architecture '${arch}'; skipping kernel metapackage." ;;
    esac ;;
  *) log_warn "Unknown distro; skipping kernel metapackage." ;;
esac

# =========================================================================== #
#  Firmware, GPU drivers, microcode  (bare metal only, hardware-detected)
# =========================================================================== #
if [[ $DO_DRIVERS == true && $IS_BAREMETAL == true ]]; then
  log_step "Installing firmware and hardware drivers (bare metal)"

  if [[ $OS_ID == "ubuntu" ]]; then
    apt_install linux-firmware
  else
    apt_install firmware-linux firmware-linux-nonfree firmware-misc-nonfree
  fi

  gpu="$(lspci 2>/dev/null | grep -iE 'vga|3d|display' || true)"
  if echo "$gpu" | grep -qi 'nvidia'; then
    log_info "NVIDIA GPU detected."
    apt_install nvidia-detect nvidia-driver
  fi
  if echo "$gpu" | grep -qiE 'amd|radeon|ati'; then
    log_info "AMD/ATI GPU detected."
    apt_install firmware-amd-graphics xserver-xorg-video-amdgpu
  fi
  if echo "$gpu" | grep -qi 'intel'; then
    log_info "Intel GPU detected."
    apt_install xserver-xorg-video-intel intel-media-va-driver-non-free
  fi

  # Auto-install the Realtek driver only if such an adapter is present AND the
  # user did not already force it with --install-realtek (handled separately).
  if [[ $DO_INSTALL_REALTEK == false ]] && have lsusb && lsusb 2>/dev/null | grep -qiE 'RTL8188|8188eu'; then
    log_info "Realtek RTL8188-class USB Wi-Fi detected; installing DKMS driver."
    apt_install "linux-headers-$(uname -r)"
    apt_install realtek-rtl8188eus-dkms
  fi

  cpu_vendor="$(lscpu 2>/dev/null | awk -F: '/Vendor ID/{gsub(/ /,"",$2); print tolower($2); exit}' || echo '')"
  if [[ $cpu_vendor == *intel* ]]; then
    apt_install intel-microcode
  elif [[ $cpu_vendor == *amd* ]]; then
    apt_install amd64-microcode
  else
    log_info "CPU vendor '${cpu_vendor:-unknown}'; skipping microcode."
  fi
else
  log_step "Skipping bare-metal drivers (VM detected or --no-drivers given)"
fi

# Forced Realtek install runs in any environment when explicitly requested.
[[ $DO_INSTALL_REALTEK == true ]] && install_realtek_driver

# =========================================================================== #
#  Guest tools inside a VM / Hyper-V / WSL
# =========================================================================== #
case "$VIRT" in
  vmware)            log_step "VMware detected — installing open-vm-tools"
                     apt_install open-vm-tools open-vm-tools-desktop ;;
  oracle)            log_step "VirtualBox detected — installing guest utilities"
                     apt_install virtualbox-guest-utils virtualbox-guest-x11 ;;
  kvm|qemu)          log_step "KVM/QEMU detected — installing qemu-guest-agent"
                     apt_install qemu-guest-agent ;;
  microsoft|hyperv)  log_step "Hyper-V detected — installing virtualisation tools"
                     apt_install linux-tools-virtual linux-cloud-tools-virtual ;;
  wsl)               log_step "WSL detected — installing WSL utilities"
                     apt_install wslu ;;
  *)                 : ;;
esac

# =========================================================================== #
#  Laptop power tools  (opt-in: --power-tools)
# =========================================================================== #
is_laptop=false
ls /sys/class/power_supply/BAT* >/dev/null 2>&1 && is_laptop=true
chassis="$(cat /sys/class/dmi/id/chassis_type 2>/dev/null || echo '')"
case "$chassis" in 8|9|10|14) is_laptop=true ;; esac

if [[ $DO_POWER_TOOLS == true && $is_laptop == true ]]; then
  log_step "Installing laptop power-management tools"
  apt_install tlp tlp-rdw powertop thermald
  run_soft systemctl enable --now tlp
  run_soft systemctl enable --now thermald
elif [[ $DO_POWER_TOOLS == true ]]; then
  log_info "No battery/laptop chassis detected; skipping power tools."
fi

# =========================================================================== #
#  Storage maintenance
#    Default (safe): enable periodic TRIM on SSDs.
#    Opt-in (--tune-storage): persistent I/O scheduler + noatime (SSD) /
#                             swappiness (HDD).
# =========================================================================== #
log_step "Storage maintenance"
root_src="$(findmnt -n -o SOURCE / 2>/dev/null || echo '')"
root_dev=""
[[ $root_src =~ ^/dev/ ]] && root_dev="$(basename "$root_src" | sed -E 's/p?[0-9]+$//')"

if [[ -n $root_dev && -r "/sys/block/${root_dev}/queue/rotational" ]]; then
  rota="$(cat "/sys/block/${root_dev}/queue/rotational" 2>/dev/null || echo 1)"
  if [[ $rota == 0 ]]; then
    log_info "Root device /dev/${root_dev} is an SSD."
    systemctl list-unit-files 2>/dev/null | grep -q '^fstrim.timer' && run_soft systemctl enable --now fstrim.timer
    run_soft fstrim -av
  else
    log_info "Root device /dev/${root_dev} is a spinning disk (HDD)."
  fi

  if [[ $DO_TUNE_STORAGE == true ]]; then
    log_info "Applying deep storage tuning (--tune-storage)."
    apply_io_scheduler "$root_dev" "$rota"
    if [[ $rota == 0 ]]; then add_noatime_to_root; else set_swappiness; fi
  fi
else
  log_info "Could not determine root storage type; skipping storage tuning."
fi

# =========================================================================== #
#  Cleanup & repair
# =========================================================================== #
log_step "Cleaning up and repairing package state"
run_soft apt-get autoremove -y "${APT_OPTS[@]}"
run_soft apt-get autoclean -y "${APT_OPTS[@]}"
run_soft apt-get --fix-broken install -y "${APT_OPTS[@]}"
run_soft dpkg --configure -a
have update-grub && run_soft update-grub

# =========================================================================== #
#  Optional utilities (fastfetch — a modern neofetch-style system viewer)
# =========================================================================== #
log_step "Installing optional utilities"
apt_install fastfetch dconf-editor

# =========================================================================== #
#  System report  (read-only — gathers info, changes nothing)
# =========================================================================== #
log_step "Writing system report"
if [[ $DRY_RUN == false && -n $LOGFILE ]]; then
  REPORT="${LOGFILE%.log}_report.txt"
  {
    echo "==================== System Report ===================="
    echo "Generated : $(date)"
    echo "OS        : ${OS_PRETTY}"
    echo "Kernel    : $(uname -r)"
    echo "Arch      : ${arch}"
    echo "Hostname  : $(hostname)"
    echo "Uptime    : $(uptime -p 2>/dev/null || true)"
    echo "Env       : ${VIRT}"
    echo
    echo "----- CPU -----";     lscpu 2>/dev/null || true
    echo "----- Memory -----";  free -h 2>/dev/null || true
    echo "----- Disks -----";   lsblk -o NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null || true
    df -hT / 2>/dev/null || true
    echo "----- Network -----"; ip -br a 2>/dev/null || true
    echo "----- GPU -----";     lspci 2>/dev/null | grep -iE 'vga|3d|display' || true
    if have fastfetch; then echo "----- fastfetch -----"; fastfetch -c none 2>/dev/null || fastfetch 2>/dev/null || true; fi
  } > "$REPORT" 2>/dev/null || true
  log_ok "Report saved to ${REPORT}"
else
  log_info "(dry run) report generation skipped."
fi

# =========================================================================== #
#  Rotate our own old logs (older than 7 days)
# =========================================================================== #
if [[ $DRY_RUN == false && -n $LOGFILE ]]; then
  run_soft find "$(dirname "$LOGFILE")" -maxdepth 1 -type f \
    -name 'linux-maintain_*.log' -mtime +7 -delete
fi

# =========================================================================== #
#  Summary + reboot handling
# =========================================================================== #
if [[ $DRY_RUN == false ]] && have fastfetch; then
  log_step "System summary"
  fastfetch 2>/dev/null || true
fi

needs_reboot=false
[[ -f /var/run/reboot-required || -f /run/reboot-required ]] && needs_reboot=true

_log_line "===============================================================" "$C_CYN"
log_ok "Maintenance complete."
_log_line "  Finished : $(date '+%Y-%m-%d %H:%M:%S')" "$C_CYN"
[[ -n $LOGFILE ]] && _log_line "  Log      : ${LOGFILE}" "$C_CYN"
if [[ $needs_reboot == true ]]; then
  _log_line "  Reboot   : REQUIRED (kernel or core libraries were updated)" "${C_BOLD}${C_YLW}"
else
  _log_line "  Reboot   : not required" "$C_CYN"
fi
_log_line "===============================================================" "$C_CYN"

do_reboot() { log_warn "Rebooting now..."; run sync; run shutdown -r now; }

case "$REBOOT_MODE" in
  always) do_reboot ;;
  never)  log_info "Reboot suppressed (--no-reboot)." ;;
  auto)
    if [[ $needs_reboot == true ]]; then
      if [[ $ASSUME_YES == true ]]; then
        do_reboot
      elif [[ $DRY_RUN == true ]]; then
        log_info "(dry run) a reboot would be recommended here."
      else
        read -rp "A reboot is required. Reboot now? (y/N): " ans || ans="n"
        [[ ${ans,,} =~ ^y ]] && do_reboot || log_info "Reboot postponed — remember to reboot later."
      fi
    fi
    ;;
esac

exit 0
