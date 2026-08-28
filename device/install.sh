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
# server or decoy steps — they install the same way with or without a
# game build, on purpose. redoku-watcher.service's ExecStart is that same
# binary (`redoku --watch`), though, so it genuinely cannot START without
# one — fix round 2, finding 1: the unit is still written and enabled
# either way (ready for the next boot, or the next install once a build
# exists), but is only STARTED, and only then hard-verified, when the
# binary is actually present. A watcher with nothing to spawn must not
# roll back an otherwise healthy display-server install.
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
# redoku-watcher.service's ExecStart, spelled out here too (fix round 2,
# finding 1): whether this file exists on the device is what decides
# whether the watcher can be STARTED today or only enabled for later.
GAME_BIN=$REDOKU_DIR/bin/redoku

# Fix round 2, finding 2: how long wait_for_active (below) will wait for a
# unit to settle before giving up, per service. Named so every call site
# says the same number for the same reason, not a fresh guess each time.
# 60s, not 15: the exact line the owner's one real install run died at was
# a single `systemctl is-active` sample 15s after a restart, and their own
# device journal shows xochitl can take multi-second network timeouts
# during a normal startup — indistinguishable, at one sample, from a unit
# that is never coming back.
WAIT_BUDGET=60

# Fix round 3, item 1: how many consecutive active samples the FINAL
# settle checks (after xochitl's own restart) require, a second apart —
# see wait_for_active's own comment on why one sample is not enough. Not
# used by the early, right-after-its-own-restart checks (those pass 1):
# this is specifically for proving a service is still up seconds after
# xochitl's restart, not merely that it came up in the first place.
SETTLE_SAMPLES=3

FORCE=0
[ "${1:-}" = --force ] && FORCE=1

say() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Fix round 2, finding 2: `systemctl is-active --quiet` is one sample —
# it returns non-zero for "activating" and for the "auto-restart" substate
# (a Restart=on-failure unit sitting in its RestartSec backoff between a
# crash and its next retry) exactly the same as for a unit that is
# permanently gone, so a single sample partway through a restart cannot
# tell "still coming up" apart from "never coming back". wait_for_active
# polls once a second up to a budget instead: ActiveState=failed is a real
# terminal failure worth reporting immediately (no reason to burn the rest
# of the budget on a unit that has already given up); anything else that
# isn't active — activating, the auto-restart substate, reloading,
# deactivating — is "keep waiting". Logs what it last saw whichever way it
# ends, so a real failure is diagnosable instead of guessed at.
#
# <required_consecutive> (fix round 3, item 1): `systemctl restart`
# already returns only once its own start job completes, at which point
# ActiveState is already "active" — a caller that accepts the FIRST active
# sample proves nothing "restart"'s own exit status didn't already say.
# That is the exact shape of the owner's real failure: the device journal
# shows xochitl started cleanly and then failed a DNS/HTTP call 8s later —
# work that happens AFTER the start job, not during it. Passing >1 here
# requires that many consecutive active samples, a second apart, with
# NRestarts unchanged between them (a bump mid-streak means it crashed and
# came back on its own — not "up and staying up" — so the streak restarts
# rather than counting through it). Early callers that only need "did it
# come up at all" (right after their own restart, with nothing yet
# depending on it) pass 1; the final settle checks, after xochitl's own
# restart, pass more.
wait_for_active() { # wait_for_active <unit> <budget_seconds> <required_consecutive>
  _unit=$1
  _budget=$2
  _required=$3
  _waited=0
  _streak=0
  _last_nrestarts=
  while :; do
    _show=$(systemctl show -p ActiveState -p SubState -p NRestarts "$_unit" 2>/dev/null)
    _state=$(printf '%s\n' "$_show" | sed -n 's/^ActiveState=//p')
    _sub=$(printf '%s\n' "$_show" | sed -n 's/^SubState=//p')
    _nrestarts=$(printf '%s\n' "$_show" | sed -n 's/^NRestarts=//p')
    if [ "$_state" = failed ]; then
      printf 'ERROR: %s failed (ActiveState=%s SubState=%s NRestarts=%s)\n' \
        "$_unit" "$_state" "$_sub" "$_nrestarts" >&2
      return 1
    fi
    if [ "$_state" = active ]; then
      if [ "$_streak" -gt 0 ] && [ "$_nrestarts" != "$_last_nrestarts" ]; then
        _streak=0 # restarted mid-streak: that streak belonged to a process that isn't the one running now
      fi
      _streak=$((_streak + 1))
      _last_nrestarts=$_nrestarts
      [ "$_streak" -ge "$_required" ] && return 0
    else
      _streak=0
    fi
    [ "$_waited" -lt "$_budget" ] || break
    sleep 1
    _waited=$((_waited + 1))
  done
  printf 'ERROR: %s did not stay active within %ss (ActiveState=%s SubState=%s NRestarts=%s, streak=%s/%s)\n' \
    "$_unit" "$_budget" "$_state" "$_sub" "$_nrestarts" "$_streak" "$_required" >&2
  return 1
}

