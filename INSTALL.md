# Installing reDoku

The short version lives in the [README](README.md#play-it): plug the tablet in
over USB and pipe one script into `sh`. This file is for everyone who wants to
look before they leap, install without the network, or build the whole thing
themselves.

- [What you need](#what-you-need)
- [The one-liner, and what it actually does](#the-one-liner-and-what-it-actually-does)
- [Reading the script first](#reading-the-script-first)
- [What the checksum proves](#what-the-checksum-proves)
- [Installing without the network](#installing-without-the-network)
- [Building it yourself](#building-it-yourself)
- [Firmware](#firmware)
- [Uninstalling](#uninstalling)

## What you need

- A **reMarkable 2** on firmware **3.27.3.0**, plugged in over USB. No rM1
  support — the display path is rM2-only.
- Its **SSH password**, from *Settings → Help → Copyrights and licenses*.
  Write it down before you start.
- `curl`, and **any one of** `shasum`, `sha256sum` or `openssl`. With no way to
  check a download, the installer refuses to fetch one at all rather than
  unpack bytes it can't verify.

## The one-liner, and what it actually does

```bash
curl -fsSL https://github.com/QuirkQ/reDoku/releases/latest/download/install.sh | sh
```

`install.sh` is deliberately the only file that runs unverified — it's what you
piped, and nothing it downloads is used before its checksum matches. It fetches
the host CLI, checks it against `redoku.sha256` published in the same release,
and hands over to `redoku install --download --kit ~/.redoku`. That:

- unpacks the release **kit** into `~/.redoku/<tag>/` and points
  `~/.redoku/current` at it;
- writes a two-line `redoku` wrapper into `~/.local/bin`;
- if that directory isn't on your `PATH`, **prints** the `export` line for you
  to add. No shell rc file is ever edited behind your back, and a `redoku`
  already sitting there that this installer didn't write is left exactly as it
  is;
- **then asks** before it touches the device.

A kit ships all four device pieces prebuilt: the rm2fb display server, the game
binary, the decoy "Sudoku" document, and the watcher that launches the game when
you tap it.

Useful knobs — `redoku --help` is the full list:

| | |
|---|---|
| `--kit DIR` / `$REDOKU_HOME` | where the kit lives (the one-liner passes `~/.redoku`) |
| `--bin-dir DIR` / `$REDOKU_BIN_DIR` | where the `PATH` entry goes (default `~/.local/bin`) |
| `--no-symlink` | write no `PATH` entry at all |
| `$REDOKU_VERSION` | pin a release tag instead of taking the latest |
| `$REDOKU_BASE_URL` | fetch from a fork, a mirror, or a `file://` directory |
| `-n`, `--dry-run` | show what would happen without touching anything |

Keeping it current: `redoku upgrade` fetches the newest release into the kit,
repoints `current`, and keeps the version it pointed at before — so a rollback
is one symlink swap. It's host-side only and never opens an SSH connection; run
`redoku install` afterwards to put the new version on the device.

## Reading the script first

The CLI is published as its own release asset, so nothing has to run straight
out of a pipe:

```bash
curl -fsSLO https://github.com/QuirkQ/reDoku/releases/latest/download/redoku
curl -fsSLO https://github.com/QuirkQ/reDoku/releases/latest/download/redoku.sha256
shasum -a 256 -c redoku.sha256   # or: sha256sum -c redoku.sha256
less redoku
sh redoku install --download --kit ~/.redoku
```

## What the checksum proves

It ships in the same release as the tarball, so it proves **the bytes arrived
intact — not that the release is authentic**: whoever could publish a bad
tarball could publish its checksum too.

A detached [minisign](https://jedisct1.github.io/minisign/) signature would be
real protection against that, and it costs a private key that must never be
lost, a signing step in every release, and `minisign` on your machine. For a
casually maintained holiday sudoku machine, this paragraph is the better trade.

What the checks *do* buy:

- nothing unverified is ever unpacked or run;
- every binary is checked to really be 32-bit ARM — by reading its header —
  before it leaves your machine;
- any archive entry whose name is absolute, contains `..`, or doesn't start
  `redoku/` is refused outright.

That last guard reads entry *names*, not symlink and hardlink *targets*, so it
is the checksum, not the guard, standing behind the archive.

## Installing without the network

Point the CLI at binaries you already have:

```bash
redoku install --artifacts DIR
```

Or set `$REDOKU_BASE_URL` to a `file://` directory holding the release assets
and the normal download path works offline.

## Building it yourself

You need Docker. Every build runs in a container, and it's `linux/amd64`, so
expect emulation on an Apple Silicon Mac.

```bash
make build          # the game            → build/rm2/bin/
make rm2fb          # the display server  → build/rm2fb/dist/
bin/redoku install  # copy both over, run the on-device installer
bin/redoku play     # launch it over SSH
```

Drawing on an rM2 goes through the
[rm2fb display server](https://github.com/timower/rM2-stuff), which has to run
on the device — that's `make rm2fb`, built from a
[pinned fork](https://github.com/QuirkQ/rM2-stuff). You'll be asked for the SSH
password once, and `install` is safe to re-run from any state.

In a checkout the game is whatever `make build` last produced; `install` warns
and puts everything else on alone when there isn't one. See also
`bin/redoku status`, `shell`, `--dry-run` and `--help`, and
[CONTRIBUTING.md](CONTRIBUTING.md) for the development loop.

## Firmware

**3.27.3.0 is the only version this has been tested on.** The installer refuses
anything else without `--force`.

A firmware update wipes every unit under `/etc/systemd/system/` — the display
server, the xochitl drop-in and the watcher alike — reverting you to stock.
`/home/root/redoku/` and your saves survive, but nothing in it runs, the decoy
document goes back to being just a PDF, and launch is SSH-only again until you
reinstall. That's stock behaviour by design, so keep auto-updates off.

## Uninstalling

```bash
redoku uninstall          # device back to stock
redoku uninstall --purge  # ...and delete /home/root/redoku, saves included
redoku uninstall --self   # ...and remove the kit and PATH entry from this machine
```

`uninstall` always takes the decoy and its watcher back out together — a
document that launches nothing is worse than no document. It's idempotent, and
SSH-over-USB never depends on xochitl, so it stays reachable even if the
display server is broken. If the device ever looks stuck, hold power for ~10 s:
it reboots, and a broken display server disarms itself.
