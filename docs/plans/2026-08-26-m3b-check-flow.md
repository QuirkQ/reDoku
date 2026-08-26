# M3b — the check flow: ink becomes an answer

> **For agentic workers:** REQUIRED SUB-SKILL: use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to implement this plan task-by-task, **in
> order**. Steps use checkbox (`- [ ]`) syntax for tracking. The ledger is
> `.superpowers/sdd/2026-08-26-m3b-check-flow/progress.md` — append to it
> after every task and every review, as M1/M2/the difficulty rework did.

**Date:** 2026-08-26
**Status:** planned
**Spec:** [`docs/design/m3b-check-flow.md`](../design/m3b-check-flow.md) — the
plan argues from the spec and the spec travels with it. Read both.
**Supersedes:** PLAN.md §6's pipeline detail (the $P sizing is wrong — see
Task 5) and §7's "Mistake checking" paragraph (ink is no longer kept on a
correct cell). PLAN.md §10's M3b bullet is the scope this refines.

---

## Goal

Pressing CHECK reads every inked cell once, writes what it read into the game
model, marks each cell right / wrong / unreadable, and declares a win only
when the board really is solved. Erasing becomes real, so the workflow the
whole thing rests on — *erase your notes, then check* — actually holds across
a relaunch.

## Architecture

Three layers, added bottom-up so each task is testable on the host before the
next one leans on it:

1. **`Redoku::Ink`** — pure stroke geometry (bounding box, centre, which cell,
   path length). No display, no store, no sudoku. Consumed by erase, by
   retirement and by the recognizer's grouping.
2. **`Redoku::Recognizer`** — one fixed seam, `read(strokes) ->
   [digit_or_nil, confidence]`, behind which a cheap feature classifier (and
   possibly a $P second stage) lives. Fixing the seam first is what lets the
   CHECK flow be built and tested against a stub.
3. **`App#run_check`** — the pass itself: group live ink by cell, read each,
   write entries, retire ink, paint marks, autosave, maybe win.

Underneath, `Store` goes to **schema v3** to carry stroke identity and a
`retired` flag, and `Grid` gains a fourth cell state for "unreadable" that is
contained by a single filter in `value_at`.

## Tech stack

mruby 4.0.0, pure Ruby in `mrbgems/mruby-redoku/mrblib/redoku/`. Tests are
mrbtest assertions under `mrbgems/mruby-redoku/test/`, run by `make test`
(Docker). Device build is `make build`. No new gems, no new C.

## Global constraints (inherited)

1. **The mrbtest dependency trap:** any new dependency must be declared in
   `mrbgems/mruby-redoku/mrbgem.rake`. Undeclared deps pass on device but
   raise under `make test`. *(This plan adds no gem, so nothing to declare —
   stated because it is the trap that has bitten this repo before.)*
2. **Host-first:** everything Ruby-side is written and tested under
   `make test` before any device run. Only Task 11 needs hardware.
3. **Font charset is `A–Z`, `0–9`, space, `-`, `:`, `.` only.** `Font.draw`
   **silently draws nothing** for a character it lacks. `'?'` is *not* in
   `Font::GLYPHS` today — Task 7 adds it. Every UI string below stays inside
   the charset.
4. **Waveform discipline** (PLAN.md §3, and `App#flush_ink` says it at the
   point of choice): `DU` for pen ink, `GL16` for chrome. `ENTRY_GRAY` is 96,
   a mid tone, so **any repaint that puts an entry digit on the glass, or
   takes one off, needs `GL16` for that region.** A `DU` repaint of a cell
   holding an entry leaves a ghost.
5. **`Grid` must stay invisible to the engine.** Nothing in
   `mrblib/redoku/sudoku/` takes a `Grid` instance — `Solver`, `Rater` and
   `Techniques` all take raw `values` arrays. Task 4 must not change that.
6. **Every button press acknowledges itself at the button** (M1's decision,
   re-checked at M2): paint inverted, run the action, paint back ~200 ms
   later. `acknowledge(name) { ... }` already does this.
7. **Files stay focused.** `app.rb` is already 1482 lines and `test/app.rb`
   2675. New responsibilities go in new files (`ink.rb`, `recognizer.rb`,
   `templates.rb`) with their own test files, not appended to `app.rb`.

## File structure

| File | Responsibility | Task |
|---|---|---|
| `mrblib/redoku/ink.rb` | **new** — stroke geometry only | 1 |
| `test/ink.rb` | **new** — its tests | 1 |
| `mrblib/redoku/store.rb` | schema v3, stroke identity, retirement | 2 |
| `test/store.rb` | migration + retirement tests | 2 |
| `mrblib/redoku/app.rb` | erase deletes ink; CHECK; win; level menu | 3, 7, 8, 9 |
| `test/app.rb` | the two probes, then the CHECK flow | 3, 7, 8, 9 |
| `mrblib/redoku/sudoku/grid.rb` | the `UNREADABLE` cell state | 4 |
| `test/sudoku_grid.rb` | its tests, incl. the no-false-win pin | 4 |
| `mrblib/redoku/recognizer.rb` | **new** — the seam + classifier | 5, 6 |
| `mrblib/redoku/templates.rb` | **new** — authored template clouds | 5 |
| `test/recognizer.rb` | **new** — accuracy + cost measurement | 5, 6, 12 |
| `mrblib/redoku/renderer.rb` | marks, win screen, level menu | 7, 8, 9 |
| `mrblib/redoku/layout.rb` | the CHECK button, level-menu rows | 7, 9 |
| `mrblib/redoku/font.rb` | one glyph: `'?'` | 7 |
| `mrblib/redoku/recorder.rb` | **new** — the template-capture state machine | 10 |
| `test/record.rb` | **new** — its tests | 10 |
| `mrblib/redoku/main.rb` | `--record` | 10 |

**Load order matters here and has bitten this repo before.** mruby loads a
gem's `mrblib` as `Dir.glob('mrblib/**/*.rb')` **sorted**, so the new files
land as `…/pen.rb`, `recognizer.rb`, `recorder.rb`, `renderer.rb`, … — which
puts `recognizer.rb` *before* both `sudoku/grid.rb` and `templates.rb`. Any
constant that is **evaluated at load time** must therefore not reference
another file's constant; references inside method bodies are fine, being
resolved when called. This is the trap `ENGINE-IMPROVEMENTS.md` item 4
records against `DEMAND_SETS`, where it forced four rule lists to be
duplicated by hand. Task 5 resolves it with a memoised method and pins that
with a test.

---

## Task 1 — `Redoku::Ink`: stroke geometry

**Files:** create `mrbgems/mruby-redoku/mrblib/redoku/ink.rb`, create
`mrbgems/mruby-redoku/test/ink.rb`.

**Interfaces produced** (Tasks 3, 5 and 7 all consume these):

```
Ink.bbox(stroke)        -> [min_x, min_y, max_x, max_y]  or nil if no points
Ink.centre(stroke)      -> [cx, cy]                      or nil
Ink.cell_of(stroke)     -> Integer 0..80                 or nil if off board
Ink.path_length(stroke) -> Integer (pixels, rounded down)
```

A **stroke** is the hash M3a already journals and replays:
`{ color: Integer, width: Integer, subpaths: [[[x, y], ...], ...] }`, panel
coordinates. Task 2 adds an `id:` key; `Ink` ignores it.

- [ ] **Step 1: write the failing tests** in `test/ink.rb`.

```ruby
# Ink is pure geometry over the stroke hash M3a journals: no display, no
# store, no sudoku. Every helper here is called once per stroke per CHECK,
# so they allocate nothing they do not have to.

def ink_stroke(subpaths)
  { color: Redoku::App::INK_GRAY, width: Redoku::App::INK_WIDTH,
    subpaths: subpaths }
end

assert('Ink.bbox spans every subpath') do
  s = ink_stroke([[[10, 20], [30, 40]], [[5, 50], [7, 9]]])
  assert_equal [5, 9, 30, 50], Redoku::Ink.bbox(s)
end

assert('Ink.bbox of a stroke with no points is nil') do
  assert_nil Redoku::Ink.bbox(ink_stroke([]))
  assert_nil Redoku::Ink.bbox(ink_stroke([[]]))
end

assert('Ink.centre is the bounding box centre, not the mean point') do
  # Nine points bunched left, one far right: the mean would sit left of
  # centre, the bbox centre does not. Which one we use decides the cell a
  # digit with a long tail lands in, so this is pinned deliberately.
  pts = [[10, 10], [10, 11], [10, 12], [10, 13], [10, 14],
         [10, 15], [10, 16], [10, 17], [10, 18], [110, 10]]
  assert_equal [60, 14], Redoku::Ink.centre(ink_stroke([pts]))
end

assert('Ink.cell_of answers the cell holding the bbox centre') do
  # Cell (1,1) is index 10: x 212..351, y 340..479.
  x, y, w, h = Redoku::Layout.cell_rect(1, 1)
  cx = x + w / 2
  cy = y + h / 2
  s = ink_stroke([[[cx - 5, cy - 5], [cx + 5, cy + 5]]])
  assert_equal 10, Redoku::Ink.cell_of(s)
end

assert('a stroke whose centre lies outside the board has no cell') do
  s = ink_stroke([[[0, 0], [4, 4]]]) # above and left of BOARD_X/BOARD_Y
  assert_nil Redoku::Ink.cell_of(s)
end

assert('cell_of follows the CENTRE even when the ink crosses a cell line') do
  # PLAN.md §6 contradicts itself here: step 1 says "the cell containing its
  # bounding-box center", the pre-classification guards say "strokes fully
  # inside a cell's bounds only". The centre wins (spec §4) — a digit
  # written slightly over a line is normal handwriting, and discarding it
  # would be invisible to the player.
  x, y, w, h = Redoku::Layout.cell_rect(4, 4)
  s = ink_stroke([[[x - 20, y + h / 2], [x + w / 2 + 10, y + h / 2]]])
  assert_equal Redoku::Sudoku::Grid.index_of(4, 4), Redoku::Ink.cell_of(s)
end

assert('Ink.path_length sums every segment and ignores subpath gaps') do
  # 3-4-5 triangle twice, in two subpaths: 5 + 5, and NOT the jump between.
  s = ink_stroke([[[0, 0], [3, 4]], [[100, 100], [103, 104]]])
  assert_equal 10, Redoku::Ink.path_length(s)
end

assert('a single-point stroke has no length — the dot guard') do
  assert_equal 0, Redoku::Ink.path_length(ink_stroke([[[50, 50]]]))
end
```

- [ ] **Step 2: run them and confirm RED.**

Run: `make test`
Expected: KO on the `Ink` assertions with `uninitialized constant
Redoku::Ink`. Note the baseline totals from the run before this task
(2546 total / 2499 OK at `9802590`) in the ledger.

- [ ] **Step 3: implement `ink.rb`.**

```ruby
module Redoku
  # Geometry over one journaled ink stroke. Pure Ruby, no display and no
  # store: the same stroke hash M3a persists and replays
  # ({ color:, width:, subpaths: [[[x, y], ...], ...] }, panel coordinates,
  # plus an id: from schema v3 which nothing here reads).
  #
  # Three callers, all of which ask the same question in different words:
  # the eraser wants "which strokes are in the cell I just cleared", CHECK
  # wants "group the live ink by cell", and the dot guard wants "is this
  # ink at all, or a knuckle". Kept in one module so the answer cannot
  # drift between them — a stroke assigned to cell A by the recognizer and
  # cell B by the eraser would strand ink that no repaint could remove.
  module Ink
    # Ink below this much total path is an accidental contact, not a mark
    # (PLAN.md §6, "tiny dots (< 8 px path) are discarded"). Applied by
    # CHECK's grouping, never by the journal: an accidental dot is still
    # the player's ink and still erasable.
    MIN_PATH = 8

    def self.bbox(stroke)
      min_x = nil
      min_y = nil
      max_x = nil
      max_y = nil
      stroke[:subpaths].each do |sub|
        sub.each do |x, y|
          if min_x.nil?
            min_x = max_x = x
            min_y = max_y = y
            next
          end
          min_x = x if x < min_x
          max_x = x if x > max_x
          min_y = y if y < min_y
          max_y = y if y > max_y
        end
      end
      min_x.nil? ? nil : [min_x, min_y, max_x, max_y]
    end

    # The BOUNDING BOX centre, deliberately, and not the centroid of the
    # points. A 7's long diagonal or a 4's tail puts many more samples at
    # one end than the other, so a centroid drifts toward wherever the pen
    # dawdled; the box centre is where the glyph LOOKS like it sits, which
    # is the cell the player aimed at.
    def self.centre(stroke)
      b = bbox(stroke)
      return nil unless b
      [(b[0] + b[2]) / 2, (b[1] + b[3]) / 2]
    end

    def self.cell_of(stroke)
      c = centre(stroke)
      return nil unless c
      cell = Layout.cell_at(c[0], c[1])
      return nil unless cell
      Sudoku::Grid.index_of(cell[0], cell[1])
    end

    # Summed segment length WITHIN each subpath. The gap between subpaths is
    # where the pen left the board and came back, so bridging it would
    # invent travel the pen never made — the same reason replay must not
    # draw across it (M3a Task 6).
    def self.path_length(stroke)
      total = 0
      stroke[:subpaths].each do |sub|
        i = 1
        while i < sub.size
          dx = sub[i][0] - sub[i - 1][0]
          dy = sub[i][1] - sub[i - 1][1]
          total += Math.sqrt(dx * dx + dy * dy).to_i
          i += 1
        end
      end
      total
    end
  end
end
```

- [ ] **Step 4: run and confirm GREEN.** `make test` — every `Ink` assertion
      passes, no previously-passing assertion changed.
- [ ] **Step 5: commit.**

```bash
git add mrbgems/mruby-redoku/mrblib/redoku/ink.rb mrbgems/mruby-redoku/test/ink.rb
git commit -m "feat(m3b): Redoku::Ink — bbox, centre, cell_of, path_length

One module answers 'which cell is this stroke in' for all three callers
that ask it (erase, retire, CHECK's grouping), so the answer cannot drift
between them. Resolves PLAN.md §6's self-contradiction in favour of the
bounding-box centre: the 'fully inside a cell' guard would silently
discard a digit written over a cell line."
```

---

## Task 2 — Schema v3: stroke identity and retirement

**Files:** modify `mrbgems/mruby-redoku/mrblib/redoku/store.rb` (`VERSION`,
`SCHEMA_SQL`, `open_database`, `journal_stroke`, `strokes`; add
`retire_strokes`, `delete_strokes`), modify
`mrbgems/mruby-redoku/test/store.rb`.

