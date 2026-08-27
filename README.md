# reDoku

[![rM2](https://img.shields.io/badge/rM2-supported-green)](https://remarkable.com)
[![rM1](https://img.shields.io/badge/rM1-not%20supported-lightgrey)](https://remarkable.com)
[![firmware](https://img.shields.io/badge/firmware-3.27.3.0%20tested-blue)](#before-you-start)
[![Casual Maintenance Intended](https://casuallymaintained.tech/badge.svg)](https://casuallymaintained.tech/)

A sudoku game for the reMarkable 2 that you play with the pen. Write digits
into the cells in your own handwriting, scribble candidate notes anywhere you
like, erase them with the back of the pen, then press `CHECK` and find out how
you did. Games are saved automatically, ink and all, and survive a reboot or a
flat battery.

It exists because I wanted to do sudoku on holiday, and the reMarkable is the
only screen I own that doesn't glow at me. It now works, so I do sudoku on it.
That was the entire success criterion, and it has been met.

<!-- TODO: photos of the real device belong here — the rM house style is 2-3
     held-in-hand JPGs at width="300" in raw <img> tags. -->

There are no screenshots yet.

## Vibe code alert (this section too)

Nearly all of this was written by LLMs — mostly Claude, with Kimi K3 and Oz
Alpha taking shifts — over a couple of days of evenings, with me directing,
reviewing, and playtesting. AI slop, lovingly supervised. I know what the
pieces do; I did not type most of them.

The convention is to label a disclosure like this one *(written by a human)*,
so you know which bytes to trust. I couldn't be bothered: an LLM wrote this
section as well. I read it, agreed with it, and left it in.

That's provenance, not an apology, and it has two visible consequences. The
comments are enormous: about 45% of the Ruby lines explain why the other 55%
is the way it is, because that's where the reasoning had to live to survive
the next session. And there is more design document than there is program —
some 15,000 lines of plan and design notes against roughly 9,300 lines of
Ruby and C. If you want to know why something is shaped the way it is, the
answer is almost certainly written down in [PLAN.md](PLAN.md) or
[docs/plans/](docs/plans/), including the parts that were tried and thrown
away.

Nothing here is an engineering flex. It's a holiday sudoku machine.

## Before you start

I'm not affiliated with reMarkable AS, and nothing here is endorsed by them.
You are fiddling with the internals of your own tablet at your own risk: there
may be bugs, and your device may misbehave. The only guarantee is that there's
no ill-intended code in here.

Two things to do first:

- **Write down your SSH password** and keep it somewhere safe. It's on the
  device under _Settings → Help → Copyrights and licenses_. Losing it is how
  people end up needing recovery help.
- **Check your firmware version.** This has been tested on **3.27.3.0** only.
  The installer refuses to run on anything else unless you pass `--force`.
  A firmware update wipes the install (and reverts you to stock), so if you
  want to keep it, keep auto-updates off.

What the install actually does, so you can decide how nervous to be: it _adds_
files, and only files — binaries under `/home/root/redoku/`, two systemd units
under `/etc/systemd/system/`. No kernel, boot, or partition changes. xochitl's
`LD_PRELOAD` is armed through an env file that exists only while the display
server runs, so a broken server means xochitl starts stock rather than
crash-looping. Failed installs roll themselves back, and SSH-over-USB never
depends on xochitl, so the uninstaller is always reachable.

If the device ever looks stuck: hold the power button for about 10 seconds.
It reboots, the display server disarms itself, and xochitl comes up stock.
Last resort is a firmware update, which reinstalls the root filesystem clean.

## Play it

### What you need

- Docker. Every build runs in a container; nothing gets installed on your
  machine. (The image is `linux/amd64`, so on an Apple Silicon Mac it runs
  emulated — the first build is a good moment to make coffee.)
- A reMarkable 2 on 3.27.3.0, plugged in over USB.
- Its SSH password, from _Settings → Help → Copyrights and licenses_.

There are no prebuilt downloads yet, so the path is: build it, then install it.
Dependencies fetch themselves — `make` clones the pinned
[mruby](https://github.com/mruby/mruby) and
[rM2-stuff](https://github.com/QuirkQ/rM2-stuff) into `tmp/` on first use, or
reuses sibling checkouts if you happen to have them (`MRUBY_DIR=` /
`RM2STUFF_DIR=` to point elsewhere).

### 1. Build

```bash
make build   # the game, cross-compiled to armv7 → build/rm2/bin/
make rm2fb   # the display server → build/rm2fb/dist/
```

Drawing on an rM2 goes through the
[rm2fb display server](https://github.com/timower/rM2-stuff) (swtcon mode),
which has to run on the device. That's what `make rm2fb` is for. If you skip
it, `install` will offer to run it for you.

### 2. Install

```bash
bin/redoku install
```

That's the whole dance: it takes the display server from
`build/rm2fb/dist/` and the game from `build/rm2/bin/redoku`, double-checks
they really are 32-bit ARM before they leave your machine, copies everything
over, and runs the on-device installer. You'll be asked once for the SSH
password (the connection is then held open for two minutes, so back-to-back
commands only ask once).

Re-running it is always safe: the same files land in the same places and the
device ends up in the same state, so there's no "repair" mode to learn.

Your `~/.ssh/config` is deliberately ignored so nothing in it can interfere.
If you use keys or host aliases, add `--ssh-config ~/.ssh/config`.
`bin/redoku --help` lists everything; `--dry-run` shows the plan without
touching the device.

### 3. Play

```bash
bin/redoku play
```

The board appears on the panel and the pen leaves ink in it. To get out of the
game, press `QUIT` — the game closes its display connection and the screen
goes back to xochitl.

### 4. Go back to stock

```bash
bin/redoku uninstall            # add --purge to also delete /home/root/redoku
```

`bin/redoku status` shows what's running on the device, and `bin/redoku shell`
drops you into an SSH session on it.

## Playing

Five buttons around the board:

| Button     | What it does                                                                  |
| ---------- | ----------------------------------------------------------------------------- |
| `NEW`      | Deals a fresh puzzle at the current difficulty. Discards the board you're on. |
| `LEVEL...` | Opens the difficulty picker. Every row deals a new board at that level.       |
| `CHECK`    | Reads every inked cell and marks it — the only moment ink is read.            |
| `SAVES`    | The saved-games list: resume, keep a manual copy, or delete.                  |
| `QUIT`     | Hands the screen back to xochitl.                                             |

The board is a **free drawing surface** for the whole game. Answers, candidate
notes, stencil marks — it's all just ink, and it's all persisted. Erase with
the back of the pen, exactly as you would in a notebook. Nothing is judged
until you press `CHECK`, at which point whatever ink sits in a cell is read as
your answer. Cells it can't read are marked as unreadable rather than wrong.
Solve the thing and you get a win screen, which is withheld unless the board
really is solved.

Difficulty comes in five tiers — `EASY`, `MEDIUM`, `HARD`, `EXPERT`, `MASTER` —
gated on the solving techniques a puzzle actually requires, not on how many
digits are pre-filled. (The first version graded on given-count, I played it,
and every "medium" board fell to the same singles as "easy". That rework is
[written up](docs/design/difficulty-rating.md) if you're curious.) Generating a
hard board takes a visible moment on the device's Cortex-A7, hence the
`GENERATING...` splash.

Every game is auto-saved the instant it's dealt and again on quit, with every
completed stroke journaled alongside it, so a power loss or a reboot resumes
exactly where you were — your handwriting included. Saves live in a SQLite
database at `/home/root/redoku/games.db`, which survives firmware updates.
Deleting that file (or `uninstall --purge`) takes the saves with it.

## Making it read your handwriting

The shipped digit templates were authored by hand and then tuned against
exactly one person's writing: mine. It reads my 7s beautifully. It has never
seen yours.

So teach it:

```bash
ssh -t root@10.11.99.1 /home/root/redoku/bin/redoku --record
```

It takes the panel itself, so run it with the display server up and the game
closed. It walks you through writing 1–9 four times each — 36 samples,
round-major, so your hand doesn't drift into a stylised version of whichever
digit it's drilling — and saves the result to
`/home/root/redoku/templates.local`. The recognizer loads that on top of the
built-in set on every launch. If `CHECK` keeps misreading a digit, this is the
fix. Interrupting halfway keeps the samples you did write.

## What works, and what doesn't

Works: generating and rating puzzles across five tiers, drawing and erasing,
batch recognition at `CHECK`, unreadable cells, the win screen, autosave,
manual saves, the saves list, and ink that survives quit, relaunch and a
battery pull.

Doesn't, or not yet:

- **You start the game over SSH.** The nice version — you tap an
  innocent-looking document in the stock library and sudoku appears instead —
  is [milestone M4](M4-HIJACK.md). The primitives it needs (inotify, detached
  spawn, a SIGHUP latch) have landed; the watcher and the decoy document
  haven't.
- **The recognizer knows one hand** — see the section above. Accuracy numbers
  anywhere in this repo describe authored templates plus jitter, not a
  stranger's handwriting.
- **Generation time on the device is unmeasured.** It's fine in practice,
  which is a subjective judgement and not a number.
- **Palm rejection is unverified.** It hasn't caused me a problem; it also
  hasn't been tested.
- **The digits are a placeholder face** — a 14× upscale of a built-in 5×7
  table. Legible enough that I stopped noticing.
- **No timer, no undo, no printed pencil marks, no landscape.** These are in
  the parking lot in [PLAN.md](PLAN.md) §10 and may stay there forever.

`PLAN.md` tracks per-milestone what has been witnessed on real hardware versus
what is host-tested only, in more detail than any sane person wants.

## Develop

The build is entirely containerised, and most of the game is testable without
a tablet anywhere near you:

```bash
make test    # host build + the full mrbtest suite, in Docker — the main loop
make build   # cross-compile armv7 binaries into build/rm2/bin/
make rm2fb   # cross-compile the rm2fb display server into build/rm2fb/dist/
make shell   # a shell inside the build container
make clean   # drop build/ and the config lock
```

`make test` is the loop you'll live in. Tests sit next to their gems in
`mrbgems/*/test/*.rb` and run under mrbtest; the design deliberately keeps the
pen, ink, recognizer, renderer, generator, rater and store host-testable, and
the display client is tested against a `fake_server.c` rather than hardware.
Roughly 9,800 lines of test to 7,000 lines of library, which tells you what
kind of project it became.

On-device iteration is a two-step:

```bash
make build
bin/redoku play --seconds 10   # run unattended for 10s — quickest smoke test
```

`play` only ever copies the game binary, so rebuilding never disturbs the
display server. `redoku --clients` (a mode that never touches the screen) lists
the display server's clients, which is how you tell who owns the panel:

```bash
ssh root@10.11.99.1 /home/root/redoku/bin/redoku --clients
```

There's also a standalone demo, useful for proving the toolchain before you
trust it:

```bash
scp build/rm2/bin/mruby examples/checkerboard.rb root@10.11.99.1:/home/root/
ssh -t root@10.11.99.1 '/home/root/mruby /home/root/checkerboard.rb'
```

A full-screen checkerboard flashes onto the panel. Without the display server
running you can still sanity-check the cross build with the REPL — `scp` over
`build/rm2/bin/mirb`, run it, and try `RM2::GC16` (it should answer `61442`).

### Layout

- `mrbgems/mruby-rm2/` — the display and input client.
  [Its README](mrbgems/mruby-rm2/README.md) documents the API, the waveforms,
  and the process-lifecycle rules the display server imposes.
- `mrbgems/mruby-redoku/` — the game: layout, rendering, pen and touch
  handling, ink, recognizer, sudoku engine, store, event loop.
- `mrbgems/mruby-sqlite3/` — SQLite bindings
  ([README](mrbgems/mruby-sqlite3/README.md)); the amalgamation is vendored
  and pinned.
- `mrbgems/mruby-bin-redoku/` — the `redoku` executable, a `main` that calls
  `Redoku.main`.
- `bin/redoku` — the host-side installer/runner (POSIX sh, talks SSH).
- `device/` — install and uninstall scripts that run on the tablet.
- `examples/` — demos run with the cross-built `bin/mruby`.
- `build_config.rb`, `docker/`, `Makefile` — the build pipeline.
- `PLAN.md`, `docs/design/`, `docs/plans/` — the design record.

### Conventions

Plan first, in `docs/plans/`, then implement; when a plan turns out to be
wrong, the wrong reasoning stays on the record with an annotation saying what
killed it. Commits are [Conventional Commits](https://www.conventionalcommits.org/)
— release-please keeps a release PR open from them, and merging it tags a
release and attaches cross-built binaries. CI runs `make build` and `make test`
on every push.

## Status and maintenance

[Casual maintenance intended](https://casuallymaintained.tech/). I still do
sudoku on this thing, so if it breaks in a way that stops me playing, I'll
probably fix it. Anything else may sit untouched for a very long time, and I
might well stop here — M4 is the last thing I definitely want. That's the
honest version; treating it as a promise would be the dishonest one.

Issues and pull requests are welcome and may or may not be looked at. Smaller
is much better. It's AGPL, so forking is entirely fine — if this project's real
value to you is as a starting point, take it.

Prior art worth knowing about:
[remarkable-sudoku](https://github.com/HookedBehemoth/remarkable-sudoku) is an
older, much smaller sudoku for the reMarkable, installable from Toltec.
If you want puzzles on your tablet without building anything, start there.

## Credits

- [timower's rM2-stuff](https://github.com/timower/rM2-stuff) — the rm2fb
  display server this whole thing stands on. Built here from a
  [pinned fork](https://github.com/QuirkQ/rM2-stuff).
- [mruby](https://mruby.org) — small enough to cross-compile without drama.
- [SQLite](https://www.sqlite.org) — for saves that survive a battery pull.
- [Toltec](https://github.com/toltec-dev/toltec) — the ARM toolchain.
- The [reMarkable hacking community](https://github.com/reHackable/awesome-reMarkable),
  whose accumulated knowledge is the reason step 1 wasn't "brick the tablet".

## License

reDoku is free software, licensed under the
[GNU Affero General Public License v3.0](LICENSE) or (at your option) any
later version (`AGPL-3.0-or-later`).

Anyone may use, study, modify, and share it — but if a company (say
reMarkable, shipping it as part of their product) distributes it or a modified
version, they must pass those same freedoms on: the complete corresponding
source, under the same license. If that's a problem for you, get in touch and
we can talk about a commercial license.
