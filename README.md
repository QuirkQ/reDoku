# reDoku

[![rM2](https://img.shields.io/badge/rM2-supported-green)](https://remarkable.com)
[![rM1](https://img.shields.io/badge/rM1-not%20supported-lightgrey)](https://remarkable.com)
[![firmware](https://img.shields.io/badge/firmware-3.27.3.0%20tested-blue)](#before-you-start)
[![Casual Maintenance Intended](https://casuallymaintained.tech/badge.svg)](https://casuallymaintained.tech/)

Sudoku for the reMarkable 2, played with the pen: write digits into the cells,
scribble notes anywhere you like, erase with the back of the pen, press
`CHECK`. Games autosave with your ink and survive a reboot or a flat battery.

It exists because I wanted to do sudoku on holiday and the reMarkable is the
only screen I own that doesn't glow at me. It works, so I do sudoku on it.
That was the whole success criterion.

<!-- TODO: photos of the real device belong here — the rM house style is 2-3
     held-in-hand JPGs at width="300" in raw <img> tags. -->

There are no screenshots yet.

## Vibe code alert (this section too)

Nearly all of this was written by LLMs — mostly Claude, with Kimi K3 and Oz
Alpha taking shifts — over a couple of days of evenings, with me directing,
reviewing and playtesting. AI slop, lovingly supervised.

The convention is to label a disclosure like this one *(written by a human)*,
so you know which bytes to trust. I couldn't be bothered: an LLM wrote this
section as well. I read it, agreed with it, and left it in.

Not an engineering flex, then — a holiday sudoku machine. Why anything is
shaped the way it is lives in [PLAN.md](PLAN.md) and [docs/plans/](docs/plans/),
which together run longer than the program.

## Before you start

I'm not affiliated with reMarkable AS. You're poking at your own tablet's
internals at your own risk; the only guarantee is that there's no ill-intended
code in here.

- **Write down your SSH password** first — *Settings → Help → Copyrights and
  licenses*.
- **Tested on firmware 3.27.3.0 only.** The installer refuses anything else
  without `--force`. A firmware update wipes every unit under
  `/etc/systemd/system/` — the display server, the xochitl drop-in, and the
  hijack watcher alike — reverting you to stock: `/home/root/redoku/` (saves
  included) survives, but nothing in it runs, the decoy document in the
  library goes back to being just a PDF, and launch is SSH-only again until
  you reinstall. Stock behaviour, by design — keep auto-updates off.

The install only *adds* files: `/home/root/redoku/`, the decoy document in
xochitl's own library, and three systemd units. No kernel, boot or partition
changes, failures roll themselves back, and xochitl comes up stock if the
display server is broken. If the device ever looks stuck, hold power for
~10 s. SSH-over-USB never depends on xochitl, so the uninstaller is always
reachable.

## Play it

An rM2 on 3.27.3.0 plugged in over USB, `curl`, and any one of `shasum`,
`sha256sum` or `openssl` — with no way to check a download, the installer
refuses to fetch one at all. Then one line:

```bash
curl -fsSL https://github.com/QuirkQ/reDoku/releases/latest/download/install.sh | sh
```

It fetches the host CLI, checks it against the checksum published beside it,
and hands over to `redoku install --download --kit ~/.redoku`: the release kit
lands in `~/.redoku`, `~/.redoku/current` points at it, and a two-line
`redoku` wrapper goes in `~/.local/bin`. If that directory isn't on your
`PATH`, it prints the `export` line for you to add — it never edits a shell rc
file behind your back. Then it asks before touching the device.

```bash
redoku play              # play
redoku status            # the device, and which kit this machine has
redoku upgrade           # newer release into the kit ('install' puts it on the device)
redoku uninstall         # device back to stock (--purge also deletes the saves)
redoku uninstall --self  # ...and remove the kit and the PATH entry from here
```

**What the checksum proves.** It ships in the same release as the tarball, so
it proves the bytes arrived intact — not that the release is authentic:
whoever could publish a bad tarball could publish its checksum too. A detached
[minisign](https://jedisct1.github.io/minisign/) signature would be real
protection against that, and it costs a private key that must never be lost, a
signing step in every release, and `minisign` on your machine — for a casually
maintained holiday sudoku machine, this paragraph is the better trade. What
the checks do buy: nothing unverified is ever unpacked or run, every binary is
checked to really be 32-bit ARM before it leaves your machine, and any archive
entry whose name is absolute, holds `..`, or doesn't start `redoku/` is
refused outright — though that reads entry *names*, not symlink and hardlink
*targets*, so it is the checksum, not the guard, standing behind the archive.

**Rather read the script first?** The CLI is published as its own asset, so
nothing has to run straight out of a pipe:

```bash
curl -fsSLO https://github.com/QuirkQ/reDoku/releases/latest/download/redoku
curl -fsSLO https://github.com/QuirkQ/reDoku/releases/latest/download/redoku.sha256
shasum -a 256 -c redoku.sha256   # or: sha256sum -c redoku.sha256
less redoku
sh redoku install --download --kit ~/.redoku
```

**Or build it yourself.** You need Docker (every build runs in a container —
it's `linux/amd64`, so expect emulation on an Apple Silicon Mac).

```bash
make build          # the game            → build/rm2/bin/
make rm2fb          # the display server  → build/rm2fb/dist/
bin/redoku install  # copy both over, run the on-device installer
bin/redoku play     # play
```

Drawing on an rM2 goes through the
[rm2fb display server](https://github.com/timower/rM2-stuff), which has to run
on the device — that's `make rm2fb`. You'll be asked for the SSH password once,
and `install` is safe to re-run from any state. Back to stock:
`bin/redoku uninstall` (`--purge` also deletes the saves). See also
`bin/redoku status`, `shell`, `--dry-run` and `--help`.

## Playing

`NEW` deals a puzzle, `LEVEL...` picks one of five technique-gated tiers
(`EASY` → `MASTER`), `CHECK` reads your ink and marks it, `SAVES` lists saved
games, `QUIT` hands the screen back to xochitl. Until you press `CHECK` the
board is just a drawing surface — answers, candidate notes, scratch, all
persisted, all erasable. Cells it can't read are marked unreadable rather than
wrong. Saves live in SQLite at `/home/root/redoku/games.db` and survive
firmware updates.

**Teach it your handwriting.** The shipped digit templates were tuned against
exactly one hand: mine.

```bash
ssh -t root@10.11.99.1 /home/root/redoku/bin/redoku --record
```

Nine digits, four rounds, saved to `templates.local` and loaded on top of the
built-ins at every launch. If `CHECK` keeps misreading a digit, this is the fix.

## Not working yet

- **You launch it over SSH.** The nice version — tap an innocent-looking
  document in the stock library and sudoku appears — is [M4](M4-HIJACK.md).
  Its primitives have landed; the watcher hasn't.
- **The recognizer knows one hand** (see above). Accuracy numbers in this repo
  describe authored templates, not a stranger's handwriting.
- **Palm rejection is unverified, generation timing on-device is unmeasured,
  and the digits are a placeholder font.** No timer, undo, printed pencil
  marks or landscape.

`PLAN.md` records, per milestone, what has been witnessed on real hardware
versus host-tested only.

## Develop

```bash
make test    # host build + the full mrbtest suite, in Docker — the main loop
make build   # cross-compile armv7 → build/rm2/bin/
make shell   # a shell in the build container
```

Most of the game is deliberately host-testable — pen, ink, recognizer,
renderer, generator, rater and store, with the display client running against
a fake server — so `make test` is the loop you live in. Tests sit next to
their gems in `mrbgems/*/test/`. For on-device iteration,
`make build && bin/redoku play --seconds 10`: `play` only copies the game
binary, so the display server stays up. `redoku --clients` says who owns the
panel.

The gems are `mruby-rm2` (display and input,
[API docs](mrbgems/mruby-rm2/README.md)), `mruby-redoku` (the game),
`mruby-sqlite3` ([bindings](mrbgems/mruby-sqlite3/README.md)) and
`mruby-bin-redoku` (the executable); `bin/redoku` and `device/` are the
install scripts. Convention is plan first in `docs/plans/`, then implement,
keeping what got rejected on the record. Conventional commits, release-please,
and CI runs build + test.

## Status

[Casual maintenance intended](https://casuallymaintained.tech/). I still do
sudoku on this thing, so if it breaks in a way that stops me playing I'll
probably fix it; anything else may sit untouched for a long time. Issues and
PRs are welcome and may or may not be looked at.

Prior art: [remarkable-sudoku](https://github.com/HookedBehemoth/remarkable-sudoku)
is older, much smaller, and installable from Toltec.

Standing on: [rM2-stuff](https://github.com/timower/rM2-stuff) (rm2fb, built
from a [pinned fork](https://github.com/QuirkQ/rM2-stuff)),
[mruby](https://mruby.org), [SQLite](https://www.sqlite.org),
[Toltec](https://github.com/toltec-dev/toltec)'s toolchain, and the
[reMarkable hacking community](https://github.com/reHackable/awesome-reMarkable),
who are the reason step 1 wasn't "brick the tablet".

## License

[AGPL-3.0-or-later](LICENSE). Anyone may use, study, modify and share it — but
a company distributing it (say reMarkable, shipping it in their product) has
to pass those freedoms on, complete source included. If that's a problem, get
in touch and we can talk about a commercial license.