**Interfaces produced** (Task 3 consumes `delete_strokes`; Task 7 consumes
`retire_strokes`; both consume the `id:` key):

```
Store#journal_stroke(game_id, color, width, subpaths) -> Integer row id, or false on failure
Store#strokes(game_id)        -> [{ id:, color:, width:, subpaths: }, ...]  retired rows excluded
Store#retire_strokes(ids)     -> Integer count marked, 0 on failure or empty
Store#delete_strokes(ids)     -> Integer count deleted, 0 on failure or empty
```

**`journal_stroke`'s return type changes, and that breaks four existing
assertions.** It returns `true` today. `mrbtest`'s `assert_true(obj)` requires
`obj == true` *strictly* (`tmp/mruby/test/assert.rb:159`), so an Integer id
fails it — while `assert_false(obj)` is `assert_true(!obj)`, which passes for
`false` and `nil` alike. Hence the contract chosen: **Integer id on success,
`false` (unchanged) on failure.** That keeps all six `assert_false` calls
passing untouched and leaves exactly four assertions to update, in
`test/store.rb` at lines **386, 394, 460 and 545**:

```ruby
  # was: assert_true(store.journal_stroke(id, 0, 4, stroke_subpaths))
  assert_true(store.journal_stroke(id, 0, 4, stroke_subpaths).is_a?(Integer))
```

Do this as part of Step 1, and say so in the ledger. An existing green
assertion that changes shape is exactly the thing a reviewer must be told
about rather than discover.

Why two operations and not one, from spec §4: **erase deletes** (the player
erased it; it is gone, and the journal stays inside `STROKES_CAP` instead of
growing a tail of tombstones) while **CHECK retires** (the strokes stay in
the record, they just stop being replayed, because the cell now prints a
digit). Conflating them would either resurrect erased ink or destroy the
player's hand.

- [ ] **Step 1: write the failing tests** in `test/store.rb`.

```ruby
assert('journal_stroke returns the row id it wrote') do
  path = store_db('journal_id')
  remove_store_db(path)
  store = Redoku::Store.open(path, log: nil)
  id = store.save_autosave(store_game)
  a = store.journal_stroke(id, 96, 3, [[[10, 10], [20, 20]]])
  b = store.journal_stroke(id, 96, 3, [[[30, 30], [40, 40]]])
  assert_true a.is_a?(Integer)
  assert_true b > a
  got = store.strokes(id)
  assert_equal [a, b], [got[0][:id], got[1][:id]]
  store.close
  remove_store_db(path)
end

assert('a retired stroke is kept but no longer read back') do
  path = store_db('retire')
  remove_store_db(path)
  store = Redoku::Store.open(path, log: nil)
  id = store.save_autosave(store_game)
  a = store.journal_stroke(id, 96, 3, [[[10, 10], [20, 20]]])
  b = store.journal_stroke(id, 96, 3, [[[30, 30], [40, 40]]])

  assert_equal 1, store.retire_strokes([a])
  got = store.strokes(id)
  assert_equal 1, got.size
  assert_equal b, got[0][:id]

  # Kept, not deleted — this is the whole difference from erase.
  rows = store.instance_variable_get(:@db)
              .execute('SELECT COUNT(*) FROM strokes WHERE game_id = ?', [id])
  assert_equal 2, rows[0][0]
  store.close
  remove_store_db(path)
end

assert('a deleted stroke is gone from the table') do
  path = store_db('delete_strokes')
  remove_store_db(path)
  store = Redoku::Store.open(path, log: nil)
  id = store.save_autosave(store_game)
  a = store.journal_stroke(id, 96, 3, [[[10, 10], [20, 20]]])
  store.journal_stroke(id, 96, 3, [[[30, 30], [40, 40]]])
  assert_equal 1, store.delete_strokes([a])
  rows = store.instance_variable_get(:@db)
              .execute('SELECT COUNT(*) FROM strokes WHERE game_id = ?', [id])
  assert_equal 1, rows[0][0]
  store.close
  remove_store_db(path)
end

assert('retire_strokes and delete_strokes tolerate an empty list') do
  path = store_db('empty_ids')
  remove_store_db(path)
  store = Redoku::Store.open(path, log: nil)
  assert_equal 0, store.retire_strokes([])
  assert_equal 0, store.delete_strokes([])
  assert_equal 0, store.retire_strokes(nil)
  store.close
  remove_store_db(path)
end

assert('a v2 file migrates to v3 with every stroke still live') do
  path = store_db('v2_to_v3')
  remove_store_db(path)

  # Build a genuine v2 file: the v2 DDL, v2's user_version, one stroke row
  # written the way v2 wrote them (no retired column at all).
  db = SQLite3::Database.open(path)
  db.exec(V2_SCHEMA_SQL) # pinned copy, see below
  db.exec('PRAGMA user_version = 2')
  now = 1_700_000_000
  db.execute('INSERT INTO games (kind, difficulty, achieved_tier, givens, ' \
             'entries, solution, created_at, updated_at) VALUES ' \
             "('autosave','easy','easy',?,?,?,?,?)",
             ['.' * 81, '.' * 81, '1' * 81, now, now])
  gid = db.last_insert_rowid
  db.execute('INSERT INTO strokes (game_id, seq, color, width, pts, ' \
             'created_at) VALUES (?,1,96,3,?,?)', [gid, '10,10 20,20', now])
  db.close

  store = Redoku::Store.open(path, log: nil)
  assert_equal 3, store.instance_variable_get(:@db)
                       .execute('PRAGMA user_version')[0][0]
  got = store.strokes(gid)
  assert_equal 1, got.size            # survived the migration
  assert_equal [[[10, 10], [20, 20]]], got[0][:subpaths]
  assert_true got[0][:id].is_a?(Integer)
  store.close
  remove_store_db(path)
end

assert('a v1 file migrates straight to v3') do
  path = store_db('v1_to_v3')
  remove_store_db(path)
  db = SQLite3::Database.open(path)
  db.exec(V1_SCHEMA_SQL) # games only, no strokes table
  db.exec('PRAGMA user_version = 1')
  db.close
  store = Redoku::Store.open(path, log: nil)
  assert_equal 3, store.instance_variable_get(:@db)
                       .execute('PRAGMA user_version')[0][0]
  # The strokes table was CREATEd fresh, so it already has `retired` and
  # needs no ALTER — the migration must not run one and must not raise.
  assert_equal [], store.strokes(1)
  store.close
  remove_store_db(path)
end

assert('a version ABOVE v3 is still quarantined') do
  path = store_db('v4')
  remove_store_db(path)
  db = SQLite3::Database.open(path)
  db.exec('PRAGMA user_version = 4')
  db.close
  store = Redoku::Store.open(path, log: nil)
  assert_true Dir.entries(File.dirname(path))
                 .any? { |f| f.include?('.bad-') }
  store.close
  remove_store_db(path)
end
```

`V1_SCHEMA_SQL` and `V2_SCHEMA_SQL` are pinned literal copies of the old DDL,
added to `test/store.rb` next to the tests. Pin them rather than deriving them
from `Store::SCHEMA_SQL`: a migration test that builds its "old" file from the
*current* schema tests nothing at all.

- [ ] **Step 2: run them and confirm RED.** `make test` — `NoMethodError` on
      `retire_strokes` / `delete_strokes`, and the v2 test fails on
      `user_version` still reading 2.

- [ ] **Step 3: bump the schema and add the two operations.**

```ruby
    VERSION = 3
```

In `SCHEMA_SQL`, the `strokes` DDL gains one column, so a **fresh** file and a
v1 file both get it without any ALTER:

```sql
      CREATE TABLE IF NOT EXISTS strokes (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        game_id    INTEGER NOT NULL REFERENCES games(id) ON DELETE CASCADE,
        seq        INTEGER NOT NULL,
        color      INTEGER NOT NULL,
        width      INTEGER NOT NULL,
        pts        TEXT    NOT NULL,
        retired    INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      );
```

`open_database` gains the one migration a v2 file needs. Note `version` is
hoisted out of the `if existed` block, because the ALTER decision is made
after `SCHEMA_SQL` has run:

```ruby
    def open_database
      existed = File.exist?(@path)
      version = 0
      @db = SQLite3::Database.open(@path)
      if existed
        begin
          version = read_version
          if version > VERSION
            quarantine('unexpected schema version ' + version.to_s)
            @db = SQLite3::Database.open(@path)
            version = 0
          end
        rescue StandardError => e
          quarantine(e.message)
          @db = SQLite3::Database.open(@path)
          version = 0
        end
      end
      @db.exec(SCHEMA_SQL)
      # v2 is the ONLY version that owns a strokes table without `retired`:
      # a v1 file has no strokes table, so CREATE TABLE IF NOT EXISTS above
      # just built it with the column, and a fresh file likewise. Running
      # the ALTER on those would raise "duplicate column name".
      @db.exec('ALTER TABLE strokes ADD COLUMN retired INTEGER NOT NULL ' \
               'DEFAULT 0') if version == 2
      @db.exec('PRAGMA user_version = ' + VERSION.to_s)
    end
```

`journal_stroke` returns the id (the binding exposes
`Database#last_insert_rowid` — `mrb_sqlite3.c:489`), `strokes` selects the id
and skips retired rows, and the two new operations take id lists:

```ruby
    # journal_stroke's tail: was `true`, now the row id. The failure paths
    # above keep returning `false` — see the interface note on why that
    # distinction matters to the existing assertions. enforce_stroke_cap
    # runs first and deletes the OLDEST rows, never the one just inserted,
    # so the id is still valid after it.
      enforce_stroke_cap(game_id)
      @db.last_insert_rowid

    def strokes(game_id)
      return [] unless game_id
      rows = @db.execute(
        'SELECT id, color, width, pts FROM strokes ' \
        'WHERE game_id = ? AND retired = 0 ORDER BY seq ASC, id ASC',
        [game_id])
      out = []
      rows.each do |id, color, width, pts|
        subpaths = self.class.decode_pts(pts)
        if subpaths.nil? || !int?(color) || color < 0 || color > 255 ||
           !int?(width) || width < 1
          log_line('skipped corrupt stroke row for game ' + game_id.to_s)
          next
        end
        out << { id: id, color: color, width: width, subpaths: subpaths }
      end
      out
    rescue StandardError => e
      log_line('could not read strokes (' + e.message + ')')
      []
    end

    # CHECK consumed this ink: the cell prints a digit now, so the strokes
    # stop being replayed — but they stay in the record, because they are
    # the player's own hand and the only copy of it.
    def retire_strokes(ids)
      update_strokes_by_id(ids,
                           'UPDATE strokes SET retired = 1 WHERE id IN ')
    end

    # The player erased this ink. It is gone: no tombstone, which also keeps
    # the journal inside STROKES_CAP instead of growing a permanent tail.
    def delete_strokes(ids)
      update_strokes_by_id(ids, 'DELETE FROM strokes WHERE id IN ')
    end

    private

    # One statement over a bounded id list. The list is built from
    # App@ink_strokes, so it is at most STROKES_CAP long and every element
    # is an Integer this Store itself handed out — but it is filtered here
    # anyway, because a nil id (a stroke buffered before the first dig) must
    # not become the string 'nil' inside SQL.
    def update_strokes_by_id(ids, sql)
      return 0 unless ids.is_a?(Array)
      live = ids.select { |i| int?(i) }
      return 0 if live.empty?
      marks = (['?'] * live.size).join(',')
      @db.execute(sql + '(' + marks + ')', live)
      @db.changes
    rescue StandardError => e
      log_line('could not update strokes (' + e.message + ')')
      0
    end
```

- [ ] **Step 4: run and confirm GREEN.** `make test`. Pay attention to the
      pre-existing `copy_strokes` test — `SAVE` copies a game's strokes onto
      the manual copy, and its `INSERT ... SELECT` names columns explicitly,
      so it is unaffected by the new column. **Confirm that by reading it, not
      by assuming it.**
- [ ] **Step 5: commit.**

```bash
git add mrbgems/mruby-redoku/mrblib/redoku/store.rb mrbgems/mruby-redoku/test/store.rb
git commit -m "feat(m3b): schema v3 — stroke identity and retirement

journal_stroke returns its row id and strokes() hands it back, so a caller
holding App@ink_strokes can name exactly the rows it means without a cell
column, an index or a back-fill migration.

Two operations, deliberately not one: erase DELETEs (the player erased it,
and a tombstone would eat STROKES_CAP) while CHECK RETIREs (the ink stops
being replayed but stays in the record, being the only copy of the
player's hand). v2 is the only version needing the ALTER — v1 has no
strokes table, so CREATE TABLE IF NOT EXISTS builds it with the column."
```

---

## Task 3 — The erase fix

**Files:** modify `mrbgems/mruby-redoku/mrblib/redoku/app.rb`
(`close_ink_capture`, `erase_at`), modify
`mrbgems/mruby-redoku/test/app.rb`.

This closes the defect proven in spec §1. **The two probe assertions below
were run at `9802590` and both failed** — they are the regression tests, and
their first job in this task is to fail again before anything is changed.

- [ ] **Step 1: add the two probes as permanent tests** in `test/app.rb`,
      in the stroke-persistence section (near `stroke_app_db`).

