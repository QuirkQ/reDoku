#!/bin/sh
# tools/test/kit_test.sh — offline tests for the prebuilt-kit install path
# (docs/design/prebuilt-kit.md), wired as `make test-kit`.
#
# This file will grow: later milestone tasks append the rest of design doc
# §8's test list here (mkkit.sh's tree, upgrade, uninstall --self, D8's
# path-drift canary...). What's here now is the skeleton — helpers every
# later test will reuse — plus every test §8 assigns to THIS task: the
# tools/install.sh bootstrap, proven with a stub CLI (bin/redoku itself
# gains install --download/--kit in Tasks 2/3, so nothing here drives it).
#
# Every test is OFFLINE (REDOKU_BASE_URL=file://... over a fixture this
# file builds in a temp dir — there is no network in CI) and never touches
# a device. No test may write inside this checkout or to the real $HOME;
# every install.sh invocation below gets its own HOME under $ROOT.
#
# POSIX sh, no bashisms — this has to run under dash and macOS's /bin/sh,
# same as everything it tests.

set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

# Exit 2, not 1: 1 is reserved for "some tests legitimately failed" (the
# summary at the bottom), so a harness-side die — a fixture that couldn't
# be built, a host missing a tool the HARNESS itself needs — is
# distinguishable in CI logs from a real regression.
die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

# ---- scratch space -------------------------------------------------------

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT INT HUP TERM

# ---- shared digest helper -------------------------------------------------
#
# The same shasum -a 256 / sha256sum / openssl dgst -sha256 fallback
# tools/install.sh's own digest step uses, in this one place, so that:
#  (a) make_fixture_release below checksums a fixture exactly the way
#      install.sh will re-verify it, and
#  (b) tests that need to know what a "correct" or "corrupted" digest
#      looks like (test_checksum_mismatch) compute it the same way too,
#      instead of a second, potentially drifting implementation.
# tools/install.sh cannot itself source this — it ships standalone as a
# release asset — so it carries its own copy of the same three-tool
# fallback; this is the "one place" for the harness's half.
kit_digest() { # kit_digest <file> — prints its sha256 as lowercase hex
  _kd_file=$1
  if command -v shasum >/dev/null 2>&1; then
    _kd_line=$(shasum -a 256 "$_kd_file") || die "shasum failed on $_kd_file"
    _kd_hex=${_kd_line%% *}
  elif command -v sha256sum >/dev/null 2>&1; then
    _kd_line=$(sha256sum "$_kd_file") || die "sha256sum failed on $_kd_file"
    _kd_hex=${_kd_line%% *}
  elif command -v openssl >/dev/null 2>&1; then
    # shasum/sha256sum print "<hex>  <path>" (hex first field); openssl
    # prints "SHA2-256(<path>)= <hex>" (hex LAST field, and the label
    # before it differs between OpenSSL and LibreSSL) — one "first field"
    # rule can't cover both shapes.
    _kd_line=$(openssl dgst -sha256 "$_kd_file") || die "openssl dgst failed on $_kd_file"
    _kd_hex=${_kd_line##* }
  else
    die "no sha256 tool (shasum, sha256sum, or openssl) on this machine — the harness itself needs one to build fixtures"
  fi
  printf '%s\n' "$_kd_hex" | tr 'A-F' 'a-f'
}

# ---- assertions -----------------------------------------------------------
#
# None of these exit the suite on failure — they return 1 and print what
# was expected vs. what happened. A test function must chain each assert
# it wants to be fatal to ITS test with "|| return 1": calling a function
# from a position `run_test` tests with `if`/`set +e` suppresses `set -e`
# for everything executed underneath, all the way through nested function
# and even subshell calls (verified against dash, bash and macOS /bin/sh —
# see run_test's comment) — so a bare failing command in a test body does
# NOT abort that test early on its own; only an explicit `|| return 1` does.

# assert_eq <expected> <actual> <label> — string compare.
assert_eq() {
  [ "$1" = "$2" ] && return 0
  printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$3" "$1" "$2" >&2
  return 1
}

# assert_contains <haystack> <needle> <label> — substring check, for
# messages. A `case` pattern, not grep: the quoted needle is matched
# literally, so no regex metacharacters in it need escaping. Pick needles
# that appear ONLY in the branch under test — a needle like bare "sha256"
# also matches an asset URL such as ".../redoku.sha256", so a test can
# pass having proven nothing about which branch actually ran (fix round 1,
# IMPORTANT 3): prefer whole phrases like "no sha256 tool" or "refusing".
assert_contains() {
  case $1 in
    *"$2"*) return 0 ;;
  esac
  printf 'FAIL: %s\n  expected to contain: %s\n  actual: %s\n' "$3" "$2" "$1" >&2
  return 1
}

# assert_file <path> <label> — a regular file exists there.
assert_file() {
  [ -f "$1" ] && return 0
  printf 'FAIL: %s\n  expected a file at: %s\n' "$2" "$1" >&2
  return 1
}

# assert_no_file <path> <label> — nothing at all exists there (-e, not
# -f: this is also used to assert a whole temp DIRECTORY is gone).
assert_no_file() {
  [ ! -e "$1" ] && return 0
  printf 'FAIL: %s\n  expected nothing at: %s\n' "$2" "$1" >&2
  return 1
}

# assert_fails <label> -- <cmd...> — runs <cmd...>, asserts it exits
# non-zero, and leaves its combined stdout+stderr in $ASSERT_OUTPUT for a
# following assert_contains. Brackets the run in explicit set +e/set -e
# rather than trusting the ambient -e-suppression context described
# above, so this is safe to call from anywhere, not just inside a test
# function invoked just so.
#
# It saves and restores the CALLER's own -e state (via `$-`) rather than
# unconditionally turning -e back on afterwards (fix round 1, MINOR 11):
# this is a shared interface later tasks call too, and a caller that had
# deliberately run `set +e` before calling it must get that back, not a
# surprise re-enable.
assert_fails() {
  _af_label=$1
  shift
  [ "${1:-}" = -- ] || die "assert_fails: expected -- before the command (label: $_af_label)"
  shift
  case $- in *e*) _af_had_e=1 ;; *) _af_had_e=0 ;; esac
  set +e
  ASSERT_OUTPUT=$("$@" 2>&1)
  _af_rc=$?
  [ "$_af_had_e" -eq 0 ] || set -e
  if [ "$_af_rc" -eq 0 ]; then
    printf 'FAIL: %s\n  expected non-zero exit, got 0\n  output: %s\n' "$_af_label" "$ASSERT_OUTPUT" >&2
    return 1
  fi
  return 0
}

