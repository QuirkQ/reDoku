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

## Running the checkerboard demo on the device

The demo draws to the screen through the
[rm2fb display server](https://github.com/timower/rM2-stuff) — the rM2 has
no kernel framebuffer, so **the server must be running on the device
first**. Installing it is Milestone 0 in [PLAN.md](PLAN.md) and isn't
scripted yet; until then the demo will raise a connect error (harmless).

Once you have SSH access:

```bash
make build
scp build/rm2/bin/mruby examples/checkerboard.rb root@10.11.99.1:/home/root/
ssh -t root@10.11.99.1 '/home/root/mruby /home/root/checkerboard.rb'
```

With the display server running you'll see a full-screen checkerboard
flash onto the e-ink panel. Without any display server you can still
sanity-check the toolchain with the REPL:

```bash
scp build/rm2/bin/mirb root@10.11.99.1:/home/root/
ssh -t root@10.11.99.1 /home/root/mirb    # try: RM2::GC16  =>  61442
```

## Repository layout

- `mrbgems/mruby-rm2/` — the display-client gem ([its README](mrbgems/mruby-rm2/README.md) documents the API)
- `examples/` — demo scripts run with the cross-built `bin/mruby`
- `build_config.rb`, `docker/`, `Makefile` — the build pipeline
- `PLAN.md` — design document and roadmap