# Fix round 1, Critical 2: a `case … "$XOCHITL_DIR"/*.pdf)` glob is not a
# validator — `*` also matches the EMPTY string (pdf=$XOCHITL_DIR/.pdf
# derives an empty uuid) and matches `..`/`/` (a pdf= line escaping the
# directory entirely), and either one reaching `rm -rf "$XOCHITL_DIR/$
# DECOY_UUID"` below is `rm -rf` on $XOCHITL_DIR itself or worse — a
# reviewer demonstrated exactly that against the previous version of this
# script. A uuid is 8-4-4-4-12 lowercase-or-uppercase hex (mkdecoy.rb's
# own UUID_RE); `case` glob character classes need no external tool
# (grep -E/expr are not guaranteed present in every BusyBox build) and,
# unlike a partial regex match, a shell `case` pattern must match the
# WHOLE string — too short, too long, or the wrong characters all fail
# closed. Called before ANY path is built from a watch.conf-derived uuid.
looks_like_uuid() {
  case $1 in
    [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])
      return 0 ;;
    *)
      return 1 ;;
  esac
}

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
# head -n 1: fix round 2, item 6 — a watch.conf with two 'pdf=' lines
# (corrupt, or hand-edited) would otherwise make DECOY_PDF hold both,
# joined by an embedded newline, which the glob below can still match
# (glob `*` matches newlines) while every later use of the value breaks
# in stranger ways than a clean refusal would. First line wins, always.
DECOY_PDF=$(sed -n 's/^pdf=//p' "$WATCH_CONF" | head -n 1)
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
looks_like_uuid "$DECOY_UUID" || \
  die "$WATCH_CONF's pdf= path ($DECOY_PDF) doesn't have a uuid-shaped basename (got '$DECOY_UUID') — refusing to build a path from it"

