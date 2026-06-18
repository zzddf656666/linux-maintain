# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/); versioning follows [SemVer](https://semver.org/).

## [3.2.0] — 2026-06-18

Backward-compatible feature release focused on rollback safety, deeper cleanup,
unattended-run alerting, and read-only security visibility. The safe-by-default
model is unchanged: a plain run still rewrites no sources, edits no fstab, and
restarts no network. Every new heavyweight or destructive action is opt-in.

### Added
- **Pre-upgrade snapshots** (`--snapshot`): creates a tagged Timeshift snapshot
  (any filesystem) or, on BTRFS, a Snapper snapshot, *before* the upgrade.
  Because the goal is a guaranteed rollback path, a requested-but-impossible
  snapshot **aborts before any package change** rather than upgrading
  unprotected.
- **Container cleanup** (`--clean-docker`): `docker system prune -f` for the
  safe set (dangling images, stopped containers, unused networks, build cache).
  Volume pruning is split into a separate, explicit `--clean-docker-volumes`
  (implies `--clean-docker`) because deleting detached volumes is destructive.
  Skips cleanly when docker is absent or the daemon is down.
- **Webhook failure alerts**: on a non-zero exit *after* pre-flight (including a
  disk-guard or snapshot abort during an unattended timer run), an alert is
  sent to Discord and/or Telegram. **Discord** receives a professional red
  **rich embed** (fields: Hostname, Exit Code, Version, Trigger/Reason,
  Timestamp, and an ANSI-stripped log tail, plus a native embed timestamp);
  **Telegram** receives the equivalent as plain text. Configured via environment
  only (`MAINTAIN_DISCORD_WEBHOOK`, `MAINTAIN_TELEGRAM_TOKEN`,
  `MAINTAIN_TELEGRAM_CHAT`) so secrets never appear in `ps`. Successful runs
  never alert. The JSON payload is built with a hardened escaper that keeps the
  embed valid even when the reason or log contains quotes, backslashes,
  newlines, or UTF-8.
- **Compressed /etc archive** (`--backup-etc`): writes a root-only
  `etc-backup_<timestamp>.tar.gz`; runs automatically before any aggressive
  repair (`--repair-mirrors`, `--tune-storage`, `--aggressive-network`,
  `--install-realtek`).
- **Journal vacuuming** (`--vacuum-journal[=SPEC]`): `journalctl --vacuum-time`
  (default `14d`) or `--vacuum-size` when SPEC ends in K/M/G (e.g. `500M`).
- **Privilege-escalation audit** (`--audit-perms`): read-only scan for SUID/SGID
  binaries and world-writable files / non-sticky world-writable directories,
  flagging SUID/SGID in unusual writable locations.
- **Attack-surface summary** (always, read-only): listening sockets
  (`ss -tulpn`, `netstat` fallback) and failed units (`systemctl --failed`)
  appended to the system report.
- **SSH posture check** (always, read-only): passive audit of `sshd_config`
  flagging `PermitRootLogin yes`, `PermitEmptyPasswords yes`, and
  password authentication; never modifies the file.
- Interactive menu option **6) Security Audit** (safe maintenance plus the
  privilege-escalation audit).
- `test_behavior.sh`: ten new test groups (flag parsing, menu option 6,
  journal-vacuum routing, docker tiers, SSH posture, attack surface, privesc
  audit, /etc archive, snapshot abort/success, an end-to-end disk-guard →
  Discord alert with a valid rich-embed payload, and the full Realtek flow),
  86 assertions total.

### Changed
- The ERR trap and `die()` now record a failure context that the EXIT trap uses
  to send a single alert. `ssh_posture_check` and `audit_permissions` honour the
  optional `SSHD_CONFIG` and `AUDIT_PATHS` overrides. Version bumped to 3.2.0.
- **Realtek RTL8188EUS handling reworked** into a safe-by-default flow. The
  previous `lsusb` hardware-detection and bare-metal gate were removed in favour
  of an idempotent, environment-independent step: skip if the `8188eu` module is
  already present; install when `--install-realtek` is given; otherwise prompt
  `[y/N]` on an interactive terminal and safely skip when unattended (cron/`--yes`
  without the flag). Installation now tries the `realtek-rtl8188eus-dkms` apt
  package first and **falls back to building from `aircrack-ng/rtl8188eus` via
  DKMS** when it isn't packaged (typical on Debian/Ubuntu) — name and version are
  read from the cloned `dkms.conf` (never hardcoded), the HTTPS clone is
  pinnable/mirrorable via `RTL8188EUS_REPO` / `RTL8188EUS_REF`, and the whole
  step honours `--dry-run` and never aborts the run. `--no-drivers` suppresses
  the step entirely and overrides `--install-realtek`.

### Unchanged (guaranteed)
- All pre-existing CLI flags, their semantics, and the step order of a default
  run; the `run` / `run_soft` model and `--dry-run` preview; and the
  safe-by-default contract (no sources/fstab/network changes unless opted in).

## [3.1.0] — 2026-06-11

Backward-compatible feature release. The core structure, safe-by-default logic
and `--dry-run` mechanism are unchanged; a default run performs the same flow
as 3.0.0 plus the additions below.

### Added
- **Disk-space guard**: the script now checks free space on `/` right before
  refreshing package lists and aborts a real run below 1024 MB
  (`MIN_FREE_MB`) to prevent half-finished upgrades. A `--dry-run` only warns,
  so previews always complete.
- **Full session logging**: all stdout and stderr (including raw apt/dpkg
  output and unexpected errors) is mirrored into the log file via
  `exec > >(tee -a "$LOGFILE") 2>&1`, enabled right after log creation.
- **Snap & Flatpak support**: after the apt upgrade phase, `snap refresh` and
  `flatpak update -y` run automatically when those tools are installed
  (guarded by `have`, executed through `run_soft`).
- **Deep cleanup**: residual configuration of removed packages (dpkg `rc`
  state) is purged during the cleanup phase
  (`dpkg -l | awk '/^rc/ { print $2 }' | xargs -r apt-get purge -y`).
- **needrestart compatibility**: `NEEDRESTART_MODE=a` is exported alongside
  `DEBIAN_FRONTEND=noninteractive`, so Ubuntu's service-restart prompts can
  never stall an unattended run.
- **Interactive TUI**: the no-flags menu now uses `whiptail` when available
  and gracefully degrades to the classic numbered text menu when whiptail is
  absent or the user presses Cancel/Esc — with identical mode behaviour.
- `test_behavior.sh`: containerised behavioural test suite (stubbed package
  managers) covering all of the above.

### Changed
- `_log_line` skips its explicit per-line append while full-session capture is
  active, so log lines are never duplicated.
- Version bumped to 3.1.0.

### Unchanged (guaranteed)
- All CLI flags, their semantics, and the step order of a default run.
- The `run` / `run_soft` runner model and the `--dry-run` preview.
- Safe-by-default behaviour: no sources rewritten, no fstab edits, no network
  restarts unless explicitly requested via opt-in flags.

## [3.0.0]

Initial public release: safe-by-default maintenance with opt-in aggressive
repairs, dry-run preview, timestamped backups, hardware-aware driver
installation, SSD TRIM, cleanup, logging and system report.
