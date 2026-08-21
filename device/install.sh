#!/bin/sh
# reDoku rm2fb installer — run ON the reMarkable 2, as root.
#
# Installs the rm2fb display server (swtcon mode, from rM2-stuff) so
# reDoku and other clients can draw to the e-ink panel while xochitl
# keeps working normally.
#
# Safety design:
#   * Userland + systemd files only. No kernel, boot, or partition
#     writes. SSH over USB never depends on xochitl, so uninstall.sh
#     is always reachable.
#   * Nothing existing is modified — we only ADD files. xochitl's
#     LD_PRELOAD comes from an EnvironmentFile that exists only while
#     the server is actually running (armed by ExecStartPost, disarmed
#     by ExecStopPost, which systemd runs even on crashes). A broken
#     server therefore means xochitl starts stock — it can never be
#     crash-looped into remarkable-fail.sh's reboot.
#   * Any failure during install rolls the device back to stock.
#   * A firmware update reinstalls the rootfs, silently removing the
#     systemd files — built-in cleanup. /home/root/redoku survives
#     updates but is inert without them.
#
# Expects the built artifacts already staged (see README):
#   /home/root/redoku/bin/rm2fb_server_swtcon
#   /home/root/redoku/bin/rm2fbctl                (optional)
#   /home/root/redoku/lib/librm2fb_client_swtcon.so
#
# Usage: install.sh [--force]
#   --force   proceed even if the firmware version differs from the
#             version this was tested on.

set -eu

REDOKU_DIR=/home/root/redoku
SERVER_BIN=$REDOKU_DIR/bin/rm2fb_server_swtcon
CLIENT_LIB=$REDOKU_DIR/lib/librm2fb_client_swtcon.so
PRELOAD_ENV=$REDOKU_DIR/preload.env
UNIT=/etc/systemd/system/rm2fb.service
DROPIN_DIR=/etc/systemd/system/xochitl.service.d
DROPIN=$DROPIN_DIR/10-redoku.conf
SOCKET=/var/run/rm2fb.sock
TESTED_VERSION=3.27.3.0

FORCE=0
[ "${1:-}" = --force ] && FORCE=1

say() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---- preflight: read-only checks, abort before touching anything ----

[ "$(id -u)" = 0 ] || die "must run as root"
[ -x /usr/bin/xochitl ] || \
  die "no /usr/bin/xochitl — this doesn't look like a reMarkable; run me ON the device"
grep -q '^ID=codex' /etc/os-release 2>/dev/null || \
  die "/etc/os-release doesn't look like reMarkable firmware"

version=$(sed -n 's/^IMG_VERSION=//p' /etc/os-release | tr -d '"')
if [ "$version" != "$TESTED_VERSION" ]; then
  if [ "$FORCE" = 1 ]; then
    say "WARNING: firmware $version differs from tested $TESTED_VERSION — continuing (--force)"
  else
    die "firmware $version differs from tested $TESTED_VERSION — re-run with --force if you're sure"
  fi
fi

[ -f "$SERVER_BIN" ] || die "missing $SERVER_BIN — deploy the built artifacts first (see README)"
[ -f "$CLIENT_LIB" ] || die "missing $CLIENT_LIB — deploy the built artifacts first (see README)"
chmod +x "$SERVER_BIN"

# 32-bit ARM ELF check: magic 7f 'E' 'L' 'F' + ELFCLASS32, and e_machine
# EM_ARM (0x28 0x00 little-endian at offset 18) — catches an accidental
# host-arch build before it can touch the device. dd+cmp because the
# device's BusyBox od has no -A/-t.
ELFREF=/tmp/redoku-elfref.$$
EMREF=/tmp/redoku-emref.$$
printf '\177ELF\001' > "$ELFREF"
printf '\050\000' > "$EMREF"
elf_check() {
  dd if="$1" bs=1 count=5 2>/dev/null | cmp -s - "$ELFREF" || \
    die "$1 is not a 32-bit ELF"
  dd if="$1" bs=1 skip=18 count=2 2>/dev/null | cmp -s - "$EMREF" || \
    die "$1 is not built for 32-bit ARM"
}
elf_check "$SERVER_BIN"
elf_check "$CLIENT_LIB"
rm -f "$ELFREF" "$EMREF"

[ -f /usr/lib/systemd/system/xochitl.service ] || \
  die "xochitl.service not found where expected"

# Everything swtcon needs at runtime must already be on the firmware.
[ -e /dev/fb0 ] || die "/dev/fb0 missing — swtcon can't drive the panel"
ls /usr/share/remarkable/*.wbf >/dev/null 2>&1 || \
  ls /var/lib/uboot/*.wbf >/dev/null 2>&1 || \
  die "no .wbf waveform file found on the device"
grep -q sy7636a /sys/class/hwmon/hwmon*/name 2>/dev/null || \
  die "sy7636a temperature hwmon not found"