```ruby
# --- erase persistence (M3b Task 3). The M3a plan claimed the eraser needed
# no journal entry because it "repaints cells from the model, so a reload
# restores erased cells correctly by simply not having those strokes"
# (docs/plans/2026-08-25-m3-sqlite-saves.md, Task 6). The stroke was already
# journaled at pen-lift, before the eraser came, so it did have one. These
# two assertions are the proof and the guard.

assert('erasing a cell removes its stroke from the journal') do
  path = stroke_app_db('erase_journal')
  remove_app_db(path)
  store = Redoku::Store.open(path, log: nil)
  app, d, = new_app(store: store)
  app.new_puzzle
  sid = app.current_save_id
  assert_false sid.nil?

  draw_ink_stroke(app, d)              # cell (1,1), screen (300,400)..(340,440)
  assert_equal 1, store.strokes(sid).size

  app.handle_sample(eraser_sample(300, 400, true))
  app.handle_sample(eraser_sample(300, 400, false))

  assert_equal 0, store.strokes(sid).size
  assert_equal 0, app.ink_strokes.size
  store.close
  remove_app_db(path)
end

assert('an erased stroke is not replayed after a relaunch') do
  path = stroke_app_db('erase_reload')
  remove_app_db(path)

  store1 = Redoku::Store.open(path, log: nil)
  app1, d1, _in1, signals1 = new_app(store: store1)
  app1.new_puzzle
  draw_ink_stroke(app1, d1)
  app1.handle_sample(eraser_sample(300, 400, true))
  app1.handle_sample(eraser_sample(300, 400, false))
  signals1.terminated = true
  app1.run
  assert_true store1.closed?

  store2 = Redoku::Store.open(path, log: nil)
  app2, _d2, _in2, signals2 = new_app(store: store2)
  signals2.terminated = true
  app2.run                             # resume-on-launch happens inside run
  assert_equal 0, app2.ink_strokes.size
  remove_app_db(path)
end

assert('erasing one cell leaves a neighbour cell ink alone') do
  # The fix must be cell-scoped, not "clear the journal". Two strokes in
  # two cells, erase one, the other survives in memory AND on disk.
  path = stroke_app_db('erase_neighbour')
  remove_app_db(path)
  store = Redoku::Store.open(path, log: nil)
  app, = new_app(store: store)
  app.new_puzzle
  sid = app.current_save_id

  app.handle_sample(pen_sample(300, 400, true))   # cell (1,1)
  app.handle_sample(pen_sample(320, 420, true))
  app.handle_sample(pen_sample(320, 420, false))
  app.handle_sample(pen_sample(300, 540, true))   # cell (1,2), one row down
  app.handle_sample(pen_sample(320, 560, true))
  app.handle_sample(pen_sample(320, 560, false))
  assert_equal 2, store.strokes(sid).size

  app.handle_sample(eraser_sample(300, 400, true))
  app.handle_sample(eraser_sample(300, 400, false))

  assert_equal 1, store.strokes(sid).size
  assert_equal 1, app.ink_strokes.size
  survivor = Redoku::Sudoku::Grid.index_of(1, 2)
  assert_equal survivor, Redoku::Ink.cell_of(app.ink_strokes[0])
  store.close
  remove_app_db(path)
end
```

- [ ] **Step 2: run and confirm RED, with the exact numbers.** `make test`.
      Expected: the first two fail with `Expected: 0  Actual: 1` and the third
      with `Expected: 1  Actual: 2`. **Record these in the ledger** — this is
      the milestone's one pre-existing defect and the evidence matters.

- [ ] **Step 3: carry the row id on each in-memory stroke.** In
      `close_ink_capture`, the id the store hands back is stored on the stroke
      so the eraser can name the row later:

```ruby
      stroke = { color: INK_GRAY, width: INK_WIDTH, subpaths: subs }
      @ink_strokes << stroke
      return unless @store && @current_save_id
      begin
        # The id is what lets erase (Task 3) and CHECK (Task 7) delete or
        # retire exactly these rows without a cell column or a table scan.
        # nil is fine and expected: a stroke drawn before the first dig has
        # no game row to hang off, and M3a discards those when the dig lands.
        stroke[:id] = @store.journal_stroke(@current_save_id, stroke[:color],
                                            stroke[:width], stroke[:subpaths])
      rescue StandardError => e
        log_line('stroke journal failed (' + e.message + ')')
      end
```

- [ ] **Step 4: make `erase_at` clear the record as well as the glass.**

```ruby
    def erase_at(x, y)
      return unless @mode == :erase
      cell = Layout.cell_at(x, y)
      return unless cell
      index = Sudoku::Grid.index_of(cell[0], cell[1])
      return if index == @erased
      @erased = index
      forget_ink_in(index)
      @renderer.redraw_cell(index, @grid)
      cx, cy, cw, ch = Layout.cell_rect(cell[0], cell[1])
      mark_dirty(cx, cy, cx + cw - 1, cy + ch - 1)
    end

    # An erase has to reach the RECORD, not only the glass. redraw_cell
    # repaints this cell from the model, which is what makes the ink
    # disappear now; without this the same strokes are still in
    # @ink_strokes and still in the strokes table, so the next repaint —
    # a resume, a GAMES load, or the next relaunch — puts them straight
    # back. That is the defect this method carried until M3b (spec §1):
    # the stroke was journaled at PEN LIFT, before the eraser existed as
    # far as this cell was concerned.
    #
    # DELETE and not retire: the player erased it. Retiring would leave a
    # tombstone row eating this game's STROKES_CAP for ink nobody can ever
    # see again.
    def forget_ink_in(index)
      doomed = []
      kept = []
      @ink_strokes.each do |s|
        if Ink.cell_of(s) == index
          doomed << s[:id] if s[:id]
        else
          kept << s
        end
      end
      return if doomed.empty? && kept.size == @ink_strokes.size
      @ink_strokes = kept
      return if doomed.empty? || @store.nil?
      begin
        @store.delete_strokes(doomed)
      rescue StandardError => e
        log_line('stroke delete failed (' + e.message + ')')
      end
    end
```

- [ ] **Step 5: run and confirm GREEN.** `make test`. Every pre-existing
      erase assertion (`test/app.rb` around lines 470–630) must still pass
      untouched — the eraser's *drawing* behaviour is unchanged and those
      tests are the only coverage it can ever have (PLAN.md §9).
- [ ] **Step 6: commit.**

```bash
git add mrbgems/mruby-redoku/mrblib/redoku/app.rb mrbgems/mruby-redoku/test/app.rb
git commit -m "fix(m3b): an erase now survives a reload

Ink a cell, erase it, quit, relaunch: the stroke came back, in
@ink_strokes and in the strokes table. erase_at repainted the glass from
the model and touched neither. The M3a plan's reasoning — 'the eraser is
not journaled ... so a reload restores erased cells correctly by simply
not having those strokes' — missed that the stroke was journaled at pen
lift, before the eraser arrived.

This is load-bearing for M3b rather than cosmetic: the gameplay model is
'erase your notes, then press CHECK', so a player who erased, quit and
came back would have had those notes read as answers."
```

---

## Task 4 — `Grid`'s unreadable cell state

**Files:** modify `mrbgems/mruby-redoku/mrblib/redoku/sudoku/grid.rb`, modify
`mrbgems/mruby-redoku/mrblib/redoku/store.rb` (validator split), modify
`mrbgems/mruby-redoku/mrblib/redoku/app.rb` (`adopt_record`), modify
`mrbgems/mruby-redoku/test/sudoku_grid.rb` and `test/store.rb`.

**Interfaces produced** (Task 7 consumes all of these):

```
Grid::UNREADABLE            = -1        the sentinel stored in @entries
Grid#set_unreadable(i)      -> self     raises on a given, like set_entry
Grid#unreadable?(i)         -> true/false
Grid#entries_s              -> String   an unreadable cell renders as '?'
Store.entries_board?(s)     -> true/false   the looser validator, entries only
```

**Constraint 5 is the whole point of this task.** Nothing under
`mrblib/redoku/sudoku/` takes a `Grid` instance — `Solver.solve/count/unique?/
cost`, `Rater.measure/rate/score/demand_of` and `Techniques.solves?` all take
raw `values` arrays. So the fourth state is contained by one filter in
`value_at`, and the engine never learns it exists. Do not let it leak.

- [ ] **Step 1: write the failing tests** in `test/sudoku_grid.rb`.

```ruby
assert('an unreadable cell reads as empty to the engine') do
  g = Redoku::Sudoku::Grid.parse('.' * 81)
  g.set_unreadable(0)
  assert_true g.unreadable?(0)
  assert_equal 0, g.value_at(0)      # not -1: the sentinel never escapes
  assert_true g.empty?(0)
  assert_equal 0, g.values[0]
  assert_equal '.', g.values_s[0]    # the engine's view is unchanged
end

assert('an unreadable cell persists as ? and nothing else does') do
  g = Redoku::Sudoku::Grid.parse('.' * 81)
  g.set_unreadable(3)
  g.set_entry(4, 7)
  assert_equal '?', g.entries_s[3]
  assert_equal '7', g.entries_s[4]
  assert_equal '.', g.entries_s[5]
  # givens_s and values_s can never carry the sentinel, because value_at
  # filters it and @givens never holds it.
  assert_false g.givens_s.include?('?')
  assert_false g.values_s.include?('?')
end

assert('an unreadable cell cannot produce a false win') do
  # THE property this state exists to protect, and the reason the sentinel
  # filter in value_at must not be "simplified" away. Fill a solved board,
  # then make one cell unreadable: complete? already returns false because
  # value_at reads 0 there, so solved? is false with no extra guard.
  solved = solved_values                        # test/_support.rb
  g = Redoku::Sudoku::Grid.new(Array.new(81, 0), solved.dup)
  assert_true g.solved?
  g.set_unreadable(40)
  assert_false g.solved?
end

assert('writing a digit over an unreadable cell clears the sentinel') do
  g = Redoku::Sudoku::Grid.parse('.' * 81)
  g.set_unreadable(9)
  g.set_entry(9, 5)
  assert_false g.unreadable?(9)
  assert_equal 5, g.value_at(9)
end

assert('clear_entry clears an unreadable cell too') do
  g = Redoku::Sudoku::Grid.parse('.' * 81)
  g.set_unreadable(9)
  g.clear_entry(9)
  assert_false g.unreadable?(9)
  assert_equal '.', g.entries_s[9]
end

assert('set_unreadable refuses a given, exactly as set_entry does') do
  g = Redoku::Sudoku::Grid.parse('5' + '.' * 80)
  begin
    g.set_unreadable(0)
    assert_true false, 'expected a raise'
  rescue RuntimeError => e
    assert_true e.message.include?('given')
  end
end

assert('a Grid round-trips an unreadable cell through its strings') do
  g = Redoku::Sudoku::Grid.parse('.' * 81)
  g.set_unreadable(11)
  back = Redoku::Sudoku::Grid.new(Array.new(81, 0),
                                  values_of_entries(g.entries_s))
  assert_true back.unreadable?(11)
end
```

`values_of_entries(s)` is a new `test/_support.rb` helper — the inverse of
`entries_s`, mapping `'?'` back to the sentinel:

```ruby
# The inverse of Grid#entries_s: '.' is empty, '?' is unreadable (M3b), and
# anything else is a digit. Distinct from values_of, which has no '?' case
# because givens and solutions can never hold one.
def values_of_entries(str)
  out = []
  str.each_char do |ch|
    out << if ch == '.' || ch == '0'
             0
           elsif ch == '?'
             Redoku::Sudoku::Grid::UNREADABLE
           else
             ch.to_i
           end
  end
  out
end
```

And in `test/store.rb`:

```ruby
assert('a game record may carry ? in entries but not in givens or solution') do
  path = store_db('entries_q')
  remove_store_db(path)
  store = Redoku::Store.open(path, log: nil)
  ok = store_game
  ok[:entries] = '?' + '.' * 80
  assert_false store.save_autosave(ok).nil?
  assert_equal '?', store.autosave[:entries][0]

  bad = store_game
  bad[:givens] = '?' + bad[:givens][1, 80]
  assert_nil store.save_autosave(bad)
  store.close
  remove_store_db(path)
end
```

- [ ] **Step 2: run and confirm RED.** `make test` — `NoMethodError` on
      `set_unreadable`, and the store test failing because `board?` rejects
      `'?'` in `entries`.

- [ ] **Step 3: add the state to `Grid`.**

```ruby
      # A non-given cell holds one of three things in @entries: 0 (empty),
      # 1..9 (the player's answer), or UNREADABLE.
      #
      # UNREADABLE means CHECK looked at this cell's ink and could not read
      # a digit from it with enough confidence (spec §5 — the thresholds err
      # this way deliberately, because a guess that happens to match the
      # solution is a silent false win). The cell keeps its ink and shows a
      # '?'.
      #
      # It is a NEGATIVE sentinel and not a tenth digit so that value_at can
      # filter it with one comparison, which is what keeps the whole engine
      # blind to it: Solver, Rater and Techniques take `values` arrays, never
      # a Grid, so as long as `values` reports 0 here they see exactly the
      # board they have always seen. Two properties depend on that filter and
      # neither is separately coded — an unreadable cell counts as unsolved
      # (so it cannot produce a false win), and the generator's dig and the
      # rater's re-solves are unaffected. Do not "simplify" value_at.
      UNREADABLE = -1

      def value_at(i)
        return @givens[i] if @givens[i] != 0
        @entries[i] > 0 ? @entries[i] : 0
      end

      def set_unreadable(i)
        raise "cell #{i} is a given" if given?(i)
        @entries[i] = UNREADABLE
        self
      end

      def unreadable?(i)
        @entries[i] == UNREADABLE
      end
```

and `str_of` learns the one character:

```ruby
      def str_of(list)
        s = ''
        list.each do |d|
          s = s + if d == 0
                    '.'
                  elsif d == UNREADABLE
                    '?'
                  else
                    d.to_s
                  end
        end
        s
      end
```

`clear_entry` already sets `@entries[i] = 0`, so it clears the sentinel with
no change. `set_entry` already overwrites, likewise.

- [ ] **Step 4: split the `Store` validator.** `board?` is applied to
      `givens`, `entries` *and* `solution`; only `entries` may hold `'?'`.

```ruby
    BOARD_CHARS = '0123456789.'
    # entries is the only column that may carry M3b's unreadable marker: a
    # given and a solution are always digits or holes.
    ENTRY_CHARS = '0123456789.?'
```

```ruby
    def board?(s)
      chars?(s, BOARD_CHARS)
    end

    def entries_board?(s)
      chars?(s, ENTRY_CHARS)
    end

    def chars?(s, allowed)
      return false unless s.is_a?(String) && s.size == 81
      s.each_char { |ch| return false unless allowed.include?(ch) }
      true
    end
```

Then in `normalize` and `validate_row`, the `entries` field uses
`entries_board?` while `givens` and `solution` keep `board?`.

- [ ] **Step 5: teach `adopt_record` the character.** In `app.rb`'s
      `adopt_record` loop over `rec[:entries]`:

```ruby
        ch = rec[:entries][i]
        if ch == '?'
          grid.set_unreadable(i) unless grid.given?(i)
        elsif ch >= '1' && ch <= '9'
          grid.set_entry(i, ch.to_i) unless grid.given?(i)
        end
```

- [ ] **Step 6: run and confirm GREEN.** `make test`. Watch the generator and
      rater suites especially: if any of them changed behaviour, the sentinel
      has leaked out of `value_at` and constraint 5 is broken.
- [ ] **Step 7: commit.**

