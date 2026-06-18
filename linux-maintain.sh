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
readonly SCRIPT_VERSION="3.2.0"
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

# --- Opt-in maintenance / security features (new in 3.2.0) ----------------- #
DO_SNAPSHOT=false             # --snapshot               : Timeshift/BTRFS snapshot before upgrade
DO_CLEAN_DOCKER=false         # --clean-docker           : docker system prune (safe set)
DO_CLEAN_DOCKER_VOLUMES=false # --clean-docker-volumes   : also prune unused volumes (DESTRUCTIVE)
DO_BACKUP_ETC=false           # --backup-etc             : compressed /etc archive
JOURNAL_VACUUM=false          # --vacuum-journal[=SPEC]  : vacuum the systemd journal
JOURNAL_VACUUM_SPEC="14d"     #                            default age; SPEC like 30d or 500M
DO_AUDIT_PERMS=false          # --audit-perms            : SUID/SGID + world-writable scan
WANTS_AGGRESSIVE=false        # set true if any aggressive flag is active (gates the /etc archive)

# --- Failure notifications (configured via ENVIRONMENT, never via CLI) ------ #
#   Secrets on the command line are visible in `ps`; we read them from the
#   environment instead (use a systemd EnvironmentFile= for unattended timers).
#     MAINTAIN_DISCORD_WEBHOOK   full Discord webhook URL
#     MAINTAIN_TELEGRAM_TOKEN    Telegram bot token
#     MAINTAIN_TELEGRAM_CHAT     Telegram chat id
DISCORD_WEBHOOK="${MAINTAIN_DISCORD_WEBHOOK:-}"
TELEGRAM_TOKEN="${MAINTAIN_TELEGRAM_TOKEN:-}"
TELEGRAM_CHAT="${MAINTAIN_TELEGRAM_CHAT:-}"
NOTIFY_ARMED=false            # true once we are past pre-flight (real maintenance)
NOTIFY_DONE=false             # ensures a single failure alert
FAILURE_CONTEXT=""            # populated by die()/ERR for the alert body

readonly APT_RETRIES_DEFAULT=3
readonly APT_RETRIES_AGGRESSIVE=8

# Abort threshold for free space on / before package operations (MB).
readonly MIN_FREE_MB=1024

# Known-dead / hijacked mirror hosts to replace when --repair-mirrors is used.
# These are examples — edit the list to match mirrors that have failed for you.
BAD_MIRROR_HOSTS=(
  "mirror.sox.rs"
  "mirror1.sox.rs"
)

LOGFILE=""                  # set after we confirm we are root
LOGDIR=""                   # log/report/backup destination (resolved at runtime)
REPORT=""                   # system-report path (set when logging is active)
EXEC_LOG_ACTIVE=false       # true once exec>tee captures all output (full logging)
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a   # auto-restart services; never block on needrestart prompts

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
  # When exec>tee full logging is active, stdout already lands in the log file;
  # the explicit append below would duplicate every line, so it is skipped.
  [[ $EXEC_LOG_ACTIVE == true ]] && return 0
  [[ -n $LOGFILE ]] && printf '%s\n' "$raw" >> "$LOGFILE" 2>/dev/null || true
}
log_info() { _log_line "[*]  $*" "$C_BLU"; }
log_ok()   { _log_line "[OK] $*" "$C_GRN"; }
log_warn() { _log_line "[!]  $*" "$C_YLW"; }
log_err()  { _log_line "[x]  $*" "$C_RED"; }
log_cmd()  { _log_line "       \$ $*" "$C_DIM"; }
log_step() { _log_line ""; _log_line "==> $*" "${C_BOLD}${C_CYN}"; }

# =========================================================================== #
#  Failure-notification helpers
#    Alerts are OFF unless a webhook/token is present in the environment.
#    notify_failure() is safe to call from traps: it never throws, honours
#    --dry-run, and no-ops when nothing is configured.
# =========================================================================== #
# JSON string escaper. Escapes the JSON-significant characters and strips
# control characters (except TAB/CR/LF, which become \t \r \n) so hand-built
# payloads stay valid even when the reason or log tail contains quotes,
# backslashes, ANSI escapes, or newlines. Valid UTF-8 (e.g. the em-dash in our
# own messages) is preserved.
_json_escape() {
  local s="${1:-}"
  s="$(printf '%s' "$s" | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' 2>/dev/null || true)"
  s="${s//\\/\\\\}"     # backslash (must be first)
  s="${s//\"/\\\"}"     # double quote
  s="${s//$'\r'/\\r}"   # CR  -> \r
  s="${s//$'\n'/\\n}"   # LF  -> \n
  s="${s//$'\t'/\\t}"   # TAB -> \t
  printf '%s' "$s"
}

