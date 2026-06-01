# linux-maintain

A single, safe, idempotent **system-maintenance tool for Debian, Ubuntu, and Kali**.

It does the boring-but-important work — update, upgrade, fix broken packages,
install firmware/drivers/microcode, keep SSDs trimmed, and produce a report — and
it does it **safely by default**. The riskier "fix a broken box" operations
(rewriting apt mirrors, forcing out-of-tree drivers, deep storage tuning) are
**strictly opt-in**, always **back up the files they touch**, and can be previewed
with `--dry-run` before anything changes.

```bash
sudo ./linux-maintain.sh            # safe routine maintenance
sudo ./linux-maintain.sh --dry-run  # preview everything, change nothing
```

---

## Why it's built this way

Most "all-in-one" maintenance scripts fail in one of two directions: they're either
too timid to fix a genuinely broken system, or they're a kitchen sink that rewrites
your config and hopes for the best. This tool separates the two on purpose:

- **A default run is conservative.** It never rewrites `/etc/apt/sources.list`,
  never edits `/etc/fstab`, and never restarts networking — so it's safe to run on
  a remote server or in a cron job.
- **The aggressive fixes are real, but gated.** Each one lives behind its own flag,
  creates a timestamped backup of any file it modifies, and runs through the same
  `run` / `run_soft` wrappers and `--dry-run` preview as everything else.
- **Failures are explicit.** The script uses `set -Eeuo pipefail` with an error trap
  that reports the exact failing line. Optional steps that are *allowed* to fail are
  the only ones that continue — there is no blanket `|| true`.

---

## Features

**Safe (runs by default):**
- `apt update` / `upgrade` / `full-upgrade` with sane non-interactive defaults
- Correct kernel metapackage per distro (`linux-image-generic` on Ubuntu, arch-specific on Debian/Kali)
- Bare-metal firmware, GPU drivers (NVIDIA / AMD / Intel), and CPU microcode — hardware-detected
- VM/WSL guest tools (VMware, VirtualBox, KVM/QEMU, Hyper-V, WSL)
- SSD periodic TRIM (`fstrim.timer`)
- `autoremove` / `autoclean` / `--fix-broken` / `dpkg --configure -a`
- Timestamped log + read-only system report, plus a `fastfetch` summary

**Aggressive (opt-in, backed up, dry-run-able):**
- `--repair-mirrors` — smart apt mirror repair
- `--install-realtek` — force the RTL8188EUS DKMS Wi-Fi driver
- `--aggressive-network` — persistent IPv4 + raised apt retries
- `--tune-storage` — persistent I/O scheduler, `noatime` (SSD), `vm.swappiness` (HDD)

---

## Supported systems

Anything `apt`-based. Requires `root` for real runs (`--dry-run` works without it).

**Distributions**

| Distro | Supported | Notes |
|--------|:---------:|-------|
| Ubuntu (and derivatives) | ✅ | incl. 24.04 deb822 `ubuntu.sources` handling |
| Debian | ✅ | |
| Kali Linux | ✅ | rolling release |
| Fedora / RHEL (`dnf`) | ❌ | not apt-based |
| Arch (`pacman`) | ❌ | not apt-based |

**Environments**

| Environment | Behaviour |
|-------------|-----------|
| Bare metal | Installs firmware, GPU drivers, microcode |
| VM (VMware, VirtualBox, KVM/QEMU, Hyper-V) | Installs the matching guest tools instead |
| WSL | Installs WSL utilities (`wslu`) |

**Architectures**

| Arch | Kernel metapackage |
|------|--------------------|
| `amd64` | `linux-image-generic` (Ubuntu) / `linux-image-amd64` (Debian, Kali) |
| `arm64` | `linux-image-generic` (Ubuntu) / `linux-image-arm64` (Debian, Kali) |
| `i386` | `linux-image-686` (Debian, Kali) |

---

## Wi-Fi adapters (Realtek / TP-Link)

The `--install-realtek` flag (and the auto-detection on bare metal) installs
**`realtek-rtl8188eus-dkms`**, which drives the **Realtek RTL8188EUS** chipset used
by small TP-Link USB adapters such as the **TL-WN725N** and **TL-WN722N (v2/v3)**.

> **If you have an AC adapter** (e.g. **Archer T2U / T3U**), it uses a different
> chipset (RTL8811AU / RTL8812AU) and needs **`rtl8812au-dkms`** instead — not
> `rtl8188eus`. Check your chipset with `lsusb` before installing.

---

## ⚠️ Disclaimer

**This tool installs, upgrades, and removes packages, and — when you pass the
aggressive flags — modifies system files.**

In particular, `--repair-mirrors` **overwrites `/etc/apt/sources.list`** (and backs
up `ubuntu.sources` on Ubuntu 24.04+), `--tune-storage` **edits `/etc/fstab`** and
writes `udev`/`sysctl` rules, and `--aggressive-network` **writes a persistent apt
config**. Every modified file is copied to `FILE.bak_<timestamp>` first, but you are
still responsible for what runs on your machine.

