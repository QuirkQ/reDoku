# M3a — SQLite saves: persist and resume games

**Date:** 2026-08-25
**Status:** planned
**Supersedes:** the PLAN.md §7 sketch of a single key=value state file in
`/home/root/redoku/state` ("no JSON gem needed"). That design covered exactly
one game. This plan moves "multiple saved puzzles" out of the v2 parking lot
into M3a, and upgrades the store to SQLite.

---

## Goal

A player's games survive power loss, SIGTERM, and reboots, and the player can
keep several games at once and pick one to resume:

- Every dug puzzle is auto-saved immediately (crash/power-safe).
- Quitting and relaunching resumes where you left off.
- A GAMES screen lists saved games; tapping one loads it; a delete mode
  removes unwanted ones.

## Why SQLite (the research answer)

The owner asked for SQLite if at all possible. It is possible. Findings:

1. **No SQLite in mruby's default gembox**, and no usable `mruby-json` either.
   Anything storage-shaped must be vendored into this tree, like mruby,
   rM2-stuff, and our three gems already are.
2. **SQLite itself is trivially cross-compilable.** The amalgamation
   (`sqlite3.c` + `sqlite3.h`, one pinned download) is designed for exactly
   this. Dropped into a gem's `src/`, it is compiled by whatever toolchain the
   build uses — host gcc under `make test`, armv7hf gcc under `make build` —
   with zero extra plumbing.
3. **A C binding is needed.** mattn/mruby-sqlite3 is the known gem but targets
   mruby of 2013–2020 vintage; against mruby 4.0.0 it may need small fixes or
   may fight us. Fallback, in keeping with how this repo wrote its own rm2fb
   shim: a minimal binding with just what we need (~200 lines of C: open,
   exec, query-with-binds returning rows, last_insert_rowid, close).
4. **Cost:** ~1 MB binary growth from the amalgamation, statically linked.
   Fine on an rM2. Writes are rare (dig, quit, explicit save), so eMMC wear is
   negligible. Rollback-journal mode (default) keeps the device free of WAL
   side files; `synchronous=FULL` gives real durability across battery pull.

JSON-per-file was the runner-up and would work, but SQLite buys indexed
listing, transactional atomic writes, schema versioning via `PRAGMA
user_version`, and no hand-rolled parser to maintain — for less code than a
correct JSON parser.

## Architecture

```
bin/redoku ── Redoku::App ── @store (Redoku::Store)  ── SQLite3::Database ── libsqlite3 (static amalgamation)
                 │
                 ├── generator seam (existing)      same injection pattern
                 └── mode :play / :menu             new screen state
```

- **DB path:** `/home/root/redoku/games.db`. `/home/root/redoku` survives
  firmware updates (install.sh relies on this already). The path is injectable
  so host tests use tmp files.
- **Store is pure Ruby over the binding**, host-testable against real SQLite
  in mrbtest — no filesystem fakes needed, unlike the JSON plan which would
  have needed them.
- **What is saved:** `givens`, `entries`, `solution` (the Grid class's
  existing 81-char `[0-9.]` strings), requested difficulty, achieved tier,
  timestamps. **Ink is not saved**: strokes are ephemeral marks on the
  framebuffer with no model behind them yet; stroke journaling stays v2.
  `entries` is currently always 81 dots until the M3 recognizer lands — the
  schema is future-proofed for it regardless.

## Schema

```sql
PRAGMA user_version = 1;

CREATE TABLE IF NOT EXISTS games (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  kind          TEXT    NOT NULL CHECK (kind IN ('autosave','manual')),
  difficulty    TEXT    NOT NULL,   -- requested tier
  achieved_tier TEXT    NOT NULL,   -- tier the board actually landed on
  givens        TEXT    NOT NULL,   -- 81 chars, '.' = empty
  entries       TEXT    NOT NULL,   -- 81 chars, '.' = empty
  solution      TEXT    NOT NULL,   -- 81 digits
  created_at    INTEGER NOT NULL,   -- unix epoch
  updated_at    INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_games_updated ON games(updated_at DESC);
```

