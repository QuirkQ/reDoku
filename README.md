# reDoku

[![rM2](https://img.shields.io/badge/rM2-supported-green)](https://remarkable.com)
[![rM1](https://img.shields.io/badge/rM1-not%20supported-lightgrey)](https://remarkable.com)
[![firmware](https://img.shields.io/badge/firmware-3.27.3.0%20tested-blue)](#before-you-start)
[![Casual Maintenance Intended](https://casuallymaintained.tech/badge.svg)](https://casuallymaintained.tech/)

Sudoku for the reMarkable 2, played with the pen. Tap a document called
**Sudoku** in the stock library and the board takes the screen: write digits
into the cells, scribble notes anywhere you like, erase with the back of the
pen, press `CHECK`. Games autosave with your ink and survive a reboot or a
flat battery.

It exists because I wanted to do sudoku on holiday and the reMarkable is the
only screen I own that doesn't glow at me. It works, so I do sudoku on it.
That was the whole success criterion.

There are no screenshots yet.

## Play it

You need an rM2 on firmware 3.27.3.0 plugged in over USB, and a Mac or Linux
box with `curl`. Then one line:

```bash
curl -fsSL https://github.com/QuirkQ/reDoku/releases/latest/download/install.sh | sh
```

It fetches the host CLI, checks it against the checksum published beside it,
and installs a `redoku` command — then asks before it touches the device.
You'll be asked for the device's SSH password once, so write it down first:
*Settings → Help → Copyrights and licenses*.

```bash
redoku install     # put it all on the device (re-runnable from any state)
redoku play        # launch over SSH, if you'd rather not tap
redoku status      # what's running on the device, and your installed version
redoku upgrade     # pull down a newer release ('install' then puts it on the device)
redoku uninstall   # device back to stock (--purge also deletes your saves)
```

Then tap **Sudoku** in the library. That's the game.

[INSTALL.md](INSTALL.md) covers reading the installer before you run it, what
the checksum does and doesn't prove, installing without the network, and
building the whole thing from source.

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

## Before you start

I'm not affiliated with reMarkable AS. You're poking at your own tablet's
internals at your own risk; the only guarantee is that there's no ill-intended
code in here.

- **Tested on firmware 3.27.3.0 only.** The installer refuses anything else
  without `--force`.
- **A firmware update reverts you to stock.** It wipes every unit under
  `/etc/systemd/system/`, so `/home/root/redoku/` and your saves survive but
  nothing in it runs, the decoy goes back to being an ordinary PDF, and launch
  is SSH-only until you reinstall. Keep auto-updates off.
- **The install only adds files:** `/home/root/redoku/`, the decoy document in
  xochitl's own library, and three systemd units. No kernel, boot or partition
  changes, failures roll themselves back, and xochitl comes up stock if the
  display server is broken. If the device ever looks stuck, hold power for
  ~10 s — and SSH-over-USB never depends on xochitl, so `uninstall` is always
  reachable.

## Rough edges

- **The recognizer knows one hand** (see above). Accuracy numbers in this repo
  describe authored templates, not a stranger's handwriting.
- **Three device checks were never witnessed.** The pen drawing through a
  tap-launched game rather than an SSH-launched one, the watcher being killed
  mid-play, and a battery pull during play. [M4-HIJACK.md](M4-HIJACK.md) keeps
  the full ledger of what was and wasn't seen on hardware.
- **Palm rejection is unverified, on-device generation timing is unmeasured,
  and the digits are a placeholder font.** No timer, undo, printed pencil
  marks or landscape.

[PLAN.md](PLAN.md) records, per milestone, what has been witnessed on real
hardware versus host-tested only.

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

## Develop

`make test` — host build plus the full mrbtest suite, in Docker — is the loop
you live in, because most of the game is deliberately host-testable.
[CONTRIBUTING.md](CONTRIBUTING.md) has the rest.

## Status

[Casual maintenance intended](https://casuallymaintained.tech/). I still do
sudoku on this thing, so if it breaks in a way that stops me playing I'll
probably fix it; anything else may sit untouched for a long time. Issues and
PRs are welcome and may or may not be looked at.

Prior art: [remarkable-sudoku](https://github.com/HookedBehemoth/remarkable-sudoku)
is older, much smaller, and installable from Toltec.

Standing on [rM2-stuff](https://github.com/timower/rM2-stuff) (rm2fb, built from
a [pinned fork](https://github.com/QuirkQ/rM2-stuff)),
[mruby](https://mruby.org), [SQLite](https://www.sqlite.org),
[Toltec](https://github.com/toltec-dev/toltec)'s toolchain, and the
[reMarkable hacking community](https://github.com/reHackable/awesome-reMarkable),
who are the reason step 1 wasn't "brick the tablet".

## License

[AGPL-3.0-or-later](LICENSE). Anyone may use, study, modify and share it — but
a company distributing it (say reMarkable, shipping it in their product) has
to pass those freedoms on, complete source included. If that's a problem, get
in touch and we can talk about a commercial license.
