# M4 — the hijack: launch reDoku by tapping a document

**Date:** 2026-08-26
**Status: shipped 2026-08-27, host-complete and partially device-verified**
(commits `7ae3a28`..`43b1633`; ledger `.superpowers/sdd/M4-HIJACK/progress.md`,
git-ignored and deleted with the workspace — the facts worth keeping from it
are folded into this document, [PLAN.md §10/§11](PLAN.md) and
[`docs/design/m4-decoy-format.md`](docs/design/m4-decoy-format.md)). Tasks 1–4
below are done, reviewed and on `main`; Task 5's device checklist is only
partly discharged — see its section for exactly which checks were witnessed
and which were not. Two of this plan's own guesses turned out wrong once the
device was reachable — see the annotations on Task 1 and Task 2 below, kept
rather than silently corrected.
**Supersedes:** the M4 sketch in [PLAN.md §10](PLAN.md) (this document expands
it into tasks; PLAN.md stays the design record).

---

## Goal

The launch UX stops needing SSH. A document named **Sudoku.pdf** sits in the
stock library like any other notebook. Tapping it opens — and the sudoku board
takes the screen. Quitting hands the panel straight back to xochitl, no
restart, no black flash of stock UI in between.

## Why the game cannot be compiled into the PDF

The original ask was "compile the game and installer into a PDF so we can
perform the hijack." That is not how the device works, and no amount of
packaging changes it:

- xochitl renders PDFs with a viewer; it **never executes content from them**.
  There is no macro, attachment-exec, or launcher facility in the stock
  firmware to hang a payload on.
- Anything that runs must be an executable already on the root filesystem.
  We have exactly that: `/home/root/redoku/bin/redoku`, installed by
  `bin/redoku install` (M1–M3 machinery, unchanged).
- What a PDF *can* be is the **trigger**: opening a file is a filesystem event
  (`IN_OPEN` on the `.pdf`), and a tiny resident watcher can act on it.

So M4 ships three pieces, none of which live inside the PDF:

1. **The decoy document** — a real, openable Sudoku PDF plus the xochitl
   metadata that makes it appear in the library (`tools/mkdecoy.rb`).
2. **The watcher** — `redoku --watch`, a systemd service holding only an
   inotify watch and the control socket. It spawns the game when the decoy is
   opened.
3. **Install/uninstall wiring** — the decoy and the watcher unit go in and out
   with the rest of the install.

## Architecture

```
xochitl library ── tap "Sudoku"
      │
      ▼ opens /home/root/.local/share/remarkable/xochitl/<uuid>.pdf
      │   (IN_OPEN)
redoku --watch  ── redoku-watcher.service (systemd, always resident)
      │   inotify watch · 5 s debounce · GetClients check
      ▼ spawns /home/root/redoku/bin/redoku
game Init ──▶ rm2fb_server_swtcon takes the screen automatically (§3)
      │
   play … Quit
      ▼
game closes its display socket and exits
server promotes the next client ──▶ xochitl (never an explicit switch_to)
```

Design decisions inherited from PLAN.md, restated because they are load-bearing:

- **No `switch_to` on quit.** The server SIGSTOPs the whole process group of
  the client it demotes; a live client that switches away from itself would
  freeze inside the call and never reach its exit path. Closing our display
  connection cleanly is the entire handback.
- **Watcher stays out of the draw path.** `--watch` holds an inotify fd and,
  when checking state, control-socket datagrams only. It never connects to
  `/var/run/rm2fb.sock` as a framebuffer client, so it can never steal the
  screen by accident.
- **One binary, three modes** (§5): `redoku` (game), `redoku --watch`
  (watcher), `redoku --record` (M3b). No second daemon to ship.

## Prerequisites

- **`RM2::Inotify`** was deferred from M1 ("only the hijack watcher needs it")
  and lands here: `RM2::Inotify.watch(path, mask)` /
  `#read_events` in the C shim gem, host-testable against a real inotify fd.
