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
# literally, so no regex metacharacters in it need escaping.
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
assert_fails() {
  _af_label=$1
  shift
  [ "${1:-}" = -- ] || die "assert_fails: expected -- before the command (label: $_af_label)"
  shift
  set +e
  ASSERT_OUTPUT=$("$@" 2>&1)
  _af_rc=$?
  set -e
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
# Both $REDOKU_TEST_RECORD and $REDOKU_TEST_TMPDIR_RECORD are OPTIONAL —
# a test that only cares whether the stub ran at all (not what it was
# called with) can leave either unset rather than pointing it at a
# throwaway path it never reads.
#
# [marker], when given, is prefixed to the recorded line ("marker argv"),
# so two fixture versions can each get a distinguishable stub — needed by
# test_redoku_version_pins_url to prove WHICH one actually ran, since
# both stubs are always called with the identical argv otherwise.
#
# It also writes its own directory (dirname "$0") to
# $REDOKU_TEST_TMPDIR_RECORD when that's set, letting a test that wants
# to assert the bootstrap's temp dir was removed afterwards learn its
# exact name — install.sh's own trap deletes it before install.sh
# returns, so nothing outside the stub can observe it directly.
write_stub_cli() {
  _wsc_path=$1
  _wsc_marker=${2:-}
  _wsc_prefix=
  [ -z "$_wsc_marker" ] || _wsc_prefix="$_wsc_marker "
  cat > "$_wsc_path" <<STUBEOF
#!/bin/sh
[ -z "\${REDOKU_TEST_RECORD:-}" ] || printf '%s\n' "$_wsc_prefix\$*" > "\$REDOKU_TEST_RECORD"
[ -z "\${REDOKU_TEST_TMPDIR_RECORD:-}" ] || dirname "\$0" > "\$REDOKU_TEST_TMPDIR_RECORD"
exit 0
STUBEOF
  chmod +x "$_wsc_path"
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
# The tarball is a minimal stand-in for THIS task: just redoku/VERSION.
# Task 2 introduces tools/mkkit.sh, which builds the real §3.2 tree; the
# only change that rewiring needs here is swapping the four lines that
# build $_scratch/redoku for a call to mkkit.sh writing into the same
# place — the checksum/symlink/layout code around it does not change.
#
# <cli-source-file> lets each call supply a different stub CLI (see
# write_stub_cli), which is what makes two fixture versions
# distinguishable for the REDOKU_VERSION-pinning test.
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

  _mfr_scratch=$_mfr_dir/.scratch-$_mfr_version
  mkdir -p "$_mfr_scratch/redoku" || die "make_fixture_release: mkdir scratch failed"
  printf '%s\n' "$_mfr_version" > "$_mfr_scratch/redoku/VERSION"
  tar -C "$_mfr_scratch" -czf "$_mfr_pinned/redoku-rm2.tar.gz" redoku || \
    die "make_fixture_release: tar failed for $_mfr_version"
  rm -rf "$_mfr_scratch"
  printf '%s  redoku-rm2.tar.gz\n' "$(kit_digest "$_mfr_pinned/redoku-rm2.tar.gz")" \
    > "$_mfr_pinned/redoku-rm2.tar.gz.sha256"

  cp "$REPO/tools/install.sh" "$_mfr_pinned/install.sh" || \
    die "make_fixture_release: cp install.sh failed"

  mkdir -p "$_mfr_dir/latest" || die "make_fixture_release: mkdir latest failed"
  rm -f "$_mfr_dir/latest/download"
  ln -s "../download/$_mfr_version" "$_mfr_dir/latest/download"
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
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n' "$1"
    TEST_FAILED=$((TEST_FAILED + 1))
  fi
}

# ---- bootstrap tests (tools/install.sh) --------------------------------
#
# Every install.sh invocation below redirects stdin from /dev/null: piped
# real-world use hits install.sh's own "[ -t 0 ] || try /dev/tty" branch
# (see tools/install.sh's comment on it), and /dev/null makes that branch
# run the same deterministic way in an interactive shell, in `make
# test-kit`, and in CI, instead of picking up whatever the harness's own
# stdin happens to be.

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
    sh "$REPO/tools/install.sh" < /dev/null 2>&1)
  _rc=$?
  set -e

  assert_eq 0 "$_rc" "happy path: install.sh exit code (output: $ASSERT_OUTPUT)" || return 1
  assert_file "$_record" "happy path: stub CLI ran" || return 1
  assert_eq "install --download --kit $_home/.redoku" "$(cat "$_record")" \
    "happy path: recorded argv" || return 1
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
    sh "$REPO/tools/install.sh" --yes --dry-run < /dev/null 2>&1)
  _rc=$?
  set -e

  assert_eq 0 "$_rc" "arg passthrough: install.sh exit code (output: $ASSERT_OUTPUT)" || return 1
  assert_eq "install --download --kit $_home/.redoku --yes --dry-run" "$(cat "$_record")" \
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
    sh "$REPO/tools/install.sh" < /dev/null 2>&1)
  _rc=$?
  set -e

  assert_eq 0 "$_rc" "REDOKU_HOME: install.sh exit code (output: $ASSERT_OUTPUT)" || return 1
  # REDOKU_HOME replaces the whole default, it is not $HOME-relative —
  # ${REDOKU_HOME:-$HOME/.redoku} only appends /.redoku in the unset case.
  assert_eq "install --download --kit $_kit" "$(cat "$_record")" \
    "REDOKU_HOME: --kit follows it exactly, no /.redoku suffix" || return 1
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
    sh "$REPO/tools/install.sh" < /dev/null 2>&1)
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
    sh "$REPO/tools/install.sh" < /dev/null || return 1

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

  # A PATH dir holding only symlinks to what install.sh genuinely needs
  # when NO digest tool exists (curl, mktemp, rm, and sh itself — sh has
  # to be reachable through the SAME restricted PATH used for its own
  # internal lookups, since a shell invoked via PATH=... prog also
  # resolves "prog" through that overridden PATH, not the ambient one;
  # verified empirically). Preferred over shadowing shasum/sha256sum/
  # openssl with three failing stubs: an absent file IS "not found" to
  # `command -v` on every shell, where a stub has to correctly fake that
  # across implementations.
  _minpath=$_w/minpath
  mkdir -p "$_minpath"
  for _bin in curl mktemp rm sh; do
    _src=$(command -v "$_bin") || die "test_no_sha256_tool: no '$_bin' on this machine"
    ln -s "$_src" "$_minpath/$_bin"
  done

  assert_fails "no sha256 tool: install.sh exits non-zero" -- \
    env PATH="$_minpath" REDOKU_BASE_URL="file://$_w/release" \
    REDOKU_TEST_RECORD="$_record" HOME="$_home" \
    "$_minpath/sh" "$REPO/tools/install.sh" < /dev/null || return 1

  assert_contains "$ASSERT_OUTPUT" "sha256" "no sha256 tool: message says so" || return 1
  assert_no_file "$_record" "no sha256 tool: the stub CLI never ran" || return 1
}