# PLAN.md's M4 backup mandate, cheapest resolution: the installer only
# ever ADDS a document (R9's fixed uuid means a re-run's cp is safe — see
# the header — but a real document colliding with our fixed uuid, however
# astronomically unlikely per mkdecoy.rb's own DEFAULT_UUID comment, would
# otherwise get silently overwritten and later rm -rf'd by rollback/
# uninstall). If something is already at this path, it must be OUR decoy
# — verified the cheap way, by content, not by trusting the uuid alone.
if [ -f "$XOCHITL_DIR/$DECOY_UUID.metadata" ] && \
   ! grep -q '"visibleName": "Sudoku"' "$XOCHITL_DIR/$DECOY_UUID.metadata"; then
  die "$XOCHITL_DIR/$DECOY_UUID.metadata exists and is not the reDoku decoy \
(no Sudoku visibleName) — refusing to overwrite what looks like a real \
document; this uuid collision should be essentially impossible, so \
investigate by hand before doing anything else"
fi

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
  # DECOY_UUID is always set (and shape-checked by looks_like_uuid) by
  # here — derived from $WATCH_CONF during preflight, which runs to
  # completion before this trap is even armed (below). "Back to stock"
  # means no trace of the decoy either, so this is unconditional, exactly
  # like the rm2fb/dropin removal above — including on a re-run of an
  # install that had already succeeded once. .thumbnails/ included: if
  # xochitl got far enough to thumbnail the decoy before this attempt
  # failed, nothing else will ever collect it (uninstall.sh's reasoning
  # for the same removal applies identically here).
  rm -f "$XOCHITL_DIR/$DECOY_UUID.pdf" "$XOCHITL_DIR/$DECOY_UUID.metadata" \
        "$XOCHITL_DIR/$DECOY_UUID.content" "$XOCHITL_DIR/$DECOY_UUID.pagedata"
  # shellcheck disable=SC2115  # "use ${var:?} so this can't expand to /" —
  # the guarantee it asks for is already there, one line after DECOY_UUID is
  # derived: looks_like_uuid above rejects empty, '..', '/', too-short and
  # too-long, and preflight dies on the spot if it does. See the paragraph
  # just above for why no path reaches this line without that check having
  # passed. Adding ${DECOY_UUID:?} here would be a second, weaker test of
  # the same thing, and would read as if the real guard were not trusted.
  rm -rf "$XOCHITL_DIR/$DECOY_UUID" "$XOCHITL_DIR/$DECOY_UUID.thumbnails"
  systemctl daemon-reload
  # Leaves the device's failure-counter state clean, not just stopped —
  # symmetric with the reset-failed added before the watcher's own start
  # above (Important 3): a rollback is exactly the situation that leaves
  # a stale counter behind for the next attempt to trip over.
  systemctl reset-failed redoku-watcher.service 2>/dev/null || true
  systemctl reset-failed xochitl.service 2>/dev/null || true
  # NEVER `stop` xochitl.service here or anywhere in this script — an
  # on-device test this round found that stopping it over this same
  # SSH-over-USB session kills the session itself (port 22 refuses
  # instantly), taking the rest of the script down with it and leaving
  # xochitl stopped until a power cycle. `restart` is what has always
  # been here and is what must stay.
  systemctl restart xochitl.service || true
  sleep 3

  # Fix round 1, finding 1 (corrected in fix round 2, finding 4): the
  # same resurrection risk uninstall.sh's decoy removal carries (see its
  # comment for the on-device evidence and the corrected reasoning) — a
  # `systemctl restart` is a stop job THEN a start job, so if xochitl was
  # alive with the decoy in its in-memory model at the moment of the rm
  # above, its shutdown flush completes BEFORE the new process starts and
  # scans the library — the fresh process can adopt exactly what its
  # predecessor just wrote back. One restart cannot outrun that sequence;
  # a second one, after the resurrected files are gone again, is what
  # finally gives a process nothing left to adopt. Best-effort throughout:
  # rollback must not itself fail, so nothing here is allowed to die.
  _resurrected=0
  for _f in "$XOCHITL_DIR/$DECOY_UUID.pdf" "$XOCHITL_DIR/$DECOY_UUID.metadata" \
            "$XOCHITL_DIR/$DECOY_UUID.content" "$XOCHITL_DIR/$DECOY_UUID.pagedata" \
            "$XOCHITL_DIR/$DECOY_UUID" "$XOCHITL_DIR/$DECOY_UUID.thumbnails"; do
    [ -e "$_f" ] || continue
    _resurrected=1
    rm -rf "$_f" 2>/dev/null || true
  done
  if [ "$_resurrected" = 1 ]; then
    systemctl restart xochitl.service || true
    sleep 3
    for _f in "$XOCHITL_DIR/$DECOY_UUID.pdf" "$XOCHITL_DIR/$DECOY_UUID.metadata" \
              "$XOCHITL_DIR/$DECOY_UUID.content" "$XOCHITL_DIR/$DECOY_UUID.pagedata" \
              "$XOCHITL_DIR/$DECOY_UUID" "$XOCHITL_DIR/$DECOY_UUID.thumbnails"; do
      [ -e "$_f" ] || continue
      rm -rf "$_f" 2>/dev/null || true
    done
  fi

  # Fix round 3, item 3: "rollback done" used to print unconditionally —
  # uninstall.sh warns when its own equivalent removal can't be confirmed
  # clean; rollback() didn't. An operator reading "rollback done" over a
  # decoy that is still there has been told something false at exactly
  # the moment they most need the truth.
  _still_present=0
  for _f in "$XOCHITL_DIR/$DECOY_UUID.pdf" "$XOCHITL_DIR/$DECOY_UUID.metadata" \
            "$XOCHITL_DIR/$DECOY_UUID.content" "$XOCHITL_DIR/$DECOY_UUID.pagedata" \
            "$XOCHITL_DIR/$DECOY_UUID" "$XOCHITL_DIR/$DECOY_UUID.thumbnails"; do
    [ -e "$_f" ] && _still_present=1
  done
  if [ "$_still_present" = 1 ]; then
    say "WARNING: rollback could not fully remove the decoy — some of $XOCHITL_DIR/$DECOY_UUID.* remain; check by hand (systemctl status xochitl)"
  else
    say "rollback done — check with: systemctl status xochitl"
  fi
}
STATUS=fail
FINISHED=0
# Fix round 3, item 5: `trap ... EXIT` alone is not enough — dash/ash do
# NOT run an EXIT trap on an untrapped fatal signal, only on a normal
# script exit. Combined with the up-to-$WAIT_BUDGET-second silent waits
# below (now announced, but still long), an operator who Ctrl-Cs what
# looks like a hang would get no rollback at all: SIGINT would just kill
# the script outright, mid-install, decoy and half-started services left
# exactly where they stood. INT/TERM/HUP all now run the same path.
# FINISHED guards against running it twice: the handler below calls exit
# explicitly (needed — without it, dash resumes the script after the trap
# instead of stopping it), and `exit` itself fires the EXIT trap too.
finish() {
  [ "$FINISHED" = 1 ] && return
  FINISHED=1
  [ "$STATUS" = ok ] || rollback
}
trap finish EXIT
trap 'finish; exit 1' INT TERM HUP