- M3b is not a hard blocker (the watcher launches whatever `redoku` does
  today), but M4 verification reads best after CHECK exists — decide at
  kickoff whether to sequence M4 before or after M3b.

## Tasks

### Task 1 — `RM2::Inotify` in the C shim

- `Inotify.init` → fd; `watch(path, mask)`; `read_events` returning decoded
  `struct inotify_event`s as Ruby arrays `[wd, mask, cookie, name]`.
- Host tests: real tmpdir watches — create, open, write, close — asserting the
  decoded events. No fake needed; Linux inotify works under macOS Docker fine
  (the container is Linux).
- Empirically verify on-device which event actually fires when xochitl opens a
  document: primary signal is `IN_OPEN` on the decoy's `<uuid>.pdf`; fallback
  is watching `<uuid>.metadata` for `lastOpened` writes (`IN_CLOSE_WRITE`) if
  `IN_OPEN` proves noisy or cached-away on 3.27. This check gates Task 3.

> **SUPERSEDED 2026-08-27 — the last sentence is wrong, kept as written**
> because the reasoning that replaced it is worth reading against it. The
> device was unreachable when Task 1 ran (checked at kickoff), so this could
> not gate Task 3 as written; the controller's ruling instead was to ship
> **both** triggers, watched simultaneously off one debounce, and treat the
> pick as a tuning observation rather than a code fork. The device came
> online mid-run, but the empirical answer still did not come from Task 1 —
> it came from three later device episodes, spanning Tasks 3 and 4's fix
> rounds. What was actually measured: `IN_OPEN` fires at the instant of a
> tap, every time, but *also* fires with no tap at all on every boot
> (xochitl re-reads the decoy while restoring its last-open document), and
> gating on `.metadata`'s `lastOpened` instead trades that false trigger for
> 13–54 s of latency, because xochitl records it at open time but flushes
> the sidecar to disk lazily. `trigger=open` shipped as the default with a
> 10 s startup grace and a suppress+cooldown that close the boot-phantom and
> post-quit-relaunch hazards structurally; `trigger=lastopened` stays
> selectable. Full evidence: PLAN.md §10, `docs/design/m4-decoy-format.md`,
> and `watch_config.rb`'s `DEFAULT_TRIGGER` comment.

### Task 2 — `tools/mkdecoy.rb` (host-side, CRuby)

- Generates a genuine single-page Sudoku PDF (a printed puzzle — it should
  look plausible if someone actually views it) plus the xochitl side files:
  - `<uuid>.pdf` — the document itself
  - `<uuid>.metadata` — `visibleName: "Sudoku"`, etc., in xochitl's line-based
    format
  - `<uuid>.content` — the fileType/document metadata stub

> **SUPERSEDED 2026-08-27 — "trio" and "line-based format" are both wrong,
> kept as written.** A PDF document on 3.27.3.0 is **five** filesystem
> entries (`.pdf`, `.metadata`, `.content`, `.pagedata`, and an empty
> `<uuid>/` ink directory — a sixth, `<uuid>.thumbnails/`, is xochitl's own
> to create on first open), and `.metadata`/`.content` are **JSON**, not a
> line-based grammar. The guess was replaced with a measurement: a real
> document's sidecars were dumped off the owner's device once it was
> reachable, and `tools/mkdecoy.rb` was rewritten against that dump rather
> than this description. The full corrected field set, the JSON grammar's
> exact rules, and why an earlier summary of the same dump got the array
> formatting wrong are in
> [`docs/design/m4-decoy-format.md`](docs/design/m4-decoy-format.md).
- UUID generated once and recorded (in the unit file's env or a small config
  the watcher reads) so the watcher knows which file to watch without
  scanning the whole directory.
- Verify against the real 3.27 on-device formats by dumping an existing
  document trio first — do not guess the metadata grammar.
- Released kits ship the decoy trio prebuilt — `tools/mkdecoy.rb` stays the
  single source of truth and CI still runs it once per release; a kit install
  carries its output, not the tool, which is what lets a kit install skip
  ruby entirely.

