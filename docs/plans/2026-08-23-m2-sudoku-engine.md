# Milestone 2 — Sudoku Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate, rate and render real sudoku puzzles — so the board that
M1 paints stops being empty.

**Architecture:** A pure-Ruby engine with zero device dependencies, living in
`mruby-redoku/mrblib/redoku/sudoku/`. Candidate sets are **9-bit integer
masks**, not arrays or Sets: that choice is forced by what mruby actually
gives us (below) and it is also the fastest thing available on a Cortex-A7,
which matters because puzzle generation is the one user-visible pause in the
game. Four units — `Grid` (state), `Solver` (counting backtracker for
uniqueness), `Techniques` + `Rater` (human-technique solver for difficulty),
`Generator` (fill, dig, rate, retry) — then a rendering task that draws
digits into cells and wires generation into the existing event loop.

**Tech Stack:** mruby 4.0.0, pure Ruby, no new gem dependencies. mrbtest for
unit tests. No C in this milestone.

**Spec:** `PLAN.md` §7 (sudoku engine), §8 (screen layout & rendering), §10
(M2 definition). The spec travels with this plan; executors read both.

---

## Global Constraints

These are project-wide and every task's requirements implicitly include them.

**1. mrbtest dependency scoping — MEASURED, not assumed.** A gem's mrbtest
state holds only its *declared* dependencies, while the shipped binary links
the whole `default` gembox. So code using an undeclared gem's method passes
on the device and crashes under `make test`. This project has been bitten
three times (`String#start_with?`, `String#each_char`, `Integer#zero?`).
`mruby-redoku` declares `mruby-rm2` and `mruby-string-ext` only.

Probed empirically inside this gem's own mrbtest state on 2026-08-23 (a
throwaway `test/_zzprobe.rb`, run and deleted). **UNAVAILABLE — do not use:**

- `Array`: `combination` `permutation` `shuffle` `shuffle!` `sample` `sum`
  `uniq` `uniq!` `flatten` `compact` `each_slice` `each_cons` `minmax`
  `count` `none?` `one?` `find_index` `sort_by` `group_by`
  `each_with_object` `filter` `rotate` `product` `transpose` `zip`
  `delete_if` `insert` `fill` `take` `drop` `take_while` `drop_while`
  `tally` `flat_map` `assoc` `values_at` `fetch`
- `Integer`: `zero?` `positive?` `negative?` `odd?` `even?` `pow` `gcd`
  `lcm` `pred` `digits` `clamp`
- `String`: `%` `format`
- `Hash`: `each_pair` `fetch` `merge!` `each_with_object` `sort_by` `min_by`
  `max_by` `group_by` `count`
- `Kernel`: **`rand`** **`srand`** `catch` `throw` `format` `sprintf`
- Classes absent entirely: **`Set`**, **`Struct`**, **`Random`**

**AVAILABLE and used by this plan:** `Array#each` `#map` `#select` `#reject`
`#partition` `#find` `#index` `#rindex` `#min` `#max` `#sort` `#any?`
`#all?` `#reduce` `#inject` `#each_with_index` `#first` `#last` `#dup`
`#push` `#<<` `#pop` `#shift` `#unshift` `#concat` `#include?` `#empty?`
`#size` `#reverse` `#join` `#delete` `#delete_at` `#slice`;
`Integer#times` `#upto` `#downto` `#step` `#div` `#divmod` `#abs` `#succ`
`#to_s` `#between?`; `String#each_char` `#chars` `#split` `#to_i` `#*` `#+`
`#include?`; `Hash#each` `#keys` `#values` `#store` `#delete` `#size`
`#key?`; `Comparable`; `Enumerable`.

**Consequences baked into this plan, not left to the implementer:**
- Candidates are integer bitmasks. This is why no `Set`, `uniq` or
  `combination` is needed anywhere.
- Randomness is `Redoku::Rng`, ~15 lines of xorshift in Task 2. `rand` does
  not exist here, and adding `mruby-random` as a test dependency would
  renumber the generated test ireps and force a `make clean` on every
  contributor's tree (recorded pain: M1 fix wave A). A seeded PRNG is also
  strictly better for tests and for reproducing a reported puzzle.
- Write `x == 0`, never `x.zero?`. Write `n % 2 == 0`, never `n.even?`.
- Build strings by `+`/`<<`/`join`, never `%` or `format`.
- Lookup tables are built with `9.times` loops, not `(0..8).map`: `Range`
  was not probed, and a table that fails to build takes the whole gem down.

**2. Integer width.** `mrb_int` is 64-bit on the host and **32-bit on the
device**. Every mask in this milestone is ≤ 10 bits and every index ≤ 80, so
nothing here can overflow — but keep it that way: no packing 81 cells into
one integer.

**3. Test file naming.** `test/_support.rb`'s leading underscore is
load-bearing: mrbtest runs each `assert` block *as its file loads*, in
alphabetical order, so shared helpers must sort before their consumers. New
shared helpers go in `_support.rb`; new suites are named for their subject.

**4. Performance budget.** PLAN.md §7 allows "a few hundred ms per attempt"
for generation on the Cortex-A7, covered by a "generating…" splash. The
counting solver is the hot path and is called once per dug cell pair, so it
must early-exit at 2 solutions and use the
minimum-remaining-values heuristic. Tests assert the *behaviour*, not the
timing; timing is checked once on the device.

**5. No device dependency.** Tasks 1–4 must not reference `RM2`,
`Display`, `Layout` or `Renderer` at all. The engine is pure logic and its
tests run with no display mock. Task 5 is the only one that touches the
device-facing layer.

---

## File Structure

```
mrbgems/mruby-redoku/
├── mrblib/redoku/
│   ├── rng.rb              NEW  Task 2  seeded xorshift PRNG + shuffle
│   ├── sudoku/
│   │   ├── grid.rb         NEW  Task 1  81 cells, givens vs entries, units, peers
│   │   ├── solver.rb       NEW  Task 2  counting backtracker, MRV, early exit
│   │   ├── techniques.rb   NEW  Task 3  human techniques, hardest-needed
│   │   ├── rater.rb        NEW  Task 3  technique + clue count -> tier
│   │   └── generator.rb    NEW  Task 4  fill, symmetric dig, rate, retry
│   ├── renderer.rb         MOD  Task 5  draw_given / draw_entry / splash
│   └── app.rb              MOD  Task 5  hold a puzzle; New and Level generate
└── test/
    ├── _support.rb         MOD  Task 1  puzzle fixtures shared by 4 suites
    ├── rng.rb              NEW  Task 2
    ├── sudoku_grid.rb      NEW  Task 1
    ├── sudoku_solver.rb    NEW  Task 2
    ├── sudoku_techniques.rb NEW Task 3
    ├── sudoku_rater.rb     NEW  Task 3
    ├── sudoku_generator.rb NEW  Task 4
    ├── renderer.rb         MOD  Task 5
    └── app.rb              MOD  Task 5
```

`mrbgem.rake` is **not** modified: no new dependency is declared, which is
the point of the bitmask/own-PRNG design. `mrblib` files are picked up by
directory glob, so a new subdirectory needs no build wiring — verify this in
Task 1 Step 2 rather than assuming it.

---

## Representation, decided once here

Three shapes travel between tasks. Getting these names and types wrong is
how the tasks stop composing, so they are fixed now:

**`values`** — a bare 81-element `Array` of `Integer` 0..9, index
`row * 9 + col`, `0` meaning empty. This is what `Solver`, `Techniques`,
`Rater` and `Generator` all consume and return. Not a Grid: the solver is
called tens of thousands of times and must not allocate objects.

**`mask`** — an `Integer` whose bits 1..9 mean "digit d is possible".
`ALL = 0b1111111110 = 1022`. Bit 0 is unused on purpose so that
`1 << digit` needs no offset.

**`Grid`** — the game's stateful object, wrapping two `values`-shaped
arrays (`givens` and `entries`). Only Task 1 and Task 5 touch it; the
solving machinery never sees it.

---

### Task 1: Grid, board geometry, and the shared fixtures

**Files:**
- Create: `mrbgems/mruby-redoku/mrblib/redoku/sudoku/grid.rb`
- Create: `mrbgems/mruby-redoku/test/sudoku_grid.rb`
- Modify: `mrbgems/mruby-redoku/test/_support.rb` (append fixtures)

**Interfaces:**
- Consumes: nothing (first task).
- Produces, and later tasks rely on exactly these names:
  - `Redoku::Sudoku::Grid::ALL` = 1022, `::SIZE` = 81
  - `Grid.row_of(i)` / `.col_of(i)` / `.box_of(i)` → 0..8
  - `Grid::ROWS` / `::COLS` / `::BOXES` / `::UNITS` — `UNITS` is all 27,
    each a 9-element array of cell indices
  - `Grid::PEERS` — 81 arrays of 20 indices each
  - `Grid.candidates(values, i)` → mask of digits legal at `i`
  - `Grid.count_bits(mask)` → 0..9, `Grid.bits(mask)` → array of digits
  - `Grid.consistent?(values)` → no unit repeats a digit
  - `Grid.complete?(values)` → no zeros **and** consistent
  - `Grid.new(givens, entries = nil)`, `#given?(i)`, `#value_at(i)`,
    `#set_entry(i, d)`, `#clear_entry(i)`, `#values`, `#clue_count`,
    `#givens_s`, `#values_s`, `Grid.parse(str)`
  - Test fixtures in `_support.rb`: `SOLVED_81`, `EASY_81`, `UNIQUE_81`,
    `MULTI_81`, `grid_of(str)`

- [ ] **Step 1: Write the failing test for geometry**

