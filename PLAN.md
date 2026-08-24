# reDoku — Design & Implementation Plan

A handwritten sudoku game for the reMarkable 2, written in mruby.

You tap an innocent-looking "Sudoku" document in the stock library; instead of a
PDF, a game launches. It generates puzzles, you play by literally writing
digits into cells with the pen, and your scribbles snap to printed digits.
Quit, and you're back in the stock UI exactly where you left it.

**Status:** design approved 2026-08-20. Build pipeline + `mruby-rm2` display
gem complete 2026-08-21 (host tests green against a fake rm2fb server;
cross-built mruby verified running on the device). **Milestone 0 passed
2026-08-21**: rm2fb (swtcon) installed via `bin/redoku install` on firmware
3.27.3.0 — xochitl feels stock under the client shim, the mruby
checkerboard demo flashed onto the e-ink and xochitl's UI came back, and
`rm2fbctl list` works (live-client `switch` deferred to M1, which builds
the first long-running client).

**Milestone 1 is complete 2026-08-23.** `mruby-rm2` grew input, the control
socket, signal flags and a monotonic clock; `mruby-redoku` holds the layout,
bitmap font, renderer, pen and touch mapping and the event loop; and
`mruby-bin-redoku` links it all into the `redoku` executable, cross-built for
armv7 and put on the device by `bin/redoku install` / `play`. Green on 2269
host assertions plus a bintest that runs the real binary.

Verified on the real device, not inferred: the board paints, pen ink echoes
under a real digitizer, taps land on both button rows from the pen *and* a
finger, palm suppression holds while writing, and Quit hands the panel back
to xochitl. Two defects the device found that no host test could — Quit and
then New/Level each reading as a button that did nothing — are why §5's
"every button acknowledges its press" exists. M1 also grew two features past
its original scope on the owner's instruction: finger-tappable buttons and
the press acknowledgement.

**Milestone 2 is complete 2026-08-24.** `Redoku::Sudoku` holds Grid, Solver,
Techniques, Rater and Generator; the renderer prints digits, whole puzzles and
a `GENERATING...` splash; and the event loop now holds a puzzle — `run` digs
the first one behind the opening paint, New digs a fresh one, Level digs at
the new tier, and a suspend/resume repaints the board it was on. Green on 2438
host assertions (KO 0, Crash 0, Warning 0) plus the bintest, and cross-built
clean for armv7.

Witnessed on the real device 2026-08-24, not inferred: the `GENERATING...`
splash renders and appears *during* generation as intended; New generates a
puzzle; Level generates a puzzle; Quit works; and the buttons respond to both
pen and finger. That discharges the button-feedback half of M1's outstanding
hardware caveat.

What that device run did **not** establish, and must not be read as saying:

- **Generation timing is still unmeasured.** No timings were taken on the
  device. What the run establishes is that the pause was *acceptable to the
  owner in practice* — a subjective acceptance, not a measurement. The host
  figures are easy ≈55 ms, medium ≈86 ms and hard ≈157 ms, and the spread
  matters more than the medians: across 13 seeds a *hard* dig ran from 90 ms
  to 596 ms on the host alone, and the Cortex-A7 is substantially slower, so
  the worst-case pause remains an unknown number.
- **Palm suppression under the new build is unverified.** It was not mentioned
  in the device report, and it is the half of M1's caveat that stays open.
- **The digits are not §8's font.** They are a 14× upscale of the built-in
  5×7 table, so each glyph pixel is a blocky 14×14 square; §8's Spleen BDF
  pipeline (`tools/fontpack.rb`) does not exist yet — deferred, not dropped.
  No formal legibility assessment was made, but the deferral drew no visual
  complaint in the first device run, which is some evidence it was a
  reasonable call and nothing stronger.

Next: Milestone 3 — the recognizer and the game proper.

---

## 1. Context & constraints

| Fact | Value |
|---|---|
| Device | reMarkable 2 (i.MX7, Cortex-A7, armv7hf, 1404×1872 e-ink) |
| Firmware | **3.27.3.0**, auto-updates disabled (2026-08-20) |
| Device state | Stock. SSH access only — no Toltec, no Vellum, no launcher |
| Dev machine | macOS, Docker Desktop (build environment) |
| Language | mruby 4.0.0, cross-compiled; game logic in Ruby, thin C shim for OS interfaces |

