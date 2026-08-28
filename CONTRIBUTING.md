# Contributing

[Casual maintenance intended](https://casuallymaintained.tech/) — issues and
PRs are welcome and may or may not be looked at. If you're here to build or
change something, this is the loop.

For installing a release rather than working on the code, see
[INSTALL.md](INSTALL.md).

## The loop

Every target is a thin Docker wrapper, so your Mac never needs the toolchain
directly. The image is `linux/amd64`; expect emulation on Apple Silicon.

```bash
make test    # host build + the full mrbtest suite — the loop you live in
make build   # cross-compile armv7 → build/rm2/bin/
make rm2fb   # cross-compile the display server → build/rm2fb/dist/
make shell   # a shell in the build container
```

Most of the game is deliberately host-testable — pen, ink, recognizer,
renderer, generator, rater and store, with the display client running against a
fake server — which is why `make test` is worth living in rather than
round-tripping to the device. Tests sit next to their gems in
`mrbgems/*/test/`.

Two suites sit outside that:

- **`make test-tools`** covers `tools/`, which is host-side CRuby (stdlib
  only), not mruby — no gem to build, nothing to cross-compile. It runs in the
  image but needs no mruby checkout, so it works in a bare clone.
- **`make test-kit`** is the one target that deliberately does *not* use
  Docker. It tests `tools/install.sh`, whose entire risk surface **is** the
  host's own `curl`, `shasum`/`sha256sum`/`openssl` and `tar` — exactly the
  things a fixed Linux image would hide, since it always has GNU everything and
  never the BSD userland this also has to work on. Running it in Docker would
  test the one platform the portability code isn't written for.

## On-device iteration

```bash
make build && bin/redoku play --seconds 10
```

`play` only copies the game binary, so the display server stays up and the
decoy doesn't need re-tapping. `bin/redoku status` and `bin/redoku shell` are
the other two you'll want; on the device itself,
`/home/root/redoku/bin/redoku --clients` says who currently owns the panel.

Beware the process-lifecycle contract: the display server `SIGSTOP`s the whole
process group of the client it demotes, so a live client must never `switch_to`
xochitl's pid — it would freeze inside the call and never reach its exit path.
`PLAN.md` §3, `mrbgems/mruby-rm2/src/control.c`'s header and
[`mrbgems/mruby-rm2/README.md`](mrbgems/mruby-rm2/README.md) all spell this out.

## Layout

| | |
|---|---|
| [`mruby-rm2`](mrbgems/mruby-rm2/README.md) | display and input, plus the inotify and spawn shims |
| `mruby-redoku` | the game — board, recognizer, renderer, generator, rater, store, watcher |
| [`mruby-sqlite3`](mrbgems/mruby-sqlite3/README.md) | SQLite bindings |
| `mruby-bin-redoku` | the executable |
| `bin/redoku`, `device/` | the host CLI and the on-device install scripts |
| `tools/` | decoy generator, release packager, and their tests |

## Conventions

**Plan first, then implement, and keep what got rejected on the record.**
Designs go in [`docs/plans/`](docs/plans/) and
[`docs/design/`](docs/design/); `PLAN.md` is the standing design record. When a
plan turns out to have guessed wrong, the habit here is to annotate it with the
correction next to the original rather than silently rewrite it — `PLAN.md`
§10 and `M4-HIJACK.md` both carry examples.

`PLAN.md` also distinguishes, per milestone, what has been **witnessed on real
hardware** from what is only host-tested. Keep that line honest: don't promote
a check to witnessed because it ought to pass.

Commits are [conventional](https://www.conventionalcommits.org/);
release-please turns them into a release PR, and merging that PR tags the
release and publishes its five assets. CI runs build, test, and shellcheck.