- `autosave`: at most one row, upserted. Holds the game in progress.
- `manual`: explicit saves from the SAVE flow / menu, capped at 50.
- On read, every row is validated (lengths, `[0-9.]` charset, difficulty in
  TIERS) before use; a bad row is skipped and logged — *an unchanged board
  beats a wiped one*, same rule as §11's signal handling.
- If the DB file is corrupt on open: rename aside to `games.db.bad-<epoch>`,
  recreate empty, log. **The game must never refuse to start because of its
  save file.**

## Store API

```ruby
Redoku::Store.open(path)   # mkdir -p parent; create schema; check user_version
# instance:
#   save_autosave(game) -> id        # upserts the singleton autosave row
#   autosave            -> hash|nil  # full game record
#   save_manual(game)   -> id|nil    # nil when grid nil, db error, or cap reached (logged)
#   games               -> [{id:, kind:, difficulty:, achieved_tier:, updated_at:}, ...]
#                                   ordered by updated_at DESC — metadata only, no puzzle strings
#   load(id)            -> hash|nil  # full record, validated
#   delete(id)          -> true|false
#   close
# game hash: {difficulty:, achieved_tier:, givens:, entries:, solution:}
```

One connection held open for the app's lifetime; single process, so locking
is moot. All writes inside transactions. Values bound as parameters where the
binding supports it; every string we write is validated `[0-9.]{81}` first
regardless.

---

## Global constraints (inherited)

1. **The mrbtest dependency trap:** `mruby-redoku` must declare its dependency
   on the new `mruby-sqlite3` gem in `mrbgem.rake`. Undeclared deps pass on
   device but raise under `make test`.
2. Host-first: everything Ruby-side is written and tested under `make test`
   before any device run.
3. No network access at rake time — the amalgamation is fetched by a pinned
   Makefile target like mruby/rM2-stuff, never by mrbgem.rake.
4. Font charset is A–Z, 0–9, space, `-`, `:`, `.` only. All UI labels below
   stay within it. Epoch times are formatted by hand (digits exist; strftime
   is not among our declared deps).

---

## Task 0 — Spike: SQLite + a binding on mruby 4.0.0  *(GO/NO-GO gate)*

Nothing else starts until this passes. Throwaway quality is fine here.

- [ ] Add Makefile target to fetch the pinned SQLite amalgamation
      (`SQLITE_VERSION ?= <latest 3.x>`) into `tmp/sqlite/`; verify checksum
      if published.
- [ ] Create `mrbgems/mruby-sqlite3/` skeleton: copy `sqlite3.c`/`sqlite3.h`
      into its `src/` so mruby compiles them automatically; add slimming
      flags via `spec.cc.flags`:
      `-DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION
       -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_OMIT_DEPRECATED
       -DSQLITE_OMIT_PROGRESS_CALLBACK -DSQLITE_MAX_EXPR_DEPTH=0`.
- [ ] Vendor mattn/mruby-sqlite3's binding source; attempt host build.
- [ ] Write a throwaway mrbtest that CREATEs a table, INSERTs a row, SELECTs
      it back, and reopens the file to confirm persistence.
- [ ] Run `make build`; confirm the ARM binary links and grows by ~1 MB.
- [ ] Device smoke: ssh, run a one-off script that opens
      `/home/root/redoku/spike.db`, inserts, exits; rerun and SELECT the row
      back; delete spike.db.
- [ ] **If the vendored binding fights mruby 4.0.0:** write the minimal
      binding instead (~200 LOC: `Database.open(path)`, `#execute(sql,
      binds=[])` → array of rows, `#exec(sql)`, `#last_insert_rowid`,
      `#close`). Decide and record the outcome here before Task 1.

**Gate passes when:** host mrbtest smoke green, ARM binary runs on device,
row survives process restart.

## Task 1 — `Redoku::Store`

- [ ] `mrbgems/mruby-redoku/mrblib/redoku/store.rb`: implement the API above.
- [ ] Schema creation + `user_version`; refuse-to-start protection (corrupt →
      rename aside + recreate) lives here.
- [ ] Row validation helper shared by `autosave`/`load`/`games`.
- [ ] Declare `spec.add_dependency('mruby-sqlite3', path: ...)` in
      `mrbgems/mruby-redoku/mrbgem.rake` (constraint 1).