Append to `mrbgems/mruby-redoku/test/sudoku_grid.rb`:

```ruby
assert('Grid geometry maps indices to rows, columns and boxes') do
  g = Redoku::Sudoku::Grid
  assert_equal 0, g.row_of(0)
  assert_equal 0, g.col_of(0)
  assert_equal 0, g.box_of(0)
  assert_equal 8, g.row_of(80)
  assert_equal 8, g.col_of(80)
  assert_equal 8, g.box_of(80)
  # Cell 30 is row 3, col 3 -> the centre box, which is box 4.
  assert_equal 3, g.row_of(30)
  assert_equal 3, g.col_of(30)
  assert_equal 4, g.box_of(30)
  # Box 2 is rows 0-2, cols 6-8. Cell 8 is row 0 col 8.
  assert_equal 2, g.box_of(8)
  # Every index is covered and box numbering is row-major over 3x3 blocks.
  assert_equal 1, g.box_of(3)
  assert_equal 3, g.box_of(27)
end

assert('Grid units are 27 nine-cell groups covering every cell three times') do
  g = Redoku::Sudoku::Grid
  assert_equal 9, g::ROWS.size
  assert_equal 9, g::COLS.size
  assert_equal 9, g::BOXES.size
  assert_equal 27, g::UNITS.size
  g::UNITS.each { |u| assert_equal 9, u.size }
  # Each cell appears in exactly three units: its row, its column, its box.
  seen = []
  81.times { seen << 0 }
  g::UNITS.each { |u| u.each { |i| seen[i] += 1 } }
  assert_true seen.all? { |n| n == 3 }
  # Rows and columns really are transposes of each other.
  assert_equal [0, 1, 2, 3, 4, 5, 6, 7, 8], g::ROWS[0]
  assert_equal [0, 9, 18, 27, 36, 45, 54, 63, 72], g::COLS[0]
  assert_equal [0, 1, 2, 9, 10, 11, 18, 19, 20], g::BOXES[0]
end

assert('Grid peers are the 20 cells a digit conflicts with') do
  g = Redoku::Sudoku::Grid
  assert_equal 81, g::PEERS.size
  g::PEERS.each { |p| assert_equal 20, p.size }
  # A cell is never its own peer, and peership is symmetric.
  81.times do |i|
    assert_false g::PEERS[i].include?(i)
  end
  assert_true g::PEERS[0].include?(1)   # same row
  assert_true g::PEERS[0].include?(9)   # same column
  assert_true g::PEERS[0].include?(10)  # same box
  assert_false g::PEERS[0].include?(80) # shares nothing
  assert_true g::PEERS[10].include?(0)
end
```

- [ ] **Step 2: Run it and confirm a real RED, including the build wiring**

Run: `make test`
Expected: `NameError: uninitialized constant Redoku::Sudoku`.

This step doubles as the check that `mrblib/redoku/sudoku/*.rb` is compiled
at all. If the failure is instead that the suite never runs, the mrblib glob
does not recurse into subdirectories and `mrbgem.rake` needs an explicit
`spec.rbfiles` — find that out now, not in Task 4.

- [ ] **Step 3: Implement geometry**

Create `mrblib/redoku/sudoku/grid.rb`:

```ruby
module Redoku
  module Sudoku
    # An 81-cell sudoku board, plus the board geometry every other unit in
    # the engine asks it for.
    #
    # Two shapes live here and they are not the same thing:
    #
    #   `values` — a bare 81-element Array of 0..9, index row * 9 + col,
    #   0 meaning empty. This is the engine's working currency: Solver,
    #   Techniques, Rater and Generator all take and return one. It is a
    #   plain Array on purpose — the counting solver touches it tens of
    #   thousands of times per generated puzzle and must not allocate.
    #
    #   A `Grid` instance — the game's state, which is `values` split in
    #   two: the givens the puzzle came with, and the entries the player
    #   wrote. Keeping them apart is what lets the renderer print givens
    #   heavier (PLAN.md §8) and what stops the player editing a clue.
    #
    # Candidate sets are integer bitmasks, bit d set meaning "digit d is
    # still possible". Bit 0 is deliberately unused so that the bit for
    # digit d is exactly `1 << d` with no offset arithmetic. Masks rather
    # than Sets or Arrays because mruby's mrbtest state for this gem has
    # neither Set nor Array#uniq/#combination, and because bitwise ops are
    # the fastest thing on the device's Cortex-A7 — generation is the one
    # pause the player sees.
    class Grid
      SIZE = 81
      ALL = 0b1111111110 # digits 1..9, bit 0 unused

      # Built with explicit `times` loops rather than (0..8).map: Range's
      # methods are not in this gem's measured mrbtest surface, and a
      # constant that fails to build takes the whole gem down at load.
      ROWS = [].tap do |rows|
        9.times do |r|
          row = []
          9.times { |c| row << r * 9 + c }
          rows << row
        end
      end

      COLS = [].tap do |cols|
        9.times do |c|
          col = []
          9.times { |r| col << r * 9 + c }
          cols << col
        end
      end

      # Box b covers rows 3*(b/3)..+2 and cols 3*(b%3)..+2, so boxes are
      # numbered row-major over the 3x3 blocks: 0 1 2 / 3 4 5 / 6 7 8.
      BOXES = [].tap do |boxes|
        9.times do |b|
          box = []
          base_r = (b / 3) * 3
          base_c = (b % 3) * 3
          3.times do |dr|
            3.times { |dc| box << (base_r + dr) * 9 + base_c + dc }
          end
          boxes << box
        end
      end

      UNITS = ROWS + COLS + BOXES

      # The 20 cells that may not repeat this cell's digit: 8 in its row,
      # 8 in its column, and the 4 remaining cells of its box. Built by
      # union rather than by arithmetic so it cannot disagree with UNITS.
      PEERS = [].tap do |peers|
        SIZE.times do |i|
          set = []
          UNITS.each do |unit|
            next unless unit.include?(i)
            unit.each { |j| set << j if j != i && !set.include?(j) }
          end
          peers << set
        end
      end

      def self.row_of(i)
        i / 9
      end

      def self.col_of(i)
        i % 9
      end

      def self.box_of(i)
        (i / 27) * 3 + (i % 9) / 3
      end
    end
  end
end
```

- [ ] **Step 4: Run the geometry tests**

Run: `make test`
Expected: the three geometry assertions PASS.

- [ ] **Step 5: Write the failing test for masks and validity**

Append to `test/sudoku_grid.rb`:

```ruby
assert('Grid.count_bits and Grid.bits read a candidate mask') do
  g = Redoku::Sudoku::Grid
  assert_equal 0, g.count_bits(0)
  assert_equal 9, g.count_bits(g::ALL)
  assert_equal [1, 2, 3, 4, 5, 6, 7, 8, 9], g.bits(g::ALL)
  assert_equal [], g.bits(0)
  assert_equal 1, g.count_bits(1 << 5)
  assert_equal [5], g.bits(1 << 5)
  assert_equal 2, g.count_bits((1 << 1) | (1 << 9))
  assert_equal [1, 9], g.bits((1 << 1) | (1 << 9))
  # Bit 0 is not a digit and must never be reported.
  assert_equal 0, g.count_bits(1)
  assert_equal [], g.bits(1)
end

assert('Grid.candidates excludes every peer digit') do
  g = Redoku::Sudoku::Grid
  values = []
  81.times { values << 0 }
  assert_equal g::ALL, g.candidates(values, 0)
  values[1] = 3   # same row
  values[9] = 4   # same column
  values[10] = 5  # same box
  values[80] = 6  # shares nothing with cell 0
  mask = g.candidates(values, 0)
  assert_equal [1, 2, 6, 7, 8, 9], g.bits(mask)
  # An already-filled cell still reports what would be legal there, which
  # is what the technique solver needs; callers skip filled cells.
  assert_equal g::ALL, g.candidates(values, 40)
end

assert('Grid.consistent? and Grid.complete? judge a values array') do
  g = Redoku::Sudoku::Grid
  solved = solved_values
  assert_true g.consistent?(solved)
  assert_true g.complete?(solved)

  empty = []
  81.times { empty << 0 }
  assert_true g.consistent?(empty)   # nothing repeats
  assert_false g.complete?(empty)    # but it is not finished

  clash = solved.dup
  # Break row 0 by copying cell 1's digit over cell 0.
  clash[0] = clash[1]
  assert_false g.consistent?(clash)
  assert_false g.complete?(clash)
end
```

- [ ] **Step 6: Add the shared fixtures**

Append to `test/_support.rb`. These four boards are used by Tasks 1–4, which
is why they live in the shared helper rather than in one suite.

```ruby
# --- sudoku fixtures, shared by the grid, solver, technique and generator
# suites. 81 characters, '.' for an empty cell, read row-major.

# A complete, valid solution. Rows are the classic shift-by-3 pattern, which
# is a genuine sudoku solution and easy to re-derive by hand if it is ever
# doubted.
SOLVED_81 =
  '123456789' \
  '456789123' \
  '789123456' \
  '214365897' \
  '365897214' \
  '897214365' \
  '531642978' \
  '642978531' \
  '978531642'

# Solvable by naked and hidden singles alone: the Rater must call this easy.
EASY_81 =
  '.23456789' \
  '456789123' \
  '789123456' \
  '214365897' \
  '365897214' \
  '897214365' \
  '531642978' \
  '642978531' \
  '97853164.'

# Exactly one solution, but with enough removed that the counting solver has
# to search rather than propagate.
UNIQUE_81 =
  '....56789' \
  '456789123' \
  '789123456' \
  '214365897' \
  '365897214' \
  '897214365' \
  '531642978' \
  '642978531' \
  '9785316..'

# Two or more solutions: only four digits given, so the board is wide open.
MULTI_81 =
  '1........' \
  '.........' \
  '.........' \
  '.........' \
  '....5....' \
  '.........' \
  '.........' \
  '.........' \
  '........9'

def values_of(str)
  out = []
  str.each_char { |ch| out << (ch == '.' ? 0 : ch.to_i) }
  out
end

def solved_values
  values_of(SOLVED_81)
end

def grid_of(str)
  Redoku::Sudoku::Grid.parse(str)
end
```