```bash
git add mrbgems/mruby-redoku/mrblib/redoku/sudoku/grid.rb \
        mrbgems/mruby-redoku/mrblib/redoku/store.rb \
        mrbgems/mruby-redoku/mrblib/redoku/app.rb \
        mrbgems/mruby-redoku/test/sudoku_grid.rb \
        mrbgems/mruby-redoku/test/store.rb \
        mrbgems/mruby-redoku/test/_support.rb
git commit -m "feat(m3b): Grid learns an unreadable cell, and only Grid does

CHECK needs to say 'I looked and could not read this', persistently, and
distinguishably from a wrong digit. A negative sentinel in @entries filtered
by one comparison in value_at does it: nothing under sudoku/ takes a Grid
instance (Solver, Rater and Techniques all take raw values arrays), so the
engine cannot see the state at all.

Two properties fall out of that filter rather than being coded, which is why
its comment says not to simplify it: an unreadable cell counts as unsolved,
so it cannot produce a false win, and the dig and the rater's re-solves are
untouched."
```

---

## Task 5 — `Recognizer`: the seam, stage 1, and the measured gate

**Files:** create `mrbgems/mruby-redoku/mrblib/redoku/recognizer.rb`, create
`mrbgems/mruby-redoku/mrblib/redoku/templates.rb`, create
`mrbgems/mruby-redoku/test/recognizer.rb`.

**Interfaces produced** (Task 7 consumes the first; Task 10 the rest):

```
Recognizer.read(strokes)        -> [digit_or_nil, Integer confidence 0..1000]
Recognizer.features(strokes)    -> [Integer, ...] fixed-length vector
Recognizer.resample(strokes, n) -> [[x, y], ...] exactly n points, normalised
Templates::AUTHORED             -> [[digit, subpaths], ...]
```

**Why not $P as PLAN.md §6 specifies.** Costed in spec §5: $P's greedy match
runs `n^(1-ε)` starts (ε = 0.5), each a full O(n²) pass. At n = 48 against 45
templates that is ≈ 725k point-distance evaluations *per cell*, ≈ 36M per
board. That is seconds to minutes of interpreted mruby on a Cortex-A7, not
the cheap one-shot §6 assumed it bought. Stage 1 below is ≈ 1.1k operations
per cell instead.

> **DECISION GATE.** This task ends by measuring accuracy and cost and
> writing both into the ledger *and* into spec §5. If stage 1 alone clears
> the bar, **Task 6 is skipped and deleted from the plan.** If it does not,
> Task 6 runs. Do not guess — measure and record.
>
> Bar: **≥ 95 % of readable cells classified correctly, and zero false
> passes** on the authored corpus. A false pass is the failure spec §5 tunes
> against, so it is a hard zero, not a percentage.

- [ ] **Step 1: write the authored templates** in `templates.rb`. Real
      coordinates, not a placeholder — these are polylines in a 100×100
      authoring box, origin top-left, which the loader resamples so only the
      shape matters.

```ruby
module Redoku
  # Bootstrap digit templates, authored by hand rather than recorded, so the
  # recognizer is testable on the host from the first commit (spec §5: the
  # chicken-and-egg is that --record needs a recognizer and a recognizer
  # needs templates). Task 11 replaces these with the owner's own recorded
  # clouds, which become both the shipped set and the corpus.
  #
  # Each entry is [digit, subpaths] in a 100x100 box, origin top-left. Two
  # or three variants per digit cover the ways a hand actually draws it —
  # a 7 with and without a crossbar, a 4 open and closed, a 1 with and
  # without a serif — because stroke COUNT and order vary between them and
  # that is precisely what the classifier must not key on.
  module Templates
    AUTHORED = [
      [1, [[[50, 8], [50, 92]]]],
      [1, [[[34, 24], [50, 8], [50, 92]]]],
      [1, [[[34, 24], [50, 8], [50, 92]], [[30, 92], [70, 92]]]],

      [2, [[[18, 26], [34, 10], [62, 10], [76, 26], [70, 46],
            [20, 90], [80, 90]]]],
      [2, [[[20, 28], [50, 8], [78, 28], [66, 52], [18, 92], [82, 92]]]],

      [3, [[[20, 12], [70, 12], [44, 46], [74, 60], [64, 90], [22, 88]]]],
      [3, [[[22, 14], [66, 10], [46, 46], [76, 62], [60, 92], [20, 86]]]],

      [4, [[[64, 8], [18, 62], [86, 62]], [[64, 8], [64, 92]]]],
      [4, [[[62, 10], [20, 64], [84, 64]], [[62, 34], [62, 92]]]],
      [4, [[[26, 8], [26, 52], [80, 52], [66, 8], [66, 92]]]],

      [5, [[[80, 10], [26, 10], [24, 44], [58, 42], [78, 62],
            [62, 90], [22, 86]]]],
      [5, [[[78, 12], [28, 12], [26, 46], [60, 44], [76, 66], [58, 92],
            [20, 84]]]],

      [6, [[[70, 10], [34, 40], [26, 70], [46, 90], [72, 78],
            [66, 54], [34, 52]]]],
      [6, [[[72, 12], [36, 44], [28, 72], [50, 92], [74, 76], [64, 52],
            [32, 54]]]],

      [7, [[[16, 12], [84, 12], [40, 92]]]],
      [7, [[[16, 12], [84, 12], [40, 92]], [[28, 52], [64, 52]]]],
      [7, [[[18, 10], [82, 14], [44, 90]]]],

      [8, [[[54, 10], [30, 26], [54, 44], [76, 62], [54, 90],
            [28, 68], [54, 44], [72, 26], [54, 10]]]],
      [8, [[[52, 12], [28, 28], [52, 46], [74, 64], [50, 90], [26, 66],
            [52, 46], [70, 28], [52, 12]]]],

      [9, [[[70, 40], [40, 48], [30, 26], [54, 10], [70, 28],
            [70, 40], [58, 90]]]],
      [9, [[[72, 42], [42, 50], [32, 26], [56, 10], [72, 30], [70, 44],
            [54, 92]]]]
    ].freeze
  end
end
```

- [ ] **Step 2: write the failing tests** in `test/recognizer.rb`.

```ruby
# The recognizer's own corpus for now is the authored template set plus
# hand-made distortions of it. That is a weak corpus and is meant to be:
# Task 11 replaces it with recorded human clouds. What it CAN prove today is
# that the pipeline is sane — a template classifies as itself, a distorted
# template still classifies as itself, and noise is refused rather than
# guessed at.

def cell_strokes(subpaths, cell = 10, box = 100)
  # Map a 100x100 authoring box onto a real cell, so the recognizer is
  # exercised on the panel coordinates it will actually see.
  x, y, w, h = Redoku::Layout.cell_rect(Redoku::Sudoku::Grid.col_of(cell),
                                        Redoku::Sudoku::Grid.row_of(cell))
  mapped = subpaths.map do |sub|
    sub.map { |px, py| [x + px * w / box, y + py * h / box] }
  end
  [{ color: Redoku::App::INK_GRAY, width: Redoku::App::INK_WIDTH,
     subpaths: mapped }]
end

def jitter(subpaths, dx, dy, scale_num, scale_den)
  subpaths.map do |sub|
    sub.map do |px, py|
      [(px * scale_num / scale_den) + dx, (py * scale_num / scale_den) + dy]
    end
  end
end

assert('resample returns exactly n points however many subpaths there were') do
  s = cell_strokes([[[10, 10], [90, 10]], [[10, 90], [90, 90]]])
  pts = Redoku::Recognizer.resample(s, 32)
  assert_equal 32, pts.size
  pts.each { |p| assert_equal 2, p.size }
end

assert('features is a fixed-length integer vector') do
  a = Redoku::Recognizer.features(cell_strokes([[[10, 10], [90, 90]]]))
  b = Redoku::Recognizer.features(cell_strokes([[[50, 8], [50, 92]]]))
  assert_equal a.size, b.size
  a.each { |v| assert_true v.is_a?(Integer) }
  assert_false a == b   # different shapes must not collide
end

assert('every authored template classifies as its own digit') do
  Redoku::Templates::AUTHORED.each_with_index do |(digit, subpaths), i|
    got, conf = Redoku::Recognizer.read(cell_strokes(subpaths))
    assert_equal digit, got, "template #{i} (a #{digit}) read as #{got.inspect}"
    assert_true conf > 0
  end
end

assert('a shifted and scaled template still classifies as its digit') do
  # Translation and uniform scale invariance: the player does not write in
  # the middle of the cell at a fixed size.
  Redoku::Templates::AUTHORED.each_with_index do |(digit, subpaths), i|
    moved = jitter(subpaths, 6, -4, 9, 10)
    got, = Redoku::Recognizer.read(cell_strokes(moved))
    assert_equal digit, got, "template #{i} (a #{digit}) moved read as #{got.inspect}"
  end
end

assert('1 and 7 are not confused, which is what aspect ratio is for') do
  one   = [[[50, 8], [50, 92]]]
  seven = [[[16, 12], [84, 12], [40, 92]]]
  assert_equal 1, Redoku::Recognizer.read(cell_strokes(one))[0]
  assert_equal 7, Redoku::Recognizer.read(cell_strokes(seven))[0]
end

assert('scribble is refused rather than guessed at') do
  # Spec §5: the thresholds err toward nil, because a guess that happens to
  # match the solution is a silent false win.
  scribble = [[[10, 10], [90, 90], [10, 90], [90, 10], [10, 50], [90, 50],
               [50, 10], [50, 90], [20, 20], [80, 80]]]
  got, = Redoku::Recognizer.read(cell_strokes(scribble))
  assert_nil got
end

assert('ink below the dot guard is refused') do
  tiny = [{ color: Redoku::App::INK_GRAY, width: Redoku::App::INK_WIDTH,
            subpaths: [[[300, 400], [302, 401]]] }]
  assert_nil Redoku::Recognizer.read(tiny)[0]
end

assert('no strokes at all reads as nil, not as a crash') do
  assert_nil Redoku::Recognizer.read([])[0]
  assert_nil Redoku::Recognizer.read(nil)[0]
end
```

- [ ] **Step 3: run and confirm RED.** `make test` — `uninitialized constant
      Redoku::Recognizer`.

- [ ] **Step 4: implement stage 1.**

