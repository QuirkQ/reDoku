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

# Fix round 1, Critical 2: a bare `case … "$XOCHITL_DIR"/*.pdf)` glob
# doesn't validate anything — `*` also matches the EMPTY string (a
# corrupt/hand-edited pdf= like "$XOCHITL_DIR/.pdf" derives an empty
# uuid) and matches `..`/`/`, so a bad watch.conf could point this
# script's rm -rf outside the decoy entirely. Mirrors install.sh's own
# looks_like_uuid — duplicated, not sourced, same reasoning install.sh
# gives for not sharing the pdf=-parsing logic itself: two small
# independent scripts, one small function, no shared-file dependency to
# keep in sync at runtime.
looks_like_uuid() {
  case $1 in
    [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])
      return 0 ;;
    *)
      return 1 ;;
  esac
}

[ "$(id -u)" = 0 ] || { echo "ERROR: must run as root" >&2; exit 1; }

say "disarming the xochitl preload"
rm -f "$PRELOAD_ENV"

say "stopping + disabling the hijack watcher"
systemctl disable --now redoku-watcher.service 2>/dev/null || true

say "stopping + disabling rm2fb.service"
systemctl disable --now rm2fb.service 2>/dev/null || true

say "removing systemd files"
rm -f "$UNIT" "$DROPIN" "$WATCHER_UNIT"
rmdir "$DROPIN_DIR" 2>/dev/null || true

say "removing the decoy document"
# watch.conf's pdf= line is the only place the decoy's uuid is recorded
# on the device (install.sh derives it the same way, from the same
# file, rather than either script hardcoding it — see install.sh's
# header on WATCH_CONF). No watch.conf means nothing was ever installed,
# or a previous partial run already got this far; either way there is
# nothing to derive a path from, so this step is a safe no-op.
#
# Fix round 1, Important 4: watch.conf used to be removed unconditionally
# below, even in the branches that refuse to touch the decoy — deleting
# the one file that names *what* to go check by hand, right after telling
# the operator to go check it by hand. It is now removed only inside the
# branch that actually removed the decoy (deferred to just after the
# restart+verify below, alongside DECOY_REMOVED), and every refusal below
# leaves it in place so a later run can still find the decoy from it.
#
# Deliberately placed AFTER rm2fb.service is already stopped+disabled and
# its units are gone (fix round 1, finding 1 — reordered from an earlier
# draft of this fix): the removal below needs one more xochitl restart to
# settle (see the comment at that restart), and restarting xochitl while
# rm2fb.service is still active would restart it unshimmed (preload.env
# is already gone, disarmed above) racing an rm2fb that still holds the
# panel — on-device evidence this same round shows that exact combination
# leaves xochitl running but undraws nothing (a stale frame, no error).
# Stopping rm2fb.service first removes that hazard: by the time xochitl
# restarts below, there is no rm2fb left for it to race against.
DECOY_REMOVED=0
if [ -f "$WATCH_CONF" ]; then
  DECOY_PDF=$(sed -n 's/^pdf=//p' "$WATCH_CONF")
  case $DECOY_PDF in
    "$XOCHITL_DIR"/*.pdf)
      DECOY_BASE=${DECOY_PDF%.pdf}
      DECOY_UUID=${DECOY_BASE##*/}
      if looks_like_uuid "$DECOY_UUID"; then
        # This IS the <uuid>/ ink directory install.sh creates (the base
        # path with no suffix) — rm -rf, not rmdir, because it may hold
        # the player's own annotations on the decoy by now. <uuid>.
        # thumbnails/ is xochitl's own cache, never this script's to
        # create — but it IS this script's to remove: xochitl only reaps
        # a document's thumbnails when IT deletes the document, and here
        # the document vanishes out from under it instead, so nothing
        # else will ever collect this one. Six entries now, not five —
        # the sixth found by a reviewer reading uninstall.sh's own "no
        # trace left" promise against what it actually left behind.
        rm -f "$DECOY_BASE.pdf" "$DECOY_BASE.metadata" "$DECOY_BASE.content" "$DECOY_BASE.pagedata"
        rm -rf "$DECOY_BASE" "$DECOY_BASE.thumbnails"
        DECOY_REMOVED=1
      else
        say "  WARNING: $WATCH_CONF's pdf= line ($DECOY_PDF) doesn't have a uuid-shaped basename — leaving $WATCH_CONF, check by hand"
      fi
      ;;
    *)
      say "  WARNING: $WATCH_CONF's pdf= line ($DECOY_PDF) doesn't point under $XOCHITL_DIR — leaving $WATCH_CONF, check by hand"
      ;;
  esac
else
  say "  no $WATCH_CONF found — nothing to remove (never installed, or already removed)"
fi

say "reloading systemd + restarting xochitl (stock)"
systemctl daemon-reload
systemctl reset-failed xochitl.service 2>/dev/null || true
# NEVER `stop` xochitl.service here (or anywhere in this script) — an
# on-device test this round found that stopping it over this same
# SSH-over-USB session kills the session itself (port 22 refuses
# instantly), taking the rest of the script down with it and leaving
# xochitl stopped until a power cycle. `restart` is what has always been
# here and is what must stay. rm2fb.service is already stopped by this
# point (above), so this restart also has no unshimmed-vs-active-rm2fb
# race to worry about (see the decoy-removal comment).
systemctl restart xochitl.service
sleep 3

if [ "$DECOY_REMOVED" = 1 ]; then
  # Fix round 1, finding 1: if xochitl was still alive with the decoy in
  # its own in-memory model at the moment of the rm above, it can flush
  # that model back to disk on its own initiative — confirmed on-device:
  # deleting these same four files under a live xochitl recreated
  # .content and .pagedata from memory a moment later, with the library
  # row surviving. The restart just above is what forces the point: once
  # its new process has started, it has scanned a library that no longer
  # has the decoy in it — it never loaded the document in the first
  # place, so nothing is left to resurrect from here on. Then verify — a
  # reviewer's whole point was that this script used to just assume `rm`
  # won.
  _resurrected=0
  for _f in "$DECOY_BASE.pdf" "$DECOY_BASE.metadata" "$DECOY_BASE.content" \
            "$DECOY_BASE.pagedata" "$DECOY_BASE" "$DECOY_BASE.thumbnails"; do
    [ -e "$_f" ] || continue
    _resurrected=1
    rm -rf "$_f"
  done
  if [ "$_resurrected" = 1 ]; then
    say "  WARNING: xochitl recreated some decoy files after the first removal — removed them again; the now-running xochitl never loaded the decoy, so this should be the last time"
  else
    say "  removed $DECOY_BASE.{pdf,metadata,content,pagedata,thumbnails} and its ink directory"
  fi
  rm -f "$WATCH_CONF"
fi

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