- [ ] Tests in `mrbgems/mruby-redoku/test/store.rb` against tmp-dir DBs:
      round-trip save/load, autosave upsert semantics, manual cap at 50,
      corrupt-row skip, corrupt-file recovery, delete, persistence across
      reopen, `games` ordering and metadata-only shape.
- [ ] Verify: `make test`.

## Task 2 — App wiring

- [ ] `App.new(store: seam)` — injected like `generator:`; bin tool passes
      `/home/root/redoku/games.db`; tests pass tmp paths. Missing/unopenable
      DB ⇒ play on without persistence (log only).
- [ ] After a successful dig in `fill_board`, write the autosave row.
- [ ] Quit path (button and SIGTERM/SIGINT handlers, discharging PLAN.md §11):
      refresh the autosave row, then close the store, then exit 0.
- [ ] New / Level change does **not** implicitly save a manual copy — it is a
      deliberate discard, consistent with today's "New clears the ink".
      Documented here as a decision; revisitable.
- [ ] Track `@current_save_id` (nil for unsaved manual copies).

## Task 3 — Resume on launch

- [ ] In `App#run`: if `store.autosave` exists, restore it — rebuild Grid via
      `Grid.parse` on givens, replay entries with `set_entry`, set achieved
      tier, skip the dig — and repaint. Splash/dig only when there is none.
- [ ] Ink stays blank after resume (not persisted); note in the splash text?
      No — silent, matches board-after-clear behavior.
- [ ] Test: app-level test with a tmp-path store — dig → quit → new App →
      same givens/tier restored.

## Task 4 — GAMES menu UI

- [ ] Layout: add a second button on row 2 — `:games` at the left position;
      `:quit` stays right. Confirm geometry fits within margins in
      `layout.rb` before coding.
- [ ] `App` gains `@mode` (`:play` / `:menu`); press routing switches on it.
- [ ] Renderer: `draw_games_menu(list, page, delete_mode)` — title `GAMES`,
      rows filling the board area (row height ≈ cell height; expect ~9 per
      page), each row `N TIER YYYY-MM-DD HH:MM` from `updated_at` (hand
      formatting). Empty state: `NO SAVED GAMES`.
- [ ] Pagination: `PREV`/`NEXT` buttons rendered only when the list exceeds
      one page.
- [ ] Interactions:
      - tap row → load that game (set current id, repaint board, press-ack);
      - `DEL` toggles delete mode (label inverts while active); next row taps
        delete instead of load;
      - `BACK` returns to play.
- [ ] Save affordance in play mode: pressing `:games` opens the menu; saving
      the current game happens via a `SAVE` action inside the menu (writes a
      manual row; refused with a logged warning at cap).
- [ ] Verify all labels render within the glyph set; visual pass on device.

## Task 5 — Install / docs

- [ ] No installer change needed — `/home/root/redoku` exists and survives
      updates; Store creates its own directory. `uninstall.sh --purge` already
      removes the DB with it. Confirm both.
- [ ] Update PLAN.md: §7 persistence sketch replaced by a pointer to this
      plan; parking lot loses "multiple saved puzzles"; milestone status
      noted on completion.
- [ ] README: one paragraph — games auto-save and resume; GAMES manages
      saves; DB lives at `/home/root/redoku/games.db`.
- [ ] Full verification: `make test`, `make build`, deploy, then on device:
      dig → quit → relaunch resumes; save three games, list, load each,
      delete one; pull battery mid-game → relaunch resumes.

---

## Out of scope (explicitly)

- Persisting ink/strokes (needs a journal model — v2).
- Saving recognizer entries meaningfully (arrives with the M3 recognizer; the
  column already exists).
- Export/import of games, statistics, named saves, cloud anything.
- A delete-all shortcut (ssh + removing the file covers it).

## Risks

| Risk | Mitigation |
| --- | --- |
| mattn binding incompatible with mruby 4.0.0 | Spike decides first; bounded fallback is our own ~200-line binding |
| Amalgamation warnings under stricter flags | Tune flags in the gem only; do not relax project-wide flags |
| Binary size +~1 MB | Accepted; static link, no runtime device dependency |
| Corrupt DB bricks the game | Rename-aside-and-recreate; game always starts |
| Accidental data loss via DEL mode | Toggle requires a second deliberate tap; deletion is per-row only |
