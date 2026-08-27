# Installing reDoku without a toolchain

**Status:** designed 2026-08-27, not yet implemented. Owner decisions taken
this date are marked **[owner]**. Supersedes README §"Play it"'s claim that
"There are no prebuilt downloads yet" and `bin/redoku`'s header claim that it
must be "run from a reDoku checkout"; extends `.github/workflows/release.yml`,
which already publishes a tarball nothing consumes.

This records how a user gets reDoku onto a reMarkable 2 with no Docker, no
cross-toolchain, no ruby and no checkout — and why each half of the mechanism
is shaped the way it is. Read §2 before changing any of it: several decisions
below invert the obvious answer, and the reasoning is not recoverable from the
code.

Provenance markers, as in [`m3b-check-flow.md`](m3b-check-flow.md):

- **[src]** — read in the source, citable.
- **[test]** — proven by an assertion that was actually run.
- **[reasoned]** — argument only, unmeasured.
- **[owner]** — a decision, not a finding.

---

## 1. Where we start from

**The publishing half already exists.** `.github/workflows/release.yml` runs
release-please on `main`; when a release is cut it cross-builds both halves
(`make build`, `make rm2fb`), packs `redoku-rm2.tar.gz`, and
`gh release upload`s it to the tag. **[src]** So this change is not "create
CI" — it is "make `bin/redoku` able to consume what CI already produces", plus
the smaller CI gaps that consumption exposes.

Three such gaps:

1. **No checksum asset.** Nothing published beside the tarball can prove it
   arrived intact. **[src]**
2. **A layout nothing reads.** The tarball puts the game at
   `redoku/bin/redoku` and the three rm2fb artifacts loose at `redoku/`
   **[src]**, while `bin/redoku` looks for them at `build/rm2/bin/redoku` and
   `build/rm2fb/dist/` **[src]**. The published artifact and the consumer have
   never met.
3. **Nothing to fetch yet.** `git tag` lists nothing locally and
   `.release-please-manifest.json` still reads `0.1.0` **[src]** — the
   pre-release start state, so no release has been cut. **[reasoned]** (`gh`
   is unauthenticated on this machine, so the remote's release list was not
   queried — confirm before relying on it.) Until the release-please PR is
   merged, every `latest/download/…` URL in this document 404s.

**`ci.yml` is the wrong source and stays so.** Its `upload-artifact` blob needs
an authenticated API call to retrieve and expires after 30 days **[src]**.
Release assets are public, `curl`-able with no token, and permanent. **[owner]**

**What the user asked for** is `curl … | sh`: no clone at all. **[owner]** That
is what makes this bigger than an artifact-path change — `bin/redoku` needs
`device/install.sh`, `device/uninstall.sh`, `device/redoku-watcher.service`
and `tools/mkdecoy.rb` beside it **[src]**, so a repo-less install means
shipping the whole install kit and retiring the ruby dependency along with the
Docker one.

## 2. Decisions

All **[owner]**, taken 2026-08-27, each with its rejected alternative in §10.

| # | Decision |
|---|---|
| D1 | Repo-less `curl … \| sh` is the target, not "clone but don't build" |
| D2 | The kit is persistent (`~/.redoku/`) **and** puts a `redoku` on `PATH` |
| D3 | Verification is SHA-256 published beside the tarball, plus the existing 32-bit-ARM-ELF gate |
| D4 | A source checkout can download prebuilts too — fetching lives in `bin/redoku` |
| D5 | Upgrading is a `redoku upgrade` subcommand |
| D6 | `redoku uninstall --self` removes the host kit and the `PATH` entry |
| D7 | The bootstrap fetches exactly one file (the CLI) and delegates everything else |
| D8 | The kit mirrors a checkout's `build/` tree, so no path in `bin/redoku` changes |
| D9 | CI gains `shellcheck` over every shell file in the repo |

D7 and D8 are the two that keep the diff small, and they are worth stating as
a pair: D7 means the security-relevant download-verify-unpack code exists in
exactly one place, and D8 means the consumer needs no new path plumbing at
all.

## 3. What CI publishes

### 3.1 Release assets

Five, and their names never change from release to release, because
`https://github.com/QuirkQ/reDoku/releases/latest/download/<name>` only
resolves for a stable name. The version therefore lives *inside* the
artifacts, never in a filename. **[owner]**