- [ ] **Step 7: Run it and confirm RED**

Run: `make test`
Expected: FAIL — `undefined method 'count_bits'`, and the fixture
assertions fail on `Grid.parse`.

Also expected and worth pausing on: `assert_true g.consistent?(solved)`
proves `SOLVED_81` is a real solution. If that assertion fails, the fixture
is wrong, not the code — fix the fixture before going on, because Tasks 2–4
all trust it.

- [ ] **Step 8: Implement masks, validity and the Grid instance**

Add to `grid.rb`, inside `class Grid`:

```ruby
      # Digits still legal at cell i: ALL minus every digit already taken by
      # a peer. Reads the cell's own value not at all, so a caller may ask
      # about a filled cell (the technique solver does).
      def self.candidates(values, i)
        mask = ALL
        PEERS[i].each do |j|
          d = values[j]
          mask &= ~(1 << d) if d != 0
        end
        mask
      end

      # Bit 0 is not a digit, so both of these start at 1. A nine-iteration
      # loop beats any cleverness at this width, and Integer#digits and the
      # popcount idioms are not available here anyway.
      def self.count_bits(mask)
        n = 0
        d = 1
        while d <= 9
          n += 1 if (mask & (1 << d)) != 0
          d += 1
        end
        n
      end

      def self.bits(mask)
        out = []
        d = 1
        while d <= 9
          out << d if (mask & (1 << d)) != 0
          d += 1
        end
        out
      end

      # No unit repeats a digit. Empty cells are ignored, so a partially
      # filled board can be consistent without being complete.
      def self.consistent?(values)
        UNITS.each do |unit|
          seen = 0
          unit.each do |i|
            d = values[i]
            next if d == 0
            bit = 1 << d
            return false if (seen & bit) != 0
            seen |= bit
          end
        end
        true
      end

      def self.complete?(values)
        values.each { |d| return false if d == 0 }
        consistent?(values)
      end

      # `givens` and `entries` are values-shaped arrays. Both are copied:
      # a Grid that shared its caller's array would let a solver's scratch
      # buffer mutate the player's board.
      def initialize(givens, entries = nil)
        @givens = givens.dup
        @entries = entries ? entries.dup : Array.new(SIZE, 0)
      end

      # '.' or '0' for an empty cell; every other digit becomes a given.
      def self.parse(str)
        givens = []
        str.each_char do |ch|
          givens << (ch == '.' || ch == '0' ? 0 : ch.to_i)
        end
        raise "grid needs #{SIZE} cells, got #{givens.size}" if givens.size != SIZE
        new(givens)
      end

      def given?(i)
        @givens[i] != 0
      end

      def value_at(i)
        @givens[i] != 0 ? @givens[i] : @entries[i]
      end

      # A given is the puzzle, not the player's work, so writing over one is
      # refused rather than ignored: the caller has a bug, and silently
      # dropping the write would hide it.
      def set_entry(i, digit)
        raise "cell #{i} is a given" if given?(i)
        @entries[i] = digit
        self
      end

      def clear_entry(i)
        @entries[i] = 0 unless given?(i)
        self
      end

      def empty?(i)
        value_at(i) == 0
      end

      # The board as the engine wants it: one flat 81-array, givens and
      # entries merged, which is what Solver and Techniques consume.
      def values
        out = []
        SIZE.times { |i| out << value_at(i) }
        out
      end

      def givens
        @givens.dup
      end

      def clue_count
        n = 0
        @givens.each { |d| n += 1 if d != 0 }
        n
      end

      def givens_s
        str_of(@givens)
      end

      def values_s
        str_of(values)
      end

      def solved?
        Grid.complete?(values)
      end

      private

      def str_of(list)
        s = ''
        list.each { |d| s = s + (d == 0 ? '.' : d.to_s) }
        s
      end
```

Note `Array.new(SIZE, 0)` — verify in Step 9 that the two-argument form
exists here. If it does not, replace with an explicit
`[].tap { |a| SIZE.times { a << 0 } }`.

- [ ] **Step 9: Run the tests**

Run: `make test`
Expected: all Task 1 assertions PASS, KO 0, Crash 0, Warning 0.

- [ ] **Step 10: Write the failing test for the Grid instance**

Append to `test/sudoku_grid.rb`:

```ruby
assert('Grid keeps givens and entries apart') do
  grid = grid_of(EASY_81)
  assert_false grid.given?(0)         # EASY_81 starts with '.'
  assert_true grid.given?(1)
  assert_equal 0, grid.value_at(0)
  assert_equal 2, grid.value_at(1)
  assert_equal 79, grid.clue_count   # 81 cells less the two blanks

  grid.set_entry(0, 7)
  assert_equal 7, grid.value_at(0)
  assert_false grid.given?(0)        # writing an entry never creates a given
  assert_equal EASY_81, grid.givens_s # givens are untouched by an entry

  grid.clear_entry(0)
  assert_equal 0, grid.value_at(0)

  # A given is the puzzle, not the player's to edit.
  err = nil
  begin
    grid.set_entry(1, 5)
  rescue StandardError => e
    err = e
  end
  assert_true !err.nil?
  assert_equal 2, grid.value_at(1)
end

assert('Grid serialises to 81 characters and back') do
  grid = grid_of(EASY_81)
  assert_equal 81, grid.givens_s.size
  assert_equal EASY_81, grid.givens_s
  # values_s shows the merged board, so with no entries it equals the givens.
  assert_equal EASY_81, grid.values_s
  grid.set_entry(0, 1)
  assert_equal '1' + EASY_81.slice(1, 80), grid.values_s
  assert_equal EASY_81, grid.givens_s

  # A round trip through parse preserves the givens exactly.
  assert_equal EASY_81, grid_of(grid.givens_s).givens_s

  # Solved detection is the merged board, entries included.
  full = grid_of(SOLVED_81)
  assert_true full.solved?
  assert_false grid_of(EASY_81).solved?
end

assert('Grid copies its inputs so a solver buffer cannot alias the board') do
  givens = values_of(EASY_81)
  grid = Redoku::Sudoku::Grid.new(givens)
  givens[0] = 9
  assert_equal 0, grid.value_at(0)
  # And the array handed out is a copy too.
  out = grid.values
  out[5] = 0
  assert_equal 6, grid.value_at(5)
end
```

- [ ] **Step 11: Run, confirm RED then GREEN**

Run: `make test` before and after each fix. Expected finally: PASS.

If `EASY_81`'s `clue_count` is not 79, count the dots in the fixture and
correct the assertion to match the fixture — do not adjust the fixture to
match a guessed number, because Task 3 rates this board.

- [ ] **Step 12: Commit**

```bash
git add mrbgems/mruby-redoku/mrblib/redoku/sudoku/grid.rb \
        mrbgems/mruby-redoku/test/sudoku_grid.rb \
        mrbgems/mruby-redoku/test/_support.rb
git commit -m "feat(redoku): add sudoku Grid, board geometry and bitmask candidates"
```

---

### Task 2: Seeded RNG and the counting backtracker

**Files:**
- Create: `mrbgems/mruby-redoku/mrblib/redoku/rng.rb`
- Create: `mrbgems/mruby-redoku/mrblib/redoku/sudoku/solver.rb`
- Create: `mrbgems/mruby-redoku/test/rng.rb`
- Create: `mrbgems/mruby-redoku/test/sudoku_solver.rb`

**Interfaces:**
- Consumes: `Grid::SIZE`, `Grid.candidates`, `Grid.count_bits`,
  `Grid.bits`, `Grid.complete?`, fixtures `SOLVED_81` / `EASY_81` /
  `UNIQUE_81` / `MULTI_81`, `values_of`.
- Produces:
  - `Redoku::Rng.new(seed)`, `#next_int(n)` → 0...n, `#shuffle(array)` → a
    new shuffled array
  - `Redoku::Sudoku::Solver.solve(values, rng = nil)` → a solved values
    array, or `nil`
  - `Redoku::Sudoku::Solver.count(values, limit = 2)` → Integer, never
    exceeding `limit`
  - `Solver.unique?(values)` → `count(values, 2) == 1`

- [ ] **Step 1: Write the failing RNG test**

Create `test/rng.rb`:

```ruby
assert('Rng is deterministic for a seed and varies across seeds') do
  a = Redoku::Rng.new(12345)
  b = Redoku::Rng.new(12345)
  10.times { assert_equal a.next_int(1000), b.next_int(1000) }

  c = Redoku::Rng.new(999)
  d = Redoku::Rng.new(12345)
  # Not a guarantee for any single draw, so compare a run of them.
  first = []
  second = []
  10.times { first << c.next_int(1000) }
  10.times { second << d.next_int(1000) }
  assert_false first == second
end

assert('Rng.next_int stays inside its bound and reaches both ends') do
  r = Redoku::Rng.new(7)
  200.times do
    n = r.next_int(10)
    assert_true n >= 0
    assert_true n < 10
  end
  # n == 1 is the degenerate bound and must not loop or divide by zero.
  assert_equal 0, r.next_int(1)

  # Over many draws every bucket of a small range should appear; a generator
  # stuck on one value passes the bounds check above but is useless.
  seen = {}
  r2 = Redoku::Rng.new(3)
  300.times { seen.store(r2.next_int(5), true) }
  assert_equal 5, seen.keys.size
end

assert('Rng.shuffle permutes without losing or duplicating elements') do
  source = []
  20.times { |i| source << i }
  r = Redoku::Rng.new(42)
  out = r.shuffle(source)

  assert_equal source.size, out.size
  assert_equal source, out.sort          # same multiset
  assert_false source == out             # and actually reordered
  assert_equal 20, source.size           # input not mutated
  assert_equal 0, source[0]

  # Same seed, same permutation.
  assert_equal r_shuffle_with_seed(source, 5), r_shuffle_with_seed(source, 5)
  assert_false r_shuffle_with_seed(source, 5) == r_shuffle_with_seed(source, 6)
end
```