### Task 3 — `redoku --watch`

- Resolve target paths (decoy pdf, fallback metadata) from argv/config.
- Loop: `RM2::Input.wait`-style poll over the inotify fd; on the trigger event:
  - **Debounce:** 5 s window, matching §11's re-trigger-loop rule.
  - **Already-running check:** `RM2::Control.clients`; if a client named
    `redoku` is present, skip spawning (GetClients' remaining job per §10).
  - Spawn `/home/root/redoku/bin/redoku` detached (its `Init` takes the screen
    automatically); log spawn failures to journald and keep watching.
- Ignore everything else; survive inotify queue overflow (`IN_Q_OVERFLOW`) by
  re-arming; handle SIGHUP re-read of config.

**What shipped is more than this list, because the device changed the
design twice while this task's fix rounds were running.** The debounce and
the "already a client" check above both shipped as written, but they were
not enough on hardware: a boot-time phantom launch (xochitl reads the decoy
while restoring its last-open document, with nobody touching the screen)
and a post-quit relaunch loop (xochitl returns to the still-open document,
re-reads the PDF, and the watcher fires again) both needed a different
mechanism. `mrbgems/mruby-redoku/mrblib/redoku/watcher.rb` and
`watch_config.rb` ship: a `trigger=` mode (`open`, the default, or
`lastopened`, both selectable in `watch.conf`), a 10 s startup grace, and a
suppress-while-the-game-is-running rule plus a 10 s cooldown after every
spawn. PLAN.md §10 has the full account, with the device evidence that
proves each guard closes the hazard it was built for.

### Task 4 — install/uninstall wiring

- `device/install.sh` gains: copy the decoy trio into xochitl's documents dir,
  install `redoku-watcher.service` (WantedBy the same target as the display
  server), start it. One xochitl restart indexes the new document.
- `bin/redoku` orchestrates as today: build the decoy on the Mac
  (`tools/mkdecoy.rb`), ship all files over SSH, same idempotency contract as
  the current install (re-run lands the same state, auto-rollback on failure).
- Uninstall removes the unit, kills the watcher, deletes the decoy trio
  (`--purge` scope unchanged otherwise). The decoy must die with the install
  or the library keeps a document that silently does nothing.
- Firmware-update posture documented in README: units under
  `/etc/systemd/system/` are wiped by updates (same as the existing two), so a
  firmware update reverts launch to SSH-only until reinstall — stock behaviour,
  by design.

### Task 5 — end-to-end verification on hardware

- Tap the decoy in the library → board appears within the debounce budget;
  pen still draws (M3a ink path intact through a spawned launch).
- Quit → xochitl returns front without an explicit switch (assert via
  `--clients`: no redoku client, xochitl active, screen shows the library).
- Re-tap while the game runs → debounce + GetClients check swallow it (no
  double spawn, no SIGSTOP pile-up).
- Watcher killed mid-play (`systemctl stop`) → running game unaffected.
- Battery pull during play → resume-on-launch still lands in the game, not
  the library.
- Fallback path exercised too if Task 1 chose the `.metadata` trigger.

**Status: partly discharged, across three unplanned device episodes rather
than one scripted run (`bin/redoku install` was run by the owner, not by an
agent, each time).** Stated plainly, the way M3b's plan states its own open
Task 11, so nothing above reads as claimed that was not:

- **Witnessed:** the installer completes cleanly (owner, episode 3, after
  the `rm -rf` and slow-restart fixes below landed); tapping the decoy
  launches the game; quit hands the panel back to xochitl (both, episode 1,
  even though the *installer* rolled back that same run); the boot-time
  phantom launch is swallowed (`swallowed: 9190ms … startup grace`, episode
  2); the post-quit relaunch loop is swallowed (`swallowed: 1504ms …
  cooldown` and `swallowed: 1800ms … cooldown`, episode 3's latency
  capture).
- **Not witnessed, still open:** pen input through a spawned launch (M3a's
  ink path has never been exercised on a game the watcher started, only on
  one launched over SSH); the watcher killed mid-play; a battery pull during
  play. None of these were run, on this device or any other, at any point in
  M4 — do not read the witnessed list above as covering them.

## Risks & fallbacks

| Risk | Answer |
|---|---|
| `IN_OPEN` noisy/cached on 3.27 | Both triggers ship; `trigger=open` (default) or `trigger=lastopened` in `watch.conf` — picked from device measurement, not guessed (PLAN.md §10) |
| xochitl rewrites metadata formats in a firmware update | Drift warning already patterned in install.sh (`/etc/version` check); decoy regen is one tool run |
| Watcher double-spawn race | Startup grace + suppress/cooldown, not the plan's original debounce-only design (Task 3's device evidence forced the redesign — see above); worst case two clients, second loses front arbitration cleanly |
| User opens the decoy expecting a printable puzzle | The PDF *is* a printable puzzle — it just also launches the game |
| Firmware update removes units | Same accepted failure mode as the existing install: revert to stock + SSH launch |

