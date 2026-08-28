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

REPO=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)

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
#
# Self-checked on every call, not just trusted to have worked: this file
# is explicitly load-bearing for a LATER task (pick_artifact / is_arm_elf
# there select only files that check out as 32-bit ARM), so a shell whose
# printf mishandles or truncates the octal escapes above must fail LOUDLY
# here, not surface three tasks from now as a mysterious is_arm_elf
# rejection nobody can explain. The check re-reads the same two offsets
# bin/redoku's own is_arm_elf reads (dd + od -An -tx1, the same technique
# its _hex_at helper uses) — an independent re-derivation of "did this
# actually come out right", not a trust-the-loop-above assumption.
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

  _mfae_size=$(wc -c < "$_mfae_path" | tr -d '[:space:]')
  [ "$_mfae_size" -ge 64 ] || \
    die "make_fake_arm_elf: $_mfae_path is $_mfae_size bytes, expected >= 64 — this shell's printf may have mishandled the octal escapes above"
  _mfae_magic=$(dd if="$_mfae_path" bs=1 skip=0 count=5 2>/dev/null | od -An -tx1 | tr -d ' \n')
  [ "$_mfae_magic" = 7f454c4601 ] || \
    die "make_fake_arm_elf: $_mfae_path has $_mfae_magic at offset 0-4, expected 7f454c4601 — bin/redoku's is_arm_elf would reject this file"
  _mfae_machine=$(dd if="$_mfae_path" bs=1 skip=18 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
  [ "$_mfae_machine" = 2800 ] || \
    die "make_fake_arm_elf: $_mfae_path has $_mfae_machine at offset 18-19, expected 2800 — bin/redoku's is_arm_elf would reject this file"
}

# make_dead_ssh_config <path> — an ssh config under which every connection
# fails INSTANTLY, so a test can drive a real, complete host-side install
# (download, verify, unpack, symlink, wrapper) and have the run stop dead at
# connect()'s die, which is the assertion boundary: everything host-side has
# happened by then, nothing device-side has been attempted.
#
# Why not just "--host 127.0.0.1": a developer's Mac may well have a real
# sshd listening there, in which case the run does not fail — it sits at a
# password prompt until the test times out or someone notices. ProxyCommand
# /usr/bin/false makes the connection fail before any network or credential
# is involved at all; BatchMode yes guarantees no prompt even if something
# else answered; ConnectTimeout 2 bounds the pathological case. The other
# seam, --dry-run, returns early from connect() and never reaches ssh — use
# that where the point is the PLAN, and this where the point is that the
# host-side work really ran.
make_dead_ssh_config() {
  _mdsc_path=$1
  mkdir -p "$(dirname -- "$_mdsc_path")" || \
    die "make_dead_ssh_config: mkdir for $_mdsc_path failed"
  cat > "$_mdsc_path" <<'EOF'
Host *
  ProxyCommand /usr/bin/false
  BatchMode yes
  ConnectTimeout 2
EOF
}

# write_mktemp_shim <shim-dir> <parent-dir> <record-file> — a stand-in for
# the mktemp BINARY, to be put on $PATH ahead of the real one.
#
# It exists because `TMPDIR=... ; count what landed in it` is NOT a portable
# way to observe where a script put its temp directory, and the two tests that
# used to do it were therefore vacuous on this machine: measured directly,
# macOS's `mktemp -d` with no template ignores $TMPDIR entirely and uses the
# per-user Darwin temp dir, so the directory those tests inspected was never
# the one tools/install.sh used and their assertions passed whatever the code
# did. (test_kit_tarball_entry_outside_redoku records the same measurement for
# its own reasons.)
#
# The shim gives the assertion something it can actually fail: it forwards to
# the real mktemp, but with an explicit template under <parent-dir>, and
# APPENDS the path it created to <record-file>. A test can then assert on the
# exact directory install.sh used, by name — and can prove it is observing
# anything at all, because an empty record means the shim never ran.
#
# It shims the BINARY, on PATH; nothing inside tools/install.sh knows it is
# there, and no seam was added to the product to make this observable.
# `mktemp -d` with no template is install.sh's only use of it, so that is the
# single shape handled specially; everything else is passed straight through.
write_mktemp_shim() {
  _wms_dir=$1
  _wms_parent=$2
  _wms_record=$3
  mkdir -p "$_wms_dir" "$_wms_parent" || die "write_mktemp_shim: mkdir failed"
  _wms_real=$(command -v mktemp) || die "write_mktemp_shim: no 'mktemp' on this machine"
  cat > "$_wms_dir/mktemp" <<MKTEMPEOF
#!/bin/sh
if [ "\$#" -eq 1 ] && [ "\$1" = -d ]; then
  _d=\$('$_wms_real' -d '$_wms_parent/bootstrap.XXXXXX') || exit 1
  printf '%s\n' "\$_d" >> '$_wms_record'
  printf '%s\n' "\$_d"
  exit 0
fi
exec '$_wms_real' "\$@"
MKTEMPEOF
  chmod +x "$_wms_dir/mktemp"
}

# write_fake_ssh <path> <device-root> [uninstaller-exit-code] — a stand-in for
# the ssh BINARY, to be put on $PATH ahead of the real one.
#
# make_dead_ssh_config above is the seam for "the device stage must FAIL";
# this is the seam for the one case that needs it to SUCCEED — design doc §8's
# test 6, `uninstall --self`, whose entire ordering rule is that the host kit
# is deleted only AFTER the device is back to stock. With no way to satisfy
# the device stage there is no way to observe the deletion at all, and the
# alternative — a bypass inside bin/redoku — would be a test seam in
# safety-critical product code, which is exactly what must not be added.
#
# What it emulates is deliberately tiny and exact: it takes the last argument
# (which is how `remote()` passes its one command), rewrites the fixed literal
# /home/root/redoku to <device-root> so the "device" is a directory under the
# test's own tree, and runs the result with `sh -c`. That is enough for
# `true`, `mkdir -p`, push_file's `rm -f && cat >` plus its `wc -c` size
# check — the whole of cmd_uninstall's device stage.
#
# The ONE command it does not really run is the on-device uninstaller itself:
# `sh <device-root>/uninstall.sh` is matched EXACTLY (not as a substring —
# push_file's own commands also mention uninstall.sh) and answered with a
# printed line and <uninstaller-exit-code>. device/uninstall.sh is written for
# a reMarkable running systemd and must never be executed against a developer's
# own machine. Its exit code is a parameter so a test can also drive the
# "device stage failed" branch through the uninstaller rather than through
# connect().
write_fake_ssh() {
  _wfs_path=$1
  _wfs_dev=$2
  _wfs_rc=${3:-0}
  mkdir -p "$(dirname -- "$_wfs_path")" || die "write_fake_ssh: mkdir failed"
  cat > "$_wfs_path" <<FAKESSHEOF
#!/bin/sh
# Harness-written stand-in for ssh — see write_fake_ssh in tools/test/kit_test.sh.
_cmd=
for _a in "\$@"; do _cmd=\$_a; done
# Every occurrence of the fixed remote path replaced with this fake device's
# root, in pure shell rather than with sed (review N4): the replacement text is
# a path from mktemp, and a '#', '&' or '\\' anywhere in it would corrupt a sed
# substitution and surface as what looks like a product bug. \${var%%pat*} and
# \${var#*pat} do it with no escaping question at all.
_out=
while :; do
  case \$_cmd in
    *"/home/root/redoku"*) ;;
    *) break ;;
  esac
  _out=\$_out\${_cmd%%/home/root/redoku*}'$_wfs_dev'
  _cmd=\${_cmd#*/home/root/redoku}
done
_cmd=\$_out\$_cmd
case \$_cmd in
  "sh $_wfs_dev/uninstall.sh"|"sh $_wfs_dev/uninstall.sh --purge")
    printf 'fake device: ran the on-device uninstaller\n'
    exit $_wfs_rc ;;
esac
sh -c "\$_cmd"
FAKESSHEOF
  chmod +x "$_wfs_path"
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

# tools/install.sh's EXIT/INT/HUP/TERM trap removes the temp directory it
# downloads into, on success and on failure alike.
#
# Both of these tests used to set $TMPDIR and count what was left in it, and
# both were VACUOUS on this machine for the reason write_mktemp_shim's header
# records: macOS's `mktemp -d` with no template ignores $TMPDIR, so the
# directory they counted was never the one install.sh used and the assertion
# could not fail however broken the cleanup was. They now capture the real
# path — the one the shimmed mktemp actually created — and assert that exact
# directory is gone, which is an assertion that fails the moment the trap is
# removed. The record file being non-empty is checked first, because an
# assertion about a path nobody recorded would be the same vacuity again in a
# new disguise.
_assert_bootstrap_tmpdir_gone() { # <record-file> <label>
  assert_file "$1" "$2: the mktemp shim ran, so there is a real temp path to assert on" || return 1
  _abtg_dir=
  read -r _abtg_dir < "$1" || true
  [ -n "$_abtg_dir" ] || {
    printf 'FAIL: %s: the mktemp shim recorded no path\n' "$2" >&2
    return 1
  }
  assert_no_file "$_abtg_dir" "$2: install.sh removed the temp dir it created ($_abtg_dir)" || return 1
}

test_tmpdir_cleanup_on_success() {
  _w=$(mktemp -d "$ROOT/cleanup-ok.XXXXXX")
  _home=$_w/home
  mkdir -p "$_home"
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"
  _record=$_w/mktemp-record
  _clidir=$_w/cli-dir
  write_mktemp_shim "$_w/shim" "$_w/tmp" "$_record"

  set +e
  ASSERT_OUTPUT=$(PATH="$_w/shim:$PATH" REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
    REDOKU_TEST_TMPDIR_RECORD="$_clidir" \
    "$KIT_SH" "$REPO/tools/install.sh" < /dev/null 2>&1)
  _rc=$?
  set -e

  assert_eq 0 "$_rc" "cleanup on success: install.sh exit code (output: $ASSERT_OUTPUT)" || return 1
  # Two independent observations of the same directory: the shim's record says
  # what mktemp handed install.sh, and the stub CLI's own `dirname "$0"` says
  # what install.sh ran the CLI out of. If those agree, the path asserted on
  # below is unambiguously install.sh's own temp dir and not some bystander's.
  assert_file "$_clidir" "cleanup on success: the stub CLI ran" || return 1
  _shim_dir=
  read -r _shim_dir < "$_record" || true
  assert_eq "$_shim_dir" "$(cat "$_clidir")" \
    "cleanup on success: the shim's directory is the one install.sh ran the CLI from" || return 1
  _assert_bootstrap_tmpdir_gone "$_record" "cleanup on success" || return 1
}

