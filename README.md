# reDoku

A handwritten sudoku game for the reMarkable 2, written in [mruby](https://mruby.org).
You'll tap an innocent-looking document in the stock library, a sudoku
appears, and you play by writing digits with the pen.

**Status:** early days. The walking skeleton is in: `redoku` draws the
board, echoes pen ink into it, and hands the screen back on Quit — no
puzzles yet, and the pen path is still awaiting its first run on real
hardware. See [PLAN.md](PLAN.md) for the full design and roadmap.

## License

reDoku is free software, licensed under the
[GNU Affero General Public License v3.0](LICENSE) or (at your option) any
later version (`AGPL-3.0-or-later`).

That means anyone may use, study, modify, and share it — but if a company
(for example reMarkable, shipping it as part of their product) distributes
it or a modified version, they must pass those same freedoms on: the
complete corresponding source, under the same license. If that's a problem
for you, get in touch and we can talk about a commercial license.

## Prerequisites

- Docker (all builds run in a container; nothing is installed on your machine)
- A reMarkable 2 connected via USB; its SSH password is shown on the
  device under Settings → Help → Copyrights and licenses

The source dependencies take care of themselves: `make` uses an
[mruby](https://github.com/mruby/mruby) or
[rM2-stuff](https://github.com/QuirkQ/rM2-stuff) checkout sitting next
to this repo when one exists (override with `MRUBY_DIR=` /
`RM2STUFF_DIR=`), and otherwise clones the pinned versions into `tmp/`
(gitignored) on first use.

## Build & test

```bash
make test    # host build + full mrbtest suite (in Docker)
make build   # also cross-compiles armv7 binaries into build/rm2/bin/
make rm2fb   # cross-compiles the display server into build/rm2fb/dist/
```

## Installing on the device

Drawing goes through the
[rm2fb display server](https://github.com/timower/rM2-stuff) (swtcon
mode), which must run on the device. `bin/redoku` does the whole dance —
plug the device in over USB and run:

```bash
make build           # the game binary; install offers to build the server
bin/redoku install
```

It takes the cross-built display server from `build/rm2fb/dist/`
(offering to run `make rm2fb` first when it isn't built yet) and the game
from `build/rm2/bin/redoku`, double-checks they really are 32-bit ARM,
copies everything over, and runs `device/install.sh` on the device. The
game is optional here: when it hasn't been cross-built, `install` says so
and puts the display server on by itself. Re-running it is safe from any
state: the same files land in the same places and the device ends up in
the same working state, so there is no "repair" path to learn. You'll be
asked once for the device's SSH password. Your `~/.ssh/config` is
deliberately ignored so nothing in it can interfere; if you have keys or
aliases set up, add
`--ssh-config ~/.ssh/config`. See `bin/redoku --help` for all options
(`--dry-run` shows the plan without touching anything).

Back to stock (add `--purge` to also delete `/home/root/redoku`):

```bash
bin/redoku uninstall
```

`bin/redoku status` shows what's running on the device, and
`bin/redoku shell` drops you into an SSH session there.

The install only *adds* files — binaries under `/home/root/redoku/`, two
systemd files under `/etc/systemd/system/`. No kernel, boot, or
partition changes, and SSH over USB never depends on xochitl, so the
uninstaller is always reachable. xochitl's `LD_PRELOAD` is armed via an
env file that exists only while the server is running, so a broken
server means xochitl starts stock instead of crash-looping; install
failures roll back automatically, and a firmware update wipes the
systemd files, reverting to stock by itself.

If the device seems unresponsive, hold the power button ~10 s to force a
reboot — a broken display server disarms itself and xochitl boots stock.
Last resort: a firmware update reinstalls the root filesystem clean.

## Running on the device

```bash
bin/redoku play      # refresh the game binary from build/rm2/bin/, then run it
```

The board appears on the e-ink panel and pen strokes leave ink inside it:
`New` clears the ink, `Level` cycles the difficulty label, and `Quit`
closes the display connection, which hands the screen back to xochitl.

Every game is auto-saved the moment it is dealt (and again on quit), so a
power loss or reboot resumes exactly where you left off. `GAMES` opens the
saves list: tap a row to resume that game, arm `DEL` and tap a row to delete
it, or press `SAVE` to keep a manual copy you can come back to later. Saves
live in a SQLite database at `/home/root/redoku/games.db`, which survives
firmware updates; removing it (or `bin/redoku uninstall --purge`) removes
the saves with everything else.

`play` only ever copies that one binary, so a rebuild reaches the device
without disturbing the display server; `bin/redoku play --seconds 10`
runs the game unattended for ten seconds instead of waiting for you,
which is the quickest way to smoke-test a build.

The binary has a second mode that never touches the screen —
`redoku --clients` lists the display server's clients:

```bash
ssh root@10.11.99.1 /home/root/redoku/bin/redoku --clients
```

### The checkerboard demo

```bash
make build
scp build/rm2/bin/mruby examples/checkerboard.rb root@10.11.99.1:/home/root/
ssh -t root@10.11.99.1 '/home/root/mruby /home/root/checkerboard.rb'
```

You'll see a full-screen checkerboard flash onto the e-ink panel.
Without the display server you can still sanity-check the toolchain
with the REPL:

```bash
scp build/rm2/bin/mirb root@10.11.99.1:/home/root/
ssh -t root@10.11.99.1 /home/root/mirb    # try: RM2::GC16  =>  61442
```

## Repository layout

- `mrbgems/mruby-rm2/` — the display-client gem ([its README](mrbgems/mruby-rm2/README.md) documents the API)
- `mrbgems/mruby-redoku/` — the game: layout, rendering, pen handling, event loop
- `mrbgems/mruby-bin-redoku/` — the `redoku` executable (a `main` that calls `Redoku.main`)
- `bin/redoku` — installs, runs, and uninstalls reDoku on the device over SSH
- `device/` — install/uninstall scripts for the rm2fb display server (run on the device)
- `examples/` — demo scripts run with the cross-built `bin/mruby`
- `build_config.rb`, `docker/`, `Makefile` — the build pipeline
- `PLAN.md` — design document and roadmap