```ruby
module Redoku
  # Reads a digit out of the ink sitting in one cell. Runs in a batch when
  # the player presses CHECK — never during play (PLAN.md §6, model change
  # 2026-08-25), so this is invoked ~50 times per press rather than
  # hundreds of times per game, and it may spend a millisecond where a live
  # recognizer could not.
  #
  # NOT $P, which PLAN.md §6 specifies. $P greedy-matches with n^(1-e)
  # starts over an O(n^2) pass: at n=48 against 45 templates that is ~725k
  # point-distance evaluations per cell and ~36M per board, which is
  # seconds to minutes of interpreted mruby on a Cortex-A7 (spec §5 shows
  # the arithmetic). Stage 1 here is a feature vector compared by squared
  # distance: ~1.1k operations per cell.
  #
  # The mruby lesson from ENGINE-IMPROVEMENTS.md applies throughout: the VM
  # has inlined opcodes for arithmetic and []/[]=, but routes every bitwise
  # operator through a method send. So this file counts and indexes; it
  # never packs bits.
  module Recognizer
    POINTS  = 32          # resampled points per cell, fixed
    GRID_N  = 4           # 4x4 ink-density boxes
    DENSITY = GRID_N * GRID_N
    SHAPE   = 4           # aspect, subpaths, reversals, spread
    SIZE    = DENSITY + SHAPE

    # Tuned in Task 11 against recorded human clouds. These bootstrap
    # values are set from the authored set only and are deliberately
    # STRICT, per spec §5: a false '?' costs the player one rewrite, while
    # a guess that happens to match the solution is a false win they can
    # neither see nor undo.
    ACCEPT_MAX = 900      # best squared distance must be under this
    MARGIN_MIN = 220      # runner-up must exceed the best by this

    def self.read(strokes)
      live = playable(strokes)
      return [nil, 0] if live.empty?
      want = features(live)
      return [nil, 0] unless want

      best_d = nil
      best_digit = nil
      runner_d = nil
      template_features.each do |digit, vec|
        d = distance(want, vec)
        if best_d.nil? || d < best_d
          runner_d = best_d if best_digit != digit
          best_d = d
          best_digit = digit
        elsif digit != best_digit && (runner_d.nil? || d < runner_d)
          runner_d = d
        end
      end
      return [nil, 0] if best_digit.nil?
      return [nil, 0] if best_d > ACCEPT_MAX
      return [nil, 0] if runner_d && runner_d - best_d < MARGIN_MIN

      # 0..1000, monotone in how far the best beat the bar. Reported so the
      # corpus test in Task 12 can plot accuracy against it, and so
      # --record can show it while capturing.
      conf = 1000 - (best_d * 1000 / ACCEPT_MAX)
      conf = 1 if conf < 1
      [best_digit, conf]
    end

    # Strokes worth classifying: real ink, not a knuckle. The guard is on
    # the COMBINED path so that a digit drawn as several short strokes is
    # not thrown away one stroke at a time.
    def self.playable(strokes)
      return [] unless strokes.is_a?(Array)
      total = 0
      strokes.each { |s| total += Ink.path_length(s) }
      total < Ink::MIN_PATH ? [] : strokes
    end

    # A fixed-length integer vector. Every element is scaled to 0..255 so
    # the squared distance below stays inside mruby's fixnum range on
    # 32-bit ARM even when every component disagrees maximally
    # (20 * 255^2 = 1.3M, against a +-2^30 limit).
    def self.features(strokes)
      pts = resample(strokes, POINTS)
      return nil if pts.nil? || pts.empty?
      vec = density(pts)
      vec << aspect_of(strokes)
      vec << (strokes.size > 255 ? 255 : strokes.size) * 40
      vec << reversals(pts)
      vec << spread(pts)
      vec
    end

    # Resample the combined cloud to exactly n points, then normalise:
    # translate the bounding box to the origin and scale by its LARGER
    # side. Scaling by the larger side alone preserves aspect ratio, which
    # is what separates 1 from 7 (PLAN.md §6 says so) — a per-axis
    # normalisation would map both onto the same square.
    #
    # The near-vertical 1 is the degenerate case that needs the guard: its
    # bounding box width can be a single pixel, and dividing by it would
    # blow the shape up to nonsense.
    def self.resample(strokes, n)
      flat = []
      strokes.each { |s| s[:subpaths].each { |sub| sub.each { |p| flat << p } } }
      return nil if flat.empty?
      pts = spread_evenly(flat, n)
      min_x = min_y = max_x = max_y = nil
      pts.each do |x, y|
        if min_x.nil?
          min_x = max_x = x
          min_y = max_y = y
          next
        end
        min_x = x if x < min_x
        max_x = x if x > max_x
        min_y = y if y < min_y
        max_y = y if y > max_y
      end
      w = max_x - min_x
      h = max_y - min_y
      side = w > h ? w : h
      side = 1 if side < 1
      out = []
      pts.each do |x, y|
        out << [(x - min_x) * 255 / side, (y - min_y) * 255 / side]
      end
      out
    end

    # Picks n points evenly by INDEX, not by arc length. Arc-length
    # resampling is the textbook step and is skipped deliberately: the
    # digitizer already reports at a near-constant rate, so index spacing
    # approximates it closely, and the exact version costs a full
    # path-length pass plus an interpolation per point. If Task 11's
    # accuracy falls short, this is the first thing to upgrade.
    def self.spread_evenly(flat, n)
      return flat.dup if flat.size == n
      out = []
      i = 0
      while i < n
        out << flat[i * (flat.size - 1) / (n - 1)]
        i += 1
      end
      out
    end

    def self.density(pts)
      boxes = Array.new(DENSITY, 0)
      pts.each do |x, y|
        cx = x * GRID_N / 256
        cy = y * GRID_N / 256
        cx = GRID_N - 1 if cx > GRID_N - 1
        cy = GRID_N - 1 if cy > GRID_N - 1
        boxes[cy * GRID_N + cx] += 1
      end
      out = []
      boxes.each { |c| out << c * 255 / pts.size }
      out
    end

    def self.aspect_of(strokes)
      min_x = min_y = max_x = max_y = nil
      strokes.each do |s|
        b = Ink.bbox(s)
        next unless b
        min_x = b[0] if min_x.nil? || b[0] < min_x
        min_y = b[1] if min_y.nil? || b[1] < min_y
        max_x = b[2] if max_x.nil? || b[2] > max_x
        max_y = b[3] if max_y.nil? || b[3] > max_y
      end
      return 128 if min_x.nil?
      w = max_x - min_x
      h = max_y - min_y
      return 255 if h < 1
      r = w * 128 / h
      r > 255 ? 255 : r
    end

    # How often the path doubles back. A 1 barely turns; an 8 turns
    # constantly. Counted on the sign of each axis delta rather than on an
    # angle, because atan2 per point is dear and the sign is enough.
    def self.reversals(pts)
      n = 0
      last_sx = 0
      last_sy = 0
      i = 1
      while i < pts.size
        dx = pts[i][0] - pts[i - 1][0]
        dy = pts[i][1] - pts[i - 1][1]
        sx = dx > 0 ? 1 : (dx < 0 ? -1 : 0)
        sy = dy > 0 ? 1 : (dy < 0 ? -1 : 0)
        n += 1 if sx != 0 && last_sx != 0 && sx != last_sx
        n += 1 if sy != 0 && last_sy != 0 && sy != last_sy
        last_sx = sx if sx != 0
        last_sy = sy if sy != 0
        i += 1
      end
      v = n * 12
      v > 255 ? 255 : v
    end

    # Mean absolute deviation from the centre — a blunt "how spread out is
    # the ink", which separates a compact 0-ish 8 from a sprawling 7.
    def self.spread(pts)
      total = 0
      pts.each do |x, y|
        dx = x - 128
        dy = y - 128
        total += (dx < 0 ? -dx : dx) + (dy < 0 ? -dy : dy)
      end
      v = total / pts.size
      v > 255 ? 255 : v
    end

    def self.distance(a, b)
      d = 0
      i = 0
      while i < a.size
        t = a[i] - b[i]
        d += t * t
        i += 1
      end
      d / a.size
    end

    # MEMOISED ON FIRST USE, and deliberately NOT a constant initialised at
    # load time. mruby loads a gem's mrblib as `Dir.glob('mrblib/**/*.rb')`
    # sorted, which puts this file (`redoku/recognizer.rb`) BEFORE both
    # `redoku/sudoku/grid.rb` and `redoku/templates.rb` — so
    # `TEMPLATE_FEATURES = build_template_features` would raise
    # `uninitialized constant Redoku::Templates` at load. This is the same
    # load-order trap ENGINE-IMPROVEMENTS.md item 4 records against
    # DEMAND_SETS, where it forced four rule lists to be duplicated by hand;
    # resolving the dependency inside a method makes load order irrelevant
    # instead of making it someone's problem later.
    #
    # Not thread-safety-sensitive: the game is a single-threaded poll loop.
    def self.template_features
      @template_features ||= build_template_features
    end

    # The authored polylines live in a 100x100 box, so they are lifted into
    # panel coordinates for a real cell first: the feature vector must be
    # computed from the same kind of input the game will hand read(), or the
    # density boxes disagree.
    def self.build_template_features
      out = []
      cell = 40 # the middle cell; any cell works, features are normalised
      x, y, w, h = Layout.cell_rect(Sudoku::Grid.col_of(cell),
                                    Sudoku::Grid.row_of(cell))
      Templates::AUTHORED.each do |digit, subpaths|
        mapped = []
        subpaths.each do |sub|
          m = []
          sub.each { |px, py| m << [x + px * w / 100, y + py * h / 100] }
          mapped << m
        end
        vec = features([{ color: 0, width: 1, subpaths: mapped }])
        out << [digit, vec] if vec
      end
      out
    end

  end
end
```

- [ ] **Step 4b: add a load-order regression test.** The hazard above is
      invisible until someone "tidies" the memo into a constant, and then it
      fails at *load*, which reads as an unrelated crash in every test.

```ruby
assert('the template table resolves lazily, not at load time') do
  # mrblib loads sorted: recognizer.rb comes before sudoku/grid.rb and
  # templates.rb, so a constant built at load would raise. The suite running
  # at all is half the proof; this pins the other half.
  assert_false Redoku::Recognizer.constants.include?(:TEMPLATE_FEATURES)
  assert_true Redoku::Recognizer.template_features.size > 0
  # Same object on the second call — memoised, not rebuilt per read().
  assert_true Redoku::Recognizer.template_features
                .equal?(Redoku::Recognizer.template_features)
end
```

- [ ] **Step 5: run and confirm GREEN.** `make test`. If the two invariance
      assertions fail, the fix is in `resample`/`features`, **not** in
      loosening `ACCEPT_MAX` — a threshold widened to pass a test is how a
      false pass gets shipped.

- [ ] **Step 6: measure, and record.** Add a measuring assertion that prints
      rather than asserts, so the numbers land in the run log:

```ruby
assert('MEASURE: stage-1 accuracy and cost over the authored corpus') do
  # Not a pass/fail gate — the gate is spec §5's bar, judged by a human
  # reading these numbers. Printed so they reach the ledger.
  right = 0
  refused = 0
  total = 0
  false_pass = 0
  [[0, 0, 10, 10], [6, -4, 9, 10], [-5, 5, 11, 10], [3, 3, 10, 10]].each do |dx, dy, sn, sd|
    Redoku::Templates::AUTHORED.each do |digit, subpaths|
      total += 1
      got, = Redoku::Recognizer.read(cell_strokes(jitter(subpaths, dx, dy, sn, sd)))
      if got == digit
        right += 1
      elsif got.nil?
        refused += 1
      else
        false_pass += 1
      end
    end
  end
  puts "STAGE1 total=#{total} right=#{right} refused=#{refused} " \
       "misread=#{false_pass} accuracy=#{right * 100 / total}%"
  assert_true total > 0
end
```

Run `make test 2>&1 | grep STAGE1` and copy the line into the ledger **and**
into spec §5 under the decision gate.

- [ ] **Step 7: rule on the gate.** Write into the ledger, explicitly:
      `GATE: stage 1 <clears|misses> the bar (accuracy X%, misread N).
      Task 6 <skipped|required>.` If skipped, mark Task 6 `SKIPPED` in this
      plan with the numbers beside it.
- [ ] **Step 8: commit.**

```bash
git add mrbgems/mruby-redoku/mrblib/redoku/recognizer.rb \
        mrbgems/mruby-redoku/mrblib/redoku/templates.rb \
        mrbgems/mruby-redoku/test/recognizer.rb
git commit -m "feat(m3b): read a digit out of a cell's ink, cheaply

PLAN.md §6 specifies \$P at 48 points. Costed before writing it: n^(1-e)
starts over an O(n^2) pass is ~725k point-distance evaluations per cell and
~36M per board — seconds to minutes of interpreted mruby on a Cortex-A7,
not the cheap one-shot the batch-at-CHECK model assumed it bought.

Stage 1 instead: resample to 32 points, normalise by the LARGER bbox side
so aspect survives (it is what separates 1 from 7), and compare a 20-int
feature vector by squared distance — ~1.1k operations per cell. Thresholds
are strict on purpose: a false '?' costs one rewrite, a guess that happens
to match the solution is a false win nobody can see."
```

---

## Task 6 — `Recognizer` stage 2: $P on the shortlist  *(CONDITIONAL)*

**Run this task only if Task 5's gate said stage 1 misses the bar.** If it
cleared, mark this task `SKIPPED` with Task 5's measured numbers and move to
Task 7. The whole point of the gate is not to build this speculatively.

**Files:** modify `mrbgems/mruby-redoku/mrblib/redoku/recognizer.rb`, modify
`mrbgems/mruby-redoku/test/recognizer.rb`.

Stage 1 keeps its job but changes its output: instead of deciding, it ranks
and hands the **best two digits** to a greedy cloud match over just those
digits' templates (≈ 10 clouds at n = 32 → ≈ 60k point-distance evaluations
per cell, ≈ 3M per board — spec §5).

- [ ] **Step 1: write the failing tests.**

```ruby
assert('shortlist returns exactly two distinct digits, best first') do
  s = cell_strokes([[[64, 8], [18, 62], [86, 62]], [[64, 8], [64, 92]]]) # a 4
  got = Redoku::Recognizer.shortlist(Redoku::Recognizer.features(s), 2)
  assert_equal 2, got.size
  assert_false got[0] == got[1]
end

assert('cloud_distance is zero for a cloud against itself') do
  pts = Redoku::Recognizer.resample(cell_strokes([[[50, 8], [50, 92]]]), 32)
  assert_equal 0, Redoku::Recognizer.cloud_distance(pts, pts)
end

assert('cloud_distance ignores stroke order and direction') do
  # The reason $P was chosen over $1 in the first place (PLAN.md §6):
  # people draw a 4 and a 7 with varying stroke counts and orders.
  fwd = [[[64, 8], [18, 62], [86, 62]], [[64, 8], [64, 92]]]
  rev = [[[64, 92], [64, 8]], [[86, 62], [18, 62], [64, 8]]]
  a = Redoku::Recognizer.resample(cell_strokes(fwd), 32)
  b = Redoku::Recognizer.resample(cell_strokes(rev), 32)
  assert_true Redoku::Recognizer.cloud_distance(a, b) < 400
end

assert('stage 2 resolves the pairs a coarse density grid blurs') do
  # These three pairs are the ones a 4x4 density grid is expected to blur,
  # because each pair shares its ink distribution and differs mainly in
  # connectivity: 4/9 (both top-heavy with a descending stem), 3/5 (both
  # two right-facing bowls), 6/8 (both a closed lower loop). Every one of
  # them must survive stage 2.
  pairs = [
    [4, [[[64, 8], [18, 62], [86, 62]], [[64, 8], [64, 92]]],
     9, [[[70, 40], [40, 48], [30, 26], [54, 10], [70, 28], [70, 40], [58, 90]]]],
    [3, [[[20, 12], [70, 12], [44, 46], [74, 60], [64, 90], [22, 88]]],
     5, [[[80, 10], [26, 10], [24, 44], [58, 42], [78, 62], [62, 90], [22, 86]]]],
    [6, [[[70, 10], [34, 40], [26, 70], [46, 90], [72, 78], [66, 54], [34, 52]]],
     8, [[[54, 10], [30, 26], [54, 44], [76, 62], [54, 90], [28, 68],
          [54, 44], [72, 26], [54, 10]]]]
  ]
  pairs.each do |da, sa, db, sb|
    assert_equal da, Redoku::Recognizer.read(cell_strokes(sa))[0]
    assert_equal db, Redoku::Recognizer.read(cell_strokes(sb))[0]
  end
end

assert('MEASURE: stage-2 accuracy, beside stage 1 for comparison') do
  # Re-run Task 5 Step 6's measurement verbatim so the two numbers are
  # directly comparable, and record BOTH in the ledger. If stage 2 does not
  # beat stage 1 by a visible margin it is not worth its ~50x cost, and the
  # honest move is to revert this task rather than keep it for tidiness.
  right = 0
  total = 0
  misread = 0
  [[0, 0, 10, 10], [6, -4, 9, 10], [-5, 5, 11, 10], [3, 3, 10, 10]].each do |dx, dy, sn, sd|
    Redoku::Templates::AUTHORED.each do |digit, subpaths|
      total += 1
      got, = Redoku::Recognizer.read(cell_strokes(jitter(subpaths, dx, dy, sn, sd)))
      if got == digit
        right += 1
      elsif !got.nil?
        misread += 1
      end
    end
  end
  puts "STAGE2 total=#{total} right=#{right} misread=#{misread} " \
       "accuracy=#{right * 100 / total}%"
  assert_true total > 0
end
```

- [ ] **Step 2: run and confirm RED** (`NoMethodError` on `shortlist` /
      `cloud_distance`).
- [ ] **Step 3: implement `shortlist` and `cloud_distance`.**

```ruby
    # $P's greedy cloud match, restricted to a shortlist. Runs
    # STARTS = sqrt(n) passes from evenly spaced start indices and keeps
    # the cheapest, which is what buys stroke-order and direction
    # invariance without the n! of an exact assignment.
    STARTS = 6

    def self.cloud_distance(a, b)
      best = nil
      s = 0
      while s < STARTS
        d = greedy_pass(a, b, s * a.size / STARTS)
        best = d if best.nil? || d < best
        s += 1
      end
      best
    end

    def self.greedy_pass(a, b, start)
      used = Array.new(b.size, false)
      sum = 0
      weight = a.size
      k = 0
      while k < a.size
        i = (start + k) % a.size
        best = nil
        best_j = 0
        j = 0
        while j < b.size
          unless used[j]
            dx = a[i][0] - b[j][0]
            dy = a[i][1] - b[j][1]
            d = dx * dx + dy * dy
            if best.nil? || d < best
              best = d
              best_j = j
            end
          end
          j += 1
        end
        used[best_j] = true
        # Later matches count for less: the first pairings are the
        # confident ones, and $P weights them so a bad tail cannot swamp a
        # good head.
        sum += best * weight / a.size
        weight -= 1
        k += 1
      end
      sum / a.size
    end

    def self.shortlist(want, n)
      scored = []
      template_features.each do |digit, vec|
        d = distance(want, vec)
        found = false
        scored.each_with_index do |(dg, dd), i|
          next unless dg == digit
          found = true
          scored[i] = [digit, d] if d < dd
        end
        scored << [digit, d] unless found
      end
      scored.sort { |p, q| p[1] <=> q[1] }[0, n].map { |dg, _d| dg }
    end
```