# count_entries <dir> — number of direct children; used to prove a temp
# dir was cleaned up without needing to know its exact generated name.
count_entries() {
  find "$1" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' '
}

# ---- which shell interprets tools/install.sh ---------------------------
#
# KIT_SH is the seam every install.sh invocation below goes through (fix
# round 1, IMPORTANT 2). The bug that prompted this — a failed `exec <
# /dev/tty` is fatal under dash and under bash-as-sh, but macOS's own
# /bin/sh tolerates it — was invisible to this suite even when the suite
# itself was RUN under dash, because every test still hardcoded a literal
# `sh` at the invocation site, and on this machine that's bash 3.2. The
# fix is structural, not "run the harness under dash once": every place
# that used to say `sh "$REPO/tools/install.sh"` now says
# `"$KIT_SH" "$REPO/tools/install.sh"`, and `main` below runs the ENTIRE
# test list once per interesting shell on this machine, not just once.
# KIT_SHELLS, when already set in the environment, is authoritative and
# nothing below touches it — this is the hook CI uses to add a third shell
# (e.g. busybox ash) without editing this file. Left unset (the normal
# developer-machine case), it defaults to "sh" plus "dash" when dash is
# present.
if [ -z "${KIT_SHELLS:-}" ]; then
  KIT_SHELLS="sh"
  if command -v dash >/dev/null 2>&1; then
    KIT_SHELLS="$KIT_SHELLS dash"
  else
    printf 'NOTE: dash not found on this machine — skipping the dash pass.\n' >&2
    printf '      dash is the shell that caught a fatal-exec regression in review;\n' >&2
    printf '      install it for full coverage.\n' >&2
  fi
fi

# build_minpath <dir> <bin...> — creates <dir> and populates it with
# symlinks to the real location of each named binary, resolved via
# `command -v` — except "sh", which resolves through $KIT_SH so a PATH
# built this way exercises the same shell the rest of the current pass is
# testing, not whatever the ambient default happens to be. Used by tests
# that need to run install.sh with almost nothing on PATH (ones exercising
# what it does when a tool it depends on is missing).
build_minpath() {
  _bmp_dir=$1
  shift
  mkdir -p "$_bmp_dir" || die "build_minpath: mkdir $_bmp_dir failed"
  for _bmp_bin in "$@"; do
    if [ "$_bmp_bin" = sh ]; then
      _bmp_src=$(command -v "$KIT_SH") || die "build_minpath: no '$KIT_SH' on this machine"
    else
      _bmp_src=$(command -v "$_bmp_bin") || die "build_minpath: no '$_bmp_bin' on this machine"
    fi
    ln -s "$_bmp_src" "$_bmp_dir/$_bmp_bin"
  done
}

# ---- stub CLI ---------------------------------------------------------
#
# write_stub_cli <path> [marker] — writes a tiny redoku stand-in used
# across every bootstrap test. It never touches a device or a real kit;
# when $REDOKU_TEST_RECORD is set it records the argv it was called with
# there, and it always exits 0 — exactly enough to prove the bootstrap
# handed it the right command line. Driving the real bin/redoku is out of
# scope here: install --download/--kit are Task 2/3 additions to it, and
# this task is explicitly off-limits from touching that file.
#
# The record is ONE ARGUMENT PER LINE (`printf '%s\n' "$@"`), not a single
# $*-joined line (fix round 1, MINOR 10): $* joins with a space, which is
# indistinguishable from a single argument that legitimately CONTAINS a
# space — so a quoting regression in install.sh (e.g. losing the quotes
# around its --kit value) would go undetected. One line per argument is
# unambiguous either way; see test_kit_path_with_space, which is the
# regression this format exists to catch.
#
# Both $REDOKU_TEST_RECORD and $REDOKU_TEST_TMPDIR_RECORD are OPTIONAL —
# a test that only cares whether the stub ran at all (not what it was
# called with) can leave either unset rather than pointing it at a
# throwaway path it never reads.
#
# [marker], when given, is written as the record's first line, so two
# fixture versions can each get a distinguishable stub — needed by
# test_redoku_version_pins_url to prove WHICH one actually ran, since
# both stubs are always called with the identical argv otherwise. It has
# to be baked into the generated script at WRITE time (not read from an
# env var at run time): the whole point is that the test doesn't know in
# advance which of two fixture assets will actually be fetched and run.
#
# It also writes its own directory (dirname "$0") to
# $REDOKU_TEST_TMPDIR_RECORD when that's set, letting a test that wants
# to assert the bootstrap's temp dir was removed afterwards learn its
# exact name — install.sh's own trap deletes it before install.sh
# returns, so nothing outside the stub can observe it directly.
write_stub_cli() {
  _wsc_path=$1
  _wsc_marker=${2:-}
  cat > "$_wsc_path" <<STUBEOF
#!/bin/sh
if [ -n "\${REDOKU_TEST_RECORD:-}" ]; then
  : > "\$REDOKU_TEST_RECORD"
  [ -z '$_wsc_marker' ] || printf '%s\n' '$_wsc_marker' >> "\$REDOKU_TEST_RECORD"
  printf '%s\n' "\$@" >> "\$REDOKU_TEST_RECORD"
fi
[ -z "\${REDOKU_TEST_TMPDIR_RECORD:-}" ] || dirname "\$0" > "\$REDOKU_TEST_TMPDIR_RECORD"
exit 0
STUBEOF
  chmod +x "$_wsc_path"
}

# make_fake_arm_elf <path> — writes a minimal file that satisfies
# bin/redoku's is_arm_elf (and device/install.sh's own copy of the same
# check): the ELF magic + ELFCLASS32 (7f 45 4c 46 01) at offset 0, and
# e_machine = EM_ARM, little-endian (28 00) at offset 18, padded to 64
# bytes total. tools/mkkit.sh itself is deliberately format-agnostic (see
# its own header) — it would happily pack plain text files — but a LATER
# task drives a REAL `install` against a fixture kit, and pick_artifact /
# find_game there refuse anything that doesn't check out as 32-bit ARM.
# Using this for every fake binary here costs nothing now and is
# load-bearing then, so it's introduced in this task rather than the one
# that first needs it.
#
# Bytes are written via printf's POSIX-guaranteed octal \NNN escapes for
# the two fixed magic sequences, and `dd if=/dev/zero bs=1 count=N` for
# the padding in between and after — not a hand-counted single printf
# string, which is exactly the kind of off-by-one that is invisible on
# sight and only shows up as is_arm_elf inexplicably failing.
make_fake_arm_elf() {
  _mfae_path=$1
  mkdir -p "$(dirname -- "$_mfae_path")" || \
    die "make_fake_arm_elf: mkdir for $_mfae_path failed"
  {
    printf '\177\105\114\106\001'        # offset 0-4: 7f 45 4c 46 01
    dd if=/dev/zero bs=1 count=13 2>/dev/null   # offset 5-17: padding
    printf '\050\000'                     # offset 18-19: e_machine = EM_ARM (LE)
    dd if=/dev/zero bs=1 count=44 2>/dev/null   # offset 20-63: padding to 64 bytes
  } > "$_mfae_path" || die "make_fake_arm_elf: write $_mfae_path failed"
}

