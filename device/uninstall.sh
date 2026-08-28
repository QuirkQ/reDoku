#!/bin/sh
# reDoku uninstaller — run ON the reMarkable 2, as root.
#
# Returns the device to stock: stops and removes the rm2fb display
# server, the M4 hijack watcher, and the decoy "Sudoku" document it
# watches — the decoy must not outlive the watcher, or the library keeps
# a document that silently does nothing (docs/plans/2026-08-27-m4-hijack.md).
# Idempotent: safe to run repeatedly and on partial installs (it removes
# whatever it finds, step by step). Like preload.env and the systemd files,
# the watcher/decoy removal below is unconditional, not gated by --purge —
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
  # head -n 1: fix round 2, item 6 — a watch.conf with two 'pdf=' lines
  # (corrupt, or hand-edited) would otherwise make DECOY_PDF hold both,
  # joined by an embedded newline; first line wins, always (matches the
  # same fix in install.sh).
  DECOY_PDF=$(sed -n 's/^pdf=//p' "$WATCH_CONF" | head -n 1)
  case $DECOY_PDF in
    "$XOCHITL_DIR"/*.pdf)
      DECOY_BASE=${DECOY_PDF%.pdf}
      DECOY_UUID=${DECOY_BASE##*/}
      if looks_like_uuid "$DECOY_UUID"; then
        # Recomposed from $XOCHITL_DIR (a fixed constant) + the
        # just-validated $DECOY_UUID, never from $DECOY_BASE directly —
        # fix round 2, item 6: a traversal payload whose *basename*
        # happens to be uuid-shaped (pdf=$XOCHITL_DIR/../../../../etc/
        # <uuid>.pdf) would still pass looks_like_uuid on that basename
        # while $DECOY_BASE itself points at /etc/<uuid> — rm -rf on
        # $DECOY_BASE would then escape $XOCHITL_DIR entirely.
        # install.sh's own decoy-copy step already builds these same six
        # paths this way; this is the same recomposition on the removal
        # side, closing the same class of bug Critical 2 closed for the
        # uuid itself.
        DECOY_TARGET=$XOCHITL_DIR/$DECOY_UUID

        # This IS the <uuid>/ ink directory install.sh creates (the base
        # path with no suffix) — rm -rf, not rmdir, because it may hold
        # the player's own annotations on the decoy by now. <uuid>.
        # thumbnails/ is xochitl's own cache, never this script's to
        # create — but it IS this script's to remove: xochitl only reaps
        # a document's thumbnails when IT deletes the document, and here
        # the document vanishes out from under it instead, so nothing
        # else will ever collect this one. Six entries, not five — the
        # sixth found by a reviewer reading uninstall.sh's own "no trace
        # left" promise against what it actually left behind.
        rm -f "$DECOY_TARGET.pdf" "$DECOY_TARGET.metadata" "$DECOY_TARGET.content" "$DECOY_TARGET.pagedata"
        rm -rf "$DECOY_TARGET" "$DECOY_TARGET.thumbnails"

        # Fix round 2, finding 3: check that the FIRST removal actually
        # worked before doing anything xochitl-related. A failed rm
        # (permissions, a read-only filesystem) must not be mistaken for
        # something xochitl needs blaming for, and must not cost the
        # operator the only record of the uuid — watch.conf, removed
        # further down only when DECOY_REMOVED ends up 1.
        _still_present=0
        for _f in "$DECOY_TARGET.pdf" "$DECOY_TARGET.metadata" "$DECOY_TARGET.content" \
                  "$DECOY_TARGET.pagedata" "$DECOY_TARGET" "$DECOY_TARGET.thumbnails"; do
          [ -e "$_f" ] && _still_present=1
        done

        if [ "$_still_present" = 1 ]; then
          say "  WARNING: removal failed — some decoy files are still on disk after rm (permissions? read-only filesystem?); leaving $WATCH_CONF so the uuid record survives to retry"
        else
          # Fix round 2, findings 4/5: `systemctl restart` is a stop job
          # THEN a start job — the dying xochitl's own shutdown flush
          # completes BEFORE the new process starts, so if it was
          # holding the decoy in memory at the moment of the rm above,
          # the flush recreates the files and the FRESH process then
          # scans the library and ADOPTS what its predecessor just wrote
          # back (fix round 1's "the now-running xochitl never loaded
          # the decoy" had this backwards). One restart cannot outrun
          # that sequence; a second one, after the resurrected files are
          # gone again, is what finally gives a process nothing left to
          # adopt. Restart-only per the standing constraint — see the
          # "NEVER stop" comment below.
          systemctl restart xochitl.service
          sleep 3
          _resurrected=0
          for _f in "$DECOY_TARGET.pdf" "$DECOY_TARGET.metadata" "$DECOY_TARGET.content" \
                    "$DECOY_TARGET.pagedata" "$DECOY_TARGET" "$DECOY_TARGET.thumbnails"; do
            [ -e "$_f" ] || continue
            _resurrected=1
            rm -rf "$_f"
          done
          if [ "$_resurrected" = 1 ]; then
            say "  xochitl recreated some decoy files from its in-memory model — removed them again and restarting once more so the next process has nothing left to adopt"
            systemctl restart xochitl.service
            sleep 3
          fi

          _still_present=0
          for _f in "$DECOY_TARGET.pdf" "$DECOY_TARGET.metadata" "$DECOY_TARGET.content" \
                    "$DECOY_TARGET.pagedata" "$DECOY_TARGET" "$DECOY_TARGET.thumbnails"; do
            [ -e "$_f" ] && _still_present=1
          done
          if [ "$_still_present" = 1 ]; then
            say "  WARNING: decoy files reappeared a second time after removal — leaving $WATCH_CONF; investigate by hand (systemctl status xochitl) rather than re-running blindly"
          else
            say "  removed $DECOY_TARGET.{pdf,metadata,content,pagedata,thumbnails} and its ink directory"
            DECOY_REMOVED=1
          fi
        fi
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

# Fix round 2, finding 3: gated on DECOY_REMOVED as it stands AFTER the
# full removal-verify(-retry) sequence above, not right after the first
# rm — a failed removal, or one still unresolved after the resurrection
# retry, must keep watch.conf so the uuid record survives to try again.
if [ "$DECOY_REMOVED" = 1 ]; then
  rm -f "$WATCH_CONF"
fi

# Fix round 3, item 4: the restart just above is ITSELF a stop-then-start
# cycle — the same mechanism the removal sequence above exists to survive
# is not structurally ruled out on this restart too, and by the time
# anyone would notice, watch.conf is already gone (DECOY_REMOVED gated
# its removal, but not on this restart surviving). Cheap to guard:
if [ "$DECOY_REMOVED" = 1 ]; then
  for _f in "$DECOY_TARGET.pdf" "$DECOY_TARGET.metadata" "$DECOY_TARGET.content" \
            "$DECOY_TARGET.pagedata" "$DECOY_TARGET" "$DECOY_TARGET.thumbnails"; do
    [ -e "$_f" ] || continue
    rm -rf "$_f"
  done
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