# Build a Discord rich-embed payload: a red embed with structured fields
# (Hostname, Exit Code, Version, Trigger/Reason, Timestamp, and a log tail).
# Every interpolated value is JSON-escaped; color 15548997 == #ED4245 (red).
_discord_embed_payload() {  # $1=host $2=rc $3=reason $4=iso8601 $5=fenced-log
  printf '{"username":"linux-maintain","embeds":[{"title":"🚨 Maintenance Run Failed","description":"An unattended **linux-maintain** run exited abnormally and needs attention.","color":15548997,"fields":[{"name":"Hostname","value":"%s","inline":true},{"name":"Exit Code","value":"%s","inline":true},{"name":"Version","value":"%s","inline":true},{"name":"Trigger / Reason","value":"%s","inline":false},{"name":"Timestamp (UTC)","value":"%s","inline":false},{"name":"Log (tail)","value":"%s","inline":false}],"footer":{"text":"linux-maintain v%s • automated maintenance"},"timestamp":"%s"}]}' \
    "$(_json_escape "$1")" \
    "$(_json_escape "$2")" \
    "$(_json_escape "$SCRIPT_VERSION")" \
    "$(_json_escape "$3")" \
    "$(_json_escape "$4")" \
    "$(_json_escape "$5")" \
    "$(_json_escape "$SCRIPT_VERSION")" \
    "$(_json_escape "$4")"
}