`read` then becomes: features → `shortlist(want, 2)` → resample once →
`cloud_distance` against each shortlisted digit's template clouds → apply
`ACCEPT_MAX`/`MARGIN_MIN` to *those* distances.

- [ ] **Step 4: run and confirm GREEN**, then re-run the MEASURE assertion
      from Task 5 Step 6 and record the new numbers beside the old ones.
- [ ] **Step 5: commit.**

```bash
git add mrbgems/mruby-redoku/mrblib/redoku/recognizer.rb mrbgems/mruby-redoku/test/recognizer.rb
git commit -m "feat(m3b): \$P greedy cloud match, on a two-digit shortlist

Stage 1 measured below the bar (numbers in the ledger), so the second
stage lands: rank with the cheap features, then pay \$P only on the best
two digits' clouds — ~10 comparisons per cell instead of 45, ~3M
point-distance evaluations per board instead of ~36M."
```

---

## Task 7 — CHECK: the button, the pass, the verdicts

**Files:** modify `layout.rb`, `font.rb`, `renderer.rb`, `app.rb`; modify
`test/layout.rb`, `test/font.rb`, `test/renderer.rb`, `test/app.rb`.

**Interfaces produced** (Task 8 consumes `mark_of` and `solved_correctly?`):

```
Layout.button_rect(:check)                 -> [932, 1540, 400, 140]
Renderer#redraw_cell(index, grid, mark: nil)   mark: nil | :wrong | :unreadable
Renderer#draw_mark(index, mark)            paints the mark ONLY, over live ink
App#run_check                              -> Integer cells read
App#mark_of(index)                         -> nil | :wrong | :unreadable
App#solved_correctly?                      -> true/false
App#checks                                 -> Integer presses this sitting
```

- [ ] **Step 1: write the failing tests.**

```ruby
# --- layout
assert('CHECK sits in row 1, keeping QUIT alone at the far end of row 2') do
  x, y, w, h = Redoku::Layout.button_rect(:check)
  assert_equal [932, Redoku::Layout::BTN_ROW1_Y, 400, 140], [x, y, w, h]
  # PLAN.md §8's sketch draws it here, and Layout's own comment gives the
  # rule: the destructive button stays two full widths clear.
  qx, = Redoku::Layout.button_rect(:quit)
  assert_equal Redoku::Layout::BTN_ROW2_Y, Redoku::Layout.button_rect(:quit)[1]
  assert_true (x - qx).abs > 0
  assert_true x + w <= Redoku::Layout::BOARD_X + Redoku::Layout::BOARD_W
end

assert('a tap in the CHECK rect resolves to :check') do
  x, y, w, h = Redoku::Layout.button_rect(:check)
  assert_equal :check, Redoku::Layout.button_at(x + w / 2, y + h / 2)
end

# --- font
assert("Font has a '?' glyph, because draw() is silent without one") do
  assert_false Redoku::Font::GLYPHS['?'].nil?
  assert_equal Redoku::Font::HEIGHT, Redoku::Font::GLYPHS['?'].size
  Redoku::Font::GLYPHS['?'].each { |r| assert_equal Redoku::Font::WIDTH, r.size }
end

# --- the pass
assert('CHECK reads a written digit into the grid and retires its ink') do
  path = stroke_app_db('check_read')
  remove_app_db(path)
  store = Redoku::Store.open(path, log: nil)
  app, = new_app(store: store, generator: FakeGenerator.new)
  app.new_puzzle
  sid = app.current_save_id
  index = first_empty_cell(app.grid)
  want = app.solution[index]
  write_digit_in_cell(app, index, want)   # helper below

  assert_equal 1, app.run_check
  assert_equal want, app.grid.value_at(index)
  assert_nil app.mark_of(index)
  # The ink is retired: still in the table, no longer read back.
  assert_equal 0, store.strokes(sid).size
  assert_equal 0, app.ink_strokes.size
  rows = store.instance_variable_get(:@db)
              .execute('SELECT COUNT(*) FROM strokes WHERE game_id = ?', [sid])
  assert_true rows[0][0] > 0
  store.close
  remove_app_db(path)
end

assert('a wrong digit is written, printed and marked') do
  app, = new_app(generator: FakeGenerator.new)
  app.new_puzzle
  index = first_empty_cell(app.grid)
  wrong = app.solution[index] == 9 ? 8 : 9
  write_digit_in_cell(app, index, wrong)
  app.run_check
  assert_equal wrong, app.grid.value_at(index)
  assert_equal :wrong, app.mark_of(index)
end

assert('unreadable ink is KEPT on the glass and marked, not repainted away') do
  # The trap: redraw_cell repaints a cell from the model, which would wipe
  # the very ink an unreadable verdict is preserving. Unreadable cells get
  # draw_mark only.
  app, d = new_app(generator: FakeGenerator.new)
  app.new_puzzle
  index = first_empty_cell(app.grid)
  scribble_in_cell(app, index)
  d.clear_calls
  app.run_check
  assert_true app.grid.unreadable?(index)
  assert_equal :unreadable, app.mark_of(index)
  assert_equal 1, app.ink_strokes.size          # ink survived
  x, y, w, h = cell_rect_of(index)
  # No full-cell white fill over this cell: that is what erasing looks like.
  assert_false d.rects.any? { |rx, ry, rw, rh, g|
    g == Redoku::Renderer::WHITE && rx == x && ry == y && rw == w && rh == h
  }
end

assert('CHECK never touches a given, even one with ink on it') do
  app, = new_app(generator: FakeGenerator.new)
  app.new_puzzle
  given = first_given_cell(app.grid)
  before = app.grid.value_at(given)
  scribble_in_cell(app, given)
  assert_equal 0, app.run_check          # nothing was read
  assert_equal before, app.grid.value_at(given)
  assert_equal 1, app.ink_strokes.size   # the annotation survives
end

assert('CHECK counts its presses and reports them') do
  app, = new_app(generator: FakeGenerator.new)
  app.new_puzzle
  assert_equal 0, app.checks
  press_check(app)
  press_check(app)
  assert_equal 2, app.checks
end

assert('re-checking skips a cell already read, without any dirty tracking') do
  # Spec §4: a read cell has no live strokes, so it is not in the grouped
  # set at all. This is the whole of the "re-recognize only what changed"
  # promise in PLAN.md §7.
  app, = new_app(generator: FakeGenerator.new)
  app.new_puzzle
  index = first_empty_cell(app.grid)
  write_digit_in_cell(app, index, app.solution[index])
  assert_equal 1, app.run_check
  assert_equal 0, app.run_check
end

assert('writing into a checked cell clears its entry and its mark') do
  app, = new_app(generator: FakeGenerator.new)
  app.new_puzzle
  index = first_empty_cell(app.grid)
  wrong = app.solution[index] == 9 ? 8 : 9
  write_digit_in_cell(app, index, wrong)
  app.run_check
  assert_equal :wrong, app.mark_of(index)
  write_digit_in_cell(app, index, app.solution[index])
  assert_true app.grid.empty?(index)      # cleared at pen-down
  assert_nil app.mark_of(index)
  app.run_check
  assert_nil app.mark_of(index)
end

assert('a cell repaint that removes an entry digit flushes GL16, not DU') do
  # Constraint 4, and App#flush_ink's warning at the point of choice:
  # ENTRY_GRAY is 96, a mid tone, and DU is two-level.
  app, d = new_app(generator: FakeGenerator.new)
  app.new_puzzle
  index = first_empty_cell(app.grid)
  write_digit_in_cell(app, index, app.solution[index])
  app.run_check
  d.clear_calls
  write_digit_in_cell(app, index, 5)
  x, y, w, h = cell_rect_of(index)
  hit = d.updates.find { |ux, uy, uw, uh, _wf, _fl|
    ux <= x && uy <= y && ux + uw >= x + w && uy + uh >= y + h
  }
  assert_false hit.nil?
  assert_equal RM2::GL16, hit[4]
end

assert('CHECK persists its verdicts, including the unreadable one') do
  path = stroke_app_db('check_persist')
  remove_app_db(path)
  store = Redoku::Store.open(path, log: nil)
  app, = new_app(store: store, generator: FakeGenerator.new)
  app.new_puzzle
  read_cell = first_empty_cell(app.grid)
  write_digit_in_cell(app, read_cell, app.solution[read_cell])
  bad_cell = next_empty_cell(app.grid, read_cell)
  scribble_in_cell(app, bad_cell)
  app.run_check

  rec = store.autosave
  assert_equal app.solution[read_cell].to_s, rec[:entries][read_cell]
  assert_equal '?', rec[:entries][bad_cell]

  store2 = Redoku::Store.open(path, log: nil)
  app2, _d2, _in2, sig2 = new_app(store: store2)
  sig2.terminated = true
  app2.run
  assert_equal app.solution[read_cell], app2.grid.value_at(read_cell)
  assert_true app2.grid.unreadable?(bad_cell)
  remove_app_db(path)
end
```

Test helpers to add to `test/app.rb`:

```ruby
def cell_rect_of(index)
  Redoku::Layout.cell_rect(Redoku::Sudoku::Grid.col_of(index),
                           Redoku::Sudoku::Grid.row_of(index))
end

def first_empty_cell(grid)
  i = 0
  i += 1 while i < 81 && grid.given?(i)
  i
end

def next_empty_cell(grid, after)
  i = after + 1
  i += 1 while i < 81 && grid.given?(i)
  i
end

def first_given_cell(grid)
  i = 0
  i += 1 while i < 81 && !grid.given?(i)
  i
end

# Draws the authored template for `digit` inside `index`, as pen samples, so
# the recognizer sees the same panel coordinates the game gives it.
def write_digit_in_cell(app, index, digit)
  entry = Redoku::Templates::AUTHORED.find { |d, _s| d == digit }
  x, y, w, h = cell_rect_of(index)
  entry[1].each do |sub|
    pts = sub.map { |px, py| [x + px * w / 100, y + py * h / 100] }
    pts.each { |px, py| app.handle_sample(pen_sample(px, py, true)) }
    app.handle_sample(pen_sample(pts[-1][0], pts[-1][1], false))
  end
end

def scribble_in_cell(app, index)
  x, y, w, h = cell_rect_of(index)
  [[10, 10], [90, 90], [10, 90], [90, 10], [50, 10], [50, 90],
   [10, 50], [90, 50]].each do |px, py|
    app.handle_sample(pen_sample(x + px * w / 100, y + py * h / 100, true))
  end
  app.handle_sample(pen_sample(x + w / 2, y + h / 2, false))
end

def press_check(app)
  x, y, w, h = Redoku::Layout.button_rect(:check)
  app.handle_sample(pen_sample(x + w / 2, y + h / 2, true))
  app.handle_sample(pen_sample(x + w / 2, y + h / 2, false))
end
```

- [ ] **Step 2: run and confirm RED.** `make test`.

- [ ] **Step 3: add the button and the glyph.** In `layout.rb`, `BUTTONS`
      gains one row and the comment gains one sentence:

```ruby
    # CHECK takes row 1's third slot, which is where PLAN.md §8's sketch has
    # always drawn it. Not an arbitrary free slot: it keeps QUIT alone at the
    # far end of row 2, across a dead gap, which is this comment's rule.
    BUTTONS = [
      [:new,   BOARD_X,                          BTN_ROW1_Y, BTN_W, BTN_H].freeze,
      [:level, BOARD_X + BTN_W + BTN_GAP,        BTN_ROW1_Y, BTN_W, BTN_H].freeze,
      [:check, BOARD_X + 2 * (BTN_W + BTN_GAP),  BTN_ROW1_Y, BTN_W, BTN_H].freeze,
      [:games, BOARD_X,                          BTN_ROW2_Y, BTN_W, BTN_H].freeze,
      [:quit,  BOARD_X + 2 * (BTN_W + BTN_GAP),  BTN_ROW2_Y, BTN_W, BTN_H].freeze
    ].freeze
```

In `font.rb`, `GLYPHS` gains the character that constraint 3 warns about:

```ruby
      '?' => ['.###.', '#...#', '....#', '...#.', '..#..', '.....', '..#..'],
```

Check `menu_target_at` in `app.rb`: it maps play-mode buttons onto menu
meanings by name, and `:check` now exists. Give it an explicit meaning in the
GAMES menu (nil — the saves list has no check) so a tap there does nothing
rather than falling through.

- [ ] **Step 4: teach the renderer the marks.**

```ruby
    # A verdict mark, in the cell's top-right corner, small enough to leave
    # the digit or the player's ink legible under it.
    MARK_SCALE = 4
    MARK_INSET = 8

    def redraw_cell(index, grid, mark: nil)
      col = Sudoku::Grid.col_of(index)
      row = Sudoku::Grid.row_of(index)
      x, y, w, h = Layout.cell_rect(col, row)
      @d.fill_rect(x, y, w, h, WHITE)
      redraw_cell_lines(col, row, x, y, w, h)
      if grid && !grid.empty?(index)
        gray = grid.given?(index) ? GIVEN_GRAY : ENTRY_GRAY
        draw_digit(index, grid.value_at(index), gray)
      end
      draw_mark(index, mark) if mark
      self
    end

    # Paints ONLY the mark, over whatever is already in the cell. This is
    # the path an :unreadable verdict must take: that cell is keeping its
    # ink, and redraw_cell above would repaint the cell from the model and
    # wipe the very strokes the verdict exists to preserve.
    def draw_mark(index, mark)
      text = mark == :wrong ? 'X' : '?'
      col = Sudoku::Grid.col_of(index)
      row = Sudoku::Grid.row_of(index)
      x, y, w, _h = Layout.cell_rect(col, row)
      gw = Font.width(text, MARK_SCALE)
      Font.draw(@d, text, x + w - gw - MARK_INSET, y + MARK_INSET,
                MARK_SCALE, GIVEN_GRAY)
      self
    end
```