Add this helper to `test/_support.rb`:

```ruby
def r_shuffle_with_seed(list, seed)
  Redoku::Rng.new(seed).shuffle(list)
end
```

- [ ] **Step 2: Run it and confirm RED**

Run: `make test`
Expected: `NameError: uninitialized constant Redoku::Rng`.

- [ ] **Step 3: Implement the RNG**

Create `mrblib/redoku/rng.rb`:

```ruby
module Redoku
  # A seeded pseudo-random generator, ~20 lines, because `Kernel#rand` does
  # not exist in this gem's mrbtest state and `mruby-random` cannot be
  # borrowed for free: declaring a new test dependency renumbers the
  # generated test ireps, so every contributor's incremental build stops
  # compiling until they `make clean` (this cost was paid once already, in
  # M1's fix wave A, and is not worth paying again for `rand`).
  #
  # Being seeded is a feature and not a consolation. Generation is a
  # search, so a bug in it is a bug in one particular puzzle; a seed makes
  # that puzzle reproducible in a test instead of a story. It also means the
  # host and the device produce identical boards for identical seeds.
  #
  # xorshift32: three shifts and three xors, a period of 2**32 - 1, and far
  # better distribution than an LCG's low bits. Nothing here is
  # cryptographic and nothing here needs to be — it picks which empty cell
  # to try first.
  class Rng
    MASK32 = 0xffffffff

    def initialize(seed = 1)
      # State must never be zero: xorshift maps 0 to 0 and the generator
      # would emit nothing but zeros for ever. Any seed is acceptable to
      # callers, so it is corrected here rather than rejected.
      s = seed.abs & MASK32
      @state = s == 0 ? 0x9e3779b9 : s
    end

    # 0 <= result < n. Uses the HIGH bits: xorshift32's low bits are its
    # weakest, and `% n` would lean on exactly those.
    def next_int(n)
      return 0 if n <= 1
      (next_u32 >> 8) % n
    end

    # Fisher-Yates over a copy, walked downwards so each position draws from
    # the untouched head. Returns a new array: callers shuffle constants
    # (Grid::UNITS, the dig order) and must not have them rewritten.
    def shuffle(list)
      out = list.dup
      i = out.size - 1
      while i > 0
        j = next_int(i + 1)
        tmp = out[i]
        out[i] = out[j]
        out[j] = tmp
        i -= 1
      end
      out
    end

    private

    def next_u32
      x = @state
      x = (x ^ (x << 13)) & MASK32
      x = x ^ (x >> 17)
      x = (x ^ (x << 5)) & MASK32
      @state = x
      x
    end
  end
end
```

- [ ] **Step 4: Run the RNG tests**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Write the failing solver test**

Create `test/sudoku_solver.rb`:

```ruby
assert('Solver.solve completes a solvable board and leaves it valid') do
  s = Redoku::Sudoku::Solver
  g = Redoku::Sudoku::Grid

  # An already-solved board comes back unchanged.
  solved = solved_values
  out = s.solve(solved)
  assert_equal solved, out

  # A board with two holes is filled to a complete, consistent grid.
  easy = values_of(EASY_81)
  out = s.solve(easy)
  assert_true g.complete?(out)
  # Every given is preserved.
  81.times { |i| assert_equal easy[i], out[i] if easy[i] != 0 }

  # A wide-open board is still solvable.
  empty = []
  81.times { empty << 0 }
  assert_true g.complete?(s.solve(empty))
end

assert('Solver.solve does not mutate the board it was given') do
  easy = values_of(EASY_81)
  before = easy.dup
  Redoku::Sudoku::Solver.solve(easy)
  assert_equal before, easy
end

assert('Solver.solve returns nil for a contradictory board') do
  s = Redoku::Sudoku::Solver
  bad = values_of(EASY_81)
  # Cell 0 is empty in EASY_81 and its row already holds 2..9, so the only
  # digit that fits is 1. Force a 2 into it and the board is unsolvable.
  bad[0] = 2
  assert_nil s.solve(bad)

  # A board with no candidate anywhere in an empty cell fails immediately.
  wedged = []
  81.times { wedged << 0 }
  # Fill row 0 with 1..8 and column 0 with 9 below, leaving cell 8 with
  # nothing legal.
  8.times { |c| wedged[c] = c + 1 }
  wedged[17] = 9
  wedged[26] = 9 if false # keep the fixture honest: one blocker is enough
  assert_nil s.solve(wedged) if Redoku::Sudoku::Grid.candidates(wedged, 8) == 0
end

assert('Solver.count stops at its limit and recognises uniqueness') do
  s = Redoku::Sudoku::Solver

  # A solved board has exactly one solution: itself.
  assert_equal 1, s.count(solved_values)
  assert_true s.unique?(solved_values)

  # EASY_81 and UNIQUE_81 are both proper puzzles.
  assert_equal 1, s.count(values_of(EASY_81))
  assert_true s.unique?(values_of(EASY_81))
  assert_equal 1, s.count(values_of(UNIQUE_81))
  assert_true s.unique?(values_of(UNIQUE_81))

  # MULTI_81 has many solutions, and count must SAY 2 rather than counting
  # them all: the early exit is the whole point of this method.
  assert_equal 2, s.count(values_of(MULTI_81))
  assert_false s.unique?(values_of(MULTI_81))

  # The limit is honoured for a higher ceiling too.
  assert_equal 5, s.count(values_of(MULTI_81), 5)

  # An unsolvable board has zero.
  bad = values_of(EASY_81)
  bad[0] = 2
  assert_equal 0, s.count(bad)
  assert_false s.unique?(bad)
end

assert('Solver.solve with an Rng varies its answer but stays correct') do
  s = Redoku::Sudoku::Solver
  g = Redoku::Sudoku::Grid
  empty = []
  81.times { empty << 0 }

  a = s.solve(empty, Redoku::Rng.new(1))
  b = s.solve(empty, Redoku::Rng.new(2))
  assert_true g.complete?(a)
  assert_true g.complete?(b)
  # Two seeds should not agree on a full board; if they do, the rng is not
  # reaching the digit ordering and generation would produce one puzzle.
  assert_false a == b

  # Same seed, same board.
  assert_equal s.solve(empty, Redoku::Rng.new(1)), a
end
```

- [ ] **Step 6: Run it and confirm RED**

Run: `make test`
Expected: `NameError: uninitialized constant Redoku::Sudoku::Solver`.

- [ ] **Step 7: Implement the solver**

Create `mrblib/redoku/sudoku/solver.rb`:

```ruby
module Redoku
  module Sudoku
    # The machine solver: depth-first search over candidate bitmasks. Two
    # entry points, and the difference between them is the whole reason
    # this class exists rather than one `solve`:
    #
    #   `solve`  — find one solution, used to build a full board before
    #              digging and to store the answer for mistake checking.
    #   `count`  — how many solutions are there, up to a limit. Generation
    #              calls this once per dug cell pair and only ever needs to
    #              know "exactly one or more than one", so it early-exits at
    #              2 and never counts the rest. On a nearly-empty board the
    #              full count runs into the billions, so the limit is not an
    #              optimisation, it is what makes digging terminate.
    #
    # Both pick the most-constrained empty cell first (minimum remaining
    # values). That single heuristic is the difference between a generator
    # that takes a few hundred milliseconds on the Cortex-A7 and one that
    # takes minutes: it fails a doomed branch after a handful of levels
    # instead of exploring it to depth 60.
    #
    # Neither entry point mutates its argument.
    class Solver
      def self.solve(values, rng = nil)
        work = values.dup
        search(work, rng) ? work : nil
      end

      # Returns min(actual solutions, limit).
      def self.count(values, limit = 2)
        work = values.dup
        tally(work, limit, nil)
      end

      def self.unique?(values)
        count(values, 2) == 1
      end

      # The most constrained empty cell, as [index, mask], or nil when the
      # board is full. Returns immediately on a cell with a single
      # candidate — nothing can beat one — and reports a contradiction as a
      # zero mask, which both callers treat as a dead branch.
      def self.best_cell(values)
        best_i = nil
        best_mask = 0
        best_n = 10
        i = 0
        while i < Grid::SIZE
          if values[i] == 0
            mask = Grid.candidates(values, i)
            n = Grid.count_bits(mask)
            return [i, mask] if n <= 1
            if n < best_n
              best_n = n
              best_mask = mask
              best_i = i
            end
          end
          i += 1
        end
        best_i.nil? ? nil : [best_i, best_mask]
      end

      # Depth-first, in place, restoring the cell on the way out so `work`
      # is left exactly as found on a failed branch.
      def self.search(work, rng)
        cell = best_cell(work)
        return true if cell.nil? # no empty cell left: solved
        i, mask = cell
        digits = Grid.bits(mask)
        return false if digits.empty?
        digits = rng.shuffle(digits) if rng
        digits.each do |d|
          work[i] = d
          return true if search(work, rng)
          work[i] = 0
        end
        false
      end

      # Same search, but it keeps going after a hit instead of returning,
      # and stops the moment `limit` solutions have been seen.
      def self.tally(work, limit, rng)
        cell = best_cell(work)
        return 1 if cell.nil?
        i, mask = cell
        digits = Grid.bits(mask)
        return 0 if digits.empty?
        digits = rng.shuffle(digits) if rng
        found = 0
        digits.each do |d|
          work[i] = d
          found += tally(work, limit - found, rng)
          work[i] = 0
          return found if found >= limit
        end
        found
      end

      private_class_method :search, :tally, :best_cell
    end
  end