test_tmpdir_cleanup_on_failure() {
  _w=$(mktemp -d "$ROOT/cleanup-fail.XXXXXX")
  _home=$_w/home
  mkdir -p "$_home" "$_w/empty-release"
  _record=$_w/mktemp-record
  write_mktemp_shim "$_w/shim" "$_w/tmp" "$_record"

  assert_fails "cleanup on failure: install.sh exits non-zero" -- \
    env PATH="$_w/shim:$PATH" REDOKU_BASE_URL="file://$_w/empty-release" HOME="$_home" \
    "$KIT_SH" "$REPO/tools/install.sh" < /dev/null || return 1

  # The failure is a download that 404s, i.e. install.sh's own `die` — after
  # the temp dir exists and before anything else has run in it. That is the
  # window the trap is for, and the only reason the path is knowable here at
  # all is that the shim recorded it on the way in.
  assert_contains "$ASSERT_OUTPUT" "could not download" \
    "cleanup on failure: it failed at the download, which is the window the trap covers" || return 1
  _assert_bootstrap_tmpdir_gone "$_record" "cleanup on failure" || return 1
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
  # -F (fixed string), matching mkkit.sh's own grep -qxF for this exact
  # check: without it, the '.'s in "v0.5.2" are BRE wildcards, so e.g.
  # "KIT_VERSION=v0X5X2" would satisfy this pattern too.
  if grep -qxF 'KIT_VERSION=v0.5.2' "$_cli"; then _stamped=0; else _stamped=1; fi
  assert_eq 0 "$_stamped" "stamp: redoku/bin/redoku contains the line KIT_VERSION=v0.5.2" || return 1
  if grep -qxF 'KIT_VERSION=dev' "$_cli"; then _still_dev=1; else _still_dev=0; fi
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

# Regression test for the review's IMPORTANT finding: a stale file already
# sitting in --out from an unrelated earlier run (planted here exactly as
# the reviewer constructed it: a hand-written install.sh.sha256, which
# mkkit.sh itself never emits) must fail an otherwise-clean build, not
# ship silently as a sixth asset beside the real five.
test_mkkit_stale_sixth_asset_fails() {
  _w=$(mktemp -d "$ROOT/mkkit-stale.XXXXXX")
  build_fake_kit_inputs "$_w/build"
  _out=$_w/out
  mkdir -p "$_out"
  printf 'bogus\n' > "$_out/install.sh.sha256"

  assert_fails "mkkit stale sixth asset: exits non-zero despite an otherwise-clean build" -- \
    "$KIT_SH" "$REPO/tools/mkkit.sh" --version v0.2.0 --out "$_out" --build-dir "$_w/build" || return 1

  assert_contains "$ASSERT_OUTPUT" "unexpected contents" \
    "mkkit stale sixth asset: message says --out holds unexpected contents" || return 1
  assert_contains "$ASSERT_OUTPUT" "install.sh.sha256" \
    "mkkit stale sixth asset: message names the stale file found" || return 1
}

# ---- find_game tests (bin/redoku, both KIT_VERSION branches) ------------
#
# find_game's two GAME_WHY messages became conditional on KIT_VERSION in
# this task (bin/redoku), and until now nothing tested either branch —
# confirmed with `grep -rn "cross-build it with"` over the repo, which
# returns only bin/redoku itself and the design doc. The kit-mode branch
# is the one an actual end user hits (a corrupt or partial download), and
# had zero coverage. Both get a dedicated test here.
#
# Each test compares a SINGLE grep'd line ("^ERROR: no game binary") for
# EXACT equality against the full expected message, not a substring
# check: find_game's contract requires GAME_WHY stay one line, because
# both callers print it as a single indented continuation line. die()'s
# printf would still emit an embedded newline verbatim if GAME_WHY ever
# grew one — grep would then only capture the truncated first physical
# line, and the exact-equality assertion below would fail against the
# full expected string. So this one assertion proves both the message's
# CONTENT and its single-line-ness; a substring assert_contains would
# have proven neither reliably.

# build_fake_checkout <dir> — a throwaway KIT_VERSION=dev checkout: this
# repo's own bin/redoku (unmodified), device/*, tools/mkdecoy.rb, and NO
# build/ tree at all — so find_game's "no game binary" branch fires
# without ever touching this repo's REAL build/ (which may hold a real
# cross-compiled game binary a developer built earlier; deleting or
# moving it would be destructive and is not this suite's place to do).
build_fake_checkout() {
  _bfc_dir=$1
  mkdir -p "$_bfc_dir/bin" "$_bfc_dir/device" "$_bfc_dir/tools"
  cp "$REPO/bin/redoku" "$_bfc_dir/bin/redoku"
  chmod +x "$_bfc_dir/bin/redoku"
  cp "$REPO/device/install.sh" "$_bfc_dir/device/install.sh"
  cp "$REPO/device/uninstall.sh" "$_bfc_dir/device/uninstall.sh"
  cp "$REPO/device/redoku-watcher.service" "$_bfc_dir/device/redoku-watcher.service"
  cp "$REPO/tools/mkdecoy.rb" "$_bfc_dir/tools/mkdecoy.rb"
}

test_find_game_checkout_mode_message() {
  _w=$(mktemp -d "$ROOT/findgame-checkout.XXXXXX")
  build_fake_checkout "$_w/checkout"
  _checkout_repo=$(CDPATH='' cd -- "$_w/checkout" && pwd) || \
    die "test_find_game_checkout_mode_message: cd failed"

  # 'play' calls find_game before anything else and dies with $GAME_WHY —
  # no device, no network, reached instantly.
  assert_fails "find_game checkout-mode: play dies with GAME_WHY" -- \
    "$KIT_SH" "$_w/checkout/bin/redoku" play --dry-run --host 127.0.0.1 || return 1

  _expected="ERROR: no game binary at $_checkout_repo/build/rm2/bin/redoku — cross-build it with:  make build"
  _actual=$(printf '%s\n' "$ASSERT_OUTPUT" | grep '^ERROR: no game binary')
  assert_eq "$_expected" "$_actual" \
    "find_game checkout-mode: byte-identical legacy message, proven single-line" || return 1
  # "make build" is the needle for checkout-mode: it never appears in the
  # kit-mode branch's wording.
  assert_contains "$ASSERT_OUTPUT" "make build" \
    "find_game checkout-mode: names the fix, make build" || return 1
}

test_find_game_kit_mode_message() {
  _w=$(mktemp -d "$ROOT/findgame-kit.XXXXXX")
  build_fake_kit_inputs "$_w/build"
  _out=$_w/out

  "$KIT_SH" "$REPO/tools/mkkit.sh" --version v0.9.9 --out "$_out" --build-dir "$_w/build" \
    >/dev/null || die "test_find_game_kit_mode_message: mkkit.sh failed"

  _extract=$_w/extract
  mkdir -p "$_extract"
  tar -xzf "$_out/redoku-rm2.tar.gz" -C "$_extract" || \
    die "test_find_game_kit_mode_message: tar -x failed"
  # The reviewer's exact scenario: a real, extracted fixture kit, missing
  # its game binary — a corrupt or partial download, not a missing build
  # step, which is precisely why the message must differ from checkout
  # mode's.
  rm -f "$_extract/redoku/build/rm2/bin/redoku"

  _kit_repo=$(CDPATH='' cd -- "$_extract/redoku" && pwd) || \
    die "test_find_game_kit_mode_message: cd failed"

  assert_fails "find_game kit-mode: play dies with GAME_WHY" -- \
    "$KIT_SH" "$_extract/redoku/bin/redoku" play --dry-run --host 127.0.0.1 || return 1

  _expected="ERROR: no game binary at $_kit_repo/build/rm2/bin/redoku — this kit is incomplete or corrupt, re-download it with:  redoku upgrade"
  _actual=$(printf '%s\n' "$ASSERT_OUTPUT" | grep '^ERROR: no game binary')
  assert_eq "$_expected" "$_actual" \
    "find_game kit-mode: exact message, proven single-line" || return 1
  # "redoku upgrade" is the needle for kit-mode: unlike a bare "redoku"
  # substring (present all over this output — the binary's own name),
  # this exact two-word phrase never appears in the checkout-mode branch.
  assert_contains "$ASSERT_OUTPUT" "redoku upgrade" \
    "find_game kit-mode: names the fix, redoku upgrade" || return 1
}

# ---- fetch_kit / install --download (design doc §8 tests 2,3,4,7,8,9) ----
#
# These drive the REAL bin/redoku, not a stub: `install --download`, `--kit`,
# `--bin-dir`, `--no-symlink` and fetch_kit all arrived in it in this task.
# Every one of them is offline (REDOKU_BASE_URL points at a file:// fixture),
# gets its own $HOME, kit root and bin dir under $ROOT, and never touches a
# device — either because --dry-run returns early from connect(), or because
# make_dead_ssh_config makes the ssh attempt fail instantly.
#
# Note which §6.1 tag-resolution step these exercise: a file:// URL has no
# redirects at all, so step 3 finds nothing and the tag comes from step 4 —
# VERSION inside the downloaded tarball. That is the design doc's own
# prediction (§6.1: "file:// has no redirects at all, so this is the path the
# offline tests exercise"), not an accident of the harness.

# The §3.2 files (not the directory entries) an unpacked kit must hold,
# derived from KIT_TREE_EXPECTED above rather than listed a second time —
# so a change to §3.2 has exactly one place to be made.
assert_kit_tree() { # assert_kit_tree <tree-root> <label>
  _akt_root=$1
  _akt_label=$2
  while IFS= read -r _akt_entry; do
    case $_akt_entry in
      */) continue ;;
    esac
    _akt_rel=${_akt_entry#redoku/}
    assert_file "$_akt_root/$_akt_rel" "$_akt_label: §3.2 tree has $_akt_rel" || return 1
  done <<EOF
$KIT_TREE_EXPECTED
EOF
}

# Design doc §8 test 2: the bootstrap end to end, now with a real CLI and a
# real kit — tools/install.sh fetches this checkout's own bin/redoku, hands
# over to it, and it downloads, verifies, unpacks and wires up a kit.
#
# The CLI asset is $REPO/bin/redoku verbatim, so it goes out UNSTAMPED
# (KIT_VERSION=dev). That is deliberate: with no stamp and no redirect to
# read, §6.1 falls through to step 4 and takes the tag out of the tarball,
# which is the path an offline install actually takes.
#
# TMPDIR is pointed inside the test's own tree as a courtesy, not as a load
# bearing seam: where it is honoured (GNU coreutils) it keeps $REPO — which
# for the bootstrapped CLI is the PARENT of install.sh's temp dir — inside
# this test's own tree; on macOS `mktemp -d` with no template IGNORES $TMPDIR
# and uses the per-user Darwin temp dir, as test_kit_tarball_entry_outside_redoku
# records at length. No assertion below depends on which of those happened.
test_kit_bootstrap_end_to_end() {
  _w=$(mktemp -d "$ROOT/kit-e2e.XXXXXX")
  _home=$_w/home
  _kit=$_w/kit
  _bin=$_w/bindir
  _tmp=$_w/tmp
  mkdir -p "$_home" "$_tmp"
  make_fixture_release "$_w/release" v0.1.0 "$REPO/bin/redoku"
  make_dead_ssh_config "$_w/ssh_config"

  assert_fails "bootstrap e2e: the run ends non-zero at the connect step" -- \
    env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" TMPDIR="$_tmp" \
      REDOKU_HOME="$_kit" REDOKU_BIN_DIR="$_bin" \
      "$KIT_SH" "$REPO/tools/install.sh" \
      --ssh-config "$_w/ssh_config" --host nowhere --yes < /dev/null || return 1

  # "could not connect to" appears in exactly one place in bin/redoku —
  # connect()'s die — so this proves the run got all the way through the
  # host-side work and stopped at the device, rather than dying earlier for
  # some reason the assertions below would then be checking against a
  # half-finished tree.
  assert_contains "$ASSERT_OUTPUT" "could not connect to root@nowhere" \
    "bootstrap e2e: failed at connect(), not before it" || return 1

  assert_kit_tree "$_kit/v0.1.0" "bootstrap e2e" || return 1

  # current -> v0.1.0, as a symlink and not a copy.
  [ -L "$_kit/current" ] || {
    printf 'FAIL: bootstrap e2e: %s is not a symlink\n' "$_kit/current" >&2
    return 1
  }
  assert_eq "v0.1.0" "$(readlink "$_kit/current")" \
    "bootstrap e2e: current points at the version directory, by name" || return 1
  assert_eq "v0.1.0" "$(cat "$_kit/current/VERSION")" \
    "bootstrap e2e: current/VERSION reads the tag" || return 1

  # The wrapper records the RESOLVED kit path (design doc §5.3), so the
  # expectation has to be resolved too — on macOS $TMPDIR lives under a
  # /var -> /private/var symlink, and comparing against the unresolved
  # string would fail for a reason that has nothing to do with the code.
  _kit_resolved=$(CDPATH='' cd -- "$_kit" && pwd -P) || \
    die "test_kit_bootstrap_end_to_end: could not resolve $_kit"
  assert_file "$_bin/redoku" "bootstrap e2e: the PATH entry exists" || return 1
  [ -x "$_bin/redoku" ] || {
    printf 'FAIL: bootstrap e2e: %s is not executable\n' "$_bin/redoku" >&2
    return 1
  }
  assert_contains "$(cat "$_bin/redoku")" \
    "exec \"$_kit_resolved/current/bin/redoku\" \"\$@\"" \
    "bootstrap e2e: the wrapper execs through <kit>/current, absolute and resolved" || return 1

  set +e
  _e2e_help=$(env HOME="$_home" "$_bin/redoku" --help 2>&1)
  _e2e_rc=$?
  set -e
  assert_eq 0 "$_e2e_rc" "bootstrap e2e: the wrapper runs (output: $_e2e_help)" || return 1
  assert_contains "$_e2e_help" "put the rm2fb display server" \
    "bootstrap e2e: the wrapper reached the real CLI's --help" || return 1
}

# Not in design doc §8's numbered list, and here because a hand-run found a
# real bug that every test in that list missed: `current` is repointed and
# older versions pruned by an `install --download` of a different version
# just as much as by `upgrade` (§5.3), and NONE of the tests above ever ran a
# second install over an existing kit.
#
# What that hid: the repoint was written as the design doc's §6.2 sketch says
# — `ln -s <tag> .current.new && mv -f .current.new current` — and BSD `mv`
# resolves a destination that is a symlink to a directory, so the second
# install moved .current.new INSIDE the OLD version directory, left `current`
# pointing at the old tag, and then pruned the wrong version. Every command
# in the run had succeeded and the run reported the new version.
#
# This is deliberately NOT design doc §8's test 5: that one drives the
# `upgrade` COMMAND, which is a later task and does not exist yet.
test_kit_second_download_repoints_and_prunes() {
  _w=$(mktemp -d "$ROOT/kit-repoint.XXXXXX")
  _home=$_w/home
  _kit=$_w/kit
  mkdir -p "$_home"
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"
  make_fixture_release "$_w/release" v0.2.0 "$_w/cli"
  make_fixture_release "$_w/release" v0.3.0 "$_w/cli"

  # Pinned with REDOKU_VERSION so each run installs a known tag: with a
  # file:// fixture there is no redirect to resolve "latest" through, and all
  # three versions live in the same fixture directory.
  for _v in v0.1.0 v0.2.0 v0.3.0; do
    assert_fails "repoint: install $_v ends at the connect step" -- \
      env REDOKU_BASE_URL="file://$_w/release" REDOKU_VERSION="$_v" HOME="$_home" \
        "$KIT_SH" "$REPO/bin/redoku" install --download --kit "$_kit" \
        --no-symlink --host nowhere --yes < /dev/null || return 1
    assert_eq "$_v" "$(readlink "$_kit/current")" \
      "repoint: current follows the version just installed ($_v)" || return 1
    assert_eq "$_v" "$(cat "$_kit/current/VERSION")" \
      "repoint: current/VERSION reads the version just installed ($_v)" || return 1
  done

  # One back is kept so a rollback is one symlink swap; the one before that
  # is gone.
  assert_file "$_kit/v0.3.0/VERSION" "repoint: the new version is there" || return 1
  assert_file "$_kit/v0.2.0/VERSION" "repoint: the one 'current' pointed at before is kept" || return 1
  assert_no_file "$_kit/v0.1.0" "repoint: the version before that is pruned" || return 1

  # Nothing was left inside a version directory by the repoint itself — the
  # exact shape the mv bug took.
  _stray=$(find "$_kit" -name '.current.new' 2>/dev/null | wc -l | tr -d ' ')
  assert_eq 0 "$_stray" "repoint: no stray link left inside a version directory" || return 1

  # Re-running the version that is ALREADY current must reuse it and must NOT
  # prune the one-back version: 'install' is documented safe to re-run from
  # any state, and a second run that quietly destroys the rollback target
  # would not be.
  assert_fails "repoint: re-running the current version ends at the connect step" -- \
    env REDOKU_BASE_URL="file://$_w/release" REDOKU_VERSION=v0.3.0 HOME="$_home" \
      "$KIT_SH" "$REPO/bin/redoku" install --download --kit "$_kit" \
      --no-symlink --host nowhere --yes < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "already unpacked" \
    "repoint: a version already on disk is reused, not re-fetched (§6.3)" || return 1
  assert_file "$_kit/v0.2.0/VERSION" \
    "repoint: re-running the current version leaves the rollback target alone" || return 1
  assert_eq "v0.3.0" "$(readlink "$_kit/current")" \
    "repoint: re-running the current version leaves current where it was" || return 1
}

# Design doc §8 test 3: a corrupted tarball is refused, both digests are
# named, and the kit directory is left with nothing in it.
test_kit_checksum_mismatch() {
  _w=$(mktemp -d "$ROOT/kit-badsum.XXXXXX")
  _home=$_w/home
  _kit=$_w/kit
  _bin=$_w/bindir
  mkdir -p "$_home"
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"

  # Corrupted AFTER mkkit checksummed it, so redoku-rm2.tar.gz.sha256 still
  # names the pre-corruption digest — exactly the mismatch fetch_kit exists
  # to catch.
  _expect=$(kit_digest "$MFR_PINNED/redoku-rm2.tar.gz")
  printf '\n# corrupted for test_kit_checksum_mismatch\n' >> "$MFR_PINNED/redoku-rm2.tar.gz"
  _actual=$(kit_digest "$MFR_PINNED/redoku-rm2.tar.gz")
  [ "$_expect" != "$_actual" ] || \
    die "test_kit_checksum_mismatch: corruption didn't change the digest"

  assert_fails "kit checksum mismatch: install --download exits non-zero" -- \
    env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
      "$KIT_SH" "$REPO/bin/redoku" install --download --kit "$_kit" \
      --bin-dir "$_bin" --host nowhere --yes < /dev/null || return 1

  assert_contains "$ASSERT_OUTPUT" "checksum mismatch" \
    "kit checksum mismatch: message says which check failed" || return 1
  assert_contains "$ASSERT_OUTPUT" "$_expect" \
    "kit checksum mismatch: message names the expected digest" || return 1
  assert_contains "$ASSERT_OUTPUT" "$_actual" \
    "kit checksum mismatch: message names the digest it actually got" || return 1
  assert_contains "$ASSERT_OUTPUT" "file://$_w/release" \
    "kit checksum mismatch: message names the URL" || return 1
  assert_no_file "$_kit/v0.1.0" "kit checksum mismatch: no version directory" || return 1
  assert_no_file "$_kit/current" "kit checksum mismatch: no current symlink" || return 1
  assert_eq 0 "$(count_entries "$_kit")" \
    "kit checksum mismatch: the kit directory holds nothing at all" || return 1
  assert_no_file "$_bin/redoku" "kit checksum mismatch: no PATH entry written" || return 1
}

# Design doc §8 test 4: a tarball with an entry outside redoku/ is refused
# BEFORE extraction, and nothing is written anywhere.
#
# Both bad tarballs are re-checksummed after they are built, so the checksum
# passes and the ^redoku/ guard is unambiguously what fires — a test that let
# the checksum fail instead would prove nothing about the guard.
#
# Each is self-checked the way make_fake_arm_elf self-checks its output: some
# tar implementations normalise a "..", or strip a leading "/", while
# PACKING. If this machine's tar did that, the archive would be harmless and
# the test would pass having exercised nothing — so the harness dies loudly
# rather than reporting a green it did not earn.
test_kit_tarball_entry_outside_redoku() {
  _w=$(mktemp -d "$ROOT/kit-evil.XXXXXX")
  _home=$_w/home
  mkdir -p "$_home"
  write_stub_cli "$_w/cli"

  # The escaping entry is "redoku/../../evil": extracted from a temp dir
  # <tmp>, that resolves to <tmp>/../../evil, i.e. genuinely outside the
  # directory bin/redoku extracts into — which is what makes the
  # "nothing was written outside the temp dir" assertion below meaningful.
  _stage=$_w/stage
  mkdir -p "$_stage/a/b/redoku"
  printf 'v0.1.0\n' > "$_stage/a/b/redoku/VERSION"
  # Two levels up from the packing directory, which is what makes the entry
  # name "redoku/../../evil" resolve to a real file while packing and to
  # <tmp>/../evil — outside the extraction directory — while unpacking.
  printf 'pwned\n' > "$_stage/a/evil"
  ( cd "$_stage/a/b" && tar -czPf "$_w/bad-dotdot.tgz" redoku redoku/../../evil ) || \
    die "test_kit_tarball_entry_outside_redoku: could not build the '..' tarball"
  tar -tzf "$_w/bad-dotdot.tgz" | grep -q '\.\./\.\./evil' || \
    die "test_kit_tarball_entry_outside_redoku: this machine's tar normalised the '..' away while packing, so the guard under test cannot be exercised here"

  ( cd "$_stage/a/b" && tar -czPf "$_w/bad-abs.tgz" redoku "$_stage/a/evil" ) || \
    die "test_kit_tarball_entry_outside_redoku: could not build the absolute-path tarball"
  tar -tzf "$_w/bad-abs.tgz" | grep -q '^/' || \
    die "test_kit_tarball_entry_outside_redoku: this machine's tar stripped the leading '/' while packing, so the guard under test cannot be exercised here"

  for _case in dotdot abs; do
    _rel=$_w/release-$_case
    _kit=$_w/kit-$_case
    make_fixture_release "$_rel" v0.1.0 "$_w/cli"
    cp "$_w/bad-$_case.tgz" "$MFR_PINNED/redoku-rm2.tar.gz" || \
      die "test_kit_tarball_entry_outside_redoku: cp bad-$_case.tgz failed"
    printf '%s  redoku-rm2.tar.gz\n' "$(kit_digest "$MFR_PINNED/redoku-rm2.tar.gz")" \
      > "$MFR_PINNED/redoku-rm2.tar.gz.sha256"

    assert_fails "evil tarball ($_case): install --download exits non-zero" -- \
      env REDOKU_BASE_URL="file://$_rel" HOME="$_home" \
        "$KIT_SH" "$REPO/bin/redoku" install --download --kit "$_kit" \
        --no-symlink --host nowhere --yes < /dev/null || return 1

    # "refusing to unpack" appears only in the ^redoku/ guard's die — not in
    # the checksum branch, not in tar's own errors — so it proves the archive
    # was rejected by that check and not by something else upstream.
    assert_contains "$ASSERT_OUTPUT" "refusing to unpack" \
      "evil tarball ($_case): refused by the entry guard, not by something else" || return 1

    # "refused BEFORE extraction, and extract nothing" is the actual contract,
    # and this is how it is proved: bin/redoku says "unpacking" on the line
    # immediately before its `tar -xzf`, so that word's absence means tar was
    # never asked to extract anything at all.
    #
    # Deliberately NOT proved by pointing $TMPDIR at a directory of our own
    # and asserting nothing escaped into it. Two independent reasons that
    # assertion would pass without proving a thing, both measured on this
    # machine: macOS's `mktemp -d` (no template) ignores $TMPDIR entirely and
    # uses the per-user Darwin temp dir, so the seam does not exist here; and
    # bsdtar refuses a path containing ".." on its own ("Path contains '..'"),
    # so on this platform the escape would not happen even with bin/redoku's
    # guard deleted. The guard is still right — GNU tar instead strips the
    # ".." with a warning and extracts, and neither behaviour is something a
    # security check should be delegated to — but the ASSERTION has to be one
    # this machine can actually fail.
    case $ASSERT_OUTPUT in
      *unpacking*)
        printf 'FAIL: evil tarball (%s): tar was asked to extract before the guard refused\n  output: %s\n' \
          "$_case" "$ASSERT_OUTPUT" >&2
        return 1 ;;
    esac
    assert_no_file "$_kit/v0.1.0" "evil tarball ($_case): nothing unpacked into the kit" || return 1
    assert_eq 0 "$(count_entries "$_kit")" \
      "evil tarball ($_case): the kit directory holds nothing at all" || return 1
  done

  # Case-specific: the message has to name the offending entry, and the two
  # entries are different strings.
  _rel=$_w/release-dotdot
  _kit=$_w/kit-dotdot-again
  assert_fails "evil tarball (..): rerun for the entry-naming assertion" -- \
    env REDOKU_BASE_URL="file://$_rel" HOME="$_home" \
      "$KIT_SH" "$REPO/bin/redoku" install --download --kit "$_kit" \
      --no-symlink --host nowhere --yes < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "redoku/../../evil" \
    "evil tarball (..): message names the offending entry verbatim" || return 1

  _rel=$_w/release-abs
  _kit=$_w/kit-abs-again
  assert_fails "evil tarball (absolute): rerun for the entry-naming assertion" -- \
    env REDOKU_BASE_URL="file://$_rel" HOME="$_home" \
      "$KIT_SH" "$REPO/bin/redoku" install --download --kit "$_kit" \
      --no-symlink --host nowhere --yes < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "$_stage/a/evil" \
    "evil tarball (absolute): message names the offending entry verbatim" || return 1
}

# Design doc §8 test 7, first three cases: --bin-dir puts the wrapper where
# it says, --no-symlink writes nothing anywhere and says nothing about PATH,
# and the not-on-PATH hint appears exactly when the bin dir is not on PATH.
#
# One fixture, three runs against three separate kit roots. They cannot share
# a kit root: fetch_kit's §6.3 idempotence would reuse the first run's tree
# and the later runs would exercise a different path than the first.
test_kit_bin_dir_and_path_hint() {
  _w=$(mktemp -d "$ROOT/kit-bindir.XXXXXX")
  _home=$_w/home
  mkdir -p "$_home"
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"

  # (a) --bin-dir honoured, and the bin dir is NOT on PATH, so the hint runs.
  _bin_a=$_w/bin-a
  assert_fails "bin-dir: run (a) ends at the connect step" -- \
    env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
      "$KIT_SH" "$REPO/bin/redoku" install --download --kit "$_w/kit-a" \
      --bin-dir "$_bin_a" --host nowhere --yes < /dev/null || return 1
  assert_file "$_bin_a/redoku" "bin-dir: --bin-dir put the wrapper where it said" || return 1
  # "is not on your PATH" occurs in exactly one place in bin/redoku.
  assert_contains "$ASSERT_OUTPUT" "is not on your PATH" \
    "bin-dir: (a) the not-on-PATH hint was printed" || return 1
  assert_contains "$ASSERT_OUTPUT" "export PATH=" \
    "bin-dir: (a) the hint prints the line to add" || return 1
  # …and never edits a shell rc file: there is no rc file under this HOME.
  assert_no_file "$_home/.profile" "bin-dir: (a) no shell rc file was created" || return 1
  assert_no_file "$_home/.bashrc" "bin-dir: (a) no shell rc file was created" || return 1
  assert_no_file "$_home/.zshrc" "bin-dir: (a) no shell rc file was created" || return 1

  # (b) --no-symlink: nothing written anywhere, nothing said about PATH.
  # $REDOKU_BIN_DIR is set on purpose — an environment default going unused
  # is not a contradiction, so the run must succeed AND ignore it.
  _bin_b=$_w/bin-b
  assert_fails "bin-dir: run (b) ends at the connect step" -- \
    env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" REDOKU_BIN_DIR="$_bin_b" \
      "$KIT_SH" "$REPO/bin/redoku" install --download --kit "$_w/kit-b" \
      --no-symlink --host nowhere --yes < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "could not connect to root@nowhere" \
    "bin-dir: (b) --no-symlink still installed, it just wrote no PATH entry" || return 1
  assert_no_file "$_bin_b/redoku" "bin-dir: (b) --no-symlink wrote no wrapper" || return 1
  assert_no_file "$_home/.local/bin/redoku" \
    "bin-dir: (b) --no-symlink wrote nothing at the default bin dir either" || return 1
  case $ASSERT_OUTPUT in
    *"is not on your PATH"*|*"PATH entry:"*)
      printf 'FAIL: bin-dir: (b) --no-symlink still said something about PATH\n  output: %s\n' "$ASSERT_OUTPUT" >&2
      return 1 ;;
  esac

  # (c) the same bin dir, this time ON $PATH: the hint must NOT be printed.
  _bin_c=$_w/bin-c
  assert_fails "bin-dir: run (c) ends at the connect step" -- \
    env PATH="$_bin_c:$PATH" REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
      "$KIT_SH" "$REPO/bin/redoku" install --download --kit "$_w/kit-c" \
      --bin-dir "$_bin_c" --host nowhere --yes < /dev/null || return 1
  assert_file "$_bin_c/redoku" "bin-dir: (c) the wrapper was still written" || return 1
  case $ASSERT_OUTPUT in
    *"is not on your PATH"*)
      printf 'FAIL: bin-dir: (c) the hint was printed for a bin dir that IS on PATH\n  output: %s\n' "$ASSERT_OUTPUT" >&2
      return 1 ;;
  esac
}

