#!/bin/sh
# reDoku rm2fb uninstaller — run ON the reMarkable 2, as root.
#
# Returns the device to stock. Idempotent: safe to run repeatedly and
# on partial installs (it removes whatever it finds, step by step).
#
# Usage: uninstall.sh [--purge]
#   --purge   also delete /home/root/redoku entirely (binaries, these
#             scripts, everything). Without it the directory stays but
#             is inert — nothing references it once the systemd files
#             are gone.

set -u

REDOKU_DIR=/home/root/redoku
PRELOAD_ENV=$REDOKU_DIR/preload.env
UNIT=/etc/systemd/system/rm2fb.service
DROPIN_DIR=/etc/systemd/system/xochitl.service.d
DROPIN=$DROPIN_DIR/10-redoku.conf

say() { printf '==> %s\n' "$*"; }

[ "$(id -u)" = 0 ] || { echo "ERROR: must run as root" >&2; exit 1; }

say "disarming the xochitl preload"
rm -f "$PRELOAD_ENV"

say "stopping + disabling rm2fb.service"
systemctl disable --now rm2fb.service 2>/dev/null || true

say "removing systemd files"
rm -f "$UNIT" "$DROPIN"
rmdir "$DROPIN_DIR" 2>/dev/null || true

say "reloading systemd + restarting xochitl (stock)"
systemctl daemon-reload
systemctl reset-failed xochitl.service 2>/dev/null || true
systemctl restart xochitl.service

sleep 3
if systemctl is-active --quiet xochitl.service; then
  say "xochitl is running stock — uninstall complete"
else
  say "WARNING: xochitl not active yet — check: systemctl status xochitl"
fi

if [ "${1:-}" = --purge ]; then
  say "purging $REDOKU_DIR"
  cd /
  rm -rf "$REDOKU_DIR"
  say "purged — no trace left"
fi