# ---- the fixture-release builder ---------------------------------------
#
# make_fixture_release <dir> <version> <cli-source-file>
#
# Populates <dir> with the five release assets named in design doc §3.1
# (install.sh, redoku, redoku.sha256, redoku-rm2.tar.gz,
# redoku-rm2.tar.gz.sha256), laid out so "file://<dir>" is a working
# REDOKU_BASE_URL for BOTH forms a real URL can take:
#   unpinned:  $BASE/latest/download/<asset>
#   pinned:    $BASE/download/<version>/<asset>
# install.sh derives both the same way bin/redoku will (§6.1), so a
# fixture that only satisfied one would leave a whole code path untested.
#
# The real files live under download/<version>/; latest/download is a
# SYMLINK to it (relative: "../download/<version>", so the fixture stays
# self-contained if $dir itself gets moved), not a copy — a symlink is
# what a real static mirror (e.g. a fork serving its releases off GitHub
# Pages) would do to alias "latest" onto the same bytes, and unlike a
# copy it can never drift from the version it points at.
#
# The tarball is built by the real packager, tools/mkkit.sh, against a
# throwaway fake build tree (make_fake_arm_elf, above) — never this repo's
# own build/ — so from here on the suite exercises the actual packaging
# code every other release-consuming test relies on, not a stand-in.
# make_fixture_release only keeps mkkit's tarball + its checksum: the
# top-level "redoku" asset and its checksum stay independently built from
# <cli-source-file> (see write_stub_cli) a few lines up, because the
# bootstrap tests below need a stub they can prove was actually invoked —
# mkkit's own stamped bin/redoku, built from the real checkout, would
# defeat that.
#
# <cli-source-file> lets each call supply a different stub CLI (see
# write_stub_cli), which is what makes two fixture versions
# distinguishable for the REDOKU_VERSION-pinning test.
#
# Sets $MFR_PINNED to the pinned directory it just populated
# ($dir/download/$version), so a test that needs to reach into the
# fixture layout (e.g. to corrupt one file) does so through this value
# instead of reconstructing the download/<version>/ path itself.
make_fixture_release() {
  _mfr_dir=$1
  _mfr_version=$2
  _mfr_cli_src=$3
  [ -f "$_mfr_cli_src" ] || die "make_fixture_release: no such cli-source-file: $_mfr_cli_src"

  _mfr_pinned=$_mfr_dir/download/$_mfr_version
  mkdir -p "$_mfr_pinned" || die "make_fixture_release: mkdir $_mfr_pinned failed"

  cp "$_mfr_cli_src" "$_mfr_pinned/redoku" || die "make_fixture_release: cp redoku failed"
  chmod +x "$_mfr_pinned/redoku"
  printf '%s  redoku\n' "$(kit_digest "$_mfr_pinned/redoku")" > "$_mfr_pinned/redoku.sha256"

  _mfr_fake_build=$_mfr_dir/.fake-build-$_mfr_version
  mkdir -p "$_mfr_fake_build/rm2/bin" "$_mfr_fake_build/rm2fb/dist" || \
    die "make_fixture_release: mkdir fake build tree failed"
  make_fake_arm_elf "$_mfr_fake_build/rm2/bin/redoku"
  make_fake_arm_elf "$_mfr_fake_build/rm2/bin/mruby"
  make_fake_arm_elf "$_mfr_fake_build/rm2/bin/mirb"
  make_fake_arm_elf "$_mfr_fake_build/rm2fb/dist/rm2fb_server_swtcon"
  make_fake_arm_elf "$_mfr_fake_build/rm2fb/dist/librm2fb_client_swtcon.so"
  make_fake_arm_elf "$_mfr_fake_build/rm2fb/dist/rm2fbctl"

  _mfr_kit_out=$_mfr_dir/.kit-out-$_mfr_version
  "$REPO/tools/mkkit.sh" --version "$_mfr_version" --out "$_mfr_kit_out" \
    --build-dir "$_mfr_fake_build" >/dev/null || \
    die "make_fixture_release: tools/mkkit.sh failed for $_mfr_version"
  cp "$_mfr_kit_out/redoku-rm2.tar.gz" "$_mfr_pinned/redoku-rm2.tar.gz" || \
    die "make_fixture_release: cp redoku-rm2.tar.gz failed"
  cp "$_mfr_kit_out/redoku-rm2.tar.gz.sha256" "$_mfr_pinned/redoku-rm2.tar.gz.sha256" || \
    die "make_fixture_release: cp redoku-rm2.tar.gz.sha256 failed"
  rm -rf "$_mfr_fake_build" "$_mfr_kit_out"

  cp "$REPO/tools/install.sh" "$_mfr_pinned/install.sh" || \
    die "make_fixture_release: cp install.sh failed"

  mkdir -p "$_mfr_dir/latest" || die "make_fixture_release: mkdir latest failed"
  rm -f "$_mfr_dir/latest/download"
  ln -s "../download/$_mfr_version" "$_mfr_dir/latest/download"

  MFR_PINNED=$_mfr_pinned
}

# ---- test registration + runner ----------------------------------------

TEST_COUNT=0
TEST_FAILED=0

