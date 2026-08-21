# reDoku

A handwritten sudoku game for the reMarkable 2, written in [mruby](https://mruby.org).
You'll tap an innocent-looking document in the stock library, a sudoku
appears, and you play by writing digits with the pen.

**Status:** early days. The display-client gem (`mruby-rm2`) and build
pipeline work; the game itself is not written yet. See [PLAN.md](PLAN.md)
for the full design and roadmap.

## Prerequisites

- Docker (all builds run in a container; nothing is installed on your machine)
- An [mruby](https://github.com/mruby/mruby) checkout next to this repo —
  the build expects `../mruby` by default (override with
  `make MRUBY_DIR=/path/to/mruby …`):

  ```bash
  git clone --branch 4.0.0 https://github.com/mruby/mruby.git ../mruby
  ```

- Only for running on the device later (Milestone 0, not needed for
  `make build`/`make test`): the
  [rM2-stuff](https://github.com/timower/rM2-stuff) display server as
  `../rM2-stuff`
- A reMarkable 2 reachable over SSH: connect it via USB and use
  `root@10.11.99.1`; the password is shown on the device under
  Settings → Help → Copyrights and licenses

## Build & test

```bash
make test    # host build + full mrbtest suite (in Docker)
make build   # also cross-compiles armv7 binaries into build/rm2/bin/
```

## Installing the display server on the device

Drawing goes through the
[rm2fb display server](https://github.com/timower/rM2-stuff) (swtcon
mode), which must run on the device. `device/install.sh` sets it up;
`device/uninstall.sh` returns the device to stock.

The install only *adds* files — binaries under `/home/root/redoku/`, two
systemd files under `/etc/systemd/system/`. No kernel, boot, or
partition changes, and SSH over USB never depends on xochitl, so the
uninstaller is always reachable. xochitl's `LD_PRELOAD` is armed via an
env file that exists only while the server is running, so a broken
server means xochitl starts stock instead of crash-looping; install
failures roll back automatically, and a firmware update wipes the
systemd files, reverting to stock by itself.

Build the armv7 binaries (`rm2fb_server_swtcon`,
`librm2fb_client_swtcon.so`, `rm2fbctl` — the Docker build isn't in the
Makefile yet), then deploy and install:

```bash
ssh root@10.11.99.1 'mkdir -p /home/root/redoku/bin /home/root/redoku/lib'
scp rm2fb_server_swtcon rm2fbctl root@10.11.99.1:/home/root/redoku/bin/
scp librm2fb_client_swtcon.so root@10.11.99.1:/home/root/redoku/lib/
scp device/install.sh device/uninstall.sh root@10.11.99.1:/home/root/redoku/
ssh root@10.11.99.1 'sh /home/root/redoku/install.sh'
```

Back to stock (add `--purge` to also delete `/home/root/redoku`):

```bash
ssh root@10.11.99.1 'sh /home/root/redoku/uninstall.sh'
```

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
- `device/` — install/uninstall scripts for the rm2fb display server (run on the device)
- `examples/` — demo scripts run with the cross-built `bin/mruby`
- `build_config.rb`, `docker/`, `Makefile` — the build pipeline
- `PLAN.md` — design document and roadmap