# Refuse to stack on top of someone else's xochitl/display modifications.
if [ -d "$DROPIN_DIR" ]; then
  for f in "$DROPIN_DIR"/*; do
    [ -e "$f" ] || continue
    [ "$f" = "$DROPIN" ] || \
      die "unexpected xochitl drop-in $f — another modification is installed; refusing"
  done
fi
if [ -e "$UNIT" ] && ! grep -q 'reDoku' "$UNIT"; then
  die "$UNIT exists and isn't ours — another rm2fb installation? refusing"
fi

avail_kb=$(df -k / | awk 'NR==2 {print $4}')
[ "$avail_kb" -ge 512 ] || die "only ${avail_kb}KB free on / — not enough"

say "preflight OK (firmware $version)"

# ---- install: from here on, any failure rolls back to stock ----------

rollback() {
  say "FAILED — rolling back to stock"
  rm -f "$PRELOAD_ENV"
  systemctl disable --now rm2fb.service >/dev/null 2>&1 || true
  rm -f "$UNIT" "$DROPIN"
  rmdir "$DROPIN_DIR" 2>/dev/null || true
  systemctl daemon-reload
  systemctl reset-failed xochitl.service 2>/dev/null || true
  systemctl restart xochitl.service || true
  say "rollback done — check with: systemctl status xochitl"
}
STATUS=fail
finish() { [ "$STATUS" = ok ] || rollback; }
trap finish EXIT

say "writing $UNIT"
cat > "$UNIT" <<EOF
# Installed by reDoku's device/install.sh — remove with uninstall.sh.
[Unit]
Description=reDoku rm2fb display server (swtcon mode)
Before=xochitl.service
StartLimitIntervalSec=600
StartLimitBurst=4

[Service]
# The server sd_notifies READY only after its sockets are bound and the
# swtcon threads run, so Before=xochitl really means "ready first".
Type=notify
ExecStart=$SERVER_BIN
# Arm xochitl's LD_PRELOAD only while the server is actually up; the
# StopPost runs on crashes too, so a dead server disarms itself.
ExecStartPost=/bin/sh -c "echo LD_PRELOAD=$CLIENT_LIB > $PRELOAD_ENV"
ExecStopPost=/bin/rm -f $PRELOAD_ENV
# The server's clean-shutdown handler listens for SIGINT, not SIGTERM.
KillSignal=SIGINT
Restart=on-failure
RestartSec=5
Environment=HOME=/home/root

[Install]
WantedBy=multi-user.target
EOF

say "writing $DROPIN"
mkdir -p "$DROPIN_DIR"
cat > "$DROPIN" <<EOF
# Installed by reDoku's device/install.sh — remove with uninstall.sh.
[Service]
# Optional ('-' prefix): when the file is missing xochitl starts
# completely stock. rm2fb.service arms/disarms it, so a broken display
# server can never crash-loop xochitl into remarkable-fail's reboot.
EnvironmentFile=-$PRELOAD_ENV
# rm2fb SIGSTOPs xochitl while another app has the screen; a stopped
# process can't pet the 60 s watchdog, so disable it while installed.
WatchdogSec=0
EOF

say "reloading systemd"
systemctl daemon-reload

say "enabling + starting rm2fb.service"
systemctl enable rm2fb.service
systemctl restart rm2fb.service

say "waiting for $SOCKET"
i=0
while [ ! -S "$SOCKET" ] || [ ! -f "$PRELOAD_ENV" ]; do
  i=$((i + 1))
  [ "$i" -le 15 ] || die "server active but $SOCKET / $PRELOAD_ENV didn't appear"
  sleep 1
done

# Tiny race accepted here: if the server dies between this check and
# xochitl's first preload connect, xochitl can crash-loop once into a
# reboot — after which the arming file guarantees a stock, working boot.
systemctl is-active --quiet rm2fb.service || die "rm2fb.service is not active"

say "restarting xochitl with the rm2fb client preloaded"
systemctl restart xochitl.service

say "verifying (15 s settle)"
sleep 15
systemctl is-active --quiet rm2fb.service || die "rm2fb.service died after the xochitl restart"
systemctl is-active --quiet xochitl.service || die "xochitl isn't running"

STATUS=ok
say "SUCCESS — rm2fb is installed and xochitl is running through it"
say "  server status : systemctl status rm2fb"
say "  client socket : $SOCKET"
say "  back to stock : sh $REDOKU_DIR/uninstall.sh"