# run_test <test-fn> — invokes it, prints "ok"/"FAIL <name>", and counts.
# Calling it via `if "$1"; then`/`else` — rather than the more obvious
# `set +e; "$1"; rc=$?; set -e` — makes no difference here: both forms
# suppress `set -e` for everything the test function does, verified
# empirically (dash/bash/macOS-sh agree) — the shell's errexit-suppression
# for a command being tested by if/&&/||/! propagates through every
# nested function and subshell call made while evaluating it, not just
# the outermost one. That is WHY every assert_* call above returns 1
# instead of relying on -e, and why a test that wants one failure to stop
# it early must chain "|| return 1" explicitly.
run_test() {
  TEST_COUNT=$((TEST_COUNT + 1))
  if "$1"; then
    printf 'ok   %s (KIT_SH=%s)\n' "$1" "$KIT_SH"
  else
    printf 'FAIL %s (KIT_SH=%s)\n' "$1" "$KIT_SH"
    TEST_FAILED=$((TEST_FAILED + 1))
  fi
}

# ---- bootstrap tests (tools/install.sh) --------------------------------
#
# Every install.sh invocation below redirects stdin from /dev/null: piped
# real-world use hits install.sh's own tty-reopening probe —
# `[ ! -t 0 ] && [ -e /dev/tty ] && (: < /dev/tty) 2>/dev/null` guarding an
# `exec < /dev/tty` (see tools/install.sh's comment on it) — and /dev/null
# makes that branch run the same deterministic way in an interactive
# shell, in `make test-kit`, and in CI, instead of picking up whatever the
# harness's own stdin happens to be. Every invocation goes through
# "$KIT_SH", not a bare `sh` (see the KIT_SHELLS comment above).
#
# A real limitation, not a gap this suite closes: none of the above
# exercises the ENXIO branch the Critical fix (4171f68) addressed. That
# needs /dev/tty to EXIST but FAIL to open — no controlling terminal at
# all, e.g. a container run without -t, systemd, or `ssh host 'cmd'` with
# no pty — and every test here still runs under whatever session invoked
# `make test-kit`. Where that session already has a controlling terminal
# (an ordinary developer's shell), `(: < /dev/tty)` above succeeds
# trivially and the exec goes through with no observable difference from
# a reverted, unguarded `exec < /dev/tty`. The KIT_SHELLS seam catches a
# different class of blind spot (dash vs. bash-as-sh disagreeing on error
# handling for the SAME failing exec); it does not catch this one. Running
# `make test-kit` from a developer's own terminal will not catch a revert
# of the Critical fix — say so here, so nobody later assumes this suite's
# coverage is stronger than it is.

test_happy_path() {
  _w=$(mktemp -d "$ROOT/happy.XXXXXX")
  _home=$_w/home
  mkdir -p "$_home"
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"
  _record=$_w/record

  set +e
  ASSERT_OUTPUT=$(REDOKU_BASE_URL="file://$_w/release" \
    REDOKU_TEST_RECORD="$_record" HOME="$_home" \
    "$KIT_SH" "$REPO/tools/install.sh" < /dev/null 2>&1)
  _rc=$?
  set -e

  assert_eq 0 "$_rc" "happy path: install.sh exit code (output: $ASSERT_OUTPUT)" || return 1
  assert_file "$_record" "happy path: stub CLI ran" || return 1
  _expected=$(printf 'install\n--download\n--kit\n%s\n' "$_home/.redoku")
  assert_eq "$_expected" "$(cat "$_record")" "happy path: recorded argv" || return 1
}

test_arg_passthrough() {
  _w=$(mktemp -d "$ROOT/argv.XXXXXX")
  _home=$_w/home
  mkdir -p "$_home"
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"
  _record=$_w/record

  set +e
  ASSERT_OUTPUT=$(REDOKU_BASE_URL="file://$_w/release" \
    REDOKU_TEST_RECORD="$_record" HOME="$_home" \
    "$KIT_SH" "$REPO/tools/install.sh" --yes --dry-run < /dev/null 2>&1)
  _rc=$?
  set -e

  assert_eq 0 "$_rc" "arg passthrough: install.sh exit code (output: $ASSERT_OUTPUT)" || return 1
  _expected=$(printf 'install\n--download\n--kit\n%s\n--yes\n--dry-run\n' "$_home/.redoku")
  assert_eq "$_expected" "$(cat "$_record")" \
    "arg passthrough: extra args land after the fixed ones" || return 1
}

test_redoku_home_honoured() {
  _w=$(mktemp -d "$ROOT/home.XXXXXX")
  _home=$_w/home
  _kit=$_w/somewhere-else/kit
  mkdir -p "$_home"
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"
  _record=$_w/record

  set +e
  ASSERT_OUTPUT=$(REDOKU_BASE_URL="file://$_w/release" \
    REDOKU_TEST_RECORD="$_record" HOME="$_home" REDOKU_HOME="$_kit" \
    "$KIT_SH" "$REPO/tools/install.sh" < /dev/null 2>&1)
  _rc=$?
  set -e

  assert_eq 0 "$_rc" "REDOKU_HOME: install.sh exit code (output: $ASSERT_OUTPUT)" || return 1
  # REDOKU_HOME replaces the whole default, it is not $HOME-relative —
  # ${REDOKU_HOME:-$HOME/.redoku} only appends /.redoku in the unset case.
  _expected=$(printf 'install\n--download\n--kit\n%s\n' "$_kit")
  assert_eq "$_expected" "$(cat "$_record")" \
    "REDOKU_HOME: --kit follows it exactly, no /.redoku suffix" || return 1
}

test_kit_path_with_space() {
  # Fix round 1, MINOR 10's regression case: if install.sh's --kit value
  # ever lost its quoting, a HOME containing a space would split into two
  # argv entries. write_stub_cli's one-line-per-argument record is what
  # makes that visible; a $*-joined line would look identical either way.
  _w=$(mktemp -d "$ROOT/space.XXXXXX")
  _home="$_w/ho me"
  mkdir -p "$_home"
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"
  _record=$_w/record

  set +e
  ASSERT_OUTPUT=$(REDOKU_BASE_URL="file://$_w/release" \
    REDOKU_TEST_RECORD="$_record" HOME="$_home" \
    "$KIT_SH" "$REPO/tools/install.sh" < /dev/null 2>&1)
  _rc=$?
  set -e

  assert_eq 0 "$_rc" "HOME with a space: install.sh exit code (output: $ASSERT_OUTPUT)" || return 1
  _expected=$(printf 'install\n--download\n--kit\n%s\n' "$_home/.redoku")
  assert_eq "$_expected" "$(cat "$_record")" \
    "HOME with a space: --kit stayed one argument, not two" || return 1
}