test_404_missing_asset() {
  _w=$(mktemp -d "$ROOT/404.XXXXXX")
  _home=$_w/home
  mkdir -p "$_home" "$_w/empty-release"

  assert_fails "404 unpinned: install.sh exits non-zero" -- \
    env REDOKU_BASE_URL="file://$_w/empty-release" HOME="$_home" \
    sh "$REPO/tools/install.sh" < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "file://$_w/empty-release" "404 unpinned: message names the URL" || return 1
  assert_contains "$ASSERT_OUTPUT" "no published release" "404 unpinned: wording for the no-REDOKU_VERSION case" || return 1

  assert_fails "404 pinned: install.sh exits non-zero" -- \
    env REDOKU_BASE_URL="file://$_w/empty-release" REDOKU_VERSION=v9.9.9 HOME="$_home" \
    sh "$REPO/tools/install.sh" < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "file://$_w/empty-release" "404 pinned: message names the URL" || return 1
  assert_contains "$ASSERT_OUTPUT" "v9.9.9" "404 pinned: message names the version that may not exist" || return 1
  assert_contains "$ASSERT_OUTPUT" "may not exist" "404 pinned: wording differs from the unpinned case" || return 1
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
    sh "$REPO/tools/install.sh" < /dev/null 2>&1)
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
    sh "$REPO/tools/install.sh" < /dev/null || return 1

  assert_eq 0 "$(count_entries "$_tmpdir")" "cleanup on failure: install.sh's temp dir is gone afterwards" || return 1
}

# ---- main -----------------------------------------------------------------

TESTS='
test_happy_path
test_arg_passthrough
test_redoku_home_honoured
test_redoku_version_pins_url
test_checksum_mismatch
test_no_sha256_tool
test_404_missing_asset
test_tmpdir_cleanup_on_success
test_tmpdir_cleanup_on_failure
'

for _t in $TESTS; do
  run_test "$_t"
done

printf '%s/%s tests passed\n' "$((TEST_COUNT - TEST_FAILED))" "$TEST_COUNT"
[ "$TEST_FAILED" -eq 0 ] || exit 1