| asset | purpose |
|---|---|
| `install.sh` | the piped bootstrap (§4) |
| `redoku` | the host CLI, `KIT_VERSION`-stamped |
| `redoku.sha256` | verifies `redoku` |
| `redoku-rm2.tar.gz` | the kit (§3.2) |
| `redoku-rm2.tar.gz.sha256` | verifies the kit |

**No `install.sh.sha256`.** You cannot verify the thing you are already piping
into a shell; publishing a checksum that protects nothing is worse than
publishing none, because it invites the belief that the pipe was checked.
**[owner]**

### 3.2 Kit layout

The kit is a *prebuilt checkout*: it reproduces the paths `bin/redoku` already
reads, so not one path in that script changes. **[owner]** (D8)

```
redoku/
├── VERSION                              "v0.3.0\n" — am I inside a kit? (§5.1)
├── bin/redoku                           host CLI, byte-identical to the asset
├── device/install.sh
├── device/uninstall.sh
├── device/redoku-watcher.service
├── build/rm2/bin/redoku                 armv7 game    — find_game's path [src]
├── build/rm2/bin/mruby
├── build/rm2/bin/mirb
├── build/rm2fb/dist/rm2fb_server_swtcon        — pick_artifact's default [src]
├── build/rm2fb/dist/librm2fb_client_swtcon.so
├── build/rm2fb/dist/rm2fbctl
├── build/decoy/c9f2b3a4-1e6d-4b8f-9c3a-7d5e2f108a6b.pdf   — build_decoy's [src]
├── build/decoy/….metadata  ….content  ….pagedata
└── build/decoy/watch.conf
```

A directory called `build/` inside something you downloaded reads oddly. It
buys a zero-line diff to every path in `bin/redoku`, which is worth more than
the naming. **[owner]**

`mruby` and `mirb` stay. Nothing pushes them to the device **[src]**, but
`release.yml` already ships them **[src]** and they are useful on-device
debugging tools; keeping the status quo needs no argument, dropping it would.

**The decoy ships prebuilt, which is what retires ruby.** `tools/mkdecoy.rb`
is deterministic by construction — `DEFAULT_UUID` and `PAGE_UUID` are
constants precisely so two installs produce byte-identical output **[src]** —
so generating it once in CI is equivalent to generating it on every user's
machine. `mkdecoy.rb` remains the single source of truth; CI runs it, and
§8 asserts the determinism rather than assuming it.

### 3.3 Stamping

CI rewrites one line in the released copies of the CLI:

```
KIT_VERSION=dev        →        KIT_VERSION=v0.3.0
```

A checkout stays `dev` forever. This is what lets a released CLI fetch *its
own* tag with no resolution step at all (§6.1), and it makes
`REDOKU_VERSION=v0.2.0` pin both halves — bootstrap and kit — with one
variable.

### 3.4 `tools/mkkit.sh`, the single packager

Both workflows call it, so the artifact CI tests is the artifact the release
publishes. **[owner]** Responsibilities:

1. assemble the §3.2 tree from `build/rm2/bin/` and `build/rm2fb/dist/`
2. stamp `KIT_VERSION` in both copies of the CLI; write `VERSION`
3. run `ruby tools/mkdecoy.rb` into `build/decoy/`, then run it a second time
   into a scratch dir and `diff -r` the two — determinism asserted, not assumed
4. `cmp` the standalone `redoku` against the in-tarball `bin/redoku`
5. emit `redoku-rm2.tar.gz` and both `.sha256` files
6. copy `tools/install.sh` out as the fifth asset

`--version` defaults to `dev` when omitted, so `ci.yml` and the fixtures in §8
can build kits without inventing a tag; `release.yml` passes the real one.

Failing any assertion fails the build. A kit that half-satisfies its own
layout is the one failure mode the on-device installer's rollback cannot help
with, because the files would arrive intact and simply be the wrong ones.
**[reasoned]**

## 4. The bootstrap