end
```

Note: `private_class_method` may not exist in this mrbtest state. Step 8
finds out. If it raises `NoMethodError`, drop that line and leave the three
helpers public with a comment saying they are internal — a missing access
modifier is not worth a dependency.

- [ ] **Step 8: Run the solver tests**

Run: `make test`
Expected: PASS. If `Solver.count(MULTI_81)` returns something other than 2,
the early exit is wrong: `tally` must stop as soon as `found >= limit`, and
must pass the *remaining* budget down, not the original.

- [ ] **Step 9: Commit**

```bash
git add mrbgems/mruby-redoku/mrblib/redoku/rng.rb \
        mrbgems/mruby-redoku/mrblib/redoku/sudoku/solver.rb \
        mrbgems/mruby-redoku/test/rng.rb \
        mrbgems/mruby-redoku/test/sudoku_solver.rb \
        mrbgems/mruby-redoku/test/_support.rb
git commit -m "feat(redoku): add seeded Rng and the counting sudoku solver"
```

---

### Task 3: Technique solver and difficulty rating

**Files:**
- Create: `mrbgems/mruby-redoku/mrblib/redoku/sudoku/techniques.rb`
- Create: `mrbgems/mruby-redoku/mrblib/redoku/sudoku/rater.rb`
- Create: `mrbgems/mruby-redoku/test/sudoku_techniques.rb`
- Create: `mrbgems/mruby-redoku/test/sudoku_rater.rb`

**Interfaces:**
- Consumes: `Grid` geometry and mask helpers, `Solver.unique?`, fixtures.
- Produces:
  - `Techniques::ORDER` = `[:naked_single, :hidden_single, :naked_pair,
    :hidden_pair, :pointing]` — cheapest first, and the rank used for
    "hardest needed"
  - `Techniques.solve(values)` → `{ values:, solved:, hardest: }` where
    `hardest` is a symbol from `ORDER` or `nil` (nothing was needed)
  - `Rater::TIERS` = `[:easy, :medium, :hard]`
  - `Rater.rate(values)` → `:easy` | `:medium` | `:hard`

- [ ] **Step 1: Write the failing technique test**

Create `test/sudoku_techniques.rb`:

```ruby
assert('Techniques.solve finishes a singles-only board and says so') do
  t = Redoku::Sudoku::Techniques
  result = t.solve(values_of(EASY_81))
  assert_true result[:solved]
  assert_true Redoku::Sudoku::Grid.complete?(result[:values])
  # EASY_81 has two holes, each forced, so singles are enough.
  assert_true [:naked_single, :hidden_single].include?(result[:hardest])
end

assert('Techniques.solve reports nil hardest for an already-solved board') do
  result = Redoku::Sudoku::Techniques.solve(solved_values)
  assert_true result[:solved]
  assert_nil result[:hardest]
end

assert('Techniques.solve stalls rather than guessing') do
  t = Redoku::Sudoku::Techniques
  # MULTI_81 cannot be solved by logic at all: it has many solutions, so no
  # technique can force any cell. The solver must stop, not search.
  result = t.solve(values_of(MULTI_81))
  assert_false result[:solved]
  # And it must not have invented anything: the board it returns is still
  # consistent and still has the four givens it started with.
  assert_true Redoku::Sudoku::Grid.consistent?(result[:values])
  assert_equal 1, result[:values][0]
  assert_equal 5, result[:values][40]
  assert_equal 9, result[:values][80]
end

assert('Techniques.solve does not mutate its input') do
  before = values_of(EASY_81)
  copy = before.dup
  Redoku::Sudoku::Techniques.solve(before)
  assert_equal copy, before
end

assert('naked single fills a cell with one candidate') do
  t = Redoku::Sudoku::Techniques
  values = solved_values
  values[40] = 0 # one hole: exactly one digit fits
  result = t.solve(values)
  assert_true result[:solved]
  assert_equal :naked_single, result[:hardest]
  assert_equal solved_values, result[:values]
end

assert('hidden single fills a digit with one home in its unit') do
  t = Redoku::Sudoku::Techniques
  # A hidden single needs a cell with several candidates where one digit has
  # nowhere else in the unit to go. Build it by emptying a whole row: each
  # cell then has one candidate anyway, so instead empty a row and a column
  # crossing it, which leaves genuine multi-candidate cells.
  values = solved_values
  Redoku::Sudoku::Grid::ROWS[0].each { |i| values[i] = 0 }
  Redoku::Sudoku::Grid::COLS[0].each { |i| values[i] = 0 }
  result = t.solve(values)
  assert_true result[:solved]
  assert_equal solved_values, result[:values]
  # Whatever rank it needed, it must be a real technique from ORDER.
  assert_true t::ORDER.include?(result[:hardest])
end

assert('Techniques.solve never writes a digit that breaks the board') do
  t = Redoku::Sudoku::Techniques
  g = Redoku::Sudoku::Grid
  # Empty a scattering of cells and check the partial result stays legal
  # even when the techniques cannot finish.
  values = solved_values
  [0, 4, 8, 30, 40, 50, 72, 76, 80].each { |i| values[i] = 0 }
  result = t.solve(values)
  assert_true g.consistent?(result[:values])
  # Every digit it did write agrees with the unique solution.
  solution = solved_values
  81.times do |i|
    v = result[:values][i]
    assert_equal solution[i], v if v != 0
  end
end
```

- [ ] **Step 2: Run it and confirm RED**

Run: `make test`
Expected: `NameError: uninitialized constant Redoku::Sudoku::Techniques`.

- [ ] **Step 3: Implement the technique solver**

Create `mrblib/redoku/sudoku/techniques.rb`:

```ruby
module Redoku
  module Sudoku
    # A solver that only does what a person would do, used for one purpose:
    # rating. It never guesses and never searches, so if it stalls, the
    # puzzle needs more than the techniques listed here — and that stall is
    # exactly what makes a puzzle "hard" (see Rater).
    #
    # The techniques are applied cheapest-first and the loop restarts from
    # the top after any progress, because a naked single opened up by a
    # pointing pair should be found by the cheap rule, not attributed to the
    # expensive one. `hardest` therefore records the most expensive rule
    # that was ever actually *needed*, which is the difficulty signal.
    #
    # Candidates are recomputed from the board rather than maintained
    # incrementally. That is more work per pass and much harder to get
    # wrong: an incremental candidate grid that drifts out of step with the
    # board produces a wrong difficulty rating, silently.
    class Techniques
      ORDER = [:naked_single, :hidden_single, :naked_pair, :hidden_pair,
               :pointing].freeze

      def self.solve(values)
        work = values.dup
        hardest = nil
        loop do
          step = apply_cheapest(work)
          break if step.nil?
          hardest = step if rank(step) > rank(hardest)
        end
        { values: work, solved: Grid.complete?(work), hardest: hardest }
      end

      # -1 for nil so any real technique outranks "nothing needed yet".
      def self.rank(name)
        name.nil? ? -1 : ORDER.index(name)
      end

      # Tries each technique in order and returns the name of the first one
      # that changed anything, or nil if none did. Candidates are rebuilt
      # once per call and shared by every rule in that pass.
      def self.apply_cheapest(work)
        cand = candidate_grid(work)
        return :naked_single if naked_single(work, cand)
        return :hidden_single if hidden_single(work, cand)
        return :naked_pair if naked_pair(work, cand)
        return :hidden_pair if hidden_pair(work, cand)
        return :pointing if pointing(work, cand)
        nil
      end

      # 81 masks; a filled cell gets 0 so no rule can consider it.
      def self.candidate_grid(work)
        cand = []
        Grid::SIZE.times do |i|
          cand << (work[i] == 0 ? Grid.candidates(work, i) : 0)
        end
        cand
      end

      # An empty cell with exactly one candidate: write it.
      def self.naked_single(work, cand)
        Grid::SIZE.times do |i|
          next unless work[i] == 0
          next unless Grid.count_bits(cand[i]) == 1
          work[i] = Grid.bits(cand[i])[0]
          return true
        end
        false
      end

      # A digit with exactly one possible home in a unit: write it there.
      def self.hidden_single(work, cand)
        Grid::UNITS.each do |unit|
          d = 1
          while d <= 9
            bit = 1 << d
            spot = nil
            many = false
            unit.each do |i|
              next if (cand[i] & bit) == 0
              if spot.nil?
                spot = i
              else
                many = true
              end
            end
            if !many && !spot.nil?
              work[spot] = d
              return true
            end
            d += 1
          end
        end
        false
      end

      # Two cells in a unit sharing the same two candidates own that pair,
      # so no other cell in the unit may use either digit. This eliminates
      # rather than writes, so "progress" means a mask actually shrank.
      def self.naked_pair(work, cand)
        Grid::UNITS.each do |unit|
          unit.each do |a|
            next unless Grid.count_bits(cand[a]) == 2
            unit.each do |b|
              next if b <= a
              next unless cand[b] == cand[a]
              changed = false
              unit.each do |i|
                next if i == a || i == b
                next if (cand[i] & cand[a]) == 0
                cand[i] &= ~cand[a]
                changed = true
              end
              return true if changed
            end
          end
        end
        false
      end

      # The mirror image: two digits in a unit that between them can only
      # live in two cells own those cells, so those cells hold nothing else.
      def self.hidden_pair(work, cand)
        Grid::UNITS.each do |unit|
          d1 = 1
          while d1 <= 9
            d2 = d1 + 1
            while d2 <= 9
              pair = (1 << d1) | (1 << d2)
              homes = []
              unit.each do |i|
                homes << i if (cand[i] & pair) != 0
              end
              if homes.size == 2
                a = homes[0]
                b = homes[1]
                # Both digits must actually be possible somewhere in the
                # two cells, or this is a vacuous match on an empty pair.
                if (cand[a] & pair) != 0 && (cand[b] & pair) != 0 &&
                   ((cand[a] | cand[b]) & ~pair) != 0
                  cand[a] &= pair
                  cand[b] &= pair
                  return true
                end
              end
              d2 += 1
            end
            d1 += 1
          end
        end
        false
      end

      # Box/line interaction. If every home for a digit inside a box shares
      # one row (or column), that digit is somewhere on that row inside the
      # box, so it is nowhere else on the row outside the box — and the
      # converse for a line pointing into a box.
      def self.pointing(work, cand)
        Grid::BOXES.each_with_index do |box, _b|
          d = 1
          while d <= 9
            bit = 1 << d
            homes = []
            box.each { |i| homes << i if (cand[i] & bit) != 0 }
            if homes.size >= 2
              return true if strip(cand, homes, bit, Grid::ROWS,
                                   Grid.row_of(homes[0]))
              return true if strip(cand, homes, bit, Grid::COLS,
                                   Grid.col_of(homes[0]))
            end
            d += 1
          end
        end
        false
      end

      # If every home shares `line`, clear `bit` from that line's cells
      # outside the box. Returns true only if something actually changed.
      def self.strip(cand, homes, bit, lines, line)
        same = true
        homes.each do |i|
          same = false if (lines == Grid::ROWS ? Grid.row_of(i) : Grid.col_of(i)) != line
        end
        return false unless same
        changed = false
        lines[line].each do |i|
          next if homes.include?(i)
          next if (cand[i] & bit) == 0
          cand[i] &= ~bit
          changed = true
        end
        changed
      end
    end
  end