## What shipped beyond this plan

Two things forced changes this document did not anticipate, both found on
the owner's own device rather than in review.

- **The relaunch loop.** The first device run looked like a broken Quit: the
  owner quit, and the game came right back. It was never a quit bug —
  xochitl returns to the document it still has open, re-reads the PDF, and
  the watcher's `IN_OPEN` fires again. Task 3's fix is above; the journal
  line proving it holds is `swallowed: 1504ms since redoku was last seen
  running, inside the 10000ms cooldown` (`device-latency-journal.txt`,
  15:13:55).
- **A `rm -rf` that could have deleted the owner's whole document store.**
  Task 4's first review round (deliberately dispatched on a stronger model
  because this is the one diff in the milestone that runs as root on the
  owner's daily driver) found `install.sh`/`uninstall.sh` derived a delete
  path from `watch.conf` with no shape check on the UUID; a malformed
  `pdf=` line resolved to `rm -rf` on the entire xochitl documents
  directory — reviewer-executed, not theoretical. Fixed the same round
  (`looks_like_uuid`, both scripts). Recorded here because a milestone that
  shipped a bug this severe, and then fixed it before it shipped to `main`,
  is not a milestone to describe as trouble-free.
- **A pre-existing, unrelated bug found on the way, reported rather than
  quietly patched, then fixed once the owner had seen it.**
  `rm2fb.service`'s own `ExecStart` had the identical late-mount race the
  watcher had (`203/EXEC` on boot, `RequiresMountsFor` is the fix), and it
  was the cause of the frozen-splash boots — not introduced by M4, which
  only made it visible. Held out of the milestone deliberately so the
  owner could rule on a change to a unit they depend on daily; fixed on
  their word on 2026-08-28, one line in the unit `device/install.sh`
  writes. Still owed: the next boot's journal, to witness the `203/EXEC`
  actually gone. Full account, including the window the one-liner does
  *not* close: PLAN.md §11.