notify_failure() {
  local rc="${1:-?}" ctx="${2:-unknown}"
  if [[ -z $DISCORD_WEBHOOK && ( -z $TELEGRAM_TOKEN || -z $TELEGRAM_CHAT ) ]]; then
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    log_warn "Failure notification is configured but curl is missing; cannot send alert."
    return 0
  fi

  local host iso when
  host="$(hostname 2>/dev/null || echo unknown)"
  iso="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)"; [[ -n $iso ]] || iso="1970-01-01T00:00:00Z"
  when="$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "$iso")"
  ctx="${ctx:0:1000}"   # field values cap at 1024 chars; keep headroom

  # Plain-text body (used by Telegram and the dry-run preview).
  local msg
  msg="[FAILED] linux-maintain ${SCRIPT_VERSION} on ${host}
Time   : ${when}
Reason : ${ctx}
Log    : ${LOGFILE:-<none>}"

  if [[ $DRY_RUN == true ]]; then
    log_info "(dry run) would send a failure notification (Discord: rich embed; Telegram: text):"
    printf '%s\n' "$msg" | sed 's/^/         | /'
    return 0
  fi

  # ---- Discord: professional rich embed (red, structured fields) --------- #
  if [[ -n $DISCORD_WEBHOOK ]]; then
    local snip fenced payload
    snip=""
    if [[ -n ${LOGFILE:-} && -r ${LOGFILE:-/nonexistent} ]]; then
      # last lines, ANSI stripped, forced to printable ASCII (keeps JSON valid
      # regardless of locale / multibyte boundaries), then byte-capped.
      snip="$(tail -n 12 "$LOGFILE" 2>/dev/null \
                | sed -E 's/\x1b\[[0-9;]*m//g' \
                | LC_ALL=C tr -cd '\11\12\15\40-\176' \
                | tail -c 900 || true)"
    fi
    [[ -n ${snip//[$'\n\t ']/} ]] || snip="(no log output captured)"
    fenced="$(printf '```\n%s\n```' "$snip")"
    payload="$(_discord_embed_payload "$host" "$rc" "$ctx" "$iso" "$fenced")"
    if curl -fsS -m 10 -H 'Content-Type: application/json' -d "$payload" "$DISCORD_WEBHOOK" >/dev/null 2>&1; then
      log_ok "Failure alert sent to Discord (rich embed)."
    else
      log_warn "Could not send Discord failure alert."
    fi
  fi

  # ---- Telegram: simple text (its formatting is intentionally minimal) --- #
  if [[ -n $TELEGRAM_TOKEN && -n $TELEGRAM_CHAT ]]; then
    if curl -fsS -m 10 \
         --data-urlencode "chat_id=${TELEGRAM_CHAT}" \
         --data-urlencode "text=${msg}" \
         "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" >/dev/null 2>&1; then
      log_ok "Failure alert sent to Telegram."
    else
      log_warn "Could not send Telegram failure alert."
    fi
  fi
}

# die() records context first so the EXIT-trap alert can include the reason.
die() { FAILURE_CONTEXT="$*"; log_err "$*"; exit 1; }

# Report exactly where an *unexpected* failure happened. Expected, non-fatal
# failures go through run_soft and never reach this trap.
_on_err() {
  local rc=$?
  FAILURE_CONTEXT="exit ${rc} at line ${BASH_LINENO[0]:-?}: ${BASH_COMMAND}"
  log_err "Unexpected error (exit ${rc}) at line ${BASH_LINENO[0]:-?}: ${BASH_COMMAND}"
  exit "$rc"
}
trap _on_err ERR

# On any non-zero exit AFTER pre-flight, fire a single failure notification.
_on_exit() {
  local rc=$?
  if [[ $NOTIFY_DONE == false && $NOTIFY_ARMED == true ]] && (( rc != 0 )); then
    NOTIFY_DONE=true
    notify_failure "$rc" "${FAILURE_CONTEXT:-aborted (exit ${rc})}" || true
  fi
  return 0
}
trap _on_exit EXIT

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
#  3.2.0 features: pre-upgrade snapshots, /etc archive, container cleanup,
#  journal vacuum, and read-only security checks (privesc audit, attack
#  surface, SSH posture). All honour --dry-run and the safe-by-default model.
# =========================================================================== #

# Append a line to the system report when one exists (no-op in --dry-run).
sec_append() {
  [[ $DRY_RUN == false && -n ${REPORT:-} && -e ${REPORT:-/nonexistent} ]] \
    && printf '%s\n' "$*" >> "$REPORT" 2>/dev/null || true
}

# --- Pre-upgrade snapshot (Timeshift, or BTRFS via Snapper) ----------------- #
# Opt-in (--snapshot). Because the point is a GUARANTEED rollback path, if a
# snapshot is requested but cannot be produced we abort BEFORE any package
# change (nothing has been modified yet) rather than upgrade unprotected.
create_pre_upgrade_snapshot() {
  log_step "Creating pre-upgrade system snapshot (--snapshot)"
  local tag="linux-maintain ${SCRIPT_VERSION} pre-upgrade ${START_STAMP}"
  local rootfs; rootfs="$(findmnt -n -o FSTYPE / 2>/dev/null || echo '')"

  if [[ $DRY_RUN == true ]]; then
    if command -v timeshift >/dev/null 2>&1; then
      log_cmd "would run: timeshift --create --comments '${tag}' --scripted"
    elif [[ $rootfs == btrfs ]] && command -v snapper >/dev/null 2>&1; then
      log_cmd "would run: snapper -c root create --description '${tag}'"
    else
      log_warn "(dry run) no snapshot tool found; a real --snapshot run would ABORT here."
    fi
    return 0
  fi

  if command -v timeshift >/dev/null 2>&1; then
    log_info "Timeshift detected; creating a tagged snapshot (this can take a while)."
    if timeshift --create --comments "$tag" --scripted; then
      log_ok "Timeshift snapshot created."
      return 0
    fi
    log_warn "Timeshift snapshot command failed; trying BTRFS/Snapper if available."
  fi

  if [[ $rootfs == btrfs ]] && command -v snapper >/dev/null 2>&1; then
    if snapper -c root list >/dev/null 2>&1; then
      if snapper -c root create --description "$tag" --cleanup-algorithm number; then
        log_ok "Snapper (BTRFS) snapshot created on config 'root'."
        return 0
      fi
      log_warn "snapper create failed."
    else
      log_warn "snapper has no 'root' config (run: snapper -c root create-config /)."
    fi
  fi

  die "Could not create a pre-upgrade snapshot (no working Timeshift or BTRFS/Snapper). Aborting before any package change because --snapshot guarantees a rollback path. Install/configure Timeshift (any filesystem) or Snapper (BTRFS), or re-run without --snapshot."
}

# --- Compressed /etc archive before aggressive repairs ---------------------- #
backup_etc_archive() {
  log_step "Archiving /etc before aggressive repairs"
  local dest="${LOGDIR:-/var/log}"; [[ -w $dest ]] || dest="/tmp"
  local archive="${dest}/etc-backup_${START_STAMP}.tar.gz"
  if [[ $DRY_RUN == true ]]; then
    log_cmd "would archive /etc -> ${archive} (tar czf, then chmod 600)"
    return 0
  fi
  local rc=0
  log_cmd "tar czf ${archive} -C / etc"
  tar czf "$archive" --warning=no-file-changed -C / etc 2>/dev/null || rc=$?
  if (( rc <= 1 )) && [[ -s $archive ]]; then
    chmod 600 "$archive" 2>/dev/null || true   # /etc holds shadow & ssh keys -> root-only
    log_ok "Configuration archive: ${archive} ($(du -h "$archive" 2>/dev/null | awk '{print $1}'))"
  else
    log_warn "Could not create the /etc archive cleanly (tar rc=${rc}); continuing."
  fi
}

# --- Container cleanup (opt-in --clean-docker / --clean-docker-volumes) ------ #
clean_docker() {
  log_step "Pruning Docker resources (--clean-docker)"
  if ! command -v docker >/dev/null 2>&1; then
    log_info "docker not installed; skipping container cleanup."
    return 0
  fi
  if [[ $DRY_RUN == false ]] && ! docker info >/dev/null 2>&1; then
    log_warn "docker is installed but the daemon is not responding; skipping prune."
    return 0
  fi
  # Safe set: dangling images, stopped containers, unused networks, build cache.
  run_soft docker system prune -f
  if [[ $DO_CLEAN_DOCKER_VOLUMES == true ]]; then
    log_warn "Also pruning UNUSED VOLUMES (--clean-docker-volumes): this destroys data in any volume not attached to a running container."
    run_soft docker system prune -f --volumes
  else
    log_info "Unused volumes were NOT touched (add --clean-docker-volumes to include them; destructive)."
  fi
  log_ok "Docker prune complete."
}

# --- systemd journal vacuum (opt-in --vacuum-journal[=SPEC]) ---------------- #
vacuum_journal() {
  log_step "Vacuuming the systemd journal (--vacuum-journal)"
  if ! command -v journalctl >/dev/null 2>&1; then
    log_info "journalctl not available; skipping journal vacuum."
    return 0
  fi
  local spec="$JOURNAL_VACUUM_SPEC"
  if [[ $spec =~ ^[0-9]+[KMG]$ ]]; then
    log_info "Vacuuming journal down to at most ${spec}."
    run_soft journalctl --vacuum-size="${spec}"
  else
    log_info "Vacuuming journal entries older than ${spec}."
    run_soft journalctl --vacuum-time="${spec}"
  fi
  log_ok "Journal vacuum complete."
}

# --- Privilege-escalation audit (opt-in --audit-perms; read-only) ----------- #
audit_permissions() {
  log_step "Privilege-escalation audit (--audit-perms)"
  local candidates p existing=()
  if [[ -n ${AUDIT_PATHS:-} ]]; then
    read -ra candidates <<< "$AUDIT_PATHS"
  else
    candidates=(/bin /sbin /usr /lib /lib64 /opt /etc /root /boot /var)
  fi
  for p in "${candidates[@]}"; do [[ -e $p ]] && existing+=("$p"); done
  [[ ${#existing[@]} -gt 0 ]] || { log_warn "No standard paths to scan; skipping."; return 0; }

  sec_append ""
  sec_append "==================== Privilege-Escalation Audit ===================="
  sec_append "Scanned (one filesystem each, -xdev): ${existing[*]}"

  # SUID/SGID binaries.
  local suid; suid="$(find "${existing[@]}" -xdev -type f -perm /6000 2>/dev/null | sort || true)"
  local nsuid; nsuid="$(printf '%s' "$suid" | grep -c . || true)"
  sec_append ""
  sec_append "----- SUID/SGID binaries (${nsuid}) -----"
  if [[ -n $suid ]]; then
    while IFS= read -r f; do
      [[ -n $f ]] && sec_append "  $(ls -ld "$f" 2>/dev/null || printf '%s' "$f")"
    done <<< "$suid"
  else
    sec_append "  (none found)"
  fi
  local rogue; rogue="$(printf '%s\n' "$suid" | grep -E '^/(tmp|var/tmp|dev/shm|home|root|srv|mnt|media)/' || true)"
  if [[ -n ${rogue//[$'\n']/} ]]; then
    log_warn "SUID/SGID binaries in unusual writable locations (REVIEW — possible privesc):"
    sec_append ""
    sec_append "  [!] SUID/SGID in unusual locations:"
    while IFS= read -r f; do
      [[ -n $f ]] && { log_warn "      $f"; sec_append "      $f"; }
    done <<< "$rogue"
  else
    log_ok "No SUID/SGID binaries in unusual writable locations."
  fi

  # World-writable files and (non-sticky) directories.
  local wf wd
  wf="$(find "${existing[@]}" -xdev -type f -perm -0002 2>/dev/null | sort || true)"
  wd="$(find "${existing[@]}" -xdev -type d -perm -0002 ! -perm -1000 2>/dev/null | sort || true)"
  local nwf nwd
  nwf="$(printf '%s' "$wf" | grep -c . || true)"
  nwd="$(printf '%s' "$wd" | grep -c . || true)"
  sec_append ""
  sec_append "----- World-writable files (${nwf}) -----"
  if [[ -n $wf ]]; then
    while IFS= read -r f; do [[ -n $f ]] && sec_append "  $f"; done <<< "$wf"
  else
    sec_append "  (none found)"
  fi
  sec_append ""
  sec_append "----- World-writable dirs without sticky bit (${nwd}) -----"
  if [[ -n $wd ]]; then
    while IFS= read -r f; do [[ -n $f ]] && sec_append "  $f"; done <<< "$wd"
  else
    sec_append "  (none found)"
  fi
  if (( nwf > 0 || nwd > 0 )); then
    log_warn "Found ${nwf} world-writable file(s) and ${nwd} world-writable dir(s) without sticky bit (details in the report)."
  else
    log_ok "No world-writable files or non-sticky world-writable dirs in scanned paths."
  fi
  log_ok "Privilege-escalation audit complete."
}

# --- Attack-surface summary (read-only; always appended to the report) ------ #
attack_surface_summary() {
  log_step "Attack-surface summary (listening ports & failed services)"
  sec_append ""
  sec_append "==================== Attack Surface ===================="
  sec_append ""
  sec_append "----- Listening sockets (ss -tulpn) -----"
  if command -v ss >/dev/null 2>&1; then
    local out; out="$(ss -tulpn 2>/dev/null || true)"
    sec_append "${out:-  (no output)}"
    local n; n="$(printf '%s\n' "$out" | grep -c -i listen || true)"
    log_info "Listening sockets: ${n}."
  elif command -v netstat >/dev/null 2>&1; then
    local out; out="$(netstat -tulpn 2>/dev/null || true)"
    sec_append "${out:-  (no output)}"
  else
    sec_append "  (neither ss nor netstat is available)"
    log_info "Neither ss nor netstat installed; skipping port list."
  fi
  sec_append ""
  sec_append "----- Failed systemd units (systemctl --failed) -----"
  if command -v systemctl >/dev/null 2>&1; then
    local fout; fout="$(systemctl --failed --no-legend --plain 2>/dev/null || true)"
    if [[ -n ${fout//[$'\n\t ']/} ]]; then
      sec_append "$fout"
      local nf; nf="$(printf '%s\n' "$fout" | grep -c . || true)"
      log_warn "${nf} failed systemd unit(s) detected (details in the report)."
    else
      sec_append "  (no failed units)"
      log_ok "No failed systemd units."
    fi
  else
    sec_append "  (systemctl not available)"
  fi
}

# --- SSH posture (read-only, passive audit of sshd_config) ------------------ #
ssh_posture_check() {
  log_step "SSH security posture (passive audit of sshd_config)"
  local cfg="${SSHD_CONFIG:-/etc/ssh/sshd_config}"
  sec_append ""
  sec_append "==================== SSH Security Posture ===================="
  if [[ ! -r $cfg ]]; then
    sec_append "  ${cfg} not present or not readable; skipping."
    log_info "${cfg} not present/readable; skipping SSH posture check."
    return 0
  fi
  _ssh_eff() {  # last uncommented value of a directive (case-insensitive)
    grep -iE "^[[:space:]]*$1[[:space:]]+" "$cfg" 2>/dev/null | tail -n1 | awk '{print $2}' || true
  }
  local proot ppass pempty px11
  proot="$(_ssh_eff PermitRootLogin)";   ppass="$(_ssh_eff PasswordAuthentication)"
  pempty="$(_ssh_eff PermitEmptyPasswords)"; px11="$(_ssh_eff X11Forwarding)"
  sec_append "  PermitRootLogin        : ${proot:-(unset; default prohibit-password)}"
  sec_append "  PasswordAuthentication : ${ppass:-(unset; default yes)}"
  sec_append "  PermitEmptyPasswords   : ${pempty:-(unset; default no)}"
  sec_append "  X11Forwarding          : ${px11:-(unset; default no)}"
  sec_append ""
  local findings=0
  if [[ ${proot,,} == yes ]]; then
    log_warn "SSH: PermitRootLogin yes — direct root login over SSH is enabled."
    sec_append "  [!] PermitRootLogin yes — consider 'prohibit-password' or 'no'."
    findings=$((findings+1))
  fi
  if [[ ${pempty,,} == yes ]]; then
    log_warn "SSH: PermitEmptyPasswords yes — accounts with empty passwords can log in."
    sec_append "  [!] PermitEmptyPasswords yes — set to 'no'."
    findings=$((findings+1))
  fi
  if [[ ${ppass,,} == yes ]]; then
    log_warn "SSH: PasswordAuthentication yes — key-only auth resists brute force better."
    sec_append "  [i] PasswordAuthentication yes — consider key-only ('no')."
    findings=$((findings+1))
  fi
  if (( findings == 0 )); then
    log_ok "SSH posture: no high-risk directives flagged."
    sec_append "  No high-risk directives flagged."
  fi
  sec_append "  (Passive audit only — ${cfg} was not modified.)"
}

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

OPTIONAL MAINTENANCE & SECURITY (opt-in; safe-by-default is preserved):
      --snapshot           Create a Timeshift/BTRFS (Snapper) snapshot BEFORE the
                           upgrade; aborts the run if no snapshot tool works
      --backup-etc         Write a compressed, root-only /etc archive (implied
                           automatically before any aggressive repair)
      --vacuum-journal[=N] Vacuum the systemd journal (default 14d; N may be a
                           time like 30d or a size like 500M)
      --clean-docker       'docker system prune -f' (dangling images, stopped
                           containers, unused networks, build cache)
      --clean-docker-volumes
                           Also prune UNUSED VOLUMES (implies --clean-docker;
                           DESTRUCTIVE — deletes data in detached volumes)
      --audit-perms        Scan for SUID/SGID binaries and world-writable paths
                           (read-only privilege-escalation audit)

  A listening-port + failed-service summary and a passive SSH-config posture
  check are ALWAYS appended to the system report (both read-only).

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
  sudo ./${SCRIPT_NAME} --snapshot --vacuum-journal=30d
  sudo ./${SCRIPT_NAME} --clean-docker --audit-perms

ENVIRONMENT (failure/abort alerts for unattended timer runs):
  MAINTAIN_DISCORD_WEBHOOK   Discord webhook URL to alert on failure/abort
  MAINTAIN_TELEGRAM_TOKEN    Telegram bot token   (with MAINTAIN_TELEGRAM_CHAT)
  MAINTAIN_TELEGRAM_CHAT     Telegram chat id
  Set these via the environment (e.g. a systemd EnvironmentFile=) — never on
  the command line, where 'ps' would expose them.
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
#  Disk space guard: abort before package operations if / is nearly full
#    A real run aborts below MIN_FREE_MB (default 1024 MB) to prevent a
#    half-finished upgrade from crashing the system. A --dry-run only warns,
#    so the preview always completes.
# =========================================================================== #
check_disk_space() {
  local avail_mb
  avail_mb="$(df -Pm / 2>/dev/null | awk 'NR==2 {print $4}')"
  if [[ -z $avail_mb || ! $avail_mb =~ ^[0-9]+$ ]]; then
    log_warn "Could not determine free space on /; continuing without the guard."
    return 0
  fi
  if (( avail_mb < MIN_FREE_MB )); then
    if [[ $DRY_RUN == true ]]; then
      log_warn "Free space on / is ${avail_mb} MB (< ${MIN_FREE_MB} MB) — a real run would ABORT here."
      return 0
    fi
    die "Free space on / is ${avail_mb} MB — below the ${MIN_FREE_MB} MB safety minimum. Free up space and retry. Aborting to prevent a broken upgrade."
  fi
  log_ok "Free space on /: ${avail_mb} MB (minimum required: ${MIN_FREE_MB} MB)."
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
  local choice=""

  # --- Preferred: whiptail TUI (used only when the tool is installed) -------- #
  if have whiptail; then
    # fd swap (3>&1 1>&2 2>&3) captures the selection; Cancel/Esc or any
    # whiptail failure leaves choice empty and we degrade to the classic menu.
    choice="$(whiptail --title "linux-maintain ${SCRIPT_VERSION}" \
      --menu "Choose maintenance type:" 20 78 7 \
        "1" "Safe Routine Maintenance (default)" \
        "2" "Full Aggressive Maintenance (network/mirror fixes + tuning)" \
        "3" "Storage Tuning Only (+ safe maintenance)" \
        "4" "Network & Mirror Repair Only (+ safe maintenance)" \
        "5" "Dry-Run (preview only, no changes)" \
        "6" "Security Audit (safe maintenance + perms/ports/SSH posture)" \
        "0" "Exit" \
      3>&1 1>&2 2>&3)" || choice=""
  fi

  # --- Fallback: classic text menu (no whiptail, or user cancelled) ---------- #
  if [[ -z $choice ]]; then
    _log_line "===============================================================" "$C_CYN"
    _log_line "  Interactive Mode: Choose Maintenance Type" "${C_BOLD}${C_YLW}"
    _log_line "===============================================================" "$C_CYN"
    echo "  1) Safe Routine Maintenance (Default - Updates, Cleanup, TRIM)"
    echo "  2) Full Aggressive Maintenance (Safe + Network/Mirror Fixes + Storage Tuning)"
    echo "  3) Storage Tuning Only (+ Safe Maintenance)"
    echo "  4) Network & Mirror Repair Only (+ Safe Maintenance)"
    echo "  5) Dry-Run (Preview only, no changes)"
    echo "  6) Security Audit (Safe Maintenance + SUID/world-writable + ports + SSH posture)"
    echo "  0) Exit"
    echo ""
    if ! read -rp "  [?] Enter your choice [0-6]: " choice; then
      echo ""; log_info "No input received; exiting."; exit 0
    fi
    echo ""
  fi

  case "$choice" in
    1) log_info "Mode: Safe Routine Maintenance" ;;
    2) log_info "Mode: Full Aggressive Maintenance"
       DO_REPAIR_MIRRORS=true; AGGRESSIVE_NET=true; FORCE_IPV4=true
       DO_TUNE_STORAGE=true;   DO_POWER_TOOLS=true ;;
    3) log_info "Mode: Storage Tuning";          DO_TUNE_STORAGE=true ;;
    4) log_info "Mode: Network & Mirror Repair"; DO_REPAIR_MIRRORS=true; AGGRESSIVE_NET=true; FORCE_IPV4=true ;;
    5) log_info "Mode: Dry-Run";                 DRY_RUN=true ;;
    6) log_info "Mode: Security Audit (read-only checks added to a safe run)"
       DO_AUDIT_PERMS=true ;;
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
    --snapshot)            DO_SNAPSHOT=true ;;
    --backup-etc)          DO_BACKUP_ETC=true ;;
    --clean-docker)        DO_CLEAN_DOCKER=true ;;
    --clean-docker-volumes) DO_CLEAN_DOCKER=true; DO_CLEAN_DOCKER_VOLUMES=true ;;
    --vacuum-journal)      JOURNAL_VACUUM=true ;;
    --vacuum-journal=*)    JOURNAL_VACUUM=true; JOURNAL_VACUUM_SPEC="${1#*=}" ;;
    --audit-perms)         DO_AUDIT_PERMS=true ;;
    --reboot)              REBOOT_MODE="always" ;;
    --no-reboot)           REBOOT_MODE="never" ;;
    --no-color)            NO_COLOR=true; USE_COLOR=false ;;
    -V|--version)          echo "$SCRIPT_NAME $SCRIPT_VERSION"; exit 0 ;;
    -h|--help)             usage; exit 0 ;;
    *)                     echo "Unknown option: $1" >&2; echo "Try '$SCRIPT_NAME --help'." >&2; exit 2 ;;
  esac
  shift