end
```

**Important subtlety the implementer must not miss:** `naked_pair`,
`hidden_pair` and `pointing` mutate `cand`, not `work`. Their eliminations
are therefore thrown away when `apply_cheapest` returns and the next pass
rebuilds `cand` from scratch. That is a real bug if left as written: the
loop would report `:naked_pair` progress for ever without the board
changing, and `solve` would never terminate.

Fix it in this same step, and this is the design: `apply_cheapest` must run
the elimination rules and then **immediately re-derive** whatever singles
they expose, within the same pass, so that progress always ends in a written
digit. Concretely — replace `apply_cheapest` with:

```ruby
      # Every technique must end in a digit on the board, or the loop cannot
      # tell progress from repetition: the elimination rules work on a
      # candidate grid that is rebuilt each pass, so an elimination alone
      # leaves no trace and would be rediscovered for ever.
      #
      # So the eliminators run against a scratch candidate grid and their
      # payoff is claimed here: if eliminating opened a single, that single
      # is written and the pass is attributed to the ELIMINATION, not to the
      # single, because the elimination is what was actually needed.
      def self.apply_cheapest(work)
        cand = candidate_grid(work)
        return :naked_single if naked_single(work, cand)
        return :hidden_single if hidden_single(work, cand)

        [[:naked_pair, :naked_pair], [:hidden_pair, :hidden_pair],
         [:pointing, :pointing]].each do |name, _|
          scratch = candidate_grid(work)
          next unless send(name, work, scratch)
          # The elimination fired; now cash it in. Only a written digit
          # counts as progress.
          return name if naked_single(work, scratch)
          return name if hidden_single(work, scratch)
        end
        nil
      end
```

- [ ] **Step 4: Run and iterate to GREEN**

Run: `make test`

Expected on the way: a **hang** is the failure mode to watch for. If
`make test` does not return, the elimination/progress bug above is present:
some rule is reporting `true` without the board changing. The loop in
`solve` has no iteration cap, so add one as a safety net while debugging —
81 written digits is the most that can ever happen, so more than 200 passes
means a non-terminating rule:

```ruby
        passes = 0
        loop do
          step = apply_cheapest(work)
          break if step.nil?
          passes += 1
          raise 'technique solver made no progress' if passes > 200
          hardest = step if rank(step) > rank(hardest)
        end
```

Keep that guard in the shipped code. This project has spent a full cycle on
a test that hung instead of failing (M1 Task 6), and an unbounded
`loop` over a heuristic is exactly that shape.

- [ ] **Step 5: Write the failing rater test**

Create `test/sudoku_rater.rb`:

```ruby
assert('Rater calls a singles-only board easy') do
  r = Redoku::Sudoku::Rater
  assert_equal :easy, r.rate(values_of(EASY_81))
end

assert('Rater calls a board the techniques cannot finish hard') do
  r = Redoku::Sudoku::Rater
  # MULTI_81 stalls the technique solver immediately.
  assert_equal :hard, r.rate(values_of(MULTI_81))
end

assert('Rater tiers are ordered and complete') do
  r = Redoku::Sudoku::Rater
  assert_equal [:easy, :medium, :hard], r::TIERS
  # Every rating is one of the tiers, for a spread of boards.
  [SOLVED_81, EASY_81, UNIQUE_81, MULTI_81].each do |board|
    assert_true r::TIERS.include?(r.rate(values_of(board)))
  end
end

assert('Rater escalates with the hardest technique needed') do
  r = Redoku::Sudoku::Rater
  # A board needing only singles is easy; one needing a pair or pointing is
  # medium; one that stalls is hard. Drive the mapping directly so the tier
  # boundaries are pinned independently of any particular fixture.
  assert_equal :easy, r.tier_for(:naked_single)
  assert_equal :easy, r.tier_for(:hidden_single)
  assert_equal :easy, r.tier_for(nil)
  assert_equal :medium, r.tier_for(:naked_pair)
  assert_equal :medium, r.tier_for(:hidden_pair)
  assert_equal :medium, r.tier_for(:pointing)
end
```

- [ ] **Step 6: Run, confirm RED, then implement the rater**

Create `mrblib/redoku/sudoku/rater.rb`:

```ruby
module Redoku
  module Sudoku
    # Difficulty, defined as "what did it take to solve this by hand".
    #
    # PLAN.md §7 ties the tier to both the hardest technique needed and the
    # clue count. The technique is the load-bearing half and the clue count
    # is only a sanity band, because clue count on its own is a poor
    # predictor: a 30-clue board can be trivial and a 36-clue board can
    # need pointing pairs. So the technique decides, and the Generator is
    # what steers the clue count into range by choosing when to stop
    # digging.
    class Rater
      TIERS = [:easy, :medium, :hard].freeze

      # Solvable with singles alone -> easy. Needs an elimination rule ->
      # medium. The technique solver stalls, so a person would have to
      # guess -> hard.
      def self.tier_for(hardest)
        return :easy if hardest.nil?
        return :easy if hardest == :naked_single || hardest == :hidden_single
        :medium
      end

      def self.rate(values)
        result = Techniques.solve(values)
        return :hard unless result[:solved]
        tier_for(result[:hardest])
      end
    end
  end
end
```

- [ ] **Step 7: Run to GREEN**

Run: `make test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add mrbgems/mruby-redoku/mrblib/redoku/sudoku/techniques.rb \
        mrbgems/mruby-redoku/mrblib/redoku/sudoku/rater.rb \
        mrbgems/mruby-redoku/test/sudoku_techniques.rb \
        mrbgems/mruby-redoku/test/sudoku_rater.rb
git commit -m "feat(redoku): rate puzzles with a human-technique solver"
```

---

### Task 4: Generator

**Files:**
- Create: `mrbgems/mruby-redoku/mrblib/redoku/sudoku/generator.rb`
- Create: `mrbgems/mruby-redoku/test/sudoku_generator.rb`

**Interfaces:**
- Consumes: `Grid`, `Rng`, `Solver.solve`, `Solver.unique?`, `Rater.rate`.
- Produces:
  - `Generator::CLUE_FLOOR` = `{ easy: 36, medium: 28, hard: 24 }`
  - `Generator.generate(tier, rng, attempts = 12)` →
    `{ grid:, solution:, tier: }` — `grid` is a `Grid` whose givens are the
    puzzle, `solution` a values array, `tier` the tier actually achieved
    (which may be easier than asked for; see below)
  - `Generator.full_board(rng)` → a complete values array
  - `Generator.dig(solution, tier, rng)` → puzzle values array

- [ ] **Step 1: Write the failing test**

Create `test/sudoku_generator.rb`:

```ruby
assert('Generator.full_board makes a complete valid grid, seed-stable') do
  gen = Redoku::Sudoku::Generator
  g = Redoku::Sudoku::Grid
  board = gen.full_board(Redoku::Rng.new(11))
  assert_true g.complete?(board)
  assert_equal board, gen.full_board(Redoku::Rng.new(11))
  assert_false board == gen.full_board(Redoku::Rng.new(12))
end