```sh
#!/bin/sh
# tools/install.sh — published as a release asset; fetches the reDoku host CLI
# and hands over to it. Deliberately the only file that runs unverified: it is
# what you piped, and nothing it downloads is used before its checksum matches.
set -eu
BASE=${REDOKU_BASE_URL:-https://github.com/QuirkQ/reDoku/releases}
URL=${REDOKU_VERSION:+$BASE/download/$REDOKU_VERSION}
URL=${URL:-$BASE/latest/download}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT INT HUP TERM
curl -fsSL -o "$T/redoku"        "$URL/redoku"
curl -fsSL -o "$T/redoku.sha256" "$URL/redoku.sha256"
# …compute the digest (shasum -a 256 | sha256sum | openssl dgst -sha256),
#   compare to the first field, die naming both digests and the URL…
[ -t 0 ] || { [ -e /dev/tty ] && exec < /dev/tty || true; }
sh "$T/redoku" install --download --kit "${REDOKU_HOME:-$HOME/.redoku}" "$@"
```

Four things in there are load-bearing:

**`exec < /dev/tty`.** When the script is piped, stdin *is* the script, so
`confirm()` — which reads stdin and guards with `[ -t 0 ]` **[src]** — would
die with *"not running in a terminal — add --yes"*. Reopening the terminal is
what keeps the existing confirmations real rather than bypassed. With no tty
anywhere (CI, a Docker build) the guard falls through and `confirm()`'s
existing message is the right answer, not a new failure mode. **[reasoned]**

**It does not `exec` the CLI.** `exec` would replace the shell and drop the
`EXIT` trap, leaking the temp dir. Running it as a child costs nothing —
signals reach it through the terminal's process group.

**`"$@"` at the end.** `curl … | sh -s -- --yes` and `-- --dry-run` both work,
so the pipe is not a second-class entry point.

**`REDOKU_BASE_URL`.** The seam §8 tests through, with `file://` URLs and no
network at all. It also makes a fork or a mirror installable without editing
the script.

## 5. `bin/redoku`'s new surface

### 5.1 Two markers, two questions

| marker | question it answers |
|---|---|
| `KIT_VERSION` (stamped, §3.3) | which version am I, and am I a release build? |
| `$REPO/VERSION` exists | are the artifacts sitting beside me? |

Both are needed, because the bootstrap runs a *stamped* CLI from a temp dir
with no kit around it: it knows its version and knows it must fetch. A CLI
running from `~/.redoku/current/bin/` knows the opposite. One marker cannot
express both states. **[reasoned]**

### 5.2 New options and commands

| | |
|---|---|
| `install --download` | fetch the kit instead of building it |
| `--kit DIR` | kit root — default `~/.redoku`, env `REDOKU_HOME` |
| `--bin-dir DIR` | where the `PATH` entry goes — default `~/.local/bin`, env `REDOKU_BIN_DIR` |
| `--no-symlink` | write no `PATH` entry at all |
| `upgrade` | fetch latest, repoint `current`, prune to one previous |
| `uninstall --self` | device to stock, then remove the host kit and our `PATH` entry |
| `REDOKU_VERSION` | pin a version (both halves, per §3.3) |
| `REDOKU_BASE_URL` | override the release base URL |
| `status` | gains `kit : v0.3.0 (~/.redoku/current)` |

**Which mode a download runs in is decided by `--kit` alone**, not guessed:
given ⇒ kit mode (unpack into that root, repoint `current`, write the `PATH`
entry); absent ⇒ checkout mode (unpack into `build/download/<tag>/`, touch
neither). A CLI already running from inside a kit derives its root as
`dirname "$REPO"` and needs no flag. **[owner]**

### 5.3 On-disk shape

```
~/.redoku/
├── v0.2.0/            kept — one back, so a rollback is one symlink swap
├── v0.3.0/            the §3.2 tree
└── current -> v0.3.0

~/.local/bin/redoku    a two-line wrapper, NOT a symlink
```

**Why a wrapper and not a symlink.** `bin/redoku:29` computes
`REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)` **[src]**. Invoked
through a symlink at `~/.local/bin/redoku`, `$0` *is* that symlink, so `REPO`
becomes `~/.local` and every path in the script is wrong. The alternatives are
a portable `readlink` chase loop inside a safety-critical script — BSD
`readlink` has no `-f`, so it is a loop, not a one-liner — or two lines
outside it:

```sh
#!/bin/sh
exec "/Users/you/.redoku/current/bin/redoku" "$@"
```