test_no_home_no_redoku_home() {
  # Fix round 1, IMPORTANT 7: "${REDOKU_HOME:-$HOME/.redoku}" still
  # evaluates $HOME under set -u the moment REDOKU_HOME is unset, even
  # when $HOME is ALSO entirely unset — that used to die with a bare
  # "HOME: parameter not set", naming no fix. Both env vars are
  # legitimately unset for this one process (not written elsewhere on the
  # real $HOME — the download succeeds, but the guard fires before
  # anything is written anywhere).
  _w=$(mktemp -d "$ROOT/nohome.XXXXXX")
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"
  _record=$_w/record

  assert_fails "no HOME, no REDOKU_HOME: install.sh exits non-zero" -- \
    env -u HOME -u REDOKU_HOME REDOKU_BASE_URL="file://$_w/release" \
    REDOKU_TEST_RECORD="$_record" \
    "$KIT_SH" "$REPO/tools/install.sh" < /dev/null || return 1

  assert_contains "$ASSERT_OUTPUT" "REDOKU_HOME" "no HOME, no REDOKU_HOME: message names a fix" || return 1
  assert_no_file "$_record" "no HOME, no REDOKU_HOME: the stub CLI never ran" || return 1
}

test_redoku_version_pins_url() {
  _w=$(mktemp -d "$ROOT/pin.XXXXXX")
  _home=$_w/home
  mkdir -p "$_home"
  write_stub_cli "$_w/cli-old" OLD
  write_stub_cli "$_w/cli-new" NEW
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli-old"
  make_fixture_release "$_w/release" v0.2.0 "$_w/cli-new"
  _record=$_w/record

  set +e
  ASSERT_OUTPUT=$(REDOKU_BASE_URL="file://$_w/release" REDOKU_VERSION=v0.1.0 \
    REDOKU_TEST_RECORD="$_record" HOME="$_home" \
    "$KIT_SH" "$REPO/tools/install.sh" < /dev/null 2>&1)
  _rc=$?
  set -e

  assert_eq 0 "$_rc" "version pin: install.sh exit code (output: $ASSERT_OUTPUT)" || return 1
  assert_contains "$(cat "$_record")" "OLD" \
    "version pin: the older (pinned) CLI ran, not latest" || return 1
}

test_checksum_mismatch() {
  _w=$(mktemp -d "$ROOT/badsum.XXXXXX")
  _home=$_w/home
  mkdir -p "$_home"
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"
  _asset=$_w/release/download/v0.1.0/redoku
  _expect=$(kit_digest "$_asset")
  # Corrupted AFTER the checksum was written, so redoku.sha256 still
  # names the pre-corruption digest — exactly the mismatch install.sh
  # must catch.
  printf '\n# corrupted for test_checksum_mismatch\n' >> "$_asset"
  _actual=$(kit_digest "$_asset")
  [ "$_expect" != "$_actual" ] || die "test_checksum_mismatch: corruption didn't change the digest"

  _record=$_w/record
  _tmpdir=$(mktemp -d "$ROOT/badsum-tmpdir.XXXXXX")
  [ "$(count_entries "$_tmpdir")" = 0 ] || die "test_checksum_mismatch: dedicated TMPDIR not empty before the run"

  assert_fails "checksum mismatch: install.sh exits non-zero" -- \
    env REDOKU_BASE_URL="file://$_w/release" REDOKU_TEST_RECORD="$_record" \
    HOME="$_home" TMPDIR="$_tmpdir" \
    "$KIT_SH" "$REPO/tools/install.sh" < /dev/null || return 1

  assert_contains "$ASSERT_OUTPUT" "$_expect" "checksum mismatch: message names the expected digest" || return 1
  assert_contains "$ASSERT_OUTPUT" "$_actual" "checksum mismatch: message names the actual digest" || return 1
  assert_contains "$ASSERT_OUTPUT" "file://$_w/release" "checksum mismatch: message names the URL" || return 1
  assert_no_file "$_record" "checksum mismatch: the stub CLI never ran" || return 1
  assert_eq 0 "$(count_entries "$_tmpdir")" "checksum mismatch: install.sh's temp dir was cleaned up" || return 1
}

test_no_sha256_tool() {
  _w=$(mktemp -d "$ROOT/nodigest.XXXXXX")
  _home=$_w/home
  mkdir -p "$_home"
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"
  _record=$_w/record

  # Preferred over shadowing shasum/sha256sum/openssl with three failing
  # stubs: an absent file IS "not found" to `command -v` on every shell,
  # where a stub has to correctly fake that across implementations.
  _minpath=$_w/minpath
  build_minpath "$_minpath" curl mktemp rm sh

  assert_fails "no sha256 tool: install.sh exits non-zero" -- \
    env PATH="$_minpath" REDOKU_BASE_URL="file://$_w/release" \
    REDOKU_TEST_RECORD="$_record" HOME="$_home" \
    "$_minpath/sh" "$REPO/tools/install.sh" < /dev/null || return 1

  # Fix round 1, IMPORTANT 3: bare "sha256" also matches the asset URL
  # ".../redoku.sha256" (e.g. if redoku.sha256 were the thing missing,
  # producing "could not download .../redoku.sha256"), so that needle
  # passed vacuously without proving refusal happened at all. "no sha256
  # tool" appears only in the branch this test exists to exercise.
  assert_contains "$ASSERT_OUTPUT" "no sha256 tool" "no sha256 tool: message says so, specifically" || return 1
  assert_no_file "$_record" "no sha256 tool: the stub CLI never ran" || return 1
}

test_no_curl() {
  # Fix round 1, MINOR 9: the no-curl branch (design doc §7's failure
  # catalogue) had no covering test — one omitted symlink away from
  # test_no_sha256_tool's own build_minpath call.
  _w=$(mktemp -d "$ROOT/nocurl.XXXXXX")
  _home=$_w/home
  mkdir -p "$_home"
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"
  _record=$_w/record

  _minpath=$_w/minpath
  build_minpath "$_minpath" mktemp rm sh

  assert_fails "no curl: install.sh exits non-zero" -- \
    env PATH="$_minpath" REDOKU_BASE_URL="file://$_w/release" \
    REDOKU_TEST_RECORD="$_record" HOME="$_home" \
    "$_minpath/sh" "$REPO/tools/install.sh" < /dev/null || return 1

  assert_contains "$ASSERT_OUTPUT" "no 'curl'" "no curl: message says so" || return 1
  assert_contains "$ASSERT_OUTPUT" "--artifacts" "no curl: message names an offline route" || return 1
  assert_no_file "$_record" "no curl: the stub CLI never ran" || return 1
}