The rM2 has **no kernel framebuffer**: the e-ink panel is driven in software.
All homebrew drawing goes through a display server. We use
[rM2-stuff](https://github.com/timower/rM2-stuff) (timower), whose
`rm2fb_server_swtcon` variant drives the panel with its own reimplemented
driver and is therefore **firmware-version-independent** (no per-version
address hooks). Its master branch explicitly handles the RGB32 framebuffer
format that firmware 3.24+/3.27 introduced (see the repo's
`doc/swtcon_3.27_diff.md`), tested by the author against a real 3.27 image.
Our exact build 3.27.3.0 was unverified → hence the Milestone 0 gate (§10),
**passed on the real device 2026-08-21**.

Decisions already made with rationale:

- **mruby over CRuby** — one self-contained ARM binary, `scp` to deploy, no
  interpreter install on the device.
- **rM2-stuff display server over a standalone panel driver** — screen
  arbitration, xochitl coexistence, and return-to-stock-UI are solved
  problems there; linking the panel driver ourselves would add large C
  integration cost and a janky resume of xochitl.
- **Real handwriting recognition** (not a tap-picker) — the point of the
  project. Nine symbols is tractable with a classical point-cloud matcher; no
  ML runtime.
- **Staged launch UX** — SSH launch first (M3), document hijack second (M4).

## 2. System architecture

```
┌────────────────── reMarkable 2 ──────────────────────────────┐
│                                                              │
│  rm2fb_server_swtcon  (systemd, owns the e-ink panel)        │
│    ▲ unix socket /var/run/rm2fb.sock       (draw protocol)   │
│    ▲ unix dgram  /var/run/rm2fb.control.sock (switch/list)   │
│    ▲ tcp :8888                             (debug/screens)   │
│    │                                                         │
│    ├── xochitl        (stock UI; LD_PRELOAD client shim)     │
│    ├── redoku         (our game: mruby VM + C shim)          │
│    └── redoku --watch (hijack watcher, systemd service;      │
│                        control socket + inotify only)        │
│                                                              │
│  /dev/input/event*  ── pen (Wacom I2C Digitizer), touch,     │
│                        power button (evdev, read directly)   │
└──────────────────────────────────────────────────────────────┘
```

One client is "front" and may draw; the server freezes all others with
SIGSTOP (whole process group) and thaws them with SIGCONT, re-flashing their
buffer to the panel on resume. Switching front is a one-datagram RPC. A fresh
client `Init` takes the screen automatically.

**Nothing stock is replaced.** xochitl keeps its own systemd service; we add
a drop-in override injecting the `LD_PRELOAD` client shim. Uninstall = remove
our files, drop-in, and units; reboot.

## 3. Display server protocol (research reference)

Verified against rM2-stuff master source (commit `4515770`-era squash).
Our C shim implements the client side of this — nothing else.

**Connect & init** — `AF_UNIX/SOCK_STREAM` to `/var/run/rm2fb.sock`. Messages
are `int32 tag` + raw little-endian struct, strict request/reply:

| Tag | Message | Payload | Reply |
|---|---|---|---|
| 0 | `Init{bool ownSwtcon; pad[3]; int32 w,h,fmt}` | 16 B (send `0, 1404, 1872, RGB565=0`) | 12 B `FbFormat` + `SCM_RIGHTS` memfd (1 dummy byte) |
| 2 | `UpdateParams{int32 y1,x1,y2,x2; flags; waveform; float temp; int32 extraMode}` | 32 B — **y first, corners inclusive** | 1 B bool ack (false = we're not front, dropped) |
| 3 | `UpdateBatchHeader{int32 count}` + count×32 B | | 1 B ack |
| 4 | `OpenInputDevice{char path[64]; int32 flags}` | 68 B | 1 B bool, then `SCM_RIGHTS` fd if true |

**Framebuffer** — mmap the received memfd, `MAP_SHARED`, size **7,884,864 B**
(= 1404×1872×3): RGB565 plane 1404×1872×2 (stride = width×2, no padding),
followed by a 1-byte-per-pixel gray plane we never touch but must include in
the mapping size. Gray→RGB565:
`(g>>3) | ((g>>2)<<5) | ((g>>3)<<11)`; white `0xFFFF`, black `0x0000`.

**Waveforms** (`waveform = mode | 0xf000`; flags: `SYNC=1`, `FAST_DRAW=2`):

| Use | mode | flags |
|---|---|---|
| Pen ink echo | `DU=1` (or `A2=4` if too slow) | `FAST_DRAW` |
| UI / printed digits | `GL16=3` | 0 |
| Full refresh (start, win screen) | `GC16=2` | `SYNC` |

**Control socket** — `SOCK_DGRAM` to `/var/run/rm2fb.control.sock`.
`Request{int32 type; int32 pid}` with `GetClients=0 / GetFB=1 / SwitchTo=2 /
SetLauncher=3`. `GetClients` returns `int32 n` + n×52 B
`Client{pid, active, FbFormat, char name[32]}` (name may be unterminated).
`SwitchTo` returns 1 bool byte. `rm2fbctl list|switch <pid>` is the CLI.

**Input** — plain evdev; the server can hand us fds via `OpenInputDevice`
(preferred: it drains stale event backlog when we're thawed). Devices are
identified **by name**, never by eventN:

| Device | evdev name | Ranges |
|---|---|---|
| Pen | `Wacom I2C Digitizer` | ABS_X 0..20966 (long axis), ABS_Y 0..15725, ABS_PRESSURE 0..4095, ABS_DISTANCE 0..255, BTN_TOOL_PEN/RUBBER, BTN_TOUCH |
| Touch | `pt_mt` | ABS_MT_POSITION_X 0..1403, _Y 0..1871, slots 0..31 |
| Power | `snvs-powerkey` | KEY_POWER |

Pen→screen transform: `sx = ABS_Y * 1404/15725`, `sy = 1872 − ABS_X * 1872/20967`.
Touch→screen: `sx = X`, `sy = 1871 − Y` (1871, not 1872: row 1872 does not
exist, and every mapped point has to be a real panel pixel — `Redoku::Touch`).

**Process-lifecycle contract** — one connection per PID (identified via
`SO_PEERCRED`); expect SIGSTOP/SIGCONT of our process group; ignore SIGPIPE
(server restart = reconnect); on SIGCONT the server has already re-flashed
our buffer, but we do a defensive full redraw. Closing the socket cleanly
deregisters us.

**TCP :8888 debug protocol** — server pushes every front-client update
(`UpdateParams` + rect RGB565 pixels) and accepts
`Input{int32 x,y,type(Move/Down/Up); bool touch}` / `PowerButton` injections
into uinput clones. This is our remote screenshot + synthetic-pen test rig (§9).

## 4. Repository layout

Idiomatic mruby: everything — C shim, game logic, and the executable — is an
mrbgem with the canonical layout (`mrbgem.rake`, `src/`, `mrblib/`, `test/`,
`tools/<bin>/`). mruby itself is **not vendored**: like the rM2-stuff fork, it
lives in a sibling checkout (`../mruby`, 4.0.0) mounted into the build
container; builds run mruby's own rake with `MRUBY_CONFIG`/`MRUBY_BUILD_DIR`
pointing back into this repo, so the mruby tree stays pristine.

```
reDoku/
├── PLAN.md                  # this document
├── Makefile                 # build / deploy / test / shell entry points (Docker wrappers)
├── build_config.rb          # mruby build config: host (test) + rm2 (cross) targets
├── docker/Dockerfile        # ghcr.io/toltec-dev/base:v4.0 + host toolchain + CRuby
├── mrbgems/
│   ├── mruby-rm2/           # C shim gem: display/input/control/inotify/signals
│   │   ├── mrbgem.rake
│   │   ├── src/             # C sources (display.c, later input.c, control.c, …)
│   │   ├── mrblib/          # thin Ruby sugar (constants, kwargs wrappers)
│   │   └── test/            # mrbtest suites + fake rm2fb server (C, gem_test hook)
│   ├── mruby-redoku/        # game logic gem, pure Ruby (mrblib/: sudoku/,
│   │   │                    #   recognizer/, ui/, app/; test/: unit suites)
│   │   └── …
│   └── mruby-bin-redoku/    # binary gem: tools/redoku/redoku.c (main), bintest/
├── examples/                # demo scripts run with the cross-built bin/mruby
├── assets/
│   ├── fonts/               # BDF bitmap fonts (public domain, e.g. Spleen)
│   └── templates/           # digit stroke templates (generated + recorded)
├── tools/                   # host-side Ruby (CRuby on the Mac)
│   ├── rmctl.rb             # screenshot / inject pen via TCP :8888
│   ├── fontpack.rb          # BDF → packed glyph tables (Ruby data)
│   └── mkdecoy.rb           # generate decoy Sudoku PDF + xochitl metadata
├── device/                  # install.sh, uninstall.sh, backup.sh, systemd units, xochitl drop-in
└── build/                   # mruby build output (gitignored)
```

## 5. The game binary

One binary, three modes: `redoku` (game), `redoku --watch` (hijack watcher),
`redoku --record` (capture your own handwriting as recognizer templates).

### C shim (mrbgem `mruby-rm2`, ~500 lines total)

The shim is deliberately dumb — syscalls and byte-packing only, zero game
knowledge:

- `RM2::Display.open` → connect, Init, mmap; raises on failure
- `Display#fill_rect(x, y, w, h, gray)` / `#draw_line(x1, y1, x2, y2, width, gray)` /
  `#blit(x, y, w, h, packed_gray_string)` — pixel pushing in C for speed
- `Display#update(x, y, w, h, waveform:, flags:)` — clamps, converts to
  inclusive y-first corners, sends, reads ack
- `RM2::Input.resolve_all(name)` → every device path whose evdev name
  matches (the server publishes uinput clones of the real nodes, and both
  carry the same name); `Display#open_input(path)` requests that
  path's fd over the display connection (`OpenInputDevice` — the server
  allows one socket per PID, so input fds ride the Display's connection) and
  returns an `RM2::Input`; `#pending_events` decodes `input_event` structs
  and assembles per-SYN_REPORT samples into `[raw_x, raw_y, pressure, tools]`
  arrays (`tools` = TOOL_PEN|TOOL_RUBBER|TOUCH bitmask);
  `RM2::Input.wait(inputs, timeout_ms)` — a class method over an array of
  them, one poll() for every source at once, so the event loop needs no IO
  objects
- `RM2::Control.clients` / `.switch_to(pid)` — control-socket datagrams
- `RM2::Inotify.watch(path, mask)` / `#read_events` — for the watcher
- `RM2.setup_signals` — ignore SIGPIPE, SIGCONT and SIGTERM/SIGINT → flags
  polled from Ruby (`RM2.resumed?`, `RM2.terminated?`). No `setsid`: the game
  keeps its controlling terminal, which is what lets Ctrl-C over an SSH
  session reach it as SIGINT and quit it cleanly

Everything above this line is Ruby.

### Ruby event loop

Single-threaded poll loop (`RM2::Input.wait`) over the pen fds **and the
touch fds** with a timeout that doubles as the recognition-idle timer. Both
devices are opened; what they may do differs, and that split is deliberate:
the board is a writing surface, so **ink is pen-only**, while the buttons
also answer to a finger.

1. Pen events → `InputRouter` maps raw→screen coordinates, classifies the
   target region (cell / button), and forwards to the active screen.
2. Pen-down inside a cell starts `StrokeCapture`: points buffered, ink echoed
   immediately as `draw_line` + DU updates (small dirty rects per segment).
3. Pen idle ≥ 500 ms after pen-up (or writing moves to another cell) →
   strokes for that cell go to the recognizer.
4. Recognizer verdict → cell ink region cleared, printed digit drawn (GL16),
   or rejection feedback (§6).
5. Buttons (New / Difficulty / Check / Quit) are tap targets for the pen and
   for a finger alike: a tap = down+up on the same button with little
   movement. The finger's travel budget is the looser of the two (a fingertip
   rolls as it lands), and a touch contact is suppressed while the pen is in
   proximity and for ~500 ms after it leaves — otherwise the palm you write
   with would press Quit. A contact that began under the pen has to lift and
   press again before it counts, so a resting palm cannot fire a button just
   because the pen was set aside.
6. **Every** button press is acknowledged at the button: it paints inverted
   in the ink waveform, the action runs while it is held down, and it paints
   back ~200 ms later (Quit is not painted back — it is leaving). Not
   optional polish: verified on the device, an action whose only visible
   result is elsewhere on the panel, or is pixel-identical to what was
   already there, reads as a button that did nothing at all.
7. Proximity suppression is recoverable. The pen's proximity state is an
   event latch, and a lost proximity-off packet — the display server drains
   the evdev backlog of a client it thaws, and `SYN_DROPPED` discards torn
   packets — would otherwise disable the touchscreen for the whole session.
   So a resume forgets it, and it also expires after ~1 s of complete pen
   silence.
8. Touch events reach nothing else. A finger on the board does not ink, does
   not select a cell, and does not disturb a pen stroke in progress.

### mruby build

mruby 4.0.0, sibling checkout `../mruby`. The `default` gembox already
carries everything we need (`mruby-io`, `mruby-pack`, `mruby-math`,
`mruby-random`, `mruby-time`, `mruby-sprintf`, `mruby-errno`, plus the
`mruby`/`mirb`/`mrbc` binaries); we add our own gems on top. Two targets in
`build_config.rb`:

- **rm2** (device): cross-compile with `/opt/x-tools/arm-remarkable-linux-gnueabihf`
  from `ghcr.io/toltec-dev/base:v4.0` (glibc 2.35, matched to firmware
  ≥ 3.18.2.3 — dynamic libc is safe; a static-musl fallback exists if that
  ever bites)
- **host** (test): same gems compiled natively inside the container; runs
  `mrbtest` against the fake display server

Game Ruby code is compiled to `.mrb` bytecode and linked into the binary.

## 6. Handwriting recognition

**Algorithm: $P point-cloud recognizer** (Vatavu/Anthony/Wobbrock).
Chosen over $1 because it's inherently multi-stroke and stroke-order/direction
invariant — people write 4, 5, 7 with varying stroke counts and orders.

Pipeline per cell entry:

1. Collect all strokes for the cell (a stroke belongs to the cell containing
   its bounding-box center; consecutive strokes in the same cell accumulate).
2. Normalize: resample the combined cloud to 48 points, scale uniformly by
   the larger bounding-box side (aspect preserved — it's what separates 1
   from 7; guard the degenerate near-vertical "1" against divide-by-tiny
   width), translate centroid to origin.
3. Greedy cloud matching against templates for digits 1–9; score =
   inverse of best cloud distance.
4. Accept if best score clears a confidence threshold **and** leads the
   runner-up digit by a margin; else reject: flash the cell border (DU
   invert-flash), clear the ink, let the user retry.

**Templates:** ship 3–5 authored samples per digit in `assets/templates/`
(bootstrap set drawn during development). `redoku --record` runs on-device:
it prompts "write 1 … write 9" a few rounds, saves clouds to
`/home/root/redoku/templates.local`, which the game loads on top of the
shipped set — so the recognizer tunes itself to *your* handwriting cheaply.

**Erase gesture: scribble-out.** A stroke set over a non-given, filled cell
is an erase (not an entry) when its total path length exceeds ~4× the cell
diagonal **and** it has ≥ 4 direction reversals. Recognized before digit
matching. Given (clue) cells never erase. Misclassification risk is low
because digit strokes are short; thresholds tuned in M3.

**Pre-classification guards:** strokes fully inside a cell's bounds only;
tiny dots (< 8 px path) are discarded as accidental touches.

## 7. Sudoku engine

Pure Ruby, zero device dependencies (fully unit-testable on host).

- **`Grid`** — 81 cells; each is a given, an entry, or empty. Serializes to a
  string; game state persists as a few `key=value` lines plus that string in
  `/home/root/redoku/state` (no JSON gem needed) so a SIGTERM/reboot resumes
  the puzzle.
- **`Solver`** — two solvers:
  - *Counting backtracker*: randomized order, early-exits at 2 solutions.
    Used for generation (uniqueness) and to store the solution for checking.
  - *Technique solver*: applies human techniques cheapest-first — naked
    single, hidden single, pointing/box-line, naked pair, naked triple,
    hidden pair, hidden triple, X-wing. Used for rating, and for M3's hints;
    records both the hardest technique needed and how often each was needed.
- **`Generator`** — fill an empty grid with the randomized backtracker; dig
  cell pairs (rotational symmetry) as deep as uniqueness allows, then walk
  that chain of boards from the shallow end and keep the first one whose
  score lands in the requested band. Clue count is a **guard rail, not a
  target** (22–45); the score decides where to stop. Real attempt cap, and
  the closest board found if none matches.
- **`Rater`** — one score per puzzle, from two measurements in series: the
  weighted count of human techniques needed, plus 120 per guess still
  required on the board the techniques could not finish. The tier is the
  harder of the score's band and the floor its hardest technique implies.
  - **Easy**: score ≤ 130 — singles only, generously clued (44–45 clues)
  - **Medium**: 131–230 — more filling in, or one eliminator needed (31–41)
  - **Hard**: 231+ — a lot of filling in, or guessing beyond our eight
    rules (26–32)
  - Measured 12/12 hit rate per tier at 56/87/153 ms on the build host — but
    both halves of that sentence need a qualifier before anyone reads them as
    "medium and hard are proven fine." 153 ms is the HARD tier's **median**,
    not its typical case: across 13 seeds a hard dig on the same host ran
    from 90 ms to 596 ms (§10), and it is that tail, not the median, that the
    "few hundred ms" budget above has to survive. And "12/12 hit rate" means
    only that the Rater agreed with its own bands 12 times out of 12 — an
    internal self-consistency check, not evidence that a player would call
    those boards easy, medium or hard. The owner's device playtest (§10)
    tested the claim the numbers invite and contradicted it in the only
    sense that matters: medium and hard both played far too easy, which is
    why M2 closed with a follow-on milestone to rework difficulty into five
    technique-gated tiers rather than shipping these three bands as final.
  - Bands are **calibrated against measurement, not borrowed**, and are
    derived from two ordered lists so that going to five levels is a table
    edit plus a recalibration.
  - **Why not clue count, search cost, or the technique alone — and what our
    "hard" honestly means — is recorded in
    [`docs/design/difficulty-rating.md`](docs/design/difficulty-rating.md).**
    Read it before changing any constant in `Rater`; several of these numbers
    are counter-intuitive and were arrived at by being wrong first.
- **Mistake checking** — the Check button compares entries against the stored
  solution and marks wrong entries with a small corner ✕ (they stay until
  edited). When the grid is full and correct, the win screen fires
  automatically (full GC16 flash, "Solved — n mistakes checked", tap for new
  puzzle).

## 8. Screen layout & rendering

Portrait, full screen 1404×1872:

```
┌──────────────────────────────┐
│  reDoku          ● Medium    │   header: title, difficulty
│ ┏━━━┯━━━┯━━━┳━━━┯━━━┯━━━┳──┓ │
│ ┃   │   │   ┃   │   │   ┃  ┃ │   board: 9×9, cell = 140 px
│ …          1260×1260 px    … │   givens: heavy print
│ ┗━━━┷━━━┷━━━┻━━━┷━━━┷━━━┻──┛ │   entries: lighter print
│                              │
│ [ New ] [ Level ] [ Check ]  │   button row (pen-tap targets)
│                    [ Quit ]  │
└──────────────────────────────┘
```

- Board 1260×1260 (9 × 140 px cells), centered; 4 px block borders, 1 px cell
  borders — thick lines matter on e-ink.
- **Font pipeline:** public-domain BDF bitmap fonts (Spleen family) packed at
  build time by `tools/fontpack.rb` into Ruby data tables; digits rendered at
  ~96 px via integer upscale of the largest face. Crisp-enough v1; swappable
  later without touching the renderer. **Deferred as of M2** — `tools/` does
  not exist in the tree. Digits ship instead as a 14× upscale of the
  built-in 5×7 UI font, hitting this section's SIZE but not its METHOD; see
  `font.rb`'s header comment, `renderer.rb`'s `DIGIT_SCALE`, and §10's M2
  entry for the on-the-record deferral.
- Givens black; user entries dark gray (visually distinct); check-marks and
  reject-flash use inversion.
- Waveform discipline as in §3; a full GC16 refresh on screen transitions
  clears e-ink ghosting.

## 9. Build, deploy, test

**Make targets, plus `bin/redoku`** (each a thin wrapper over Docker/ssh):

- `make build` — Docker: cross-compile rM2-stuff (server + xochitl shim +
  rm2fbctl, via their `release-toltec` CMake preset) and the `redoku` binary.
  rM2-stuff builds from the sibling fork checkout
  `../rM2-stuff` (github.com/QuirkQ/rM2-stuff, tracking upstream master,
  currently `4515770` — the exact commit this plan's protocol reference was
  verified against), mounted into the build container. Any 3.27.3.0 fixes we
  need land as commits on the fork, upstreamable later.
- `bin/redoku install` — copy binaries + `device/` scripts to the device and
  run `install.sh` (idempotent, safe to re-run); `bin/redoku play` refreshes
  just the game binary and runs it
- `make test` — Docker: mruby's rake builds the host target and runs
  `mrbtest` (every gem's `test/` suite, incl. the fake-server protocol tests)
- `make screenshot` / `make inject STROKES=…` — `tools/rmctl.rb` against
  device port 8888

**Testing strategy** (TDD per superpowers; the layering makes this natural):

1. **Unit (host, fast)**: sudoku engine, recognizer math, stroke
   classification, layout hit-testing — pure Ruby, no shim. Recognizer gets a
   corpus test: recorded strokes (captured once via `--record` during M3) must
   classify ≥ threshold accuracy; erase-gesture corpus likewise.
2. **Protocol (Docker)**: a fake rm2fb server written in C inside
   `mruby-rm2/test/` using mrbtest's `mrb_<gem>_gem_test` scaffolding hook
   (the same pattern mruby-io uses to test its socket code). It forks a
   child speaking the real wire protocol (unix socket, memfd, SCM_RIGHTS)
   and logs received messages for byte-exact assertions: init handshake,
   update packing (y-first inclusive corners!), input fd passing,
   reconnect-on-EPIPE.
3. **Integration (device)**: scripted end-to-end via TCP 8888 — inject a
   recorded "write 5 in cell (3,4)" stroke sequence, pull a screenshot,
   assert the printed 5 appears in the right cell region. Semi-automated:
   run from the Mac, eyeball + a couple of pixel-region asserts.

**Device install (`device/install.sh`)** — as built, after on-device
discovery of 3.27.3.0 (2026-08-21):

1. Binaries are staged to `/home/root/redoku/{bin,lib}` (survives OTA
   updates); the two systemd files go to `/etc/systemd/system/` (wiped by
   OTA updates — built-in cleanup). Nothing existing is modified, only
   added: no backups needed for this phase (a backup step returns in M4,
   which touches xochitl's document store).
2. `rm2fb.service`: `Type=notify` (the server sd_notifies READY after its
   sockets bind), `Before=xochitl.service`, `KillSignal=SIGINT` (its clean
   shutdown handler ignores SIGTERM), `ExecStart` of
   `rm2fb_server_swtcon`. **No `.socket` unit** — upstream's is stale
   (DGRAM at the STREAM's path); the server binds its own sockets:
   STREAM `/var/run/rm2fb.sock` (clients), DGRAM
   `/var/run/rm2fb.control.sock` (`rm2fbctl`).
3. Self-disarming preload: the xochitl drop-in
   (`xochitl.service.d/10-redoku.conf`) uses
   `EnvironmentFile=-/home/root/redoku/preload.env`, which
   `rm2fb.service` writes on successful start (`ExecStartPost`) and
   deletes on any stop or crash (`ExecStopPost`). The shim `exit(1)`s
   xochitl when no server answers, and 4 fast xochitl failures make
   `remarkable-fail.sh` **reboot the device** — with the arming file, a
   broken server instead yields a stock xochitl boot. Reboot loops are
   structurally impossible.
4. The drop-in also sets `WatchdogSec=0`: 3.27.3.0 runs xochitl with
   `WatchdogSec=60`, and rm2fb SIGSTOPs xochitl's process group while
   another client is front — a stopped xochitl can't pet the watchdog and
   would be killed mid-game.
5. Preflight before touching anything: root + on-device check, firmware
   version (`IMG_VERSION`, hard stop on drift unless `--force`), 32-bit
   ARM ELF magic on the artifacts, swtcon's runtime deps (`/dev/fb0`,
   `.wbf` waveform, sy7636a hwmon), and refusal if foreign xochitl
   drop-ins or a non-reDoku `rm2fb.service` exist. Any failure after
   preflight auto-rolls-back to stock.

`uninstall.sh` reverses every step (disarm first, then stop, remove,
restart xochitl), is idempotent and safe on partial installs;
`--purge` also removes `/home/root/redoku`. Both scripts print what
they do.

## 10. Milestones

**M0 — infrastructure gate (spike, throwaway allowed).** Build rm2fb from
master in Docker; install on device; verify on 3.27.3.0: (a) xochitl works
normally under the swtcon client shim — writing latency feels stock,
sleep/wake OK; (b) a ~60-line C hello-client paints rectangles and logs pen
coordinates; (c) `rm2fbctl switch` flips between xochitl and the hello client
cleanly. **Hard gate: if (a) fails we stop and decide** — options are the
rM2-stuff issue tracker, the 3.28 beta channel, or a codexctl downgrade to a
supported 3.23 build. Nothing beyond M0 starts until the gate passes.
**Passed 2026-08-21**: (a) confirmed by feel on-device; (b) via
`examples/checkerboard.rb` (acked GC16 sync update, visually confirmed,
xochitl restored on disconnect) — the planned C hello-client became the
mruby demo, exercising the real client stack instead; (c) `rm2fbctl list`
verified, live-client `switch` deferred to M1's long-running skeleton.

**M1 — walking skeleton.** mruby cross-build + `mruby-rm2` shim; `redoku`
draws the empty board and echoes pen ink into cells; Quit button returns to
xochitl. Launched via SSH.

**M2 — sudoku engine.** Grid/Solver/Generator/Rater, fully host-tested.
Board renders generated puzzles with given digits. **Passed 2026-08-24.**

Witnessed by host tests: 2438 assertions green (KO 0, Crash 0, Warning 0) plus
the bintest, and a clean armv7 cross-build whose ELF was checked. Named
rather than summarised, because each is a specific claim — a generated board
is uniquely solvable and reaches the panel as given digits in `GIVEN_GRAY`;
New deals a different puzzle and clears the player's ink with it; Level
advances the tier, repaints the label as GL16 and digs at the new tier; the
splash flush lands *before* the generator's first draw (pinned from inside the
dig by a spy Rng, because the finished update list is identical either way);
and every one of those presses still acknowledges itself at the button in
`RM2::DU`, which is M1's decision and was re-checked rather than relaxed.

Witnessed on the device the same day, by the owner: the `GENERATING...` splash
renders and appears during generation; New generates a puzzle; Level generates
a puzzle; Quit works; buttons respond to pen *and* finger. This is what
discharges the button-feedback half of M1's hardware caveat below.

Four things this milestone deliberately did NOT establish. **Generation timing
on the Cortex-A7 is unmeasured** — no timings were taken on the device, and
what the run shows is that the pause was acceptable to the owner in practice,
a subjective acceptance rather than a number (host: easy ≈55 ms, medium
≈86 ms, hard 90–596 ms across 13 seeds — the tail, not the median, is what
§7's budget has to survive). **Palm suppression under this build is
unverified**: it was not part of the device report. **The digits are not §8's
face** — a 14× upscale of the built-in 5×7 table stands in until
`tools/fontpack.rb` exists; no legibility assessment was made, though the
deferral drew no complaint in the first device run. And the header shows the
tier the player **asked** for, not the tier the generator achieved, which can
differ; the achieved tier is recorded on the App (`achieved_tier`) and M3 owns
whether to surface it. See `App#fill_board` for why the read-out follows the
button rather than the rating.

**Difficulty was rejected on playtest, the same day.** M2's gate above is
about mechanism — a board generates, rates and renders — and it was met.
Difficulty was not. Playing on the device after M2 landed, the owner's own
words: *"the amount of pre-filled in numbers for medium and hard make the
sudoku's very easy."* That is device evidence, from the one test that
actually matters for a difficulty label. A host-side measurement taken
afterward does not merely echo the complaint, it sharpens it: 40 out of 40
generated `:medium` boards solve by naked and hidden singles alone — the
same techniques `:easy` is supposed to be limited to, so the two tiers are
not reliably distinguishable by the only thing a player experiences. The
next milestone reworks difficulty into five technique-gated tiers rather
than patching these three bands; its own plan document is being written
separately and is not restated here.

**M3 — the game.** Recognizer + templates + `--record`; entries, erase
gesture, Check, difficulty menu, win screen, state persistence. This is the
"playable via SSH" release.

**M4 — the hijack.** Decoy document (`tools/mkdecoy.rb` generates the PDF +
`{uuid}.metadata`/`.content`, installed by script, one xochitl restart to
index). `redoku-watcher.service`: inotify `IN_OPEN` on the decoy's `.pdf`
content file, 5 s debounce, spawn game (its `Init` takes the screen
automatically). Quit: the game closes its display connection and exits, and
the server promotes the next client — which is xochitl. It must NOT
`switch_to` xochitl's pid: the server SIGSTOPs the whole process group of the
client it demotes, so a live client that switches away from itself freezes
inside the call and never reaches its exit path (see §3's process-lifecycle
contract, `src/control.c`'s header, and `mruby-rm2/README.md`). `GetClients`
stays useful for the watcher's "is the game already a client" check, not for
handing the panel back. Fallback if `IN_OPEN` proves noisy or
cached-away on 3.27: watch the decoy's `.metadata` for `lastOpened` writes
(`IN_CLOSE_WRITE`) instead — verified empirically in M4's first task.

**v2 parking lot (explicitly out of scope):** pencil marks, recognizer
calibration UI, statistics/timer, undo, multiple saved puzzles, landscape.

## 11. Error handling & edge cases

- **Display server gone** (crash/restart): writes hit EPIPE → reconnect loop
  with backoff; after 3 failures, exit 1 (systemd/SSH shows it).
- **Not front**: update acks return false — ignore; on `RM2.resumed?` do a
  full redraw.
- **Pen device missing** (name lookup fails): fatal with a clear message
  listing found devices.
- **SIGTERM / power events**: persist game state, close socket, exit 0;
  state restored on next launch.
- **Recognition ambiguity**: never guess silently — reject-flash and let the
  user rewrite. Tunable thresholds live in one Ruby constants file.
- **Watcher re-trigger loop**: debounce + "is the game already a client"
  check via `GetClients`.
- **Firmware update pressure**: auto-update is off; `install.sh` warns if
  `/etc/version` ≠ 3.27.3.0 (drift detection after any manual update).

## 12. Sources

- rM2-stuff (display server, protocol, input): https://github.com/timower/rM2-stuff — protocol details verified directly against master source
- Toltec toolchain images: https://github.com/toltec-dev/toolchain
- Toltec firmware ceiling / ecosystem status: https://toltec-dev.org/, https://remarkable.guide/
- mruby 4.0.0: https://mruby.org/downloads/
- reMarkable release notes: https://support.remarkable.com/s/article/Release-notes-overview
- $P recognizer: Vatavu, Anthony & Wobbrock, "Gestures as Point Clouds: A $P Recognizer" (ICMI 2012)