# Design doc §8 test 7, the foreign-`redoku` case: a file at the bin dir that
# this installer did not write is left byte-for-byte alone, the message names
# its path and both ways out, and the install carries on rather than failing.
test_kit_foreign_redoku_left_alone() {
  _w=$(mktemp -d "$ROOT/kit-foreign.XXXXXX")
  _home=$_w/home
  _bin=$_w/bindir
  mkdir -p "$_home" "$_bin"
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"

  printf '#!/bin/sh\n# somebody else put this here\necho not ours\n' > "$_bin/redoku"
  chmod +x "$_bin/redoku"
  _before=$(kit_digest "$_bin/redoku")

  assert_fails "foreign redoku: the run still ends at the connect step" -- \
    env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
      "$KIT_SH" "$REPO/bin/redoku" install --download --kit "$_w/kit" \
      --bin-dir "$_bin" --host nowhere --yes < /dev/null || return 1

  assert_eq "$_before" "$(kit_digest "$_bin/redoku")" \
    "foreign redoku: left byte-for-byte unchanged" || return 1
  # "already a 'redoku' at" occurs only in write_path_entry's foreign branch.
  assert_contains "$ASSERT_OUTPUT" "already a 'redoku' at" \
    "foreign redoku: the foreign-file branch is what ran" || return 1
  assert_contains "$ASSERT_OUTPUT" "$_bin/redoku" \
    "foreign redoku: message names its path" || return 1
  assert_contains "$ASSERT_OUTPUT" "--bin-dir DIR" \
    "foreign redoku: message suggests --bin-dir" || return 1
  assert_contains "$ASSERT_OUTPUT" "--no-symlink" \
    "foreign redoku: message suggests --no-symlink" || return 1
  # Not a failed install: it reached the device step, which is as far as any
  # of these tests can go.
  assert_contains "$ASSERT_OUTPUT" "could not connect to root@nowhere" \
    "foreign redoku: the install carried on rather than failing" || return 1
  # The kit itself still went in — only the PATH entry was skipped.
  assert_file "$_w/kit/v0.1.0/VERSION" \
    "foreign redoku: the kit was still unpacked" || return 1
}

# Design doc §5.3's stated consequences of the wrapper, which §8's numbered
# list does not cover: "a kit-mode install rewrites the wrapper every run, so
# a moved ~/.local/bin or a hand-edited file self-heals and re-running stays
# idempotent" — and its neighbour, "a `redoku` some package manager put there
# is never touched".
#
# Those two collide, and this test records how the collision was settled.
# There is no way to tell a wrapper somebody hand-edited beyond recognition
# from a file that was never ours: both are "a redoku here without our exec
# line in it". The OWNERSHIP rule wins — a file we cannot prove is ours is
# left alone, and the run says so and carries on — because the alternative is
# an installer that overwrites strangers' files, and because the next task's
# `uninstall --self` decides what it may DELETE by that same rule. What
# "self-heals" then means, and what is asserted below: an edit that leaves the
# exec line intact is rewritten, a moved bin directory gets a fresh wrapper,
# and re-running is idempotent.
#
# The kit root is reached through a SYMLINK on purpose. The wrapper records
# the kit path literally and is recognised by comparing that literal back, so
# the string has to come out identical whether the run resolved the root
# itself (a --download creates it) or inherited it from marker 2 (a plain
# `install` from inside the kit). Written against an unresolved path the two
# disagreed, and each run then saw the OTHER's wrapper as a stranger's file.
test_kit_wrapper_self_heals() {
  _w=$(mktemp -d "$ROOT/kit-wrapper.XXXXXX")
  _home=$_w/home
  _bin=$_w/bindir
  mkdir -p "$_home" "$_w/real"
  ln -s "$_w/real" "$_w/kitlink"
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"

  assert_fails "wrapper: the --download run ends at the connect step" -- \
    env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
      "$KIT_SH" "$REPO/bin/redoku" install --download --kit "$_w/kitlink" \
      --bin-dir "$_bin" --host nowhere --yes < /dev/null || return 1
  assert_file "$_bin/redoku" "wrapper: written by the download" || return 1
  _first=$(kit_digest "$_bin/redoku")
  _exec_line=$(grep '^exec ' "$_bin/redoku") || \
    die "test_kit_wrapper_self_heals: the wrapper has no exec line"

  # Edited around the exec line — a stray comment, a lost shebang — which is
  # still recognisably ours, and is what gets healed.
  printf '# somebody poked at this\n%s\n# and left this behind\n' "$_exec_line" > "$_bin/redoku"

  # No --download, and driven through the kit's OWN CLI, so the kit root comes
  # from marker 2 and has to resolve to the identical string.
  assert_fails "wrapper: the plain kit install ends at the connect step" -- \
    env REDOKU_BIN_DIR="$_bin" HOME="$_home" \
      "$KIT_SH" "$_w/real/current/bin/redoku" install --host nowhere --yes < /dev/null || return 1
  assert_eq "$_first" "$(kit_digest "$_bin/redoku")" \
    "wrapper: a plain kit install healed it byte-identically (stable resolved path)" || return 1

  # A third run over the healed wrapper changes nothing, and never mistakes
  # its own file for a stranger's.
  assert_fails "wrapper: the idempotent third run ends at the connect step" -- \
    env REDOKU_BIN_DIR="$_bin" HOME="$_home" \
      "$KIT_SH" "$_w/real/current/bin/redoku" install --host nowhere --yes < /dev/null || return 1
  case $ASSERT_OUTPUT in
    *"already a 'redoku' at"*)
      printf 'FAIL: wrapper: the installer did not recognise its own wrapper\n  output: %s\n' "$ASSERT_OUTPUT" >&2
      return 1 ;;
  esac
  assert_eq "$_first" "$(kit_digest "$_bin/redoku")" \
    "wrapper: the third run left it byte-identical" || return 1

  # A moved bin directory gets a fresh wrapper with the same contents,
  # because it points at the kit and not at where it happens to live.
  _bin2=$_w/bindir-moved
  assert_fails "wrapper: the moved-bin-dir run ends at the connect step" -- \
    env REDOKU_BIN_DIR="$_bin2" HOME="$_home" \
      "$KIT_SH" "$_w/real/current/bin/redoku" install --host nowhere --yes < /dev/null || return 1
  assert_eq "$_first" "$(kit_digest "$_bin2/redoku")" \
    "wrapper: a moved bin dir gets the same wrapper" || return 1

  # And the ownership rule's other side: edited past recognition, it is a
  # stranger's file and stays untouched.
  _bin3=$_w/bindir-unrecognisable
  mkdir -p "$_bin3"
  printf '#!/bin/sh\necho nothing of ours survives here\n' > "$_bin3/redoku"
  _stranger=$(kit_digest "$_bin3/redoku")
  assert_fails "wrapper: the unrecognisable-file run ends at the connect step" -- \
    env REDOKU_BIN_DIR="$_bin3" HOME="$_home" \
      "$KIT_SH" "$_w/real/current/bin/redoku" install --host nowhere --yes < /dev/null || return 1
  assert_eq "$_stranger" "$(kit_digest "$_bin3/redoku")" \
    "wrapper: a redoku without our exec line is left alone, not healed over" || return 1
  assert_contains "$ASSERT_OUTPUT" "already a 'redoku' at" \
    "wrapper: and the run says so rather than silently skipping it" || return 1
}

# Design doc §8 test 8: with no shasum, sha256sum or openssl reachable,
# install --download refuses — and refuses BEFORE downloading anything, which
# is what "never falls through to an unverified install" has to mean in
# practice.
test_kit_no_sha256_tool() {
  _w=$(mktemp -d "$ROOT/kit-nodigest.XXXXXX")
  _home=$_w/home
  _kit=$_w/kit
  mkdir -p "$_home"
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"

  # Same reasoning as test_no_sha256_tool's minpath: an absent file IS "not
  # found" to `command -v` on every shell, where a stub has to fake that
  # correctly across implementations.
  #
  # The list is deliberately WIDER than what the refusal itself needs
  # (dirname for $REPO, ssh for bin/redoku's up-front `command -v ssh`, curl
  # for fetch_kit's first preflight check). It also carries everything the
  # download path would reach for AFTER that point — tr and sed for the tag
  # resolution, mkdir for the kit root, mktemp for the temp dir, dd and od
  # for the ARM-ELF reuse check, rm for the cleanup — so that "the kit
  # directory was never even created" is an assertion this test can actually
  # fail. With a minimal PATH, a build that dropped the check would die on a
  # missing `tr` long before it created anything, and the assertion would
  # pass having proved nothing.
  _minpath=$_w/minpath
  build_minpath "$_minpath" curl dd dirname mkdir mktemp od rm sed sh ssh tr

  assert_fails "no sha256 tool: install --download exits non-zero" -- \
    env PATH="$_minpath" REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
      "$_minpath/sh" "$REPO/bin/redoku" install --download --kit "$_kit" \
      --no-symlink --host nowhere --yes < /dev/null || return 1

  # "no sha256 tool" appears only in that refusal; a bare "sha256" would also
  # match the asset URL ".../redoku-rm2.tar.gz.sha256" and prove nothing.
  assert_contains "$ASSERT_OUTPUT" "no sha256 tool" \
    "no sha256 tool: message says so, specifically" || return 1
  assert_contains "$ASSERT_OUTPUT" "refusing to fetch" \
    "no sha256 tool: it refused rather than installing unverified" || return 1
  assert_no_file "$_kit" \
    "no sha256 tool: the kit directory was never even created" || return 1
}