test_404_missing_asset() {
  _w=$(mktemp -d "$ROOT/404.XXXXXX")
  _home=$_w/home
  mkdir -p "$_home" "$_w/empty-release"

  assert_fails "404 unpinned: install.sh exits non-zero" -- \
    env REDOKU_BASE_URL="file://$_w/empty-release" HOME="$_home" \
    "$KIT_SH" "$REPO/tools/install.sh" < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "file://$_w/empty-release" "404 unpinned: message names the URL" || return 1
  assert_contains "$ASSERT_OUTPUT" "no published release" "404 unpinned: wording for the no-REDOKU_VERSION case" || return 1

  assert_fails "404 pinned: install.sh exits non-zero" -- \
    env REDOKU_BASE_URL="file://$_w/empty-release" REDOKU_VERSION=v9.9.9 HOME="$_home" \
    "$KIT_SH" "$REPO/tools/install.sh" < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "file://$_w/empty-release" "404 pinned: message names the URL" || return 1
  assert_contains "$ASSERT_OUTPUT" "v9.9.9" "404 pinned: message names the version that may not exist" || return 1
  assert_contains "$ASSERT_OUTPUT" "may not exist" "404 pinned: wording differs from the unpinned case" || return 1
}

test_empty_checksum_file() {
  # Fix round 1, IMPORTANT 4: `read` hits EOF on an empty (or
  # newline-less, truncated) redoku.sha256 and returns non-zero; under
  # set -eu that used to exit the whole script with NO message at all.
  _w=$(mktemp -d "$ROOT/emptysum.XXXXXX")
  _home=$_w/home
  mkdir -p "$_home"
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"
  _record=$_w/record
  # Through $MFR_PINNED (make_fixture_release's own output value), not a
  # hand-reconstructed "download/v0.1.0/" path — the fixture's internal
  # layout is that function's business, not this test's.
  : > "$MFR_PINNED/redoku.sha256"

  assert_fails "empty checksum file: install.sh exits non-zero" -- \
    env REDOKU_BASE_URL="file://$_w/release" REDOKU_TEST_RECORD="$_record" \
    HOME="$_home" "$KIT_SH" "$REPO/tools/install.sh" < /dev/null || return 1

  assert_contains "$ASSERT_OUTPUT" "empty or unreadable" "empty checksum file: message says so, not silence" || return 1
  assert_contains "$ASSERT_OUTPUT" "redoku.sha256" "empty checksum file: message names the file" || return 1
  assert_no_file "$_record" "empty checksum file: the stub CLI never ran" || return 1
}

test_tmpdir_cleanup_on_success() {
  _w=$(mktemp -d "$ROOT/cleanup-ok.XXXXXX")
  _home=$_w/home
  mkdir -p "$_home"
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"
  _tmpdir=$(mktemp -d "$ROOT/cleanup-ok-tmpdir.XXXXXX")
  [ "$(count_entries "$_tmpdir")" = 0 ] || die "test_tmpdir_cleanup_on_success: dedicated TMPDIR not empty before the run"

  set +e
  ASSERT_OUTPUT=$(REDOKU_BASE_URL="file://$_w/release" HOME="$_home" TMPDIR="$_tmpdir" \
    REDOKU_TEST_RECORD="$_w/record" \
    "$KIT_SH" "$REPO/tools/install.sh" < /dev/null 2>&1)
  _rc=$?
  set -e

  assert_eq 0 "$_rc" "cleanup on success: install.sh exit code (output: $ASSERT_OUTPUT)" || return 1
  assert_eq 0 "$(count_entries "$_tmpdir")" "cleanup on success: install.sh's temp dir is gone afterwards" || return 1
}

test_tmpdir_cleanup_on_failure() {
  _w=$(mktemp -d "$ROOT/cleanup-fail.XXXXXX")
  _home=$_w/home
  mkdir -p "$_home" "$_w/empty-release"
  _tmpdir=$(mktemp -d "$ROOT/cleanup-fail-tmpdir.XXXXXX")
  [ "$(count_entries "$_tmpdir")" = 0 ] || die "test_tmpdir_cleanup_on_failure: dedicated TMPDIR not empty before the run"

  assert_fails "cleanup on failure: install.sh exits non-zero" -- \
    env REDOKU_BASE_URL="file://$_w/empty-release" HOME="$_home" TMPDIR="$_tmpdir" \
    "$KIT_SH" "$REPO/tools/install.sh" < /dev/null || return 1

  assert_eq 0 "$(count_entries "$_tmpdir")" "cleanup on failure: install.sh's temp dir is gone afterwards" || return 1
}

# ---- mkkit.sh tests (design doc §8 test 1) -------------------------------
#
# "mkkit.sh emits exactly the §3.2 tree; the in-tarball CLI cmp's equal to
# the standalone asset." Unlike the bootstrap tests above, these drive
# tools/mkkit.sh directly — it is the packager under test here, not
# something tools/install.sh happens to consume, and none of it touches
# tools/install.sh at all. Every fixture build tree is a fresh temp dir
# under $ROOT, never this repo's own build/ (make_fake_arm_elf's job).
# Like the bootstrap tests, every invocation goes through "$KIT_SH" rather
# than mkkit.sh's own #!/bin/sh shebang, so both interpreters' pass gets
# real coverage of mkkit.sh's own portability, not just install.sh's.

# build_fake_kit_inputs <dir> — the six files tools/mkkit.sh reads from
# --build-dir <dir>: rm2/bin/{redoku,mruby,mirb} and
# rm2fb/dist/{rm2fb_server_swtcon,librm2fb_client_swtcon.so,rm2fbctl}, each
# written by make_fake_arm_elf.
build_fake_kit_inputs() {
  _bfki_dir=$1
  make_fake_arm_elf "$_bfki_dir/rm2/bin/redoku"
  make_fake_arm_elf "$_bfki_dir/rm2/bin/mruby"
  make_fake_arm_elf "$_bfki_dir/rm2/bin/mirb"
  make_fake_arm_elf "$_bfki_dir/rm2fb/dist/rm2fb_server_swtcon"
  make_fake_arm_elf "$_bfki_dir/rm2fb/dist/librm2fb_client_swtcon.so"
  make_fake_arm_elf "$_bfki_dir/rm2fb/dist/rm2fbctl"
}