done

# Any aggressive flag triggers an automatic /etc archive as a safety net.
if [[ $DO_REPAIR_MIRRORS == true || $DO_TUNE_STORAGE == true \
   || $AGGRESSIVE_NET == true || $DO_INSTALL_REALTEK == true ]]; then
  WANTS_AGGRESSIVE=true
fi

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
  [[ -n $LOGFILE ]] && REPORT="${LOGFILE%.log}_report.txt" || REPORT=""
  # Full logging: mirror ALL stdout + stderr (apt, dpkg, errors — everything)
  # into the log file, not just the script's own messages.
  if [[ -n $LOGFILE ]]; then
    exec > >(tee -a "$LOGFILE") 2>&1
    EXEC_LOG_ACTIVE=true
  fi
fi

# Past pre-flight: from here a non-zero exit is a real failure -> arm the alert.
NOTIFY_ARMED=true

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
#  Optional: compressed /etc archive before any aggressive, system-wide repair
# =========================================================================== #
if [[ $DO_BACKUP_ETC == true || $WANTS_AGGRESSIVE == true ]]; then
  backup_etc_archive
fi

# =========================================================================== #
#  Optional: repair apt mirrors BEFORE refreshing package lists
# =========================================================================== #
[[ $DO_REPAIR_MIRRORS == true ]] && repair_mirrors