- [ ] **Step 5: implement the pass in `app.rb`.**

```ruby
    # CHECK is the moment ink becomes an answer (PLAN.md §7, spec §2). One
    # batch pass: group the live ink by cell, read each cell once, write the
    # verdict into the model, and paint it.
    #
    # Not gated on a full board, and it counts itself (spec §3). Pressed on
    # three cells it is a correctness oracle, which is a real way to cheat —
    # the answer taken was to leave that to the player and put the number on
    # the win screen, rather than to police it.
    def run_check
      @checks += 1
      groups = ink_by_cell
      return 0 if groups.empty?
      done = 0
      groups.each do |index, strokes|
        done += 1
        @renderer.draw_progress(done, groups.size)
        @renderer.flush_progress
        digit, = Recognizer.read(strokes)
        if digit
          @grid.set_entry(index, digit)
          retire_ink(strokes)
          # Repaints the cell from the model, so the printed digit replaces
          # the handwriting — which is the point (spec §2): a misread is
          # then visible as a printed 9 where you wrote a 4, instead of a
          # bare X you cannot tell from your own mistake.
          @renderer.redraw_cell(index, @grid, mark: mark_of(index))
        else
          @grid.set_unreadable(index)
          # NOT redraw_cell: this cell keeps its ink.
          @renderer.draw_mark(index, :unreadable)
        end
      end
      # One board-wide GL16 rather than a per-cell storm. Constraint 4
      # forbids DU here (entry digits are a mid tone), and fifty cell-sized
      # GL16 flushes would take far longer than one board flush.
      @renderer.flush_board
      save_autosave
      done
    end

    # Live ink, grouped by the cell it sits in. Givens are skipped: a clue
    # cannot be answered, set_entry would raise on one, and a player who
    # circled a clue keeps that annotation. Cells below the dot guard fall
    # out inside Recognizer.read rather than here, so a cell holding one
    # stray speck still reads as unreadable rather than silently vanishing.
    def ink_by_cell
      out = {}
      @ink_strokes.each do |s|
        index = Ink.cell_of(s)
        next if index.nil?
        next if @grid.nil? || @grid.given?(index)
        (out[index] ||= []) << s
      end
      out
    end

    # Read ink stops being replayed but stays in the record: it is the only
    # copy of the player's hand. Contrast forget_ink_in, which DELETEs,
    # because an erase means gone.
    def retire_ink(strokes)
      ids = []
      strokes.each { |s| ids << s[:id] if s[:id] }
      @ink_strokes = @ink_strokes - strokes
      return if ids.empty? || @store.nil?
      begin
        @store.retire_strokes(ids)
      rescue StandardError => e
        log_line('stroke retire failed (' + e.message + ')')
      end
    end

    # A pure function of state that already persists, which is why no column
    # and no dirty set exists for marks (spec §2).
    def mark_of(index)
      return nil if @grid.nil? || @grid.given?(index)
      return :unreadable if @grid.unreadable?(index)
      v = @grid.value_at(index)
      return nil if v == 0
      return nil if @solution.nil? || @solution[index].nil?
      v == @solution[index] ? nil : :wrong
    end

    def solved_correctly?
      return false if @grid.nil? || @solution.nil?
      i = 0
      while i < Sudoku::Grid::CELLS
        unless @grid.given?(i)
          return false if @grid.value_at(i) != @solution[i]
        end
        i += 1
      end
      true
    end
```

Wire the button, initialise the counter, and clear a cell's verdict when the
player writes into it:

```ruby
      @checks = 0          # in initialize, beside @erased

    # Added to the existing attr_reader list (app.rb:102-103), which is how
    # every other test-visible piece of App state is exposed. :screen is
    # already there; :checks is not.
    attr_reader :difficulty, :ink_dirty, :grid, :solution, :achieved_tier,
                :current_save_id, :screen, :ink_strokes, :checks

      when :check then acknowledge(:check) { run_check }   # in press

    # In begin_stroke, on the :ink path, before the first segment is echoed:
    # PLAN.md §7's "they stay until edited", made exact. Repainting is what
    # takes the printed digit off the glass, and constraint 4 makes that a
    # GL16 region — DU is two-level and would ghost the 96-gray digit.
    def clear_verdict_at(index)
      return if @grid.nil? || @grid.given?(index)
      return if @grid.empty?(index) && !@grid.unreadable?(index)
      @grid.clear_entry(index)
      @renderer.redraw_cell(index, @grid)
      x, y, w, h = Layout.cell_rect(Sudoku::Grid.col_of(index),
                                    Sudoku::Grid.row_of(index))
      @renderer.flush_rect(x, y, w, h, waveform: RM2::GL16)
    end
```

- [ ] **Step 6: run and confirm GREEN.** `make test`.
- [ ] **Step 7: commit.**

```bash
git add mrbgems/mruby-redoku/mrblib/redoku/layout.rb \
        mrbgems/mruby-redoku/mrblib/redoku/font.rb \
        mrbgems/mruby-redoku/mrblib/redoku/renderer.rb \
        mrbgems/mruby-redoku/mrblib/redoku/app.rb \
        mrbgems/mruby-redoku/test/
git commit -m "feat(m3b): CHECK reads the board and says what it found

A read cell prints the digit the recognizer saw and stops replaying its
ink, so a misread shows up as a printed 9 where you wrote a 4 instead of a
bare X indistinguishable from your own mistake. An unreadable cell KEEPS
its ink and takes draw_mark only — redraw_cell would repaint from the
model and wipe the strokes the verdict exists to preserve.

PLAN.md §7's 'only re-recognize cells whose ink changed' needs no dirty
tracking: a read cell has no live strokes, so it is not in the grouped set
at all. Marks need no column either, being a pure function of entries and
the stored solution."
```

---

## Task 8 — The win screen

**Files:** modify `renderer.rb`, `app.rb`; modify `test/renderer.rb`,
`test/app.rb`.

- [ ] **Step 1: write the failing tests.**

```ruby
assert('a full and correct board wins, and reports the check count') do
  app, d = new_app(generator: FakeGenerator.new)
  app.new_puzzle
  fill_board_correctly(app)      # helper: writes every non-given answer
  app.run_check
  assert_true app.won?
  assert_equal :win, app.screen
  # GC16 + SYNC: the one full-screen flash a transition is allowed.
  last = d.updates[-1]
  assert_equal [0, 0, Redoku::Layout::SCREEN_W, Redoku::Layout::SCREEN_H],
               [last[0], last[1], last[2], last[3]]
  assert_equal RM2::GC16, last[4]
end

assert('one unreadable cell is enough to withhold the win') do
  # The property Grid::UNREADABLE exists for (spec §2): a cell that could
  # not be read is not a solved cell, so no false win.
  app, = new_app(generator: FakeGenerator.new)
  app.new_puzzle
  fill_board_correctly(app)
  last = last_empty_cell(app.grid)
  app.grid.clear_entry(last)
  scribble_in_cell(app, last)
  app.run_check
  assert_true app.grid.unreadable?(last)
  assert_false app.won?
end

assert('one wrong digit is enough to withhold the win') do
  app, = new_app(generator: FakeGenerator.new)
  app.new_puzzle
  fill_board_correctly(app)
  i = first_empty_cell(app.grid)
  app.grid.set_entry(i, app.solution[i] == 9 ? 8 : 9)
  assert_false app.solved_correctly?
end

assert('a tap on the win screen deals a new puzzle') do
  app, = new_app(generator: FakeGenerator.new)
  app.new_puzzle
  fill_board_correctly(app)
  app.run_check
  before = app.grid.givens_s
  app.handle_sample(pen_sample(700, 900, true))
  app.handle_sample(pen_sample(700, 900, false))
  assert_equal :play, app.screen
  assert_false before == app.grid.givens_s
  assert_equal 0, app.checks         # a new puzzle is a new sitting
end

assert('the win screen text stays inside the font charset') do
  # Constraint 3: Font.draw silently draws NOTHING for a missing glyph, so
  # a stray lowercase letter would ship a blank screen.
  allowed = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -:.?'
  Redoku::Renderer::WIN_TEXT.each_char do |ch|
    assert_true allowed.include?(ch), "no glyph for #{ch.inspect}"
  end
end
```

Test helpers to add to `test/app.rb`:

```ruby
# Writes the correct answer into every non-given cell, as real pen samples,
# so the board is genuinely solved by ink and not by poking the model.
def fill_board_correctly(app)
  i = 0
  while i < Redoku::Sudoku::Grid::CELLS
    write_digit_in_cell(app, i, app.solution[i]) unless app.grid.given?(i)
    i += 1
  end
end

def last_empty_cell(grid)
  i = Redoku::Sudoku::Grid::CELLS - 1
  i -= 1 while i >= 0 && grid.given?(i)
  i
end
```

- [ ] **Step 2: run and confirm RED.**
- [ ] **Step 3: add `Renderer#draw_win(checks)`**, modelled on `draw_splash`.

```ruby
    # Pinned as constants for the reason SPLASH_TEXT is pinned: Font.draw
    # silently draws NOTHING for a character it has no glyph for, so a
    # caller-supplied string could ship a blank win screen and no test would
    # see it. Pinned here, and asserted against the charset in test/app.rb.
    WIN_TEXT   = 'SOLVED'
    WIN_LABEL  = 'CHECKS: '
    WIN_HINT   = 'TAP FOR A NEW ONE'
    WIN_SCALE  = 10
    WIN_SUB    = 5

    def draw_win(checks)
      @d.fill_rect(0, 0, @d.width, @d.height, WHITE)
      centre_line(WIN_TEXT, WIN_SCALE, Layout::SCREEN_H / 2 - 160)
      centre_line(WIN_LABEL + checks.to_s, WIN_SUB, Layout::SCREEN_H / 2)
      centre_line(WIN_HINT, WIN_SUB, Layout::SCREEN_H / 2 + 120)
      self
    end

    def centre_line(text, scale, y)
      w = Font.width(text, scale)
      Font.draw(@d, text, (Layout::SCREEN_W - w) / 2, y, scale, BLACK)
    end
```

- [ ] **Step 4: add `:win` to `App`.**

```ruby
    # In run_check, after flush_board and save_autosave:
      win_screen if solved_correctly?
      done
    end

    def won?
      @screen == :win
    end

    # The one full-screen GC16 a transition is allowed (PLAN.md §8): it also
    # clears the ghosting fifty cell repaints just laid down.
    def win_screen
      @screen = :win
      @renderer.draw_win(@checks)
      @renderer.flush_all
    end
```

`target_at` routes the new screen, and any tap on it deals:

```ruby
    def target_at(x, y)
      return :win_tap if @screen == :win
      return Layout.button_at(x, y) if @screen == :play
      menu_target_at(x, y)
    end

    # In press: a new puzzle is a new sitting, so the check count resets with
    # it — @checks is per-board, not a lifetime score (spec §3).
      when :win_tap then
        @screen = :play
        @checks = 0
        new_puzzle
```

Note `:win_tap` must be reachable from **both** stroke paths (pen and
finger), and `tap?` compares `target_at` at down and at lift — which works
unchanged here, because the whole screen is one target.

- [ ] **Step 5: run and confirm GREEN**, then **commit**.

```bash
git commit -m "feat(m3b): the win screen, withheld unless the board really is solved

Fires on every non-given cell equalling the stored solution, not on
Grid#solved?: the direct comparison is cheaper than a 27-unit consistency
sweep, is the same test the X marks already run per cell, and does not
quietly depend on the puzzle being uniquely solvable — true here, but not
something the win screen should have to know."
```

---

## Task 9 — The difficulty menu

**Files:** modify `layout.rb`, `renderer.rb`, `app.rb`; modify their tests.

