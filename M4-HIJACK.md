# M4 — the hijack: launch reDoku by tapping a document

**Date:** 2026-08-26
**Status:** planned
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

### Task 2 — `tools/mkdecoy.rb` (host-side, CRuby)

- Generates a genuine single-page Sudoku PDF (a printed puzzle — it should
  look plausible if someone actually views it) plus the xochitl side files:
  - `<uuid>.pdf` — the document itself
  - `<uuid>.metadata` — `visibleName: "Sudoku"`, etc., in xochitl's line-based
    format
  - `<uuid>.content` — the fileType/document metadata stub
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

## Risks & fallbacks

| Risk | Answer |
|---|---|
| `IN_OPEN` noisy/cached on 3.27 | `.metadata` `lastOpened` via `IN_CLOSE_WRITE` — decided empirically in Task 1, not guessed |
| xochitl rewrites metadata formats in a firmware update | Drift warning already patterned in install.sh (`/etc/version` check); decoy regen is one tool run |
| Watcher double-spawn race | Debounce + GetClients check; worst case two clients, second loses front arbitration cleanly |
| User opens the decoy expecting a printable puzzle | The PDF *is* a printable puzzle — it just also launches the game |
| Firmware update removes units | Same accepted failure mode as the existing install: revert to stock + SSH launch |

## Explicitly out of scope (unchanged parking lot)

Home-screen icon replacement, xochitl patching, launching anything other than
`redoku` from the watcher, and every v2 item in PLAN.md §10.
