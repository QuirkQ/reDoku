#!/bin/sh
# reDoku uninstaller — run ON the reMarkable 2, as root.
#
# Returns the device to stock: stops and removes the rm2fb display
# server, the M4 hijack watcher, and the decoy "Sudoku" document it
# watches — the decoy must not outlive the watcher, or the library keeps
# a document that silently does nothing (M4-HIJACK.md). Idempotent: safe
# to run repeatedly and on partial installs (it removes whatever it
# finds, step by step). Like preload.env and the systemd files, the
# watcher/decoy removal below is unconditional, not gated by --purge —
# --purge only decides the fate of $REDOKU_DIR itself.
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
WATCHER_UNIT=/etc/systemd/system/redoku-watcher.service
WATCH_CONF=$REDOKU_DIR/watch.conf
XOCHITL_DIR=/home/root/.local/share/remarkable/xochitl

say() { printf '==> %s\n' "$*"; }

[ "$(id -u)" = 0 ] || { echo "ERROR: must run as root" >&2; exit 1; }

say "disarming the xochitl preload"
rm -f "$PRELOAD_ENV"

say "stopping + disabling the hijack watcher"
systemctl disable --now redoku-watcher.service 2>/dev/null || true

say "removing the decoy document"
# watch.conf's pdf= line is the only place the decoy's uuid is recorded
# on the device (install.sh derives it the same way, from the same
# file, rather than either script hardcoding it — see install.sh's
# header on WATCH_CONF). No watch.conf means nothing was ever installed,
# or a previous partial run already got this far; either way there is
# nothing to derive a path from, so this step is a safe no-op.
if [ -f "$WATCH_CONF" ]; then
  DECOY_PDF=$(sed -n 's/^pdf=//p' "$WATCH_CONF")
  case $DECOY_PDF in
    "$XOCHITL_DIR"/*.pdf)
      DECOY_BASE=${DECOY_PDF%.pdf}
      rm -f "$DECOY_BASE.pdf" "$DECOY_BASE.metadata" "$DECOY_BASE.content" "$DECOY_BASE.pagedata"
      # This IS the <uuid>/ ink directory install.sh creates (the base
      # path with no suffix) — rm -rf, not rmdir, because it may hold
      # the player's own annotations on the decoy by now. xochitl's own
      # <uuid>.thumbnails/ cache is deliberately left: this script never
      # created it, so it isn't this script's to remove either.
      rm -rf "$DECOY_BASE"
      say "  removed $DECOY_BASE.{pdf,metadata,content,pagedata} and its ink directory"
      ;;
    *)
      say "  WARNING: $WATCH_CONF's pdf= line doesn't point under $XOCHITL_DIR — leaving it, check by hand"
      ;;
  esac
else
  say "  no $WATCH_CONF found — nothing to remove (never installed, or already removed)"
fi
rm -f "$WATCH_CONF"

say "stopping + disabling rm2fb.service"
systemctl disable --now rm2fb.service 2>/dev/null || true

say "removing systemd files"
rm -f "$UNIT" "$DROPIN" "$WATCHER_UNIT"
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
