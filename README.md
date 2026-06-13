# 🐧 linux-maintain

![Bash](https://img.shields.io/badge/Bash-4%2B-4EAA25?logo=gnubash&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Debian%20%7C%20Ubuntu%20%7C%20Kali-A81D33?logo=debian&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-blue)
![Version](https://img.shields.io/badge/Version-3.1.0-success)

**One script. Safe by default. Everything logged.**

`linux-maintain.sh` is a single, idempotent maintenance script for Debian, Ubuntu and Kali. A default run updates the system, repairs broken package state, installs the right firmware/drivers/microcode on bare metal, enables SSD TRIM, cleans up, and writes a full log plus a system report — **without ever rewriting your apt sources, editing `/etc/fstab`, or restarting your network**.

The risky stuff (mirror rewriting, forced out-of-tree drivers, persistent IPv4, deep storage tuning) exists too — but it is **strictly opt-in**, always creates a timestamped backup before touching a system file, and runs through the same safe runners and `--dry-run` preview as everything else.

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
| `--install-realtek` | Force-installs the out-of-tree RTL8188EUS DKMS Wi-Fi driver (TP-Link TL-WN725N and similar). |
| `--aggressive-network` | Forces IPv4 + raises apt retries; persists an IPv4 apt config after the first failure. |
| `--tune-storage` | Persistent I/O scheduler (udev rule), `noatime` on root for SSDs, `vm.swappiness=10` for HDDs. |

Every file these touch is first copied to `<file>.bak_<timestamp>` with root-only permissions.

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

# Force the Realtek USB Wi-Fi driver
sudo ./linux-maintain.sh --install-realtek
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

AGGRESSIVE / REPAIR OPTIONS (opt-in; modify system files; always backed up):
      --repair-mirrors     Replace dead apt mirrors, restore official repos
      --install-realtek    Force the RTL8188EUS DKMS Wi-Fi driver
      --aggressive-network Force IPv4 + more retries; persist IPv4 on failure
      --tune-storage       Persistent I/O scheduler, noatime (SSD), swappiness (HDD)
```

---

## 📋 What a default run does, step by step

1. Checks free space on `/` — aborts below 1024 MB.
2. Checks connectivity (ICMP, then a silent HTTP/204 probe — never restarts your network).
3. Detects distro, architecture, and environment (bare metal / VM / WSL).
4. Refreshes package lists with retries; upgrades and full-upgrades packages.
5. Updates Snap and Flatpak packages if those tools exist.
6. Ensures the correct kernel metapackage is installed.
7. Installs firmware / GPU drivers / microcode (bare metal) or guest tools (VMs).
8. Enables SSD TRIM and runs `fstrim`.
9. Cleans up: autoremove, autoclean, fix-broken, `dpkg --configure -a`, purges `rc` residual configs, refreshes GRUB.
10. Writes a system report, rotates old logs, prints a summary, and tells you if a reboot is needed.

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

## 🔒 Safety model

- `run` executes critical steps and aborts on failure; `run_soft` executes optional steps and continues with a warning.
- Both honour `--dry-run`: the command is printed, nothing is executed.
- The ERR trap reports the exact line and command of any unexpected failure.
- Aggressive actions back up every file they touch to `<file>.bak_<timestamp>` (mode 600).
- The disk-space guard refuses to start package operations on a nearly-full root partition (a `--dry-run` only warns, so previews always complete).

## 🚨 Disclaimer

This script modifies system packages and (only when explicitly asked) system configuration files. Read it before running it, rehearse aggressive options with `--dry-run`, and keep backups of anything you cannot afford to lose. It is provided as-is under the MIT licence.

## 🧪 Testing

`test_behavior.sh` runs the script end-to-end inside a container with stubbed package managers and asserts: full-session logging, no duplicated log lines, `NEEDRESTART_MODE` propagation, the disk-space abort and dry-run-warn paths, the `rc` purge, Snap/Flatpak handling, and all three TUI degradation paths (whiptail select, Cancel → classic menu, no whiptail → classic menu). Requires root; intended for disposable environments.

## 🤝 Contributing

Issues and pull requests are welcome — especially reports from distros or hardware I haven't tested. Please run `shellcheck` and `bash test_behavior.sh` (in a disposable VM/container) before submitting.

## 📜 License

MIT — see [LICENSE](LICENSE). © 2026 Abdelrahman Fekry El-Maghraby.