The path is written out absolute and resolved, not as `$HOME/.redoku` — a
`--kit` elsewhere must still work, and the ownership test below has to compare
against something concrete.

The wrapper also gives `uninstall --self` an exact ownership test: the file is
ours only if it contains that `exec` line pointing into *this* kit. A `redoku`
some package manager put there is never touched. **[owner]**

Two consequences worth stating: a kit-mode `install` **rewrites the wrapper
every run**, so a moved `~/.local/bin` or a hand-edited file self-heals and
re-running stays idempotent; and pruning to one previous version happens
whenever `current` is repointed — by `upgrade` and by an `install --download`
of a different version alike, not only by `upgrade`.

`~/.local/bin` over `/usr/local/bin`: no sudo, ever. A script you piped from
the internet asking for a root password is the prompt users should refuse.
When `~/.local/bin` is not on `PATH` the installer prints the `export` line
and never edits a shell rc file. **[owner]**

### 5.4 Precedence — a local build is never silently replaced

| context | command | binaries from |
|---|---|---|
| kit | `install`, `play` | the kit's own `build/` tree — no network |
| kit | `upgrade` | fetch latest, swap `current` |
| checkout | `install`, local build present | the local build *(unchanged)* |
| checkout | `install`, no local build | prompts to download into `build/download/<tag>/`; names `make rm2fb` as the alternative |
| checkout | `install --download` | always fetches, into `build/download/<tag>/` |
| checkout | `play` | local build only *(unchanged)* |
| checkout | `upgrade` | refuses — *"you're in a checkout: git pull && make build"* |

A download in a checkout lands in `build/download/<tag>/` and never in
`build/rm2/`, so a release binary cannot quietly become the thing you thought
you built. The prompt says outright that it installs released binaries, not
your working tree. **[owner]**

This inverts today's Docker prompt — `make rm2fb` becomes the opt-in
**[src]** — which is the point of the change: Docker stops being the price of
entry.

`play` in a kit works with no special casing, because `find_game` resolves
`$REPO/build/rm2/bin/redoku` **[src]** and D8 put the game exactly there.

## 6. `fetch_kit`, the one function

Three callers: kit-mode `install --download`, checkout-mode
`install --download`, and `upgrade`. No GitHub API, no token, no `jq`.

### 6.1 Tag resolution, in order

1. **`REDOKU_VERSION`** if set — explicit wins.
2. **`KIT_VERSION`** if not `dev` — a released CLI fetches its own tag, so the
   common path resolves nothing.
3. **The `Location` header of an un-followed redirect** on
   `https://github.com/QuirkQ/reDoku/releases/latest`, which points at
   `…/releases/tag/<tag>`:
   ```sh
   curl -fsSI "$BASE/latest" | tr -d '\r' \
     | sed -n 's#^[Ll]ocation:.*/releases/tag/##p'
   ```
   **Not** `-L` with `%{url_effective}`: an asset URL redirects twice — first
   to `/releases/download/<tag>/<asset>`, then to a signed
   `objects.githubusercontent.com` URL that does not carry the tag — so
   following the chain reports a URL the tag cannot be read from. **[reasoned]**
4. **`VERSION` inside the downloaded tarball** — the fallback. `file://` has no
   redirects at all, so this is the path §8's offline tests exercise; it also
   means a change in GitHub's redirect shape costs one extra download instead
   of breaking installs.

### 6.2 Verify, then unpack

```
download tarball + .sha256 into a temp dir
digest  = shasum -a 256 | sha256sum | openssl dgst -sha256   (whichever exists)
expect  = first field of the .sha256 asset
digest = expect  or  die naming both digests and the URL
tar -tzf | reject any entry not matching ^redoku/     (no absolute paths, no ..)
tar -xzf into the temp dir
mv temp/redoku  ->  <kit>/<tag>                       never a partial version dir
ln -s <tag> <kit>/.current.new && mv -f <kit>/.current.new <kit>/current
```

**Digest-and-compare, not `shasum -c`.** The `-c` input format and exit
behaviour differ between BSD and GNU implementations, and it forces the local
filename to match the one in the checksum file. Computing and string-comparing
is portable and produces a better message. **[owner]**

