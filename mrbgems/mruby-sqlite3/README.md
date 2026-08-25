# mruby-sqlite3

SQLite3 for reDoku saves (M3a, docs/plans/2026-08-25-m3-sqlite-saves.md).

## Binding path taken (Task 0 decision)

**mattn/mruby-sqlite3 vendored — the hand-rolled fallback was NOT needed.**
The upstream binding (`src/mrb_sqlite3.c`, MIT, © mattn and contributors)
compiled against mruby 4.0.0 without source changes; its pre-3.x names
(`MRB_TT_FIXNUM`, `mrb_fixnum`) resolve via mruby 4.0 compat macros
(`include/mruby/value.h`). Two deliberate deviations from upstream:

1. The C `execute` method is registered as `_execute`, so the Ruby layer in
   `mrblib/sqlite3.rb` can provide the plan's API:
   `execute(sql, binds = [])` returning an array of rows.
2. Upstream's `spec.linker.libraries << 'sqlite3'` is dropped: SQLite itself
   is compiled from the amalgamation vendored in `src/` (public domain), not
   linked from the host.

## Vendoring

The amalgamation is fetched by `make sqlite` (pinned version + SHA3-256
checksum) into `tmp/sqlite/`. It is never fetched at rake time. To update:

    make sqlite
    cp tmp/sqlite/sqlite-amalgamation-*/sqlite3.{c,h} mrbgems/mruby-sqlite3/src/

The mattn binding snapshot came from github.com/mattn/mruby-sqlite3
(default branch, 2026-08-25); its only edits live in `src/mrb_sqlite3.c`
and are marked with comments.