assert('Generator.dig leaves a uniquely solvable puzzle') do
  gen = Redoku::Sudoku::Generator
  s = Redoku::Sudoku::Solver
  solution = gen.full_board(Redoku::Rng.new(5))
  puzzle = gen.dig(solution, :easy, Redoku::Rng.new(5))

  assert_true s.unique?(puzzle)
  # Every remaining clue agrees with the solution it came from.
  81.times do |i|
    assert_equal solution[i], puzzle[i] if puzzle[i] != 0
  end
  # It actually removed something, and not everything.
  clues = 0
  puzzle.each { |d| clues += 1 if d != 0 }
  assert_true clues < 81
  assert_true clues >= gen::CLUE_FLOOR[:easy]
end

assert('Generator.dig removes cells in rotationally symmetric pairs') do
  gen = Redoku::Sudoku::Generator
  solution = gen.full_board(Redoku::Rng.new(8))
  puzzle = gen.dig(solution, :medium, Redoku::Rng.new(8))
  # PLAN.md §7: dig cell PAIRS with rotational symmetry. Cell i's partner
  # is 80 - i. So a hole at i implies a hole at 80 - i, except for the
  # centre cell 40, which is its own partner.
  81.times do |i|
    next if puzzle[i] != 0
    assert_equal 0, puzzle[80 - i]
  end
end

assert('Generator.generate returns a puzzle, its solution and its tier') do
  gen = Redoku::Sudoku::Generator
  g = Redoku::Sudoku::Grid
  s = Redoku::Sudoku::Solver

  out = gen.generate(:easy, Redoku::Rng.new(3))
  assert_true out[:grid].is_a?(Redoku::Sudoku::Grid)
  assert_true g.complete?(out[:solution])
  assert_true Redoku::Sudoku::Rater::TIERS.include?(out[:tier])

  puzzle = out[:grid].values
  assert_true s.unique?(puzzle)
  # The stored solution really does solve the stored puzzle.
  81.times do |i|
    assert_equal out[:solution][i], puzzle[i] if puzzle[i] != 0
  end
  # The grid's cells are all GIVENS: a fresh puzzle has no player entries.
  81.times do |i|
    assert_equal (puzzle[i] != 0), out[:grid].given?(i)
  end
end

assert('Generator.generate honours the clue floor for each tier') do
  gen = Redoku::Sudoku::Generator
  [:easy, :medium, :hard].each_with_index do |tier, n|
    out = gen.generate(tier, Redoku::Rng.new(100 + n))
    assert_true out[:grid].clue_count >= gen::CLUE_FLOOR[tier]
    assert_true out[:grid].clue_count <= 81
  end
end

assert('Generator.generate is reproducible from its seed') do
  gen = Redoku::Sudoku::Generator
  a = gen.generate(:medium, Redoku::Rng.new(77))
  b = gen.generate(:medium, Redoku::Rng.new(77))
  assert_equal a[:grid].givens_s, b[:grid].givens_s
  assert_equal a[:solution], b[:solution]
  assert_equal a[:tier], b[:tier]
end

assert('Generator.generate always returns a playable puzzle, tier or not') do
  gen = Redoku::Sudoku::Generator
  s = Redoku::Sudoku::Solver
  # With a deliberately tiny attempt budget the generator may fail to hit
  # the requested tier. It must still hand back a real puzzle rather than
  # nil, because the game has a board to fill either way — reporting the
  # tier it actually achieved is how the caller stays honest.
  out = gen.generate(:hard, Redoku::Rng.new(4), 1)
  assert_false out.nil?
  assert_true s.unique?(out[:grid].values)
  assert_true Redoku::Sudoku::Rater::TIERS.include?(out[:tier])
end
```

- [ ] **Step 2: Run it and confirm RED**

Run: `make test`
Expected: `NameError: uninitialized constant Redoku::Sudoku::Generator`.

- [ ] **Step 3: Implement the generator**

Create `mrblib/redoku/sudoku/generator.rb`:

```ruby
module Redoku
  module Sudoku
    # Puzzle construction, in three moves: fill a board at random, punch
    # symmetric holes in it for as long as it stays uniquely solvable, then
    # check what difficulty came out and try again if it is not what was
    # asked for.
    #
    # Generate-and-test rather than construct-to-order, per PLAN.md §7,
    # because difficulty is a property of the finished puzzle and is not
    # something you can steer directly while digging. The cost is a handful
    # of attempts; the "generating..." splash covers it.
    class Generator
      # The fewest clues each tier may be left with. PLAN.md §7's bands are
      # easy >= 36, medium 28-35, hard 24-30; the floor is the load-bearing
      # end, because digging stops when it is reached. A tier's UPPER bound
      # is not enforced by digging — digging always goes as deep as
      # uniqueness allows — it falls out of the rating instead.
      CLUE_FLOOR = { easy: 36, medium: 28, hard: 24 }.freeze

      DEFAULT_ATTEMPTS = 12

      # A full valid board. Solving a wholly empty grid with a shuffled
      # digit order is the standard trick: the search never backtracks far
      # because every branch is still wide open.
      def self.full_board(rng)
        empty = []
        Grid::SIZE.times { empty << 0 }
        Solver.solve(empty, rng)
      end

      # Rotationally symmetric pairs: cell i pairs with 80 - i, which is the
      # 180-degree rotation of the board. Cell 40 is the centre and pairs
      # with itself. Listing each pair once (i < 80 - i) plus the centre
      # gives 40 pairs + 1 = the 41 removable groups.
      def self.dig_order(rng)
        pairs = []
        Grid::SIZE.times do |i|
          partner = 80 - i
          pairs << [i, partner] if i < partner
        end
        pairs << [40, 40]
        rng.shuffle(pairs)
      end

      # Remove pairs while the puzzle stays uniquely solvable and the clue
      # count stays at or above the tier's floor. Greedy and single-pass: a
      # pair that cannot be removed now is simply skipped, never revisited.
      def self.dig(solution, tier, rng)
        puzzle = solution.dup
        floor = CLUE_FLOOR[tier] || 24
        clues = Grid::SIZE
        dig_order(rng).each do |pair|
          a = pair[0]
          b = pair[1]
          removing = a == b ? 1 : 2
          break if clues - removing < floor
          next if puzzle[a] == 0 && puzzle[b] == 0

          keep_a = puzzle[a]
          keep_b = puzzle[b]
          puzzle[a] = 0
          puzzle[b] = 0
          if Solver.unique?(puzzle)
            clues -= removing
          else
            puzzle[a] = keep_a
            puzzle[b] = keep_b
          end
        end
        puzzle
      end

      # Try until the rating matches, then stop. If nothing matches inside
      # the budget, keep the closest attempt rather than returning nil: the
      # game always has a board to draw, and an honest `tier:` in the reply
      # is better than a lie or a crash. The header will then say what the
      # player actually got.
      def self.generate(tier, rng, attempts = DEFAULT_ATTEMPTS)
        fallback = nil
        attempts.times do
          solution = full_board(rng)
          puzzle = dig(solution, tier, rng)
          got = Rater.rate(puzzle)
          candidate = {
            grid: Grid.new(puzzle),
            solution: solution,
            tier: got
          }
          return candidate if got == tier
          fallback = candidate if fallback.nil?
        end
        fallback
      end
    end
  end
end
```

- [ ] **Step 4: Run and iterate to GREEN**

Run: `make test`

Two failures to expect and how to read them:

- **The suite gets slow.** `dig` calls `Solver.unique?` up to 41 times per
  attempt, and `generate` runs up to 12 attempts. If `make test` takes
  minutes rather than seconds, the MRV heuristic in `Solver.best_cell` is
  not working — check that it returns early on a single-candidate cell.
- **`:hard` is never reached.** Only `:easy` and `:medium` come out of
  `tier_for`, so `Rater.rate` returns `:hard` only when the technique
  solver stalls, and greedy symmetric digging down to 24 clues may not
  stall it. This is expected and is why `generate` has a fallback and
  reports the tier it achieved. The test asserts a playable puzzle and an
  honest tier, not that `:hard` is always attainable. If `:hard` proves
  unreachable in practice, that is a finding for the Task 4 review to
  record, and the fix (dig deeper for `:hard`, or add an X-wing to
  `Techniques`) belongs to M3, not here.

- [ ] **Step 5: Commit**

```bash
git add mrbgems/mruby-redoku/mrblib/redoku/sudoku/generator.rb \
        mrbgems/mruby-redoku/test/sudoku_generator.rb
git commit -m "feat(redoku): generate uniquely-solvable puzzles by tier"
```

---

### Task 5: Draw the puzzle, and generate one from the buttons

**Files:**
- Modify: `mrbgems/mruby-redoku/mrblib/redoku/renderer.rb`
- Modify: `mrbgems/mruby-redoku/mrblib/redoku/app.rb`
- Modify: `mrbgems/mruby-redoku/test/renderer.rb`
- Modify: `mrbgems/mruby-redoku/test/app.rb`
- Modify: `PLAN.md` (§10 M2 status)

**Interfaces:**
- Consumes: everything from Tasks 1–4; the existing `Layout.cell_rect`,
  `Font.draw`, `Font.width`, `Renderer#draw_board`, `#flush_board`,
  `TestDisplay`.
- Produces:
  - `Renderer::GIVEN_GRAY` = 0, `::ENTRY_GRAY` = 96, `::DIGIT_SCALE`
  - `Renderer#draw_digit(index, digit, gray)`,
    `#draw_puzzle(grid)`, `#draw_splash(text)`
  - `App#grid`, `App#new_puzzle` — New generates, Level re-generates

- [ ] **Step 1: Write the failing renderer test**

Append to `test/renderer.rb`:

