# reDoku — Design & Implementation Plan

A handwritten sudoku game for the reMarkable 2, written in mruby.

You tap an innocent-looking "Sudoku" document in the stock library; instead of a
PDF, a game launches. It generates puzzles, you play by literally writing
digits into cells with the pen, and your scribbles snap to printed digits.
Quit, and you're back in the stock UI exactly where you left it.

**Status:** design approved 2026-08-20. Milestone 0 not yet started.

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
Our exact build 3.27.3.0 is unverified → hence the Milestone 0 gate (§10).

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

**Framebuffer** — mmap the received memfd, `MAP_SHARED`, size **7,886,016 B**:
RGB565 plane 1404×1872×2 (stride = width×2, no padding), followed by a 1-byte
gray plane we never touch but must include in the mapping size. Gray→RGB565:
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
Touch→screen: `sx = X`, `sy = 1872 − Y`.

**Process-lifecycle contract** — one connection per PID (identified via
`SO_PEERCRED`); expect SIGSTOP/SIGCONT of our process group (so the game
`setsid()`s); ignore SIGPIPE (server restart = reconnect); on SIGCONT the
server has already re-flashed our buffer, but we do a defensive full redraw.
Closing the socket cleanly deregisters us.

**TCP :8888 debug protocol** — server pushes every front-client update
(`UpdateParams` + rect RGB565 pixels) and accepts
`Input{int32 x,y,type(Move/Down/Up); bool touch}` / `PowerButton` injections
into uinput clones. This is our remote screenshot + synthetic-pen test rig (§9).

## 4. Repository layout

```
reDoku/
├── PLAN.md                  # this document
├── Makefile                 # build / deploy / test / shell entry points
├── docker/Dockerfile        # ghcr.io/toltec-dev/base:v4.0 + mruby sources
├── vendor/                  # pinned mruby checkout (fetch script or submodule)
├── shim/                    # mrbgem "mruby-rm2" (C)
│   ├── mrbgem.rake
│   └── src/{display.c,input.c,control.c,inotify.c,signals.c}
├── game/                    # all Ruby
│   ├── main.rb              # entry: game / --watch / --record modes
│   ├── sudoku/{grid.rb,solver.rb,generator.rb,rater.rb}
│   ├── recognizer/{recognizer.rb,templates.rb,normalize.rb}
│   ├── ui/{layout.rb,render.rb,font.rb,screens.rb}
│   └── app/{game.rb,input_router.rb,stroke_capture.rb,watcher.rb}
├── assets/
│   ├── fonts/               # BDF bitmap fonts (public domain, e.g. Spleen)
│   └── templates/           # digit stroke templates (generated + recorded)
├── tools/                   # host-side Ruby (CRuby on the Mac)
│   ├── rmctl.rb             # screenshot / inject pen via TCP :8888
│   ├── fontpack.rb          # BDF → packed glyph tables in game/ui/font_data.rb
│   └── mkdecoy.rb           # generate decoy Sudoku PDF + xochitl metadata
├── device/                  # install.sh, uninstall.sh, backup.sh, systemd units, xochitl drop-in
├── build_config/redoku.rb   # mruby cross-build config (device + host-linux targets)
└── test/                    # mruby tests (run on host-linux mruby in Docker)
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
- `RM2::Input.open(name)` → resolves the device path by scanning
  `/dev/input/event*` for the matching evdev name, then requests that path's
  fd from the server (`OpenInputDevice`); `#pending_events` decodes
  `input_event` structs and assembles per-SYN_REPORT samples into
  `[:pen, raw_x, raw_y, pressure, tool_state]` / `[:touch, ...]` arrays; `#fd`
  exposed for the Ruby select loop
- `RM2::Control.clients` / `.switch_to(pid)` — control-socket datagrams
- `RM2::Inotify.watch(path, mask)` / `#read_events` — for the watcher
- `RM2.setup_signals` — setsid, ignore SIGPIPE, SIGCONT/SIGTERM → flags
  polled from Ruby (`RM2.resumed?`, `RM2.terminated?`)

Everything above this line is Ruby.

### Ruby event loop

Single-threaded `IO.select` loop over the pen fd (touch fd optional later)
with a timeout that doubles as the recognition-idle timer:

1. Pen events → `InputRouter` maps raw→screen coordinates, classifies the
   target region (cell / button), and forwards to the active screen.
2. Pen-down inside a cell starts `StrokeCapture`: points buffered, ink echoed
   immediately as `draw_line` + DU updates (small dirty rects per segment).
3. Pen idle ≥ 500 ms after pen-up (or writing moves to another cell) →
   strokes for that cell go to the recognizer.
4. Recognizer verdict → cell ink region cleared, printed digit drawn (GL16),
   or rejection feedback (§6).
5. Buttons (New / Difficulty / Check / Quit) are pen-tap targets: a tap =
   pen-down+up with little movement and short duration.

### mruby build

mruby 4.0.0, pinned. Gembox: `default` minus unneeded bits, plus `mruby-io`,
`mruby-pack`, `mruby-math`, `mruby-random`, `mruby-time`, `mruby-sprintf`,
and our `mruby-rm2`. Two targets in `build_config/redoku.rb`:

- **device**: cross-compile with `/opt/x-tools/arm-remarkable-linux-gnueabihf`
  from `ghcr.io/toltec-dev/base:v4.0` (glibc 2.35, matched to firmware
  ≥ 3.18.2.3 — dynamic libc is safe; a static-musl fallback exists if that
  ever bites)