say "writing $UNIT"
cat > "$UNIT" <<EOF
# Installed by reDoku's device/install.sh — remove with uninstall.sh.
[Unit]
Description=reDoku rm2fb display server (swtcon mode)
Before=xochitl.service
StartLimitIntervalSec=600
StartLimitBurst=4
# $REDOKU_DIR lives on its own partition (/dev/mmcblk2p4, confirmed on the
# owner's device) that is not guaranteed mounted yet when systemd runs this
# unit's ExecStart for the first time at boot. Measured, not theoretical:
# every boot in .superpowers/sdd/M4-HIJACK/device-watcher-journal.txt
# failed the watcher's first start 203/EXEC for exactly this reason, and
# ExecStart below sits on the same partition.
#
# Untreated, this one fails SILENTLY rather than loudly, which is why it
# outranks the watcher's copy: Before=xochitl.service is an ordering, and a
# FAILED start satisfies an ordering just as well as a successful one. So
# rm2fb dies 203/EXEC, xochitl starts immediately with no preload.env to
# read (EnvironmentFile below is optional by design) and therefore no
# shim, and RestartSec=5 then brings the server up to take the panel out
# from under an already-running unshimmed xochitl. That is the frozen
# splash the owner hit twice with every unit reporting healthy — and in
# the same journal, boot 5d13c195 logs the watcher's 203/EXEC and "Started
# reMarkable main application" in the same second.
#
# RequiresMountsFor orders this unit after (and requires) whatever mount
# unit covers the path, so the first start is a real one. If that mount
# never arrives, rm2fb does not start at all and xochitl comes up
# completely stock — the same tolerated fallback as a broken server, not a
# new way to lose the tablet.
#
# NOT closed by this: rm2fb failing its first boot start for some reason
# OTHER than the mount reopens the identical window (see PLAN.md §11).
RequiresMountsFor=$REDOKU_DIR

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