# The exact §3.2 entry list as `tar -tzf | LC_ALL=C sort` produces it.
# LC_ALL=C matters, not decoration: measured directly on this machine,
# plain `sort` under en_US.UTF-8 sorts "redoku/VERSION" LAST — after every
# lowercase "redoku/b...", "redoku/build/..." entry — while the C locale's
# plain byte-value order sorts it right after "redoku/", because 'V' (0x56)
# is less than 'b' (0x62) in ASCII and en_US.UTF-8's collation folds case
# instead. A test comparing sorted output against a literal list must pin
# the locale it sorts under, or it passes or fails depending on which
# machine runs it rather than on what mkkit actually produced.
KIT_TREE_EXPECTED='redoku/
redoku/VERSION
redoku/bin/
redoku/bin/redoku
redoku/build/
redoku/build/decoy/
redoku/build/decoy/c9f2b3a4-1e6d-4b8f-9c3a-7d5e2f108a6b.content
redoku/build/decoy/c9f2b3a4-1e6d-4b8f-9c3a-7d5e2f108a6b.metadata
redoku/build/decoy/c9f2b3a4-1e6d-4b8f-9c3a-7d5e2f108a6b.pagedata
redoku/build/decoy/c9f2b3a4-1e6d-4b8f-9c3a-7d5e2f108a6b.pdf
redoku/build/decoy/watch.conf
redoku/build/rm2/
redoku/build/rm2/bin/
redoku/build/rm2/bin/mirb
redoku/build/rm2/bin/mruby
redoku/build/rm2/bin/redoku
redoku/build/rm2fb/
redoku/build/rm2fb/dist/
redoku/build/rm2fb/dist/librm2fb_client_swtcon.so
redoku/build/rm2fb/dist/rm2fb_server_swtcon
redoku/build/rm2fb/dist/rm2fbctl
redoku/device/
redoku/device/install.sh
redoku/device/redoku-watcher.service
redoku/device/uninstall.sh'

# Assertion 1: all five §3.1 assets exist in --out, and no sixth — in
# particular no install.sh.sha256 (design doc §3.1: you cannot verify the
# thing you are already piping into a shell).
test_mkkit_five_assets_only() {
  _w=$(mktemp -d "$ROOT/mkkit-assets.XXXXXX")
  build_fake_kit_inputs "$_w/build"
  _out=$_w/out

  "$KIT_SH" "$REPO/tools/mkkit.sh" --version v0.3.0 --out "$_out" --build-dir "$_w/build" \
    >/dev/null || die "test_mkkit_five_assets_only: mkkit.sh failed"

  assert_file "$_out/install.sh"              "five assets: install.sh present" || return 1
  assert_file "$_out/redoku"                  "five assets: redoku present" || return 1
  assert_file "$_out/redoku.sha256"            "five assets: redoku.sha256 present" || return 1
  assert_file "$_out/redoku-rm2.tar.gz"        "five assets: redoku-rm2.tar.gz present" || return 1
  assert_file "$_out/redoku-rm2.tar.gz.sha256" "five assets: redoku-rm2.tar.gz.sha256 present" || return 1
  assert_no_file "$_out/install.sh.sha256" \
    "five assets: no install.sh.sha256 asset" || return 1
  assert_eq 5 "$(count_entries "$_out")" "five assets: exactly five files in --out, no sixth" || return 1
}

