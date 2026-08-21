# reDoku

A handwritten sudoku game for the reMarkable 2, written in [mruby](https://mruby.org).
You'll tap an innocent-looking document in the stock library, a sudoku
appears, and you play by writing digits with the pen.

**Status:** early days. The display-client gem (`mruby-rm2`) and build
pipeline work; the game itself is not written yet. See [PLAN.md](PLAN.md)
for the full design and roadmap.

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

## Installing the display server on the device

Drawing goes through the
[rm2fb display server](https://github.com/timower/rM2-stuff) (swtcon
mode), which must run on the device. `bin/redoku` does the whole dance —
plug the device in over USB and run:

```bash
bin/redoku install
```

It takes the cross-built binaries from `build/rm2fb/dist/` (offering to
run `make rm2fb` first when they aren't built yet), double-checks they
really are 32-bit ARM, copies everything over, and runs
`device/install.sh` on the device. You'll be asked once for the device's
SSH password. Your `~/.ssh/config` is deliberately ignored so nothing in
it can interfere; if you have keys or aliases set up, add
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

## Running the checkerboard demo on the device

With the display server installed:

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
- `bin/redoku` — installs/uninstalls the display server on the device over SSH
- `device/` — install/uninstall scripts for the rm2fb display server (run on the device)
- `examples/` — demo scripts run with the cross-built `bin/mruby`
- `build_config.rb`, `docker/`, `Makefile` — the build pipeline
- `PLAN.md` — design document and roadmap
