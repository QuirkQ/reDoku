#!/bin/sh
# reDoku installer — run ON the reMarkable 2, as root.
#
# Installs the rm2fb display server (swtcon mode, from rM2-stuff) so
# reDoku and other clients can draw to the e-ink panel while xochitl
# keeps working normally; and the M4 hijack — a decoy "Sudoku" document
# in xochitl's own library plus redoku-watcher.service, which spawns the
# game when that document is tapped (PLAN.md §10, M4-HIJACK.md).
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
#   * Any failure during install rolls the device back to stock,
#     decoy document and watcher included — see rollback() below.
#   * A firmware update reinstalls the rootfs, silently removing the
#     systemd files under /etc/systemd/system/ (rm2fb.service, the
#     xochitl drop-in, redoku-watcher.service) — built-in cleanup.
#     /home/root/redoku survives updates but is inert without them:
#     the decoy document stays in xochitl's library (it's a real,
#     printable PDF either way — see tools/mkdecoy.rb), it just goes
#     back to opening as a plain PDF until a reinstall.
#   * A re-run is a plain overwrite, not a merge: the decoy's four
#     sidecar files and the watcher unit are regenerated/copied fresh
#     every time (mkdecoy.rb is deterministic, R9 in its header), which
#     also resets anything xochitl itself wrote into them since the
#     last install (lastOpened, pinned, …) back to fresh-install values.
#     What a re-run does NOT touch: the decoy's <uuid>/ ink directory
#     (the player's own annotations on the decoy, if any) and its
#     <uuid>.thumbnails/ cache — both are xochitl's to write, never
#     this script's, so they survive every re-run untouched.
#
# Expects the built artifacts already staged (see README):
#   /home/root/redoku/bin/rm2fb_server_swtcon
#   /home/root/redoku/bin/rm2fbctl                (optional)
#   /home/root/redoku/lib/librm2fb_client_swtcon.so
#   /home/root/redoku/watch.conf                  (tools/mkdecoy.rb output)
#   /home/root/redoku/decoy/<uuid>.{pdf,metadata,content,pagedata}
#   /home/root/redoku/redoku-watcher.service      (this repo's device/ copy)
#
# bin/redoku also stages /home/root/redoku/bin/redoku (the game) alongside
# these, but this script neither needs it nor reads it for the display
# server or decoy/watcher steps — they install the same way with or
# without a game build, on purpose. (The watcher will simply have nothing
# to spawn until the game binary is staged, e.g. via `bin/redoku play`.)
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

# --- M4 hijack: decoy document + watcher --------------------------------
# XOCHITL_DIR is where the decoy's four sidecar files ultimately live —
# xochitl's own document store, not $REDOKU_DIR — so a document appears
# in the stock library. WATCH_CONF is the single source of truth for
# *which* uuid that is: bin/redoku writes it there (from tools/mkdecoy.rb's
# own output, staged first) before this script ever runs, so the uuid is
# read out of it below rather than hardcoded a second time in this file —
# same reasoning mkdecoy.rb gives for not calling SecureRandom.uuid.
XOCHITL_DIR=/home/root/.local/share/remarkable/xochitl
WATCH_CONF=$REDOKU_DIR/watch.conf
DECOY_DIR=$REDOKU_DIR/decoy
WATCHER_UNIT_SRC=$REDOKU_DIR/redoku-watcher.service
WATCHER_UNIT=/etc/systemd/system/redoku-watcher.service

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
if [ -e "$WATCHER_UNIT" ] && ! grep -q 'reDoku' "$WATCHER_UNIT"; then
  die "$WATCHER_UNIT exists and isn't ours — refusing"
fi

# --- M4 preflight: decoy document + watcher -----------------------------
[ -f "$WATCH_CONF" ] || \
  die "missing $WATCH_CONF — deploy the decoy files first (bin/redoku install stages them)"
DECOY_PDF=$(sed -n 's/^pdf=//p' "$WATCH_CONF")
[ -n "$DECOY_PDF" ] || die "$WATCH_CONF has no 'pdf=' line — corrupt, or hand-edited?"
case $DECOY_PDF in
  "$XOCHITL_DIR"/*.pdf) ;;
  *) die "$WATCH_CONF's pdf= path ($DECOY_PDF) is not under $XOCHITL_DIR — refusing" ;;
esac
# Every other decoy path is this one with a different suffix — deriving
# them here, once, is what keeps the uuid out of every other line below
# (and out of rollback(), which reuses these same variables).
DECOY_BASE=${DECOY_PDF%.pdf}
DECOY_UUID=${DECOY_BASE##*/}
DECOY_STAGED_PDF=$DECOY_DIR/$DECOY_UUID.pdf
DECOY_STAGED_METADATA=$DECOY_DIR/$DECOY_UUID.metadata
DECOY_STAGED_CONTENT=$DECOY_DIR/$DECOY_UUID.content
DECOY_STAGED_PAGEDATA=$DECOY_DIR/$DECOY_UUID.pagedata
for f in "$DECOY_STAGED_PDF" "$DECOY_STAGED_METADATA" "$DECOY_STAGED_CONTENT" "$DECOY_STAGED_PAGEDATA"; do
  [ -f "$f" ] || die "missing staged decoy file $f — deploy the decoy files first (bin/redoku install stages them)"
