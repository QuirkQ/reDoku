#!/bin/sh
# tools/install.sh — published as a release asset; fetches the reDoku host CLI
# and hands over to it. Deliberately the only file that runs unverified: it is
# what you piped, and nothing it downloads is used before its checksum matches.
set -eu
BASE=${REDOKU_BASE_URL:-https://github.com/QuirkQ/reDoku/releases}
URL=${REDOKU_VERSION:+$BASE/download/$REDOKU_VERSION}
URL=${URL:-$BASE/latest/download}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# The two ways to install without curl, or without the network at all,
# named once and reused by every message below that needs them (design
# doc §7's failure catalogue) — hoisted so the sentence can't drift out
# of sync between call sites, and so it's cased the same way everywhere.
OFFLINE_ROUTES="install another way: --artifacts DIR against binaries you already have, or, from a checkout, 'make rm2fb' to build them locally"

command -v curl >/dev/null 2>&1 || \
  die "no 'curl' on this machine — $OFFLINE_ROUTES"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT INT HUP TERM

# fetch <url> <dest> — curl -fsSL's own stderr (suppressed by -s, or a bare
# HTTP/DNS error with -S) can't tell "no release published yet" apart from
# "REDOKU_VERSION pins a tag that doesn't exist", and doesn't point at the
# two offline routes either. This does both, naming the URL either way per
# design doc §7.
fetch() {
  curl -fsSL -o "$2" "$1" && return 0
  if [ -n "${REDOKU_VERSION:-}" ]; then
    die "could not download $1 — REDOKU_VERSION=$REDOKU_VERSION may not exist as a release, or you're offline; $OFFLINE_ROUTES."
  else
    die "could not download $1 — there may be no published release yet, or you're offline; $OFFLINE_ROUTES."
  fi
}

fetch "$URL/redoku"        "$T/redoku"
fetch "$URL/redoku.sha256" "$T/redoku.sha256"

# Compute the digest (shasum -a 256, then sha256sum, then openssl dgst
# -sha256 — whichever exists) and compare it to the first field of
# redoku.sha256.
#
# Not `shasum -c`: its input format and exit behaviour differ between BSD
# and GNU, and it forces the local filename to match the one recorded in
# the checksum file. Computing the digest ourselves and string-comparing
# it to the checksum file's first whitespace-separated field sidesteps
# both and produces a message with real content instead of `shasum -c`'s
# bare "FAILED".
#
# Each branch's `|| die` matters on its own: a digest tool that exists but
# fails (a broken install, a permissions problem) must not be swallowed by
# errexit into a silent, wordless exit — every failure here names its own
# fix per design doc §7, including this one.
if command -v shasum >/dev/null 2>&1; then
  ACTUAL=$(shasum -a 256 "$T/redoku") || die "shasum failed verifying $URL/redoku — try again"
  ACTUAL=${ACTUAL%% *}
elif command -v sha256sum >/dev/null 2>&1; then
  ACTUAL=$(sha256sum "$T/redoku") || die "sha256sum failed verifying $URL/redoku — try again"
  ACTUAL=${ACTUAL%% *}
elif command -v openssl >/dev/null 2>&1; then
  # openssl prints "SHA2-256(<path>)= <hex>" (or "SHA256(...)=" — the
  # label differs between OpenSSL and LibreSSL) — the hex is the LAST
  # field here, not the first, unlike shasum/sha256sum above.
  ACTUAL=$(openssl dgst -sha256 "$T/redoku") || die "openssl dgst failed verifying $URL/redoku — try again"
  ACTUAL=${ACTUAL##* }
else
  # Never fall through to an unverified install — design doc §7. Names
  # $URL/redoku, not $T/redoku: $T is removed by the EXIT trap above
  # before anyone reads this message, but the URL is still there to act on.
  die "no sha256 tool (shasum, sha256sum, or openssl) on this machine — refusing to install $URL/redoku unverified. Install one of those three and try again."
fi
# Normalise case first: none of the three tools above should ever emit
# uppercase hex, but a string-compare must not be the thing that finds out.
ACTUAL=$(printf '%s' "$ACTUAL" | tr 'A-F' 'a-f')

# The checksum file's first whitespace-separated field, read with the
# shell's own `read` rather than `cut`/`awk` — one less external tool this
# script depends on beyond curl and a digest tool.
#
# `read` returns non-zero at EOF, which an empty or truncated file (or one
# with no trailing newline reaching the second field) triggers — and under
# `set -eu` that would otherwise exit the whole script with NO output at
# all, right after a successful download: the worst possible failure under
# §7's "every message names its own fix" rule. `|| true` keeps that
# non-zero from being fatal by itself; the explicit emptiness check below
# is what actually catches it and says something.
IFS=' ' read -r EXPECT _ < "$T/redoku.sha256" || true
[ -n "${EXPECT:-}" ] || \
  die "$URL/redoku.sha256 is empty or unreadable — the download may have been truncated. Try the install again."
EXPECT=$(printf '%s' "$EXPECT" | tr 'A-F' 'a-f')

[ "$ACTUAL" = "$EXPECT" ] || \
  die "checksum mismatch for $URL/redoku
  expected: $EXPECT
  got:      $ACTUAL
  the download may be corrupt, or the release compromised — try again, and
  if it persists, do not run the downloaded file"

# When piped (curl ... | sh), stdin IS the script itself, so bin/redoku's
# confirm() — which reads stdin and guards with [ -t 0 ] — would die with
# "not running in a terminal — add --yes" on every confirmation, even
# though a real terminal is sitting right there. Reopening it here keeps
# those confirmations real instead of forcing --yes on everyone who pipes
# this.
#
# The probe-in-a-subshell is load-bearing, not decoration. `/dev/tty`
# exists as a device node inside containers and under systemd even with no
# controlling terminal, and opening it there fails with ENXIO — and a
# failed redirection on a bare `exec` is a FATAL shell error in dash and in
# bash invoked as `sh` (POSIX "Consequences of Shell Errors"), not an
# ordinary command failure that a trailing `|| true` can catch: measured
# directly against this file — dash aborted with "cannot open /dev/tty:
# Device not configured" and the CLI never ran, on a machine where
# /dev/tty exists but nothing is attached to it. `(: < /dev/tty)` forks a
# subshell to attempt the exact same open first; ITS failure is only ever
# an exit status the parent shell can act on, so `&&` short-circuits
# cleanly and the real `exec` below is only reached once the probe has
# already proven it will succeed. With no tty anywhere this falls through
# silently, and confirm()'s own message is the right answer at that point,
# not a new failure mode invented here.
if [ ! -t 0 ] && [ -e /dev/tty ] && (: < /dev/tty) 2>/dev/null; then
  exec < /dev/tty
fi

# Not `exec`: that would replace this shell and drop the EXIT trap above,
# leaking $T. Running the CLI as a child costs nothing — Ctrl-C and friends
# still reach it directly through the terminal's process group — and it's
# what lets the trap still fire and clean up $T once the CLI returns.
#
# KIT_DIR is resolved through its own guard rather than inline, because
# "${REDOKU_HOME:-$HOME/.redoku}" still evaluates $HOME — and trips set -u
# — the moment REDOKU_HOME itself is unset, even when $HOME is ALSO
# entirely unset (not just empty): that died with a bare "HOME: parameter
# not set", naming no fix.
[ -n "${REDOKU_HOME:-}" ] || [ -n "${HOME:-}" ] || \
  die "neither \$REDOKU_HOME nor \$HOME is set, so there's nowhere to default the kit directory to. Set REDOKU_HOME=/path/to/kit (or export \$HOME) and try again."
KIT_DIR=${REDOKU_HOME:-$HOME/.redoku}
sh "$T/redoku" install --download --kit "$KIT_DIR" "$@"
