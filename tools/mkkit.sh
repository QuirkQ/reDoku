#!/bin/sh
# tools/mkkit.sh — the one packager that builds every release asset (design
# doc docs/design/prebuilt-kit.md §3.4). Both ci.yml and release.yml call
# this, so the artifact CI tests IS the artifact the release publishes —
# no packaging logic may live anywhere else.
#
# Failing any assertion below fails the build: a kit that half-satisfies its
# own §3.2 layout is the one failure mode the on-device installer's rollback
# cannot help with, because the files would arrive intact and simply be the
# wrong ones.
#
# usage: tools/mkkit.sh [--version VERSION] [--out DIR] [--build-dir DIR]
#
#   --version    stamped into KIT_VERSION and VERSION (default: dev, so
#                ci.yml and this repo's own test fixtures can build kits
#                without inventing a tag; release.yml passes the real one)
#   --out        where the five §3.1 assets land, flat (default: dist/,
#                created if missing). A controller ruling — the design doc
#                names no output directory; a later task wires release.yml
#                to upload from here)
#   --build-dir  the build/ tree mkkit reads its inputs from:
#                <dir>/rm2/bin/{redoku,mruby,mirb} and
#                <dir>/rm2fb/dist/{rm2fb_server_swtcon,
#                librm2fb_client_swtcon.so,rm2fbctl} (default: build/, i.e.
#                exactly what `make build` and `make rm2fb` populate). This
#                is the interface tools/test/kit_test.sh's fixture builder
#                uses to point mkkit at a throwaway fake build tree instead
#                of the repo's own build/ — see make_fake_arm_elf there.
#
# Deliberately does NOT check that its inputs are 32-bit ARM ELF. That gate
# is bin/redoku's is_arm_elf and device/install.sh's own copy of the same
# check, and it runs against every byte before it leaves the user's host —
# this script only ever runs on a developer's machine or in CI, never on
# the device, so it has nothing to protect by re-checking. Keeping mkkit
# format-agnostic is also what lets the test suite build fixture kits out
# of small synthetic files instead of real cross-compiled binaries. Do NOT
# "fix" this by adding an ELF check here — see task-2-brief.md.

set -eu

REPO=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
say() { printf '==> %s\n' "$*"; }

usage() {
  cat <<'EOF'
tools/mkkit.sh — build the five reDoku release assets (design doc §3.1/§3.4)

usage:
  tools/mkkit.sh [--version VERSION] [--out DIR] [--build-dir DIR]

options:
  --version VERSION  stamped into KIT_VERSION and VERSION (default: dev)
  --out DIR          where the five assets land, flat (default: dist/)
  --build-dir DIR    the build/ tree to read rm2/bin/ and rm2fb/dist/
                     from (default: build/ — what 'make build' and
                     'make rm2fb' populate)
  -h, --help         this help
EOF
}

VERSION=dev
OUT=$REPO/dist
BUILD_DIR=$REPO/build