- Both the installer's rollback and the watcher's crash-loop protection were
  exercised for real, not just reasoned about: the owner's install rolled
  back **twice** on the actual device (episode 1, then episode 2) before
  episode 3 succeeded ("the installer now actually runs and works cleanly",
  the owner's own words). The causes closed across Task 4's fix rounds
  included a silent "xochitl isn't running" failure the verification step
  itself was tripping over (round 1) and a `wait_for_active` check that was
  first too eager to declare success and, after being fixed, briefly too
  eager again in the opposite direction — caught by review before it shipped
  (round 2's re-review), not by a third failed device install.

## Known, deferred issues (parked minors)

Found during review, not fixed, and not lost with the workspace. A final
whole-branch review may triage or close these; until then they are
known-and-deferred, not silently absent.

**`mrbgems/mruby-rm2` (Task 1):**
- `spawn.c:141-174` has three near-identical capture-errno/close/restore/fail
  blocks that could share one helper.
- `test/inotify.rb` / `test/spawn.rb` never clean up their
  `/tmp/redoku-*-test*` fixture directories.
- The fd-hygiene regression test's path-based tolerance would not catch a
  future *path-backed* bookkeeping fd leaking across the exec (nothing in
  the shim opens one today, so this is dormant).
- The same test has a narrow TOCTOU window — a transient shell-startup pipe
  still open at enumeration time would be wrongly flagged. Worth a looped
  run of that one assertion before trusting it in CI.

**`tools/mkdecoy.rb` (Task 2):**
- `write_all` (`tools/mkdecoy.rb:389-390`) has no rescue around
  `mkdir_p`/`File.write`, so an unwritable `--out` prints a Ruby backtrace
  instead of a clean `mkdecoy:` error.

**`mrbgems/mruby-redoku`'s watcher (Task 3, 8 items parked at completion):**
- `Config` and the re-arm state machine in `watcher.rb` are two clean
  extraction seams; the file's ~390-line size is real maintainability cost
  that flagging did not fix.
- No test exercises `Watcher#run` itself (an inverted loop condition would
  only show on a first manual launch).
- SIGHUP's "config re-read" log line reads as unconditional success
  regardless of each role's `reconcile!` outcome.
- A custom `game=` value is only ever exercised through `Config.parse`, not
  through a live trigger.
- `reconcile!(:pdf); reconcile!(:metadata)` is repeated verbatim three
  times.
- `note_redoku_presence` polls `RM2::Control.clients` once per tick forever
  after the first spawn, and each call can block up to 2 s
  (`SO_RCVTIMEO` in `control.c`), stretching SIGTERM/SIGHUP latency.
- The child-registration race (a demoted xochitl bumping `lastOpened` while
  the game holds the panel) is self-limiting by construction but untested.
- `retry_pending_rearms`'s recovery path does not carry the "died" hint the
  way the direct re-arm path does, so a re-arm that only succeeds on a later
  retry loses it — judged essentially unreachable under the shipped
  `trigger=open` default, since the pdf's own `IN_OPEN` carries the launch
  either way, but not proven unreachable.
- Cross-cutting, found by the controller rather than a task reviewer: a
  `watch.conf` with two `pdf=` lines makes the install/uninstall shell
  scripts take the **first** line and `watch_config.rb` take the **last**,
  so a corrupted config could point the installer and the watcher at
  different paths. Corrupt-config-only; not exercised by any test.

**`device/install.sh` / `device/uninstall.sh` (Task 4, 4 minors parked + 1
pre-existing at completion):**
- `install.sh:633`'s SUCCESS summary attributes every non-started watcher to
  "(no game binary yet)", which is no longer true for two newer failure
  paths.
- `FINISHED=1` is set before `rollback` runs, so a second Ctrl-C during
  rollback truncates it (closing this needs `trap '' INT TERM HUP` as
  `finish()`'s first statement).
- `uninstall.sh:222-228`'s final sweep neither verifies nor reports,
  unlike the same file's own pattern elsewhere.
- `install.sh:570` announces the watcher wait before the restart that may
  fail.
- Pre-existing, widened rather than caused by this milestone's new signal
  traps: unguarded `rm`s and a `daemon-reload` inside `rollback()` under
  `set -e`, so a failing `daemon-reload` stops rollback after its first
  line.
- Also open, not a defect: `systemctl show -p` is not among the subcommands
  verified against this specific firmware — if unsupported, every
  `wait_for_active` sample reads "keep waiting" and the first wait burns its
  full budget before rolling back. Fail-safe either way; a one-line
  on-device probe would settle it. And signal-delivery *responsiveness*
  under BusyBox ash (how fast a blocked `sleep`/`systemctl` actually reacts
  to a trapped signal) could not be measured off-device; the trap logic
  itself was verified, its timing was not.

## Explicitly out of scope (unchanged parking lot)

Home-screen icon replacement, xochitl patching, launching anything other than
`redoku` from the watcher, and every v2 item in PLAN.md §10.
