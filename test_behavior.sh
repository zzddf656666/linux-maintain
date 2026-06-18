#!/usr/bin/env bash
# Behavioral test suite for the modified linux-maintain.sh (runs in a container).
set -u
cd "$(dirname "$0")"
PASS=0; FAIL=0
ok()   { echo "  [PASS] $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------------------
# 1) Full run with stubbed package managers (exercises the real script flow)
# ---------------------------------------------------------------------------
echo "== Test 1: full stubbed run (non-dry, as root) =="
STUB=/tmp/stubbin; rm -rf "$STUB"; mkdir -p "$STUB"
CALLS=/tmp/stub_calls.log; : > "$CALLS"

cat > "$STUB/apt-get" <<'EOF'
#!/usr/bin/env bash
echo "apt-get-stub: $* (NEEDRESTART_MODE=${NEEDRESTART_MODE:-unset})" >> /tmp/stub_calls.log
echo "Reading package lists... Done (stub apt-get $1)"
exit 0
EOF
cat > "$STUB/apt-cache" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$STUB/dpkg" <<'EOF'
#!/usr/bin/env bash
echo "dpkg-stub: $*" >> /tmp/stub_calls.log
case "$1" in
  --print-architecture) echo amd64 ;;
  -l)
    echo "Desired=Unknown/Install/Remove/Purge/Hold"
    echo "ii  goodpkg     1.0  amd64  installed package"
    echo "rc  oldpkg-one  1.0  amd64  removed, config remains"
    echo "rc  oldpkg-two  2.0  amd64  removed, config remains"
    ;;
  *) : ;;
