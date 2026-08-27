#!/bin/sh
# tools/install.sh — published as a release asset; fetches the reDoku host CLI
# and hands over to it. Deliberately the only file that runs unverified: it is
# what you piped, and nothing it downloads is used before its checksum matches.
set -eu
BASE=${REDOKU_BASE_URL:-https://github.com/QuirkQ/reDoku/releases}
URL=${REDOKU_VERSION:+$BASE/download/$REDOKU_VERSION}
URL=${URL:-$BASE/latest/download}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || \
  die "no 'curl' on this machine — install another way instead:
  --artifacts DIR against binaries you already have, or, from a checkout,
  'make rm2fb' to build them locally"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT INT HUP TERM

# fetch <url> <dest> — curl -fsSL's own stderr (suppressed by -s, or a bare
# HTTP/DNS error with -S) can't tell "no release published yet" apart from
# "REDOKU_VERSION pins a tag that doesn't exist", and doesn't point at the
# two ways to install without the network either. This does both, naming
# the URL either way per design doc §7.
fetch() {
  curl -fsSL -o "$2" "$1" && return 0
  if [ -n "${REDOKU_VERSION:-}" ]; then
    die "could not download $1
  REDOKU_VERSION=$REDOKU_VERSION may not exist as a release, or you're offline.
  Install another way instead: --artifacts DIR against binaries you already
  have, or, from a checkout, 'make rm2fb' to build them locally."
  else
    die "could not download $1
  There may be no published release yet, or you're offline.
  Install another way instead: --artifacts DIR against binaries you already
  have, or, from a checkout, 'make rm2fb' to build them locally."
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
if command -v shasum >/dev/null 2>&1; then
  ACTUAL=$(shasum -a 256 "$T/redoku")
  ACTUAL=${ACTUAL%% *}
elif command -v sha256sum >/dev/null 2>&1; then
  ACTUAL=$(sha256sum "$T/redoku")
  ACTUAL=${ACTUAL%% *}
elif command -v openssl >/dev/null 2>&1; then
  # openssl prints "SHA2-256(<path>)= <hex>" (or "SHA256(...)=" — the
  # label differs between OpenSSL and LibreSSL) — the hex is the LAST
  # field here, not the first, unlike shasum/sha256sum above.
  ACTUAL=$(openssl dgst -sha256 "$T/redoku")
  ACTUAL=${ACTUAL##* }
else
  # Never fall through to an unverified install — design doc §7.
  die "no sha256 tool (shasum, sha256sum, or openssl) on this machine —
  refusing to install $T/redoku unverified. Install one of those three and
  try again."
fi
# Normalise case first: none of the three tools above should ever emit
# uppercase hex, but a string-compare must not be the thing that finds out.
ACTUAL=$(printf '%s' "$ACTUAL" | tr 'A-F' 'a-f')

# The checksum file's first whitespace-separated field, read with the
# shell's own `read` rather than `cut`/`awk` — one less external tool this
# script depends on beyond curl and a digest tool.
IFS=' ' read -r EXPECT _ < "$T/redoku.sha256"
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
# this. With no tty anywhere (CI, a Docker build) /dev/tty doesn't exist,
# the `|| true` lets that fall through, and confirm()'s own message is the
# right answer at that point, not a new failure mode invented here.
[ -t 0 ] || { [ -e /dev/tty ] && exec < /dev/tty || true; }

# Not `exec`: that would replace this shell and drop the EXIT trap above,
# leaking $T. Running the CLI as a child costs nothing — Ctrl-C and friends
# still reach it directly through the terminal's process group — and it's
# what lets the trap still fire and clean up $T once the CLI returns.
sh "$T/redoku" install --download --kit "${REDOKU_HOME:-$HOME/.redoku}" "$@"