**`mv` into place, always.** Extraction is to a temp dir so an interrupt, a
full disk or a truncated stream can never leave `<kit>/<tag>/` half-populated,
and `current` is repointed by renaming a fresh symlink over it — `ln -sfn`'s
behaviour on an existing symlink-to-directory differs across implementations.
**[reasoned]**

**The `^redoku/` check is not theatre.** It is the same class of guard as
`push_file`'s refusal to write outside `$REMOTE_DIR` **[src]**: a tarball is
attacker-controlled input the moment the checksum is the only thing standing
behind it, and we extract as the user.

`upgrade` uses §6.1 step 3 alone first, so "already current" costs no
download. When the header trick fails it falls back to downloading and
comparing `VERSION` — one wasted download, still correct.

### 6.3 Idempotence

If `<kit>/<tag>/VERSION` already exists and the game binary there passes
`is_arm_elf` **[src]**, the download is skipped and the existing tree reused.
`install` is documented as safe to re-run from any state **[src]**; adding a
network fetch must not weaken that.

## 7. Failure catalogue

Every row is a message that names its own fix, and none leaves a partial
install behind.

| failure | behaviour |
|---|---|
| checksum mismatch | dies naming both digests and the URL; temp dir removed, kit untouched |
| no sha256 tool at all | **refuses** — never falls through to an unverified install |
| no `curl` | dies naming both offline routes: `--artifacts DIR`, or `make rm2fb` in a checkout |
| 404 | distinguishes *no releases published yet* from *no such version `REDOKU_VERSION`* |
| offline / DNS failure | names the URL it tried, and the two offline routes |
| tar entry outside `redoku/` | refused before extraction |
| interrupted or disk-full unpack | temp dir + `mv`; `current` never points at a partial tree |
| `~/.local/bin` not on `PATH` | prints the `export` line; never edits a shell rc |
| a foreign `redoku` at the bin-dir | left alone; prints its path, suggests `--bin-dir` / `--no-symlink` |
| that version already downloaded | reused, not re-fetched (§6.3) |
| `current` missing or dangling | `upgrade` repairs it by installing latest |
| device-side failure | unchanged — `device/install.sh` still rolls back to stock **[src]** |

`find_game`'s *"cross-build it with: make build"* hint **[src]** is wrong
advice inside a kit, where a missing game means a corrupt download. It becomes
conditional on `KIT_VERSION = dev`.

## 8. Testing

`tools/test/kit_test.sh`, wired as `make test-kit` and run in CI. Every test is
offline (`REDOKU_BASE_URL=file://…`) and never touches a device (`--dry-run`
plus a `--host` that goes nowhere). Seams: `REDOKU_BASE_URL`, `REDOKU_HOME`,
`REDOKU_BIN_DIR`, `--dry-run`.

1. `mkkit.sh` emits exactly the §3.2 tree; the in-tarball CLI `cmp`s equal to
   the standalone asset
2. bootstrap end-to-end against a `file://` fixture release
3. checksum mismatch → non-zero exit, both digests named, kit dir untouched
4. a tarball with an entry outside `redoku/` → refused, nothing extracted
5. `upgrade` v1 → v2: `current` repoints, one previous kept, older pruned
6. `uninstall --self` removes the kit and our wrapper, and leaves a foreign
   `redoku` alone
7. `--no-symlink` and `--bin-dir` honoured; the not-on-`PATH` hint printed
8. sha256 tools stripped from `PATH` → refuses to install
9. kit-mode `install --dry-run` resolves every path — the canary for D8 drift

Test 9 is the one that earns its keep long-term: it is what fails if someone
moves a path in `bin/redoku` without moving it in `mkkit.sh`.

**`shellcheck` in CI** (D9) over `bin/redoku`, `tools/install.sh`,
`device/*.sh` and `tools/test/kit_test.sh`. `shellcheck` is not installed on
this machine, so the existing warning count is **unknown** **[reasoned]** —
establishing that baseline and either fixing or annotating each finding is part
of this work, not a follow-up.

## 9. Everything else that changes

**`release.yml`** — replace the inline `cp`/`tar` block with `tools/mkkit.sh
--version "$TAG"`, and upload five assets with `--clobber`.

**`ci.yml`** — add `make test-kit` and the `shellcheck` step. Keep
`upload-artifact` as it is.