```ruby
assert('Renderer draws a digit centred in its cell') do
  d = TestDisplay.new
  r = Redoku::Renderer.new(d)
  r.draw_digit(0, 5, Redoku::Renderer::GIVEN_GRAY)

  x, y, w, h = Redoku::Layout.cell_rect(0)
  gw = Redoku::Font.width('5') * Redoku::Renderer::DIGIT_SCALE
  gh = Redoku::Font::HEIGHT * Redoku::Renderer::DIGIT_SCALE
  # The glyph must fit inside the cell and be roughly centred: within one
  # scale step of the exact centre on both axes.
  assert_true gw <= w
  assert_true gh <= h
  centre_x = x + (w - gw) / 2
  centre_y = y + (h - gh) / 2
  assert_true d.painted_within?(centre_x, centre_y, gw, gh)
end

assert('Renderer draws givens darker than entries') do
  assert_equal 0, Redoku::Renderer::GIVEN_GRAY
  assert_true Redoku::Renderer::ENTRY_GRAY > Redoku::Renderer::GIVEN_GRAY
  assert_true Redoku::Renderer::ENTRY_GRAY < 255
end

assert('Renderer draws every filled cell of a puzzle and no empty one') do
  d = TestDisplay.new
  r = Redoku::Renderer.new(d)
  grid = grid_of(EASY_81)
  r.draw_board
  drawn = d.draw_count
  r.draw_puzzle(grid)
  # EASY_81 has 79 clues, so 79 glyphs were drawn on top of the board.
  assert_true d.draw_count > drawn
  # And the two empty cells stay empty: nothing painted inside cell 0.
  x, y, w, h = Redoku::Layout.cell_rect(0)
  assert_false d.glyph_in_cell?(0)
  assert_true d.glyph_in_cell?(1)
end
```

`painted_within?`, `draw_count` and `glyph_in_cell?` do not exist yet. Add
them to `test/_support.rb`'s `TestDisplay` in Step 3, implemented from the
recorded `fill_rect` calls it already keeps. Read `_support.rb` first and
follow its existing recording convention rather than inventing a second one.

- [ ] **Step 2: Run it and confirm RED**

Run: `make test`
Expected: `NoMethodError: undefined method 'draw_digit'`.

- [ ] **Step 3: Implement the renderer additions**

Read `renderer.rb` and `layout.rb` whole first — `CELL`, `cell_rect`,
`Font::HEIGHT` and `Font.width` all already exist and their exact values
decide `DIGIT_SCALE`. Cells are 140 px and `Font::HEIGHT` is 7, so a scale
of 14 gives a 98 px glyph with 21 px of margin top and bottom. Pick the
largest scale whose glyph still fits with a visible margin, and assert the
arithmetic in the test rather than trusting this paragraph.

Sketch, to be completed against the real constants:

```ruby
    # Givens are the puzzle and entries are the player's, so they must be
    # told apart at a glance (PLAN.md §8). Black against a mid grey reads
    # clearly on e-ink at this size without needing a second typeface.
    GIVEN_GRAY = 0
    ENTRY_GRAY = 96

    # Font::HEIGHT is 7 rows, cells are Layout::CELL px. 14 puts a 98 px
    # digit in a 140 px cell: big enough to read across the room, with
    # enough margin that the glyph never touches a cell border.
    DIGIT_SCALE = 14

    def draw_digit(index, digit, gray)
      x, y, w, h = Layout.cell_rect(index)
      text = digit.to_s
      gw = Font.width(text) * DIGIT_SCALE
      gh = Font::HEIGHT * DIGIT_SCALE
      Font.draw(@d, x + (w - gw) / 2, y + (h - gh) / 2, text,
                DIGIT_SCALE, gray)
    end

    def draw_puzzle(grid)
      Sudoku::Grid::SIZE.times do |i|
        d = grid.value_at(i)
        next if d == 0
        draw_digit(i, d, grid.given?(i) ? GIVEN_GRAY : ENTRY_GRAY)
      end
      self
    end
```

- [ ] **Step 4: Run to GREEN, then write the App test**

Append to `test/app.rb`:

```ruby
assert('App starts with a generated puzzle on the board') do
  app = test_app
  assert_false app.grid.nil?
  assert_true Redoku::Sudoku::Solver.unique?(app.grid.values)
  assert_true app.grid.clue_count > 0
end

assert('a tap on New generates a different puzzle') do
  app = test_app
  before = app.grid.givens_s
  press_new(app)
  assert_false app.grid.givens_s == before
  assert_true Redoku::Sudoku::Solver.unique?(app.grid.values)
end

assert('a tap on Level changes the difficulty and the puzzle with it') do
  app = test_app
  before_tier = app.difficulty
  before_puzzle = app.grid.givens_s
  press_level(app)
  assert_false app.difficulty == before_tier
  assert_false app.grid.givens_s == before_puzzle
end
```

`test_app`, `press_new` and `press_level` must be built from the fixtures
`test/app.rb` already has for driving taps — read the existing file and
reuse its sample builders rather than adding a parallel set.

**The App must take its Rng injected**, defaulting to a fresh one, exactly
as it already takes `waiter`, `signals` and `clock`. A test that cannot fix
the seed cannot assert "a different puzzle" without flaking.

- [ ] **Step 5: Implement the App changes**

The event loop must not grow a second responsibility. Generation is slow
enough to be visible, so:

- `App#initialize` gains `rng: Rng.new(...)` and generates its first puzzle
  lazily in `run`, not in the constructor — a constructor that searches for
  a puzzle makes every existing App test slow.
- `clear_ink` (New) becomes `new_puzzle`: draw the splash, generate, draw
  the board, draw the puzzle, flush. The press acknowledgement from Task 9
  already brackets this, so the button stays inverted for the whole
  generation, which is the progress indication PLAN.md §7 asks for.
- `cycle_difficulty` (Level) also regenerates, because the tier only means
  something once a puzzle of that tier is on the board.

- [ ] **Step 6: Run the full suite and both toolchains**

Run: `make test` — expect KO 0, Crash 0, Warning 0.
Run: `make build` — expect a clean armv7 cross-build and 0 warnings.
Run: `file build/rm2/bin/redoku` — expect `ELF 32-bit LSB ... ARM`.

- [ ] **Step 7: Update PLAN.md §10 and commit**

Mark M2 complete in the status header and §10, naming what has hardware
evidence and what does not — generation timing on the Cortex-A7 is the one
thing no host test can settle.

```bash
git add mrbgems/mruby-redoku/mrblib/redoku/renderer.rb \
        mrbgems/mruby-redoku/mrblib/redoku/app.rb \
        mrbgems/mruby-redoku/test/renderer.rb \
        mrbgems/mruby-redoku/test/app.rb \
        mrbgems/mruby-redoku/test/_support.rb PLAN.md
git commit -m "feat(redoku): render generated puzzles and generate from the buttons"
```

---

## Self-Review

**1. Spec coverage.** PLAN.md §7 requirement by requirement:

| §7 requirement | Task |
|---|---|
| `Grid`, 81 cells, given / entry / empty | 1 |
| Serializes to a string | 1 (`givens_s` / `values_s`) |
| Counting backtracker, randomized, early-exit at 2 | 2 |
| Stores the solution for checking | 4 (`generate` returns `solution:`) |
| Technique solver: naked single, hidden single, naked/hidden pair, pointing | 3 |
| Records the hardest technique needed | 3 |
| `Generator`: fill, dig pairs with rotational symmetry, uniqueness | 4 |
| `Rater`: tiers from the technique solver | 3 |
| Generate-and-test until the tier matches | 4 |
| "generating…" splash covers the pause | 5 |
| Board renders generated puzzles with given digits (§10 M2) | 5 |

**Deliberately deferred to M3, so a reviewer does not read them as gaps:**
state persistence to `/home/root/redoku/state` (§7 mentions the file, but
§10 puts persistence in M3), the `Check` button and mistake marks, the win
screen, and the entries the player writes — M2 has no recognizer, so the
only way a digit reaches a cell is generation. `Grid#set_entry` exists and
is tested because the Grid is the thing that has to be right first, but
nothing calls it outside tests until M3.

**2. Placeholder scan.** One deliberate exception, called out rather than
hidden: Task 5 Step 3's renderer code is a sketch to be completed against
the real `Layout`/`Font` constants, and Step 4's `test_app` helpers are
specified as "reuse what `test/app.rb` already has" rather than written out.
Both are cases where writing code blind against a file the implementer is
told to read whole would produce a confident wrong answer — `DIGIT_SCALE`
in particular depends on `Layout::CELL` and `Font::HEIGHT`, and guessing
them here would put a wrong number in the plan the way M1's Task 8 brief put
a wrong premise in ("New and Level read as responsive for free"). The step
says which constants decide it and requires the arithmetic be asserted.

**3. Type consistency.** Checked across tasks: `values` is an 81-element
Array of Integer everywhere; `mask` is an Integer with bits 1..9 everywhere;
`Grid.candidates(values, i)` has the same argument order in Tasks 1, 2 and
3; `Techniques.solve` returns the same three-key hash in Task 3 and Task 4;
`Generator.generate` returns `{grid:, solution:, tier:}` in Task 4's tests
and Task 5's consumer; `Rater::TIERS` and `Renderer::DIFFICULTIES` are
**not** the same list and Task 5 must map between them — flagged there
because that mismatch is exactly the kind that compiles and then shows the
wrong header label.

**4. Known risk, recorded rather than resolved.** `:hard` may be
unreachable with only five techniques and greedy symmetric digging (Task 4
Step 4 says so). The plan's answer is an honest `tier:` in the reply and a
finding for the review, not a silent relabel. That is a design decision the
owner may want to overturn in M3 by adding an X-wing.