Kept in M3b rather than deferred (spec §7). The `Level` button stops cycling
and opens a picker: five rows from `Sudoku::Rater::TIERS`, the current one
marked, tap to select and deal. Cycling is **replaced**, not kept alongside —
two ways to do one thing is how the tier label and the deleted
`Renderer::DIFFICULTIES` drifted apart before (`rater.rb`: *"Do not
reintroduce one"*).

- [ ] **Step 1: write the failing tests.**

```ruby
assert('LEVEL opens the picker instead of cycling') do
  app, = new_app(generator: FakeGenerator.new)
  app.new_puzzle
  before = app.difficulty
  press_level(app)
  assert_equal :levels, app.screen
  assert_equal before, app.difficulty      # it no longer changes on press
end

assert('the picker offers exactly the five tiers, in Rater order') do
  assert_equal Redoku::Sudoku::Rater::TIERS.size, Redoku::Layout.level_rows
  # Derived and not duplicated: adding a sixth tier must not need a Layout
  # edit. Rater::TIERS is the only tier list in the tree.
  assert_equal 5, Redoku::Layout.level_rows
  assert_true Redoku::Layout.level_rows <= 9   # rows the menu band can hold
end

assert('tapping a row sets that tier and deals at it') do
  app, = new_app(generator: FakeGenerator.new)
  app.new_puzzle
  press_level(app)
  tap_menu_row(app, 3)                     # :expert, TIERS[3]
  assert_equal :expert, app.difficulty
  assert_equal :play, app.screen
end

assert('BACK leaves the picker without changing the tier or the board') do
  app, = new_app(generator: FakeGenerator.new)
  app.new_puzzle
  before_tier = app.difficulty
  before_board = app.grid.givens_s
  press_level(app)
  press_back(app)
  assert_equal :play, app.screen
  assert_equal before_tier, app.difficulty
  assert_equal before_board, app.grid.givens_s
end

assert('every tier label has a glyph for every character') do
  allowed = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -:.?'
  Redoku::Sudoku::Rater::TIERS.each do |t|
    t.to_s.upcase.each_char do |ch|
      assert_true allowed.include?(ch), "no glyph for #{ch.inspect} in #{t}"
    end
  end
end
```

Test helpers to add to `test/app.rb`:

```ruby
def press_level(app)
  x, y, w, h = Redoku::Layout.button_rect(:level)
  app.handle_sample(pen_sample(x + w / 2, y + h / 2, true))
  app.handle_sample(pen_sample(x + w / 2, y + h / 2, false))
end

# In a menu the play-mode :new rect means BACK (App#menu_target_at).
def press_back(app)
  x, y, w, h = Redoku::Layout.button_rect(:new)
  app.handle_sample(pen_sample(x + w / 2, y + h / 2, true))
  app.handle_sample(pen_sample(x + w / 2, y + h / 2, false))
end

def tap_menu_row(app, n)
  x, y, w, h = Redoku::Layout.menu_row_rect(n)
  app.handle_sample(pen_sample(x + w / 2, y + h / 2, true))
  app.handle_sample(pen_sample(x + w / 2, y + h / 2, false))
end
```

- [ ] **Step 2: run and confirm RED.**
- [ ] **Step 3: implement.** `Layout` states the row count, derived from the
      one tier list rather than duplicating it:

```ruby
    # Derived, never duplicated: Rater::TIERS is the ONLY tier list, and
    # rater.rb says so at the point of definition ("Do not reintroduce
    # one" — Renderer::DIFFICULTIES was deleted for being a second copy).
    def self.level_rows
      Sudoku::Rater::TIERS.size
    end
```

`Renderer` draws it with the GAMES menu's own row machinery:

```ruby
    LEVEL_TITLE = 'LEVEL'
    LEVEL_MARK  = '- '        # against the current tier; inside the charset

    def draw_levels_menu(tiers, current)
      @d.fill_rect(0, 0, @d.width, @d.height, WHITE)
      Font.draw(@d, LEVEL_TITLE, Layout::HEADER_X, Layout::HEADER_Y,
                Layout::TITLE_SCALE, BLACK)
      tiers.each_with_index do |tier, i|
        x, y, w, h = Layout.menu_row_rect(i)
        label = (tier == current ? LEVEL_MARK : '  ') + tier.to_s.upcase
        Font.draw(@d, label, x + 20, y + (h - Font::HEIGHT * Layout::LABEL_SCALE) / 2,
                  Layout::LABEL_SCALE, BLACK)
        @d.fill_rect(x, y + h - 1, w, 1, BLACK)
      end
      draw_menu_buttons(false)
      self
    end
```

`App` gains the screen, and routes it beside the GAMES menu:

```ruby
    # LEVEL opens a picker rather than cycling. Cycling is REPLACED, not kept
    # beside it: five tiers meant up to five presses and a full dig on each
    # one that landed, and two ways to set one value is how the tier label
    # and Renderer::DIFFICULTIES drifted apart before.
    def open_levels
      @screen = :levels
      @renderer.draw_levels_menu(Sudoku::Rater::TIERS, @difficulty)
      @renderer.flush_all
    end

    # In press, replacing `when :level then acknowledge(:level) { cycle_difficulty }`:
      when :level then acknowledge(:level) { open_levels }

    # In menu_target_at's row branch, and in press_in_menu:
    def level_chosen(n)
      tier = Sudoku::Rater::TIERS[n]
      return unless tier
      @difficulty = tier
      @screen = :play
      new_puzzle          # repaints the board itself, hence restore: false
    end
```

Route `:levels` explicitly rather than letting it fall through the GAMES
branch — `menu_target_at` is shared, so the row-index case must dispatch on
`@screen` to decide whether a row means "load this save" or "deal at this
tier". BACK returns to `:play` and repaints without dealing.

- [ ] **Step 4: run and confirm GREEN**, then **commit**.

```bash
git commit -m "feat(m3b): pick a difficulty instead of cycling to it

Five tiers means up to five presses and a full dig on every one that lands.
Cycling is replaced rather than kept beside the picker: two ways to set one
value is how the tier label and Renderer::DIFFICULTIES drifted apart before."
```

---

## Task 10 — `redoku --record`

**Files:** create `mrbgems/mruby-redoku/mrblib/redoku/recorder.rb`, create
`mrbgems/mruby-redoku/test/record.rb`, modify `main.rb` (the `--record`
flag and its loop), modify `recognizer.rb` (overlay the recorded set),
modify `renderer.rb` (the capture prompt screen).

**Interfaces produced:**

```
Recorder.new(rounds: 4)     -> a walk over rounds x 9 samples
Recorder#wanted             -> Integer 1..9, or nil when done
Recorder#accept(subpaths)   -> self
Recorder#done?              -> true/false
Recorder#samples            -> [[digit, subpaths], ...]
Recorder#to_text            -> String, one "digit\tx,y x,y|x,y" line per sample
Recorder.parse(text)        -> [[digit, subpaths], ...], corrupt lines skipped
Recorder::TARGET            = '/home/root/redoku/templates.local'
```

`File.read` is safe to use here — `IO.read` ships in `mruby-io`
(`tmp/mruby/mrbgems/mruby-io/mrblib/io.rb:124`), `File < IO`, the gem is
already declared in `mrbgem.rake`, and `mruby-rm2/mrblib/input.rb:23` already
depends on it.

- [ ] **Step 1: write the failing tests** — the recorder is a state machine
      and is testable on the host without a device:

```ruby
assert('the recorder walks 1..9 and asks for each in turn') do
  r = Redoku::Recorder.new(rounds: 2)
  assert_equal 1, r.wanted
  r.accept(sample_cloud)
  assert_equal 2, r.wanted
end

assert('the recorder finishes after rounds x 9 samples') do
  r = Redoku::Recorder.new(rounds: 2)
  18.times { r.accept(sample_cloud) }
  assert_true r.done?
  assert_equal 18, r.samples.size
end

assert('a recorded file round-trips through the codec') do
  r = Redoku::Recorder.new(rounds: 1)
  9.times { r.accept(sample_cloud) }
  text = r.to_text
  back = Redoku::Recorder.parse(text)
  assert_equal r.samples.size, back.size
  assert_equal r.samples[0][0], back[0][0]
  assert_equal r.samples[0][1], back[0][1]
end

assert('a corrupt line is skipped, not fatal') do
  back = Redoku::Recorder.parse("1\t10,10 20,20\nnonsense\n2\t30,30 40,40\n")
  assert_equal 2, back.size
end
```

Test helper for `test/record.rb`:

```ruby
def sample_cloud
  [[[300, 400], [340, 440], [340, 480]]]
end
```

- [ ] **Step 2: run and confirm RED**, then implement the recorder.

```ruby
module Redoku
  # `redoku --record` walks the player through writing each digit a few
  # times and saves the clouds, so the recognizer can be tuned to ONE hand
  # rather than to an average of many (PLAN.md §6). Kept as a plain state
  # machine with no display and no input in it, so the whole walk is
  # host-testable: main.rb owns the loop that feeds it strokes and paints
  # the prompt.
  class Recorder
    DIGITS  = 9
    DEFAULT_ROUNDS = 4
    TARGET  = '/home/root/redoku/templates.local'

    attr_reader :samples

    def initialize(rounds: DEFAULT_ROUNDS)
      @rounds = rounds
      @samples = []
    end

    # The digit being asked for right now, or nil when the walk is over.
    # Round-major: 1..9, then 1..9 again — not nine 1s in a row, because a
    # hand drilling the same glyph nine times drifts into a stylised
    # version of it that the player never writes in play.
    def wanted
      return nil if done?
      (@samples.size % DIGITS) + 1
    end

    def done?
      @samples.size >= @rounds * DIGITS
    end

    def accept(subpaths)
      return self if done?
      @samples << [wanted, subpaths]
      self
    end

    # One line per sample: digit, TAB, then the shared points codec. Text
    # and not binary for the reason M3a records at Store.encode_pts — the
    # SQLite binding reads TEXT with mrb_str_new_cstr, which truncates at
    # the first NUL, so this codebase has exactly one points encoding and
    # it is this one.
    def to_text
      out = ''
      @samples.each do |digit, subpaths|
        enc = Store.encode_pts(subpaths)
        next unless enc
        out = out + digit.to_s + "\t" + enc + "\n"
      end
      out
    end

    # A corrupt line is skipped, never fatal: this file is written on a
    # device that can lose power mid-write, and a half-written last line
    # must not cost the player the 35 good samples above it.
    def self.parse(text)
      out = []
      text.split("\n").each do |line|
        parts = line.split("\t")
        next unless parts.size == 2
        d = parts[0]
        next unless d.size == 1 && d >= '1' && d <= '9'
        subpaths = Store.decode_pts(parts[1])
        next unless subpaths
        out << [d.to_i, subpaths]
      end
      out
    end
  end
end
```

- [ ] **Step 3: wire `--record` into `main.rb`.** Add it to the `unknown`
      guard's allow-list *and* to `--help`'s text — the guard rejects any
      flag not in that list, so forgetting it makes the flag an error rather
      than a no-op:

```ruby
      --record    capture handwriting templates for the recognizer
      --clients   list the display server's clients and exit
      --help      show this message

      unknown = argv.find { |a| !['--help', '--clients', '--record'].include?(a) }
      ...
      return record_templates if argv.include?('--record')
```

- [ ] **Step 4: overlay the recorded set.** `Recognizer.template_features`
      builds from the authored set **plus** `templates.local` when it exists,
      so a recorded set tunes the recognizer without the shipped fallback
      ever being lost:

```ruby
    def self.build_template_features
      out = []
      add_features(out, Templates::AUTHORED)
      add_features(out, load_local)   # the player's own hand, on top
      out
    end

    # Missing file is the NORMAL case, not an error: nobody has recorded
    # anything on a fresh install, and the authored set is what ships.
    def self.load_local
      return [] unless File.exist?(Recorder::TARGET)
      Recorder.parse(File.read(Recorder::TARGET))
    rescue StandardError
      []
    end
```

- [ ] **Step 5: run and confirm GREEN**, then **commit.**

```bash
git add mrbgems/mruby-redoku/mrblib/redoku/recorder.rb \
        mrbgems/mruby-redoku/mrblib/redoku/main.rb \
        mrbgems/mruby-redoku/mrblib/redoku/recognizer.rb \
        mrbgems/mruby-redoku/test/record.rb
git commit -m "feat(m3b): redoku --record, so the recognizer learns one hand

Round-major (1..9, then 1..9) rather than nine 1s in a row: a hand
drilling one glyph drifts into a stylised version of it the player never
writes in play. The recorded set overlays the authored one instead of
replacing it, so a fresh install still reads digits, and a corrupt line is
skipped rather than fatal — this file is written on a device that can lose
power mid-write."
```

---

## Task 11 — Device session: record, corpus, tune  *(needs the owner and hardware)*

**Blocked on a human.** Everything before this is host-only; this task is the
one that needs the device and the owner's hand.

- [ ] **Step 1:** `make build`, `bin/redoku install`, `bin/redoku play` —
      confirm the build is clean and the game still runs (this also discharges
      M3a's still-pending device verification: resume round-trip and a
      battery-pull, PLAN.md §10).
- [ ] **Step 2:** run `redoku --record` for **4 rounds**, giving 36 samples.
- [ ] **Step 3:** pull `templates.local`, commit it as
      `mrbgems/mruby-redoku/mrblib/redoku/templates_recorded.rb` (the shipped
      set) **split train/holdout** — 3 rounds train, 1 round holdout. The
      holdout must not be in the shipped set, or the corpus test measures
      memorisation.
- [ ] **Step 4:** tune `ACCEPT_MAX` and `MARGIN_MIN` against the holdout,
      **optimising for zero false passes first** and accuracy second (spec
      §5). Record the tuned values and the numbers behind them in the ledger
      and in spec §5.
- [ ] **Step 5:** manual verify by hand, because nothing else can (PLAN.md
      §9 — the injection rig writes only `BTN_TOOL_PEN`, so no eraser event
      can be injected): write digits, erase some, quit, relaunch, confirm the
      erased ink is **gone** and the written ink is back. That is Task 3's
      only device-level proof and it exists nowhere in the suite.
- [ ] **Step 6: commit** the recorded templates and the tuned thresholds.

---

## Task 12 — Reconcile the documents

**Files:** modify `PLAN.md`, `docs/design/m3b-check-flow.md`,
`docs/plans/2026-08-25-m3-sqlite-saves.md`, `mrbgems/mruby-redoku/test/recognizer.rb`.

The repo's habit is that a plan's claims stay true after it ships. Three
documents currently disagree with the code this milestone leaves behind.

- [ ] **Step 1:** the **corpus test** §9 promises — recorded strokes must
      classify at or above the tuned threshold accuracy over whole boards, not
      per cell. Add it to `test/recognizer.rb` using Task 11's holdout.
- [ ] **Step 2: PLAN.md §6** — replace the $P pipeline description with what
      shipped, keeping $P on the record as the costed-and-narrowed
      alternative. Delete the "strokes fully inside a cell's bounds only"
      guard, which contradicts the same section's bounding-box-centre rule
      (spec §4).
- [ ] **Step 3: PLAN.md §7** — "Mistake checking" says right cells keep their
      ink. They no longer do. Rewrite it against spec §2 and note the check
      count.
- [ ] **Step 4: PLAN.md §10** — mark M3b's outcome, and correct M3a's entry:
      its ink persistence was incomplete, not merely device-unverified.
- [ ] **Step 5: the M3a plan's Task 6** — annotate the erase claim as
      superseded, with a pointer to spec §1 and Task 3. Do not silently edit
      it: the wrong reasoning is worth keeping visible, exactly as §6 keeps
      the rejected scribble gesture.
- [ ] **Step 6: spec §5** — fill in the measured numbers from Tasks 5, 6 and
      11, replacing the reasoned estimates with `[H]`-marked measurements.
- [ ] **Step 7: commit.**

---

## Out of scope (explicitly)

Carried from PLAN.md §10's v2 parking lot, restated so it is not re-argued:
live per-stroke recognition, pencil marks, a recognizer calibration UI,
statistics or a timer, undo, landscape. Plus, from this design: the check
count does not survive a relaunch (spec §3), and a retired stroke is never
un-retired (spec §9).

## Risks

1. **Stage 1's accuracy is unknown until Task 11.** The authored corpus in
   Task 5 can only prove the pipeline is sane, not that it reads a human
   hand. Mitigation: the gate in Task 5, the conditional Task 6, and the
   holdout split in Task 11. If both stages miss the bar on real ink, the
   fallback is arc-length resampling (noted in `spread_evenly`) before
   anything more exotic.
2. **`app.rb` is already 1482 lines and this adds to it.** Mitigation:
   constraint 7 — `Ink`, `Recognizer`, `Templates` and the recorder are new
   files. If `app.rb` crosses ~1700, split the CHECK pass out before Task 9
   rather than after.
3. **The waveform trap is easy to miss** and its failure mode is a ghost on
   the glass, which no host test can see. Mitigation: the explicit GL16
   assertion in Task 7 Step 1, and Task 11 Step 5's manual pass.
4. **Task 11 blocks on the owner.** Tasks 1–10 are host-only and deliver a
   working, testable CHECK on authored templates, so the milestone is useful
   before the device session — it is just not tuned.