while [ $# -gt 0 ]; do
  case $1 in
    --version)   [ $# -ge 2 ] || die "--version needs a value — e.g. --version v0.3.0; omit --version entirely for 'dev'"; VERSION=$2; shift ;;
    --out)       [ $# -ge 2 ] || die "--out needs a value — e.g. --out dist"; OUT=$2; shift ;;
    --build-dir) [ $# -ge 2 ] || die "--build-dir needs a value — e.g. --build-dir build"; BUILD_DIR=$2; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           die "unknown argument '$1' — see tools/mkkit.sh --help" ;;
  esac
  shift
done

# ---- scratch space --------------------------------------------------------
#
# All staging happens here, never inside --out and never inside build/: an
# interrupted or failed run must not leave a half-built tree in either of
# those, and --out is a real deliverable directory a caller may reuse
# across runs (e.g. release.yml's dist/).
T=$(mktemp -d)
# EXIT alone just cleans up (the shell is already on its way out). INT,
# HUP and TERM need their own traps that ALSO exit — a POSIX shell resumes
# the script after a signal handler returns, and resuming into whatever
# came next (with $T already deleted out from under it) is not what a
# signal handler is for. 130/129/143 are the conventional 128+signal exit
# codes (SIGINT=2, SIGHUP=1, SIGTERM=15), so a caller's $? still reports
# which signal actually ended the run.
trap 'rm -rf "$T"' EXIT
trap 'rm -rf "$T"; exit 130' INT
trap 'rm -rf "$T"; exit 129' HUP
trap 'rm -rf "$T"; exit 143' TERM
TREE=$T/redoku

# ---- shared digest helper -------------------------------------------------
#
# Same three-tool fallback and ordering as tools/install.sh's own digest
# step and tools/test/kit_test.sh's kit_digest (design doc §3.1: "one line,
# <64 hex digits>  <filename> — the same shape shasum -a 256 / sha256sum
# produce"). Not sourced from the test file — mkkit.sh must work standalone
# in CI and on a developer's machine with no test harness involved — so
# this is a second copy of the same small fallback, by design, not drift.
mkkit_digest() { # mkkit_digest <file> — prints its sha256 as lowercase hex
  _mkd_file=$1
  if command -v shasum >/dev/null 2>&1; then
    _mkd_line=$(shasum -a 256 "$_mkd_file") || die "shasum failed on $_mkd_file — its own error is above"
    _mkd_hex=${_mkd_line%% *}
  elif command -v sha256sum >/dev/null 2>&1; then
    _mkd_line=$(sha256sum "$_mkd_file") || die "sha256sum failed on $_mkd_file — its own error is above"
    _mkd_hex=${_mkd_line%% *}
  elif command -v openssl >/dev/null 2>&1; then
    # shasum/sha256sum print "<hex>  <path>" (hex first field); openssl
    # prints "SHA2-256(<path>)= <hex>" (hex LAST field, and the label
    # before it differs between OpenSSL and LibreSSL) — one "first field"
    # rule can't cover both shapes.
    _mkd_line=$(openssl dgst -sha256 "$_mkd_file") || die "openssl dgst failed on $_mkd_file — its own error is above"
    _mkd_hex=${_mkd_line##* }
  else
    die "no sha256 tool (shasum, sha256sum, or openssl) on this machine — install one and try again"
  fi
  # [:upper:]/[:lower:] rather than the A-F/a-f range form: POSIX leaves
  # range-expression collation locale-dependent, so A-F is not guaranteed
  # portable everywhere tr runs, even though every one of the three tools
  # above already emits lowercase and this line can only ever be a no-op
  # in practice — which is exactly why it should be written the form that
  # cannot misfire, not the form that happens to work here.
  printf '%s\n' "$_mkd_hex" | tr '[:upper:]' '[:lower:]'
}

# ---- (1) assemble the §3.2 tree from build/rm2/bin/ and build/rm2fb/dist/

need_build_input() { # need_build_input <path> <make-target>
  [ -f "$1" ] || die "missing input: $1 — run '$2' to produce it"
}

need_build_input "$BUILD_DIR/rm2/bin/redoku"                       "make build"
need_build_input "$BUILD_DIR/rm2/bin/mruby"                        "make build"
need_build_input "$BUILD_DIR/rm2/bin/mirb"                         "make build"
need_build_input "$BUILD_DIR/rm2fb/dist/rm2fb_server_swtcon"       "make rm2fb"
need_build_input "$BUILD_DIR/rm2fb/dist/librm2fb_client_swtcon.so" "make rm2fb"
need_build_input "$BUILD_DIR/rm2fb/dist/rm2fbctl"                  "make rm2fb"

for _f in device/install.sh device/uninstall.sh device/redoku-watcher.service \
          tools/install.sh tools/mkdecoy.rb bin/redoku; do
  [ -f "$REPO/$_f" ] || die "missing $REPO/$_f — run tools/mkkit.sh from a reDoku checkout"
done

say "assembling the kit tree"
mkdir -p "$TREE/bin" "$TREE/device" \
  "$TREE/build/rm2/bin" "$TREE/build/rm2fb/dist" "$TREE/build/decoy"

cp "$BUILD_DIR/rm2/bin/redoku" "$TREE/build/rm2/bin/redoku"
cp "$BUILD_DIR/rm2/bin/mruby"  "$TREE/build/rm2/bin/mruby"
cp "$BUILD_DIR/rm2/bin/mirb"   "$TREE/build/rm2/bin/mirb"
cp "$BUILD_DIR/rm2fb/dist/rm2fb_server_swtcon"       "$TREE/build/rm2fb/dist/rm2fb_server_swtcon"
cp "$BUILD_DIR/rm2fb/dist/librm2fb_client_swtcon.so" "$TREE/build/rm2fb/dist/librm2fb_client_swtcon.so"
cp "$BUILD_DIR/rm2fb/dist/rm2fbctl"                  "$TREE/build/rm2fb/dist/rm2fbctl"

cp "$REPO/device/install.sh"             "$TREE/device/install.sh"
cp "$REPO/device/uninstall.sh"           "$TREE/device/uninstall.sh"
cp "$REPO/device/redoku-watcher.service" "$TREE/device/redoku-watcher.service"

# Executable bits: tar preserves modes, so a source file that happens not
# to be +x (e.g. a fixture written by the test harness) would otherwise
# ship non-executable inside the tarball. chmod in the staging dir is the
# fix — not a tar flag — per design doc §3.2.
chmod +x "$TREE/device/install.sh" "$TREE/device/uninstall.sh"
chmod +x "$TREE/build/rm2/bin/"*
chmod +x "$TREE/build/rm2fb/dist/"*

# ---- (2) stamp KIT_VERSION in both copies of the CLI; write VERSION
#
# design doc §3.3: CI rewrites exactly the line "KIT_VERSION=dev" to
# "KIT_VERSION=<version>". awk matching the whole line literally (not sed
# with a substitution pattern) sidesteps regex-metacharacter and
# delimiter escaping entirely — a version string is developer-controlled,
# not attacker input, but there is no reason to assume it never contains a
# '/' or '&'. sed -i is not used at all: GNU wants "-i", BSD wants "-i ''",
# so the portable form writes a new file instead of editing in place.

say "stamping KIT_VERSION=$VERSION"
STAMPED=$T/redoku-stamped
awk -v ver="$VERSION" '
  $0 == "KIT_VERSION=dev" { print "KIT_VERSION=" ver; next }
  { print }
' "$REPO/bin/redoku" > "$STAMPED"

grep -qxF "KIT_VERSION=$VERSION" "$STAMPED" || \
  die "stamping KIT_VERSION failed: $STAMPED does not contain the line 'KIT_VERSION=$VERSION' — is bin/redoku's marker still exactly 'KIT_VERSION=dev'?"
if [ "$VERSION" != dev ]; then
  ! grep -qxF 'KIT_VERSION=dev' "$STAMPED" || \
    die "stamping KIT_VERSION failed: $STAMPED still contains the line 'KIT_VERSION=dev' after stamping to $VERSION"
fi
chmod +x "$STAMPED"

# Stamp once, copy the stamped file to both destinations — so the (4) cmp
# below cannot fail for the silly reason of two independent stamping runs
# producing merely-equivalent-but-not-identical bytes. ASSET_REDOKU is the
# future $OUT/redoku, staged in $T like every other asset below — nothing
# is written to --out until every assertion in this script has passed
# (see the publish step at the very end).
ASSET_REDOKU=$T/asset-redoku
cp "$STAMPED" "$ASSET_REDOKU"
cp "$STAMPED" "$TREE/bin/redoku"
chmod +x "$ASSET_REDOKU" "$TREE/bin/redoku"

printf '%s\n' "$VERSION" > "$TREE/VERSION"

# ---- (3) the decoy, built once and proven deterministic, not assumed so
#
# tools/mkdecoy.rb is deterministic by construction (DEFAULT_UUID and
# PAGE_UUID are fixed constants), which is what makes shipping it prebuilt
# equivalent to generating it on every user's machine — but "deterministic
# by construction" is a claim about the source, not a guarantee about this
# particular run. Running it twice and diffing is what turns that claim
# into something this script actually checked.

command -v ruby >/dev/null 2>&1 || \
  die "no 'ruby' on this machine — tools/mkkit.sh needs a stdlib-only CRuby (no gems, no bundler) to build the decoy document via tools/mkdecoy.rb. Install one and try again."

say "building the decoy document (tools/mkdecoy.rb)"
ruby "$REPO/tools/mkdecoy.rb" --out "$TREE/build/decoy" >/dev/null || \
  die "tools/mkdecoy.rb failed building into $TREE/build/decoy — re-run it directly for the full error: ruby $REPO/tools/mkdecoy.rb --out $TREE/build/decoy"

DECOY_CHECK=$T/decoy-determinism-check
ruby "$REPO/tools/mkdecoy.rb" --out "$DECOY_CHECK" >/dev/null || \
  die "tools/mkdecoy.rb failed on its second (determinism-check) run into $DECOY_CHECK — re-run it directly for the full error: ruby $REPO/tools/mkdecoy.rb --out $DECOY_CHECK"

diff -r "$TREE/build/decoy" "$DECOY_CHECK" >/dev/null || \
  die "tools/mkdecoy.rb produced different output on two runs into separate directories — the decoy is supposed to be byte-identical every time (DEFAULT_UUID/PAGE_UUID are fixed constants in tools/mkdecoy.rb). Compare $TREE/build/decoy and $DECOY_CHECK to see what changed."

# ---- (4) cmp the standalone redoku against the in-tarball bin/redoku

cmp "$ASSET_REDOKU" "$TREE/bin/redoku" || \
  die "internal error: $ASSET_REDOKU and $TREE/bin/redoku differ — they were supposed to be the exact same stamped copy (see step 2 above)"

# ---- (5) emit redoku-rm2.tar.gz and both .sha256 files, staged in $T
#
# The tarball's single top-level entry is redoku/ (the consumer refuses
# any entry not matching ^redoku/) — building it as `-C "$T" redoku`
# rather than `-C "$TREE" .` is what guarantees that.

say "packing redoku-rm2.tar.gz"
ASSET_TARBALL=$T/asset-redoku-rm2.tar.gz
tar -czf "$ASSET_TARBALL" -C "$T" redoku || \
  die "tar failed building redoku-rm2.tar.gz — its own error is above; check that $T is writable and there's free disk space"

ASSET_REDOKU_SHA256=$T/asset-redoku.sha256
ASSET_TARBALL_SHA256=$T/asset-redoku-rm2.tar.gz.sha256
printf '%s  redoku\n' "$(mkkit_digest "$ASSET_REDOKU")" > "$ASSET_REDOKU_SHA256"
printf '%s  redoku-rm2.tar.gz\n' "$(mkkit_digest "$ASSET_TARBALL")" \
  > "$ASSET_TARBALL_SHA256"

# ---- (6) stage tools/install.sh as the fifth asset
#
# No install.sh.sha256 — design doc §3.1: you cannot verify the thing you
# are already piping into a shell, and publishing a checksum that protects
# nothing is worse than publishing none.

ASSET_INSTALL_SH=$T/asset-install.sh
cp "$REPO/tools/install.sh" "$ASSET_INSTALL_SH"

# ---- publish: nothing above touched --out. Every assertion in this
# script — the six missing-input checks, the KIT_VERSION stamp, the decoy
# determinism diff, the cmp above — has now passed, so this is the first
# and only point where --out is written. A run that dies at any point
# before this line leaves --out completely untouched: no fresh asset ever
# sits beside a stale one from an earlier run (design doc §3.4: "failing
# any assertion fails the build").
mkdir -p "$OUT"
cp "$ASSET_INSTALL_SH"     "$OUT/install.sh"
cp "$ASSET_REDOKU"         "$OUT/redoku"
cp "$ASSET_REDOKU_SHA256"  "$OUT/redoku.sha256"
cp "$ASSET_TARBALL"        "$OUT/redoku-rm2.tar.gz"
cp "$ASSET_TARBALL_SHA256" "$OUT/redoku-rm2.tar.gz.sha256"
chmod +x "$OUT/redoku"

# Audit --out itself, not just what this run staged: a stale file already
# sitting in --out from an unrelated earlier run (a hand-planted
# install.sh.sha256, a leftover from a different --version) must fail a
# build that would otherwise look completely successful — "no sixth
# asset" is part of the §3.1 contract, not just something the test suite
# happens to check in a directory it always starts empty.
OUT_EXPECTED='install.sh
redoku
redoku-rm2.tar.gz
redoku-rm2.tar.gz.sha256
redoku.sha256'
OUT_ACTUAL=$(find "$OUT" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort)
[ "$OUT_ACTUAL" = "$OUT_EXPECTED" ] || \
  die "internal error: $OUT holds unexpected contents after what should have been a clean build.
  expected exactly: install.sh redoku redoku.sha256 redoku-rm2.tar.gz redoku-rm2.tar.gz.sha256
  actually found:   $(printf '%s' "$OUT_ACTUAL" | tr '\n' ' ')
  Remove any stale files from $OUT (e.g. left over from an earlier or unrelated run) and re-run."

say "done — five assets in $OUT: install.sh redoku redoku.sha256 redoku-rm2.tar.gz redoku-rm2.tar.gz.sha256"