**README** — "Play it" leads with the one-liner and keeps the source build
below it; *"There are no prebuilt downloads yet"* goes. Add an honest
paragraph: the checksum lives in the same release as the tarball, so it proves
the bytes arrived intact, not that the release is authentic — a compromised
account could publish both halves. The 32-bit-ARM-ELF gate **[src]** still
checks every byte before it leaves the host. Document the no-pipe alternative
(`curl -O` the CLI, verify it by hand, run it) for anyone who would rather
read the script first, and `uninstall --self` for removal.

**`bin/redoku`'s header** — its "Run it from a reDoku checkout" and "Your
`~/.ssh/config` is IGNORED" block **[src]** gains the kit story; `--help`
gains §5.2.

**`M4-HIJACK.md`** — one line: released kits ship a prebuilt decoy;
`mkdecoy.rb` is still the source of truth and CI still runs it.

**Step 0 is not code.** Merge the release-please PR so a tag and a release
exist. Until then `latest/download/…` 404s and there is nothing to fetch.

## 10. Rejected alternatives

**Clone but don't build** (D1). `git clone` plus a download-instead-of-build
`install`. Cheapest option, keeps every script beside its checkout — but it
still requires git and a stdlib CRuby, and it is not the "just curl it" the
owner asked for. Rejected as a subset of what was wanted.

**A one-shot bootstrap that leaves nothing** (D2). Unpack to a temp dir,
install, delete. Simplest to publish, but then `uninstall` needs the network
and the release still to exist — for a tool that modified a tablet, the
reversal must not depend on GitHub. Rejected on that alone.

**`/usr/local/bin` for the `PATH` entry** (D2). On every default `PATH`, so
`redoku play` just works — but needs sudo on most Linux and on a Mac without
Homebrew. A piped script prompting for a root password teaches exactly the
wrong reflex. Rejected. "Whichever is writable" was rejected too: the answer
to *where is it installed* must not differ per machine.

**A detached minisign signature** (D3). Real protection against a compromised
release, unlike a same-release checksum. Costs a private key that must not be
lost, a signing step in every release, and `minisign` installed on the user's
machine. For a
[casually maintained](https://casuallymaintained.tech/) holiday sudoku
machine, the honest README paragraph in §9 is the better trade. Revisit if the
project ever grows a second maintainer.

**HTTPS with no checksum at all** (D3). Least CI work; turns a truncated
download into `tar: unexpected EOF in archive`. Rejected — the ARM-ELF gate
would then be the only integrity check, and it cannot tell a truncated file
from a wrong one.

**Fetching only from the bootstrap** (D4/D7). Keeps `bin/redoku` free of
network code entirely, at the price of a `--game` override and no `upgrade`.
Superseded by D4 and D5: once the CLI must fetch for `upgrade` and for
checkout downloads, keeping a second implementation in the bootstrap is the
thing to avoid, not the network code itself.

**A bootstrap that fetches the tarball** (D7). One less release asset, but
~60 lines of download-verify-unpack in a second file that `bin/redoku`
duplicates anyway — two implementations of the security-relevant step, free to
drift. Rejected in favour of fetching one small file and delegating.

**No pipe at all** (D7). Four inspectable commands, nothing executed straight
from a pipe. Genuinely safer and now available for free as the documented
alternative in §9, because D7 publishes the CLI as its own asset — but not the
one-liner that was asked for.

**Three path variables instead of a `build/` tree** (D8). `RM2FB_DIR`,
`GAME_BIN` and `DECOY_DIR`, defaulting to today's paths and overridden in a
kit, which would let the kit use clean flat `rm2/` and `rm2fb/` directories.
Rejected: a `build/` directory inside a download reads odd exactly once, per
user, while three new variables are read every time anyone touches those code
paths.

**`redoku upgrade` versus re-running the one-liner** (D5). Re-running is
simpler and adds nothing to the CLI, and an on-run update check was rejected
outright — it would put a network call in front of a tool whose whole appeal
is working over a USB cable on a plane. `upgrade` was chosen for
discoverability from `--help`; the duplication it would have caused is what D7
avoids.

**Printing the `rm` commands instead of `uninstall --self`** (D6). Zero
deletion code in a safety-critical script. Rejected because the kit writes a
`PATH` entry outside its own directory without a build step first, so it owes
the user a precise, guarded removal — §5.3's ownership test is what makes that
safe.