# Assertions 2+3: the tarball's entry list is EXACTLY the §3.2 tree (a
# missing entry and an unexpected extra one must both fail this), and
# every entry starts with redoku/. This is the milestone's canary for
# layout drift, so a mismatch prints a real diff, not just "not equal".
test_mkkit_tarball_layout() {
  _w=$(mktemp -d "$ROOT/mkkit-layout.XXXXXX")
  build_fake_kit_inputs "$_w/build"
  _out=$_w/out

  "$KIT_SH" "$REPO/tools/mkkit.sh" --version v0.3.0 --out "$_out" --build-dir "$_w/build" \
    >/dev/null || die "test_mkkit_tarball_layout: mkkit.sh failed"

  printf '%s\n' "$KIT_TREE_EXPECTED" > "$_w/expected-tree"
  tar -tzf "$_out/redoku-rm2.tar.gz" | LC_ALL=C sort > "$_w/actual-tree"

  if cmp -s "$_w/expected-tree" "$_w/actual-tree"; then
    _layout_match=0
  else
    _layout_match=1
    printf 'FAIL: tarball layout: entry list does not match §3.2 exactly\n' >&2
    diff -u "$_w/expected-tree" "$_w/actual-tree" >&2 || true
  fi
  assert_eq 0 "$_layout_match" "tarball layout: entry list matches §3.2 exactly" || return 1

  while IFS= read -r _entry; do
    case $_entry in
      redoku/*) ;;
      *) printf 'FAIL: tarball layout: entry outside redoku/: %s\n' "$_entry" >&2; return 1 ;;
    esac
  done < "$_w/actual-tree"
}

# Assertion 4: the standalone redoku asset cmp's equal to the extracted
# redoku/bin/redoku.
test_mkkit_cmp_standalone_vs_tarball() {
  _w=$(mktemp -d "$ROOT/mkkit-cmp.XXXXXX")
  build_fake_kit_inputs "$_w/build"
  _out=$_w/out

  "$KIT_SH" "$REPO/tools/mkkit.sh" --version v0.3.0 --out "$_out" --build-dir "$_w/build" \
    >/dev/null || die "test_mkkit_cmp_standalone_vs_tarball: mkkit.sh failed"

  _extract=$_w/extract
  mkdir -p "$_extract"
  tar -xzf "$_out/redoku-rm2.tar.gz" -C "$_extract" || \
    die "test_mkkit_cmp_standalone_vs_tarball: tar -x failed"

  if cmp -s "$_out/redoku" "$_extract/redoku/bin/redoku"; then _cmp_rc=0; else _cmp_rc=1; fi
  assert_eq 0 "$_cmp_rc" "cmp: standalone redoku equals redoku/bin/redoku inside the tarball" || return 1
}

# Assertion 5: redoku/VERSION matches --version, trailing newline
# included, and --version omitted yields "dev". Compared with `cmp`
# against a byte-exact expected file rather than two $(...)-captured
# strings — command substitution strips ALL trailing newlines from BOTH
# sides, which would make a "trailing newline included" assertion pass no
# matter what VERSION actually contained.
test_mkkit_version_file() {
  _w=$(mktemp -d "$ROOT/mkkit-version.XXXXXX")
  build_fake_kit_inputs "$_w/build"

  _out1=$_w/out-pinned
  "$KIT_SH" "$REPO/tools/mkkit.sh" --version v0.4.1 --out "$_out1" --build-dir "$_w/build" \
    >/dev/null || die "test_mkkit_version_file: mkkit.sh (pinned) failed"
  _extract1=$_w/extract-pinned
  mkdir -p "$_extract1"
  tar -xzf "$_out1/redoku-rm2.tar.gz" -C "$_extract1" || \
    die "test_mkkit_version_file: tar -x (pinned) failed"
  printf 'v0.4.1\n' > "$_w/expected-pinned"
  if cmp -s "$_extract1/redoku/VERSION" "$_w/expected-pinned"; then _rc1=0; else _rc1=1; fi
  assert_eq 0 "$_rc1" "VERSION: byte-exact 'v0.4.1\\n' for --version v0.4.1" || return 1

  _out2=$_w/out-default
  "$KIT_SH" "$REPO/tools/mkkit.sh" --out "$_out2" --build-dir "$_w/build" \
    >/dev/null || die "test_mkkit_version_file: mkkit.sh (default) failed"
  _extract2=$_w/extract-default
  mkdir -p "$_extract2"
  tar -xzf "$_out2/redoku-rm2.tar.gz" -C "$_extract2" || \
    die "test_mkkit_version_file: tar -x (default) failed"
  printf 'dev\n' > "$_w/expected-default"
  if cmp -s "$_extract2/redoku/VERSION" "$_w/expected-default"; then _rc2=0; else _rc2=1; fi
  assert_eq 0 "$_rc2" "VERSION: --version omitted defaults to 'dev\\n'" || return 1
}

# Assertion 6: the stamp landed — redoku/bin/redoku contains the line
# KIT_VERSION=<version> and no longer contains KIT_VERSION=dev. grep -x
# (whole-line match) so a comment mentioning the version elsewhere in the
# file can't satisfy this by accident.
test_mkkit_stamp_landed() {
  _w=$(mktemp -d "$ROOT/mkkit-stamp.XXXXXX")
  build_fake_kit_inputs "$_w/build"
  _out=$_w/out

  "$KIT_SH" "$REPO/tools/mkkit.sh" --version v0.5.2 --out "$_out" --build-dir "$_w/build" \
    >/dev/null || die "test_mkkit_stamp_landed: mkkit.sh failed"
  _extract=$_w/extract
  mkdir -p "$_extract"
  tar -xzf "$_out/redoku-rm2.tar.gz" -C "$_extract" || \
    die "test_mkkit_stamp_landed: tar -x failed"

  _cli=$_extract/redoku/bin/redoku
  if grep -qx 'KIT_VERSION=v0.5.2' "$_cli"; then _stamped=0; else _stamped=1; fi
  assert_eq 0 "$_stamped" "stamp: redoku/bin/redoku contains the line KIT_VERSION=v0.5.2" || return 1
  if grep -qx 'KIT_VERSION=dev' "$_cli"; then _still_dev=1; else _still_dev=0; fi
  assert_eq 0 "$_still_dev" "stamp: redoku/bin/redoku no longer contains KIT_VERSION=dev" || return 1
}

# Assertion 7: both .sha256 files verify their asset — recompute with
# kit_digest (this file's own independent implementation, not mkkit's) and
# string-compare against the checksum file's first field.
test_mkkit_checksums_verify() {
  _w=$(mktemp -d "$ROOT/mkkit-sum.XXXXXX")
  build_fake_kit_inputs "$_w/build"
  _out=$_w/out

  "$KIT_SH" "$REPO/tools/mkkit.sh" --version v0.6.0 --out "$_out" --build-dir "$_w/build" \
    >/dev/null || die "test_mkkit_checksums_verify: mkkit.sh failed"

  _redoku_digest=$(kit_digest "$_out/redoku")
  _redoku_sum_field=$(awk '{print $1; exit}' "$_out/redoku.sha256")
  assert_eq "$_redoku_digest" "$_redoku_sum_field" \
    "checksum: redoku.sha256's first field matches redoku's recomputed digest" || return 1

  _tar_digest=$(kit_digest "$_out/redoku-rm2.tar.gz")
  _tar_sum_field=$(awk '{print $1; exit}' "$_out/redoku-rm2.tar.gz.sha256")
  assert_eq "$_tar_digest" "$_tar_sum_field" \
    "checksum: redoku-rm2.tar.gz.sha256's first field matches the tarball's recomputed digest" || return 1
}

# Assertion 8: a missing input (one of the six fake binaries) makes
# mkkit.sh exit non-zero with a message naming that file.
test_mkkit_missing_input_names_file() {
  _w=$(mktemp -d "$ROOT/mkkit-missing.XXXXXX")
  build_fake_kit_inputs "$_w/build"
  rm -f "$_w/build/rm2fb/dist/rm2fbctl"
  _out=$_w/out

  assert_fails "mkkit missing input: exits non-zero" -- \
    "$KIT_SH" "$REPO/tools/mkkit.sh" --version v0.1.0 --out "$_out" --build-dir "$_w/build" || return 1

  assert_contains "$ASSERT_OUTPUT" "rm2fbctl" \
    "mkkit missing input: message names the missing file" || return 1
  assert_contains "$ASSERT_OUTPUT" "make rm2fb" \
    "mkkit missing input: message names the make target that produces it" || return 1
}

# ---- main -----------------------------------------------------------------

TESTS='
test_happy_path
test_arg_passthrough
test_redoku_home_honoured
test_kit_path_with_space
test_no_home_no_redoku_home
test_redoku_version_pins_url
test_checksum_mismatch
test_no_sha256_tool
test_no_curl
test_404_missing_asset
test_empty_checksum_file
test_tmpdir_cleanup_on_success
test_tmpdir_cleanup_on_failure
'

MKKIT_TESTS='
test_mkkit_five_assets_only
test_mkkit_tarball_layout
test_mkkit_cmp_standalone_vs_tarball
test_mkkit_version_file
test_mkkit_stamp_landed
test_mkkit_checksums_verify
test_mkkit_missing_input_names_file
'

for KIT_SH in $KIT_SHELLS; do
  printf '=== bootstrap tests under KIT_SH=%s ===\n' "$KIT_SH"
  for _t in $TESTS; do
    run_test "$_t"
  done
done

for KIT_SH in $KIT_SHELLS; do
  printf '=== mkkit.sh tests under KIT_SH=%s ===\n' "$KIT_SH"
  for _t in $MKKIT_TESTS; do
    run_test "$_t"
  done
done

printf '%s/%s tests passed\n' "$((TEST_COUNT - TEST_FAILED))" "$TEST_COUNT"
[ "$TEST_FAILED" -eq 0 ] || exit 1