say "installing the decoy document into $XOCHITL_DIR"
# Before either service starts, on purpose (fix round 1, Critical 1;
# corrected in fix round 2, finding 5 — the reason below used to be
# wrong). The right reason: a service must not be started before the
# thing it exists to watch, independent of whether missing it is fatal —
# and it is not. watcher.rb's Watcher#start never raises for a missing
# pdf= target ("Requirement D: never raises... a watcher that exits at
# boot because a mount lost a race is a launcher that only works after a
# manual restart, and that defeats the entire point of this milestone" —
# watcher.rb's own comment on #start); a missing target just makes
# reconcile! fail quietly and retry every REARM_RETRY_MS (5s) until the
# file shows up — exactly what the device journal measured (91s alive
# with the pdf target absent, no crash, M4-HIJACK device-watcher-
# journal.txt). Starting the watcher first still costs something real,
# though: every REARM_RETRY_MS window before the file exists is a window
# the watcher cannot see a tap in at all, since the watch was never
# armed — silent, no crash, but still a gap this hijack cannot afford at
# the one moment (right after install) a tap is most likely.
#
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
# xochitl's own <uuid>.thumbnails/ cache is left alone entirely by this
# script, on either an install or a re-run — uninstall.sh is what reaps
# it, once the document is gone from under xochitl for good.
mkdir -p "$XOCHITL_DIR/$DECOY_UUID"

say "enabling + starting rm2fb.service"
systemctl enable rm2fb.service
systemctl restart rm2fb.service || die "rm2fb.service failed to (re)start — its own output above says why"

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
# Announced (fix round 3, item 5): up to $WAIT_BUDGET seconds of otherwise
# total silence reads as a hang to whoever is watching the SSH session.
say "waiting for rm2fb.service to report active (up to ${WAIT_BUDGET}s)..."
wait_for_active rm2fb.service "$WAIT_BUDGET" 1 || die "rm2fb.service is not active"

say "enabling redoku-watcher.service"
# reset-failed first (fix round 1, Important 3): systemd's start-limit
# counter survives stop/disable and clears only via reset-failed or the
# 600s StartLimitIntervalSec window expiring on its own. Without this, a
# watcher that burned its StartLimitBurst on an earlier failed attempt
# fails every retry inside that window with "start request repeated too
# quickly" — a die below, and a rollback, whose real cause is a stale
# counter and has nothing to do with whatever this attempt actually did.
systemctl reset-failed redoku-watcher.service 2>/dev/null || true
systemctl enable redoku-watcher.service

# Fix round 2, finding 1: redoku-watcher.service's ExecStart is
# $GAME_BIN itself ("redoku --watch") — the header's old claim that the
# decoy/watcher install "the same way with or without a game build" was
# never true for the watcher specifically, and starting a unit whose
# binary does not exist is 203/EXEC, not a graceful no-op. Enabling it
# regardless means it starts on its own at the next boot, or the next
# time this script runs after a build exists; STARTING (and therefore
# hard-verifying) it only happens when there is something to start.
#
# Fix round 3, item 2: that only covered the missing-binary cause. Any
# OTHER reason the watcher fails to start (a bad unit, a systemd hiccup,
# anything) used to reach an unguarded `systemctl restart` and then
# `wait_for_active`'s own die — both of which, being ordinary command
# failures under `set -eu`, would roll back the whole install, decoy and
# a working display server included, over a launcher that failed for a
# reason that has nothing to do with either. The display server and
# xochitl are what make the tablet usable; the launcher is a convenience
# that can be retried — a watcher fault of ANY cause is now loud and
# non-fatal: it's reported, left enabled for a later start (a reboot, or
# a re-run of this script), and the install finishes around it.
if [ -x "$GAME_BIN" ]; then
  say "starting redoku-watcher.service"
  say "waiting for redoku-watcher.service to report active (up to ${WAIT_BUDGET}s)..."
  if systemctl restart redoku-watcher.service && wait_for_active redoku-watcher.service "$WAIT_BUDGET" 1; then
    WATCHER_STARTED=1
  else
    say "  WARNING: redoku-watcher.service failed to start — leaving it enabled for the next boot; the display server and the rest of the install are unaffected (systemctl status redoku-watcher for why)"
    WATCHER_STARTED=0
  fi
