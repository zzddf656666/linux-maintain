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
chmod +x "$STUB"/*

rm -f /var/log/linux-maintain_*.log /var/log/linux-maintain_*_report.txt
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

echo ""
echo "RESULTS: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
