# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/); versioning follows [SemVer](https://semver.org/).

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
