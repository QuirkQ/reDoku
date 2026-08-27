# mruby-sqlite3

SQLite3 for reDoku saves (M3a, docs/plans/2026-08-25-m3-sqlite-saves.md).

## Binding path taken (Task 0 decision)

**mattn/mruby-sqlite3 vendored — the hand-rolled fallback was NOT needed.**
The upstream binding (`src/mrb_sqlite3.c`, MIT, © mattn and contributors)
compiled against mruby 4.0.0 without source changes.

**Task 0 got one thing wrong and it cost a milestone.** It recorded that the
binding's pre-3.x names "`MRB_TT_FIXNUM`, `mrb_fixnum` resolve via mruby 4.0
compat macros". Only the first is a compat alias (`MRB_TT_FIXNUM` is
`#define`d to `MRB_TT_INTEGER`). `mrb_fixnum` / `mrb_fixnum_value` are NOT
aliases for `mrb_integer` / `mrb_int_value`: they are the IMMEDIATE-ONLY
accessors. Under `MRB_WORD_BOXING` (mruby's default since 3.2, see
`include/mrbconf.h`) an Integer past `MRB_FIXNUM_MAX` is heap-allocated, and
those two read/write the `mrb_value` word as if it were never a pointer.
`MRB_FIXNUM_MAX` is `INT64_MAX >> 1` on the 64-bit host but `INT32_MAX >> 1`
= 1_073_741_823 on the 32-bit armv7 device — and a Unix epoch is 1.79e9. So
every `created_at` / `updated_at` the device wrote was half a heap address,
saved games listed as 1970, and the host suite could not see it. Fixed by
using the boxing-aware accessors at all five sites, marked `reDoku edit`; the
regression test in `test/sqlite3.rb` derives the boundary from
`Integer#size` so it bites on both word sizes.

Three deliberate deviations from upstream:

1. The C `execute` method is registered as `_execute`, so the Ruby layer in
   `mrblib/sqlite3.rb` can provide the plan's API:
   `execute(sql, binds = [])` returning an array of rows.
2. Upstream's `spec.linker.libraries << 'sqlite3'` is dropped: SQLite itself
   is compiled from the amalgamation vendored in `src/` (public domain), not
   linked from the host.
3. `mrb_fixnum` / `mrb_fixnum_value` replaced with `mrb_integer` /
   `mrb_int_value` (five sites), per the note above. Carry this forward on
   any re-vendor: upstream still uses the immediate-only accessors, so a
   straight re-copy silently reintroduces the 1970 timestamps.

## Vendoring

The amalgamation is fetched by `make sqlite` (pinned version + SHA3-256
checksum) into `tmp/sqlite/`. It is never fetched at rake time. To update:

    make sqlite
    cp tmp/sqlite/sqlite-amalgamation-*/sqlite3.{c,h} mrbgems/mruby-sqlite3/src/

The mattn binding snapshot came from github.com/mattn/mruby-sqlite3
(default branch, 2026-08-25); its only edits live in `src/mrb_sqlite3.c`
and are marked with comments.
