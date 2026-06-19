# 🐧 linux-maintain

![Bash](https://img.shields.io/badge/Bash-4%2B-4EAA25?logo=gnubash&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Debian%20%7C%20Ubuntu%20%7C%20Kali-A81D33?logo=debian&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-blue)
![Version](https://img.shields.io/badge/Version-3.2.0-success)

**One script. Safe by default. Everything logged.**

`linux-maintain.sh` is a single, idempotent maintenance script for Debian, Ubuntu and Kali. A default run updates the system, repairs broken package state, installs the right firmware/drivers/microcode on bare metal, enables SSD TRIM, cleans up, and writes a full log plus a system report — **without ever rewriting your apt sources, editing `/etc/fstab`, or restarting your network**.

The risky stuff (mirror rewriting, forced out-of-tree drivers, persistent IPv4, deep storage tuning) exists too — but it is **strictly opt-in**, always creates a timestamped backup before touching a system file, and runs through the same safe runners and `--dry-run` preview as everything else.

Version 3.2.0 adds opt-in **pre-upgrade snapshots** (a guaranteed rollback path), **container/journal cleanup**, a compressed **`/etc` archive**, **Discord/Telegram alerts** when an unattended run fails or aborts, and a read-only **security summary** (SUID/world-writable audit, listening ports, failed services, SSH posture) appended to every report.

---

## 📖 Table of Contents

- [🧱 Why it's built this way](#-why-its-built-this-way)
- [✨ Features](#-features)
- [📦 Requirements](#-requirements)
- [🚀 Installation](#-installation)
- [💻 Usage](#-usage)
- [📋 What a default run does, step by step](#-what-a-default-run-does-step-by-step)
- [📝 Logging](#-logging)
- [⏰ Automating safe maintenance (systemd timer)](#-automating-safe-maintenance-systemd-timer)
- [🔔 Failure alerts (Discord / Telegram)](#-failure-alerts-discord--telegram)
- [🔒 Safety model](#-safety-model)
- [🚨 Disclaimer](#-disclaimer)
- [🧪 Testing](#-testing)
- [🤝 Contributing](#-contributing)
- [📜 License](#-license)

---

## 🧱 Why it's built this way

Maintenance scripts found online tend to fail in one of two directions: they either do too little to matter, or they "fix" things you never asked them to touch — your mirrors, your fstab, your network — and leave no trace of what changed.

This script is built on three rules:

1. **Safe by default.** A plain `sudo ./linux-maintain.sh` performs only routine, reversible maintenance.
2. **Dangerous actions are opt-in, backed up, and previewable.** Every aggressive fix requires an explicit flag, backs up the file it modifies, and can be rehearsed first with `--dry-run`.
3. **Everything is observable.** Every command is echoed before it runs, and the entire session — including raw `apt`/`dpkg` output and errors — is captured to a timestamped log file.

---

## ✨ Features

### Core (safe, default run)
- Full `apt` refresh, `upgrade` and `full-upgrade` with retries and sane dpkg conffile handling.
- **Disk-space guard** — aborts before package operations if `/` has less than 1024 MB free, preventing half-finished upgrades from bricking a system. *(new in 3.1.0)*
- **Snap & Flatpak updates** — refreshed automatically when the tools are installed; silently skipped when they are not. *(new in 3.1.0)*
- Correct kernel metapackage per distro and architecture (Ubuntu / Debian / Kali, amd64 / arm64 / i386).
- Bare-metal hardware care: firmware, GPU drivers (NVIDIA / AMD / Intel detected via `lspci`), CPU microcode — skipped automatically inside VMs.
- Guest tools when virtualised: VMware, VirtualBox, KVM/QEMU, Hyper-V, WSL.
- SSD periodic TRIM (`fstrim.timer`) enabled when the root device is solid-state.
- Cleanup & repair: `autoremove`, `autoclean`, `--fix-broken`, `dpkg --configure -a`.
- **Deep cleanup** — purges residual configuration of removed packages (`rc` state in dpkg). *(new in 3.1.0)*
- **Full session logging** — *all* stdout and stderr (including apt/dpkg output) is mirrored to `/var/log/linux-maintain_<timestamp>.log`. *(new in 3.1.0)*
- **Never blocks unattended runs** — `DEBIAN_FRONTEND=noninteractive` plus `NEEDRESTART_MODE=a`, so Ubuntu's *needrestart* prompts can't stall a cron/timer run. *(new in 3.1.0)*
- System report (CPU, memory, disks, network, GPU) written next to the log.
- Self log-rotation: its own logs older than 7 days are removed.

### Interactive TUI *(new in 3.1.0)*
Run the script with no flags from a real terminal and you get a menu. If **whiptail** is installed you get a proper TUI dialog; if it isn't — or you press <kbd>Esc</kbd>/Cancel — the script **gracefully degrades** to the classic numbered text menu. Automation is never affected: any flagged or non-TTY run skips the menu entirely.

### Opt-in aggressive repairs
| Flag | What it does |
|---|---|
| `--repair-mirrors` | Replaces known-dead apt mirrors and restores the official repos for your detected distro (sources are backed up first). |
| `--install-realtek` | Installs the out-of-tree RTL8188EUS DKMS Wi-Fi driver **non-interactively** (apt first, then a DKMS source build from `aircrack-ng/rtl8188eus`). The driver is handled in any environment: if it's already present the run skips it; without this flag an **interactive** run prompts `[y/N]` while an **unattended** run safely skips. See [step-by-step](#-what-a-default-run-does-step-by-step). |
| `--aggressive-network` | Forces IPv4 + raises apt retries; persists an IPv4 apt config after the first failure. |
| `--tune-storage` | Persistent I/O scheduler (udev rule), `noatime` on root for SSDs, `vm.swappiness=10` for HDDs. |

Every file these touch is first copied to `<file>.bak_<timestamp>` with root-only permissions.

### Rollback, cleanup & alerts *(new in 3.2.0)*
| Flag | What it does |
|---|---|
| `--snapshot` | Takes a **Timeshift** snapshot (any filesystem) or a **Snapper** snapshot on BTRFS **before** the upgrade. If a snapshot is requested but no tool works, the run **aborts before any package change** — a guaranteed rollback path, never an unprotected upgrade. |
| `--clean-docker` | `docker system prune -f` — dangling images, stopped containers, unused networks, build cache. Skips cleanly if docker is absent or the daemon is down. |
| `--clean-docker-volumes` | Implies `--clean-docker` **and** prunes unused volumes. **Destructive** — deletes data in any volume not attached to a running container; kept separate on purpose. |
| `--backup-etc` | Writes a compressed, root-only `etc-backup_<timestamp>.tar.gz`. Runs **automatically** before any aggressive repair. |
| `--vacuum-journal[=SPEC]` | `journalctl --vacuum-time=14d` by default; `SPEC` may be a time (`30d`) or a size (`500M`, routed to `--vacuum-size`). |

Plus **failure alerts**: if an unattended run exits non-zero after pre-flight (e.g. the disk-space guard or a snapshot abort trips), an alert is sent — a red **rich embed** to Discord and plain text to Telegram. See [Failure alerts](#-failure-alerts-discord--telegram). Successful runs never alert.

### Security visibility *(new in 3.2.0)*
- **Privilege-escalation audit** (`--audit-perms`, read-only): scans for SUID/SGID binaries and world-writable files / non-sticky world-writable directories, and flags any SUID/SGID binary sitting in an unusual writable location (`/tmp`, `/home`, `/var/tmp`, …).
- **Attack-surface summary** (always, read-only): listening sockets (`ss -tulpn`, `netstat` fallback) and failed units (`systemctl --failed`) are appended to the report.
- **SSH posture check** (always, read-only): a passive audit of `sshd_config` that warns on `PermitRootLogin yes`, `PermitEmptyPasswords yes`, and password authentication — it never edits the file.

The two always-on checks add a security section to every system report; `--audit-perms` adds the heavier filesystem scan on demand.

---

## 📦 Requirements

- Debian, Ubuntu or Kali (any apt-based derivative should work).
- Bash 4+ and root privileges (`--dry-run` works without root).
- Optional: `whiptail` for the TUI menu — the script works fine without it.

---

## 🚀 Installation

```bash
git clone https://github.com/zzddf656666/linux-maintain.git
cd linux-maintain
chmod +x linux-maintain.sh
```

---

## 💻 Usage

```bash
# Interactive menu (TUI if whiptail is present, classic text menu otherwise)
sudo ./linux-maintain.sh

# Safe routine maintenance, non-interactive (cron/timers)
sudo ./linux-maintain.sh --yes --no-reboot

# Preview EVERYTHING first — no changes are made
sudo ./linux-maintain.sh --dry-run

# Rehearse an aggressive repair, then run it for real
sudo ./linux-maintain.sh --dry-run --repair-mirrors
sudo ./linux-maintain.sh --repair-mirrors --aggressive-network

# Install the Realtek USB Wi-Fi driver non-interactively (apt, then DKMS source
# build). Without the flag, an interactive run prompts; unattended runs skip it.
sudo ./linux-maintain.sh --install-realtek

# Snapshot before upgrading, then vacuum the journal to 30 days
sudo ./linux-maintain.sh --snapshot --vacuum-journal=30d

# Prune docker (safe set) and run the read-only privesc audit
sudo ./linux-maintain.sh --clean-docker --audit-perms

# Preview the security checks (read-only checks still run in --dry-run)
sudo ./linux-maintain.sh --dry-run --audit-perms
```

### All options

```text
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
      --snapshot           Timeshift/BTRFS(Snapper) snapshot BEFORE the upgrade;
                           aborts the run if no snapshot tool works
      --backup-etc         Compressed, root-only /etc archive (auto before any
                           aggressive repair)
      --vacuum-journal[=N] Vacuum the systemd journal (default 14d; N = 30d / 500M)
      --clean-docker       docker system prune -f (safe set, no volumes)
      --clean-docker-volumes  Also prune UNUSED volumes (implies --clean-docker;
                           DESTRUCTIVE)
      --audit-perms        Read-only SUID/SGID + world-writable scan
  (A listening-port + failed-service summary and a passive SSH-config posture
   check are ALWAYS appended to the report.)

AGGRESSIVE / REPAIR OPTIONS (opt-in; modify system files; always backed up):
      --repair-mirrors     Replace dead apt mirrors, restore official repos
      --install-realtek    Install the RTL8188EUS DKMS driver non-interactively (apt, then source build)
      --aggressive-network Force IPv4 + more retries; persist IPv4 on failure
      --tune-storage       Persistent I/O scheduler, noatime (SSD), swappiness (HDD)

ENVIRONMENT (failure/abort alerts for unattended runs):
      MAINTAIN_DISCORD_WEBHOOK   Discord webhook URL
      MAINTAIN_TELEGRAM_TOKEN    Telegram bot token (with MAINTAIN_TELEGRAM_CHAT)
      MAINTAIN_TELEGRAM_CHAT     Telegram chat id
```

---

## 📋 What a default run does, step by step

1. Checks connectivity (ICMP, then a silent HTTP/204 probe — never restarts your network).
2. Detects distro, architecture, and environment (bare metal / VM / WSL).
3. Checks free space on `/` — aborts below 1024 MB.
4. Refreshes package lists with retries; upgrades and full-upgrades packages.
5. Updates Snap and Flatpak packages if those tools exist.
6. Ensures the correct kernel metapackage is installed.
7. Installs firmware / GPU drivers / microcode (bare metal) or guest tools (VMs).
8. Enables SSD TRIM and runs `fstrim`.
9. Cleans up: autoremove, autoclean, fix-broken, `dpkg --configure -a`, purges `rc` residual configs, refreshes GRUB.
10. Writes a system report.
11. **Appends a read-only security summary** to the report: listening ports (`ss -tulpn`), failed services (`systemctl --failed`), and an SSH `sshd_config` posture check.
12. Rotates old logs, prints a summary, and tells you if a reboot is needed.

Opt-in steps slot into this flow when their flags are present: a `/etc` archive and `--repair-mirrors` run before the upgrade (step 3–4); `--snapshot` runs just before the upgrade itself; `--clean-docker` and `--vacuum-journal` run in the cleanup phase (step 9); and `--audit-perms` adds a SUID/world-writable scan to the security summary (step 11).

The **Realtek RTL8188EUS Wi-Fi driver** is handled as its own step after the driver stage, in **any** environment (no hardware probe, no bare-metal restriction): it is skipped if the `8188eu` module is already present; installed when `--install-realtek` is given; otherwise an interactive run prompts `[y/N]` and an unattended run safely skips it (pass `--install-realtek` to install unattended). Passing `--no-drivers` suppresses this step entirely and overrides `--install-realtek` (a contradictory combination), honouring the explicit intent to avoid driver changes. Installation tries the `realtek-rtl8188eus-dkms` apt package first and, if it isn't packaged (typical on Debian/Ubuntu), automatically builds it from `aircrack-ng/rtl8188eus` via DKMS. All of this respects `--dry-run`.

---

## 📝 Logging

Every non-dry run writes two files (to `/var/log`, or `/tmp` if not writable):

```text
/var/log/linux-maintain_<timestamp>.log          # the FULL session: script + apt + errors
/var/log/linux-maintain_<timestamp>_report.txt   # hardware/system report
```

Since v3.1.0 the log captures **all** stdout/stderr via `exec > >(tee -a "$LOGFILE") 2>&1` — so apt's own output and any unexpected error lands in the file, not just the script's messages. When run from a colour terminal the log will contain ANSI colour codes; view it with `less -R` or strip them with `sed 's/\x1b\[[0-9;]*m//g'`.

---

## ⏰ Automating safe maintenance (systemd timer)

```bash
sudo tee /etc/systemd/system/linux-maintain.service > /dev/null <<'EOF'
[Unit]
Description=Safe system maintenance (linux-maintain)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/linux-maintain/linux-maintain.sh --yes --no-reboot
EOF

sudo tee /etc/systemd/system/linux-maintain.timer > /dev/null <<'EOF'
[Unit]
Description=Weekly safe maintenance

[Timer]
OnCalendar=Sun 04:00
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo install -D -m 0755 linux-maintain.sh /opt/linux-maintain/linux-maintain.sh
sudo systemctl daemon-reload
sudo systemctl enable --now linux-maintain.timer
```

The menu never blocks automation: it appears only when the script is started with **no flags from a real terminal**, and `NEEDRESTART_MODE=a` keeps Ubuntu's service-restart prompts from stalling unattended runs.

---

## 🔔 Failure alerts (Discord / Telegram)

For unattended timer runs you usually want to know when something *breaks* — a near-full disk that trips the guard, a snapshot that can't be created, or any unexpected error. When a run exits non-zero **after pre-flight**, the script sends an alert with the host, time, reason, and a tail of the log. A run that succeeds never alerts, and argument/usage errors before pre-flight don't either.

Each platform is used to its strengths:

- **Discord** receives a professional **rich embed** — a red-coloured card (`#ED4245`) with structured fields (Hostname, Exit Code, Version, Trigger / Reason, Timestamp, and an ANSI-stripped log tail) and a native embed timestamp in the footer. The JSON is assembled by a hardened escaper, so the embed stays valid even when the failure reason or log contains quotes, backslashes, newlines, or UTF-8.
- **Telegram** receives the same information as clean plain text (its formatting is intentionally minimal, so an embed would add nothing).

Credentials are read from the **environment**, never the command line (so they never show up in `ps`). Wire them into the service with an `EnvironmentFile`:

```bash
# Root-only secrets file
sudo install -m 600 /dev/null /etc/linux-maintain.env
sudo tee /etc/linux-maintain.env > /dev/null <<'EOF'
# Use either or both:
MAINTAIN_DISCORD_WEBHOOK=https://discord.com/api/webhooks/XXXX/YYYY
MAINTAIN_TELEGRAM_TOKEN=123456:ABC-your-bot-token
MAINTAIN_TELEGRAM_CHAT=987654321
EOF

# Point the service at it (add under [Service] in the unit above)
#   EnvironmentFile=-/etc/linux-maintain.env
sudo systemctl edit linux-maintain.service   # or edit the unit file directly
```

Add `EnvironmentFile=-/etc/linux-maintain.env` to the `[Service]` block, then `sudo systemctl daemon-reload`. The leading `-` makes the file optional, so the service still starts if it's missing. Alerts need `curl`; if it's absent the script logs a warning instead of failing.

---

## 🔒 Safety model

- `run` executes critical steps and aborts on failure; `run_soft` executes optional steps and continues with a warning.
- Both honour `--dry-run`: the command is printed, nothing is executed. Read-only security checks (privesc audit, attack surface, SSH posture) still run in `--dry-run` since they only read state.
- The ERR trap reports the exact line and command of any unexpected failure, and an EXIT trap fires a single alert when a post-pre-flight run exits non-zero — a red rich embed to Discord, plain text to Telegram.
- Aggressive actions back up every file they touch to `<file>.bak_<timestamp>` (mode 600); `--backup-etc` adds a root-only `/etc` tarball before any aggressive repair.
- The disk-space guard refuses to start package operations on a nearly-full root partition (a `--dry-run` only warns, so previews always complete).
- `--snapshot` is fail-closed: if a snapshot is requested but no tool works, the run aborts **before** any package change rather than upgrading without a rollback path.
- `--clean-docker` never prunes volumes; volume deletion is a separate, explicit `--clean-docker-volumes`. The SSH posture check is passive and never edits `sshd_config`.

## 🚨 Disclaimer

This script modifies system packages and (only when explicitly asked) system configuration files. Read it before running it, rehearse aggressive options with `--dry-run`, and keep backups of anything you cannot afford to lose. It is provided as-is under the MIT licence.

## 🧪 Testing

`test_behavior.sh` runs the script end-to-end inside a container with stubbed package managers (86 assertions across 13 groups). It asserts: full-session logging, no duplicated log lines, `NEEDRESTART_MODE` propagation, the disk-space abort and dry-run-warn paths, the `rc` purge, Snap/Flatpak handling, and all three TUI degradation paths (whiptail select, Cancel → classic menu, no whiptail → classic menu). The 3.2.0 additions cover: new flag parsing and menu option 6, journal-vacuum time-vs-size routing, the docker prune tiers (safe set, destructive volumes, daemon-down, absent), the SSH posture check (insecure flagged, hardened clean, commented directives ignored), the attack-surface report output, the privesc audit (planted SUID + world-writable items, running cleanly under `set -e`), the `/etc` archive (root-only tarball + dry-run preview), the snapshot paths (dry-run preview, Timeshift success, fail-closed abort), the Discord rich-embed payload (valid JSON with all required fields, even when the reason contains quotes/backslashes/newlines/UTF-8) versus Telegram plain text, an end-to-end check that a disk-guard abort fires a valid embed alert, and the full Realtek flow (idempotency skip, forced install, interactive `y`/default-`N`, unattended safe-skip, dry-run preview, the `--no-drivers` suppression (incl. overriding `--install-realtek`), the `can_prompt` TTY/`--yes` gate, and the apt-first → DKMS-source fallback with name/version parsed from the cloned `dkms.conf`). Requires root; intended for disposable environments.

## 🤝 Contributing

Issues and pull requests are welcome — especially reports from distros or hardware I haven't tested. Please run `shellcheck` and `bash test_behavior.sh` (in a disposable VM/container) before submitting.

## 📜 License

MIT — see [LICENSE](LICENSE). © 2026 Abdelrahman El-Maghraby.