- **host-linux**: same gems compiled natively inside the container, used by
  the test suite and the fake display server

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
  - *Technique solver*: applies human techniques in escalating order — naked
    single, hidden single, naked/hidden pair, pointing pair/box-line. Used
    only for rating; records the hardest technique needed.
- **`Generator`** — fill an empty grid with the randomized backtracker; dig
  cell pairs (rotational symmetry) while the counting solver confirms
  uniqueness; stop at a target clue range.
- **`Rater`** — difficulty from the technique solver:
  - **Easy**: solvable with singles only, ≥ 36 clues
  - **Medium**: requires pairs/pointing, 28–35 clues
  - **Hard**: technique solver stalls (needs search), 24–30 clues
  - Generate-and-test: dig, rate, retry until the requested tier matches
    (a few hundred ms per attempt on the Cortex-A7 is fine; a "generating…"
    splash covers the pause).
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
  later without touching the renderer.
- Givens black; user entries dark gray (visually distinct); check-marks and
  reject-flash use inversion.
- Waveform discipline as in §3; a full GC16 refresh on screen transitions
  clears e-ink ghosting.

## 9. Build, deploy, test

**Make targets** (each a thin wrapper over Docker/ssh):

- `make build` — Docker: cross-compile rM2-stuff (server + xochitl shim +
  rm2fbctl, via their `release-toltec` CMake preset) and the `redoku` binary.
  rM2-stuff builds from the sibling fork checkout
  `../rM2-stuff` (github.com/QuirkQ/rM2-stuff, tracking upstream master,
  currently `4515770` — the exact commit this plan's protocol reference was
  verified against), mounted into the build container. Any 3.27.3.0 fixes we
  need land as commits on the fork, upstreamable later.
- `make deploy` — scp binaries + `device/` scripts to the device, run
  `install.sh` (idempotent)
- `make test` — Docker: host-linux mruby runs `test/` suites
- `make screenshot` / `make inject STROKES=…` — `tools/rmctl.rb` against
  device port 8888

**Testing strategy** (TDD per superpowers; the layering makes this natural):

1. **Unit (host, fast)**: sudoku engine, recognizer math, stroke
   classification, layout hit-testing — pure Ruby, no shim. Recognizer gets a
   corpus test: recorded strokes (captured once via `--record` during M3) must
   classify ≥ threshold accuracy; erase-gesture corpus likewise.
2. **Protocol (Docker)**: a ~100-line fake display server in Ruby (CRuby,
   Linux-only: unix sockets, memfd, SCM_RIGHTS) exercises the C shim:
   init handshake, update packing (y-first inclusive corners!), input fd
   passing, reconnect-on-EPIPE.
3. **Integration (device)**: scripted end-to-end via TCP 8888 — inject a
   recorded "write 5 in cell (3,4)" stroke sequence, pull a screenshot,
   assert the printed 5 appears in the right cell region. Semi-automated:
   run from the Mac, eyeball + a couple of pixel-region asserts.

**Device install (`device/install.sh`)**:

1. `backup.sh` first: tar `/home/root/.local/share/remarkable/xochitl` metadata
   (not the full content if huge — metadata + config), original
   `xochitl.service`, `/etc/version` → pulled back to the Mac.
2. Copy binaries to `/home/root/redoku/`, units to `/etc/systemd/system/`
   (`rm2fb.service` + `.socket`, later `redoku-watcher.service`).
3. Write `/etc/systemd/system/xochitl.service.d/10-rm2fb.conf` with
   `Environment=LD_PRELOAD=/home/root/redoku/lib/librm2fb_client_swtcon.so`.
4. `daemon-reload`, enable + start rm2fb socket, restart xochitl.

`uninstall.sh` reverses every step. Both scripts print what they do.

## 10. Milestones

**M0 — infrastructure gate (spike, throwaway allowed).** Build rm2fb from
master in Docker; install on device; verify on 3.27.3.0: (a) xochitl works
normally under the swtcon client shim — writing latency feels stock,
sleep/wake OK; (b) a ~60-line C hello-client paints rectangles and logs pen
coordinates; (c) `rm2fbctl switch` flips between xochitl and the hello client
cleanly. **Hard gate: if (a) fails we stop and decide** — options are the
rM2-stuff issue tracker, the 3.28 beta channel, or a codexctl downgrade to a
supported 3.23 build. Nothing beyond M0 starts until the gate passes.

**M1 — walking skeleton.** mruby cross-build + `mruby-rm2` shim; `redoku`
draws the empty board and echoes pen ink into cells; Quit button returns to
xochitl. Launched via SSH.

**M2 — sudoku engine.** Grid/Solver/Generator/Rater, fully host-tested.
Board renders generated puzzles with given digits.

**M3 — the game.** Recognizer + templates + `--record`; entries, erase
gesture, Check, difficulty menu, win screen, state persistence. This is the
"playable via SSH" release.

**M4 — the hijack.** Decoy document (`tools/mkdecoy.rb` generates the PDF +
`{uuid}.metadata`/`.content`, installed by script, one xochitl restart to
index). `redoku-watcher.service`: inotify `IN_OPEN` on the decoy's `.pdf`
content file, 5 s debounce, spawn game (its `Init` takes the screen
automatically). Quit: game switches front back to xochitl's pid (looked up
via `GetClients` by name) and exits. Fallback if `IN_OPEN` proves noisy or
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