# Design doc §8 test 9, and the one that earns its keep long-term: a kit-mode
# `install --dry-run` resolves EVERY path it prints, and every one of them
# exists. This is the canary for D8 drift — it is what fails if someone moves
# a path in bin/redoku without moving it in tools/mkkit.sh, or the other way
# round.
#
# It also pins the two things that make a kit installable with no toolchain:
# the decoy is taken as it shipped (no tools/mkdecoy.rb, no ruby), and the
# "not built yet" download/'make rm2fb' prompt never appears, because the kit
# came with its binaries.
test_kit_dry_run_resolves_every_path() {
  _w=$(mktemp -d "$ROOT/kit-canary.XXXXXX")
  _home=$_w/home
  _kit=$_w/kit
  mkdir -p "$_home" "$_kit"
  build_fake_kit_inputs "$_w/build"
  "$KIT_SH" "$REPO/tools/mkkit.sh" --version v0.9.9 --out "$_w/out" \
    --build-dir "$_w/build" >/dev/null || \
    die "test_kit_dry_run_resolves_every_path: mkkit.sh failed"

  # Unpacked by hand into the §5.3 shape rather than through a download: the
  # point here is the PLAN a kit resolves, not the fetch that put it there.
  mkdir -p "$_kit/v0.9.9"
  tar -xzf "$_w/out/redoku-rm2.tar.gz" -C "$_w" || \
    die "test_kit_dry_run_resolves_every_path: tar -x failed"
  mv "$_w/redoku"/* "$_w/redoku"/.[!.]* "$_kit/v0.9.9/" 2>/dev/null || true
  [ -f "$_kit/v0.9.9/VERSION" ] || \
    die "test_kit_dry_run_resolves_every_path: the fixture kit did not land at $_kit/v0.9.9"
  ln -s v0.9.9 "$_kit/current"

  set +e
  ASSERT_OUTPUT=$(env HOME="$_home" \
    "$KIT_SH" "$_kit/current/bin/redoku" install --dry-run --yes --host nowhere \
    < /dev/null 2>&1)
  _canary_rc=$?
  set -e
  assert_eq 0 "$_canary_rc" \
    "kit dry-run: exits 0 (output: $ASSERT_OUTPUT)" || return 1

  # Each plan line is matched by its EXACT literal prefix, padding included,
  # so this pins the plan's shape as well as its contents; a sed alternation
  # would need GNU-only BRE syntax to do the same in one pass.
  for _spec in \
    'server :|==>   server : ' \
    'client :|==>   client : ' \
    'ctl    :|==>   ctl    : ' \
    'game   :|==>   game   : ' \
    'watcher:|==>   watcher: ' \
    'decoy  :|==>   decoy  : '
  do
    _label=${_spec%%|*}
    _prefix=${_spec#*|}
    _path=$(printf '%s\n' "$ASSERT_OUTPUT" | sed -n "s#^$_prefix##p")
    # The decoy line carries a trailing " (…)" note; the path is what
    # precedes it.
    _path=${_path%% (*}
    [ -n "$_path" ] || {
      printf 'FAIL: kit dry-run: plan line "%s" is missing or its path is empty\n  output: %s\n' \
        "$_label" "$ASSERT_OUTPUT" >&2
      return 1
    }
    case $_path in
      /*) ;;
      *) printf 'FAIL: kit dry-run: plan line "%s" names a non-absolute path: %s\n' "$_label" "$_path" >&2
         return 1 ;;
    esac
    [ -e "$_path" ] || {
      printf 'FAIL: kit dry-run: plan line "%s" names a path that does not exist: %s\n' "$_label" "$_path" >&2
      return 1
    }
  done

  assert_contains "$ASSERT_OUTPUT" "  device : root@nowhere" \
    "kit dry-run: the plan names the device" || return 1

  # No path anywhere in the plan came out empty or with an unexpanded
  # variable in it. "$" would catch a literal $VAR that never expanded; this
  # run prints no shell snippet of its own, so there is no legitimate '$'
  # in the output to confuse it with.
  case $ASSERT_OUTPUT in
    *'$'*) printf 'FAIL: kit dry-run: an unexpanded variable reached the plan\n  output: %s\n' "$ASSERT_OUTPUT" >&2
           return 1 ;;
  esac

  # The decoy came from the kit, not from a generator: "mkdecoy.rb" is named
  # by BOTH lines the regenerating branch prints (its say and its plan note),
  # so its absence is a branch-level proof, and "prebuilt" is unique to the
  # other branch.
  assert_contains "$ASSERT_OUTPUT" "shipped prebuilt in this kit" \
    "kit dry-run: the decoy was taken as it shipped" || return 1
  case $ASSERT_OUTPUT in
    *mkdecoy.rb*) printf 'FAIL: kit dry-run: the decoy generator was invoked inside a kit\n  output: %s\n' "$ASSERT_OUTPUT" >&2
                  return 1 ;;
  esac
  case $ASSERT_OUTPUT in
    *ruby*) printf 'FAIL: kit dry-run: ruby was asked for inside a kit\n  output: %s\n' "$ASSERT_OUTPUT" >&2
            return 1 ;;
  esac
  # …and no "not built yet" prompt: the kit came with its binaries, so
  # neither the download offer nor 'make rm2fb' has anything to offer here.
  case $ASSERT_OUTPUT in
    *"not built yet"*|*"make rm2fb"*)
      printf 'FAIL: kit dry-run: the not-built-yet prompt appeared inside a kit\n  output: %s\n' "$ASSERT_OUTPUT" >&2
      return 1 ;;
  esac
}

# ---- fix round 1 -----------------------------------------------------------

# repack_kit_without <fixture-dir> <version> <path-inside-redoku>
#
# Rebuilds the fixture's redoku-rm2.tar.gz with one path removed, and
# re-checksums it so the checksum still passes and whatever the test is
# probing is unambiguously what fires. Used to make the two shapes of
# "arrived incomplete" the milestone has messages for: a kit with no game
# binary, and a kit with no device/ scripts.
#
# Self-checked, like make_fake_arm_elf: if the path was not actually in the
# archive, the harness dies rather than reporting a green it did not earn.
repack_kit_without() {
  _rkw_dir=$1
  _rkw_version=$2
  _rkw_path=$3
  _rkw_pinned=$_rkw_dir/download/$_rkw_version
  _rkw_stage=$_rkw_dir/.repack-$_rkw_version
  rm -rf "$_rkw_stage"
  mkdir -p "$_rkw_stage" || die "repack_kit_without: mkdir $_rkw_stage failed"
  tar -xzf "$_rkw_pinned/redoku-rm2.tar.gz" -C "$_rkw_stage" || \
    die "repack_kit_without: tar -x failed"
  [ -e "$_rkw_stage/redoku/$_rkw_path" ] || \
    die "repack_kit_without: redoku/$_rkw_path is not in the fixture tarball, so removing it proves nothing"
  rm -rf "$_rkw_stage/redoku/$_rkw_path"
  ( cd "$_rkw_stage" && tar -czf "$_rkw_pinned/redoku-rm2.tar.gz" redoku ) || \
    die "repack_kit_without: tar -c failed"
  printf '%s  redoku-rm2.tar.gz\n' "$(kit_digest "$_rkw_pinned/redoku-rm2.tar.gz")" \
    > "$_rkw_pinned/redoku-rm2.tar.gz.sha256"
  rm -rf "$_rkw_stage"
}

# IMPORTANT 3: after a checkout-mode `install --download`, the game came out
# of a tarball — so a missing or wrong-arch one must be met with "re-download
# it" and never with "make build". Before the fix, find_game keyed that
# entirely off $KIT_VERSION, which is still `dev` here (this CLI is an
# unstamped checkout build), so it handed a developer build advice about a
# file no build of theirs produced.
#
# The needle is "cross-build it with", which appears ONLY in find_game's
# checkout branch — a bare "make build" would also match the final
# "play it : make build, then bin/redoku play" line that prints whenever the
# game is missing, in either branch.
test_find_game_downloaded_into_checkout_message() {
  _w=$(mktemp -d "$ROOT/findgame-dl.XXXXXX")
  _home=$_w/home
  mkdir -p "$_home"
  build_fake_checkout "$_w/checkout"
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"
  repack_kit_without "$_w/release" v0.1.0 build/rm2/bin/redoku
  make_dead_ssh_config "$_w/ssh_config"

  assert_fails "find_game downloaded-into-checkout: run ends at the connect step" -- \
    env REDOKU_BASE_URL="file://$_w/release" REDOKU_VERSION=v0.1.0 HOME="$_home" \
      "$KIT_SH" "$_w/checkout/bin/redoku" install --download \
      --ssh-config "$_w/ssh_config" --host nowhere --yes < /dev/null || return 1

  assert_contains "$ASSERT_OUTPUT" "could not connect to root@nowhere" \
    "find_game downloaded-into-checkout: the whole host-side plan ran" || return 1
  # The command has to fit the state, not merely the provenance: this tree
  # sits in a CHECKOUT's build/download/, so it has no kit root, no 'current'
  # and nothing for `redoku upgrade` to operate on — the next task makes that
  # command refuse in a checkout outright. What re-fetches this tree is the
  # command that put it here.
  assert_contains "$ASSERT_OUTPUT" "this kit is incomplete or corrupt, re-download it with:  bin/redoku install --download" \
    "find_game downloaded-into-checkout: names the command that fits a checkout" || return 1
  case $ASSERT_OUTPUT in
    *"cross-build it with"*)
      printf 'FAIL: find_game downloaded-into-checkout: gave checkout advice for a downloaded file\n  output: %s\n' "$ASSERT_OUTPUT" >&2
      return 1 ;;
  esac
  case $ASSERT_OUTPUT in
    *"redoku upgrade"*)
      printf 'FAIL: find_game downloaded-into-checkout: named a kit command in a checkout\n  output: %s\n' "$ASSERT_OUTPUT" >&2
      return 1 ;;
  esac
  # The game came from build/download/, so the path it names must too — this
  # is also what proves KIT_ROOT moved rather than find_game just guessing.
  assert_contains "$ASSERT_OUTPUT" "build/download/v0.1.0/redoku/build/rm2/bin/redoku" \
    "find_game downloaded-into-checkout: names the downloaded tree's path" || return 1
}

# IMPORTANT 2: the prompt path downloads AFTER the device-file check has
# already run against the checkout, so both of the things that check protects
# have to be redone against what actually arrived.
#
# (a) an incomplete kit must produce the "incomplete or corrupt" message that
#     controller ruling 3 asked for, not push_file's "no such file" three
#     screens later;
# (b) a developer's edited device/install.sh is REPLACED by the released one
#     (controller ruling 3 made all three device files come from $KIT_ROOT) —
#     which is correct, but §5.4's promise is that it is never done SILENTLY.
test_kit_prompt_download_rechecks_device_files() {
  _w=$(mktemp -d "$ROOT/kit-prompt-device.XXXXXX")
  _home=$_w/home
  mkdir -p "$_home"
  write_stub_cli "$_w/cli"
  make_dead_ssh_config "$_w/ssh_config"

  # (a) — a kit with no device/ at all. build_fake_checkout makes a checkout
  # with NO build/ tree, which is exactly the state the "not built yet"
  # prompt exists for; --yes answers it.
  build_fake_checkout "$_w/co-a"
  make_fixture_release "$_w/rel-a" v0.1.0 "$_w/cli"
  repack_kit_without "$_w/rel-a" v0.1.0 device

  assert_fails "prompt device re-check: incomplete kit exits non-zero" -- \
    env REDOKU_BASE_URL="file://$_w/rel-a" REDOKU_VERSION=v0.1.0 HOME="$_home" \
      "$KIT_SH" "$_w/co-a/bin/redoku" install \
      --ssh-config "$_w/ssh_config" --host nowhere --yes < /dev/null || return 1
  # Proves the prompt path was the one taken, not --download.
  assert_contains "$ASSERT_OUTPUT" "not built yet" \
    "prompt device re-check: the download prompt is what ran" || return 1
  assert_contains "$ASSERT_OUTPUT" "this kit is incomplete or corrupt" \
    "prompt device re-check: the corrupt-kit message, not push_file's" || return 1
  # The check must have been re-run against the DOWNLOADED tree; naming the
  # checkout would mean it still ran against $REPO.
  assert_contains "$ASSERT_OUTPUT" "not found in $_w/co-a/build/download/v0.1.0/redoku" \
    "prompt device re-check: it was re-run against the downloaded tree" || return 1
  # And it stopped there rather than carrying on into the device work.
  case $ASSERT_OUTPUT in
    *"could not connect to"*)
      printf 'FAIL: prompt device re-check: an incomplete kit still reached the device step\n  output: %s\n' "$ASSERT_OUTPUT" >&2
      return 1 ;;
  esac

  # (b) — a complete kit, but this checkout's device/install.sh has been
  # edited. The released one goes on the device; the run has to say so.
  build_fake_checkout "$_w/co-b"
  printf '\n# a developer edited this\n' >> "$_w/co-b/device/install.sh"
  make_fixture_release "$_w/rel-b" v0.1.0 "$_w/cli"

  assert_fails "prompt device re-check: edited script run ends at the connect step" -- \
    env REDOKU_BASE_URL="file://$_w/rel-b" REDOKU_VERSION=v0.1.0 HOME="$_home" \
      "$KIT_SH" "$_w/co-b/bin/redoku" install \
      --ssh-config "$_w/ssh_config" --host nowhere --yes < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "could not connect to root@nowhere" \
    "prompt device re-check: (b) the install carried on to the device step" || return 1
  # "device/ scripts differ" occurs only in warn_device_scripts_replaced.
  assert_contains "$ASSERT_OUTPUT" "device/ scripts differ" \
    "prompt device re-check: (b) the replacement is announced, not silent" || return 1
  assert_contains "$ASSERT_OUTPUT" "install.sh" \
    "prompt device re-check: (b) it names which script" || return 1
  # Re-review F4: round 2 corrected the remedy line here — the old wording
  # said "install without downloading: make rm2fb", which is wrong advice on
  # an `install --download --kit DIR`, where dropping the download also means
  # dropping --kit — and nothing pinned the new wording, so the correction
  # passed with itself reverted. "neither --download nor --kit" is the phrase
  # the corrected line exists to say and appears nowhere else in this file.
  assert_contains "$ASSERT_OUTPUT" "neither --download nor --kit" \
    "prompt device re-check: (b) the remedy names both flags to drop, not just the download" || return 1
  # And the RELEASED ones really are what would go on: the plan's watcher line
  # is the only device/ path printed before connect() ends the run, and it
  # names the downloaded tree rather than the checkout.
  assert_contains "$ASSERT_OUTPUT" "  watcher: $_w/co-b/build/download/v0.1.0/redoku/device/redoku-watcher.service" \
    "prompt device re-check: (b) the device files come from the downloaded kit" || return 1

  # The control: an UNEDITED checkout must say nothing at all about it.
  build_fake_checkout "$_w/co-c"
  make_fixture_release "$_w/rel-c" v0.1.0 "$_w/cli"
  assert_fails "prompt device re-check: unedited run ends at the connect step" -- \
    env REDOKU_BASE_URL="file://$_w/rel-c" REDOKU_VERSION=v0.1.0 HOME="$_home" \
      "$KIT_SH" "$_w/co-c/bin/redoku" install \
      --ssh-config "$_w/ssh_config" --host nowhere --yes < /dev/null || return 1
  case $ASSERT_OUTPUT in
    *"device/ scripts differ"*)
      printf 'FAIL: prompt device re-check: (c) warned about identical scripts\n  output: %s\n' "$ASSERT_OUTPUT" >&2
      return 1 ;;
  esac
}

# IMPORTANT 4: an option handed an EMPTY value must not fall through to
# meaning "not given at all" — the standard this file already sets for
# --seconds in its own words ("--seconds '' must not silently fall through to
# interactive play"). --kit '' would silently switch a kit install into
# checkout mode; --bin-dir '' would resolve to $PWD/ and drop the wrapper
# wherever the user happened to be standing.
#
# No fixture needed: both die during argument validation, which is the point —
# nothing downstream should ever see the empty value. $REDOKU_BASE_URL still
# points at a file:// path that does not exist, so a regression that got past
# the guard fails offline instead of reaching for github.com; without it, the
# mutation that removes these guards went straight to the real network.
test_kit_empty_option_values() {
  _w=$(mktemp -d "$ROOT/kit-emptyopt.XXXXXX")
  _home=$_w/home
  mkdir -p "$_home"
  _nowhere="file://$_w/no-such-release"

  # The control comes FIRST, so a guard that over-fires is caught by the
  # assertion that exists for it rather than incidentally by a later one. An
  # empty $REDOKU_HOME is NOT an empty --kit: ${REDOKU_HOME:-} documents it as
  # "unset", and tools/install.sh's own ${REDOKU_HOME:-$HOME/.redoku} reads it
  # the same way. It must keep working, so the guard has to be on the FLAG.
  #
  # Driven through a THROWAWAY checkout, not $REPO/bin/redoku. This is the one
  # case in this file that gets past argument validation with KIT_ROOT still
  # equal to $REPO, so it reaches build_decoy — and against the real checkout
  # that regenerates <repo>/build/decoy/ in the developer's own tree, which
  # this suite is not allowed to write to (see build_fake_checkout's header).
  # The two refusals below never get that far, so they can stay on $REPO's own
  # copy. It dies at the artifact hunt, with --artifacts pointed at a
  # directory holding no ARM builds.
  build_fake_checkout "$_w/checkout"
  assert_fails "empty REDOKU_HOME: gets past argument validation" -- \
    env HOME="$_home" REDOKU_BASE_URL="$_nowhere" REDOKU_HOME='' REDOKU_BIN_DIR='' \
      "$KIT_SH" "$_w/checkout/bin/redoku" install --dry-run --host nowhere --yes \
      --artifacts "$_w" < /dev/null || return 1
  # It really did get past validation and into cmd_install — a run stopped by
  # an argument guard never reaches the artifact hunt.
  assert_contains "$ASSERT_OUTPUT" "no ARM builds of rm2fb_server_swtcon" \
    "empty REDOKU_HOME: the run reached the artifact hunt, not an argument guard" || return 1
  case $ASSERT_OUTPUT in
    *"wants a directory, not an empty value"*)
      # shellcheck disable=SC2016  # "expressions don't expand in single
      # quotes" — nothing here wants to expand. $REDOKU_HOME and
      # $REDOKU_BIN_DIR are the NAMES of the two variables this test is
      # about, printed for a human reading a failure; expanding them would
      # print the empty strings the test deliberately set, which is exactly
      # the information the message is trying to convey by naming them.
      printf 'FAIL: an empty $REDOKU_HOME / $REDOKU_BIN_DIR was treated as an empty flag\n  output: %s\n' "$ASSERT_OUTPUT" >&2
      return 1 ;;
  esac

  assert_fails "empty --kit: exits non-zero" -- \
    env HOME="$_home" REDOKU_BASE_URL="$_nowhere" \
      "$KIT_SH" "$REPO/bin/redoku" install --download --kit '' \
      --host nowhere --yes < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "--kit wants a directory, not an empty value" \
    "empty --kit: says so rather than switching modes" || return 1

  assert_fails "empty --bin-dir: exits non-zero" -- \
    env HOME="$_home" REDOKU_BASE_URL="$_nowhere" \
      "$KIT_SH" "$REPO/bin/redoku" install --download --bin-dir '' \
      --host nowhere --yes < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "--bin-dir wants a directory, not an empty value" \
    "empty --bin-dir: says so rather than defaulting to \$PWD" || return 1
}

# IMPORTANT 1: downloads are staged BESIDE the destination, never under
# $TMPDIR, so the final `mv` is a rename and not a recursive copy. On a stock
# Linux box /tmp is often tmpfs while ~/.redoku is on the root filesystem, so
# $TMPDIR staging turned the rename into a copy on the DEFAULT path — and a
# copy interrupted by a full disk leaves a half-populated <kit>/<tag>/, which
# is what §6.2's temp-dir-then-mv shape exists to make impossible.
#
# Proving "it staged beside the destination" portably is the trick here. A
# planted leftover staging directory is the proof: clean_stale_staging only
# ever looks in the staging PARENT, so if staging had moved back under
# $TMPDIR the planted directory would still be sitting there afterwards.
# (Asserting through $TMPDIR itself would prove nothing on macOS, where
# `mktemp -d` with no template ignores it — see
# test_kit_tarball_entry_outside_redoku.)
test_kit_staging_beside_destination() {
  _w=$(mktemp -d "$ROOT/kit-staging.XXXXXX")
  _home=$_w/home
  _kit=$_w/kit
  mkdir -p "$_home" "$_kit"
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"

  # A leftover only a SIGKILL could have produced — everything short of that
  # is covered by fetch_kit's own traps. 99999 is above the default pid_max on
  # both macOS (99998) and Linux (32768), so it is reliably a DEAD pid rather
  # than one that happens to be free right now.
  mkdir -p "$_kit/.staging.99999/half-a-download"
  # …and something that is NOT a staging directory, which must survive.
  mkdir -p "$_kit/notes"
  printf 'keep me\n' > "$_kit/notes/README"
  # …and one belonging to a process that is still ALIVE, which must survive
  # too (fix round 2, MINOR E). Staging under $TMPDIR made it impossible for
  # one install to delete another's half-finished download; staging in the
  # kit root does not, so the pid is checked before anything is removed.
  sleep 45 &
  _live_pid=$!
  mkdir -p "$_kit/.staging.$_live_pid"
  printf 'half a download\n' > "$_kit/.staging.$_live_pid/being-downloaded-right-now"

  assert_fails "staging: kit-mode run ends at the connect step" -- \
    env REDOKU_BASE_URL="file://$_w/release" REDOKU_VERSION=v0.1.0 HOME="$_home" \
      "$KIT_SH" "$REPO/bin/redoku" install --download --kit "$_kit" \
      --no-symlink --host nowhere --yes < /dev/null || return 1

  assert_file "$_kit/v0.1.0/VERSION" "staging: the kit still installed" || return 1
  assert_no_file "$_kit/.staging.99999" \
    "staging: a leftover staging dir in the KIT ROOT was swept, so that is where staging lives" || return 1
  assert_file "$_kit/notes/README" \
    "staging: a directory that is not a staging dir was left alone" || return 1
  assert_file "$_kit/.staging.$_live_pid/being-downloaded-right-now" \
    "staging: a LIVE run's staging directory was not deleted out from under it" || return 1
  kill "$_live_pid" 2>/dev/null || true
  rm -rf "$_kit/.staging.$_live_pid"
  _left=$(find "$_kit" -maxdepth 1 -name '.staging.*' 2>/dev/null | wc -l | tr -d ' ')
  assert_eq 0 "$_left" "staging: nothing named .staging.* survives a successful run" || return 1

  # Checkout mode stages under build/download/, beside its own destination,
  # for exactly the same reason.
  build_fake_checkout "$_w/checkout"
  mkdir -p "$_w/checkout/build/download/.staging.99999/half-a-download"
  assert_fails "staging: checkout-mode run ends at the connect step" -- \
    env REDOKU_BASE_URL="file://$_w/release" REDOKU_VERSION=v0.1.0 HOME="$_home" \
      "$KIT_SH" "$_w/checkout/bin/redoku" install --download \
      --host nowhere --yes < /dev/null || return 1
  assert_file "$_w/checkout/build/download/v0.1.0/redoku/VERSION" \
    "staging: the checkout-mode download landed" || return 1
  assert_no_file "$_w/checkout/build/download/.staging.99999" \
    "staging: checkout mode stages under build/download/, beside its destination" || return 1
}

# IMPORTANT 1, the other half: the §6.3 reuse gate decides whether a download
# is SKIPPED, so a tree that is present but incomplete must not satisfy it.
# is_arm_elf reads bytes 0-4 and 18-19 only, so the game binary alone cannot
# answer the question — a tree missing everything past it would have been
# adopted, `current` repointed at it, and a truncated binary pushed.
test_kit_reuse_gate_rejects_a_partial_tree() {
  _w=$(mktemp -d "$ROOT/kit-reusegate.XXXXXX")
  _home=$_w/home
  _kit=$_w/kit
  mkdir -p "$_home"
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"

  # First install: complete and reusable.
  assert_fails "reuse gate: first install ends at the connect step" -- \
    env REDOKU_BASE_URL="file://$_w/release" REDOKU_VERSION=v0.1.0 HOME="$_home" \
      "$KIT_SH" "$REPO/bin/redoku" install --download --kit "$_kit" \
      --no-symlink --host nowhere --yes < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "downloading" "reuse gate: the first run fetched" || return 1

  # Second: untouched, so it is reused.
  assert_fails "reuse gate: second install ends at the connect step" -- \
    env REDOKU_BASE_URL="file://$_w/release" REDOKU_VERSION=v0.1.0 HOME="$_home" \
      "$KIT_SH" "$REPO/bin/redoku" install --download --kit "$_kit" \
      --no-symlink --host nowhere --yes < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "already unpacked" "reuse gate: an intact tree is reused" || return 1

  # Third: the shape an interrupted copy leaves — VERSION and the head of the
  # game binary present, everything past it gone. The ARM gate still passes,
  # so this is exactly the tree that used to be adopted.
  rm -rf "$_kit/v0.1.0/device" "$_kit/v0.1.0/build/rm2fb"
  assert_fails "reuse gate: partial-tree install ends at the connect step" -- \
    env REDOKU_BASE_URL="file://$_w/release" REDOKU_VERSION=v0.1.0 HOME="$_home" \
      "$KIT_SH" "$REPO/bin/redoku" install --download --kit "$_kit" \
      --no-symlink --host nowhere --yes < /dev/null || return 1
  case $ASSERT_OUTPUT in
    *"already unpacked"*)
      printf 'FAIL: reuse gate: a partial tree was adopted instead of re-fetched\n  output: %s\n' "$ASSERT_OUTPUT" >&2
      return 1 ;;
  esac
  assert_contains "$ASSERT_OUTPUT" "replacing an incomplete earlier download" \
    "reuse gate: the partial tree is replaced, not merged with" || return 1
  assert_file "$_kit/v0.1.0/device/install.sh" \
    "reuse gate: the re-fetched tree is complete again" || return 1
}

# Fix round 2, IMPORTANT A: a tag beginning ".staging." is legal by every
# other rule valid_tag applies, and it would put a version directory in the
# kit root under the exact name clean_stale_staging sweeps — so the next
# download of anything at all would rm -rf a complete, current version.
#
# Both remote sources of a tag are covered: $REDOKU_VERSION is the user's own
# typo, but the tarball's VERSION is bytes off the network, which is what puts
# this in §6.2's "attacker-controlled input" class rather than tidiness.
test_kit_staging_shaped_tag_is_refused() {
  _w=$(mktemp -d "$ROOT/kit-stagingtag.XXXXXX")
  _home=$_w/home
  mkdir -p "$_home"
  write_stub_cli "$_w/cli"

  # (a) explicit, via $REDOKU_VERSION — refused before anything is fetched.
  _kit_a=$_w/kit-a
  assert_fails "staging-shaped tag: REDOKU_VERSION is refused" -- \
    env REDOKU_BASE_URL="file://$_w/no-such-release" REDOKU_VERSION=.staging.1 \
      HOME="$_home" "$KIT_SH" "$REPO/bin/redoku" install --download \
      --kit "$_kit_a" --no-symlink --host nowhere --yes < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "REDOKU_VERSION='.staging.1'" \
    "staging-shaped tag: the message names the value it refused" || return 1
  assert_no_file "$_kit_a" "staging-shaped tag: nothing was created for it" || return 1

  # (b) the remote path: the tag comes out of the downloaded tarball's own
  # VERSION (design doc §6.1 step 4, which is what every file:// install
  # takes), so the refusal has to happen after the download and before the
  # unpacked tree is moved into place under that name.
  _kit_b=$_w/kit-b
  make_fixture_release "$_w/release" .staging.1 "$_w/cli"
  assert_fails "staging-shaped tag: a tarball VERSION is refused too" -- \
    env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
      "$KIT_SH" "$REPO/bin/redoku" install --download \
      --kit "$_kit_b" --no-symlink --host nowhere --yes < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "carries a VERSION this installer" \
    "staging-shaped tag: refused at the step-4 fallback, not somewhere else" || return 1
  assert_contains "$ASSERT_OUTPUT" "('.staging.1')" \
    "staging-shaped tag: the message names the VERSION it refused" || return 1
  # The whole point: no directory under that name was ever created, so the
  # sweep can never be handed a version directory to delete.
  assert_no_file "$_kit_b/.staging.1" \
    "staging-shaped tag: no version directory was created under the sweep's own name" || return 1
  assert_no_file "$_kit_b/current" "staging-shaped tag: current was not repointed" || return 1
}

# Fix round 2, IMPORTANT D: the `mv`-failure branch, which the previous round
# claimed had no portable way to be provoked. It does: chmod 555 on the
# destination's PARENT gives EACCES, while `mkdir -p` on a directory that
# already exists still succeeds and `[ -e "$_fk_dest" ]` is still false — so
# the run reaches the mv and the mv fails.
#
# What this pins is the message, which used to say "Nothing was installed"
# while a partial tree could be sitting there. It now removes whatever the mv
# began to create and says there is nothing to clean up by hand.
#
# The `rm -rf` itself cannot be made to matter here, and that is worth saying
# plainly rather than implying otherwise: staging is a sibling of the
# destination (fix round 1), so this mv is a rename, and a rename either
# happens or does not. The assertion below is what would catch debris if a
# future change reintroduced a cross-filesystem copy; today it is a guard on
# a case this platform cannot produce.
test_kit_mv_failure_leaves_nothing_behind() {
  _w=$(mktemp -d "$ROOT/kit-mvfail.XXXXXX")
  _home=$_w/home
  mkdir -p "$_home"
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"
  build_fake_checkout "$_w/checkout"

  # Pinned, so <tag> is known before the download and this directory can be
  # pre-created at the exact path the mv will target.
  _blocked=$_w/checkout/build/download/v0.1.0
  mkdir -p "$_blocked" || die "test_kit_mv_failure_leaves_nothing_behind: mkdir failed"
  chmod 555 "$_blocked" || die "test_kit_mv_failure_leaves_nothing_behind: chmod failed"

  set +e
  ASSERT_OUTPUT=$(env REDOKU_BASE_URL="file://$_w/release" REDOKU_VERSION=v0.1.0 \
    HOME="$_home" "$KIT_SH" "$_w/checkout/bin/redoku" install --download \
    --host nowhere --yes < /dev/null 2>&1)
  _mv_rc=$?
  set -e
  # Restored before any assertion can return early, so $ROOT's cleanup trap
  # never meets a directory it cannot remove.
  chmod 755 "$_blocked"

  [ "$_mv_rc" -ne 0 ] || {
    printf 'FAIL: mv failure: expected non-zero exit, got 0\n  output: %s\n' "$ASSERT_OUTPUT" >&2
    return 1
  }
  assert_contains "$ASSERT_OUTPUT" "could not move the unpacked kit into" \
    "mv failure: it is the mv that failed, not something earlier" || return 1
  assert_contains "$ASSERT_OUTPUT" "no half-installed version to clean up" \
    "mv failure: the message says what is true about the state it left" || return 1
  # And it does not still claim "Nothing was installed", which was the false
  # half of the old wording.
  case $ASSERT_OUTPUT in
    *"Nothing was installed."*)
      printf 'FAIL: mv failure: the message still claims nothing was installed\n  output: %s\n' "$ASSERT_OUTPUT" >&2
      return 1 ;;
  esac
  assert_no_file "$_blocked/redoku" "mv failure: no partial tree was left at the destination" || return 1
  # The staging directory went with it, so a failed run leaves no debris of
  # its own either.
  _left=$(find "$_w/checkout/build/download" -maxdepth 1 -name '.staging.*' 2>/dev/null | wc -l | tr -d ' ')
  assert_eq 0 "$_left" "mv failure: the staging directory was cleaned up" || return 1
}

# Fix round 3: design doc §6.3's idempotence on the STEP-4 tag-resolution
# path, which is the path every offline install takes and which had the least
# coverage in this suite rather than the most.
#
# The reuse gate runs once before the download, but on this path $TAG is still
# empty then — a file:// base URL has no redirects, so §6.1 steps 1-3 resolve
# nothing and the tag is only knowable from the tarball's own VERSION. So the
# gate has to be consulted a SECOND time, after step 4, before the existing
# tree is touched. Without that, a complete <kit>/<tag>/ was deleted and
# replaced by a freshly downloaded copy of itself on every re-run, and the run
# said "replacing an incomplete earlier download" about a tree that was
# neither incomplete nor in need of replacing.
#
# The DOWNLOAD staying unconditional is deliberate and is not what this tests:
# §6.2 settles that trade ("one wasted download, still correct") because step
# 4 cannot learn the tag without the bytes. What is asserted is what happens
# to the tree on disk once the tag IS known.
#
# A marker file planted inside the version directory is what separates "reused"
# from "replaced" beyond any wording: a replacement rm -rf's the tree and the
# marker goes with it.
test_kit_step4_reuses_a_complete_tree() {
  _w=$(mktemp -d "$ROOT/kit-step4.XXXXXX")
  _home=$_w/home
  _kit=$_w/kit
  mkdir -p "$_home"
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"

  # UNPINNED on purpose — no REDOKU_VERSION, so the tag can only come from
  # inside the tarball. This is the whole point of the test.
  _run() {
    assert_fails "step-4 reuse: $1" -- \
      env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
        "$KIT_SH" "$REPO/bin/redoku" install --download --kit "$_kit" \
        --no-symlink --host nowhere --yes < /dev/null
  }

  _run "first install ends at the connect step" || return 1
  assert_contains "$ASSERT_OUTPUT" "downloading" \
    "step-4 reuse: the first run fetched" || return 1
  assert_file "$_kit/v0.1.0/VERSION" "step-4 reuse: the first run unpacked" || return 1
  printf 'planted\n' > "$_kit/v0.1.0/MARKER"

  # Second run: the tag still has to be downloaded to be learned, but the tree
  # it names is already here and complete, so the tree must survive untouched.
  _run "second install ends at the connect step" || return 1
  assert_file "$_kit/v0.1.0/MARKER" \
    "step-4 reuse: the existing tree was reused, not deleted and re-unpacked" || return 1
  assert_contains "$ASSERT_OUTPUT" "reusing it" \
    "step-4 reuse: the run says it reused the tree" || return 1
  # The downloaded tree really was discarded rather than moved somewhere. An
  # unguarded `mv` onto the existing directory would not delete anything — it
  # would move the staging tree INSIDE it, leaving <tag>/redoku/ and a kit
  # whose every path resolves one level short. The marker assertion above
  # cannot see that; this one can.
  assert_no_file "$_kit/v0.1.0/redoku" \
    "step-4 reuse: the discarded download was not moved inside the reused tree" || return 1
  # The wording that used to be printed here was false — the tree was neither
  # incomplete nor replaced.
  case $ASSERT_OUTPUT in
    *"replacing an incomplete earlier download"*)
      printf 'FAIL: step-4 reuse: a complete tree was announced as an incomplete one\n  output: %s\n' "$ASSERT_OUTPUT" >&2
      return 1 ;;
  esac
  assert_eq "v0.1.0" "$(readlink "$_kit/current")" \
    "step-4 reuse: current still points at it — reusing is not leaving current alone" || return 1

  # The complement: a tree that genuinely fails the gate IS replaced, and then
  # the message is true and should stay. Removing device/ is the same shape of
  # damage test_kit_reuse_gate_rejects_a_partial_tree uses, and it leaves
  # VERSION and the ARM-passing game binary in place — so only the full gate
  # can tell the difference.
  rm -rf "$_kit/v0.1.0/device"
  _run "third install ends at the connect step" || return 1
  assert_contains "$ASSERT_OUTPUT" "replacing an incomplete earlier download" \
    "step-4 reuse: a tree that fails the gate is still replaced" || return 1
  assert_no_file "$_kit/v0.1.0/MARKER" \
    "step-4 reuse: the replacement really did replace the tree" || return 1
  assert_file "$_kit/v0.1.0/device/install.sh" \
    "step-4 reuse: and what replaced it is complete" || return 1
  case $ASSERT_OUTPUT in
    *"reusing it"*)
      printf 'FAIL: step-4 reuse: an incomplete tree was reused\n  output: %s\n' "$ASSERT_OUTPUT" >&2
      return 1 ;;
  esac
}

# MINOR 9: $KIT_VERSION was the only source of a tag not passed through
# valid_tag. It is mkkit-stamped, so the risk is low — but a tag becomes a
# directory name and a URL component, and "every source is checked" is a
# cheaper property to hold than "every source except this one".
test_kit_stamped_version_is_validated() {
  _w=$(mktemp -d "$ROOT/kit-badstamp.XXXXXX")
  _home=$_w/home
  _kit=$_w/kit
  mkdir -p "$_home"
  build_fake_kit_inputs "$_w/build"
  # mkkit stamps whatever --version says; it is not its job to police the
  # value, and this is the CLI's guard being tested, not the packager's.
  "$KIT_SH" "$REPO/tools/mkkit.sh" --version '../evil' --out "$_w/out" \
    --build-dir "$_w/build" >/dev/null || \
    die "test_kit_stamped_version_is_validated: mkkit.sh failed"
  _extract=$_w/extract
  mkdir -p "$_extract"
  tar -xzf "$_w/out/redoku-rm2.tar.gz" -C "$_extract" || \
    die "test_kit_stamped_version_is_validated: tar -x failed"

  assert_fails "bad stamp: exits non-zero" -- \
    env REDOKU_BASE_URL="file://$_w/no-such-release" HOME="$_home" \
      "$KIT_SH" "$_extract/redoku/bin/redoku" install --download --kit "$_kit" \
      --no-symlink --host nowhere --yes < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "was stamped KIT_VERSION='../evil'" \
    "bad stamp: the message names the stamp it refused" || return 1
  assert_no_file "$_kit" "bad stamp: nothing was created under the kit root" || return 1
}

# MINOR 7: the controller singled out "a dry run downloads nothing and writes
# nothing" with a ruling of its own, and nothing covered it. It is the one
# behaviour where a future edit could quietly make --dry-run start fetching
# megabytes with no test to notice.
test_kit_download_dry_run_writes_nothing() {
  _w=$(mktemp -d "$ROOT/kit-dlplan.XXXXXX")
  _home=$_w/home
  _kit=$_w/kit
  _bin=$_w/bindir
  mkdir -p "$_home"
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"

  set +e
  ASSERT_OUTPUT=$(env REDOKU_BASE_URL="file://$_w/release" REDOKU_VERSION=v0.1.0 \
    HOME="$_home" \
    "$KIT_SH" "$REPO/bin/redoku" install --download --dry-run --kit "$_kit" \
    --bin-dir "$_bin" --host nowhere --yes < /dev/null 2>&1)
  _dlplan_rc=$?
  set -e
  assert_eq 0 "$_dlplan_rc" "download dry-run: exits 0 (output: $ASSERT_OUTPUT)" || return 1

  # Nothing written, anywhere this run could have written.
  assert_no_file "$_kit" "download dry-run: the kit directory was not created" || return 1
  assert_no_file "$_bin/redoku" "download dry-run: no PATH entry" || return 1
  assert_no_file "$_home/.local/bin/redoku" "download dry-run: nothing at the default bin dir" || return 1

  # The plan is concrete: the resolved tag, the asset URL, the destination,
  # the current repoint and the wrapper path.
  assert_contains "$ASSERT_OUTPUT" "  version : v0.1.0" \
    "download dry-run: names the resolved tag" || return 1
  assert_contains "$ASSERT_OUTPUT" "file://$_w/release/download/v0.1.0/redoku-rm2.tar.gz" \
    "download dry-run: names the asset URL it would fetch" || return 1
  assert_contains "$ASSERT_OUTPUT" "  unpack  : $_kit/v0.1.0/" \
    "download dry-run: names the destination" || return 1
  assert_contains "$ASSERT_OUTPUT" "  current : $_kit/current -> v0.1.0" \
    "download dry-run: names the current repoint" || return 1
  assert_contains "$ASSERT_OUTPUT" "$_bin/redoku, a two-line wrapper" \
    "download dry-run: names the wrapper path" || return 1
  assert_contains "$ASSERT_OUTPUT" "[dry-run] stops here" \
    "download dry-run: stops with the file's own dry-run ending" || return 1

  # And it never carried on into the device plan, whose artifact paths would
  # all be inside a kit that has not arrived.
  case $ASSERT_OUTPUT in
    *"  server : "*|*"  decoy  : "*)
      printf 'FAIL: download dry-run: continued into the device plan\n  output: %s\n' "$ASSERT_OUTPUT" >&2
      return 1 ;;
  esac
}

# Re-review F1: 'current' is the kit root's OTHER reserved name (design doc
# §5.3 gives it to the symlink), and valid_tag let it through where it refused
# .staging.*. The same two entry points as test_kit_staging_shaped_tag_is_refused,
# because it is the same class of defect — a tag is remote input that becomes a
# directory name next to names this installer already owns.
#
# What makes this MAJOR rather than untidy, and what the second half asserts:
# against an existing kit the tag did not merely fail, it destroyed. The reuse
# gate followed <kit>/current into the live version directory and called it
# "already unpacked", the repoint produced current -> current (whose read-back
# guard passes, because the loop's own name is the tag), and prune_kit then
# rm -rf'd the one-back version — the rollback target §5.3 exists to keep. So
# the assertions below are not only "it was refused": they are that 'current'
# is still a SYMLINK pointing where it did, and that the one-back version is
# still on disk.
test_kit_current_shaped_tag_is_refused() {
  _w=$(mktemp -d "$ROOT/kit-currenttag.XXXXXX")
  _home=$_w/home
  mkdir -p "$_home"
  write_stub_cli "$_w/cli"

  # (a) explicit, via $REDOKU_VERSION — "current" is the word a user reaches
  # for when they mean "the current release", so this is a plain typo as much
  # as it is an attack. Refused before anything is fetched or created.
  _kit_a=$_w/kit-a
  assert_fails "current-shaped tag: REDOKU_VERSION is refused" -- \
    env REDOKU_BASE_URL="file://$_w/no-such-release" REDOKU_VERSION=current \
      HOME="$_home" "$KIT_SH" "$REPO/bin/redoku" install --download \
      --kit "$_kit_a" --no-symlink --host nowhere --yes < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "REDOKU_VERSION='current'" \
    "current-shaped tag: the message names the value it refused" || return 1
  # Re-review F2: the refusal used to explain itself with a character-set rule
  # that 'current' satisfies, i.e. it named a fix the user had already applied.
  # This phrase is what says which rule actually fired.
  assert_contains "$ASSERT_OUTPUT" "may not be 'current'" \
    "current-shaped tag: the message names the rule that fired, not one the value already meets" || return 1
  assert_no_file "$_kit_a" "current-shaped tag: nothing was created for it" || return 1

  # (b) the remote path, against a kit that already has two versions in it —
  # the state in which this tag was destructive rather than merely fatal. The
  # first two installs are pinned so the fixture's own 'latest' can be moved on
  # to the hostile release afterwards.
  _kit=$_w/kit
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"
  make_fixture_release "$_w/release" v0.2.0 "$_w/cli"
  for _v in v0.1.0 v0.2.0; do
    assert_fails "current-shaped tag: install $_v ends at the connect step" -- \
      env REDOKU_BASE_URL="file://$_w/release" REDOKU_VERSION="$_v" HOME="$_home" \
        "$KIT_SH" "$REPO/bin/redoku" install --download --kit "$_kit" \
        --no-symlink --host nowhere --yes < /dev/null || return 1
  done
  assert_eq "v0.2.0" "$(readlink "$_kit/current")" \
    "current-shaped tag: the kit is set up as expected before the hostile release" || return 1
  assert_file "$_kit/v0.1.0/VERSION" \
    "current-shaped tag: and the one-back version is there to be destroyed" || return 1

  # Published last, so it is what 'latest' resolves to and the tag can only
  # come out of the tarball's own VERSION (§6.1 step 4 — the path every
  # offline install takes).
  make_fixture_release "$_w/release" current "$_w/cli"
  assert_fails "current-shaped tag: a tarball VERSION of 'current' is refused too" -- \
    env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
      "$KIT_SH" "$REPO/bin/redoku" install --download --kit "$_kit" \
      --no-symlink --host nowhere --yes < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "carries a VERSION this installer" \
    "current-shaped tag: refused at the step-4 fallback, not somewhere else" || return 1
  assert_contains "$ASSERT_OUTPUT" "('current')" \
    "current-shaped tag: the message names the VERSION it refused" || return 1
  # It never got as far as the reuse gate's lie about a symlink.
  case $ASSERT_OUTPUT in
    *"already unpacked"*)
      printf 'FAIL: current-shaped tag: the reuse gate followed the current symlink\n  output: %s\n' "$ASSERT_OUTPUT" >&2
      return 1 ;;
  esac
  # The three states the defect produced, each asserted directly.
  [ -L "$_kit/current" ] || {
    printf 'FAIL: current-shaped tag: %s is no longer a symlink\n' "$_kit/current" >&2
    return 1
  }
  assert_eq "v0.2.0" "$(readlink "$_kit/current")" \
    "current-shaped tag: current still points where it did (not at itself)" || return 1
  assert_file "$_kit/v0.1.0/VERSION" \
    "current-shaped tag: the one-back version was not pruned" || return 1
}

# Re-review F9, the defence in depth behind F1's tag guard: -f and is_arm_elf
# all follow symlinks, so kit_tree_is_complete would report a SYMLINKED
# destination complete and the caller would then treat the link as the tree.
#
# Provoked directly rather than through a hostile tag, because the tag is now
# refused: a second kit root whose <tag> entry is a symlink into a real,
# complete kit elsewhere. The gate must say "incomplete" about it, and the
# replacement must remove the LINK and not the tree it points at.
test_kit_reuse_gate_rejects_a_symlinked_destination() {
  _w=$(mktemp -d "$ROOT/kit-linkgate.XXXXXX")
  _home=$_w/home
  _real=$_w/real-kit
  _kit=$_w/kit
  mkdir -p "$_home" "$_kit"
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"

  assert_fails "symlinked destination: the real kit installs" -- \
    env REDOKU_BASE_URL="file://$_w/release" REDOKU_VERSION=v0.1.0 HOME="$_home" \
      "$KIT_SH" "$REPO/bin/redoku" install --download --kit "$_real" \
      --no-symlink --host nowhere --yes < /dev/null || return 1
  assert_file "$_real/v0.1.0/VERSION" "symlinked destination: the real tree is complete" || return 1
  printf 'planted\n' > "$_real/v0.1.0/MARKER"

  ln -s "$_real/v0.1.0" "$_kit/v0.1.0"

  assert_fails "symlinked destination: the second install ends at the connect step" -- \
    env REDOKU_BASE_URL="file://$_w/release" REDOKU_VERSION=v0.1.0 HOME="$_home" \
      "$KIT_SH" "$REPO/bin/redoku" install --download --kit "$_kit" \
      --no-symlink --host nowhere --yes < /dev/null || return 1
  case $ASSERT_OUTPUT in
    *"already unpacked"*)
      printf 'FAIL: symlinked destination: the gate adopted a symlink as a complete tree\n  output: %s\n' "$ASSERT_OUTPUT" >&2
      return 1 ;;
  esac
  assert_contains "$ASSERT_OUTPUT" "replacing an incomplete earlier download" \
    "symlinked destination: the link is replaced, not adopted" || return 1
  [ ! -L "$_kit/v0.1.0" ] || {
    printf 'FAIL: symlinked destination: %s is still a symlink\n' "$_kit/v0.1.0" >&2
    return 1
  }
  assert_file "$_kit/v0.1.0/VERSION" "symlinked destination: a real tree took its place" || return 1
  # `rm -rf <symlink>` removes the link, never what it points at — asserted
  # rather than assumed, because getting this wrong would have deleted a
  # complete kit belonging to a different root.
  assert_file "$_real/v0.1.0/MARKER" \
    "symlinked destination: the tree the link pointed at was not touched" || return 1
}

# Re-review F4, half G: warn_device_scripts_replaced's `command -v cmp` guard.
# With no cmp, all three comparisons fail and the NOTE fires claiming the
# scripts differ when they are identical — a warning that goes off when nothing
# is wrong, which is worse than no warning. Nothing pinned the guard, and on
# every machine this suite runs on cmp exists, so removing it changed no test.
#
# Driven as a kit-mode dry-run install, which is where the comparison is
# between a file and itself ($KIT_ROOT is $REPO in a kit) — so ANY output from
# that function is false by construction, and a minimal PATH is cheap because
# no download, tarball or checksum is involved. The PATH deliberately carries
# everything this run reaches for EXCEPT cmp, so "no NOTE" cannot be satisfied
# by the run dying early somewhere else.
test_kit_no_cmp_prints_no_false_warning() {
  _w=$(mktemp -d "$ROOT/kit-nocmp.XXXXXX")
  _home=$_w/home
  _kit=$_w/kit
  mkdir -p "$_home" "$_kit"
  build_fake_kit_inputs "$_w/build"
  "$KIT_SH" "$REPO/tools/mkkit.sh" --version v0.9.9 --out "$_w/out" \
    --build-dir "$_w/build" >/dev/null || \
    die "test_kit_no_cmp_prints_no_false_warning: mkkit.sh failed"
  mkdir -p "$_kit/v0.9.9"
  tar -xzf "$_w/out/redoku-rm2.tar.gz" -C "$_w" || \
    die "test_kit_no_cmp_prints_no_false_warning: tar -x failed"
  mv "$_w/redoku"/* "$_w/redoku"/.[!.]* "$_kit/v0.9.9/" 2>/dev/null || true
  [ -f "$_kit/v0.9.9/VERSION" ] || \
    die "test_kit_no_cmp_prints_no_false_warning: the fixture kit did not land"
  ln -s v0.9.9 "$_kit/current"

  _minpath=$_w/minpath
  build_minpath "$_minpath" basename chmod dd dirname find mkdir od sh sort ssh tr
  command -v cmp >/dev/null 2>&1 || \
    die "test_kit_no_cmp_prints_no_false_warning: this machine has no cmp at all, so the guard under test cannot be exercised here"
  [ ! -e "$_minpath/cmp" ] || \
    die "test_kit_no_cmp_prints_no_false_warning: cmp reached the minimal PATH"

  set +e
  ASSERT_OUTPUT=$(env PATH="$_minpath" HOME="$_home" \
    "$_minpath/sh" "$_kit/current/bin/redoku" install --dry-run --yes --host nowhere \
    < /dev/null 2>&1)
  _nocmp_rc=$?
  set -e
  assert_eq 0 "$_nocmp_rc" "no cmp: the install plan still runs (output: $ASSERT_OUTPUT)" || return 1
  # Proof the run got past warn_device_scripts_replaced rather than dying
  # before it: the plan's watcher line is printed well after it.
  assert_contains "$ASSERT_OUTPUT" "  watcher: $_kit/current/device/redoku-watcher.service" \
    "no cmp: the run reached the plan, so the function under test really ran" || return 1
  case $ASSERT_OUTPUT in
    *"device/ scripts differ"*)
      printf 'FAIL: no cmp: warned that identical scripts differ\n  output: %s\n' "$ASSERT_OUTPUT" >&2
      return 1 ;;
  esac
}

# ---- upgrade (design doc §8 test 5) --------------------------------------
#
# Every upgrade below is driven through the KIT'S OWN CLI ($_kit/current/bin/
# redoku), never through $REPO/bin/redoku, and that is load-bearing rather than
# realism for its own sake: mkkit STAMPS the CLI inside a kit with that kit's
# version, and §6.1's step 2 says a stamped CLI resolves its own tag. Applied
# to 'upgrade' that would resolve the version already installed, find its tree
# complete, and report success having changed nothing. Run through the
# unstamped checkout CLI these tests would pass with that bug present.

# §8 test 5 proper: v1 -> v2 -> v3, one previous kept, older pruned, and the
# wrapper — which points through <kit>/current and not at a version — comes out
# byte-identical.
#
# Each version is published to the fixture in turn, so 'latest' moves and every
# upgrade is UNPINNED, which is the real command a user runs. (A file:// base
# has no redirects, so the tag comes from the tarball's VERSION each time —
# §6.1 step 4, exactly as the design doc predicts for offline tests.)
test_kit_upgrade_repoints_and_prunes() {
  _w=$(mktemp -d "$ROOT/kit-upgrade.XXXXXX")
  _home=$_w/home
  _kit=$_w/kit
  _bin=$_w/bindir
  mkdir -p "$_home"
  write_stub_cli "$_w/cli"

  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"
  assert_fails "upgrade: the initial install ends at the connect step" -- \
    env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
      "$KIT_SH" "$REPO/bin/redoku" install --download --kit "$_kit" \
      --bin-dir "$_bin" --host nowhere --yes < /dev/null || return 1
  assert_eq "v0.1.0" "$(readlink "$_kit/current")" "upgrade: v0.1.0 is installed" || return 1
  assert_file "$_bin/redoku" "upgrade: the install wrote the PATH entry" || return 1
  _wrapper=$(kit_digest "$_bin/redoku")

  # upgrade_to <version> <label> — publishes it, then upgrades through the
  # kit's own (stamped) CLI. --bin-dir is passed to prove the option now
  # reaches 'upgrade' as well as 'install'.
  _upgrade_to() {
    make_fixture_release "$_w/release" "$1" "$_w/cli"
    set +e
    ASSERT_OUTPUT=$(env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
      "$KIT_SH" "$_kit/current/bin/redoku" upgrade --bin-dir "$_bin" \
      < /dev/null 2>&1)
    _up_rc=$?
    set -e
    assert_eq 0 "$_up_rc" "upgrade: $2 exits 0 (output: $ASSERT_OUTPUT)"
  }

  _upgrade_to v0.2.0 "v0.1.0 -> v0.2.0" || return 1
  assert_contains "$ASSERT_OUTPUT" "upgraded: v0.1.0 -> v0.2.0" \
    "upgrade: it says what it did, from and to" || return 1
  assert_eq "v0.2.0" "$(readlink "$_kit/current")" "upgrade: current follows v0.2.0" || return 1

  _upgrade_to v0.3.0 "v0.2.0 -> v0.3.0" || return 1
  assert_contains "$ASSERT_OUTPUT" "upgraded: v0.2.0 -> v0.3.0" \
    "upgrade: and again, from the new current" || return 1

  assert_eq "v0.3.0" "$(readlink "$_kit/current")" "upgrade: current points at the newest" || return 1
  assert_eq "v0.3.0" "$(cat "$_kit/current/VERSION")" "upgrade: and the tree there is that version" || return 1
  assert_file "$_kit/v0.2.0/VERSION" "upgrade: one previous is kept, so a rollback is one swap" || return 1
  assert_no_file "$_kit/v0.1.0" "upgrade: the version before that is pruned" || return 1
  # The wrapper execs through <kit>/current, so two upgrades must not have
  # changed a byte of it.
  assert_eq "$_wrapper" "$(kit_digest "$_bin/redoku")" \
    "upgrade: the PATH entry is byte-identical after two upgrades" || return 1

  # Already latest, UNPINNED: §6.1 step 3 finds nothing over file://, so the
  # tag is only knowable from the tarball — one wasted download, still correct.
  # What must not happen is any change on disk.
  _dirs_before=$(find "$_kit" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  set +e
  ASSERT_OUTPUT=$(env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
    "$KIT_SH" "$_kit/current/bin/redoku" upgrade --bin-dir "$_bin" < /dev/null 2>&1)
  _up_rc=$?
  set -e
  assert_eq 0 "$_up_rc" "upgrade: already-latest is not an error (output: $ASSERT_OUTPUT)" || return 1
  assert_contains "$ASSERT_OUTPUT" "already on v0.3.0 — nothing changed" \
    "upgrade: already-latest says so" || return 1
  assert_eq "v0.3.0" "$(readlink "$_kit/current")" "upgrade: already-latest left current alone" || return 1
  assert_eq "$_dirs_before" "$(find "$_kit" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')" \
    "upgrade: already-latest created no new version directory" || return 1
  assert_file "$_kit/v0.2.0/VERSION" \
    "upgrade: already-latest did not prune the rollback target" || return 1

  # Already latest, and the tag known WITHOUT a download — §6.1 step 1 here,
  # standing in for step 3's redirect, which file:// cannot provide. This is
  # the path the brief's cost argument is about: no bytes are fetched at all.
  set +e
  ASSERT_OUTPUT=$(env REDOKU_BASE_URL="file://$_w/release" REDOKU_VERSION=v0.3.0 \
    HOME="$_home" "$KIT_SH" "$_kit/current/bin/redoku" upgrade --bin-dir "$_bin" \
    < /dev/null 2>&1)
  _up_rc=$?
  set -e
  assert_eq 0 "$_up_rc" "upgrade: already-current with a known tag exits 0 (output: $ASSERT_OUTPUT)" || return 1
  assert_contains "$ASSERT_OUTPUT" "already on v0.3.0 — nothing to download" \
    "upgrade: it took the cheap path and says so" || return 1
  # "downloading" is printed on the line immediately before fetch_kit's first
  # fetch_url, so its absence is proof no download was started.
  case $ASSERT_OUTPUT in
    *downloading*)
      printf 'FAIL: upgrade: the already-current check still downloaded\n  output: %s\n' "$ASSERT_OUTPUT" >&2
      return 1 ;;
  esac

  # REDOKU_VERSION still pins, even backwards, and the run says so rather than
  # leaving a surprising result unexplained.
  set +e
  ASSERT_OUTPUT=$(env REDOKU_BASE_URL="file://$_w/release" REDOKU_VERSION=v0.2.0 \
    HOME="$_home" "$KIT_SH" "$_kit/current/bin/redoku" upgrade --bin-dir "$_bin" \
    < /dev/null 2>&1)
  _up_rc=$?
  set -e
  assert_eq 0 "$_up_rc" "upgrade: a pinned downgrade exits 0 (output: $ASSERT_OUTPUT)" || return 1
  assert_eq "v0.2.0" "$(readlink "$_kit/current")" "upgrade: REDOKU_VERSION pinned it to v0.2.0" || return 1
  assert_contains "$ASSERT_OUTPUT" "REDOKU_VERSION=v0.2.0 asked for that version specifically" \
    "upgrade: it explains why it installed something older" || return 1
}

# design doc §7's row "current missing or dangling | upgrade repairs it by
# installing latest" — a documented recovery path, not an error case.
#
# Both sub-cases are driven through <kit>/<version>/bin/redoku rather than
# through <kit>/current/bin/redoku, because with 'current' broken the latter is
# not runnable — which is also the reason resolve_kit_root derives the kit root
# from marker 2 alone rather than through resolve_kit_mode's stricter test.
# With the strict test, the repair would walk away from the kit it is standing
# in and install a fresh one into ~/.redoku instead.
test_kit_upgrade_repairs_current() {
  _w=$(mktemp -d "$ROOT/kit-repair.XXXXXX")
  _home=$_w/home
  _kit=$_w/kit
  mkdir -p "$_home"
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"

  assert_fails "repair: the initial install ends at the connect step" -- \
    env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
      "$KIT_SH" "$REPO/bin/redoku" install --download --kit "$_kit" \
      --no-symlink --host nowhere --yes < /dev/null || return 1
  assert_file "$_kit/v0.1.0/VERSION" "repair: the kit installed" || return 1

  # (a) current deleted outright.
  rm -f "$_kit/current"
  assert_no_file "$_kit/current" "repair: (a) current really is gone before the run" || return 1
  set +e
  ASSERT_OUTPUT=$(env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
    "$KIT_SH" "$_kit/v0.1.0/bin/redoku" upgrade --no-symlink < /dev/null 2>&1)
  _rp_rc=$?
  set -e
  assert_eq 0 "$_rp_rc" "repair: (a) a missing current is repaired, not an error (output: $ASSERT_OUTPUT)" || return 1
  assert_contains "$ASSERT_OUTPUT" "was missing — repaired" \
    "repair: (a) it says what it repaired" || return 1
  assert_eq "v0.1.0" "$(readlink "$_kit/current")" "repair: (a) current points at a real version again" || return 1

  # (b) current dangling — pointing at a version directory that is not there.
  rm -f "$_kit/current"
  ln -s v9.9.9 "$_kit/current"
  set +e
  ASSERT_OUTPUT=$(env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
    "$KIT_SH" "$_kit/v0.1.0/bin/redoku" upgrade --no-symlink < /dev/null 2>&1)
  _rp_rc=$?
  set -e
  assert_eq 0 "$_rp_rc" "repair: (b) a dangling current is repaired (output: $ASSERT_OUTPUT)" || return 1
  assert_contains "$ASSERT_OUTPUT" "was dangling (it pointed at v9.9.9" \
    "repair: (b) it names what current pointed at" || return 1
  assert_eq "v0.1.0" "$(readlink "$_kit/current")" "repair: (b) current points at a real version again" || return 1
  # A repair is not "already up to date": the tag it landed on happens to be
  # the one that was there, and saying "nothing changed" would be false. The
  # needle is the whole sentence, not a bare "nothing changed" — the closing
  # "on the device: nothing changed" line contains that phrase legitimately,
  # and matching it made this assertion fire on a correct run.
  case $ASSERT_OUTPUT in
    *"already on v0.1.0 — nothing changed"*)
      printf 'FAIL: repair: (b) a repair reported itself as a no-op\n  output: %s\n' "$ASSERT_OUTPUT" >&2
      return 1 ;;
  esac

  # (c) review F4: current points at a tree that IS there but is incomplete.
  # One message used to cover this and the dangling case together, so a
  # directory still sitting on disk was reported as "which isn't there" — the
  # message-that-misdescribes-state class this file treats as a real defect.
  rm -f "$_kit/current"
  ln -s v0.1.0 "$_kit/current"
  rm -f "$_kit/v0.1.0/build/rm2/bin/redoku"
  assert_file "$_kit/v0.1.0/VERSION" "repair: (c) the target really is still on disk" || return 1
  set +e
  ASSERT_OUTPUT=$(env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
    "$KIT_SH" "$_kit/v0.1.0/bin/redoku" upgrade --no-symlink < /dev/null 2>&1)
  _rp_rc=$?
  set -e
  assert_eq 0 "$_rp_rc" "repair: (c) an incomplete target is repaired (output: $ASSERT_OUTPUT)" || return 1
  assert_contains "$ASSERT_OUTPUT" "which is still there but incomplete" \
    "repair: (c) the message describes the state it actually found" || return 1
  case $ASSERT_OUTPUT in
    *"which isn't there"*)
      printf 'FAIL: repair: (c) a present directory was reported as absent\n  output: %s\n' "$ASSERT_OUTPUT" >&2
      return 1 ;;
  esac

  # …and the --dry-run plan tells the same story, rather than printing
  # "from : v0.1.0 — what <kit>/current points at now" as though that were
  # the version you are on.
  rm -f "$_kit/current"
  ln -s v9.9.9 "$_kit/current"
  set +e
  ASSERT_OUTPUT=$(env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
    "$KIT_SH" "$_kit/v0.1.0/bin/redoku" upgrade --no-symlink --dry-run < /dev/null 2>&1)
  _rp_rc=$?
  set -e
  assert_eq 0 "$_rp_rc" "repair: (d) the dry-run plan exits 0 (output: $ASSERT_OUTPUT)" || return 1
  assert_contains "$ASSERT_OUTPUT" "  from    : nothing usable" \
    "repair: (d) the plan does not claim a broken current is a version you are on" || return 1
  assert_no_file "$_kit/v9.9.9" "repair: (d) the dry run created nothing" || return 1

  # (e) re-review N7: a `current` made by hand with an ABSOLUTE target — a
  # plausible manual rollback. The state was derived by string-joining
  # readlink's output onto the kit root, giving "<kit>//abs/path/...", so a
  # complete version directory sitting right there was reported as "which
  # isn't there" and then pruned, since the absolute string never matched a
  # basename either.
  rm -rf "$_kit/v0.1.0"
  assert_fails "repair: (e) re-seed a complete v0.1.0" -- \
    env REDOKU_BASE_URL="file://$_w/release" REDOKU_VERSION=v0.1.0 HOME="$_home" \
      "$KIT_SH" "$REPO/bin/redoku" install --download --kit "$_kit" \
      --no-symlink --host nowhere --yes < /dev/null || return 1
  _kit_resolved=$(CDPATH='' cd -- "$_kit" && pwd -P) || \
    die "test_kit_upgrade_repairs_current: could not resolve $_kit"
  rm -f "$_kit/current"
  ln -s "$_kit_resolved/v0.1.0" "$_kit/current"
  set +e
  ASSERT_OUTPUT=$(env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
    "$KIT_SH" "$_kit/v0.1.0/bin/redoku" upgrade --no-symlink < /dev/null 2>&1)
  _rp_rc=$?
  set -e
  assert_eq 0 "$_rp_rc" "repair: (e) an absolute current is understood (output: $ASSERT_OUTPUT)" || return 1
  # It is a complete tree, so this is not a repair at all — it is "already on
  # v0.1.0", which is the state the string-joined path could never see.
  assert_contains "$ASSERT_OUTPUT" "already on v0.1.0" \
    "repair: (e) an absolute current resolves to the version it names" || return 1
  case $ASSERT_OUTPUT in
    *"which isn't there"*)
      printf 'FAIL: repair: (e) an absolute current target was reported as absent\n  output: %s\n' "$ASSERT_OUTPUT" >&2
      return 1 ;;
  esac
  assert_file "$_kit/v0.1.0/VERSION" "repair: (e) and the version it named was not pruned" || return 1
}

# design doc §5.4's last row: in a checkout, upgrade refuses with the advice
# the doc gives verbatim. Nothing is fetched and nothing is written.
test_kit_upgrade_refuses_in_a_checkout() {
  _w=$(mktemp -d "$ROOT/kit-upgrade-co.XXXXXX")
  _home=$_w/home
  mkdir -p "$_home"
  build_fake_checkout "$_w/checkout"

  assert_fails "upgrade in a checkout: exits non-zero" -- \
    env REDOKU_BASE_URL="file://$_w/no-such-release" HOME="$_home" \
      "$KIT_SH" "$_w/checkout/bin/redoku" upgrade < /dev/null || return 1
  # "git pull && make build" appears in exactly one place in bin/redoku; a bare
  # "make build" would also match find_game's checkout-mode hint.
  assert_contains "$ASSERT_OUTPUT" "git pull && make build" \
    "upgrade in a checkout: the message names the right thing to do instead" || return 1
  assert_contains "$ASSERT_OUTPUT" "you're in a checkout" \
    "upgrade in a checkout: and says why" || return 1
  assert_no_file "$_w/checkout/build" "upgrade in a checkout: nothing was downloaded" || return 1
  assert_no_file "$_home/.redoku" "upgrade in a checkout: no kit was created behind its back" || return 1
}

# Review F1 (critical): `upgrade` derived its kit root as `dirname "$REPO"` on
# marker 2 alone, and marker 2 is carried by a kit tree unpacked BY HAND just
# as much as by an installed one. So `tar xzf redoku-rm2.tar.gz -C ~` followed
# by `~/redoku/bin/redoku upgrade` made $HOME a kit root and recursively
# deleted every child of it holding a VERSION file — a source tree with a
# VERSION at its root being entirely commonplace — with no flag, no
# confirmation and exit 0.
#
# The sibling here is deliberately the reviewer's own shape: an ordinary
# project directory whose VERSION says something OTHER than its own name,
# which is exactly what separates it from a directory this installer created.
test_kit_upgrade_refuses_a_hand_unpacked_kit() {
  _w=$(mktemp -d "$ROOT/kit-handunpack.XXXXXX")
  _home=$_w/home
  mkdir -p "$_home/myapp"
  printf '1.2.0\n' > "$_home/myapp/VERSION"
  printf 'my source\n' > "$_home/myapp/src.c"
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"

  # Unpacked by hand into $HOME, which is what a user who did not want the
  # curl|sh installer actually does.
  tar -xzf "$MFR_PINNED/redoku-rm2.tar.gz" -C "$_home" || \
    die "test_kit_upgrade_refuses_a_hand_unpacked_kit: tar -x failed"
  assert_file "$_home/redoku/VERSION" "hand-unpacked: the kit tree is there" || return 1

  assert_fails "hand-unpacked: upgrade refuses" -- \
    env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
      "$KIT_SH" "$_home/redoku/bin/redoku" upgrade --no-symlink < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "is not part of an installed kit" \
    "hand-unpacked: it says why it will not guess a kit root" || return 1
  assert_contains "$ASSERT_OUTPUT" "install --download --kit" \
    "hand-unpacked: and names the way to install it properly" || return 1

  # The three things the defect did, each asserted directly.
  assert_file "$_home/myapp/src.c" \
    "hand-unpacked: the sibling project was NOT deleted" || return 1
  assert_no_file "$_home/current" \
    "hand-unpacked: no 'current' symlink was created in \$HOME" || return 1
  assert_no_file "$_home/v0.1.0" \
    "hand-unpacked: no version directory was created in \$HOME" || return 1
  assert_file "$_home/redoku/VERSION" \
    "hand-unpacked: and the kit tree itself is still there" || return 1

  # …and `status` no longer routes the user into the command that did it. It
  # printed "broken, repair it with: redoku upgrade" on exactly this kit.
  set +e
  ASSERT_OUTPUT=$(env HOME="$_home" "$KIT_SH" "$_home/redoku/bin/redoku" status \
    --dry-run --host nowhere < /dev/null 2>&1)
  _hu_rc=$?
  set -e
  assert_eq 0 "$_hu_rc" "hand-unpacked: status still exits 0 (output: $ASSERT_OUTPUT)" || return 1
  assert_contains "$ASSERT_OUTPUT" "was unpacked by hand, not installed" \
    "hand-unpacked: status says what is true" || return 1
  case $ASSERT_OUTPUT in
    *"repair it with: redoku upgrade"*)
      printf 'FAIL: hand-unpacked: status still advises the command that would delete siblings\n  output: %s\n' "$ASSERT_OUTPUT" >&2
      return 1 ;;
  esac
  # The advice has to name the FULL path, matching resolve_kit_root's refusal
  # for this identical state: in a hand-unpacked tree there is no kit and so no
  # PATH wrapper, which means neither `redoku` nor `bin/redoku` names anything
  # the reader can actually run. This is the same misdescribes-state class as
  # F4, one layer down.
  assert_contains "$ASSERT_OUTPUT" "sh $_home/redoku/bin/redoku install --download --kit" \
    "hand-unpacked: status names a command the reader can actually run" || return 1
}

# The two commands that read device/ from disk both have to answer "it isn't
# there" twice — once for a checkout, once for a kit — because "go and find a
# checkout" is wrong advice for somebody running a kit, who may well not have
# one and whose real problem is a download that arrived incomplete.
# require_device_files has had both answers all along; cmd_uninstall's opening
# check had only the checkout one, unguarded.
test_kit_uninstall_names_the_right_fix_for_a_kit() {
  _w=$(mktemp -d "$ROOT/kit-unmsg.XXXXXX")
  _home=$_w/home
  mkdir -p "$_home"
  build_fake_kit_inputs "$_w/build"
  "$KIT_SH" "$REPO/tools/mkkit.sh" --version v0.9.9 --out "$_w/out" \
    --build-dir "$_w/build" >/dev/null || \
    die "test_kit_uninstall_names_the_right_fix_for_a_kit: mkkit.sh failed"
  _extract=$_w/extract
  mkdir -p "$_extract"
  tar -xzf "$_w/out/redoku-rm2.tar.gz" -C "$_extract" || \
    die "test_kit_uninstall_names_the_right_fix_for_a_kit: tar -x failed"
  # The state a truncated or partial download leaves.
  rm -f "$_extract/redoku/device/uninstall.sh"

  assert_fails "uninstall message: a kit missing the uninstaller exits non-zero" -- \
    env HOME="$_home" "$KIT_SH" "$_extract/redoku/bin/redoku" uninstall \
      --host nowhere --yes < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "this kit is incomplete or corrupt" \
    "uninstall message: a kit is told its download is incomplete" || return 1
  assert_contains "$ASSERT_OUTPUT" "not found in $_extract/redoku" \
    "uninstall message: and where it looked" || return 1
  # The checkout answer must NOT be what a kit user gets.
  case $ASSERT_OUTPUT in
    *"from a reDoku checkout"*)
      printf 'FAIL: uninstall message: a kit user was told to go and find a checkout\n  output: %s\n' "$ASSERT_OUTPUT" >&2
      return 1 ;;
  esac

  # The control: a checkout still gets the checkout answer, unchanged.
  build_fake_checkout "$_w/checkout"
  rm -f "$_w/checkout/device/uninstall.sh"
  assert_fails "uninstall message: a checkout missing the uninstaller exits non-zero" -- \
    env HOME="$_home" "$KIT_SH" "$_w/checkout/bin/redoku" uninstall \
      --host nowhere --yes < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "from a reDoku checkout" \
    "uninstall message: a checkout still gets the checkout answer" || return 1
  case $ASSERT_OUTPUT in
    *"this kit is incomplete"*)
      printf 'FAIL: uninstall message: a checkout was told its kit was corrupt\n  output: %s\n' "$ASSERT_OUTPUT" >&2
      return 1 ;;
  esac
}

# Re-review N2 (major): `cmd_upgrade`'s call to the shared guards was the
# second half of F1's prescribed remedy — "the two commands that write in a kit
# root are held to one standard" — and deleting that one line left the whole
# suite green. It is not semantically inert: without it `upgrade --kit $HOME`
# creates $HOME/current and $HOME/v0.1.0/, in the directory `uninstall --self`
# refuses by name. Only is_version_dir then keeps ~/myapp from going with them,
# so the guard the review asked for was the only thing preventing the WRITE,
# and nothing pinned it.
#
# Both ways of naming a root are covered, because they arrive differently: only
# --kit passes through the option-validation lines, $REDOKU_HOME does not.
test_kit_upgrade_guards_its_kit_root() {
  _w=$(mktemp -d "$ROOT/kit-upguard.XXXXXX")
  _home=$_w/home
  _kit=$_w/kit
  mkdir -p "$_home/myapp"
  printf '1.2.0\n' > "$_home/myapp/VERSION"
  printf 'my source\n' > "$_home/myapp/src.c"
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"
  # A real installed kit elsewhere, so the CLI driving these runs is a genuine
  # kit CLI: the refusal can then only come from the guard on the NAMED root,
  # not from resolve_kit_root declining to derive one.
  assert_fails "upgrade guard: the setup install ends at the connect step" -- \
    env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
      "$KIT_SH" "$REPO/bin/redoku" install --download --kit "$_kit" \
      --no-symlink --host nowhere --yes < /dev/null || return 1

  for _how in flag env; do
    if [ "$_how" = flag ]; then
      assert_fails "upgrade guard: --kit \$HOME is refused" -- \
        env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
          "$KIT_SH" "$_kit/current/bin/redoku" upgrade --kit "$_home" \
          --no-symlink < /dev/null || return 1
    else
      assert_fails "upgrade guard: REDOKU_HOME=\$HOME is refused" -- \
        env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" REDOKU_HOME="$_home" \
          "$KIT_SH" "$_kit/current/bin/redoku" upgrade --no-symlink < /dev/null || return 1
    fi
    # Guard 3's own wording, printed by nothing but check_kit_root — so this
    # proves the CALL is there, not merely that the run failed somehow.
    assert_contains "$ASSERT_OUTPUT" "your home directory" \
      "upgrade guard: ($_how) refused by the shared guards" || return 1
    # …and in upgrade's voice rather than uninstall's (re-review N4).
    assert_contains "$ASSERT_OUTPUT" "refusing to install into" \
      "upgrade guard: ($_how) the message describes the command that was run" || return 1
    case $ASSERT_OUTPUT in
      *"refusing to remove"*)
        printf 'FAIL: upgrade guard: (%s) upgrade claimed to be refusing to REMOVE something\n  output: %s\n' "$_how" "$ASSERT_OUTPUT" >&2
        return 1 ;;
    esac
    # The write the missing guard allowed, asserted directly.
    assert_no_file "$_home/current" \
      "upgrade guard: ($_how) no 'current' symlink was created in \$HOME" || return 1
    assert_no_file "$_home/v0.1.0" \
      "upgrade guard: ($_how) no version directory was created in \$HOME" || return 1
    assert_file "$_home/myapp/src.c" \
      "upgrade guard: ($_how) the sibling project is untouched" || return 1
  done

  # A directory of the user's, named with --kit: guard 5 this time rather than
  # guard 3, so both arms of the refusal are proven reachable from `upgrade`.
  _docs=$_w/Documents
  mkdir -p "$_docs/coolproject-1.2"
  printf '1.2.0\n' > "$_docs/coolproject-1.2/VERSION"
  printf 'int main(void){}\n' > "$_docs/coolproject-1.2/main.c"
  assert_fails "upgrade guard: a projects directory is refused" -- \
    env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
      "$KIT_SH" "$_kit/current/bin/redoku" upgrade --kit "$_docs" \
      --no-symlink < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "does not look like a reDoku kit" \
    "upgrade guard: guard 5 is reachable from upgrade too" || return 1
  assert_contains "$ASSERT_OUTPUT" "nothing was installed into it" \
    "upgrade guard: and it says what THIS command would have done" || return 1
  assert_no_file "$_docs/current" "upgrade guard: nothing was created there" || return 1
  assert_file "$_docs/coolproject-1.2/main.c" "upgrade guard: and nothing was removed" || return 1
}

# Re-review N3 (major): guard 5's `current` arm accepted the NAME alone, and
# `current` is the canonical Capistrano deploy symlink
# (<root>/current -> releases/<timestamp>). So a user's deploy root passed all
# five guards: `uninstall --self` deleted their symlink, and `upgrade` wrote a
# version directory into their project folder while describing THEIR directory
# as an incomplete reDoku version.
#
# Both verbs are driven, because the arm is shared and each did something
# different with it.
test_kit_guard_rejects_a_deploy_root() {
  _w=$(mktemp -d "$ROOT/kit-deployroot.XXXXXX")
  _home=$_w/home
  mkdir -p "$_home"
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"

  # The canonical shape, including the release directory the symlink points at.
  _proj=$_w/projects
  mkdir -p "$_proj/releases/20240101120000" "$_proj/shared"
  printf 'app\n' > "$_proj/releases/20240101120000/app.rb"
  printf 'note\n' > "$_proj/shared/config.yml"
  ln -s releases/20240101120000 "$_proj/current"

  assert_fails "deploy root: uninstall --self is refused" -- \
    env HOME="$_home" "$KIT_SH" "$REPO/bin/redoku" uninstall --self \
      --kit "$_proj" --host nowhere --yes < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "does not look like a reDoku kit" \
    "deploy root: refused rather than treated as a kit" || return 1
  assert_contains "$ASSERT_OUTPUT" "pointing at one of its own version" \
    "deploy root: the message says the symlink has to point at one of ours" || return 1

  assert_fails "deploy root: upgrade is refused" -- \
    env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
      "$KIT_SH" "$REPO/bin/redoku" upgrade --kit "$_proj" --no-symlink \
      < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "does not look like a reDoku kit" \
    "deploy root: upgrade refuses it too" || return 1
  # It never got as far as calling the user's own directory an incomplete
  # reDoku version.
  case $ASSERT_OUTPUT in
    *"still there but incomplete"*)
      printf 'FAIL: deploy root: upgrade described the user directory as an incomplete kit\n  output: %s\n' "$ASSERT_OUTPUT" >&2
      return 1 ;;
  esac

  # Everything survives, symlink included.
  [ -L "$_proj/current" ] || {
    printf 'FAIL: deploy root: the user symlink at %s/current was removed\n' "$_proj" >&2
    return 1
  }
  assert_eq "releases/20240101120000" "$(readlink "$_proj/current")" \
    "deploy root: and it still points where it did" || return 1
  assert_file "$_proj/releases/20240101120000/app.rb" "deploy root: the release is intact" || return 1
  assert_file "$_proj/shared/config.yml" "deploy root: and everything beside it" || return 1
  assert_no_file "$_proj/v0.1.0" "deploy root: no version directory was written into it" || return 1

  # The complement, so this is not just "guard 5 refuses everything": OUR
  # dangling `current` — the §6.2 repoint window and §7's repair case — still
  # reads as a kit, because what it names is a bare tag rather than a path.
  _kit=$_w/kit
  assert_fails "deploy root: the control install ends at the connect step" -- \
    env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
      "$KIT_SH" "$REPO/bin/redoku" install --download --kit "$_kit" \
      --no-symlink --host nowhere --yes < /dev/null || return 1
  rm -rf "$_kit/v0.1.0"
  set +e
  ASSERT_OUTPUT=$(env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
    "$KIT_SH" "$REPO/bin/redoku" upgrade --kit "$_kit" --no-symlink < /dev/null 2>&1)
  _dr_rc=$?
  set -e
  assert_eq 0 "$_dr_rc" \
    "deploy root: our own dangling current is still repaired (output: $ASSERT_OUTPUT)" || return 1
  assert_eq "v0.1.0" "$(readlink "$_kit/current")" "deploy root: and the repair landed" || return 1
}

# Re-review N5/N6: the empty/absent-root widening, which the re-review called
# load-bearing but under-reasoned and unpinned — removing it entirely left the
# whole suite green.
#
# It is now scoped to the verb, and this is what pins both halves of that
# scoping. `upgrade` may create a kit in a directory that holds nothing of the
# user's; `uninstall --self` may not act there at all, because there is no kit
# to remove and the closing rmdir would delete a directory this installer never
# created.
test_kit_guard_empty_root_scope() {
  _w=$(mktemp -d "$ROOT/kit-emptyroot.XXXXXX")
  _home=$_w/home
  mkdir -p "$_home"
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"

  # (a) upgrade into a root that does not exist yet.
  set +e
  ASSERT_OUTPUT=$(env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
    "$KIT_SH" "$REPO/bin/redoku" upgrade --kit "$_w/fresh" --no-symlink \
    < /dev/null 2>&1)
  _er_rc=$?
  set -e
  assert_eq 0 "$_er_rc" "empty root: upgrade creates a fresh kit root (output: $ASSERT_OUTPUT)" || return 1
  assert_eq "v0.1.0" "$(readlink "$_w/fresh/current")" "empty root: and the kit landed" || return 1

  # (b) upgrade into a root holding nothing but a SIGKILLed download's
  # leftovers — the state the widening's own comment cites, and which it did
  # not actually cover before: one .staging.* child made the root non-empty.
  mkdir -p "$_w/halfdone/.staging.999999/half-a-download"
  set +e
  ASSERT_OUTPUT=$(env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
    "$KIT_SH" "$REPO/bin/redoku" upgrade --kit "$_w/halfdone" --no-symlink \
    < /dev/null 2>&1)
  _er_rc=$?
  set -e
  assert_eq 0 "$_er_rc" "empty root: a staging leftover does not block the repair (output: $ASSERT_OUTPUT)" || return 1
  assert_eq "v0.1.0" "$(readlink "$_w/halfdone/current")" "empty root: the repair landed" || return 1

  # (c) but a directory of the user's is still refused, so (a) and (b) are a
  # scoped exception rather than a hole.
  mkdir -p "$_w/mixed/notes"
  printf 'mine\n' > "$_w/mixed/notes/a.txt"
  assert_fails "empty root: a root with the user's own files is still refused" -- \
    env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
      "$KIT_SH" "$REPO/bin/redoku" upgrade --kit "$_w/mixed" --no-symlink \
      < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "does not look like a reDoku kit" \
    "empty root: (c) refused" || return 1
  assert_file "$_w/mixed/notes/a.txt" "empty root: (c) untouched" || return 1

  # (d) the other half of the scoping: uninstall --self must NOT accept an
  # empty root, because the closing rmdir would then delete a directory this
  # installer never created.
  mkdir -p "$_w/scratch"
  assert_fails "empty root: uninstall --self refuses an empty directory" -- \
    env HOME="$_home" "$KIT_SH" "$REPO/bin/redoku" uninstall --self \
      --kit "$_w/scratch" --host nowhere --yes < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "nothing was removed" \
    "empty root: (d) refused with the remove voice" || return 1
  [ -d "$_w/scratch" ] || {
    printf 'FAIL: empty root: (d) uninstall --self removed an empty directory it never created\n' >&2
    return 1
  }
}

# Re-review N1 (major): the F3 fix keyed on where the CLI LIVES, not on the kit
# being repaired, so every repair driven from outside the kit still pruned to
# zero. Reachable with no flag at all — $REDOKU_HOME exported plus a checkout
# CLI against ~/.redoku.
#
# The driving CLI here is deliberately the checkout's, which lives nowhere near
# the kit, so the running-tree rule cannot fire and only the validated keep-too
# can produce a rollback target.
test_kit_upgrade_repair_from_outside_keeps_one_previous() {
  _w=$(mktemp -d "$ROOT/kit-outsiderepair.XXXXXX")
  _home=$_w/home
  mkdir -p "$_home"
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"
  make_fixture_release "$_w/release" v0.2.0 "$_w/cli"
  make_fixture_release "$_w/release" v0.3.0 "$_w/cli"

  # Both shapes §7 names, each in a kit of its own rather than one kit reused:
  # re-seeding between passes would run another install, and that install
  # repoints and prunes, so the second pass would start from a state the test
  # did not intend.
  for _damage in dangling missing; do
    _kit=$_w/kit-$_damage
    for _v in v0.1.0 v0.2.0; do
      assert_fails "outside repair: ($_damage) install $_v ends at the connect step" -- \
        env REDOKU_BASE_URL="file://$_w/release" REDOKU_VERSION="$_v" HOME="$_home" \
          "$KIT_SH" "$REPO/bin/redoku" install --download --kit "$_kit" \
          --no-symlink --host nowhere --yes < /dev/null || return 1
    done
    assert_file "$_kit/v0.1.0/VERSION" "outside repair: ($_damage) v0.1.0 is present" || return 1
    assert_file "$_kit/v0.2.0/VERSION" "outside repair: ($_damage) v0.2.0 is present" || return 1

    rm -f "$_kit/current"
    # dangling names a version that is not there; missing names nothing at all.
    # Both produced a keep-too that excluded no directory from the sweep.
    [ "$_damage" = missing ] || ln -s v9.9.9 "$_kit/current"

    # $REDOKU_HOME and the CHECKOUT's CLI: no flag, and the CLI lives nowhere
    # near the kit, so the running-tree rule cannot fire and only the validated
    # keep-too can produce a rollback target. This is the re-review's repro A.
    set +e
    ASSERT_OUTPUT=$(env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
      REDOKU_HOME="$_kit" "$KIT_SH" "$REPO/bin/redoku" upgrade --no-symlink \
      < /dev/null 2>&1)
    _or_rc=$?
    set -e
    assert_eq 0 "$_or_rc" "outside repair: ($_damage) exits 0 (output: $ASSERT_OUTPUT)" || return 1
    assert_eq "v0.3.0" "$(readlink "$_kit/current")" \
      "outside repair: ($_damage) current points at the new version" || return 1

    # The whole point: the kit is not left with zero rollback targets.
    _left=$(find "$_kit" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    assert_eq 2 "$_left" \
      "outside repair: ($_damage) exactly one previous version survives beside the new one" || return 1
    assert_file "$_kit/v0.1.0/VERSION" \
      "outside repair: ($_damage) and it is the first surviving version, kept deliberately" || return 1
    assert_contains "$ASSERT_OUTPUT" "as the rollback target" \
      "outside repair: ($_damage) the run says it chose one" || return 1
    # And it did NOT keep it by the running-tree rule, which cannot apply here.
    case $ASSERT_OUTPUT in
      *"it is the version this command is running from"*)
        printf 'FAIL: outside repair: (%s) the running-tree rule fired for a CLI outside the kit\n  output: %s\n' "$_damage" "$ASSERT_OUTPUT" >&2
        return 1 ;;
    esac
  done
}

# Review F3: repairing a broken `current` pruned to ZERO previous versions.
# prune_kit was handed the tag being installed plus whatever `current` named,
# and a dangling `current` names something that is not there — so both real
# versions were swept, one of them the directory the CLI was executing from.
# §5.2 and §5.3 both say "prune to one previous".
test_kit_upgrade_repair_keeps_one_previous() {
  _w=$(mktemp -d "$ROOT/kit-repairprune.XXXXXX")
  _home=$_w/home
  _kit=$_w/kit
  mkdir -p "$_home"
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"
  make_fixture_release "$_w/release" v0.2.0 "$_w/cli"

  for _v in v0.1.0 v0.2.0; do
    assert_fails "repair prune: install $_v ends at the connect step" -- \
      env REDOKU_BASE_URL="file://$_w/release" REDOKU_VERSION="$_v" HOME="$_home" \
        "$KIT_SH" "$REPO/bin/redoku" install --download --kit "$_kit" \
        --no-symlink --host nowhere --yes < /dev/null || return 1
  done
  assert_file "$_kit/v0.1.0/VERSION" "repair prune: two versions are on disk" || return 1
  assert_file "$_kit/v0.2.0/VERSION" "repair prune: two versions are on disk" || return 1

  # The damage: a half-finished manual rollback, or the rm/ln window §6.2
  # documents, or a version directory someone removed by hand.
  rm -f "$_kit/current"
  ln -s v9.9.9 "$_kit/current"

  make_fixture_release "$_w/release" v0.3.0 "$_w/cli"
  set +e
  ASSERT_OUTPUT=$(env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
    "$KIT_SH" "$_kit/v0.2.0/bin/redoku" upgrade --no-symlink < /dev/null 2>&1)
  _rp_rc=$?
  set -e
  assert_eq 0 "$_rp_rc" "repair prune: the repair exits 0 (output: $ASSERT_OUTPUT)" || return 1
  assert_eq "v0.3.0" "$(readlink "$_kit/current")" "repair prune: current points at the new version" || return 1

  # Exactly one previous survives, and it is the one the CLI ran from — the
  # directory that used to be deleted out from under the running process.
  assert_file "$_kit/v0.2.0/VERSION" \
    "repair prune: the version this run executed from survived" || return 1
  assert_no_file "$_kit/v0.1.0" \
    "repair prune: the older one was pruned, so this is 'one previous' and not 'all of them'" || return 1
  assert_contains "$ASSERT_OUTPUT" "it is the version this command is running from" \
    "repair prune: and it says why it kept that one" || return 1
  assert_contains "$ASSERT_OUTPUT" "as the rollback target" \
    "repair prune: the keep-too was replaced rather than trusted" || return 1
}

# ---- uninstall --self (design doc §8 test 6) -----------------------------
#
# The device stage is what makes this hard to test offline, and the two seams
# are opposite ones: make_dead_ssh_config for "the device stage must FAIL"
# (the ordering rule), write_fake_ssh for "the device stage must SUCCEED" (the
# deletion). Both replace or configure the ssh BINARY from outside; no seam was
# added to bin/redoku to make any of this observable. write_fake_ssh's header
# says exactly how much of a device it emulates and which single command it
# refuses to really run.

# install_a_kit_for_self <work> <home> <kit> <bin|-> <label> — the setup every
# uninstall --self test starts from. "-" means --no-symlink.
_install_a_kit_for_self() {
  _ias_w=$1; _ias_home=$2; _ias_kit=$3; _ias_bin=$4; _ias_label=$5
  write_stub_cli "$_ias_w/cli"
  make_fixture_release "$_ias_w/release" v0.1.0 "$_ias_w/cli"
  if [ "$_ias_bin" = - ]; then
    set -- --no-symlink
  else
    set -- --bin-dir "$_ias_bin"
  fi
  assert_fails "$_ias_label: the setup install ends at the connect step" -- \
    env REDOKU_BASE_URL="file://$_ias_w/release" HOME="$_ias_home" \
      "$KIT_SH" "$REPO/bin/redoku" install --download --kit "$_ias_kit" \
      "$@" --host nowhere --yes < /dev/null || return 1
  assert_file "$_ias_kit/v0.1.0/VERSION" "$_ias_label: the kit is there to be removed" || return 1
}

# The ordering rule, and the only sub-case that can be proved without a device
# at all: the device stage fails, so NOTHING host-side may be deleted and the
# run has to say the kit is still here. Both connect() and remote() fail by
# exiting the process, which is why that sentence comes from an EXIT trap.
test_kit_uninstall_self_device_first() {
  _w=$(mktemp -d "$ROOT/kit-self-order.XXXXXX")
  _home=$_w/home
  _kit=$_w/kit
  _bin=$_w/bindir
  mkdir -p "$_home"
  _install_a_kit_for_self "$_w" "$_home" "$_kit" "$_bin" "self ordering" || return 1
  _wrapper=$(kit_digest "$_bin/redoku")
  make_dead_ssh_config "$_w/ssh_config"

  assert_fails "self ordering: the run ends non-zero at the connect step" -- \
    env HOME="$_home" "$KIT_SH" "$_kit/current/bin/redoku" uninstall --self \
      --bin-dir "$_bin" --ssh-config "$_w/ssh_config" --host nowhere --yes \
      < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "could not connect to root@nowhere" \
    "self ordering: it failed at the device, not somewhere host-side" || return 1
  # "was NOT removed" appears only in that trap.
  assert_contains "$ASSERT_OUTPUT" "was NOT removed" \
    "self ordering: it says the host kit is still there" || return 1
  assert_contains "$ASSERT_OUTPUT" "$_kit" \
    "self ordering: and names the kit it left alone" || return 1

  assert_file "$_kit/v0.1.0/VERSION" "self ordering: the kit was NOT deleted" || return 1
  assert_eq "v0.1.0" "$(readlink "$_kit/current")" "self ordering: current is untouched" || return 1
  assert_eq "$_wrapper" "$(kit_digest "$_bin/redoku")" \
    "self ordering: the PATH entry is untouched too" || return 1
}

# --dry-run: the plan names, by absolute path, everything that would be
# deleted, and deletes none of it. §5.3's rule is that nothing is removed that
# was not in that plan, so the plan is the contract.
test_kit_uninstall_self_dry_run() {
  _w=$(mktemp -d "$ROOT/kit-self-dry.XXXXXX")
  _home=$_w/home
  _kit=$_w/kit
  _bin=$_w/bindir
  mkdir -p "$_home"
  _install_a_kit_for_self "$_w" "$_home" "$_kit" "$_bin" "self dry-run" || return 1
  _wrapper=$(kit_digest "$_bin/redoku")
  # The install resolved the kit root before recording it in the wrapper, so
  # the plan prints the resolved form and the expectation has to match it.
  _kit_resolved=$(CDPATH='' cd -- "$_kit" && pwd -P) || \
    die "test_kit_uninstall_self_dry_run: could not resolve $_kit"

  set +e
  ASSERT_OUTPUT=$(env HOME="$_home" "$KIT_SH" "$_kit/current/bin/redoku" uninstall \
    --self --dry-run --bin-dir "$_bin" --host nowhere --yes < /dev/null 2>&1)
  _dr_rc=$?
  set -e
  assert_eq 0 "$_dr_rc" "self dry-run: exits 0 (output: $ASSERT_OUTPUT)" || return 1

  assert_contains "$ASSERT_OUTPUT" "            $_kit_resolved" \
    "self dry-run: the plan names the kit root by absolute path" || return 1
  # Review F2's other half: the plan ENUMERATES the children it will delete
  # rather than summarising them as "every version directory in it". A summary
  # read as reassuring on a root where what would actually go was somebody's
  # source tree, so the contract is now the list.
  assert_contains "$ASSERT_OUTPUT" "            $_kit_resolved/v0.1.0" \
    "self dry-run: the plan names each version directory it will delete" || return 1
  assert_contains "$ASSERT_OUTPUT" "            $_kit_resolved/current" \
    "self dry-run: and the 'current' symlink" || return 1
  assert_contains "$ASSERT_OUTPUT" "            $_bin/redoku" \
    "self dry-run: the plan names the wrapper by absolute path" || return 1
  assert_contains "$ASSERT_OUTPUT" "on THIS machine (not the device)" \
    "self dry-run: the plan says which machine --self is about" || return 1
  assert_contains "$ASSERT_OUTPUT" "still there and nothing was removed" \
    "self dry-run: it stops rather than doing it" || return 1

  assert_file "$_kit/v0.1.0/VERSION" "self dry-run: the kit is still there" || return 1
  assert_eq "v0.1.0" "$(readlink "$_kit/current")" "self dry-run: current is still there" || return 1
  assert_eq "$_wrapper" "$(kit_digest "$_bin/redoku")" "self dry-run: the wrapper is untouched" || return 1
}

# The success path: device stage satisfied by write_fake_ssh, so the deletion
# actually runs. Kit root gone, wrapper gone, nothing else asked for.
test_kit_uninstall_self_removes_kit_and_wrapper() {
  _w=$(mktemp -d "$ROOT/kit-self-done.XXXXXX")
  _home=$_w/home
  _kit=$_w/kit
  _bin=$_w/bindir
  mkdir -p "$_home"
  _install_a_kit_for_self "$_w" "$_home" "$_kit" "$_bin" "self removal" || return 1
  assert_file "$_bin/redoku" "self removal: the wrapper is there to be removed" || return 1
  write_fake_ssh "$_w/fakebin/ssh" "$_w/device"

  set +e
  ASSERT_OUTPUT=$(env PATH="$_w/fakebin:$PATH" HOME="$_home" \
    "$KIT_SH" "$_kit/current/bin/redoku" uninstall --self --bin-dir "$_bin" \
    --host nowhere --yes < /dev/null 2>&1)
  _rm_rc=$?
  set -e
  assert_eq 0 "$_rm_rc" "self removal: exits 0 (output: $ASSERT_OUTPUT)" || return 1
  # Non-vacuity: without this the whole test would still "pass" if the device
  # stage had been skipped rather than satisfied, which is the one thing the
  # ordering rule says must never happen.
  assert_contains "$ASSERT_OUTPUT" "fake device: ran the on-device uninstaller" \
    "self removal: the device stage really ran before anything was deleted" || return 1
  assert_contains "$ASSERT_OUTPUT" "done — the device is back to stock and this machine has no reDoku kit left" \
    "self removal: it reports both halves" || return 1
  # The EXIT trap that carries the "kit left in place" sentence has to be
  # DISARMED once the device stage succeeds, or every successful run ends by
  # claiming it removed nothing.
  case $ASSERT_OUTPUT in
    *"was NOT removed"*)
      printf 'FAIL: self removal: a successful run still claimed the kit was left in place\n  output: %s\n' "$ASSERT_OUTPUT" >&2
      return 1 ;;
  esac

  assert_no_file "$_kit" "self removal: the kit root is gone" || return 1
  assert_no_file "$_bin/redoku" "self removal: the PATH entry is gone" || return 1
  # …and nothing beyond what the plan named. The bin directory is somebody's
  # ~/.local/bin, holding whatever else they keep there; only the one file
  # inside it was ever ours.
  [ -d "$_bin" ] || {
    printf 'FAIL: self removal: the bin directory itself was removed, not just our file in it\n' >&2
    return 1
  }
}

# The two things --self must leave alone, in one run: a `redoku` at the bin dir
# that is not ours (§5.3's ownership test — a package manager's, or a script of
# the user's), and anything of the user's own sitting in the kit root, which
# also stops the root itself from being removed.
test_kit_uninstall_self_leaves_what_is_not_ours() {
  _w=$(mktemp -d "$ROOT/kit-self-foreign.XXXXXX")
  _home=$_w/home
  _kit=$_w/kit
  _bin=$_w/bindir
  mkdir -p "$_home" "$_bin"
  # --no-symlink, so nothing of ours is ever written to the bin dir.
  _install_a_kit_for_self "$_w" "$_home" "$_kit" - "self foreign" || return 1
  printf '#!/bin/sh\n# somebody else put this here\necho not ours\n' > "$_bin/redoku"
  chmod +x "$_bin/redoku"
  _foreign=$(kit_digest "$_bin/redoku")
  mkdir -p "$_kit/notes"
  printf 'keep me\n' > "$_kit/notes/README"
  write_fake_ssh "$_w/fakebin/ssh" "$_w/device"

  set +e
  ASSERT_OUTPUT=$(env PATH="$_w/fakebin:$PATH" HOME="$_home" \
    "$KIT_SH" "$_kit/current/bin/redoku" uninstall --self --bin-dir "$_bin" \
    --host nowhere --yes < /dev/null 2>&1)
  _fg_rc=$?
  set -e
  assert_eq 0 "$_fg_rc" "self foreign: exits 0 (output: $ASSERT_OUTPUT)" || return 1
  assert_contains "$ASSERT_OUTPUT" "fake device: ran the on-device uninstaller" \
    "self foreign: the device stage really ran" || return 1

  assert_eq "$_foreign" "$(kit_digest "$_bin/redoku")" \
    "self foreign: a 'redoku' that is not ours is byte-unchanged" || return 1
  assert_contains "$ASSERT_OUTPUT" "$_bin/redoku" \
    "self foreign: its path is printed" || return 1
  assert_contains "$ASSERT_OUTPUT" "is NOT ours" \
    "self foreign: and the plan said it would be left" || return 1

  assert_no_file "$_kit/v0.1.0" "self foreign: the version directory was still removed" || return 1
  assert_no_file "$_kit/current" "self foreign: and so was current" || return 1
  assert_file "$_kit/notes/README" "self foreign: the user's own file survived" || return 1
  assert_contains "$ASSERT_OUTPUT" "did not put there" \
    "self foreign: the run says the root was left and why" || return 1
}

# The guards, each refusing on its own and leaving everything where it is.
# None of these reaches the device: a root that could never be removed is
# refused before an ssh connection is opened, so the run cannot end with a
# device returned to stock and a kit still sitting there for no reason.
test_kit_uninstall_self_guards_refuse() {
  _w=$(mktemp -d "$ROOT/kit-self-guards.XXXXXX")
  _home=$_w/home
  mkdir -p "$_home"
  build_fake_checkout "$_w/checkout"

  # (a) a checkout: there is no kit here to remove.
  assert_fails "self guards: (a) a checkout is refused" -- \
    env HOME="$_home" "$KIT_SH" "$_w/checkout/bin/redoku" uninstall --self \
      --host nowhere --yes < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "you're in a checkout — there is no kit here" \
    "self guards: (a) says why" || return 1
  assert_contains "$ASSERT_OUTPUT" "bin/redoku uninstall" \
    "self guards: (a) names the right thing to do instead" || return 1

  # (b) an ordinary directory of the user's, named with --kit.
  _plain=$_w/not-a-kit
  mkdir -p "$_plain"
  printf 'mine\n' > "$_plain/notes.txt"
  assert_fails "self guards: (b) a non-kit directory is refused" -- \
    env HOME="$_home" "$KIT_SH" "$_w/checkout/bin/redoku" uninstall --self \
      --kit "$_plain" --host nowhere --yes < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "does not look like a reDoku kit" \
    "self guards: (b) says what is wrong with it" || return 1
  assert_file "$_plain/notes.txt" "self guards: (b) its contents are untouched" || return 1
  case $ASSERT_OUTPUT in
    *"connecting to"*)
      printf 'FAIL: self guards: (b) it opened an ssh connection before refusing\n  output: %s\n' "$ASSERT_OUTPUT" >&2
      return 1 ;;
  esac

  # (c) the home directory itself. $HOME here is under a symlinked path
  # (/var -> /private/var on macOS), and resolve_kit_root resolves --kit while
  # $HOME stays as written — so this only refuses because the guard compares
  # against BOTH spellings, which is the reason it does.
  assert_fails "self guards: (c) \$HOME is refused as a kit root" -- \
    env HOME="$_home" "$KIT_SH" "$_w/checkout/bin/redoku" uninstall --self \
      --kit "$_home" --host nowhere --yes < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "refusing to remove your home directory" \
    "self guards: (c) says so by name" || return 1

  # (d) a directory that holds this very script directly, rather than holding
  # it the way a kit holds its versions (<root>/<version>/bin/redoku). It has
  # a 'current' symlink, so it passes the looks-like-a-kit test and only this
  # guard stands between it and an rm -rf.
  _odd=$_w/oddkit
  mkdir -p "$_odd/bin" "$_odd/device" "$_odd/v0.1.0"
  cp "$REPO/bin/redoku" "$_odd/bin/redoku"
  chmod +x "$_odd/bin/redoku"
  cp "$REPO/device/uninstall.sh" "$_odd/device/uninstall.sh"
  printf 'v0.1.0\n' > "$_odd/v0.1.0/VERSION"
  ln -s v0.1.0 "$_odd/current"
  assert_fails "self guards: (d) a root holding this script directly is refused" -- \
    env HOME="$_home" "$KIT_SH" "$_odd/bin/redoku" uninstall --self \
      --kit "$_odd" --host nowhere --yes < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "which sits directly in it rather than inside one of its version directories" \
    "self guards: (d) says exactly what is wrong with the shape" || return 1
  assert_file "$_odd/v0.1.0/VERSION" "self guards: (d) nothing was removed" || return 1

  # (e) --self is uninstall-only, validated like --purge.
  assert_fails "self guards: (e) --self on another command is refused" -- \
    env HOME="$_home" "$KIT_SH" "$_w/checkout/bin/redoku" status --self \
      --host nowhere < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "--self only applies to uninstall" \
    "self guards: (e) says so" || return 1

  # (f) review F2: a directory of somebody's own projects. It has never held a
  # kit, has no 'current', and its one VERSION-bearing child is a source tree
  # whose VERSION says something other than its own name. Under the old guard
  # all five passed and coolproject-1.2 was recursively deleted, while the plan
  # block called it "every version directory in it".
  _docs=$_w/Documents
  mkdir -p "$_docs/letters" "$_docs/coolproject-1.2"
  printf '1.2.0\n' > "$_docs/coolproject-1.2/VERSION"
  printf 'int main(void){}\n' > "$_docs/coolproject-1.2/main.c"
  printf 'dear sir\n' > "$_docs/letters/a.txt"
  assert_fails "self guards: (f) a projects directory is refused" -- \
    env HOME="$_home" "$KIT_SH" "$_w/checkout/bin/redoku" uninstall --self \
      --kit "$_docs" --host nowhere --yes < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "does not look like a reDoku kit" \
    "self guards: (f) refused, with its own message" || return 1
  # Needle chosen to sit inside one physical line of the message: the phrase
  # "named after their own VERSION file" is split across a wrap, so asserting
  # on it would fail against correct output.
  assert_contains "$ASSERT_OUTPUT" "containing a VERSION that reads" \
    "self guards: (f) the message says what a kit root actually looks like" || return 1
  assert_file "$_docs/coolproject-1.2/main.c" \
    "self guards: (f) the source tree with a VERSION in it survived" || return 1
  assert_file "$_docs/letters/a.txt" "self guards: (f) and everything else did too" || return 1

  # (g) review F5: --kit and --bin-dir are about a kit on THIS machine, which a
  # plain `uninstall` never touches. They used to be accepted and silently
  # ignored there while the refusal message said they applied to
  # "uninstall --self" — a message stating a rule the code did not enforce.
  assert_fails "self guards: (g) --kit on a plain uninstall is refused" -- \
    env HOME="$_home" "$KIT_SH" "$_w/checkout/bin/redoku" uninstall \
      --kit "$_docs" --dry-run --host nowhere --yes < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "--kit only applies to install, upgrade and uninstall --self" \
    "self guards: (g) and the message it always claimed is now true" || return 1
  assert_fails "self guards: (g) --bin-dir on a plain uninstall is refused" -- \
    env HOME="$_home" "$KIT_SH" "$_w/checkout/bin/redoku" uninstall \
      --bin-dir "$_w/bin" --dry-run --host nowhere --yes < /dev/null || return 1
  assert_contains "$ASSERT_OUTPUT" "--bin-dir only applies to install, upgrade and uninstall --self" \
    "self guards: (g) same for --bin-dir" || return 1
}

# ---- status's kit line (design doc §5.2) ---------------------------------
#
# The one line of `status` that is about this machine. Driven with --dry-run so
# connect() returns before any ssh is attempted; the remote block is then a
# dry-run echo and the kit line is printed after it either way.
test_kit_status_line() {
  _w=$(mktemp -d "$ROOT/kit-status.XXXXXX")
  _home=$_w/home
  _kit=$_home/.redoku
  mkdir -p "$_home"
  write_stub_cli "$_w/cli"
  make_fixture_release "$_w/release" v0.1.0 "$_w/cli"

  # (a) a checkout has no kit, and must say what IS true there rather than
  # printing an empty value.
  build_fake_checkout "$_w/checkout"
  _co_repo=$(CDPATH='' cd -- "$_w/checkout" && pwd) || die "test_kit_status_line: cd failed"
  set +e
  ASSERT_OUTPUT=$(env HOME="$_home" "$KIT_SH" "$_w/checkout/bin/redoku" status \
    --dry-run --host nowhere < /dev/null 2>&1)
  _st_rc=$?
  set -e
  assert_eq 0 "$_st_rc" "status line: (a) a checkout status exits 0 (output: $ASSERT_OUTPUT)" || return 1
  assert_contains "$ASSERT_OUTPUT" "kit      : none — running from $_co_repo (KIT_VERSION=dev)" \
    "status line: (a) it names the checkout and KIT_VERSION" || return 1

  # (b) inside a kit: the version and the path, aligned with the device's own
  # lines and with $HOME abbreviated to ~.
  assert_fails "status line: the setup install ends at the connect step" -- \
    env REDOKU_BASE_URL="file://$_w/release" HOME="$_home" \
      "$KIT_SH" "$REPO/bin/redoku" install --download --kit "$_kit" \
      --no-symlink --host nowhere --yes < /dev/null || return 1
  set +e
  ASSERT_OUTPUT=$(env HOME="$_home" "$KIT_SH" "$_kit/current/bin/redoku" status \
    --dry-run --host nowhere < /dev/null 2>&1)
  _st_rc=$?
  set -e
  assert_eq 0 "$_st_rc" "status line: (b) a kit status exits 0 (output: $ASSERT_OUTPUT)" || return 1
  assert_contains "$ASSERT_OUTPUT" "kit      : v0.1.0 (~/.redoku/current)" \
    "status line: (b) the version, the path, ~-abbreviated, aligned like the rest" || return 1
  # It is host-side and stays host-side: the remote script is echoed verbatim
  # by the dry run, and "kit" must not appear inside it.
  case $ASSERT_OUTPUT in
    *'printf "kit'*)
      printf 'FAIL: status line: the kit line was smuggled into the remote script\n  output: %s\n' "$ASSERT_OUTPUT" >&2
      return 1 ;;
  esac

  # (c) a broken kit says so, and names the command that repairs it, rather
  # than printing an empty version.
  rm -f "$_kit/current"
  set +e
  ASSERT_OUTPUT=$(env HOME="$_home" "$KIT_SH" "$_kit/v0.1.0/bin/redoku" status \
    --dry-run --host nowhere < /dev/null 2>&1)
  _st_rc=$?
  set -e
  assert_eq 0 "$_st_rc" "status line: (c) a broken kit's status still exits 0 (output: $ASSERT_OUTPUT)" || return 1
  assert_contains "$ASSERT_OUTPUT" "kit      : ~/.redoku/current — broken, repair it with: redoku upgrade" \
    "status line: (c) it says what is wrong and how to fix it" || return 1
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
test_mkkit_stale_sixth_asset_fails
'

FIND_GAME_TESTS='
test_find_game_checkout_mode_message
test_find_game_kit_mode_message
test_find_game_downloaded_into_checkout_message
'

FETCH_KIT_TESTS='
test_kit_bootstrap_end_to_end
test_kit_second_download_repoints_and_prunes
test_kit_checksum_mismatch
test_kit_tarball_entry_outside_redoku
test_kit_bin_dir_and_path_hint
test_kit_foreign_redoku_left_alone
test_kit_wrapper_self_heals
test_kit_no_sha256_tool
test_kit_dry_run_resolves_every_path
test_kit_prompt_download_rechecks_device_files
test_kit_empty_option_values
test_kit_download_dry_run_writes_nothing
test_kit_staging_beside_destination
test_kit_reuse_gate_rejects_a_partial_tree
test_kit_stamped_version_is_validated
test_kit_staging_shaped_tag_is_refused
test_kit_mv_failure_leaves_nothing_behind
test_kit_step4_reuses_a_complete_tree
test_kit_current_shaped_tag_is_refused
test_kit_reuse_gate_rejects_a_symlinked_destination
test_kit_no_cmp_prints_no_false_warning
'

# design doc §8's tests 5 and 6, plus §5.2's status line. All three drive the
# real bin/redoku offline against a file:// fixture; none of them touches a
# device except through make_dead_ssh_config (which must fail) or
# write_fake_ssh (which stands in for one).
UPGRADE_TESTS='
test_kit_upgrade_repoints_and_prunes
test_kit_upgrade_repairs_current
test_kit_upgrade_refuses_in_a_checkout
test_kit_upgrade_refuses_a_hand_unpacked_kit
test_kit_upgrade_repair_keeps_one_previous
test_kit_upgrade_guards_its_kit_root
test_kit_upgrade_repair_from_outside_keeps_one_previous
test_kit_guard_rejects_a_deploy_root
test_kit_guard_empty_root_scope
'

UNINSTALL_SELF_TESTS='
test_kit_uninstall_self_device_first
test_kit_uninstall_self_dry_run
test_kit_uninstall_self_removes_kit_and_wrapper
test_kit_uninstall_self_leaves_what_is_not_ours
test_kit_uninstall_self_guards_refuse
test_kit_uninstall_names_the_right_fix_for_a_kit
test_kit_status_line
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

for KIT_SH in $KIT_SHELLS; do
  printf '=== find_game tests under KIT_SH=%s ===\n' "$KIT_SH"
  for _t in $FIND_GAME_TESTS; do
    run_test "$_t"
  done
done

for KIT_SH in $KIT_SHELLS; do
  printf '=== fetch_kit / install --download tests under KIT_SH=%s ===\n' "$KIT_SH"
  for _t in $FETCH_KIT_TESTS; do
    run_test "$_t"
  done
done

for KIT_SH in $KIT_SHELLS; do
  printf '=== upgrade tests under KIT_SH=%s ===\n' "$KIT_SH"
  for _t in $UPGRADE_TESTS; do
    run_test "$_t"
  done
done

for KIT_SH in $KIT_SHELLS; do
  printf '=== uninstall --self / status tests under KIT_SH=%s ===\n' "$KIT_SH"
  for _t in $UNINSTALL_SELF_TESTS; do
    run_test "$_t"
  done
done

printf '%s/%s tests passed\n' "$((TEST_COUNT - TEST_FAILED))" "$TEST_COUNT"
[ "$TEST_FAILED" -eq 0 ] || exit 1