# =========================================================================== #
#  Update & upgrade
# =========================================================================== #
log_step "Checking free disk space on /"
check_disk_space

log_step "Updating package lists"
apt_update

# Pre-upgrade snapshot (opt-in). Must come before any package modification.
[[ $DO_SNAPSHOT == true ]] && create_pre_upgrade_snapshot

log_step "Upgrading installed packages"
run_soft apt-get upgrade -y "${APT_OPTS[@]}"
run_soft apt-get full-upgrade -y "${APT_OPTS[@]}"
log_ok "Upgrade step complete."

# --- Snap & Flatpak (updated only if the tool is actually installed) -------- #
log_step "Updating Snap and Flatpak packages (if present)"
if have snap; then
  run_soft snap refresh
  log_ok "Snap packages refreshed."
else
  log_info "snap not installed; skipping."
fi
if have flatpak; then
  run_soft flatpak update -y
  log_ok "Flatpak packages updated."
else
  log_info "flatpak not installed; skipping."
fi

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

# --- Deep cleanup: purge residual configs of removed packages (rc state) ---- #
rc_count="$(dpkg -l 2>/dev/null | awk '/^rc/' | wc -l)"
if (( rc_count > 0 )); then
  log_info "Found ${rc_count} residual-config (rc) package(s) to purge."
  run_soft bash -c "dpkg -l | awk '/^rc/ { print \$2 }' | xargs -r apt-get purge -y"
else
  log_info "No residual-config (rc) packages to purge."
fi

have update-grub && run_soft update-grub

# --- Optional container cleanup & journal vacuum (both opt-in) -------------- #
[[ $DO_CLEAN_DOCKER == true ]] && clean_docker
[[ $JOURNAL_VACUUM == true ]] && vacuum_journal

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
#  Security checks (read-only): privesc audit (opt-in), attack surface, SSH.
#  These append to the system report and log any warnings; safe in --dry-run
#  (they only read state, so they run and report even in preview mode).
# =========================================================================== #
log_step "Security checks (read-only)"
[[ $DO_AUDIT_PERMS == true ]] && audit_permissions
attack_surface_summary
ssh_posture_check
if [[ $DRY_RUN == false && -n ${REPORT:-} && -e ${REPORT:-/nonexistent} ]]; then
  log_ok "Security summary appended to ${REPORT}"
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