else
  say "no game binary at $GAME_BIN yet — redoku-watcher.service is enabled for the next boot (or the next 'bin/redoku install' once 'make build' has produced one), not started now"
  WATCHER_STARTED=0
fi

say "restarting xochitl with the rm2fb client preloaded — this also indexes the decoy"
# NEVER `stop` xochitl.service here or anywhere in this script — an
# on-device test this round found that stopping it over this same
# SSH-over-USB session kills the session itself (port 22 refuses
# instantly), taking the rest of the script down with it and leaving
# xochitl stopped until a power cycle. `restart` is what has always been
# here and is what must stay.
systemctl restart xochitl.service || die "xochitl failed to restart — its own output above says why"

say "verifying (15 s settle, then requiring $SETTLE_SAMPLES consecutive active samples per service)"
# Fix round 3, item 1: fix round 2 deleted the old `sleep 15` and did not
# replace what it bought. `systemctl restart` already returns only once
# its start job completes — at which point ActiveState is already
# "active" — so a caller that accepts the very first sample proves
# nothing `restart`'s own exit status didn't already say, and the
# "verifying" block became silent instead of over-eager. That is the
# exact shape of the owner's real failure: the device journal shows
# xochitl started cleanly ("Started reMarkable main application") and
# then failed a DNS/HTTP call 8s later — work that happens AFTER the
# start job, not during it. The settle below gives that window a chance
# to happen before sampling even begins; SETTLE_SAMPLES consecutive
# active reads from wait_for_active (NRestarts required unchanged
# between them) extends the same proof a few seconds further. Over-eager
# was fix round 2's bug; silent would have been this round's — a check
# that returns the instant "active" first reads true tells you nothing
# more than `restart`'s own exit status did.
sleep 15
say "waiting for rm2fb.service to stay active (up to ${WAIT_BUDGET}s)..."
wait_for_active rm2fb.service "$WAIT_BUDGET" "$SETTLE_SAMPLES" || die "rm2fb.service did not stay active after the xochitl restart"
if [ "$WATCHER_STARTED" = 1 ]; then
  # Non-fatal here too (fix round 3, item 2's principle applied to this
  # round's own new check, not just the line the finding named): a
  # watcher that started fine but then flapped within the settle window
  # is still just a watcher fault, and rolling back a healthy display
  # server over it would be the exact thing item 2 exists to prevent —
  # this check would have silently reintroduced it if left as `|| die`.
  say "waiting for redoku-watcher.service to stay active (up to ${WAIT_BUDGET}s)..."
  if ! wait_for_active redoku-watcher.service "$WAIT_BUDGET" "$SETTLE_SAMPLES"; then
    say "  WARNING: redoku-watcher.service did not stay active — leaving it enabled for the next boot; the display server and the rest of the install are unaffected (systemctl status redoku-watcher for why)"
    WATCHER_STARTED=0
  fi
fi
say "waiting for xochitl.service to stay active (up to ${WAIT_BUDGET}s)..."
wait_for_active xochitl.service "$WAIT_BUDGET" "$SETTLE_SAMPLES" || die "xochitl did not stay active after its restart"

STATUS=ok
say "SUCCESS — rm2fb is installed, the decoy is in the library, and xochitl is running through it"
say "  server status : systemctl status rm2fb"
if [ "$WATCHER_STARTED" = 1 ]; then
  say "  watcher status: systemctl status redoku-watcher"
else
  say "  watcher status: enabled, not started (no game binary yet) — starts on the next boot, or re-run install once one exists"
fi
say "  client socket : $SOCKET"
say "  back to stock : sh $REDOKU_DIR/uninstall.sh"