esac
exit 0
EOF
cat > "$STUB/snap" <<'EOF'
#!/usr/bin/env bash
echo "snap-stub: $* (NEEDRESTART_MODE=${NEEDRESTART_MODE:-unset})" >> /tmp/stub_calls.log
echo "All snaps up to date (stub)."
EOF
cat > "$STUB/flatpak" <<'EOF'
#!/usr/bin/env bash
echo "flatpak-stub: $*" >> /tmp/stub_calls.log
echo "Nothing to do (stub)."
EOF
cat > "$STUB/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl-stub: $*" >> /tmp/curl_calls.log
exit 0
EOF
chmod +x "$STUB"/*

rm -f /var/log/linux-maintain_*.log /var/log/linux-maintain_*_report.txt
: > /tmp/curl_calls.log
# Webhook is configured but the run SUCCEEDS -> a false failure alert must NOT fire.
MAINTAIN_DISCORD_WEBHOOK='https://discord.example/api/webhooks/TESTHOOK' \
  PATH="$STUB:$PATH" bash linux-maintain.sh --no-reboot --no-color --no-drivers > /tmp/run_out.txt 2>&1
rc=$?
[[ $rc -eq 0 ]] && ok "script exited 0" || bad "script exited $rc"

LOG="$(ls -t /var/log/linux-maintain_*.log 2>/dev/null | head -1)"
[[ -n $LOG ]] && ok "log file created: $LOG" || bad "no log file created"

grep -q "stub apt-get update" "$LOG" && ok "FULL LOGGING: child apt output captured in log" \
                                     || bad "child apt output missing from log"
n_banner=$(grep -c "Maintenance complete." "$LOG")
[[ $n_banner -eq 1 ]] && ok "no duplicate log lines (banner appears once)" \
                      || bad "duplicate lines: 'Maintenance complete.' appears $n_banner times"
grep -q "NEEDRESTART_MODE=a" "$CALLS" && ok "NEEDRESTART_MODE=a exported to child processes" \
                                      || bad "NEEDRESTART_MODE not seen by children"
grep -q "apt-get-stub: purge -y oldpkg-one oldpkg-two" "$CALLS" && ok "rc purge ran with correct packages" \
                                      || bad "rc purge missing/wrong: $(grep purge "$CALLS")"
grep -q "snap-stub: refresh" "$CALLS" && ok "snap refresh called" || bad "snap refresh not called"
grep -q "flatpak-stub: update -y" "$CALLS" && ok "flatpak update called" || bad "flatpak update not called"
grep -q "Free space on /:" /tmp/run_out.txt && ok "disk space guard ran (OK path)" || bad "disk guard missing"
grep -q "Security checks (read-only)" /tmp/run_out.txt && ok "read-only security step runs in a default run" \
                                      || bad "security step missing from default run"
grep -q "SSH security posture" /tmp/run_out.txt && ok "SSH posture check runs by default" \
                                      || bad "SSH posture check missing"
grep -q "Attack-surface summary" /tmp/run_out.txt && ok "attack-surface summary runs by default" \
                                      || bad "attack-surface summary missing"
! grep -q "discord.example" /tmp/curl_calls.log && ok "NO false failure alert on a successful run" \
                                      || bad "a failure alert was sent on a successful run: $(cat /tmp/curl_calls.log)"
REPORT_FILE="$(ls -t /var/log/linux-maintain_*_report.txt 2>/dev/null | head -1)"
[[ -n $REPORT_FILE ]] && grep -q "Attack Surface" "$REPORT_FILE" \
  && ok "security sections appended to the system report" \
  || bad "security sections not found in report: ${REPORT_FILE:-<none>}"

# ---------------------------------------------------------------------------
# 2) Disk guard: abort path (real run) and warn path (dry run), via fake df
# ---------------------------------------------------------------------------
echo "== Test 2: disk space guard =="
sed -n '/^check_disk_space()/,/^}/p' linux-maintain.sh > /tmp/guard_fn.sh
cat > "$STUB/df" <<'EOF'
#!/usr/bin/env bash
echo "Filesystem 1048576-blocks Used Available Capacity Mounted on"
echo "/dev/sda1 50000 49500 500 99% /"
EOF
chmod +x "$STUB/df"
out=$(PATH="$STUB:$PATH" bash -c '
  set -Eeuo pipefail
  MIN_FREE_MB=1024; DRY_RUN=false
  log_ok(){ echo "[OK] $*"; }; log_warn(){ echo "[!] $*"; }
  log_err(){ echo "[x] $*"; }; die(){ log_err "$*"; exit 1; }
  source /tmp/guard_fn.sh; check_disk_space; echo UNREACHABLE'; echo "rc=$?")
echo "$out" | grep -q "below the 1024 MB safety minimum" && echo "$out" | grep -q "rc=1" \
  && ! echo "$out" | grep -q UNREACHABLE \
  && ok "real run ABORTS at 500 MB free (exit 1, clear message)" \
  || bad "abort path wrong: $out"
out=$(PATH="$STUB:$PATH" bash -c '
  set -Eeuo pipefail
  MIN_FREE_MB=1024; DRY_RUN=true
  log_ok(){ echo "[OK] $*"; }; log_warn(){ echo "[!] $*"; }
  log_err(){ echo "[x] $*"; }; die(){ log_err "$*"; exit 1; }
  source /tmp/guard_fn.sh; check_disk_space; echo CONTINUED'; echo "rc=$?")
echo "$out" | grep -q "a real run would ABORT" && echo "$out" | grep -q CONTINUED \
  && ok "dry run WARNS at 500 MB and continues the preview" \
  || bad "dry-run guard path wrong: $out"
rm -f "$STUB/df"

# ---------------------------------------------------------------------------
# 3) Interactive menu: whiptail path, Cancel fallback, no-whiptail fallback
# ---------------------------------------------------------------------------
echo "== Test 3: interactive menu (whiptail + graceful degradation) =="
sed -n '/^interactive_menu()/,/^}/p' linux-maintain.sh > /tmp/menu_fn.sh

menu_harness() {  # $1 = have_whiptail(true/false)  stdin = classic-menu input
  HAVE_WT="$1" bash -c '
    set -Eeuo pipefail
    SCRIPT_VERSION=3.1.0
    C_CYN=""; C_BOLD=""; C_YLW=""
    DRY_RUN=false; DO_TUNE_STORAGE=false; DO_REPAIR_MIRRORS=false
    AGGRESSIVE_NET=false; FORCE_IPV4=false; DO_POWER_TOOLS=false
    _log_line(){ echo "$1"; }; log_info(){ echo "[*] $*"; }; log_err(){ echo "[x] $*"; }
    have(){ [[ $1 == whiptail ]] && [[ $HAVE_WT == true ]] && return 0
            [[ $1 == whiptail ]] && return 1; command -v "$1" >/dev/null; }
    source /tmp/menu_fn.sh
    interactive_menu
    echo "RESULT DRY=$DRY_RUN TUNE=$DO_TUNE_STORAGE MIRRORS=$DO_REPAIR_MIRRORS"'
}

# 3a) whiptail present and user selects "3" (stub writes selection to stderr, like real whiptail)
cat > "$STUB/whiptail" <<'EOF'
#!/usr/bin/env bash
printf '3' >&2
exit 0
EOF
chmod +x "$STUB/whiptail"
out=$(PATH="$STUB:$PATH" menu_harness true < /dev/null)
echo "$out" | grep -q "RESULT DRY=false TUNE=true MIRRORS=false" \
  && ok "whiptail selection '3' -> storage tuning mode set" \
  || bad "whiptail selection path wrong: $out"

# 3b) whiptail present but user hits Cancel/Esc (exit 1) -> classic menu fallback, choose 5
cat > "$STUB/whiptail" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
out=$(printf '5\n' | PATH="$STUB:$PATH" menu_harness true 2>&1)
echo "$out" | grep -q "Interactive Mode: Choose Maintenance Type" && echo "$out" | grep -q "RESULT DRY=true" \
  && ok "Cancel/Esc -> graceful fallback to classic menu, '5' sets dry-run, no errors" \
  || bad "cancel fallback wrong: $out"

# 3c) whiptail NOT installed -> classic menu directly, choose 2
out=$(printf '2\n' | menu_harness false)
echo "$out" | grep -q "RESULT DRY=false TUNE=true MIRRORS=true" \
  && ok "no whiptail -> classic menu, '2' sets full aggressive mode" \
  || bad "no-whiptail fallback wrong: $out"

# 3d) real whiptail binary in a broken/non-tty terminal degrades without crashing
if command -v whiptail >/dev/null 2>&1; then
  out=$(printf '1\n' | TERM=dumb bash -c '
    set -Eeuo pipefail
    choice="$(whiptail --title t --menu m 18 70 2 "1" "a" "2" "b" 3>&1 1>&2 2>&3 </dev/null)" || choice=""
    [[ -z $choice ]] && echo "DEGRADED-OK" || echo "GOT:$choice"' 2>/dev/null)
  echo "$out" | grep -q "DEGRADED-OK" \
    && ok "real whiptail in unusable terminal -> empty choice, no crash (set -e survives)" \
    || bad "real whiptail degradation: $out"
else
  echo "  [SKIP] real whiptail not installed in container"
fi

# ---------------------------------------------------------------------------
# 4) Argument parser: new flags + menu option 6
# ---------------------------------------------------------------------------
echo "== Test 4: new flag parsing + menu option 6 =="
sed -n '/^while \[\[ \$# -gt 0 \]\]/,/^done/p' linux-maintain.sh > /tmp/parse_loop.sh

parse_harness() {  # args after the function name are passed to the parser
  bash -c '
    set -Eeuo pipefail
    SCRIPT_NAME=t; SCRIPT_VERSION=x; usage(){ :; }
    DRY_RUN=false; ASSUME_YES=false; DO_DRIVERS=true; DO_POWER_TOOLS=false
    DO_TUNE_STORAGE=false; FORCE_IPV4=false; DO_REPAIR_MIRRORS=false
    DO_INSTALL_REALTEK=false; AGGRESSIVE_NET=false; REBOOT_MODE=auto
    NO_COLOR=false; USE_COLOR=false
    DO_SNAPSHOT=false; DO_BACKUP_ETC=false; DO_CLEAN_DOCKER=false
    DO_CLEAN_DOCKER_VOLUMES=false; JOURNAL_VACUUM=false; JOURNAL_VACUUM_SPEC=14d
    DO_AUDIT_PERMS=false
    source /tmp/parse_loop.sh
    echo "PARSE SNAP=$DO_SNAPSHOT ETC=$DO_BACKUP_ETC DOCKER=$DO_CLEAN_DOCKER VOL=$DO_CLEAN_DOCKER_VOLUMES JV=$JOURNAL_VACUUM JVSPEC=$JOURNAL_VACUUM_SPEC AUDIT=$DO_AUDIT_PERMS"
  ' _ "$@"
}

out=$(parse_harness --clean-docker-volumes)
echo "$out" | grep -q "DOCKER=true VOL=true" \
  && ok "--clean-docker-volumes implies --clean-docker AND sets the volumes flag" \
  || bad "clean-docker-volumes parse wrong: $out"

out=$(parse_harness --vacuum-journal=30d)
echo "$out" | grep -q "JV=true JVSPEC=30d" \
  && ok "--vacuum-journal=30d enables vacuum with a custom spec" \
  || bad "vacuum-journal=spec parse wrong: $out"

out=$(parse_harness --vacuum-journal)
echo "$out" | grep -q "JV=true JVSPEC=14d" \
  && ok "--vacuum-journal (no value) keeps the 14d default" \
  || bad "vacuum-journal default parse wrong: $out"

out=$(parse_harness --snapshot --backup-etc --audit-perms)
echo "$out" | grep -q "SNAP=true ETC=true.*AUDIT=true" \
  && ok "--snapshot / --backup-etc / --audit-perms parse together" \
  || bad "combined parse wrong: $out"

# menu option 6 -> DO_AUDIT_PERMS=true (classic menu, no whiptail)
sed -n '/^interactive_menu()/,/^}/p' linux-maintain.sh > /tmp/menu_fn.sh
out=$(printf '6\n' | HAVE_WT=false bash -c '
  set -Eeuo pipefail
  SCRIPT_VERSION=3.2.0; C_CYN=""; C_BOLD=""; C_YLW=""
  DRY_RUN=false; DO_TUNE_STORAGE=false; DO_REPAIR_MIRRORS=false
  AGGRESSIVE_NET=false; FORCE_IPV4=false; DO_POWER_TOOLS=false; DO_AUDIT_PERMS=false
  _log_line(){ echo "$1"; }; log_info(){ echo "[*] $*"; }; log_err(){ echo "[x] $*"; }
  have(){ [[ $1 == whiptail ]] && return 1; command -v "$1" >/dev/null; }
  source /tmp/menu_fn.sh; interactive_menu
  echo "RESULT AUDIT=$DO_AUDIT_PERMS"')
echo "$out" | grep -q "RESULT AUDIT=true" \
  && ok "menu option 6 -> security audit (DO_AUDIT_PERMS=true)" \
  || bad "menu option 6 wrong: $out"

# ---------------------------------------------------------------------------
# 5) Journal vacuum routing (time- vs size-based)
# ---------------------------------------------------------------------------
echo "== Test 5: journal vacuum routing =="
sed -n '/^vacuum_journal()/,/^}/p' linux-maintain.sh > /tmp/vac_fn.sh
cat > "$STUB/journalctl" <<'EOF'
#!/usr/bin/env bash
echo "journalctl-stub: $*" >> /tmp/vac_calls.log
EOF
chmod +x "$STUB/journalctl"
vac_run() {  # $1 = spec
  : > /tmp/vac_calls.log
  PATH="$STUB:$PATH" bash -c '
    set -Eeuo pipefail
    DRY_RUN=false; JOURNAL_VACUUM_SPEC="'"$1"'"
    log_step(){ :; }; log_info(){ :; }; log_ok(){ :; }; log_cmd(){ :; }
    run_soft(){ "$@"; }
    source /tmp/vac_fn.sh; vacuum_journal' >/dev/null 2>&1
}
vac_run 30d;  grep -q -- "--vacuum-time=30d"  /tmp/vac_calls.log && ok "spec '30d' -> --vacuum-time=30d"  || bad "time route wrong: $(cat /tmp/vac_calls.log)"
vac_run 500M; grep -q -- "--vacuum-size=500M" /tmp/vac_calls.log && ok "spec '500M' -> --vacuum-size=500M" || bad "size route wrong: $(cat /tmp/vac_calls.log)"
rm -f "$STUB/journalctl"

# ---------------------------------------------------------------------------
# 6) Docker prune: safe set vs destructive volumes vs daemon-down vs absent
# ---------------------------------------------------------------------------
echo "== Test 6: docker prune tiers =="
sed -n '/^clean_docker()/,/^}/p' linux-maintain.sh > /tmp/docker_fn.sh
make_docker_stub() {  # $1 = info exit code
  cat > "$STUB/docker" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == info ]]; then exit $1; fi
echo "docker-stub: \$*" >> /tmp/docker_calls.log
EOF
  chmod +x "$STUB/docker"
}
docker_run() {  # $1 = DO_CLEAN_DOCKER_VOLUMES
  : > /tmp/docker_calls.log
  PATH="$STUB:$PATH" bash -c '
    set -Eeuo pipefail
    DRY_RUN=false; DO_CLEAN_DOCKER_VOLUMES='"$1"'
    log_step(){ :; }; log_info(){ echo "[*] $*"; }; log_ok(){ :; }; log_warn(){ echo "[!] $*"; }; log_cmd(){ :; }
    run_soft(){ "$@"; }
    source /tmp/docker_fn.sh; clean_docker'
}
make_docker_stub 0
out=$(docker_run false 2>&1)
grep -q "docker-stub: system prune -f" /tmp/docker_calls.log \
  && ! grep -q -- "--volumes" /tmp/docker_calls.log \
  && ok "default --clean-docker prunes the SAFE set (no --volumes)" \
  || bad "docker safe prune wrong: $(cat /tmp/docker_calls.log)"
echo "$out" | grep -q "volumes were NOT touched" && ok "user is told volumes were left intact" || bad "no volumes-skipped notice"

out=$(docker_run true 2>&1)
grep -q "docker-stub: system prune -f --volumes" /tmp/docker_calls.log \
  && ok "--clean-docker-volumes additionally prunes volumes" \
  || bad "docker volume prune missing: $(cat /tmp/docker_calls.log)"
echo "$out" | grep -qi "destroys data" && ok "destructive volume prune carries a clear warning" || bad "no destructive warning"

make_docker_stub 1   # daemon not responding
: > /tmp/docker_calls.log
out=$(docker_run false 2>&1)
! grep -q "system prune" /tmp/docker_calls.log && echo "$out" | grep -q "daemon is not responding" \
  && ok "daemon-down -> skips prune safely" || bad "daemon-down path wrong: $out / $(cat /tmp/docker_calls.log)"
rm -f "$STUB/docker"

out=$(PATH="$STUB:$PATH" bash -c '
  set -Eeuo pipefail; DRY_RUN=false; DO_CLEAN_DOCKER_VOLUMES=false
  log_step(){ :; }; log_info(){ echo "[*] $*"; }; log_ok(){ :; }; log_warn(){ :; }; log_cmd(){ :; }; run_soft(){ "$@"; }
  source /tmp/docker_fn.sh; clean_docker' 2>&1)
echo "$out" | grep -q "docker not installed" && ok "docker absent -> graceful skip" || bad "docker-absent path wrong: $out"

# ---------------------------------------------------------------------------
# 7) SSH posture: flags insecure directives, clears a hardened config
# ---------------------------------------------------------------------------
echo "== Test 7: SSH posture check =="
sed -n '/^ssh_posture_check()/,/^}/p' linux-maintain.sh > /tmp/ssh_fn.sh
ssh_run() {  # $1 = path to sshd_config, returns combined log + report
  local rep; rep="$(mktemp)"
  out=$(SSHD_CONFIG="$1" REPORT="$rep" bash -c '
    set -Eeuo pipefail
    DRY_RUN=false
    log_step(){ :; }; log_info(){ echo "[*] $*"; }; log_ok(){ echo "[OK] $*"; }; log_warn(){ echo "[!] $*"; }
    sec_append(){ [[ $DRY_RUN == false && -n ${REPORT:-} && -e ${REPORT:-/nonexistent} ]] && printf "%s\n" "$*" >> "$REPORT" 2>/dev/null || true; }
    source /tmp/ssh_fn.sh; ssh_posture_check' 2>&1)
  cat "$rep"; echo "$out"; rm -f "$rep"
}
insecure_cfg="$(mktemp)"; printf 'PermitRootLogin yes\nPermitEmptyPasswords yes\nPasswordAuthentication yes\n' > "$insecure_cfg"
res=$(ssh_run "$insecure_cfg")
echo "$res" | grep -q "PermitRootLogin yes" && echo "$res" | grep -q "PermitEmptyPasswords yes" \
  && ok "SSH posture flags PermitRootLogin + PermitEmptyPasswords" \
  || bad "ssh insecure flags missing: $res"
hardened_cfg="$(mktemp)"; printf 'PermitRootLogin no\nPasswordAuthentication no\nPermitEmptyPasswords no\n' > "$hardened_cfg"
res=$(ssh_run "$hardened_cfg")
echo "$res" | grep -q "no high-risk directives flagged" \
  && ok "SSH posture passes a hardened config with no findings" \
  || bad "ssh hardened path wrong: $res"
# commented-out directive must NOT be flagged (passive/effective reading)
commented_cfg="$(mktemp)"; printf '#PermitRootLogin yes\nPermitRootLogin no\n' > "$commented_cfg"
res=$(ssh_run "$commented_cfg")
echo "$res" | grep -q "no high-risk directives flagged" \
  && ok "commented '#PermitRootLogin yes' is correctly ignored" \
  || bad "commented directive mis-handled: $res"
rm -f "$insecure_cfg" "$hardened_cfg" "$commented_cfg"

# ---------------------------------------------------------------------------
# 8) Attack-surface summary: stubbed ss + systemctl, written to the report
# ---------------------------------------------------------------------------
echo "== Test 8: attack-surface summary =="
sed -n '/^attack_surface_summary()/,/^}/p' linux-maintain.sh > /tmp/atk_fn.sh
cat > "$STUB/ss" <<'EOF'
#!/usr/bin/env bash
echo "Netid State  Recv-Q Send-Q Local:Port"
echo "tcp   LISTEN 0      128    0.0.0.0:22"
EOF
cat > "$STUB/systemctl" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "--failed" ]] && { echo "fake.service loaded failed failed Fake Broken Daemon"; exit 0; }
exit 0
EOF
chmod +x "$STUB/ss" "$STUB/systemctl"
rep="$(mktemp)"
out=$(PATH="$STUB:$PATH" REPORT="$rep" bash -c '
  set -Eeuo pipefail
  DRY_RUN=false
  log_step(){ :; }; log_info(){ echo "[*] $*"; }; log_ok(){ echo "[OK] $*"; }; log_warn(){ echo "[!] $*"; }
  sec_append(){ [[ $DRY_RUN == false && -n ${REPORT:-} && -e ${REPORT:-/nonexistent} ]] && printf "%s\n" "$*" >> "$REPORT" 2>/dev/null || true; }
  source /tmp/atk_fn.sh; attack_surface_summary' 2>&1)
grep -q "0.0.0.0:22" "$rep" && ok "attack-surface writes listening ports to the report" || bad "ports missing from report: $(cat "$rep")"
grep -q "fake.service" "$rep" && ok "attack-surface writes failed units to the report" || bad "failed unit missing: $(cat "$rep")"
echo "$out" | grep -q "failed systemd unit" && ok "failed units raise a console warning" || bad "no failed-unit warning: $out"
rm -f "$rep" "$STUB/ss" "$STUB/systemctl"

# ---------------------------------------------------------------------------
# 9) Privilege-escalation audit: detects planted SUID + world-writable items
# ---------------------------------------------------------------------------
echo "== Test 9: privilege-escalation audit =="
sed -n '/^audit_permissions()/,/^}/p' linux-maintain.sh > /tmp/audit_fn.sh
SANDBOX="$(mktemp -d)"; mkdir -p "$SANDBOX/home" "$SANDBOX/bin"
# planted SUID binary inside a "home"-like path (suspicious location)
printf '#!/bin/sh\n' > "$SANDBOX/home/rootme"; chmod 4755 "$SANDBOX/home/rootme"
# world-writable file and a world-writable dir without sticky bit
: > "$SANDBOX/bin/loosefile"; chmod 0666 "$SANDBOX/bin/loosefile"
mkdir -p "$SANDBOX/opendir"; chmod 0777 "$SANDBOX/opendir"
rep="$(mktemp)"
out=$(AUDIT_PATHS="$SANDBOX" REPORT="$rep" bash -c '
  set -Eeuo pipefail
  DRY_RUN=false
  log_step(){ :; }; log_info(){ :; }; log_ok(){ echo "[OK] $*"; }; log_warn(){ echo "[!] $*"; }
  sec_append(){ [[ $DRY_RUN == false && -n ${REPORT:-} && -e ${REPORT:-/nonexistent} ]] && printf "%s\n" "$*" >> "$REPORT" 2>/dev/null || true; }
  source /tmp/audit_fn.sh; audit_permissions' 2>&1)
ar=$?
[[ $ar -eq 0 ]] && ok "audit runs to completion under set -e (exit 0)" || bad "audit aborted under set -e (exit $ar): $out"
grep -q "rootme" "$rep" && ok "audit lists the planted SUID binary" || bad "SUID not listed: $(cat "$rep")"
echo "$out" | grep -qi "unusual writable locations" && ok "SUID in a home-like path raises a privesc warning" || bad "no privesc warning: $out"
grep -q "loosefile" "$rep" && ok "audit lists the world-writable file" || bad "world-writable file missing: $(cat "$rep")"
grep -q "opendir" "$rep" && ok "audit lists the non-sticky world-writable dir" || bad "world-writable dir missing: $(cat "$rep")"
rm -rf "$SANDBOX" "$rep"

# ---------------------------------------------------------------------------
# 10) /etc archive: creates a root-only tar.gz (and dry-run only previews)
# ---------------------------------------------------------------------------
echo "== Test 10: /etc archive =="
sed -n '/^backup_etc_archive()/,/^}/p' linux-maintain.sh > /tmp/etc_fn.sh
etcdir="$(mktemp -d)"
out=$(LOGDIR="$etcdir" bash -c '
  set -Eeuo pipefail
  DRY_RUN=false; START_STAMP=testrun
  log_step(){ :; }; log_info(){ :; }; log_ok(){ echo "[OK] $*"; }; log_warn(){ echo "[!] $*"; }; log_cmd(){ :; }
  source /tmp/etc_fn.sh; backup_etc_archive' 2>&1)
arch="$etcdir/etc-backup_testrun.tar.gz"
[[ -s $arch ]] && ok "/etc archive created and non-empty" || bad "archive missing: $out"
[[ "$(stat -c '%a' "$arch" 2>/dev/null)" == "600" ]] && ok "/etc archive is locked to root (mode 600)" || bad "archive mode not 600: $(stat -c '%a' "$arch" 2>/dev/null)"
tar tzf "$arch" >/dev/null 2>&1 && ok "/etc archive is a valid gzip tarball" || bad "archive not a valid tarball"
# dry-run must not create a file
rm -f "$arch"
out=$(LOGDIR="$etcdir" bash -c '
  set -Eeuo pipefail
  DRY_RUN=true; START_STAMP=testrun
  log_step(){ :; }; log_info(){ :; }; log_ok(){ :; }; log_warn(){ :; }; log_cmd(){ echo "CMD $*"; }
  source /tmp/etc_fn.sh; backup_etc_archive' 2>&1)
[[ ! -e $arch ]] && echo "$out" | grep -q "would archive /etc" && ok "dry-run previews the /etc archive without writing it" || bad "dry-run etc archive wrong: $out"
rm -rf "$etcdir"

# ---------------------------------------------------------------------------
# 11) Pre-upgrade snapshot: dry-run preview, tool success, hard abort
# ---------------------------------------------------------------------------
echo "== Test 11: pre-upgrade snapshot =="
sed -n '/^create_pre_upgrade_snapshot()/,/^}/p' linux-maintain.sh > /tmp/snap_fn.sh
cat > "$STUB/findmnt" <<'EOF'
#!/usr/bin/env bash
echo "${FAKE_FSTYPE:-ext4}"
EOF
chmod +x "$STUB/findmnt"
snap_harness() {  # stdin: nothing; relies on PATH + env FAKE_FSTYPE
  PATH="$STUB:$PATH" bash -c '
    set -Eeuo pipefail
    SCRIPT_VERSION=3.2.0; START_STAMP=testrun
    log_step(){ :; }; log_info(){ echo "[*] $*"; }; log_ok(){ echo "[OK] $*"; }; log_warn(){ echo "[!] $*"; }; log_cmd(){ echo "CMD $*"; }
    die(){ echo "[x] $*"; exit 1; }
    source /tmp/snap_fn.sh; create_pre_upgrade_snapshot; echo "REACHED-END"'
}
# 11a) dry-run, no tools, non-btrfs -> warns it WOULD abort, returns 0
out=$(DRY_RUN=true FAKE_FSTYPE=ext4 snap_harness 2>&1); rc=$?
echo "$out" | grep -q "would ABORT" && echo "$out" | grep -q "REACHED-END" && [[ $rc -eq 0 ]] \
  && ok "dry-run with no snapshot tool previews the abort and continues" \
  || bad "snapshot dry-run wrong (rc=$rc): $out"
# 11b) real run, Timeshift present and succeeds -> snapshot created, returns 0
cat > "$STUB/timeshift" <<'EOF'
#!/usr/bin/env bash
echo "timeshift-stub: $*" >&2
exit 0
EOF
chmod +x "$STUB/timeshift"
out=$(DRY_RUN=false FAKE_FSTYPE=ext4 snap_harness 2>&1); rc=$?
echo "$out" | grep -q "Timeshift snapshot created" && [[ $rc -eq 0 ]] \
  && ok "real run with working Timeshift creates a snapshot" \
  || bad "snapshot success path wrong (rc=$rc): $out"
rm -f "$STUB/timeshift"
# 11c) real run, no tool, non-btrfs -> HARD ABORT (exit 1, guarantee message)
out=$(DRY_RUN=false FAKE_FSTYPE=ext4 snap_harness 2>&1); rc=$?
echo "$out" | grep -q "guarantees a rollback path" && [[ $rc -eq 1 ]] && ! echo "$out" | grep -q "REACHED-END" \
  && ok "requested-but-impossible snapshot ABORTS before any package change (exit 1)" \
  || bad "snapshot hard-abort wrong (rc=$rc): $out"
rm -f "$STUB/findmnt"

# ---------------------------------------------------------------------------
# 12) Failure notification: unit behaviour + end-to-end disk-guard alert
# ---------------------------------------------------------------------------
echo "== Test 12: failure/abort notifications =="
sed -n '/^notify_failure()/,/^}/p' linux-maintain.sh > /tmp/notify_fn.sh
# pull in the helpers notify_failure depends on
sed -n '/^_json_escape()/,/^}/p' linux-maintain.sh > /tmp/jsonesc_fn.sh
sed -n '/^_discord_embed_payload()/,/^}/p' linux-maintain.sh > /tmp/embed_fn.sh
cat > "$STUB/curl" <<'EOF'
#!/usr/bin/env bash
# Record the call, and split out the Discord -d payload, Telegram fields, and URL.
args=("$@")
echo "curl-stub: $*" >> /tmp/notify_calls.log
for ((i=0; i<${#args[@]}; i++)); do
  [[ ${args[i]} == "-d" ]]               && printf '%s' "${args[i+1]}" > /tmp/notify_payload.json
  [[ ${args[i]} == "--data-urlencode" ]] && printf '%s\n' "${args[i+1]}" >> /tmp/notify_telegram.txt
done
echo "${args[-1]}" >> /tmp/notify_urls.txt
exit 0
EOF
chmod +x "$STUB/curl"
notify_run() {  # env: DISCORD/TELEGRAM vars + DRY_RUN + REASON
  rm -f /tmp/notify_calls.log /tmp/notify_payload.json /tmp/notify_telegram.txt /tmp/notify_urls.txt
  printf 'SENTINEL_LOG_LINE last action before the crash\n' > /tmp/x.log
  PATH="$STUB:$PATH" REASON="${REASON:-disk guard tripped}" bash -c '
    set -Eeuo pipefail
    SCRIPT_VERSION=3.2.0; LOGFILE=/tmp/x.log
    log_info(){ echo "[*] $*"; }; log_ok(){ echo "[OK] $*"; }; log_warn(){ echo "[!] $*"; }
    source /tmp/jsonesc_fn.sh; source /tmp/embed_fn.sh; source /tmp/notify_fn.sh
    notify_failure 1 "$REASON"' 2>&1
}
json_ok() { python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1; }

# 12a) nothing configured -> no curl call
DISCORD_WEBHOOK="" TELEGRAM_TOKEN="" TELEGRAM_CHAT="" DRY_RUN=false notify_run >/dev/null 2>&1
[[ ! -s /tmp/notify_calls.log ]] && ok "no webhook configured -> notify_failure is a no-op" || bad "unexpected curl call: $(cat /tmp/notify_calls.log)"

# 12b) Discord configured -> POSTs a valid rich-embed JSON payload
out=$(DISCORD_WEBHOOK="https://discord.example/api/webhooks/HOOK" TELEGRAM_TOKEN="" TELEGRAM_CHAT="" DRY_RUN=false notify_run)
grep -q "discord.example" /tmp/notify_urls.txt && ok "Discord alert hits the webhook URL" || bad "discord URL missing: $(cat /tmp/notify_urls.txt 2>/dev/null)"
json_ok /tmp/notify_payload.json && ok "Discord payload is valid JSON" || bad "discord payload is INVALID JSON: $(cat /tmp/notify_payload.json 2>/dev/null)"
grep -q '"embeds"' /tmp/notify_payload.json && grep -q '"color":15548997' /tmp/notify_payload.json \
  && ok "Discord payload is a coloured rich embed (red #ED4245)" \
  || bad "discord embed/color missing: $(cat /tmp/notify_payload.json)"
for f in "Hostname" "Exit Code" "Trigger / Reason" "Timestamp (UTC)" "Log (tail)"; do
  grep -qF "\"$f\"" /tmp/notify_payload.json || bad "embed field missing: $f"
done
grep -qF "\"Log (tail)\"" /tmp/notify_payload.json && ok "embed contains all required fields (Hostname/Exit Code/Reason/Timestamp/Log)" || true
grep -q "disk guard tripped" /tmp/notify_payload.json && ok "embed carries the trigger/reason" || bad "reason missing from embed"
grep -q "SENTINEL_LOG_LINE" /tmp/notify_payload.json && ok "embed includes a tail of the log" || bad "log snippet missing from embed"
python3 -c 'import json,sys
d=json.load(open("/tmp/notify_payload.json")); e=d["embeds"][0]
assert e["timestamp"].endswith("Z"), e["timestamp"]
names=[f["name"] for f in e["fields"]]
assert names==["Hostname","Exit Code","Version","Trigger / Reason","Timestamp (UTC)","Log (tail)"], names
print("ok")' >/dev/null 2>&1 && ok "embed JSON structure verified (timestamp + field order)" || bad "embed JSON structure wrong: $(cat /tmp/notify_payload.json)"

# 12c) Telegram configured -> plain text via sendMessage, NOT an embed
DISCORD_WEBHOOK="" TELEGRAM_TOKEN="123:ABC" TELEGRAM_CHAT="999" DRY_RUN=false notify_run >/dev/null 2>&1
grep -q "api.telegram.org/bot123:ABC/sendMessage" /tmp/notify_urls.txt \
  && ok "Telegram alert hits the sendMessage endpoint" \
  || bad "telegram endpoint wrong: $(cat /tmp/notify_urls.txt 2>/dev/null)"
grep -q "^text=" /tmp/notify_telegram.txt && grep -q "FAILED" /tmp/notify_telegram.txt \
  && ok "Telegram payload is simple text (chat_id + text)" \
  || bad "telegram text payload wrong: $(cat /tmp/notify_telegram.txt 2>/dev/null)"
[[ ! -e /tmp/notify_payload.json ]] && ok "Telegram path sends NO embed/JSON payload (text only)" \
  || bad "telegram unexpectedly sent an embed: $(cat /tmp/notify_payload.json)"

# 12d) both configured -> Discord embed AND Telegram text in one run
DISCORD_WEBHOOK="https://discord.example/api/webhooks/BOTH" TELEGRAM_TOKEN="123:ABC" TELEGRAM_CHAT="999" DRY_RUN=false notify_run >/dev/null 2>&1
{ grep -q '"embeds"' /tmp/notify_payload.json && grep -q "^text=" /tmp/notify_telegram.txt; } \
  && ok "with both configured, Discord gets the embed and Telegram gets text" \
  || bad "dual-channel dispatch wrong"

# 12e) dry-run -> previews, never calls curl
out=$(DISCORD_WEBHOOK="https://discord.example/api/webhooks/HOOK" TELEGRAM_TOKEN="" TELEGRAM_CHAT="" DRY_RUN=true notify_run)
[[ ! -s /tmp/notify_calls.log ]] && echo "$out" | grep -q "would send a failure notification" \
  && ok "dry-run previews the alert and sends nothing" \
  || bad "notify dry-run wrong: $out / $(cat /tmp/notify_calls.log 2>/dev/null)"

# 12f) nasty reason (quotes, backslash, newline, em-dash) -> still valid JSON
REASON='exit 1 at line 7: rm -rf "$x" \ done
multi—line' DISCORD_WEBHOOK="https://discord.example/api/webhooks/HOOK" TELEGRAM_TOKEN="" TELEGRAM_CHAT="" DRY_RUN=false notify_run >/dev/null 2>&1
json_ok /tmp/notify_payload.json \
  && ok "embed JSON stays valid when the reason has quotes/backslashes/newlines/UTF-8" \
  || bad "escaper produced invalid JSON: $(cat /tmp/notify_payload.json)"
rm -f "$STUB/curl"

# 12g) END-TO-END: the disk-space guard abort actually fires an alert
echo "   (end-to-end: disk-guard abort -> Discord alert)"
cat > "$STUB/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl-stub: $*" >> /tmp/e2e_curl.log
args=("$@"); for ((i=0;i<${#args[@]};i++)); do [[ ${args[i]} == "-d" ]] && printf '%s' "${args[i+1]}" > /tmp/e2e_payload.json; done
exit 0
EOF
cat > "$STUB/df" <<'EOF'
#!/usr/bin/env bash
echo "Filesystem 1048576-blocks Used Available Capacity Mounted on"
echo "/dev/sda1 50000 49500 500 99% /"
EOF
chmod +x "$STUB/curl" "$STUB/df"
: > /tmp/e2e_curl.log; rm -f /tmp/e2e_payload.json
rm -f /var/log/linux-maintain_*.log
MAINTAIN_DISCORD_WEBHOOK="https://discord.example/api/webhooks/E2E" \
  PATH="$STUB:$PATH" bash linux-maintain.sh --yes --no-reboot --no-color --no-drivers > /tmp/e2e_out.txt 2>&1
e2e_rc=$?
[[ $e2e_rc -ne 0 ]] && ok "disk-guard abort exits non-zero (real failure)" || bad "expected non-zero exit on disk-guard abort"
grep -q "discord.example/api/webhooks/E2E" /tmp/e2e_curl.log \
  && ok "END-TO-END: disk-guard abort triggers the Discord failure alert" \
  || bad "no alert fired on disk-guard abort: $(cat /tmp/e2e_curl.log)"
{ [[ -s /tmp/e2e_payload.json ]] && json_ok /tmp/e2e_payload.json && grep -q '"embeds"' /tmp/e2e_payload.json; } \
  && ok "END-TO-END alert payload is a valid rich embed" \
  || bad "e2e payload not a valid embed: $(cat /tmp/e2e_payload.json 2>/dev/null)"
grep -q "below the 1024 MB safety minimum" /tmp/e2e_out.txt \
  && ok "abort reason is logged before the alert" || bad "abort reason missing from output"
rm -f "$STUB/df" "$STUB/curl"

echo ""
echo "RESULTS: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