- Always run with `--dry-run` first and read the planned actions.
- Review the script before running it as root (it's short and commented).
- Use it at your own risk. **No warranty** — see [LICENSE](LICENSE).

---

## Installation

**One-liner (download + make executable):**

```bash
curl -fsSL https://raw.githubusercontent.com/zzddf656666/linux-maintain/main/linux-maintain.sh -o linux-maintain.sh \
  && chmod +x linux-maintain.sh
```

(or with `wget`)

```bash
wget -qO linux-maintain.sh https://raw.githubusercontent.com/zzddf656666/linux-maintain/main/linux-maintain.sh \
  && chmod +x linux-maintain.sh
```

**Or clone the repo:**

```bash
git clone https://github.com/zzddf656666/linux-maintain.git
cd linux-maintain
chmod +x linux-maintain.sh
```

> Good habit: open the file and skim it before running anything as root.

---

## Usage & common use cases

**1. Safe routine maintenance** (laptop/desktop/server, or a weekly cron job):

```bash
sudo ./linux-maintain.sh
```

**2. Preview first — change nothing:**

```bash
sudo ./linux-maintain.sh --dry-run
```

**3. Unattended (no prompts), e.g. from a timer:**

```bash
sudo ./linux-maintain.sh --yes --no-reboot
```

**4. "My system is broken" — aggressive repair** (dead mirrors + flaky network):

```bash
# preview the repair plan
sudo ./linux-maintain.sh --dry-run --repair-mirrors --aggressive-network

# then run it for real
sudo ./linux-maintain.sh --repair-mirrors --aggressive-network
```

**5. Install a TP-Link / Realtek RTL8188EUS USB Wi-Fi driver:**

```bash
sudo ./linux-maintain.sh --install-realtek
```

**6. Performance tuning for a fresh install:**

```bash
sudo ./linux-maintain.sh --tune-storage
```

---

## Options

| Flag | Type | What it does |
|------|------|--------------|
| `-n, --dry-run` | safe | Preview every action; change nothing |
| `-y, --yes` | safe | Non-interactive (assume "yes"); good for cron/timers |
| `--no-drivers` | safe | Skip the bare-metal firmware/GPU/microcode block |
| `--power-tools` | safe | Install laptop power management (TLP, thermald, powertop) |
| `--force-ipv4` | safe | Force apt over IPv4 for this run only |
| `--reboot` | safe | Reboot at the end **if** a reboot is required |
| `--no-reboot` | safe | Never reboot, even if one is required |
| `--no-color` | safe | Disable coloured output |
| `-V, --version` | safe | Print version and exit |
| `-h, --help` | safe | Show help and exit |
| `--repair-mirrors` | **aggressive** | Replace dead apt mirrors and restore official repos (backs up sources) |
| `--install-realtek` | **aggressive** | Force-install the RTL8188EUS DKMS driver |
| `--aggressive-network` | **aggressive** | Force IPv4 + raise apt retries; persist IPv4 config on failure |
| `--tune-storage` | **aggressive** | Persistent I/O scheduler (udev), `noatime` on root (SSD), `vm.swappiness=10` (HDD) |

---

## What it does, step by step

1. Parse flags, confirm root (unless `--dry-run`), open a timestamped log.
2. Check connectivity (informational — never restarts the network).
3. Detect the distro (`/etc/os-release`) and environment (bare metal / VM / WSL).
4. *(opt-in)* `--repair-mirrors`: back up and repair apt sources before updating.
5. `apt update` (with retries), then `upgrade` and `full-upgrade`.
6. Ensure the correct kernel metapackage for the distro/arch.
7. On bare metal: firmware, detected GPU drivers, CPU microcode; auto-Realtek if the adapter is present.
8. *(opt-in)* `--install-realtek`: force the RTL8188EUS DKMS driver in any environment.
9. Install VM/WSL guest tools when running virtualised.
10. *(opt-in)* `--power-tools` on laptops.
11. Storage: SSD TRIM by default; *(opt-in)* `--tune-storage` for scheduler/fstab/swappiness.
12. Cleanup & repair: `autoremove`, `autoclean`, `--fix-broken`, `dpkg --configure -a`, `update-grub`.
13. Install `fastfetch`, write a read-only report, rotate old logs, show a summary.
14. Reboot only if required, honouring `--reboot` / `--no-reboot` / `--yes`.

---

## Logs & backups

- **Log:** `/var/log/linux-maintain_<timestamp>.log` (falls back to `/tmp`). Logs older than 7 days are pruned automatically.
- **Report:** `<log>_report.txt` — OS, kernel, CPU, memory, disks, network, GPU.
- **Backups:** any modified system file is copied to `FILE.bak_<timestamp>` before changes.

**Reverting an aggressive change** — restore the backup, e.g.:

```bash
sudo cp /etc/apt/sources.list.bak_<timestamp> /etc/apt/sources.list
sudo cp /etc/fstab.bak_<timestamp> /etc/fstab
sudo rm -f /etc/apt/apt.conf.d/99force-ipv4 /etc/udev/rules.d/60-ioscheduler.rules /etc/sysctl.d/99-swappiness.conf
```

---

## Automating safe maintenance (systemd timer)

`/etc/systemd/system/linux-maintain.service`

```ini
[Unit]
Description=Safe system maintenance
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/linux-maintain.sh --yes --no-reboot
```

`/etc/systemd/system/linux-maintain.timer`

```ini
[Unit]
Description=Run system maintenance weekly

[Timer]
OnCalendar=Sun *-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
sudo cp linux-maintain.sh /usr/local/sbin/ && sudo chmod +x /usr/local/sbin/linux-maintain.sh
sudo systemctl enable --now linux-maintain.timer
```

> Keep the aggressive flags out of automated runs — use them only when you're fixing a problem by hand.

---

## Contributing

Issues and pull requests welcome. Please keep the safe-by-default philosophy:
new system-modifying behaviour should be opt-in, backed up, and dry-run-able.

## License

MIT © Abdelrahman Fekry El-Maghraby — see [LICENSE](LICENSE).