done
[ -f "$WATCHER_UNIT_SRC" ] || \
  die "missing $WATCHER_UNIT_SRC — deploy device/redoku-watcher.service first (bin/redoku install stages it)"
[ -d "$XOCHITL_DIR" ] || \
  die "$XOCHITL_DIR missing — this doesn't look like a reMarkable with xochitl's document store"

avail_kb=$(df -k / | awk 'NR==2 {print $4}')
[ "$avail_kb" -ge 512 ] || die "only ${avail_kb}KB free on / — not enough"

say "preflight OK (firmware $version)"

# ---- install: from here on, any failure rolls back to stock ----------

rollback() {
  say "FAILED — rolling back to stock"
  rm -f "$PRELOAD_ENV"
  systemctl disable --now redoku-watcher.service >/dev/null 2>&1 || true
  systemctl disable --now rm2fb.service >/dev/null 2>&1 || true
  rm -f "$UNIT" "$DROPIN" "$WATCHER_UNIT"
  rmdir "$DROPIN_DIR" 2>/dev/null || true
  # DECOY_UUID is always set by here — it's derived from $WATCH_CONF
  # during preflight, which runs to completion before this trap is even
  # armed (below). "Back to stock" means no trace of the decoy either,
  # so this is unconditional, exactly like the rm2fb/dropin removal
  # above — including on a re-run of an install that had already
  # succeeded once.
  rm -f "$XOCHITL_DIR/$DECOY_UUID.pdf" "$XOCHITL_DIR/$DECOY_UUID.metadata" \
        "$XOCHITL_DIR/$DECOY_UUID.content" "$XOCHITL_DIR/$DECOY_UUID.pagedata"
  rm -rf "$XOCHITL_DIR/$DECOY_UUID"
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

say "installing $WATCHER_UNIT"
# A plain copy, not a heredoc like the two units above: this one has no
# device-specific paths to substitute (its ExecStart is a fixed
# /home/root/redoku/bin/redoku, install-independent), so the repo's
# device/redoku-watcher.service — already staged at $WATCHER_UNIT_SRC by
# bin/redoku — is the single source of truth for its content.
cp "$WATCHER_UNIT_SRC" "$WATCHER_UNIT"

say "reloading systemd"
systemctl daemon-reload

say "enabling + starting rm2fb.service"
systemctl enable rm2fb.service
systemctl restart rm2fb.service

say "enabling + starting redoku-watcher.service"
systemctl enable redoku-watcher.service
systemctl restart redoku-watcher.service

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
systemctl is-active --quiet redoku-watcher.service || die "redoku-watcher.service is not active"

say "installing the decoy document into $XOCHITL_DIR"
# Plain overwrite (see the header comment on what that does and doesn't
# reset). Copied, not moved, so a re-run's staged files under $DECOY_DIR
# stay put for the next run rather than only existing once.
cp "$DECOY_STAGED_PDF" "$XOCHITL_DIR/$DECOY_UUID.pdf"
cp "$DECOY_STAGED_METADATA" "$XOCHITL_DIR/$DECOY_UUID.metadata"
cp "$DECOY_STAGED_CONTENT" "$XOCHITL_DIR/$DECOY_UUID.content"
cp "$DECOY_STAGED_PAGEDATA" "$XOCHITL_DIR/$DECOY_UUID.pagedata"
# The per-page ink dir a real document has (xochitl-3.27-format.md): empty
# on a fresh install, but mkdir -p is a no-op if the player already wrote
# on the decoy in a previous install, so their ink is never touched here.
# xochitl's own <uuid>.thumbnails/ cache is left alone entirely — this
# script never creates or touches it, on either an install or a re-run.
mkdir -p "$XOCHITL_DIR/$DECOY_UUID"

say "restarting xochitl with the rm2fb client preloaded — this also indexes the decoy"
systemctl restart xochitl.service

say "verifying (15 s settle)"
sleep 15
systemctl is-active --quiet rm2fb.service || die "rm2fb.service died after the xochitl restart"
systemctl is-active --quiet redoku-watcher.service || die "redoku-watcher.service died after the xochitl restart"
systemctl is-active --quiet xochitl.service || die "xochitl isn't running"

STATUS=ok
say "SUCCESS — rm2fb is installed, the decoy is in the library, and xochitl is running through it"
say "  server status : systemctl status rm2fb"
say "  watcher status: systemctl status redoku-watcher"
say "  client socket : $SOCKET"
say "  back to stock : sh $REDOKU_DIR/uninstall.sh"
