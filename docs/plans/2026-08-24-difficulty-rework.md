# Difficulty Rework — Five Technique-Gated Rungs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the three score-banded difficulty tiers with five rungs
whose upper three are gated by what a board *demands* of a solver, and put a
real progress bar behind the longer search that costs.

**Architecture:** The tier stops being "which band did the score fall in" and
becomes "what is the weakest RULE SET that finishes this board" — a property
trivial filling cannot fake. The score keeps exactly one job: splitting the
singles-only class into a short rung (`:easy`) and a long one (`:medium`),
which is the owner's "long, not clever" axis, deliberately kept at the bottom
of the ladder rather than the top. Three units change shape: `Techniques`
gains a rule filter, `Rater` swaps score bands for a demand classifier plus a
per-class tier range, and `Generator` walks the dug chain from its *deep* end
for every rung but `:easy`, rescues a stalled chain floor by restoring one
symmetric group, and reports progress through a block. `App` then owns the
retry loop and a progress bar whose denominator survives a retry.

**Tech Stack:** mruby 4.0.0, pure Ruby, no new gem dependencies. mrbtest for
unit tests. No C in this change.

**Spec:** `.superpowers/sdd/2026-08-23-m2-sudoku-engine/design-harder-tiers.md`
— the measured design, and the source of every constant below. Its §12 holds
the raw script output every number here traces back to. Secondary:
`docs/design/difficulty-rating.md` (the decision record this plan partly
supersedes and Task 6 corrects), `PLAN.md` §7 (engine) and §8 (layout). The
spec travels with the plan; executors read both. This plan departs from the
design in six places; they are enumerated in Task 6 Step 4 rather than left in
code comments, and the Self-Review coverage table flags them per section.

**Baseline:** revised against `2bebc4e` (2026-08-24). The first draft was
written against `2aae216` and three commits landed under it — `75eb7cf`
(deleted `Renderer::DIFFICULTIES`, landed `fill_board`'s nil guard), `c437d95`
+ `2bebc4e` (the pen eraser: `Renderer#redraw_cell`, `boundary_weight` /
`leading_band` / `trailing_band`, `Sudoku::Grid.index_of`) and `18cc2f5`
(declared eleven core gems, which retired most of Global Constraint 1). **Every
line number below was re-verified at `2bebc4e`, and they have already moved
twice — re-verify with `grep -n` rather than trusting them.**

---

## Global Constraints

These are project-wide. Every task's requirements implicitly include them.

**1. The mrbtest dependency trap — real, but the forbidden list this project
carried for two milestones was mostly fiction, and `18cc2f5` retired it.**

The mechanism is unchanged and still worth stating: a gem's mrbtest state
holds only its *declared* dependencies, while the shipped device binary links
the whole `default` gembox. So code using an **undeclared** gem's method
passes on the device and raises `NoMethodError` under `make test`. This
project was bitten four times by that gap.

What changed is the size of the gap. `18cc2f5` read `build_config.rb` (both
targets call `conf.gembox 'default'`) against `mrbgems/default.gembox`, found
that the binary already linked stdlib, stdlib-ext, stdlib-io, math and
metaprog, and **declared eleven of those gems** so that `make test` sees what
already ships. `mruby-redoku` now declares:

```
mruby-rm2  mruby-string-ext  mruby-time
mruby-array-ext  mruby-enum-ext  mruby-hash-ext  mruby-numeric-ext
mruby-compar-ext  mruby-sprintf  mruby-random  mruby-catch  mruby-set
mruby-struct  mruby-metaprog
```

**Proven, not argued:** `make test` totals identical before and after
(Total 2455, OK 2410, KO 0, Crash 0, Skip 45), a 13-assertion probe of the
newly visible methods passed and was deleted, `make build` clean with a valid
ARM ELF — and **no `make clean` was needed**, even declaring eleven gems at
once.

**So all of these are now LEGAL under `make test`:** every `Array` and
`Enumerable` method (`uniq` `sum` `count` `sort_by` `flat_map` `tally`
`each_with_object` `none?` `one?` `compact` `flatten` `zip` `group_by`
`filter` — `filter` reaches us as `alias filter select` in `mruby-enum-ext`);
every `Hash` extension (`fetch` `merge!` `min_by` `max_by`, and `each_pair`
as `alias each_pair each` in `mruby-hash-ext`); every `Integer` extension
(`zero?` `even?` `odd?` `clamp` `pow` `digits`); `format` / `sprintf` /
`String#%`; `Kernel#rand` / `srand`; `catch` / `throw`; `Set`; `Struct`;
and — the one that changes a decision in Task 5 — `Object#send` and
`Object#instance_variable_set`, both from `mruby-metaprog`.

**GENUINELY UNAVAILABLE, and this is the whole list that matters here:**

- **`Integer#pred`** — absent from the mruby checkout entirely, not merely
  undeclared. Zero matches anywhere. Write `n - 1`.
- **Anything from a gem the `default` gembox links but this gem still does
  not declare.** Those are `mruby-object-ext`, `mruby-range-ext`,
  `mruby-symbol-ext`, `mruby-proc-ext`, `mruby-kernel-ext`,
  `mruby-class-ext`, `mruby-method`, `mruby-eval`, `mruby-binding`,
  `mruby-proc-binding`, `mruby-regexp`, `mruby-objectspace`, `mruby-fiber`,
  `mruby-enumerator` (and `-lazy` / `-chain`), `mruby-pack`, `mruby-data`,
  `mruby-toplevel-ext`, `mruby-math`, and the `mruby-io` family. The two that
  this change actually touches:
  - **`Object#tap`** (`mruby-object-ext`) — still absent. Task 1's table
    builder is written without it.
  - **`Method` / `UnboundMethod`** (`mruby-method`) — still absent, which is
    still half the reason `Techniques.solve` filters with a bitmask rather
    than a dispatch table (the other half is speed; see Task 1 Step 4).
  - **`$stderr`** (`mruby-io`) — undefined under `make test`, and an
    undefined global in Ruby is `nil`, not an error. That is exactly what
    Task 5's `@log.puts(...) if @log` guard is for; do not remove it, and do
    not declare `mruby-io` to make it go away.

**TWO CAUTIONS, because "it is legal now" is not "rewrite it".**

- **Do not rewrite speed-driven hand-rolled code.** The candidate bitmasks,
  the allocation-free solver loops and `Grid.count_bits`'s nine-iteration
  loop exist because bitwise operations are the fastest thing on a Cortex-A7
  and the solver runs tens of thousands of times per puzzle. `Array#sum` over
  a candidate mask would be correct and slower. Leave them.
- **Do not mass-convert `x == 0` to `x.zero?`.** Legal now, not clearer, and
  the churn would touch hot files for no benefit. Two comments in the tree
  currently justify `== 0` by claiming `Integer#zero?` is unavailable —
  `Renderer#boundary_weight` and `Rater.band`. The second is deleted by
  Task 2; the first is corrected by Task 4, which is already editing that
  file. Nothing else moves.

Consequences that survive, and are not left to the implementer:

- Build lookup tables with `times`/`while` loops in a `def self.build_*`
  method called from the class body, the way `Grid.build_rows` and
  `Grid.build_peers` already do. This is house style, not a workaround: a
  constant that fails to build takes the whole gem down at load, and takes
  every other suite with it, so the building code wants to be readable.
- **The "adding a dependency forces every contributor to `make clean`"
  belief is WEAKENED, not established.** It comes from M1 fix wave A and has
  now failed to reproduce twice — once with one gem (`mruby-time`), once with
  eleven at a stroke. Two data points against, none for. It is a single trial
  at eleven gems rather than a stress test of every irep-renumbering
  scenario, so it is not *disproved*; but stop presenting it as a known cost,
  and stop citing it as a reason to avoid a dependency. Nothing in this plan
  adds one.

**2. Integer width.** `mrb_int` is 64-bit on the host and **32-bit on the
device**. Nothing here may rely on more. The widest product in this change is
`Renderer.progress_fill`'s `inner * num` — 614 × a few thousand attempts, six
digits, safe. Keep it that way.

**3. mrblib load order is `sort` over full paths, and it is load-bearing.**
Verified against the generated `build/host/mrbgems/mruby-redoku/gem_init.c`:

```
app.rb  font.rb  layout.rb  main.rb  pen.rb  renderer.rb  rng.rb
sudoku/generator.rb  sudoku/grid.rb  sudoku/rater.rb  sudoku/solver.rb
sudoku/techniques.rb  touch.rb
```

**`rater.rb` loads BEFORE `techniques.rb`.** So `Rater` may call
`Techniques.solve` (runtime) but **must not name `Techniques::ORDER` in a
constant expression** — that raises `NameError` at load. The design document's
§6.1 sketch does exactly that (`DEMAND_SETS = [ ..., Techniques::ORDER ]`) and
it would take the gem down. Task 2 spells the fourth set out in full and pins
its agreement with `ORDER` in a test. `Generator` loads before both `Rater`
and `Techniques`, so its constants must be literals too.

**There is no precedent for that pin in this gem any more, and the one that
existed was deleted for being vacuous.** `75eb7cf` removed
`Renderer::DIFFICULTIES` *and* "the vacuous test pinning the two lists equal",
on the grounds that the constant was a duplicate of `Sudoku::Rater::TIERS`
with no reason to exist. So Task 2's `DEMAND_SETS`-against-`ORDER` assertion
is the **first** guard of its kind here, and it has to justify itself rather
than cite a house pattern. It does, and the difference from the deleted one is
the point: `DIFFICULTIES == TIERS` pinned two literals that had no reason to
be separate, so the fix was to delete one of them. `DEMAND_SETS` **must** be a
literal — the load order forbids the reference — so the copy is forced, and a
test is the only thing that can keep a forced copy honest.

**4. Verified signatures.** Re-checked against HEAD; the previous plan got
three of them wrong:

- `Layout.cell_rect(col, row)` takes **two** arguments and returns
  `[x, y, w, h]`.
- `Font.width(text, scale)` takes **two** arguments, and is
  `text.size * 6 * scale - scale` — so a 6-character label at `LABEL_SCALE 5`
  is 175 px.
- `Font.draw(display, text, x, y, scale, gray)` — `text` is the **third**
  argument, after the display.
- The cell-count constant is `Sudoku::Grid::CELLS` (81). There is
  deliberately **no** `Grid::SIZE`, because `Layout::SIZE` already means 9.
- `Sudoku::Grid.index_of(col, row)` exists (added by the eraser work) and is
  the inverse of `Grid.col_of` / `Grid.row_of`.
- `Renderer` has private `centered_origin(text, scale, x, y, w, h)` and — new
  from the eraser work — private `boundary_weight` / `leading_band` /
  `trailing_band`, plus public `redraw_cell(index, grid)`. Task 4 appends to
  this file; read it whole first, because no snippet in this plan quotes it as
  it now stands.
- **`Renderer::DIFFICULTIES` DOES NOT EXIST.** It was deleted in `75eb7cf`.
  The tier list has exactly one home, `Sudoku::Rater::TIERS`, and `app.rb`
  (`:93`, `:719`) and `test/app.rb` (`:759`, `:909`) already read it directly.
  Nothing in this plan may reference `Renderer::DIFFICULTIES`.
- `Font::GLYPHS` holds `A-Z`, `0-9`, space, `-`, `:` and `.` and **nothing
  else**. `Font.draw` silently draws nothing for a missing glyph while still
  advancing the cursor, so `:very_hard` would render as `VERY`, a gap, `HARD`,
  with no error anywhere. Every tier name in this change is a single
  upper-case word for that reason.

**5. Do not run `make test` or `make build` while a fix wave holds the
build.** They are Docker wrappers. Steps below say "Run: `make test`" because
that is what the implementer must do *when the build is theirs*; if it is
held, wait for it rather than working around it. The throwaway measurement
scripts in Tasks 2 and 3 run through the same container
(`docker run … build/host/bin/mruby -r lib.rb <script>.rb`) and are subject to
the same rule.

**6. Test cost is a design constraint here, not an afterthought.** The top
rungs are expensive to generate: measured on the build host, `:master` is
p50 4.7 s / p90 16.0 s at its 150-attempt cap. **No test may request
`:master`, `:expert` or `:hard` at its production attempt cap**, and no test
may assert that those rungs are *reachable*. Tests either pass an explicit
small `attempts` and assert the *contract* (an honest reply, or nil), or drive
the classifier directly on a fixture board. Reachability is established once,
by a throwaway measurement script whose output is pasted into the Task 3
commit message — the same discipline the design used.

`:medium` at its production cap of 12 **is** allowed, and two `test/app.rb`
tests pay it because they construct an `App` directly (Task 2 Step 7 names
them). It is p50 90 ms but p90 552 ms and max 1309 ms, which makes it the
suite's largest single cost — worth knowing before blaming a slow run on the
new floor rescue.

---

## File Structure

```
mrbgems/mruby-redoku/
├── mrblib/redoku/
│   ├── sudoku/
│   │   ├── techniques.rb   MOD  Task 1  rule-filtered solve + solves?
│   │   ├── rater.rb        MOD  Task 2  demand ladder replaces score bands
│   │   └── generator.rb    MOD  Task 2,3  tier-equality accept; deep walk,
│   │                                      floor rescue, per-tier attempts,
│   │                                      progress block
│   ├── renderer.rb         MOD  Task 4  progress bar (+ one stale comment)
│   └── app.rb              MOD  Task 2,5  generator seam; retry loops, nil
│                                          guard, cross-retry bar, log
└── test/
    ├── _support.rb         MOD  Task 2  demand-class fixtures
    ├── sudoku_techniques.rb MOD Task 1
    ├── sudoku_rater.rb     MOD  Task 2  large rewrite
    ├── sudoku_generator.rb MOD  Task 2,3
    ├── renderer.rb         MOD  Task 4
    └── app.rb              MOD  Task 2,5  FakeGenerator, FakeLog, % 3 fixes
docs/
├── design/difficulty-rating.md   MOD  Task 6  the overturned decision
└── plans/2026-08-24-difficulty-rework.md      this file
PLAN.md                            MOD  Task 6  §7 engine, §10 M2 note
```

**`renderer.rb` is NOT touched by Task 2.** An earlier draft of this plan had
Task 2 grow `Renderer::DIFFICULTIES` to five names; that constant no longer
exists (`75eb7cf`), so there is nothing to grow and the five-name list lands
once, in `Rater::TIERS`. Renderer's only involvement is Task 4's bar.

`mrbgem.rake` is **not** modified: this change needs no gem that `18cc2f5` did
not already declare.

---

## Contracts, decided once here

Four shapes travel between tasks. Getting a name or a type wrong here is how
the tasks stop composing.

**`Techniques.solve(values, rules = ALL_RULES)`** → unchanged four-key hash
`{ values:, solved:, hardest:, counts: }`. `rules` is an **Integer bitmask**
over `ORDER`'s positions. `hardest` and `counts` describe the *filtered* run.

**`Rater.measure(values)`** → for a board the eight rules finish:
`{ tier:, demand:, score:, counts:, hardest:, solved: true }`. For a board
they cannot — a **reject** — `{ tier: nil, demand: nil, score: nil, counts:,
hardest:, solved: false }`. `tier: nil` is a **contract change**: today's
`measure` always names a tier. Every caller must handle nil.

**`Generator.generate(tier, rng, attempts = nil) { |done, total| }`** →
either a candidate hash
`{ grid:, solution:, tier:, demand:, score:, hardest:, counts:, clues:,
attempts: }` or **nil**. `tier:` is the tier actually achieved, which may be
easier than the request. The block fires once per *completed* attempt.
`attempts:` in the reply is the attempt the returned board came from, not the
total spent — the caller counts the total from the block (see Task 5).

**The progress fraction** is two Integers, `(num, den)`, and it is the
**App's**, not the generator's: `num` counts attempts completed across every
retry of one press, `den` is `num + total`. Never a Float, never a percentage
string. Task 5 explains why that shape and not the design's `retry_cap`
formula — and names what it costs, because this shape has a visible
consequence the design's did not: **the bar never fills.** An `:easy` press
that hits on its first attempt stops at 1/(1+6) = 14% and is then replaced by
the board. Design §6.5 promised "the bar jumps to full — correct, and cheap";
under this shape it does not, and that is a deliberate trade recorded in Task
5, not an oversight.

---

### Task 1: A rule-filtered technique solve

The one new primitive the whole ladder rests on: "does *this set of rules*
finish this board?". The measurement harness implemented exactly this against
the existing public rule methods and agreed with the shipped
`Techniques.solve` on `solved`, `hardest` **and** `counts` in 289/289 boards
drawn from 30 real dig chains, so this is a refactor of one loop, not new
logic.

**Files:**
- Modify: `mrbgems/mruby-redoku/mrblib/redoku/sudoku/techniques.rb`
- Modify: `mrbgems/mruby-redoku/test/sudoku_techniques.rb` (append)

**Interfaces:**
- Consumes: nothing new. `Grid`, `Grid::BIT_LIST`, the eight existing rule
  methods, all unchanged.
- Produces, and Task 2 relies on exactly these names:
  - `Techniques::RULE_BIT` — Hash, rule symbol → `1 << ORDER.index(rule)`
  - `Techniques::ALL_RULES` — Integer, every bit set
  - `Techniques.mask_of(rules)` → Integer, for an Array of rule symbols
  - `Techniques.solve(values, rules = ALL_RULES)` → the same four-key hash
  - `Techniques.solves?(values, rules)` → `true`/`false`, `rules` an **Array
    of symbols**

- [ ] **Step 1: Write the failing test**

Append to `test/sudoku_techniques.rb`:

```ruby
assert('Techniques rule masks name every rule in ORDER, once') do
  t = Redoku::Sudoku::Techniques
  # One bit per rule, in ORDER's own positions: the mask is how a caller says
  # "solve with these rules and no others", and a rule missing from the table
  # would silently be unaskable.
  assert_equal(t::ORDER.size, t::RULE_BIT.size)
  t::ORDER.each_with_index do |name, i|
    assert_equal(1 << i, t::RULE_BIT[name])
  end
  # Every bit set, and nothing above them.
  assert_equal((1 << t::ORDER.size) - 1, t::ALL_RULES)
  t::ORDER.each { |name| assert_true (t::ALL_RULES & t::RULE_BIT[name]) != 0 }

  # mask_of turns the readable form (a list of names) into the fast one.
  assert_equal(0, t.mask_of([]))
  assert_equal(t::RULE_BIT[:x_wing], t.mask_of([:x_wing]))
  assert_equal(t::ALL_RULES, t.mask_of(t::ORDER))
  # An unknown name contributes NOTHING rather than raising. That is the
  # UNKNOWN_WEIGHT convention: this runs inside generation, and the cost of a
  # typo should be a board that looks harder than it is (a weaker set fails to
  # solve it, so its demand class comes out higher), never a game that dies
  # mid-tap. Rater's table-agreement test is what actually catches the typo.
  assert_equal(t::RULE_BIT[:pointing], t.mask_of([:pointing, :not_a_rule]))
end

assert('Techniques.solve with every rule is exactly what it was') do
  t = Redoku::Sudoku::Techniques
  # The filter must be free when nothing is filtered: this is the equivalence
  # the design measured at 289/289 boards, asserted here on the fixtures.
  [SOLVED_81, EASY_81, UNIQUE_81, MULTI_81].each do |board|
    values = values_of(board)
    plain = t.solve(values)
    masked = t.solve(values, t::ALL_RULES)
    assert_equal(plain[:solved], masked[:solved])
    assert_equal(plain[:hardest], masked[:hardest])
    assert_equal(plain[:counts], masked[:counts])
    assert_equal(plain[:values], masked[:values])
  end
end

assert('Techniques.solves? answers for a set of rules, not for all of them') do
  t = Redoku::Sudoku::Techniques
  singles = [:naked_single, :hidden_single]

  # EASY_81's two holes are each forced by their row, so singles finish it.
  assert_true t.solves?(values_of(EASY_81), singles)
  # A finished board needs no rule at all, so even the empty set "solves" it.
  assert_true t.solves?(solved_values, [])
  # MULTI_81 has three givens: nothing our eight rules know can force a cell.
  assert_false t.solves?(values_of(MULTI_81), t::ORDER)
  assert_false t.solves?(values_of(MULTI_81), singles)

  # A set with no WRITING rule can never finish an unfinished board, however
  # much it eliminates. Worth pinning: it is the one way to hand solves? a set
  # that cannot possibly work, and a caller could do it by accident.
  assert_false t.solves?(values_of(EASY_81), [:naked_pair, :x_wing])

  # It does not mutate the board it is asked about.
  values = values_of(EASY_81)
  before = values.dup
  t.solves?(values, t::ORDER)
  assert_equal(before, values)
end
```

- [ ] **Step 2: Run it and confirm RED**

Run: `make test`
Expected: FAIL — `NameError: uninitialized constant
Redoku::Sudoku::Techniques::RULE_BIT`.

- [ ] **Step 3: Add the mask table**

In `techniques.rb`, immediately after the `ORDER` constant and before
`MAX_PASSES`:

```ruby
      # A bit per rule, in ORDER's positions. This is how a caller asks for a
      # solve with a RESTRICTED repertoire, which is what Rater's demand
      # classifier needs: "is this board finished by singles alone?" is a
      # question about a rule SET, and the answer cannot be read off a single
      # solve (see Rater::DEMAND_SETS).
      #
      # Derived from ORDER rather than written out, so a rule added to ORDER
      # gets a bit automatically. Built by a method called from the class body,
      # the house pattern Grid.build_rows and Grid.build_peers already use:
      # a constant that raises while building takes the whole gem down at load
      # and every other suite with it, so the building code wants to be plain.
      # (Object#tap would read better as a one-liner and is genuinely absent --
      # mruby-object-ext is one of the gems this gem still does not declare.)
      def self.build_rule_bits
        bits = {}
        i = 0
        while i < ORDER.size
          bits.store(ORDER[i], 1 << i)
          i += 1
        end
        bits
      end
      RULE_BIT = build_rule_bits.freeze

      # Every rule. The default for `solve`, so today's one-argument callers
      # are unaffected.
      ALL_RULES = (1 << ORDER.size) - 1

      # The mask for a list of rule names. An unknown name contributes
      # nothing, deliberately: this runs inside generation and the safety net
      # firing should make a board look HARDER (a weaker set fails, so the
      # demand class rises) rather than kill the game. Rater's tables are
      # pinned against ORDER by a test, which is where a typo is caught.
      def self.mask_of(rules)
        m = 0
        rules.each do |name|
          bit = RULE_BIT[name]
          m |= bit if bit
        end
        m
      end

      # Does this set of rules finish this board? One solve, no search, no
      # guessing. A set containing no WRITING rule (neither single) can never
      # finish an unfinished board however much it eliminates.
      def self.solves?(values, rules)
        solve(values, mask_of(rules))[:solved]
      end
```

- [ ] **Step 4: Put the filter through `solve`**

Replace the head of `solve` and guard each rule. The eight `enabled_*` locals
are read once per pass rather than re-masked inside each `if`, so the loop
body keeps the shape it has today:

```ruby
      # `rules` restricts the repertoire to a mask of RULE_BIT bits. The
      # default is every rule, so a one-argument call is exactly what it was.
      #
      # WHY A MASK AND NOT A DISPATCH TABLE. Object#send IS available (this
      # gem declares mruby-metaprog since 18cc2f5), so the old reason for this
      # shape is gone -- but the shape is right anyway, on two grounds that do
      # not expire. A table of Method objects still needs the Method class,
      # and mruby-method is one of the gems this gem does not declare. And
      # SPEED: this loop is the hot path of the whole engine -- Rater.measure
      # calls it once per board, the generator measures up to 16 boards per
      # chain walk plus a ~27-board floor neighbourhood, and :master runs 150
      # of those. Eight guarded ifs cost one bitwise AND per rule per pass;
      # eight `send`s cost eight symbol dispatches per pass.
      def self.solve(values, rules = ALL_RULES)
        work = values.dup
        cand = candidate_grid(work)
        hardest = nil
        counts = {}
        passes = 0

        do_naked_single  = (rules & RULE_BIT[:naked_single]) != 0
        do_hidden_single = (rules & RULE_BIT[:hidden_single]) != 0
        do_pointing      = (rules & RULE_BIT[:pointing]) != 0
        do_naked_pair    = (rules & RULE_BIT[:naked_pair]) != 0
        do_naked_triple  = (rules & RULE_BIT[:naked_triple]) != 0
        do_hidden_pair   = (rules & RULE_BIT[:hidden_pair]) != 0
        do_hidden_triple = (rules & RULE_BIT[:hidden_triple]) != 0
        do_x_wing        = (rules & RULE_BIT[:x_wing]) != 0

        while passes < MAX_PASSES
          passes += 1

          if do_naked_single
            i = find_naked_single(cand)
            if i
              place(work, cand, i, Grid::BIT_LIST[cand[i]][0])
              hardest = harder(hardest, :naked_single)
              tally(counts, :naked_single)
              next
            end
          end

          if do_hidden_single
            spot = find_hidden_single(cand)
            if spot
              place(work, cand, spot[0], spot[1])
              hardest = harder(hardest, :hidden_single)
              tally(counts, :hidden_single)
              next
            end
          end

          if do_pointing && pointing(cand)
            hardest = harder(hardest, :pointing)
            tally(counts, :pointing)
            next
          end
          if do_naked_pair && naked_pair(cand)
            hardest = harder(hardest, :naked_pair)
            tally(counts, :naked_pair)
            next
          end
          if do_naked_triple && naked_triple(cand)
            hardest = harder(hardest, :naked_triple)
            tally(counts, :naked_triple)
            next
          end
          if do_hidden_pair && hidden_pair(cand)
            hardest = harder(hardest, :hidden_pair)
            tally(counts, :hidden_pair)
            next
          end
          if do_hidden_triple && hidden_triple(cand)
            hardest = harder(hardest, :hidden_triple)
            tally(counts, :hidden_triple)
            next
          end
          if do_x_wing && x_wing(cand)
            hardest = harder(hardest, :x_wing)
            tally(counts, :x_wing)
            next
          end

          break # nothing applies: stalled, and that is an answer
        end

        { values: work, solved: Grid.complete?(work), hardest: hardest,
          counts: counts }
      end
```

Everything below `solve` in the file is untouched.

- [ ] **Step 5: Run to GREEN**

Run: `make test`
Expected: PASS, KO 0, Crash 0, Warning 0. The rest of `sudoku_techniques.rb`
(600 lines pinning each rule) must stay green untouched — if any of it fails,
a guard was placed wrongly and one rule is no longer being tried.

- [ ] **Step 6: Commit**

```bash
git add mrbgems/mruby-redoku/mrblib/redoku/sudoku/techniques.rb \
        mrbgems/mruby-redoku/test/sudoku_techniques.rb
git commit -m "feat(redoku): let the technique solver run a restricted rule set"
```

---

### Task 2: Five rungs — the demand ladder, and everything that assumed three

**This task is large because the tier list's length and the rating contract
cannot change apart.** `Rater::CEILING` disappears, `Rater::TIERS` grows to
five, `measure` may answer `tier: nil`, and `Generator` calls three of the
methods being deleted. Every intermediate split leaves the tree red, so this
is one reviewable change: *the ladder*. Task 3 then changes how the generator
searches, which is a separate question with its own tests.

**Files:**
- Modify: `mrbgems/mruby-redoku/mrblib/redoku/sudoku/rater.rb`
- Modify: `mrbgems/mruby-redoku/mrblib/redoku/sudoku/generator.rb`
- Modify: `mrbgems/mruby-redoku/mrblib/redoku/app.rb` (one keyword)
- **Not** `renderer.rb`: `Renderer::DIFFICULTIES` was deleted in `75eb7cf`
  and `Rater::TIERS` is the only tier list. Nothing in the renderer knows how
  many rungs there are.
- Modify: `mrbgems/mruby-redoku/test/_support.rb` (three fixtures)
- Modify: `mrbgems/mruby-redoku/test/sudoku_rater.rb` (large rewrite)
- Modify: `mrbgems/mruby-redoku/test/sudoku_generator.rb`
- Modify: `mrbgems/mruby-redoku/test/app.rb` (`% 3`, FakeGenerator)

**Interfaces:**
- Consumes: `Techniques.solve`, `Techniques.solves?`, `Techniques::ORDER`
  (runtime only — see Global Constraint 3), `Rater.points`, `Rater::WEIGHT`.
- Produces:
  - `Rater::TIERS` = `[:easy, :medium, :hard, :expert, :master]`
  - `Rater::DEMANDS` = `[:singles, :locked, :subset, :xwing]`
  - `Rater::DEMAND_SETS` — four Arrays of rule symbols, each a superset of the
    last, and each — as a *set* — a contiguous prefix of `Techniques::ORDER`
    (see Step 4; the classifier's early break depends on it)
  - `Rater::DEMAND_RANGE` — demand → `[first_tier_index, last_tier_index]`
  - `Rater::DEMAND_EDGES` — demand → Array of score edges inside its range
  - `Rater::RULE_LEVEL` — rule symbol → its index in `DEMANDS`
  - `Rater.rank(tier)` → index in `TIERS`, or `-1` for nil/unknown
  - `Rater.upper_bound(counts)` → Integer index into `DEMANDS`
  - `Rater.demand_of(values, counts)` → a symbol from `DEMANDS`
  - `Rater.tier_for(demand, score)` → a symbol from `TIERS`, or nil
  - `Rater.measure(values)` → the hash in **Contracts** above
  - `Rater.rate` / `.score` → tier or nil / Integer or nil
  - **Gone:** `CEILING` `TOLERANCE_POINTS` `TOLERANCE_PERCENT` `GUESS`
    `STALL_FLOOR` `TECHNIQUE_FLOOR` `slack` `accepts?` `in_band?` `band`
    `band_for` `harder_tier`, and `measure`'s `:guesses` and
    `:technique_points` keys
  - `App.new(..., generator: Sudoku::Generator)` — a new keyword
  - Fixtures `LOCKED_81`, `PAIR_81`, `XWING_81` in `test/_support.rb`

- [ ] **Step 1: Write the failing test for the ladder tables**

In `test/sudoku_rater.rb`, **replace** the assertion named `'Rater bands tile
the whole score range with no gap or overlap'` (lines 51–73 at HEAD; line 57 is
the `TIERS.size == CEILING.size` pin) and the two that follow it,
`'Rater.band_for places a score in exactly one band'` (`:75`) and
`'Rater.harder_tier takes the harder of two, and unknowns lose'` (`:88`),
with:

```ruby
assert('Rater has five rungs, named so the font can print them') do
  r = Redoku::Sudoku::Rater
  assert_equal([:easy, :medium, :hard, :expert, :master], r::TIERS)
  # Font::GLYPHS holds A-Z 0-9 space - : . and NOTHING else, and Font.draw
  # silently draws nothing for a missing glyph while still advancing the
  # cursor -- so :very_hard would print as "VERY", a gap, "HARD", with no
  # error anywhere and no test to catch it. Every rung name is checked against
  # the real glyph table, which is the only thing that can settle it.
  r::TIERS.each do |tier|
    tier.to_s.upcase.each_char do |ch|
      assert_true Redoku::Font::GLYPHS.has_key?(ch)
    end
  end
end

assert('Rater demand classes tile the tier ladder with no gap or overlap') do
  r = Redoku::Sudoku::Rater
  # The ladder is meant to be data: adding a rung is an edit to TIERS,
  # DEMAND_RANGE and DEMAND_EDGES and nothing else. This pins the DERIVATION
  # rather than today's five values.
  assert_equal(r::DEMAND_SETS.size, r::DEMANDS.size)
  assert_equal(r::DEMANDS.size, r::DEMAND_RANGE.size)

  # Each class owns a contiguous run of tiers; the runs abut, start at 0 and
  # finish at the top rung. A gap would make a tier unreachable; an overlap
  # would make a board's tier ambiguous.
  expected_first = 0
  r::DEMANDS.each do |demand|
    range = r::DEMAND_RANGE[demand]
    assert_false range.nil?
    assert_equal(expected_first, range[0])
    assert_true range[1] >= range[0]
    expected_first = range[1] + 1
  end
  assert_equal(r::TIERS.size, expected_first)

  # A class of width w needs exactly w-1 score edges: one boundary fewer than
  # the rungs it spans. Absent means none, which is what every class but
  # :singles has.
  r::DEMANDS.each do |demand|
    range = r::DEMAND_RANGE[demand]
    edges = r::DEMAND_EDGES[demand] || []
    assert_equal(range[1] - range[0], edges.size)
    i = 1
    while i < edges.size
      assert_true edges[i] > edges[i - 1]
      i += 1
    end
  end

  # Only :singles is allowed to consult the score at all. That is the whole
  # fix: today's TECHNIQUE_FLOOR could only ever RAISE a tier, so a big enough
  # score promoted a singles-only board to the top -- measured, 55% of :hard
  # boards. A class whose range is one tier wide cannot be promoted by volume.
  assert_equal([140], r::DEMAND_EDGES[:singles])
  assert_equal(1, r::DEMAND_RANGE[:singles][1] - r::DEMAND_RANGE[:singles][0])
end

assert('Rater demand sets are nested and cover exactly ORDER') do
  r = Redoku::Sudoku::Rater
  t = Redoku::Sudoku::Techniques
  # DEFINED BY MEMBERSHIP, NOT BY INDEX, and this test is the guard rail on
  # that. ORDER puts naked_triple AHEAD of hidden_pair for readability, so a
  # ladder keyed on ORDER POSITIONS -- one rung per rule -- would let that
  # cosmetic choice decide a tier, and it measured badly: the per-rule prefix
  # ladder found 0 X-wing boards in 1467 where these four sets find 10 in 4852,
  # because it filed them under "pair".
  i = 1
  while i < r::DEMAND_SETS.size
    r::DEMAND_SETS[i - 1].each do |name|
      assert_true r::DEMAND_SETS[i].include?(name)
    end
    assert_true r::DEMAND_SETS[i].size > r::DEMAND_SETS[i - 1].size
    i += 1
  end

  # The strongest set is ORDER, spelled out rather than referenced: rater.rb
  # loads BEFORE techniques.rb (mrblib sorts full paths), so naming
  # Techniques::ORDER in a constant expression would take the gem down at
  # load. This assertion is what keeps the copy honest.
  top = r::DEMAND_SETS[r::DEMAND_SETS.size - 1]
  assert_equal(t::ORDER.size, top.size)
  t::ORDER.each { |name| assert_true top.include?(name) }

  # Every rule knows which class it belongs to, and it is the WEAKEST class
  # that contains it.
  t::ORDER.each do |name|
    level = r::RULE_LEVEL[name]
    assert_false level.nil?
    assert_true r::DEMAND_SETS[level].include?(name)
    assert_false r::DEMAND_SETS[level - 1].include?(name) if level > 0
  end
  # Triples sit with the PAIRS and are not a rung of their own. Boards that
  # genuinely require a triple turned up on 1 chain in 500; boards requiring an
  # X-wing on 10 in 500, ten times more common, because the subset rules all
  # narrow toward the same fixed point while X-wing reasons across two units.
  assert_equal(r::RULE_LEVEL[:naked_pair], r::RULE_LEVEL[:naked_triple])
  assert_equal(r::RULE_LEVEL[:naked_pair], r::RULE_LEVEL[:hidden_triple])
  assert_true r::RULE_LEVEL[:x_wing] > r::RULE_LEVEL[:hidden_triple]
end

assert('every demand set is a contiguous prefix of ORDER, which is what makes demand_of sound') do
  r = Redoku::Sudoku::Rater
  t = Redoku::Sudoku::Techniques
  # THE LOAD-BEARING ACCIDENT, PINNED. demand_of walks DOWN the ladder and
  # BREAKS the moment a set fails to solve the board -- which needs
  # "DEMAND_SETS[k-1] fails => DEMAND_SETS[k-2] fails", and that does NOT
  # follow from nesting alone. Adding a rule that sits EARLIER in ORDER can
  # pre-empt the rule the weaker run relied on and send the solve down a
  # different path, so "a bigger set still solves it" is not free in general.
  #
  # It IS free when every set is a contiguous prefix of ORDER, and here is the
  # argument, which is the one upper_bound already uses run backwards. Let F be
  # the rules that fired in a successful run with set S. At every state the
  # solver takes the FIRST rule in ORDER that fires, so no rule ahead of the
  # one it took fired at that state -- membership or not. Therefore any T with
  # F subset T subset ORDER takes exactly the same rule at every state, visits
  # exactly the same states, and solves. If S is a prefix and T is a longer
  # prefix then F subset S subset T, so T solves whenever S does; contrapose it
  # and the downward break is sound.
  #
  # Nothing else pins this. ORDER's own comment says its ordering is a
  # READABILITY choice and invites re-ordering, and today's boundaries happen
  # to fall at positions 2 and 7 -- either side of the naked_triple /
  # hidden_pair swap, not through it. Move one name across a boundary and the
  # break silently starts mis-classifying boards, with no other test failing.
  # So: this assertion, or delete the break from demand_of. Not neither.
  r::DEMAND_SETS.each do |set|
    set.each { |name| assert_true t::ORDER.include?(name) }
    # A prefix of length n as a SET: every one of ORDER's first n names is in
    # it, and nothing after them is. Order WITHIN the array is irrelevant --
    # mask_of ORs bits -- which is why this asks about membership, not indices.
    n = set.size
    i = 0
    while i < t::ORDER.size
      assert_equal(i < n, set.include?(t::ORDER[i]))
      i += 1
    end
  end
end

assert('Rater.rank orders the tiers and puts a reject below all of them') do
  r = Redoku::Sudoku::Rater
  assert_equal(0, r.rank(:easy))
  assert_equal(4, r.rank(:master))
  assert_true r.rank(:expert) > r.rank(:hard)
  # A reject and a typo both rank below every real tier, so neither can win a
  # "is this hard enough?" comparison by accident.
  assert_equal(-1, r.rank(nil))
  assert_equal(-1, r.rank(:not_a_tier))
end

assert('Rater.tier_for lets the score speak only inside :singles') do
  r = Redoku::Sudoku::Rater
  edge = r::DEMAND_EDGES[:singles][0]
  # The owner's "long, not clever" axis, and it is deliberately the BOTTOM of
  # the ladder rather than the top: a singles-only board is easy when short and
  # medium when long, and can be neither hard nor anything above it however
  # many singles it takes.
  assert_equal(:easy, r.tier_for(:singles, 0))
  assert_equal(:easy, r.tier_for(:singles, edge))
  assert_equal(:medium, r.tier_for(:singles, edge + 1))
  assert_equal(:medium, r.tier_for(:singles, 1_000_000))

  # Above :singles the score has nothing to say: a chain yields at most one or
  # two boards of any given non-singles class, so a per-tier edge there would
  # be a threshold that never fires.
  assert_equal(:hard, r.tier_for(:locked, 0))
  assert_equal(:hard, r.tier_for(:locked, 1_000_000))
  assert_equal(:expert, r.tier_for(:subset, 0))
  assert_equal(:expert, r.tier_for(:subset, 1_000_000))
  assert_equal(:master, r.tier_for(:xwing, 0))
  assert_equal(:master, r.tier_for(:xwing, 1_000_000))

  # An unknown demand has no tier rather than a wrong one.
  assert_nil r.tier_for(:not_a_demand, 100)
end
```

- [ ] **Step 2: Run it and confirm RED**

Run: `make test`
Expected: FAIL — `NameError: uninitialized constant
Redoku::Sudoku::Rater::DEMAND_SETS`, and the surviving old assertions still
pass.

- [ ] **Step 3: Write the failing test for `demand_of` and `measure`**

Still in `test/sudoku_rater.rb`, **replace** `'Rater.tier_for lets a technique
raise the tier but never lower it'` (`:98`), `'Rater.tier_for floors a stalled
board short of the hardest tier'` (`:136`), `'Rater.in_band? is strict and
accepts? forgives, in that order'` (`:150`), `'Rater.slack is the more generous
of a flat and a proportional margin'` (`:185`) — they test methods that are
being deleted — plus the **two** assertions that read `:guesses` /
`:technique_points` (`'Rater.measure reports a finished board as needing
nothing'` at `:198`, and `'Rater.measure adds guess points only for what
techniques cannot finish'` at `:210`, which goes away entirely because the
guess term has left the rating path) and `'Rater.rate and Rater.score agree
with measure'` (`:245`, which asserts a real tier for `MULTI_81` and for an
empty board — both rejects now). With:

```ruby
assert('Rater.upper_bound reads the demand ceiling straight off the counts') do
  r = Redoku::Sudoku::Rater
  # FREE, and this is why the classifier costs about one solve. The solve is
  # deterministic and tries rules in a fixed order, so a rule that DECLINED at
  # every step of the all-rules run declines at every step of a run without it
  # -- the two runs visit the same states. So the board is finished by the
  # weakest DEMAND_SET containing every rule that fired, and that is a table
  # lookup over `counts`.
  assert_equal(0, r.upper_bound({}))
  assert_equal(0, r.upper_bound({ naked_single: 30, hidden_single: 4 }))
  assert_equal(1, r.upper_bound({ naked_single: 30, pointing: 1 }))
  assert_equal(2, r.upper_bound({ pointing: 2, naked_triple: 1 }))
  assert_equal(3, r.upper_bound({ naked_single: 1, x_wing: 1 }))
  # A rule added to Techniques::ORDER and forgotten in RULE_LEVEL must make a
  # board look HARDER, never free -- the UNKNOWN_WEIGHT convention.
  assert_equal(r::DEMANDS.size - 1, r.upper_bound({ some_future_rule: 1 }))
end

assert('Rater.demand_of confirms the weakest set, because firing is not needing') do
  r = Redoku::Sudoku::Rater
  # The leave-one-out result that decides the whole design: over 120 generated
  # boards, the only rule ever INDIVIDUALLY indispensable was hidden_single
  # (3 boards). Pointing, both pairs, both triples and X-wing were never
  # necessary on their own, because the eliminators are confluent -- whenever
  # one was used, some other rule reached the same fixed point. So "which rule
  # fired" cannot be the tier, and demand_of has to confirm by re-solving with
  # the weaker set.
  easy = values_of(EASY_81)
  assert_equal(:singles, r.demand_of(easy, { naked_single: 2 }))
  # Hand it counts CLAIMING an X-wing fired on a board singles can finish: the
  # upper bound says :xwing, the confirming solves walk it all the way back
  # down to :singles. This is the assertion that pins "set inclusion, then
  # confirm" rather than "the hardest rule that fired".
  assert_equal(:singles, r.demand_of(easy, { x_wing: 1 }))
  assert_equal(:singles, r.demand_of(easy, { pointing: 3, naked_pair: 1 }))
end

assert('Rater.measure reports a finished board as needing nothing') do
  r = Redoku::Sudoku::Rater
  m = r.measure(solved_values)
  assert_equal(0, m[:score])
  assert_equal({}, m[:counts])
  assert_nil m[:hardest]
  assert_true m[:solved]
  assert_equal(:singles, m[:demand])
  assert_equal(:easy, m[:tier])
end

assert('Rater.measure answers tier nil for a board our rules cannot finish') do
  r = Redoku::Sudoku::Rater
  # A CONTRACT CHANGE, and the reason every caller has to be read: today's
  # measure always named a tier, flooring a stall at :medium and letting guess
  # points push it up. Under the no-guessing rule a board the eight rules
  # cannot finish is a REJECT -- not a hard puzzle, not a puzzle at all -- and
  # nil is how it says so. 199 of 4852 chain boards (4%) are rejects, and
  # because they crowd the chain floor, 109 of 500 chain FLOORS (22%) are.
  m = r.measure(values_of(MULTI_81))
  assert_nil m[:tier]
  assert_nil m[:demand]
  assert_nil m[:score]
  assert_false m[:solved]
  # The counts of the partial solve still come back: they are what the caller
  # would log, and throwing them away would make a reject undiagnosable.
  assert_false m[:counts].nil?

  # rate and score answer nil for the same board, so no caller can turn a
  # reject into arithmetic by accident.
  assert_nil r.rate(values_of(MULTI_81))
  assert_nil r.score(values_of(MULTI_81))
  assert_nil r.rate(Array.new(81, 0))
end

assert('Rater.rate and Rater.score agree with measure') do
  r = Redoku::Sudoku::Rater
  values = values_of(UNIQUE_81)
  m = r.measure(values)
  assert_equal(m[:tier], r.rate(values))
  assert_equal(m[:score], r.score(values))
  # Every board our rules FINISH gets a real rung.
  [SOLVED_81, EASY_81, UNIQUE_81].each do |board|
    assert_true r::TIERS.include?(r.rate(values_of(board)))
  end
end
```

Keep unchanged: `'Rater.points weights each use and discounts repeats'`,
`'Rater.points charges an unweighted technique as the hardest, not as free'`,
`'Rater weights rank locked candidates below the pairs'`, `'Rater.measure
scores a board with more holes above one with fewer'`, `'Rater is
deterministic and does not mutate the board it rates'`, `'Rater.clue_count
counts the filled cells'`. **Delete** `'Rater tiers are ordered easiest
first'` — the new first assertion of this file replaces it.

- [ ] **Step 4: Run it and confirm RED, then implement the Rater**

Run: `make test` — expect the new assertions to fail on missing constants.

In `rater.rb`: **delete** `GUESS`, `TECHNIQUE_FLOOR`, `CEILING`,
`TOLERANCE_POINTS`, `TOLERANCE_PERCENT`, `STALL_FLOOR`, and the methods
`band`, `band_for`, `harder_tier`, `in_band?`, `accepts?`, `slack`. Keep
`WEIGHT`, `UNKNOWN_WEIGHT`, `REPEAT_NUM`, `REPEAT_DEN`, `points`, `rate`,
`score`, `clue_count` and the whole class comment down to the "WHY COUNT USES
RATHER THAN TAKE THE MAXIMUM" paragraph. Then add, in place of what was
deleted:

```ruby
      # FIVE RUNGS, easiest first. Single upper-case words on purpose: Font's
      # glyph table holds A-Z 0-9 space - : . and nothing else, and Font.draw
      # silently draws NOTHING for a missing glyph while still advancing the
      # cursor -- so :very_hard would render as "VERY", a gap, "HARD", with no
      # error anywhere. Renderer#draw_header prints difficulty.to_s.upcase, so
      # the SYMBOL is the label.
      #
      # The header survives five names without a layout change: EXPERT and
      # MASTER are 6 characters, exactly as MEDIUM already is -- 175 px at
      # Layout::LABEL_SCALE 5, right-aligned to x = 1332, so starting at
      # x = 1157, against REDOKU ending at x = 352 at TITLE_SCALE 8.
      #
      # This is the ONLY tier list. Renderer::DIFFICULTIES used to hold a
      # second copy and was deleted in 75eb7cf for being exactly that; app.rb
      # and test/app.rb read TIERS directly. Do not reintroduce one.
      TIERS = [:easy, :medium, :hard, :expert, :master].freeze

      # THE RULE SETS THAT DEFINE THE LADDER, weakest first, each a superset of
      # the last. A board's DEMAND is the weakest of these that finishes it,
      # or nil -- a reject -- if even the strongest cannot.
      #
      # DEFINED BY MEMBERSHIP, NOT BY ORDER POSITION. ORDER lists naked_triple
      # AHEAD of hidden_pair (a readability choice recorded in techniques.rb),
      # so a ladder with one rung per ORDER position would let that cosmetic
      # ordering decide a tier -- and it measured badly: the per-rule prefix
      # ladder found 0 X-wing boards in 1467 where these four sets find 10 in
      # 4852, because it filed them under "pair". Getting that wrong does not
      # fail loudly; it silently makes the top rung unreachable.
      #
      # BUT NOTE WHAT IS ALSO TRUE, because demand_of's early break leans on
      # it: each of these four sets happens to be a CONTIGUOUS PREFIX of ORDER
      # taken as a set -- ORDER[0..1], [0..2], [0..6], [0..7]. The level
      # boundaries fall either side of the naked_triple / hidden_pair swap, not
      # through it. That is what licenses breaking out of the downward walk
      # (see demand_of), and it is an accident of where the boundaries landed,
      # so test/sudoku_rater.rb pins it explicitly. Moving a name across a
      # boundary, or re-ordering ORDER, breaks the soundness argument without
      # breaking any other test.
      #
      # TRIPLES SIT WITH THE PAIRS and are not a rung. Boards that genuinely
      # require a naked or hidden triple turned up on 1 chain in 500; boards
      # requiring an X-wing on 10 in 500, ten times more common. The subset
      # rules all narrow toward the same candidate fixed point, so a triple
      # rarely deduces anything the pairs did not (difficulty-rating.md
      # records hidden_triple never firing at all); X-wing reasons across two
      # units and is the only rule in our repertoire that adds a genuinely
      # different kind of inference.
      #
      # The strongest set is Techniques::ORDER, SPELLED OUT rather than
      # referenced: mrblib loads in sorted-path order, so rater.rb loads
      # BEFORE techniques.rb and naming Techniques::ORDER here would raise
      # NameError at load and take the whole gem down. test/sudoku_rater.rb
      # pins this copy against ORDER, and that test is the only thing keeping
      # the two in step -- the copy is forced by the load order, so it cannot
      # be removed the way Renderer::DIFFICULTIES was.
      DEMAND_SETS = [
        [:naked_single, :hidden_single].freeze,
        [:naked_single, :hidden_single, :pointing].freeze,
        [:naked_single, :hidden_single, :pointing, :naked_pair, :hidden_pair,
         :naked_triple, :hidden_triple].freeze,
        [:naked_single, :hidden_single, :pointing, :naked_pair, :hidden_pair,
         :naked_triple, :hidden_triple, :x_wing].freeze
      ].freeze

      # The name of each set, in the same order.
      DEMANDS = [:singles, :locked, :subset, :xwing].freeze

      # Which rungs a demand class may occupy, as [first, last] indices into
      # TIERS. THIS IS THE FIX. Today's TECHNIQUE_FLOOR could only ever RAISE
      # a tier, so a big enough score promoted a singles-only board to the top
      # -- measured, 22 of 40 :hard boards (55%) were solvable by naked and
      # hidden singles alone, and every one of 40 :medium boards was. Here the
      # class sets a CEILING as well as a floor, so volume can no longer buy
      # cleverness.
      DEMAND_RANGE = {
        singles: [0, 1].freeze,   # easy or medium, by score
        locked:  [2, 2].freeze,
        subset:  [3, 3].freeze,
        xwing:   [4, 4].freeze
      }.freeze

      # Score edges INSIDE a class's range: exactly one fewer than the range is
      # wide, so only :singles has any. This is all that is left of the old
      # CEILING, and it is the one place the owner's "long, not clever is more
      # fun" axis lives -- deliberately at the BOTTOM of the ladder, where the
      # owner finds it fun, rather than at the top, where it was wrong.
      #
      # 140 MEASURED, not chosen for roundness. EASY boards (44-45 clues)
      # score 97-117 over 500 chains, so any edge above 117 keeps them easy;
      # the deepest singles-only board on a chain scores p50 203. The edge
      # trades MEDIUM's reachability against how long a MEDIUM has to be:
      # 120 -> reachable on 99% of chains, 140 -> 89%, 160 -> 75%, 180 -> 66%,
      # 200 -> 51%, 230 -> 29%. 140 keeps a clear gap above EASY's worst case
      # and leaves MEDIUM reachable on nine chains in ten.
      DEMAND_EDGES = { singles: [140].freeze }.freeze

      # Rule -> the index of the WEAKEST demand class that contains it. Built
      # from DEMAND_SETS walking strongest to weakest so the weakest
      # assignment wins, because the sets are nested.
      def self.build_rule_level
        table = {}
        i = DEMAND_SETS.size - 1
        while i >= 0
          DEMAND_SETS[i].each { |name| table.store(name, i) }
          i -= 1
        end
        table
      end
      RULE_LEVEL = build_rule_level.freeze

      # Everything known about a board in one pass.
      #
      #   tier     which rung, or NIL for a reject -- see below
      #   demand   the weakest rule set that finishes it, or nil
      #   score    the weighted technique sum, or nil for a reject
      #   counts   how many times each technique was needed
      #   hardest  the hardest single technique that fired, or nil
      #   solved   whether the eight rules finished it
      #
      # tier: nil means REJECT: our rules cannot finish this board, so it is
      # not a puzzle we may ship under the no-guessing rule. CALLERS MUST
      # HANDLE NIL -- this is a contract change, today's measure always named a
      # tier.
      #
      # Solver.cost and the GUESS weight have LEFT the rating path entirely. A
      # scored board is by construction one the techniques finished, so the
      # guess term was always zero on every board that still gets a score.
      # Solver.cost stays as a diagnostic (its own tests pin it) and is simply
      # not called from here. Measured saving: p50 1.2 ms, max 11.4 ms per
      # stalled board -- small, and worth saying so rather than claiming a win.
      # The expensive half of a stalled board is Techniques.solve itself, at
      # 8.6-28.1 ms, because hidden_triple and x_wing are dear to DECLINE.
      def self.measure(values)
        result = Techniques.solve(values)
        unless result[:solved]
          return { tier: nil, demand: nil, score: nil, counts: result[:counts],
                   hardest: result[:hardest], solved: false }
        end
        score = points(result[:counts])
        demand = demand_of(values, result[:counts])
        { tier: tier_for(demand, score), demand: demand, score: score,
          counts: result[:counts], hardest: result[:hardest], solved: true }
      end

      # The weakest DEMAND_SET that finishes this board.
      #
      # `counts` gives an exact upper bound for FREE (see upper_bound), and the
      # solve that produced it is one the caller needed anyway to know the
      # board is not a reject. From there, walk DOWN the ladder confirming with
      # one solve each until a set fails; the last set that succeeded is the
      # demand. Only a board where a strong rule actually fired pays for any
      # confirming solve at all.
      #
      # WHY CONFIRM AT ALL, when a rule fired: because firing is not the same
      # as being needed. The eliminators are confluent -- over 120 boards no
      # eliminator was ever INDIVIDUALLY indispensable, because whenever one
      # was used another rule reached the same fixed point. Measured: x_wing
      # fired on 17 of ~3400 boards and on all 17 it really was needed; the
      # confirming solve is kept anyway, because 17/17 is an observation about
      # a corpus and not a theorem, and the cost of being wrong is a
      # mislabelled tier.
      #
      # WHY DOWNWARD AND NOT A CASCADE OF PER-RULE TESTS: a cascade that
      # branches on "did a subset rule fire?" after confirming the subset set
      # can return :locked without ever testing whether LOCKED solves the
      # board -- the rules that fire in a RESTRICTED run are not the rules that
      # fired in the full one. Walking down tests every set it claims.
      #
      # WHY THE BREAK IS SOUND, spelled out because it is subtler than it
      # looks and nothing else in this file says it. The loop stops at the
      # first failure and reports the set below it, which needs
      #
      #     DEMAND_SETS[k-1] fails to solve  =>  DEMAND_SETS[k-2] fails too
      #
      # and THAT DOES NOT FOLLOW FROM NESTING. A superset can contain a rule
      # that sits EARLIER in ORDER than the one the smaller run took, pre-empt
      # it, and walk a different path -- so "more rules cannot hurt" needs an
      # argument, not an appeal to obviousness.
      #
      # The argument is the one upper_bound uses, run backwards. At each state
      # the solver takes the FIRST rule in ORDER that fires, so no rule ahead
      # of it fired at that state, member of the set or not. So if F is the set
      # of rules that fired in a successful run, EVERY T with
      # F subset T subset ORDER takes the same rule at every state and solves.
      # When the sets are contiguous ORDER PREFIXES, S subset T gives
      # F subset S subset T, so T solves whenever S does -- and the
      # contrapositive is exactly the implication the break needs.
      #
      # So the break is sound BECAUSE the four sets are ORDER prefixes, which
      # they are today by where the boundaries happen to land. That is pinned
      # by 'every demand set is a contiguous prefix of ORDER' in
      # test/sudoku_rater.rb. If that test is ever deleted or a boundary moves,
      # delete the `break` and walk the whole ladder instead: it costs at most
      # three extra solves on the rare board that got past upper_bound, and it
      # needs no property of ORDER at all.
      #
      # (A confluence argument would give the same conclusion for ANY nested
      # sets -- these eight rules are all sound and monotone, so their closure
      # should not depend on the order they are tried in. That is a stronger
      # claim about how eight rules interact and nothing in this repository has
      # measured it, so it is not what the code leans on.)
      #
      # Measured cost over 500 chains: 1 solve per board at p50, mean 7 per
      # chain including the neighbourhood work, max 40.
      def self.demand_of(values, counts)
        k = upper_bound(counts)
        while k > 0
          break unless Techniques.solves?(values, DEMAND_SETS[k - 1])
          k -= 1
        end
        DEMANDS[k]
      end

      # The strongest class any rule that FIRED belongs to -- an exact upper
      # bound on the demand, at no cost.
      #
      # Sound because the solve is deterministic and tries rules in a fixed
      # order: a rule that declined at every step of the all-rules run
      # declines at every step of a run without it, since the two runs visit
      # exactly the same states. So the set of rules that fired is enough to
      # finish the board, and the weakest DEMAND_SET containing all of them is
      # therefore enough too. Note this needs NOTHING about prefixes -- any
      # superset of the fired rules will do, which is why the upper bound is
      # safe even if ORDER is re-ordered. demand_of's BREAK is the part that
      # is not; see there.
      def self.upper_bound(counts)
        k = 0
        counts.each_key do |name|
          level = RULE_LEVEL[name]
          # A rule added to Techniques::ORDER and forgotten in DEMAND_SETS is
          # treated as the STRONGEST class, for UNKNOWN_WEIGHT's reason: the
          # safety net firing should make a board look harder than it is, never
          # silently free.
          level = DEMANDS.size - 1 if level.nil?
          k = level if level > k
        end
        k
      end

      # The rung a board sits on: its demand class picks the run of tiers, and
      # the score picks within that run -- which only :singles is wide enough
      # to allow. An unknown demand has no tier rather than a wrong one.
      def self.tier_for(demand, score)
        range = DEMAND_RANGE[demand]
        return nil if range.nil?
        i = range[0]
        edges = DEMAND_EDGES[demand]
        if edges
          j = 0
          while j < edges.size && score > edges[j]
            i += 1
            j += 1
          end
        end
        # Cannot happen while every class has width-1 edges (a test pins that),
        # but a table typo must not index off the end of TIERS.
        i = range[1] if i > range[1]
        TIERS[i]
      end

      # Where a tier sits on the ladder. A reject (nil) and an unknown name
      # both rank BELOW every real tier, so neither can win an "is this hard
      # enough?" comparison by accident -- which is what Generator's monotone
      # dismissal leans on.
      def self.rank(tier)
        i = TIERS.index(tier)
        i.nil? ? -1 : i
      end
```

`rate` and `score` need no change — they already read `measure`'s keys, and
now return nil for a reject.

- [ ] **Step 5: Point the Generator at tier equality instead of score bands**

`generator.rb` calls `Rater.in_band?`, `Rater.accepts?` and `Rater.band`,
all three of which are now gone. Three edits, and no change of search
strategy — that is Task 3.

In `dig`, replace the body of the walk loop's accept tests:

```ruby
          board = board_at(solution, removals, k)
          m = Rater.measure(board)
          budget -= 1

          # EXACT TIER MATCH, not a score band. With a discrete class deciding
          # the tier there is no near miss to forgive, so the two-tier
          # strict/tolerant accept that CEILING needed is gone: it was solving
          # a problem that only exists when a continuous score decides a
          # discrete tier.
          return [board, m] if m[:tier] == tier

          # A reject is not a candidate for anything. It is not a hard puzzle,
          # it is not a puzzle: our rules cannot finish it, so a player would
          # have to guess.
          if !m[:tier].nil? && (best.nil? || closer?(m, best, tier))
            best = m
            best_board = board
          end
          k += 1
```

and delete the `near` / `near_board` machinery and the `return [near_board,
near] unless near.nil?` line with it — there is no tolerance left to hold a
board back for.

Replace `closer?` and delete `score_distance`:

```ruby
      # Is `a` a better answer than `b` for this request? Tier distance alone
      # now: the score cannot separate two candidates in different demand
      # classes in any way that means anything (a chain yields at most one or
      # two boards of any non-singles class), and inside :singles the tier
      # already carries the score's one distinction. Equal is not closer, so
      # the first candidate found wins a tie and the search stays
      # deterministic.
      def self.closer?(a, b, tier)
        tier_distance(a[:tier], tier) < tier_distance(b[:tier], tier)
      end

      # How many rungs apart two tiers are. A reject or an unknown name is
      # further away than any real tier, so it never wins.
      def self.tier_distance(got, wanted)
        gi = Rater.rank(got)
        wi = Rater.rank(wanted)
        return Rater::TIERS.size if gi < 0 || wi < 0
        gi >= wi ? gi - wi : wi - gi
      end
```

In `generate`, replace the accept test and drop the dead key:

```ruby
          candidate = {
            grid: Grid.new(puzzle),
            solution: solution,
            tier: m[:tier],
            demand: m[:demand],
            score: m[:score],
            hardest: m[:hardest],
            counts: m[:counts],
            clues: Rater.clue_count(puzzle)
          }
          return candidate if m[:tier] == tier
          best = candidate if best.nil? || closer?(candidate, best, tier)
```

`:guesses` leaves the reply because `measure` no longer computes it.

- [ ] **Step 6: There is no renderer step. Check that, do not skip it.**

An earlier draft of this plan had a step here that read *"grow
`Renderer::DIFFICULTIES` to five"*. **That constant does not exist.** It was
deleted in `75eb7cf` — one commit after the tree this plan was first written
against — as "dead weight next to `Sudoku::Rater::TIERS`, the real authority
the generator actually consumes", together with the test that pinned the two
lists equal. So the five names land once, in Step 4's `TIERS`, and the header
layout argument that used to live in the renderer comment has moved there
with them.

Confirm rather than assume, since it takes one command:

```bash
grep -rn "DIFFICULTIES" mrbgems/ PLAN.md docs/design
```

Expect **no hits** outside `docs/plans/`. If there are any, this plan is stale
again and Task 2 has a step it does not know about.

- [ ] **Step 7: Give the App a generator seam, and stop the tests assuming three tiers**

Two reasons, and the first is not convenience. Task 5 has to test that a
generation which RAISES is retried a few times and then leaves the board
alone, and that a generation which MISSES the tier is retried without limit.
Neither is drivable through the real generator: you cannot make it raise, and
a test that drives an unbounded loop against a real search either passes by
luck or hangs. The second reason is cost: with five rungs the two three-press
Level tests would traverse easy → medium → hard → expert and pay a real
`:hard` and `:expert` search each, which Task 3's attempt caps turn into
seconds per test.

In `app.rb`, add the keyword next to `rng:` and store it:

```ruby
    # `generator:` is the same kind of seam as `waiter`, `signals`, `clock` and
    # `rng`: the thing this loop cannot afford to run for real in a test. The
    # retry behaviour in fill_board is a control structure -- one path bounded,
    # one deliberately not -- and a control structure needs a collaborator that
    # can be told to fail. It also keeps the suite off the real search, which
    # for :expert is measured in seconds.
    def initialize(display, sources, renderer, waiter = RM2::Input,
                   signals = RM2, touch_sources: [], clock: RM2,
                   rng: Rng.from_clock, generator: Sudoku::Generator)
```

with `@generator = generator` beside `@rng = rng`, and `fill_board`'s call
changed from `Sudoku::Generator.generate(@difficulty, @rng)` to
`@generator.generate(@difficulty, @rng)`. Nothing else in `app.rb` changes in
this task.

In `test/app.rb`, add above `new_app`:

```ruby
# Stands in for Sudoku::Generator. Deals a real, uniquely-solvable board from
# the shared fixtures -- so every assertion about "the App holds a puzzle"
# still means something -- and lets a test say what should happen instead:
# a tier miss, nil, or a raise.
#
# It does NOT call the progress block unless asked to (progress: true), so the
# update-count assertions in this file keep counting what they counted before.
# Task 5's bar tests opt in.
class FakeGenerator
  attr_reader :calls, :tiers_asked

  def initialize(tier: nil, fail_with: nil, answer_nil: false,
                 progress: false, attempts: 4)
    @tier = tier            # nil means "answer the tier that was asked for"
    @fail_with = fail_with  # a String: raise RuntimeError with it, every call
    @answer_nil = answer_nil
    @progress = progress
    @attempts = attempts
    @calls = 0
    @tiers_asked = []
  end

  # Two fixtures alternating, so 'New deals a DIFFERENT puzzle' has something
  # to see. Both are uniquely solvable (test/sudoku_solver.rb pins that).
  BOARDS = [EASY_81, UNIQUE_81].freeze

  def generate(tier, _rng, attempts = nil)
    @calls += 1
    @tiers_asked << tier
    total = attempts || @attempts
    if block_given?
      i = 0
      while i < total && @progress
        i += 1
        yield(i, total)
      end
    end
    raise RuntimeError, @fail_with if @fail_with
    return nil if @answer_nil
    board = BOARDS[(@calls - 1) % BOARDS.size]
    {
      grid: Redoku::Sudoku::Grid.parse(board),
      solution: solved_values,
      tier: @tier.nil? ? tier : @tier,
      demand: :singles, score: 6, hardest: :naked_single,
      counts: { naked_single: 2 },
      clues: Redoku::Sudoku::Rater.clue_count(values_of(board)),
      attempts: 1
    }
  end
end
```

and thread it through the helper:

```ruby
def new_app(batches = [], rng: Redoku::Rng.new(GEN_SEED),
            generator: FakeGenerator.new)
  d = TestDisplay.new
  input = FakeInput.new(batches)
  signals = FakeSignals.new
  app = Redoku::App.new(d, [input], Redoku::Renderer.new(d),
                        FakeWaiter.new([input]), signals, rng: rng,
                        generator: generator)
  [app, d, input, signals]
end
```

Add the same `generator:` keyword to `new_touch_app`, defaulting the same way.

Then fix the two places that hard-code three tiers. **Re-verify these line
numbers before editing** — they have moved twice already; `grep -n "% 3"
mrbgems/mruby-redoku/test/app.rb` settles it. At HEAD they are
`test/app.rb:759` (inside `'the acknowledgement runs each action exactly
once'`) and `:909` (inside `'a tap on Level cycles the difficulty and repaints
the header'`), and both read

```ruby
    Redoku::Sudoku::Rater::TIERS[(i + 1) % 3]
```

— **`Rater::TIERS`, not `Renderer::DIFFICULTIES`**, since `75eb7cf` collapsed
the two lists. Both become

```ruby
    list = Redoku::Sudoku::Rater::TIERS
    assert_equal(list[(i + 1) % list.size], app.difficulty)
```

(and at `:909`, `expected = list[(i + 1) % list.size]`). Leave the enclosing
`3.times do |i|` alone: three presses from `:easy` now visit medium, hard and
expert, which is a better test of the cycle than three presses that wrap.
With a FakeGenerator behind `new_app`, those three presses cost nothing.

**Which App tests keep the REAL generator, and what that costs.** Six of the
fourteen `Redoku::App.new` call sites in `test/app.rb` construct an App
directly *and* reach a dig. They keep the real generator, which they get for
free from `App`'s own default, and they must not be converted to `new_app` —
two of them exist precisely to observe the real thing:

| test | tier(s) dug for real |
|---|---|
| `'every button acknowledges its press, at the button, for the same 200 ms'` (`:657`) | `:easy` (New), `:medium` (Level) |
| `'the action runs while the button is held down, not after it comes up'` (`:720`) | `:easy` |
| `'a Level press whose flash is refused still cycles the difficulty'` (`:803`) | `:medium` |
| `'a New press whose flash is refused still clears the ink'` (`:839`) | `:easy` |
| `'the splash reaches the panel before generation starts'` (`:1450`) | `:easy` |
| `'an App given no rng seeds itself from the clock'` (`:1508`) | `:easy` |

`:easy` is p50 53 ms. `:medium` at its production cap of 12 is p50 90 ms but
p90 552 ms and max 1309 ms, and two tests pay it — that is within Global
Constraint 6 (which bars `:hard` and above at the production cap, not
`:medium`), but it is the suite's largest single cost and worth knowing before
blaming a slow run on Task 3.

**All six of these also gain a progress-bar update once Task 5 lands**, and
three of them assert exact update counts. Task 5 Step 5 lists what each one
becomes; do not fix them here, because the bar does not exist yet.

`GEN_SEED`'s comment is now wrong about what the suite pays for. Replace its
last paragraph with: *"Every App built through `new_app` now takes a
FakeGenerator, so this seed no longer prices the suite's digging — only the
six tests that construct an App directly generate for real, five of them at
`:easy` and two of them (New-and-Level, and the refused Level flash) at
`:medium`."*

- [ ] **Step 8: Rewrite the Generator tests that spoke in bands**

In `test/sudoku_generator.rb`:

**Delete** `'Generator.score_distance is zero inside the band and grows
outside'` (`:183`) — the method is gone.

**Leave `'Generator.tier_distance measures along the tier order'` (`:173`)
alone.** It asserts `tier_distance(:nonsense, :easy) > tier_distance(:hard,
:easy)`, which is `5 > 2` with five rungs instead of `3 > 2` with three. Still
true, still meaningful, no edit.

**Replace** `'Generator.closer? prefers the right tier, then the nearer
score'` with:

```ruby
assert('Generator.closer? prefers the tier nearer the one asked for') do
  gen = Redoku::Sudoku::Generator
  right = { tier: :hard }
  near = { tier: :medium }
  far = { tier: :easy }
  assert_true gen.closer?(right, near, :hard)
  assert_true gen.closer?(near, far, :hard)
  assert_false gen.closer?(far, near, :hard)
  # Equal is not closer, so the first candidate found wins a tie and the
  # search stays deterministic.
  assert_false gen.closer?(near, near, :hard)
  # A reject never wins: it is not a puzzle at all.
  assert_true gen.closer?(far, { tier: nil }, :hard)
  assert_false gen.closer?({ tier: nil }, far, :hard)
end
```

**Replace** the one assertion that reads `m[:guesses]` (`'Generator.generate
reports the measurement of the board it returns'`, `:301` — it is the only
place in `test/sudoku_generator.rb` that touches that key) and the tier-hit
test (`'Generator.generate hits every tier it is asked for'`, `:260`):

```ruby
assert('Generator.generate reports the measurement of the board it returns') do
  gen = Redoku::Sudoku::Generator
  r = Redoku::Sudoku::Rater
  # The reply must describe the board in it. A generator that reported the tier
  # it was ASKED for rather than the one it achieved would be lying, and the
  # header on screen would be lying with it.
  out = gen.generate(:hard, Redoku::Rng.new(61), 1)
  assert_false out.nil?
  m = r.measure(out[:grid].values)
  assert_equal(m[:tier], out[:tier])
  assert_equal(m[:demand], out[:demand])
  assert_equal(m[:score], out[:score])
  assert_equal(m[:hardest], out[:hardest])
end

assert('Generator.generate hits the two rungs the bottom of the ladder offers') do
  gen = Redoku::Sudoku::Generator
  s = Redoku::Sudoku::Solver
  # EASY and MEDIUM only, and that is not timidity: measured over 500 chains,
  # EASY is available on 500 of them and MEDIUM on 446 at EDGE 140, while HARD
  # is on 70, EXPERT on 43 and MASTER on 10. Asserting the upper rungs here
  # would mean paying their attempt caps -- MASTER is host p50 4.7 s / p90
  # 16.0 s -- inside `make test`. Their reachability is established once, by
  # the measurement script in this plan's Task 3, not by the suite.
  #
  # WHY MEDIUM IS SAFE TO ASSERT at 89% per chain: `generate` draws a FRESH
  # solution per attempt, so the six attempts of DEFAULT_ATTEMPTS are six
  # independent chains and the miss probability is 0.11^6, about two in a
  # million per seed. Reachability is also a property of the CHAIN and not of
  # the walk direction -- MEASURE_BUDGET (12 here, 16 after Task 3) covers the
  # whole measured 8-to-12-board window, so a shallow walk and a deep walk find
  # a MEDIUM board on exactly the same chains and differ only in which one they
  # return. That is why this assertion survives Task 3 unchanged.
  [:easy, :medium].each do |tier|
    3.times do |n|
      out = gen.generate(tier, Redoku::Rng.new(200 + (n * 7)))
      assert_equal(tier, out[:tier])
      assert_true s.unique?(out[:grid].values)
    end
  end
end
```

If a `:medium` seed here does miss, **do not weaken the assertion to
`TIERS.include?`** — that would delete the only end-to-end evidence that the
second rung is reachable at all. Swap the seed, and record in the commit
message that the 89% figure came out lower than the design measured, because
that is a finding about `DEMAND_EDGES[:singles]` and not about the test.

**Rewrite** `'Generator.generate always returns a playable puzzle, tier or
not'` (`:286`). It is the one assertion in the file that encodes the exact
invariant this plan deliberately breaks: it asserts `assert_false out.nil?`
and then dereferences `out[:grid]` on a `generate(:hard, rng, 1)` call that
may now legitimately answer nil, and it asserts
`TIERS.include?(out[:tier])` where nil is now a possible tier. No other step
touched it, and the suite would have gone red on a contract change it was
never told about:

```ruby
assert('Generator.generate answers a playable puzzle or nothing, never a lie') do
  gen = Redoku::Sudoku::Generator
  s = Redoku::Sudoku::Solver
  # One attempt, so the requested tier may well be missed -- and under the new
  # ladder a single attempt may also come back with NOTHING, which is the
  # contract change: `generate` is nil when no attempt found a single board our
  # rules can finish. Not observed in 500 chains, and this test does not assert
  # it either way; what it pins is that a NON-nil reply is a real puzzle with a
  # real tier. `if out` rather than an unconditional dereference is the whole
  # edit.
  out = gen.generate(:hard, Redoku::Rng.new(4), 1)
  if out
    assert_true s.unique?(out[:grid].values)
    assert_true Redoku::Sudoku::Rater::TIERS.include?(out[:tier])
    assert_false out[:tier].nil?
    assert_true out[:clues] <= gen::MAX_CLUES
  end
end
```

That `if out` is the one guard in this plan that is allowed to make a test
body skippable, and only because Task 3 Step 1's `'an impossible request comes
back honest rather than empty'` asserts the non-nil case unconditionally on a
seed chosen for it. If Task 3 is ever dropped, this one has to lose the guard.

In `'Generator.generate never hands back a board that is barely dug'`
(`:245`), change the tier list from `[:easy, :medium, :hard]` to
`[:easy, :medium]` and pass an explicit small budget
(`gen.generate(tier, Redoku::Rng.new(50), 6)`) for the same cost reason.

**Leave `'Generator.dig walks from the shallow end, so easy keeps its clues'`
(`:153`) alone in this task.** The earlier draft of this plan told you to
"change its tier list", and it has no tier list — it calls `gen.dig` twice,
once for `:easy` and once for `:hard`, on one chain, which is a single walk
each and costs nothing. Task 2 does not change the walk direction, so its two
assertions (`easy_clues >= hard_clues`, `easy_score <= hard_score`) should
still hold: `:easy` still returns the shallowest match and a `:hard` request
that cannot be met now settles for the nearest *tier*, which is the deepest
board it looked at. **If it does fail, delete it** rather than repairing it —
Task 3 Step 1 replaces it with `'only easy walks the shallow end of the
chain'`, which asks the question properly, and Task 3 Step 4 deletes it in any
case.

- [ ] **Step 9: Run to GREEN**

Run: `make test`
Expected: PASS, KO 0, Crash 0, Warning 0.

Two failures to expect and how to read them:

- **`Rater.measure` returning nil where a test wanted a tier.** Every such
  spot is a caller that has not been taught the new contract. Find them all —
  `grep -rn "measure\|\.rate(\|\.score(" mrbgems/mruby-redoku` — rather than
  patching the one the suite happened to reach first.
- **`generate` now returns a `:medium` board for a `:hard` request more
  often.** That is the point: 22 of 40 boards today's rater calls `:hard` are
  genuinely MEDIUM on this ladder, and 10 of 40 are rejects. The tests above
  assert an honest reply, not a hit.

- [ ] **Step 10: Mine the demand-class fixtures**

The fixtures in `_support.rb` are all singles-only, so nothing in the suite
yet exercises `:locked`, `:subset` or `:xwing` end to end. Get three real
boards, do not invent them. Write a throwaway script (delete it afterwards;
the design's §12 scripts worked exactly this way):

```ruby
# meas_fixtures.rb -- throwaway, run through the host mruby binary, which
# links the whole default gembox. Nothing here is constrained by what the gem
# declares.
gen = Redoku::Sudoku::Generator
r = Redoku::Sudoku::Rater
seen = {}
1.upto(400) do |seed|
  rng = Redoku::Rng.new(seed)
  solution = gen.full_board(rng)
  chain = gen.dig_chain(solution, rng)
  removals = chain[0]
  k = removals.size
  board = gen.board_at(solution, removals, k)
  m = r.measure(board)
  next if m[:tier].nil?
  next if seen[m[:demand]]
  seen.store(m[:demand], true)
  puts "seed=#{seed} demand=#{m[:demand]} tier=#{m[:tier]} score=#{m[:score]}"
  puts Redoku::Sudoku::Grid.new(board).givens_s
end
```

If `:xwing` does not turn up in 400 chain floors — it is 2 per 100 chains and
7 of 10 of them come from a stalled floor's neighbourhood, not the floor
itself — extend the script with Task 3's `rescue_floor` once that exists, and
come back for this fixture then. Do **not** hand-write an 81-character board
and hope.

Append the three boards to `test/_support.rb` with the seed they came from,
then pin their class by DEFINITION rather than by the classifier that found
them:

```ruby
# --- demand-class fixtures. Mined from real dig chains (the seeds are
# recorded so each is reproducible) because a board that genuinely REQUIRES an
# eliminator cannot be written by hand with any confidence. Each is pinned
# below by the definition of its class -- the weakest DEMAND_SET that finishes
# it -- and not by Rater.demand_of, so the test can fail the classifier.

# Needs pointing / box-line: singles alone stall on it. seed=<n>
LOCKED_81 = '<81 chars>'

# Needs a subset rule (a naked or hidden pair or triple): singles plus
# pointing stall on it. seed=<n>
PAIR_81 = '<81 chars>'

# Needs an X-wing: every weaker set stalls on it. seed=<n>
XWING_81 = '<81 chars>'
```

and append to `test/sudoku_rater.rb`:

```ruby
assert('Rater classifies real boards by the weakest rule set that finishes them') do
  r = Redoku::Sudoku::Rater
  t = Redoku::Sudoku::Techniques

  # Each fixture's class is asserted from the DEFINITION first -- the weakest
  # DEMAND_SET that solves it -- so this test can fail demand_of rather than
  # agreeing with it by construction.
  locked = values_of(LOCKED_81)
  assert_false t.solves?(locked, r::DEMAND_SETS[0])
  assert_true t.solves?(locked, r::DEMAND_SETS[1])
  assert_equal(:locked, r.measure(locked)[:demand])
  assert_equal(:hard, r.measure(locked)[:tier])

  subset = values_of(PAIR_81)
  assert_false t.solves?(subset, r::DEMAND_SETS[1])
  assert_true t.solves?(subset, r::DEMAND_SETS[2])
  assert_equal(:subset, r.measure(subset)[:demand])
  assert_equal(:expert, r.measure(subset)[:tier])

  xwing = values_of(XWING_81)
  assert_false t.solves?(xwing, r::DEMAND_SETS[2])
  assert_true t.solves?(xwing, r::DEMAND_SETS[3])
  assert_equal(:xwing, r.measure(xwing)[:demand])
  assert_equal(:master, r.measure(xwing)[:tier])

  # And the ceiling really is a ceiling: however long these boards are, none
  # of them can be promoted past its class, and no singles-only board can
  # reach any of their rungs.
  assert_equal(:medium, r.tier_for(:singles, 10_000))
end
```

- [ ] **Step 11: Run to GREEN and commit**

Run: `make test`
Expected: PASS, KO 0, Crash 0, Warning 0. Delete the throwaway script.

```bash
git add mrbgems/mruby-redoku/mrblib/redoku/sudoku/rater.rb \
        mrbgems/mruby-redoku/mrblib/redoku/sudoku/generator.rb \
        mrbgems/mruby-redoku/mrblib/redoku/app.rb \
        mrbgems/mruby-redoku/test/_support.rb \
        mrbgems/mruby-redoku/test/sudoku_rater.rb \
        mrbgems/mruby-redoku/test/sudoku_generator.rb \
        mrbgems/mruby-redoku/test/app.rb
git commit -m "feat(redoku): rate difficulty by what a board demands, on five rungs"
```

---

### Task 3: Dig for the demand — deep-end walk, floor rescue, per-tier budgets

Two independent defects, fixed by two independent changes in this task, and
they must not be conflated:

- **`dig` walks the chain from the SHALLOW end** and returns the first board
  that qualifies, so every tier ships the most-clued board that barely
  passes. That costs `:medium` 4 clues at the median (up to 10) and upgrades
  its demand class on **17 of 39 chains** — it is the whole of the MEDIUM
  complaint, and fixing it is **free**, because the chain is already dug.
  `:easy` keeps the shallow walk, where the bias is a feature.
- **The tier was decided by a sum**, so volume faked difficulty. That is the
  HARD complaint and Task 2 fixed it.

**Files:**
- Modify: `mrbgems/mruby-redoku/mrblib/redoku/sudoku/generator.rb`
- Modify: `mrbgems/mruby-redoku/test/sudoku_generator.rb`

**Interfaces:**
- Consumes: `Rater.measure`, `Rater.rank`, `Rater.clue_count`,
  `Generator.dig_chain`, `.board_at`, `.first_usable` (all unchanged).
- Produces:
  - `Generator::ATTEMPTS` = `{ easy: 6, medium: 12, hard: 60, expert: 60,
    master: 150 }`
  - `Generator::WALK_SHALLOW` = `:easy`
  - `Generator::MEASURE_BUDGET` raised to 16
  - `Generator.attempts_for(tier)` → Integer
  - `Generator.hard_end(solution, removals)` → `[board, measurement]` or
    `[nil, nil]`
  - `Generator.rescue_floor(solution, removals, floor)` → same
  - `Generator.shallow_fallback(solution, removals, clues_after)` → same
  - `Generator.walk_up(solution, removals, clues_after, tier)` → same
  - `Generator.shallow_walk(solution, removals, clues_after, tier)` → same
  - `Generator.deep_walk(solution, removals, clues_after, tier)` → same
  - `Generator.dig(solution, tier, rng)` → same shape as today
  - `Generator.generate(tier, rng, attempts = nil) { |done, total| }` → the
    candidate hash (now with `attempts:`) or **nil**

- [ ] **Step 0: Mine the two seeds these tests need**

**Do this before writing the tests, because two of them are meaningless
without it.** The rescue path is where 7 of 10 measured `:master` boards come
from, and a test that covers it only *if* its seed happens to reach a rejected
floor is a test that can ship zero coverage under a green suite. So the seeds
are chosen, not hoped for. Throwaway script, same discipline as Task 2 Step 10
and the design's §12:

```ruby
# meas_floors.rb -- throwaway.
gen = Redoku::Sudoku::Generator
r = Redoku::Sudoku::Rater
1.upto(60) do |seed|
  solution = gen.full_board(Redoku::Rng.new(seed))
  chain = gen.dig_chain(solution, Redoku::Rng.new(seed))
  removals = chain[0]
  floor = gen.board_at(solution, removals, removals.size)
  m = r.measure(floor)
  # rescue_floor does not exist yet, so inline what it will do: restore each
  # removed group in turn and keep the hardest board our rules can finish.
  saved = nil
  removals.each do |g|
    b = floor.dup
    b[g[0]] = solution[g[0]]
    b[g[1]] = solution[g[1]]
    mm = r.measure(b)
    saved = mm[:tier] if !mm[:tier].nil? && saved.nil?
  end
  puts "seed=#{seed} floor_tier=#{m[:tier].inspect} rescue=#{saved.inspect}"
end
```

Record two seeds in the tests below, by name:

- **`SOLVED_FLOOR_SEED`** — a seed whose floor our rules CAN finish
  (`floor_tier` not nil; about 78% of seeds qualify). Used by `'the hard end of
  a chain is its floor'`.
- **`REJECT_FLOOR_SEED`** — a seed whose floor is a REJECT and whose
  neighbourhood yields a board (`floor_tier=nil`, `rescue` not nil; about 22%
  of seeds reach the first condition). Used by `'a rejected floor is
  rescued'`.

Declare them at the top of `test/sudoku_generator.rb`, with the measured
values recorded in the comment the way Task 2 Step 10 records the fixture
seeds:

```ruby
# Two dig-chain seeds chosen for what their FLOOR is, because three assertions
# below are unconditional and would be meaningless otherwise. Mined by a
# throwaway script over seeds 1-60 (see the plan's Task 3 Step 0); rerun it if
# the rater or the dig ever changes, because these are properties of the
# CLASSIFIER, not of the seed.
SOLVED_FLOOR_SEED = <n>  # floor_tier: <tier>   -- our rules finish this floor
REJECT_FLOOR_SEED = <n>  # floor_tier: nil, rescue: <tier> -- floor is a reject
```

Then delete the script. **`13` was this plan's placeholder in both tests and
is not a measured value**; using it unchecked is exactly how both tests became
vacuous.

- [ ] **Step 1: Write the failing test for the walk direction and the rescue**

Append to `test/sudoku_generator.rb`:

```ruby
assert('Generator attempt budgets are per tier, because the rungs differ 50x') do
  gen = Redoku::Sudoku::Generator
  # One number cannot be right for both ends: a chain can serve EASY 100% of
  # the time and MASTER 2% of the time. Measured hit rates at these caps
  # (500-chain bootstrap, 500 trials): 100% / 100% / 100% / 99% / 94%.
  Redoku::Sudoku::Rater::TIERS.each do |tier|
    assert_false gen::ATTEMPTS[tier].nil?
    assert_true gen::ATTEMPTS[tier] > 0
  end
  assert_true gen::ATTEMPTS[:master] > gen::ATTEMPTS[:easy]
  assert_equal(gen::ATTEMPTS[:easy], gen.attempts_for(:easy))
  # An unrecognised tier still gets a real cap rather than nil, because
  # nil.times is a crash and this runs behind a splash on a device whose only
  # escape is the power button.
  assert_equal(gen::DEFAULT_ATTEMPTS, gen.attempts_for(:not_a_tier))
end

assert('only easy walks the shallow end of the chain') do
  gen = Redoku::Sudoku::Generator
  # THE MEDIUM FIX, and it costs nothing: the chain is already dug, so walking
  # from the deep end is the same work in the other direction. Measured over
  # 40 chains it is worth 4 clues at the median (up to 10) and upgrades the
  # demand class on 17 of 39 chains. For EASY the shallow bias is a FEATURE --
  # the deep end of a chain is 33-34 clues, and a first-rung puzzle should look
  # generously clued -- so easy keeps it, alone.
  assert_equal(:easy, gen::WALK_SHALLOW)

  # SOLVED_FLOOR_SEED, not an arbitrary one: the two `hard_end` assertions
  # below were guarded with `if hard[0]` in an earlier draft and would have
  # gone vacuous on a chain whose floor rejects. A seed whose floor is solvable
  # is the cheapest way to make them unconditional.
  solution = gen.full_board(Redoku::Rng.new(SOLVED_FLOOR_SEED))
  chain = gen.dig_chain(solution, Redoku::Rng.new(SOLVED_FLOOR_SEED))
  removals = chain[0]
  clues_after = chain[1]

  easy = gen.shallow_walk(solution, removals, clues_after, :easy)
  assert_false easy[1].nil?
  assert_equal(:easy, easy[1][:tier])
  easy_clues = Redoku::Sudoku::Rater.clue_count(easy[0])
  # 44-45 clues over 500 measured chains, and never more than MAX_CLUES.
  assert_true easy_clues <= gen::MAX_CLUES
  assert_true easy_clues >= 40

  # The hard end of the same chain is the FLOOR, which is strictly deeper.
  hard = gen.hard_end(solution, removals)
  assert_false hard[0].nil?
  assert_false hard[1].nil?
  assert_true Redoku::Sudoku::Rater.clue_count(hard[0]) < easy_clues
end

assert('the hard end of a chain is its floor, and its class never decreases') do
  gen = Redoku::Sudoku::Generator
  r = Redoku::Sudoku::Rater
  # The monotonicity that makes the whole design affordable: 0 class DECREASES
  # in 527 adjacent chain steps, and it is provable in the direction that
  # matters -- restoring givens can only remove candidates, so a board with
  # more givens is solved by every rule set that solves the board with fewer.
  # So the hardest board on a chain is its floor, and ONE classification of the
  # floor decides whether the whole chain can serve a request.
  #
  # THIS SEED'S FLOOR IS SOLVABLE, and that is asserted rather than assumed.
  # An earlier draft guarded the floor assertion with `if
  # r.measure(floor)[:tier]`, which meant a change that made every floor reject
  # would delete this test's subject and leave the suite green. Mined by Step 0
  # (measured floor_tier: <tier>).
  solution = gen.full_board(Redoku::Rng.new(SOLVED_FLOOR_SEED))
  chain = gen.dig_chain(solution, Redoku::Rng.new(SOLVED_FLOOR_SEED))
  removals = chain[0]
  clues_after = chain[1]

  floor = gen.board_at(solution, removals, removals.size)
  assert_false r.measure(floor)[:tier].nil?
  out = gen.hard_end(solution, removals)
  m = out[1]
  assert_false m.nil?
  # A solvable floor IS the hard end, untouched -- unconditionally, now that
  # the line above has established the floor is solvable.
  assert_equal(floor, out[0])

  # No board shallower on the chain demands more than the hard end does. The
  # non-nil assertion is not defensive padding -- it is the restoring argument
  # stated as a test: this floor is solvable, so every shallower board must be
  # too. If it ever fires, the argument is WRONG and the monotone dismissal is
  # unsound, which is a finding about the design rather than a broken test.
  # (0 class decreases in 527 measured adjacent chain steps agree with it.) An
  # earlier draft wrote `unless shallower[:tier].nil?` here, which would have
  # let the whole loop skip in silence.
  k = gen.first_usable(clues_after)
  while k <= removals.size
    shallower = r.measure(gen.board_at(solution, removals, k))
    assert_false shallower[:tier].nil?
    assert_true r.rank(shallower[:tier]) <= r.rank(m[:tier])
    k += 1
  end
end

assert('a rejected floor is rescued by restoring one symmetric group') do
  gen = Redoku::Sudoku::Generator
  s = Redoku::Sudoku::Solver
  r = Redoku::Sudoku::Rater
  # 22% of chain floors (109 of 500) are boards our rules cannot finish. A
  # rejected floor is not a wasted dig: restore any one removed GROUP and the
  # board is a different legal puzzle, still 180-degree symmetric and still
  # uniquely solvable for free -- the restored givens come from the same
  # solution, so its solution set is a subset of the floor's, and the floor was
  # unique. This is where the hard rungs come from: of 10 MASTER boards found
  # in 500 chains, 7 came from a stalled floor's neighbourhood.
  #
  # THE SEED IS CHOSEN FOR ITS FLOOR, and both facts about it are asserted
  # before anything else runs. An earlier draft wrapped this whole body in
  # `unless out[0].nil?`, which meant the rescue path -- the source of 7 of 10
  # measured MASTER boards -- could ship with zero coverage and a green suite.
  # Mined by Step 0 (measured floor_tier: nil, rescue: <tier>).
  solution = gen.full_board(Redoku::Rng.new(REJECT_FLOOR_SEED))
  chain = gen.dig_chain(solution, Redoku::Rng.new(REJECT_FLOOR_SEED))
  removals = chain[0]
  floor = gen.board_at(solution, removals, removals.size)
  assert_nil r.measure(floor)[:tier]

  out = gen.rescue_floor(solution, removals, floor)
  assert_false out[0].nil?
  board = out[0]
  # Two more clues than the floor (one, if it was the centre group), and the
  # extra clues agree with the solution.
  assert_true r.clue_count(board) > r.clue_count(floor)
  81.times { |i| assert_equal(solution[i], board[i]) if board[i] != 0 }
  # Still symmetric, and still unique -- asserted here even though the proof
  # above says no Solver.unique? call is NEEDED, because the proof is what
  # licences skipping the call in production and a wrong proof would be
  # invisible.
  81.times { |i| assert_equal(0, board[80 - i]) if board[i] == 0 }
  assert_true s.unique?(board)
  # And it is a board our rules CAN finish, which is the whole point.
  assert_false out[1][:tier].nil?
  # ...and hard_end routes through the rescue rather than handing back the
  # reject, which is the only thing that connects this method to the search.
  assert_equal(board, gen.hard_end(solution, removals)[0])
end

assert('a chain with nothing our rules can finish yields nothing, not a bad puzzle') do
  gen = Redoku::Sudoku::Generator
  r = Redoku::Sudoku::Rater
  # The nil path, driven directly, because generate cannot be steered into it:
  # it needs a chain where the floor AND all ~27 of its neighbours AND the
  # shallowest usable board all reject, which was not observed in 500 chains.
  # Built by hand instead -- blank everything but the middle row, symmetrically.
  solution = solved_values
  removals = []
  36.times { |i| removals << [i, 80 - i] }
  clues_after = [81]
  removals.size.times { |k| clues_after << 81 - (2 * (k + 1)) }

  floor = gen.board_at(solution, removals, removals.size)
  assert_nil r.measure(floor)[:tier]
  out = gen.rescue_floor(solution, removals, floor)
  assert_nil out[0]
  assert_nil out[1]

  # THE SHALLOW FALLBACK REJECTS TOO, and this is a PROOF rather than a
  # measurement, which is what makes the nil below non-accidental. The
  # shallowest board MAX_CLUES allows on this hand-built chain is k = 18: rows
  # 0, 1, 7 and 8 blank, rows 2 to 6 given. Swapping the contents of rows 0 and
  # 1 -- two rows of the SAME 3x3 band -- leaves every row, column and box
  # holding the same digits, so it is a second valid solution. A board with two
  # solutions cannot be finished by rules that only ever write forced cells, so
  # it stalls, so it is a reject.
  shallow = gen.board_at(solution, removals, gen.first_usable(clues_after))
  assert_nil r.measure(shallow)[:tier]
  fall = gen.shallow_fallback(solution, removals, clues_after)
  assert_nil fall[0]
  assert_nil fall[1]

  # Only now can the deep walk honestly answer nothing, and it must -- rather
  # than inventing a board or handing back the reject.
  deep = gen.deep_walk(solution, removals, clues_after, :hard)
  assert_nil deep[0]
  assert_nil deep[1]
end

assert('the shallow fallback is the shallowest usable board, or nothing') do
  gen = Redoku::Sudoku::Generator
  r = Redoku::Sudoku::Rater
  # design section 6.4's fallback, and the reason `generate` almost never
  # answers nil. In production it fires only on the never-observed path where
  # the floor AND its whole neighbourhood reject -- a chain whose hard end is
  # merely TOO EASY does not need it, because deep_walk hands that real board
  # back as a candidate. So it is driven directly here, on an ordinary chain, to
  # pin the contract rather than the rarity.
  solution = gen.full_board(Redoku::Rng.new(SOLVED_FLOOR_SEED))
  chain = gen.dig_chain(solution, Redoku::Rng.new(SOLVED_FLOOR_SEED))
  out = gen.shallow_fallback(solution, chain[0], chain[1])
  # This seed's floor is solvable, so by the restoring argument every board on
  # the chain is -- including the shallowest. Unconditional on purpose.
  assert_false out[0].nil?
  assert_false out[1][:tier].nil?
  assert_true r.clue_count(out[0]) <= gen::MAX_CLUES
  # It really is the SHALLOWEST usable board, not merely some board.
  assert_equal(gen.board_at(solution, chain[0], gen.first_usable(chain[1])),
               out[0])
end

assert('Generator.generate reports progress once per completed attempt') do
  gen = Redoku::Sudoku::Generator
  seen = []
  # A BLOCK, not a lambda or a callable object: block-passing is core mruby and
  # mruby-method -- the Method class -- is one of the default-gembox gems this
  # gem still does not declare.
  gen.generate(:easy, Redoku::Rng.new(3), 4) { |done, total| seen << [done, total] }
  # EASY hits on its first attempt on every one of 500 measured chains, so one
  # report is the expected shape -- and it must carry the CAP as the
  # denominator, not the attempt it stopped at.
  assert_true seen.size >= 1
  assert_equal([1, 4], seen[0])

  # A request no chain can serve burns the whole budget and reports every
  # attempt, in order, exactly once.
  seen = []
  gen.generate(:not_a_tier, Redoku::Rng.new(3), 3) { |done, total| seen << [done, total] }
  assert_equal([[1, 3], [2, 3], [3, 3]], seen)
end

assert('an impossible request comes back honest rather than empty') do
  gen = Redoku::Sudoku::Generator
  s = Redoku::Sudoku::Solver
  # generate returns nil ONLY if no attempt produced a single logically
  # solvable board anywhere -- which needs consecutive pathological chains and
  # was not observed in 500. A request it cannot satisfy is a different thing:
  # it comes back with a real puzzle and an honest tier that is not the one
  # asked for, and App is what decides to ask again.
  out = gen.generate(:not_a_tier, Redoku::Rng.new(7), 2)
  assert_false out.nil?
  assert_false out[:tier] == :not_a_tier
  assert_true s.unique?(out[:grid].values)
  assert_false out[:tier].nil?
  # The reply says which attempt the board came from, which is what a caller
  # logs when it wants the real distribution rather than a bootstrap estimate.
  assert_true out[:attempts] >= 1
end
```

- [ ] **Step 2: Run it and confirm RED**

Run: `make test`
Expected: FAIL — `NameError: uninitialized constant
Redoku::Sudoku::Generator::ATTEMPTS`, then `NoMethodError` on
`shallow_walk`, `deep_walk`, `hard_end`, `rescue_floor` and
`shallow_fallback`. **Not** a `NameError` on `SOLVED_FLOOR_SEED` or
`REJECT_FLOOR_SEED` — if you see one of those, Step 0 was skipped.

- [ ] **Step 3: Implement the budgets, the two walks and the rescue**

In `generator.rb`, replace `DEFAULT_ATTEMPTS = 6` and `MEASURE_BUDGET = 12`
with:

```ruby
      # A ceiling on ratings per CHAIN WALK, so one attempt's cost is bounded
      # however long a chain turns out to be. Raised from 12 to 16: the
      # measured window between MAX_CLUES and the uniqueness floor is 8 to 12
      # boards (n=60, p50 10) and 0 of 40 chains ever exceeded 12, so this
      # never binds -- which is exactly why raising it is free, and worth doing
      # now that the walk can start at either end. It does NOT bound the floor
      # neighbourhood, which is bounded by the chain's own length (at most 41
      # groups, measured 26-29).
      MEASURE_BUDGET = 16

      # ATTEMPTS PER RUNG, and they are tier-dependent for the first time,
      # because the rungs differ in rarity by two orders of magnitude: a chain
      # can serve EASY 100% of the time and MASTER 2% of the time (500 chains:
      # 500 / 446 / 70 / 43 / 10). One number cannot be right for both.
      #
      # Measured hit rates at these caps (500-chain bootstrap, 500 trials per
      # cell), with host p50/p90/max wall clock:
      #   easy    100%   53 /    73 /   152 ms
      #   medium  100%   90 /   552 /  1309 ms
      #   hard    100%  721 /  2257 /  7750 ms
      #   expert  100% 1151 /  3301 /  9220 ms
      #   master   94% 4749 / 15993 / 22824 ms
      #
      # MASTER'S 6% IS NOT A FAILURE, because App never stops asking (decision
      # 4): a miss retries with a FRESH solution, which resets the odds, so the
      # expected cost is about 1.06 rounds rather than 1/0.06. The tail is
      # real, and it is what the progress bar is for.
      #
      # Adding a rung means adding an entry here. That is a real obligation the
      # three-tier design did not have, and it is unavoidable.
      ATTEMPTS = { easy: 6, medium: 12, hard: 60, expert: 60,
                   master: 150 }.freeze

      # For a tier ATTEMPTS does not know. nil.times is a crash, and this runs
      # behind a splash on a device whose only escape is the power button.
      DEFAULT_ATTEMPTS = 12

      # Which end of the chain each rung walks from. EASY walks from the
      # SHALLOW end because a first-rung puzzle should look generously clued --
      # measured, the shallow end gives 44-45 clues and the deep end 33-34.
      # Every other rung walks from the DEEP end, which is the fix for the
      # shallow-end bias: worth 4 clues at the median and a demand-class
      # upgrade on 17 chains in 39 at MEDIUM, and it costs NOTHING, because the
      # chain is already dug.
      WALK_SHALLOW = :easy

      def self.attempts_for(tier)
        ATTEMPTS[tier] || DEFAULT_ATTEMPTS
      end
```

Replace `dig` with the two-directional version and its helpers:

```ruby
      # One attempt: dig a chain, then walk it from whichever end this rung
      # wants. Returns [board, measurement], or [nil, nil] if this chain has no
      # board our rules can finish at all.
      def self.dig(solution, tier, rng)
        chain = dig_chain(solution, rng)
        removals = chain[0]
        clues_after = chain[1]
        if tier == WALK_SHALLOW
          shallow_walk(solution, removals, clues_after, tier)
        else
          deep_walk(solution, removals, clues_after, tier)
        end
      end

      # From the first board MAX_CLUES allows, deeper, and stop at the first
      # board of the requested tier -- so the answer has the MOST clues of any
      # that would have done. EASY's walk, and only EASY's: going deep here
      # would ship 33-clue "easy" puzzles.
      def self.shallow_walk(solution, removals, clues_after, tier)
        k = first_usable(clues_after)
        budget = MEASURE_BUDGET
        best = nil
        best_board = nil
        while k <= removals.size && budget > 0
          board = board_at(solution, removals, k)
          m = Rater.measure(board)
          budget -= 1
          return [board, m] if m[:tier] == tier
          if !m[:tier].nil? && (best.nil? || closer?(m, best, tier))
            best = m
            best_board = board
          end
          k += 1
        end
        [best_board, best]
      end

      # From the hard end. THE MONOTONE DISMISSAL IS WHAT MAKES THIS
      # AFFORDABLE: because a board's class never decreases as clues come out,
      # the hardest board on a chain is its floor -- so if the floor is easier
      # than the request, no board on this chain can serve it and the attempt
      # is over after ONE classification (p50 9 ms on top of the 47 ms dig).
      # Only a chain that can actually serve the request pays for a walk.
      def self.deep_walk(solution, removals, clues_after, tier)
        out = hard_end(solution, removals)
        board = out[0]
        m = out[1]
        # Nothing our rules can finish at the deep end, floor OR neighbourhood.
        # Fall back to the shallow end rather than writing the chain off: design
        # 6.4's fallback, and it costs one classification on a path not observed
        # in 500 chains. See shallow_fallback.
        return shallow_fallback(solution, removals, clues_after) if m.nil?
        return [board, m] if m[:tier] == tier
        # Dismissed: too easy. The board still comes back as a fallback
        # candidate -- it is a real puzzle, just an easier one, and `generate`
        # would rather hand back an honest easier board than nothing.
        return [board, m] if Rater.rank(m[:tier]) < Rater.rank(tier)
        # The hard end is HARDER than asked, so a shallower board may be
        # exactly right. Walk back up and take the DEEPEST match.
        up = walk_up(solution, removals, clues_after, tier)
        up[1].nil? ? [board, m] : up
      end

      # The hardest board this chain can offer: its floor, or -- if the floor
      # is a board our rules cannot finish -- the hardest rescue from the
      # floor's neighbourhood. [nil, nil] if there is no such board.
      def self.hard_end(solution, removals)
        floor = board_at(solution, removals, removals.size)
        m = Rater.measure(floor)
        return [floor, m] unless m[:tier].nil?
        rescue_floor(solution, removals, floor)
      end

      # A REJECTED FLOOR IS NOT A WASTED DIG. Restore any single removed group
      # and the result is a different, legal puzzle:
      #
      #   - still 180-degree symmetric, because a whole group goes back, never
      #     half of one;
      #   - still uniquely solvable, FOR FREE AND PROVABLY -- the restored
      #     givens come from the same solution, so the neighbour's solution set
      #     is a subset of the floor's, and the floor was unique. NO
      #     Solver.unique? CALL IS NEEDED, which is what makes this cheap: one
      #     Techniques.solve per neighbour instead of a search each.
      #
      # There are 26-29 such neighbours per floor and classifying all of them
      # costs 152-325 ms (p50 194). 22% of chain floors reject, so this runs on
      # about one attempt in five -- and it is where the hard rungs come from:
      # of 10 MASTER boards found in 500 chains, 7 came from a stalled floor's
      # neighbourhood and only 3 from a floor that was directly solvable.
      # Without the rescue the top rung is not merely expensive, it is three
      # times rarer.
      def self.rescue_floor(solution, removals, floor)
        best = nil
        best_board = nil
        removals.each do |pair|
          board = floor.dup
          board[pair[0]] = solution[pair[0]]
          board[pair[1]] = solution[pair[1]]
          m = Rater.measure(board)
          next if m[:tier].nil?
          next unless best.nil? || harder?(m, best)
          best = m
          best_board = board
        end
        [best_board, best]
      end

      # THE LAST RESORT ON A CHAIN, and the reason `generate` almost never
      # answers nil: the shallowest board MAX_CLUES allows, classified once.
      # That board was rung 1 on 500 of 500 measured chains, so a chain has to
      # be pathological at BOTH ends before it yields nothing at all.
      #
      # design 6.4 put this fallback on every dismissed attempt. It is here
      # instead, on the much rarer path where hard_end found nothing, and that
      # is a DEVIATION worth naming rather than a simplification. The reason is
      # that the version in 6.4 pays for it far more often for far less: a
      # chain dismissed as TOO EASY already has a real board to offer -- its
      # own hard end -- and deep_walk hands that back as the fallback candidate
      # (see above), which is both a better board and free. Classifying the
      # shallow end as well would add a second p50 9 ms classification to the
      # attempt that the monotone dismissal exists to make cost ONE, and at
      # :master's 150 attempts that is about 1.4 s added to a 4.7 s p50 for a
      # strictly worse candidate. So the fallback survives, on the path that
      # actually needs it.
      def self.shallow_fallback(solution, removals, clues_after)
        k = first_usable(clues_after)
        return [nil, nil] if k > removals.size
        board = board_at(solution, removals, k)
        m = Rater.measure(board)
        m[:tier].nil? ? [nil, nil] : [board, m]
      end

      # Harder tier first, then higher score, so the pick is deterministic
      # rather than order-dependent among equals.
      def self.harder?(a, b)
        ra = Rater.rank(a[:tier])
        rb = Rater.rank(b[:tier])
        return true if ra > rb
        return false if ra < rb
        a[:score] > b[:score]
      end

      # From one board above the floor back toward the shallow end, the FIRST
      # board of the requested tier -- which is the DEEPEST such board, because
      # the walk starts at the floor. The floor itself was already measured by
      # hard_end, so this starts one step shallower.
      def self.walk_up(solution, removals, clues_after, tier)
        k = removals.size - 1
        first = first_usable(clues_after)
        budget = MEASURE_BUDGET
        while k >= first && budget > 0
          board = board_at(solution, removals, k)
          m = Rater.measure(board)
          budget -= 1
          return [board, m] if m[:tier] == tier
          k -= 1
        end
        [nil, nil]
      end
```

Then replace `generate`, keeping its comment about the real cap and adding the
nil contract and the hook:

```ruby
      # Try until a board of the requested tier turns up, then stop.
      #
      # THE NIL CONTRACT, stated here because it used to be an undocumented
      # invariant spread over four methods in two files: this returns nil ONLY
      # if no attempt produced a single logically solvable board anywhere. For
      # one attempt that means its chain floor rejected AND all ~27 of the
      # floor's one-group neighbours rejected AND the shallowest board
      # MAX_CLUES allows rejected too (shallow_fallback) -- three independent
      # failures, none of the first two observed in 500 chains and the third
      # observed 0 times in 500. Then that has to happen `attempts` times in a
      # row. IT IS STILL POSSIBLE, SO THE CALLER MUST HANDLE IT
      # (App#fill_board does).
      #
      # If the tier is missed but a real board was found, that board comes back
      # with the tier it ACTUALLY achieved. The caller decides whether to ask
      # again -- and it does, without limit, which is why there is no fallback
      # to an easier tier and never a wrong label (decision 4).
      #
      # A real attempt cap, and it is worth restating because every one of the
      # five reference implementations read for this design got it wrong:
      # sudoku.js recurses on failure with no cap (and silently drops its
      # `unique` flag on the way), sudoku-core has three separate uncapped
      # retry loops, and super-sudoku counts attempts only to log them. A
      # generator that cannot fail is a generator that can hang, and this one
      # runs behind a splash screen on a device with a physical power button as
      # its only escape. The unbounded part of the search lives in App, where
      # the progress bar can show it happening.
      #
      # THE BLOCK reports progress: it fires once per COMPLETED attempt with
      # (done, total), both Integers, `done` counting completed attempts and
      # `total` the cap. A block rather than a callable, because block-passing
      # is core mruby and mruby-method -- the Method class -- is one of the
      # gems this gem does not declare. It fires after the attempt's
      # classification work and BEFORE the early return, so a generation that
      # succeeds on its first attempt still reports once.
      def self.generate(tier, rng, attempts = nil)
        attempts = attempts_for(tier) if attempts.nil?
        best = nil
        i = 0
        while i < attempts
          i += 1
          solution = full_board(rng)
          out = dig(solution, tier, rng)
          puzzle = out[0]
          m = out[1]

          candidate = nil
          unless m.nil?
            candidate = {
              grid: Grid.new(puzzle),
              solution: solution,
              tier: m[:tier],
              demand: m[:demand],
              score: m[:score],
              hardest: m[:hardest],
              counts: m[:counts],
              clues: Rater.clue_count(puzzle),
              # The attempt this board came from, not the total spent: a caller
              # that wants the total counts the block's reports, which is the
              # only figure that survives a retry.
              attempts: i
            }
          end

          yield(i, attempts) if block_given?
          return candidate if candidate && candidate[:tier] == tier
          if candidate && (best.nil? || closer?(candidate, best, tier))
            best = candidate
          end
        end
        best
      end
```

- [ ] **Step 4: Run and iterate to GREEN**

Run: `make test`

Three failures to expect and how to read them:

- **The suite gets slower.** `deep_walk` now runs for `:medium` too, and one
  attempt in five pays a 152–325 ms floor rescue. If it is minutes rather than
  seconds, something is asking for `:hard` or above at a production cap —
  find it and give it an explicit small budget.
- **`'Generator.dig walks from the shallow end, so easy keeps its clues'`
  fails**, because a `:hard` request no longer returns the shallowest match.
  Delete it — `'only easy walks the shallow end of the chain'` in Step 1 is its
  replacement and asks the question properly. **Delete it even if it passes:**
  its name now describes the opposite of what the code does for four rungs out
  of five, and a test whose name lies is worse than no test.
- **`'every board along a dig chain is uniquely solvable'` still passes.**
  It must: the rescue restores whole groups from the same solution, and if
  this one breaks, the rescue is corrupting a board rather than restoring it.

- [ ] **Step 5: Measure the rungs on the host, once, and record it**

Reachability is not something `make test` may pay for. Establish it once with
a throwaway script and paste the output into the commit message:

```ruby
# meas_rungs.rb -- throwaway.
gen = Redoku::Sudoku::Generator
[:easy, :medium, :hard, :expert, :master].each do |tier|
  hits = 0
  5.times do |n|
    t0 = Time.now
    out = gen.generate(tier, Redoku::Rng.new(900 + n))
    ms = ((Time.now.to_f - t0.to_f) * 1000).to_i
    hits += 1 if out && out[:tier] == tier
    puts "#{tier} seed=#{900 + n} got=#{out && out[:tier]} " \
         "clues=#{out && out[:clues]} score=#{out && out[:score]} " \
         "attempts=#{out && out[:attempts]} #{ms}ms"
  end
  puts "#{tier}: #{hits}/5"
end
```

Expected shape, from the design's bootstrap: 5/5 for easy, medium, hard and
expert; 4/5 or 5/5 for master, with master's wall clock in the seconds and one
draw plausibly past 20 s. **If `:master` is 0/5, stop** — the most likely
cause is `DEMAND_SETS[2]` having lost `hidden_pair` or `hidden_triple` (or
`RULE_LEVEL` having been built from ORDER *positions* rather than from set
membership), which files every X-wing board under `:subset`, makes the top rung
unreachable, and fails no test in the suite. Delete the script.

While that script is in hand, it is also the cheapest place to check the one
figure Task 2 could not: paste the `:medium` line into the commit message too,
because a `:medium` hit rate materially below 100% would mean
`DEMAND_EDGES[:singles] = [140]` is cutting harder than the design's 89%
per-chain measurement predicted.

- [ ] **Step 6: Commit**

```bash
git add mrbgems/mruby-redoku/mrblib/redoku/sudoku/generator.rb \
        mrbgems/mruby-redoku/test/sudoku_generator.rb
git commit -m "feat(redoku): dig for the demand — deep-end walk, floor rescue, per-tier budgets"
```

---

### Task 4: A real progress bar in the splash

**Files:**
- Modify: `mrbgems/mruby-redoku/mrblib/redoku/renderer.rb`
- Modify: `mrbgems/mruby-redoku/test/renderer.rb`

**Interfaces:**
- Consumes: `Layout.board_rect`, `Font::HEIGHT`, `Renderer::SPLASH_SCALE`,
  `RM2::DU`, `RM2::FAST_DRAW`.
- Produces:
  - `Renderer::PROGRESS_W` = 620, `::PROGRESS_H` = 24, `::PROGRESS_GAP` = 40,
    `::PROGRESS_BORDER` = 3
  - `Renderer.progress_rect` → `[x, y, w, h]`
  - `Renderer.progress_fill(num, den)` → Integer pixels, 0..inner width
  - `Renderer#draw_progress(num, den)` → self
  - `Renderer#flush_progress` → the display's answer
  - one corrected comment on the existing private `boundary_weight` (Step 3);
    no behaviour change and no test change for it

- [ ] **Step 1: Write the failing test**

Append to `test/renderer.rb`:

```ruby
assert('the progress bar sits inside the splash, under its text') do
  bx, by, bw, bh = Redoku::Layout.board_rect
  x, y, w, h = Redoku::Renderer.progress_rect
  # Wholly inside board_rect, which is what lets draw_board's white fill erase
  # it and flush_board cover it -- no second flush region, and no bar left
  # behind on the finished puzzle.
  assert_true x >= bx
  assert_true y >= by
  assert_true x + w <= bx + bw
  assert_true y + h <= by + bh
  # Below the splash text's box, not over it.
  text_bottom = by + (bh - Redoku::Font::HEIGHT *
                      Redoku::Renderer::SPLASH_SCALE) / 2 +
                Redoku::Font::HEIGHT * Redoku::Renderer::SPLASH_SCALE
  assert_true y >= text_bottom
  # Centred horizontally on the board, like the text above it.
  assert_equal(bx + bw - (x + w), x - bx)
end

assert('Renderer.progress_fill scales a fraction to pixels, monotonically') do
  r = Redoku::Renderer
  inner = r::PROGRESS_W - 2 * r::PROGRESS_BORDER
  assert_equal(0, r.progress_fill(0, 10))
  assert_equal(inner, r.progress_fill(10, 10))
  assert_equal(inner / 2, r.progress_fill(5, 10))
  # Integer arithmetic throughout: mrb_int is 32-bit on the device, and a bar
  # is pixels, so there is nothing a Float would add but a rounding rule to
  # get wrong.
  assert_true r.progress_fill(1, 3) < r.progress_fill(2, 3)
  # Degenerate inputs answer a drawable number rather than raising: this is
  # called from inside a search, where a crash costs the player their puzzle.
  assert_equal(0, r.progress_fill(0, 0))
  assert_equal(0, r.progress_fill(-1, 10))
  assert_equal(inner, r.progress_fill(11, 10))
end

assert('Renderer draws an outlined bar filled to the fraction it was given') do
  d = TestDisplay.new
  r = Redoku::Renderer.new(d)
  x, y, w, h = Redoku::Renderer.progress_rect
  b = Redoku::Renderer::PROGRESS_BORDER

  r.draw_progress(0, 4)
  # The frame is there even at zero, so an empty bar is visible as a bar
  # rather than as nothing at all.
  assert_equal(Redoku::Renderer::BLACK, d.gray_at(x + w / 2, y + 1))
  assert_equal(Redoku::Renderer::BLACK, d.gray_at(x + 1, y + h / 2))
  # ...and nothing is filled inside it.
  assert_equal(Redoku::Renderer::WHITE, d.gray_at(x + b + 1, y + h / 2))

  d.clear_calls
  r.draw_progress(2, 4)
  fill = Redoku::Renderer.progress_fill(2, 4)
  # Filled from the left edge of the interior, up to `fill` and no further.
  assert_equal(Redoku::Renderer::BLACK, d.gray_at(x + b + 1, y + h / 2))
  assert_equal(Redoku::Renderer::BLACK, d.gray_at(x + b + fill - 1, y + h / 2))
  assert_equal(Redoku::Renderer::WHITE, d.gray_at(x + b + fill + 1, y + h / 2))
  # Every rect it drew is inside the bar: a bar that painted over the splash
  # text would need a wider flush than flush_progress does.
  assert_true d.painted_within?(x, y, w, h)
end

assert('the progress bar flushes as ink, not as chrome') do
  d = TestDisplay.new
  r = Redoku::Renderer.new(d)
  r.draw_progress(1, 4)
  r.flush_progress
  x, y, w, h = Redoku::Renderer.progress_rect
  # DU + FAST_DRAW, the same exception press_button makes and for the same
  # reason: this is a two-level black-on-white repaint that happens about ten
  # times per attempt budget and about twenty times over a whole press, and a
  # GL16 chrome refresh each time would cost more than the search it reports on.
  assert_equal([x, y, w, h, RM2::DU, RM2::FAST_DRAW], d.updates[0])
  assert_equal(1, d.updates.size)
end
```

- [ ] **Step 2: Run it and confirm RED**

Run: `make test`
Expected: FAIL — `NoMethodError: undefined method 'progress_rect'`.

- [ ] **Step 3: Implement the bar**

Read `renderer.rb` whole first. Two fix waves refactored it after this plan
was drafted, so the file does not look like any snippet quoted here: the eraser
work extracted `boundary_weight`, `leading_band` and `trailing_band` out of
`draw_board` and added `redraw_cell(index, grid)`, and `75eb7cf` deleted
`DIFFICULTIES`. At HEAD the constants run `WHITE BUTTON_BORDER GIVEN_GRAY
ENTRY_GRAY DIGIT_SCALE SPLASH_SCALE SPLASH_TEXT`, and `SPLASH_TEXT` is the last
of them. Append after it:

```ruby
    # THE PROGRESS BAR, and it is a real one: generation already loops over
    # attempts, so a callback on completed work gives honest progress at no
    # extra cost. What it means, stated plainly because a bar that means
    # nothing is worse than no bar: work COMPLETED against work completed plus
    # one more full attempt budget. It advances with every finished attempt,
    # decelerates as a search runs long, and can never fill -- because a search
    # that has not finished cannot promise it is about to. See App#show_progress
    # for why that is the shape and not a percentage of a fixed total.
    #
    # WHAT THAT LOOKS LIKE IN THE COMMON CASE, said plainly because it is the
    # case the player meets: an EASY press hits on its first attempt, so the bar
    # goes to 1/(1+6) -- 14%, 87 px of 614 -- and is then replaced by the board.
    # A short bar that vanishes, not a bar that fills. design 6.5 predicted "the
    # bar jumps to full"; that was true of a denominator of `total`, and it is
    # not true of this one. The trade was taken deliberately: never resetting
    # across a retry matters more than finishing, because the retry case is the
    # one where the player is actually waiting.
    #
    # Geometry is derived from the splash text's own box so the two stay
    # centred together, and lives wholly inside board_rect so that draw_board's
    # white fill erases it and flush_board covers it -- no second flush region,
    # and no bar surviving onto the finished puzzle.
    PROGRESS_W = 620
    PROGRESS_H = 24
    PROGRESS_GAP = 40
    PROGRESS_BORDER = 3

    def self.progress_rect
      x, y, w, h = Layout.board_rect
      th = Font::HEIGHT * SPLASH_SCALE
      top = y + (h - th) / 2 + th + PROGRESS_GAP
      [x + (w - PROGRESS_W) / 2, top, PROGRESS_W, PROGRESS_H]
    end

    # The filled width in pixels for a fraction given as two Integers. Integer
    # arithmetic throughout, and the reason is the bar and not the toolchain:
    # a bar is pixels, mrb_int is 32-bit on the device, and there is nothing a
    # Float would add here but a rounding rule to get wrong. (String#% and
    # `format` ARE available since 18cc2f5 declared mruby-sprintf; a percentage
    # STRING is simply not what this returns.) Clamped at both ends and safe on
    # a zero denominator, because this is called from inside a search where a
    # raise costs the player their puzzle.
    def self.progress_fill(num, den)
      inner = PROGRESS_W - 2 * PROGRESS_BORDER
      return 0 if den <= 0 || num <= 0
      return inner if num >= den
      (inner * num) / den
    end

    # The whole bar, frame and fill, repainted from scratch each time: 620x24
    # is nothing to fill and it removes any question of a stale fill edge
    # surviving a repaint.
    def draw_progress(num, den)
      x, y, w, h = Renderer.progress_rect
      b = PROGRESS_BORDER
      @d.fill_rect(x, y, w, h, WHITE)
      @d.fill_rect(x, y, w, b, BLACK)                # top
      @d.fill_rect(x, y + h - b, w, b, BLACK)        # bottom
      @d.fill_rect(x, y, b, h, BLACK)                # left
      @d.fill_rect(x + w - b, y, b, h, BLACK)        # right
      fill = Renderer.progress_fill(num, den)
      @d.fill_rect(x + b, y + b, fill, h - 2 * b, BLACK) if fill > 0
      self
    end

    # DU + FAST_DRAW, the same exception to the chrome convention that
    # press_button makes: this is two-level black on white, it happens about ten
    # times per attempt budget and about twenty times over a whole press
    # however long it runs (App::PROGRESS_STEP_PX explains why the total is
    # bounded), and a GL16 each time would cost more than the search it
    # reports on.
    def flush_progress
      x, y, w, h = Renderer.progress_rect
      @d.update(x, y, w, h, waveform: RM2::DU, flags: RM2::FAST_DRAW)
    end
```

**One stale comment to correct while you are in this file**, because Task 4 is
the only task that opens it. `boundary_weight`'s comment reads:

```ruby
    # `== 0`, not `.zero?`: Integer#zero? is mruby-numeric-ext, which this gem
    # does not depend on, so it is absent from its mrbtest state.
```

`18cc2f5` declared `mruby-numeric-ext`, so that is now false. **Correct the
comment; do not change the code** — `i % 3 == 0` stays exactly as it is (see
Global Constraint 1's second caution). Replace those two lines with:

```ruby
    # Every third boundary, counting from the board's own edge, which is why
    # this is `% 3` and not a lookup.
```

That is the whole edit: a claim that its own repository has since falsified is
worse than no comment. The identical claim in `Rater.band` needs no attention —
Task 2 deletes that method.

- [ ] **Step 4: Run to GREEN**

Run: `make test`
Expected: PASS. If `progress_rect` fails the containment assertion, the
arithmetic is 200 + (1260 − 56) / 2 + 56 + 40 = 898 for the top and
72 + (1260 − 620) / 2 = 392 for the left, giving `[392, 898, 620, 24]` inside
a board that runs x 72–1332 and y 200–1460 — check `SPLASH_SCALE` and
`Font::HEIGHT` before changing a constant.

- [ ] **Step 5: Commit**

```bash
git add mrbgems/mruby-redoku/mrblib/redoku/renderer.rb \
        mrbgems/mruby-redoku/test/renderer.rb
git commit -m "feat(redoku): draw a progress bar in the generating splash"
```

---

### Task 5: The App — retry without limit, fail without hanging, and show it

Two failure paths, and **conflating them turns an engine bug into an infinite
loop**:

- **A TIER MISS retries without limit.** The requested rung is rare —
  `:master` is available on 2% of chains — and each retry starts from a FRESH
  solution, so retrying resets the odds: the expected cost is about 1.06 full
  budgets, not 1/0.06. There is no fallback to an easier tier and never a
  wrong label (decision 4). The bar is what makes the tail bearable.
- **AN EXCEPTION, or a `nil` reply, retries a FEW times and then keeps the
  puzzle already on the board.** Both mean "the engine could not produce a
  board at all", which is a fault, not bad luck — and retrying a fault for
  ever would hang the game on a device whose only escape is the power button.

**Files:**
- Modify: `mrbgems/mruby-redoku/mrblib/redoku/app.rb`
- Modify: `mrbgems/mruby-redoku/test/app.rb`

**Interfaces:**
- Consumes: `@generator.generate(tier, rng, attempts = nil) { |done, total| }`
  from Task 3, `Renderer#draw_progress` / `#flush_progress` /
  `Renderer.progress_fill` from Task 4, `@clock.monotonic_ms`.
- Produces:
  - `App::GENERATE_TRIES` = 3, `App::PROGRESS_STEP_PX` = 30
  - `App.new(..., log: $stderr)` — a new keyword
  - `App#fill_board` guards a nil reply and repaints either way
  - `App#new_puzzle` paints an empty bar with the splash
  - new **private** methods `search_for_puzzle`, `attempt_generation`,
    `reset_progress`, `show_progress`, `log_line`
  - **no new public methods, and no method made public.** `cycle_difficulty`
    and `fill_board` both stay private; the tests reach them with `send`.

- [ ] **Step 1: Read the nil guard that has already landed, and know that you
      are overriding half of it**

The guard this plan predicted **landed in `75eb7cf`**, before this task. At
HEAD `fill_board` reads:

```ruby
      puzzle = Sudoku::Generator.generate(@difficulty, @rng)
      # ... a long comment saying the invariant is about to be given up ...
      return self if puzzle.nil?
```

So do not add a second guard. But **do not "keep its wording" either**, which
is what an earlier draft of this step said, because one clause of it is a
decision this task reverses. The existing comment ends:

> *"On a nil result the puzzle already on the board is kept as-is — an
> unchanged board beats a wiped one — and the caller's splash is left showing,
> which is honest: nothing new was actually dug."*

The first half stands and is load-bearing (the stuck-RUBBER fix in `2bebc4e`
cites it by name as precedent for resolving corruption toward the
non-destructive answer, so do not weaken it). **The second half does not.**
`return self` before the repaint leaves `GENERATING...` on the panel with
nothing coming, and e-ink holds the last image it was given — so a first
generation that fails leaves the player looking at a permanent splash, which
reads as a hang rather than as honesty. There was also never a test on that
branch (it was unreachable when it landed), so nothing pins the old choice.

Step 3's `fill_board` therefore repaints unconditionally: the previous puzzle
if there is one, an empty board if there is not. Say so in the replacement
comment, naming the reversal, rather than silently changing behaviour that a
comment in the same file argues for.

- [ ] **Step 2: Write the failing test for the two failure paths**

Append to `test/app.rb`:

```ruby
# Records the lines App writes about generation, so the attempt count can be
# asserted rather than assumed. Stands in for $stderr.
class FakeLog
  attr_reader :lines

  def initialize
    @lines = []
  end

  def puts(line)
    @lines << line
    nil
  end
end

# A generator that misses the requested tier a fixed number of times and then
# hits it. The only way to drive App's unbounded retry without an unbounded
# test: a real generator either succeeds by luck or hangs.
class MissingGenerator < FakeGenerator
  # `progress:` is threaded through rather than poked in from outside afterwards.
  # An earlier draft did `gen.instance_variable_set(:@progress, true)`, which
  # works (mruby-metaprog is declared) but is a test reaching around a
  # collaborator's own constructor because that constructor forgot an argument.
  # Fixing the interface is the cheaper repair.
  def initialize(misses, progress: false)
    super(progress: progress)
    @misses = misses
  end

  def generate(tier, rng, attempts = nil, &block)
    out = super(tier, rng, attempts, &block)
    return out if @calls > @misses
    # An honest reply naming a tier it ACTUALLY reached, which is what a missed
    # request looks like: never a wrong label. NEVER the requested tier, which
    # is why this is conditional -- an earlier draft always answered :easy, so a
    # "miss" at the default difficulty of :easy was a HIT and every retry test
    # built on it passed while turning the loop exactly once.
    out.store(:tier, tier == :easy ? :medium : :easy)
    out
  end
end

# Cycles the difficulty until it reaches `tier`, which is how a player gets
# there -- App has no setter, deliberately, because @difficulty is the Level
# button's read-out.
#
# EACH CYCLE DIGS. cycle_difficulty ends in new_puzzle -> fill_board, so
# walking :easy -> :master is FOUR generations, not a state change: with a
# hitting FakeGenerator that is four cheap calls and four log lines, and a test
# that wants exact counts has to install its real generator AFTERWARDS. An
# earlier draft did not, and every count in the first test below was out by
# four.
#
# `send`, not a public cycle_difficulty. Object#send is available (this gem
# declares mruby-metaprog since 18cc2f5), so there is no reason to widen App's
# API for a test -- which is what an earlier draft proposed, on the premise
# that send was unavailable.
def difficulty_to(app, tier)
  Redoku::Sudoku::Rater::TIERS.size.times do
    return app if app.difficulty == tier
    app.send(:cycle_difficulty)
  end
  raise "no such difficulty: #{tier}"
end

assert('a missed tier is asked for again, without limit') do
  # Get to :master on a generator that HITS, so the four cycling digs do not
  # land in the counts below, then swap in the misser and a fresh recorder.
  # instance_variable_set rather than a public seam on App: this is a test
  # reaching into a test's own subject for one line, not an API anyone ships.
  app, = new_app(generator: FakeGenerator.new, log: FakeLog.new)
  difficulty_to(app, :master)

  gen = MissingGenerator.new(4)
  log = FakeLog.new
  app.instance_variable_set(:@generator, gen)
  app.instance_variable_set(:@log, log)
  app.new_puzzle

  # Five rounds: four misses and the hit. No fallback to an easier tier and no
  # wrong label -- the board on the glass is a MASTER board or the search is
  # still running.
  assert_equal(5, gen.calls)
  assert_equal(:master, app.achieved_tier)
  assert_false app.grid.nil?
  # The rounds are logged, so the real distribution becomes visible in play
  # instead of staying a bootstrap estimate.
  assert_equal(1, log.lines.size)
  assert_true log.lines[0].include?('MASTER')
  assert_true log.lines[0].include?('5 rounds')
end

assert('a generation that raises is retried a few times, then the board is kept') do
  # THE DISTINCTION THAT MATTERS. A tier miss is bad luck and retries for ever;
  # an exception is a fault and must not, or an engine bug becomes a hang on a
  # device whose only escape is the power button.
  broken = FakeGenerator.new(fail_with: 'dig exploded')
  log = FakeLog.new
  app, = new_app(generator: broken, log: log)
  app.new_puzzle          # nothing dug yet, so there is nothing to keep

  assert_equal(Redoku::App::GENERATE_TRIES, broken.calls)
  assert_nil app.grid
  # THE LAST LINE IS THE GIVE-UP, NOT THE FAULT. attempt_generation logs one
  # 'generation failed (...)' per fault and search_for_puzzle logs 'gave up'
  # after the last of them, so 'dig exploded' is second from the end. An
  # earlier draft asserted it was last, which would have failed on a correct
  # implementation.
  assert_equal(Redoku::App::GENERATE_TRIES + 1, log.lines.size)
  assert_true log.lines[log.lines.size - 1].include?('gave up')
  assert_true log.lines[log.lines.size - 2].include?('dig exploded')
  log.lines.each_with_index do |line, i|
    assert_true line.include?('dig exploded') if i < Redoku::App::GENERATE_TRIES
  end

  # And with a puzzle already on the board, THAT puzzle survives the fault --
  # which is the half of the behaviour a fresh App cannot show.
  app2, = new_app(generator: FakeGenerator.new, log: FakeLog.new)
  app2.new_puzzle
  before = app2.grid.givens_s
  app2.instance_variable_set(:@generator, broken)
  app2.send(:fill_board)
  assert_equal(before, app2.grid.givens_s)
end

assert('a generator that finds nothing at all is treated as a fault, not as luck') do
  # generate answers nil only when no attempt produced a single logically
  # solvable board. That is the same kind of event as a raise -- the engine
  # produced nothing -- so it takes the BOUNDED path. Retrying it for ever
  # would leave a player staring at a splash.
  empty = FakeGenerator.new(answer_nil: true)
  log = FakeLog.new
  app, d, = new_app(generator: empty, log: log)
  app.new_puzzle
  assert_equal(Redoku::App::GENERATE_TRIES, empty.calls)
  # Nothing was ever dug, so there is no puzzle to keep -- and the board is
  # painted empty rather than left showing the splash, which is where this
  # differs from the guard that landed in 75eb7cf. See Step 1.
  assert_nil app.grid
  bx, by, bw, bh = Redoku::Layout.board_rect
  assert_equal [bx, by, bw, bh, RM2::GL16, 0], d.updates[d.updates.size - 1]
  # A nil reply is not an exception, so nothing logs a 'failed' line -- only the
  # give-up. Worth pinning: it is what distinguishes the two bounded paths in
  # the log a device run will actually produce.
  assert_equal(1, log.lines.size)
  assert_true log.lines[0].include?('gave up')
end

assert('the progress bar does not reset between retries') do
  gen = MissingGenerator.new(2, progress: true)
  d = TestDisplay.new
  app = Redoku::App.new(d, [FakeInput.new], Redoku::Renderer.new(d),
                        FakeWaiter.new([]), FakeSignals.new,
                        rng: Redoku::Rng.new(GEN_SEED), generator: gen,
                        log: nil)
  app.new_puzzle

  # Every bar repaint, in order, as the x-extent of its filled rect. A long
  # wait that started over would read as a hang, and with the top rung missing
  # its budget 6% of the time, exhaustion is an expected path rather than an
  # exception.
  bx, by, bw, bh = Redoku::Renderer.progress_rect
  fills = []
  d.rects.each do |x, y, w, _h, gray|
    fills << w if gray == 0 && x == bx + Redoku::Renderer::PROGRESS_BORDER &&
                  y == by + Redoku::Renderer::PROGRESS_BORDER
  end
  assert_true fills.size >= 2
  i = 1
  while i < fills.size
    assert_true fills[i] >= fills[i - 1]
    i += 1
  end
  # And it never claims to be finished, because it never is until the board
  # replaces it.
  assert_true fills[fills.size - 1] <
              Redoku::Renderer::PROGRESS_W - 2 * Redoku::Renderer::PROGRESS_BORDER
end

assert('the bar is painted at most once per visible step') do
  gen = FakeGenerator.new(progress: true, attempts: 150)
  d = TestDisplay.new
  app = Redoku::App.new(d, [FakeInput.new], Redoku::Renderer.new(d),
                        FakeWaiter.new([]), FakeSignals.new,
                        rng: Redoku::Rng.new(GEN_SEED), generator: gen,
                        log: nil)
  app.new_puzzle
  # E-ink updates are not free: DU + FAST_DRAW is the cheap two-level
  # waveform and still costs tens of milliseconds, and MASTER's budget fires
  # the hook up to 150 times per round. Painting per attempt would add 150
  # refreshes and could double a HARD dig.
  bx, by, bw, bh = Redoku::Renderer.progress_rect
  bar = d.updates.reject { |u| u[0] != bx || u[1] != by }
  assert_true bar.size <= 25
  assert_true bar.size >= 2
  bar.each { |u| assert_equal(RM2::DU, u[4]) }
end
```

`new_app` and `new_touch_app` need one more keyword, threaded through the same
way Task 2 threaded `generator:`:

```ruby
def new_app(batches = [], rng: Redoku::Rng.new(GEN_SEED),
            generator: FakeGenerator.new, log: nil)
  d = TestDisplay.new
  input = FakeInput.new(batches)
  signals = FakeSignals.new
  app = Redoku::App.new(d, [input], Redoku::Renderer.new(d),
                        FakeWaiter.new([input]), signals, rng: rng,
                        generator: generator, log: log)
  [app, d, input, signals]
end
```

`log: nil` by default, not `log: FakeLog.new`: a suite that logged by accident
would print a generation report for every one of the sixty-odd App
assertions, and the tests that care pass their own recorder.

**`App`'s public API does not change in this task, and that is a correction to
an earlier draft of this plan.** That draft made `cycle_difficulty` public and
added a `fill_board_with(generator)` seam, on one stated premise: *"`Object#send`
is not available in this gem's mrbtest state."* Since `18cc2f5` declared
`mruby-metaprog`, it is — along with `instance_variable_set` — so both
concessions were bought with a dead premise and are withdrawn:

- `difficulty_to` calls `app.send(:cycle_difficulty)` (see its definition
  above). `cycle_difficulty` stays private.
- `fill_board_with` is not added. The one test that needs to swap a generator
  mid-life does `app2.instance_variable_set(:@generator, broken)` followed by
  `app2.send(:fill_board)`. `fill_board` stays private too — it already is, at
  `app.rb:754`, below the `private` on `:348`.

That is a test reaching into its own subject for two lines, which is a smaller
thing than a production method that exists only because a test asked for it.
The public surface of `App` after this task is exactly what it is today plus
the two new keywords.

- [ ] **Step 3: Run it and confirm RED, then implement the App**

Run: `make test`
Expected: FAIL — `NameError: uninitialized constant
Redoku::App::GENERATE_TRIES`.

In `app.rb`, add the constants next to `PRESS_ACK_MS`:

```ruby
    # How many times a generation that FAILED OUTRIGHT -- raised, or answered
    # nil -- is tried before the board is left as it was. Deliberately small
    # and deliberately BOUNDED, unlike a tier miss: an exception or an empty
    # answer means the engine produced nothing, which is a fault rather than
    # bad luck, and retrying a fault for ever would hang the game on a device
    # whose only escape is the power button. Conflating the two paths is how an
    # engine bug becomes an infinite loop.
    GENERATE_TRIES = 3

    # How far the progress bar's filled edge must move before it is worth a
    # panel refresh. E-ink updates are not free -- DU + FAST_DRAW is the cheap
    # two-level waveform and still costs tens of milliseconds -- and :master's
    # budget fires the hook up to 150 times per round.
    #
    # 30 px of a 614 px interior is about 5%. Because the fraction is
    # num/(num+total) rather than num/total, one full :master round only ever
    # reaches 614*150/300 = 307 px, so a round costs about TEN paints, not
    # twenty; and because the bar is monotone and asymptotic to 614 px, the
    # whole press -- however many rounds it runs -- costs at most about twenty.
    # Roughly a second of paint inside a search measured in seconds, and it does
    # not grow with the tail. Painting per attempt instead would add 150
    # refreshes per round and could double a :hard dig.
    PROGRESS_STEP_PX = 30
```

Add the `log:` keyword beside `generator:`. **The signature line in full**,
because an earlier draft of this plan showed it only inside a comment and
never wrote it:

```ruby
    # `log:` is where the generation report goes: which rung, how many rounds,
    # how many attempts, how many milliseconds. That line is the ONLY way the
    # real cost distribution on the device ever becomes visible -- every timing
    # in the design document is a host figure times an assumption, because the
    # tablet was unreachable when it was written. The game runs from a shell,
    # so stderr is read.
    #
    # GUARDED AT EVERY USE (`@log.puts(...) if @log`), and that is not
    # defensive style: $stderr comes from mruby-io, one of the few default-gembox
    # gems this gem still does not declare (see Global Constraint 1), so under
    # `make test` the global is simply undefined -- and an undefined global in
    # Ruby is nil, not an error. The guard is what makes one line of logging
    # safe in both worlds, and it is why the fix is NOT to declare mruby-io.
    # Tests pass their own recorder, or nil.
    def initialize(display, sources, renderer, waiter = RM2::Input,
                   signals = RM2, touch_sources: [], clock: RM2,
                   rng: Rng.from_clock, generator: Sudoku::Generator,
                   log: $stderr)
```

with `@log = log` beside `@generator = generator`. `main.rb` omits both
keywords and needs no edit.

`cycle_difficulty` stays **private** — see the note at the end of Step 2 for
why the earlier draft's plan to publish it was withdrawn.

Then replace `fill_board` with the guarded, retrying version. It is currently
private (below `app.rb:348`) and stays private; the new helpers below it are
private too, so **do not add a second `private` keyword** — everything in this
snippet goes where `fill_board` already sits.

```ruby
    # Digs a puzzle at the current difficulty and puts it on the board. The
    # caller owns the splash -- new_puzzle flushes one first, and run's opening
    # GC16 already carries one -- so this is the second half of both.
    #
    # WHAT THE HEADER SHOWS is settled here, and it shows the REQUESTED tier:
    # @difficulty is what cycle_difficulty advanced, what draw_header printed
    # and what the generator was asked for. The header is the Level button's
    # read-out, not a rating of the board -- a label that followed the achieved
    # tier would make the button unpredictable (ask for medium, get easy, the
    # label reads EASY, so the next press offers medium again and some rungs
    # become unreachable).
    #
    # Under the retry-without-limit rule that gap has NARROWED to one case, and
    # it is worth naming: a successful search only ever returns the tier that
    # was asked for, so @achieved_tier now means "the tier of the board
    # actually on the glass" and normally equals @difficulty. It differs only
    # after a FAULT, when the previous puzzle is kept while the header has
    # already been repainted with the new tier -- a visible inconsistency,
    # logged rather than papered over, and an M3 UI question (surface the
    # achieved tier, or re-request) rather than something to fix here.
    #
    # THE NIL GUARD is required, not defensive: Generator.generate's "cannot
    # return nil" was an undocumented invariant spread over four methods in two
    # files, and this change breaks it deliberately and re-establishes it in ONE
    # place -- generate's own comment, which names all three failures an attempt
    # has to suffer (rejected floor, rejected neighbourhood, rejected shallow
    # fallback) before it yields nothing.
    #
    # AND IT REPAINTS EITHER WAY, which reverses half of the guard that landed
    # in 75eb7cf. That guard returned before the repaint so the splash stayed
    # up, on the grounds that "nothing new was actually dug" and saying so is
    # honest. It is not: e-ink holds the last image it was given, so a first
    # generation that fails leaves GENERATING... on the panel for ever with
    # nothing coming, which reads as a dead device rather than as an honest
    # report. The half that stands is the other one -- an unchanged board beats
    # a wiped one, so a fault after a successful dig repaints the puzzle the
    # player already had, and only a fault with nothing ever dug paints empty.
    def fill_board
      found = search_for_puzzle
      if found
        @grid = found[:grid]
        # Kept, not used. M3's Check needs the answer and the generator has
        # already paid for computing it.
        @solution = found[:solution]
        @achieved_tier = found[:tier]
      end
      @renderer.draw_board
      # @grid is nil only when nothing has EVER been dug and this search
      # produced nothing: paint the empty board anyway (see above).
      @renderer.draw_puzzle(@grid) if @grid
      @renderer.flush_board
      self
    end

    # Ask until the requested tier arrives, or until the engine has failed
    # GENERATE_TRIES times. Returns the candidate, or nil.
    #
    # TWO PATHS, AND THEY MUST STAY DISTINCT:
    #
    #   TIER MISS -- unbounded. The rung is rare (:master is available on 2% of
    #   chains) and every retry draws a FRESH solution, so retrying resets the
    #   odds: the expected cost is about 1.06 full budgets, not 1/0.06. There
    #   is no fallback to an easier tier and never a wrong label. The tail is
    #   real, and the progress bar is what makes it readable as work rather
    #   than as a hang.
    #
    #   FAULT (a raise, or a nil reply) -- bounded. Both mean the engine
    #   produced nothing at all, and retrying that for ever would spin on a bug
    #   behind a splash screen.
    def search_for_puzzle
      reset_progress
      started = @clock.monotonic_ms
      faults = 0
      rounds = 0
      while true
        rounds += 1
        out = attempt_generation
        if out.nil?
          faults += 1
          if faults >= GENERATE_TRIES
            log_line('generation gave up after ' + rounds.to_s +
                     ' rounds; keeping the board')
            return nil
          end
          next
        end
        next unless out[:tier] == @difficulty
        log_line('generated ' + out[:tier].to_s.upcase + ' in ' +
                 rounds.to_s + ' rounds, ' + @progress_done.to_s +
                 ' attempts, ' + (@clock.monotonic_ms - started).to_s + ' ms')
        return out
      end
    end

    # One call to the generator. nil for either kind of outright failure; the
    # candidate otherwise, tier honest.
    #
    # The rescue is around the ENGINE, not around the painting: show_progress
    # swallows its own display errors (see there), so a wedged panel cannot be
    # mistaken for a broken dig and burn a generation try.
    def attempt_generation
      @generator.generate(@difficulty, @rng) do |done, total|
        show_progress(done, total)
      end
    rescue StandardError => e
      log_line('generation failed (' + e.message + ')')
      nil
    end

    def reset_progress
      @progress_done = 0
      @progress_px = 0
    end

    # THE FRACTION, and why it is this shape.
    #
    # The design had App paint (retry_index * total + done) / (retry_cap *
    # total), which needs a retry CAP -- and decision 4 removed it, so that
    # denominator does not exist. What survives of the requirement is the part
    # that matters: the bar must not RESET between retries, because a long wait
    # that starts over reads as a hang.
    #
    # So: numerator is every attempt completed since the press, across every
    # retry; denominator is that plus one more full budget. The bar is
    # monotone, never resets, decelerates as the search runs long, and never
    # fills -- which is honest, because a search that has not finished cannot
    # promise it is about to. One full budget spent shows half; two shows two
    # thirds. The board's arrival is the completion signal, and it costs no
    # extra refresh.
    #
    # `done` is IGNORED on purpose: it restarts at 1 for every retry, and the
    # numerator must not. Counting the block's own calls is what makes
    # monotonicity a property of the code rather than of the generator's
    # bookkeeping.
    #
    # Display errors are swallowed here, exactly as show_press swallows them:
    # the bar is a courtesy and the puzzle is the contract, and a raise from
    # inside the search would otherwise be counted as a failed generation.
    def show_progress(_done, total)
      @progress_done += 1
      num = @progress_done
      px = Renderer.progress_fill(num, num + total)
      return self if px - @progress_px < PROGRESS_STEP_PX
      @progress_px = px
      @renderer.draw_progress(num, num + total)
      @renderer.flush_progress
      self
    rescue StandardError
      self
    end

    def log_line(text)
      @log.puts('redoku: ' + text) if @log
      self
    end
```

Finally, put an empty bar up with the splash, in both places that raise one —
`new_puzzle`:

```ruby
    def new_puzzle
      @ink_dirty = nil
      @renderer.draw_splash
      reset_progress
      @renderer.draw_progress(0, 1)
      @renderer.flush_board
      fill_board
      self
    end
```

and `run`, between `draw_splash` and `flush_all`:

```ruby
      @renderer.draw_splash
      reset_progress
      @renderer.draw_progress(0, 1)
      @renderer.flush_all
```

The empty bar goes out on the SAME flush as the splash, so it costs no extra
refresh — the player sees a bar waiting to move rather than a bar appearing
from nowhere a second later.

- [ ] **Step 4: Fix the splash-ordering test's update list**

`'the splash reaches the panel before generation starts'` (`test/app.rb:1450`)
asserts `assert_equal 2, d.updates.size`. It now sees three: the splash flush,
the bar's one DU repaint from inside the search, and the finished board.

*(One, not several: `:easy` hits on its first attempt on every measured chain,
so the block fires once, `progress_fill(1, 1 + 6)` is 87 px, and 87 ≥
`PROGRESS_STEP_PX` — so exactly one paint. That arithmetic is what makes every
count in Step 5 predictable, and it is worth re-deriving if any of `ATTEMPTS`,
`PROGRESS_STEP_PX` or `PROGRESS_W` changes.)*

Update it, keeping its claim intact:

```ruby
  # Exactly one update had reached the panel when the generator took its first
  # draw, and that update is the splash. Nought would mean the splash flush had
  # moved after the dig; more would mean something else is flushing in between
  # and this test should be told about it.
  assert_equal 1, spy.updates_at_first_draw
  bx, by, bw, bh = Redoku::Layout.board_rect
  assert_equal [bx, by, bw, bh, RM2::GL16, 0], d.updates[0]
  # Then the progress bar moved DURING the dig -- which is the other half of
  # covering the pause, and the half a splash alone cannot do.
  px, py, pw, ph = Redoku::Renderer.progress_rect
  assert_equal [px, py, pw, ph, RM2::DU, RM2::FAST_DRAW], d.updates[1]
  # ...and the board carrying the finished puzzle came last, so the splash is a
  # cover for the pause rather than the last word on it.
  assert_equal 3, d.updates.size
  assert_equal [bx, by, bw, bh, RM2::GL16, 0], d.updates[2]
  assert_false app.grid.nil?
```

That test constructs its App directly and therefore uses the real generator
at `:easy`; it must also pass `log: nil` so the run prints nothing.

- [ ] **Step 4a: Fix the other three direct-App update counts, which move for
      exactly the same reason**

Task 2 Step 7 listed the six tests that keep the REAL generator. Five of them
dig, so five gain the bar's DU update — and **three assert exact update counts
or exact update lists, so three go red.** An earlier draft of this step told
the implementer these counts should NOT move and to go hunting if they did,
which would have sent them after a non-bug. They move. Here is what each
becomes.

The sequence for a real dig through `new_puzzle` is now: **splash (GL16,
`board_rect`) → one or more bar paints (DU, `progress_rect`) → board (GL16,
`board_rect`)**. Through a button press, a press flash comes first and a
release flash last.

**"One or more", and that is the trap in these three fixes.** The number of bar
paints is the number of attempts whose `progress_fill` step cleared
`PROGRESS_STEP_PX`, so it depends on how many attempts the search took:
`:easy` is measured to hit on its first attempt on 500 of 500 chains, giving
`progress_fill(1, 1 + 6) = 87 px` and exactly **one** paint; but `:medium` at a
cap of 12 gives 47 px on its first attempt and another 40 on its second, so a
seed that needs two attempts paints **twice**. Deterministic (the suite is
seeded) but not predictable from this document.

So the two `:medium` tests are converted to **count by REGION**, which is the
pattern `'the acknowledgement runs each action exactly once'` already uses in
this same file — "a tighter question than the old waveform count did, not a
looser one". The `:easy` test keeps its exact count, because for `:easy` the
arithmetic above pins it.

1. **`'the action runs while the button is held down, not after it comes up'`
   (`:720`).** Press New with a `TimelineWaiter`, `:easy`, so exact counts hold.
   - `assert_equal [3], waiter.updates_at` → `assert_equal [4], waiter.updates_at`
   - `d.updates[1]` and `[2]` were both the board rect; now `[1]` is the
     splash, `[2]` is the **bar** and `[3]` is the finished board. Assert the
     bar explicitly rather than skipping over it — it is the whole point of
     this change and this test is already the one that reads the sequence.
   - `assert_equal 4, d.updates.size` → `5`, and the release flash moves from
     `d.updates[3]` to `d.updates[4]`.
   - Its comment says "THREE updates had reached the panel by the time the hold
     began". Make it four, and say which one is new: the bar moved *during* the
     dig, which is the half of covering the pause a static splash cannot do.
     Add the one-paint arithmetic, so the next person to change `ATTEMPTS[:easy]`
     knows why this number is 4.
2. **`'a Level press whose flash is refused still cycles the difficulty'`
   (`:803`).** `DeafButtonsDisplay` refuses button rects only, and the bar is
   inside `board_rect`, so the bar lands. This one digs `:medium` at the
   production cap, so **drop the total count** rather than guessing it:
   ```ruby
     # The header is still FIRST and still GL16 -- the M1 decision this test
     # exists for -- and there is still exactly one of it.
     hx = Redoku::Layout::HEADER_X
     hy = Redoku::Layout::HEADER_Y
     assert_equal RM2::GL16, d.updates[0][4]
     assert_equal [hx, hy], [d.updates[0][0], d.updates[0][1]]
     assert_equal 1, d.updates.reject { |u| u[0] != hx || u[1] != hy }.size
     # Then exactly two board flushes: the splash and the finished puzzle. That
     # is the dig Level gained, counted by REGION rather than by total, because
     # the progress bar between them paints once per VISIBLE STEP and a :medium
     # search may take more than one attempt to hit.
     bx, by, bw, bh = Redoku::Layout.board_rect
     board = d.updates.reject { |u| u[0] != bx || u[1] != by }
     assert_equal 2, board.size
     board.each { |u| assert_equal [bx, by, bw, bh, RM2::GL16, 0], u }
     # ...and the bar moved at least once, in the ink waveform, between them.
     px, py, = Redoku::Renderer.progress_rect
     bar = d.updates.reject { |u| u[0] != px || u[1] != py }
     assert_true bar.size >= 1
     bar.each { |u| assert_equal RM2::DU, u[4] }
     # Nothing else reached the panel at all.
     assert_equal d.updates.size, 1 + board.size + bar.size
   ```
   That last line is what replaces `assert_equal 3, d.updates.size`: it still
   says "and nothing else", without hard-coding a number the bar controls.
3. **`'a New press whose flash is refused still clears the ink'` (`:839`).**
   Asserts the whole update list as one literal:
   ```ruby
     assert_equal [[bx, by, bw, bh, RM2::GL16, 0],
                   [bx, by, bw, bh, RM2::GL16, 0]], d.updates
   ```
   This digs `:easy`, so the literal *could* just grow to three entries with
   `[px, py, pw, ph, RM2::DU, RM2::FAST_DRAW]` in the middle. Use the same
   region form as (2) anyway — two board flushes, at least one bar paint,
   nothing else — so that the two refused-flash tests read alike and neither
   breaks the next time an attempt budget moves. Its comment says "Two board
   flushes where M1 had one"; make it "two board flushes with the bar moving
   between them", and keep the point it is actually making: the refused button
   flash still costs the player nothing.

`'every button acknowledges its press, at the button, for the same 200 ms'`
(`:657`) digs for real too, but every assertion in it indexes `d.updates[0]`,
`d.rects[0]`, `d.rects[1]` and `waiter.calls` — all of which are the press
flash's, and all of which come before any bar. **It should stay green. If it
goes red, that is a real bug**: something is painting or flushing before
`show_press`.

`'an App given no rng seeds itself from the clock'` (`:1508`) asserts only that
a grid arrived, so the bar cannot touch it.

- [ ] **Step 5: Run to GREEN**

Run: `make test`

Failures to expect:

- **The three counts in Step 4a.** Expected, and fixed there. Anything *else*
  moving is the signal to go hunting.
- **Nothing in the `new_app` tests.** `FakeGenerator` does not call the
  progress block unless asked, so `'a tap on Level cycles the difficulty and
  repaints the header'` (5 updates) and `'the acknowledgement runs each action
  exactly once'` (2 board flushes) really should be untouched. Note that
  `new_puzzle`'s `draw_progress(0, 1)` still *draws* — it adds rects — but it
  goes out on the splash's own `flush_board` and adds no update; and
  `fill_board`'s `draw_board` white-fills over it before the board flush, so no
  `gray_at` probe in the file can see it either. If one of these two moves,
  something is flushing the bar unconditionally: find it rather than adjusting
  the count.
- **A hang.** If `make test` does not return, the unbounded path has been
  reached by a test that meant to reach the bounded one: check that
  `attempt_generation` returns nil for a raise *and* for a nil reply, that a
  `FakeGenerator` built with neither `fail_with` nor `answer_nil` answers the
  tier it was asked for, and that `MissingGenerator`'s miss tier is never equal
  to the tier requested (it answers `:medium` for an `:easy` request precisely
  so that a miss at the default difficulty is still a miss).

- [ ] **Step 6: Commit**

```bash
git add mrbgems/mruby-redoku/mrblib/redoku/app.rb \
        mrbgems/mruby-redoku/test/app.rb
git commit -m "feat(redoku): retry a missed rung for ever, a broken dig three times"
```

---

### Task 6: Correct the record

A design record that a later commit silently contradicts is worse than none.
`docs/design/difficulty-rating.md` currently records *"our hard tier means
long, not clever"* as an **accepted product decision**; the owner's first
playtest overturned it. The fact was right and the verdict was wrong, and both
halves of that have to survive in the document — its value is that it records
**how** decisions were made, rejected alternatives included, so nothing here
deletes history. It appends.

**Files:**
- Modify: `docs/design/difficulty-rating.md`
- Modify: `PLAN.md` (§7's `Rater` description, §10's M2 note, the v2 parking
  list)
- Modify: `.superpowers/sdd/2026-08-23-m2-sudoku-engine/design-harder-tiers.md`
  (status line only)

- [ ] **Step 1: Append the correction to §4 of the design record**

Do **not** edit the existing subsection *"An honest characterisation: our hard
tier means 'long', not 'clever'"*. Leave its reasoning, its representative
board and its tdoku citation exactly as they are, and append immediately after
it:

```markdown
#### Overturned by the first playtest, 2026-08-24 — and what was right about it

The subsection above was accepted as a product decision and is now **wrong as
a decision**, while remaining **right as a fact**. Recorded here rather than
rewritten above, because how we got here is the point.

The owner played the shipped tiers and reported: *"the amount of pre-filled in
numbers for medium and hard make the sudoku's very easy. We can reduce those
by quite a bit, easy should be easy, medium can be more difficult and hard can
be even more like really difficult right now it's not yet."*

What the measurement then found (500 dig chains, 4852 boards; full workings in
`.superpowers/sdd/2026-08-23-m2-sudoku-engine/design-harder-tiers.md`):

- The fact above understated itself. **22 of 40 `:hard` boards (55%) and every
  one of 40 `:medium` boards** were solvable by naked and hidden singles
  alone. The representative board was not an outlier, it was the mode.
- There were **two** defects, not one, and they own different complaints.
  The tier was decided by a SUM, so volume faked difficulty — that is the HARD
  complaint. And `Generator.dig` walked the chain from its SHALLOW end and
  returned the first qualifying board, so every tier shipped the most-clued
  board that barely passed — that is the MEDIUM complaint, worth 4 clues at
  the median and a demand-class upgrade on 17 of 39 chains, and free to fix
  because the chain is already dug.

**What changed:** the tier is now the weakest RULE SET that finishes the board
(`Rater::DEMAND_SETS`), and the score keeps exactly one job — splitting the
singles-only class into a short rung and a long one. So "long, not clever" did
not go away; it moved to where the owner finds it fun. It is `:easy` versus
`:medium` now, and it is no longer able to reach `:hard` or above, because
`DEMAND_RANGE` gives each class a CEILING as well as a floor. The five rungs
are EASY / MEDIUM / HARD / EXPERT / MASTER, gated on singles / pointing /
a subset rule / an X-wing.

**What was right and is retained:** technique counts really do correlate 0.78
with human solve time, so "lots of steps" genuinely predicts a longer solve —
which is why the singles class is two rungs wide rather than one. And most
sudoku really do not require anything clever: 94% of the boards our generator
can produce are singles-only, so the hard rungs are fishing in the last 3%.
That is why they cost what they cost.

**What it cost, honestly:** a quarter of what today's generator calls `:hard`
becomes unshippable — those boards need guessing, and under the no-guessing
rule they are rejects, not hard puzzles. And the top rung is slow: host p50
4.7 s, p90 16.0 s at a 150-attempt cap for a 94% hit rate. The owner accepted
that behind a progress bar.

**Not fixable by trying harder, and still true:** the *clue count* ladder is
two steps, not five. Rungs 2–5 all sit at 24–34 clues, because that is where
uniqueness under 180° symmetry stops the dig. Difficulty above `:easy` is a
ladder of DEMAND and will look identical on the board. A per-tier clue floor
would change that and would make clue count a target rather than a guard rail,
which PLAN.md §7 forbids — so it stays a decision for the owner, not a
default.
```

- [ ] **Step 2: Replace §5, "Going from three levels to five"**

That section's recipe (extend `CEILING`, revisit `TECHNIQUE_FLOOR`) describes
machinery that no longer exists. Replace its body — keeping the heading and
the HoDoKu naming note — with what the five rungs actually cost, and record
the two places its own claim was already false:

```markdown
Done, 2026-08-24, and the recipe above was only half right. Everything is
still derived from ordered lists, but the lists changed: `TIERS` grew to five
and `CEILING` was **deleted**, along with `TECHNIQUE_FLOOR`, `STALL_FLOOR` and
the strict/tolerant accept. A demand class now sets both a floor and a ceiling
(`Rater::DEMAND_RANGE`), and the only calibrated threshold left is
`DEMAND_EDGES[:singles] = [140]`, which lives inside the one class where only
singles ever fire.

The claim that "nothing may assume `TIERS.size == 3`" was **already false in
this repository** when it was written, and finding out cost nothing only
because it was looked for. Three places broke:

1. `test/app.rb` computed the next difficulty as
   `Rater::TIERS[(i + 1) % 3]` in two places — at HEAD, `:759` and `:909`.
   (A third copy lived in `Renderer::DIFFICULTIES`, which `75eb7cf` deleted
   for being a duplicate of `TIERS` before this rework reached it. Two tier
   lists would have been two edits.)
2. `test/sudoku_rater.rb:57-64` pinned `TIERS.size == CEILING.size` and the
   band-tiling derivation — correct for the old design and meaningless in the
   new one; it is now written against `DEMAND_RANGE` and `DEMAND_EDGES`.
3. `Generator::ATTEMPTS` is a new per-tier table, so adding a rung now means
   adding an entry. That is a real new obligation and it is unavoidable: the
   rungs differ in rarity by 50×, and one attempt budget cannot be right for
   both ends of that.

**A sensitivity to `Techniques::ORDER` that has changed shape rather than
gone away, and this correction matters more than it looks.** §3 warned that a
cost metric and the propagation it is measured against are one unit, because a
calibrated *sum* decided the tier. A set-membership answer does not have that
problem — but it has a different one, and an earlier draft of this section
claimed the opposite ("a set-membership answer cannot be changed by re-ordering
the set"), which is false twice over:

- The technique solver takes the **first** applicable rule in `ORDER` at every
  step, so re-ordering `ORDER` changes which rules fire, hence `counts`, hence
  `hardest` and `Rater.upper_bound`. The upper bound stays *sound* (any superset
  of the fired rules solves the board), but it is not the same number.
- More sharply: `Rater.demand_of` stops walking down the ladder at the first set
  that fails, and that early exit is sound only because each `DEMAND_SET` is a
  contiguous prefix of `ORDER` **as a set** — `ORDER[0..1]`, `[0..2]`, `[0..6]`,
  `[0..7]`. Today the level boundaries fall either side of the
  `naked_triple`/`hidden_pair` swap rather than through it. Move a name across a
  boundary, or re-order `ORDER`, and the break can mis-classify boards with
  nothing failing. `test/sudoku_rater.rb`'s `'every demand set is a contiguous
  prefix of ORDER'` is the guard rail, and `Rater.demand_of`'s comment carries
  the proof.

So: adding a *rule* still demands recalibration. Re-ordering the existing ones
no longer demands recalibration, but it does demand re-checking that prefix
test — and if it fails, deleting the early break rather than the test.
```

- [ ] **Step 3: Record the chain rule as future work, not as a loss**

Append to §6, "Deliberate omissions":

```markdown
- **No chain-based rule, and this is the one omission that costs us boards.**
  22% of dig chains (109 of 500) reach a floor our eight rules cannot finish,
  and of 47 such floors measured, **17 need two guesses or fewer** — they are
  one or two deductions short of being logically solvable, and the missing
  deductions are exactly the chain-shaped rules we do not implement (XY-wing,
  simple colouring). Those are genuinely hard boards that we are currently
  forced to THROW AWAY under the no-guessing rule. §4 predicted this before it
  was measured: *"A chain-based rule — XY-wing, simple colouring — would be
  [the lever], because those infer across cells that no subset rule relates."*

  Implementing one would make the top rung both **faster and better**: better
  because `:master` would mean a named chain deduction rather than an X-wing,
  and faster because the pool it draws from would stop being 2% of chains. The
  owner declined it for now, and the decision is recorded rather than buried:
  the X-wing top rung ships as measured, at host p50 4.7 s / p90 16.0 s, and
  the progress bar is what pays for it.

  Honest limit on the estimate: this is inferred from guess COUNTS, not from a
  measurement of XY-wing's actual reach. It would need implementing to know.
```

- [ ] **Step 4: Update PLAN.md**

In §7, replace the `Rater` bullet's three band lines and the sentence about
the tier being "the harder of the score's band and the floor its hardest
technique implies" with the five-rung ladder — demand class, what each rung
requires, the measured per-chain yield, and the note that clue count separates
`:easy` from everything else and nothing more. Keep the pointer to
`docs/design/difficulty-rating.md`; **rewrite** the "Bands are calibrated
against measurement, not borrowed, and are derived from two ordered lists so
that going to five levels is a table edit plus a recalibration" sentence rather
than keeping it — going to five levels turned out to be a table edit *plus* a
new per-tier `ATTEMPTS` entry, which is the claim §5 of the design record now
corrects, so PLAN.md must not go on making the easier promise. Also update the
**`Generator`** bullet in the same section: it currently says the dig walks
"from the shallow end and keep[s] the first one whose score lands in the
requested band", which is wrong in three ways after Task 3 (only `:easy` walks
shallow, the score no longer decides, and `generate` may now answer nil).

In §10's M2 paragraph, the sentence *"And the header shows the tier the player
asked for, not the tier the generator achieved, which can differ"* now needs
its narrowing: a successful search only ever returns the tier asked for, so
the two differ only after a generation fault, when the previous puzzle is
kept. Add one line to the v2 parking lot: *"one chain rule (XY-wing or simple
colouring), which would make the top rung both faster and better — see
`docs/design/difficulty-rating.md` §6."*

**While rewriting that paragraph, KEEP the sentence "Palm suppression under
this build is unverified: it was not part of the device report."** It is one of
four things §10 says M2 deliberately did not establish, and it is the surviving
half of M1's own hardware caveat (§1's device block records it too, at "Palm
suppression under the new build is unverified… it is the half of M1's caveat
that stays open"). It is the last item carried forward from M1 that is not yet
discharged, and rewriting the paragraph around it is the one realistic way it
gets lost. **Nothing in this rework touches the proximity or palm logic**, so
the caveat is as open after this change as before it — see this plan's Known
Risks, which restates it so the plan is self-sufficient if the M2 workspace is
ever deleted.

In the design document's status line, replace *"design, measured, not
implemented"* with *"design, measured, implemented 2026-08-24 by
`docs/plans/2026-08-24-difficulty-rework.md`"*, and add under it the **six**
places this plan departs from the document. An earlier draft said "the two
places", counting only the first two; the other four are argued in code
comments and nowhere else, which is exactly how a deviation becomes an
undocumented difference. All six, then, and the last is a consequence rather
than a disagreement but still changes what a reader should expect:

1. **§6.1's `DEMAND_SETS` references `Techniques::ORDER`** in a constant
   expression. The mrblib load order forbids it (`rater.rb` loads before
   `techniques.rb`), so the fourth set is spelled out and pinned against
   `ORDER` by a test.
2. **§6.5's `retry_cap` denominator** does not exist, because decision 4
   removed the retry cap. The bar is `num / (num + total)` instead, which never
   resets across a retry and never fills. §6.5's "the bar jumps to full" does
   not happen.
3. **§6.2's `demand_of` is replaced, not implemented.** The design's cascade
   branches on which rules fired and can return `:locked` without ever testing
   whether `LOCKED` solves the board. This plan walks the ladder downward
   instead, so every set it names has been tested — and the early break needs
   the `ORDER`-prefix property the design does not mention.
4. **A `nil` measurement is routed to the FAULT path, not the miss path.**
   §6.4 says the caller "retries with a fresh seed a few times"; this plan makes
   that concrete and distinguishes it sharply from a tier miss, which retries
   without limit. Conflating them would turn an engine bug into a hang.
5. **§6.4's shallow-board fallback fires on a narrower path.** The design
   classifies the shallowest usable board on *every* dismissed attempt; this
   plan does it only when `hard_end` found nothing at all, because a dismissed
   chain already has a real board to offer (its own hard end) and the extra
   classification would double the cost the monotone dismissal exists to
   avoid — about 1.4 s added to `:master`'s 4.7 s p50 for a strictly worse
   candidate. `Generator.shallow_fallback`'s comment carries the argument.
6. **`@achieved_tier` has narrowed in meaning**, from "the tier the generator
   reached, which often differs from the request" to "the tier on the glass,
   which differs from the request only after a fault". Not a deviation from the
   design so much as a consequence of decision 4, but it changes what a future
   reader of that attribute should expect, so it goes in the list.

- [ ] **Step 5: Read it back, then commit**

Read all three documents through once as a stranger would. The test is
whether someone who has never seen this change can tell **what was decided,
what was measured, and what was overturned** without reading the diff.

```bash
git add docs/design/difficulty-rating.md PLAN.md \
        .superpowers/sdd/2026-08-23-m2-sudoku-engine/design-harder-tiers.md
git commit -m "docs: record the overturned hard-tier decision and the five-rung ladder"
```

---

## Self-Review

**1. Spec coverage.** The design document, section by section:

| design section | where it lands |
|---|---|
| §5.1 rule sets, by membership not by ORDER position | Task 2 (`DEMAND_SETS`, the nesting/coverage test, and the ORDER-prefix test the classifier's break needs) |
| §5.2 `hardest` as a free upper bound | Task 2 (`upper_bound`, generalised from `hardest` to `counts`) |
| §5.3 rejection rule | Task 2 (`measure` → `tier: nil`) |
| §5.4 neighbourhood rescue | Task 3 (`rescue_floor`; the test drives a seed mined for a rejecting floor, so the path cannot go uncovered) |
| §6.1 `Rater` tables | Task 2 |
| §6.1a class gates, score ranks within | Task 2 (`DEMAND_RANGE` width, `DEMAND_EDGES`) |
| §6.2 the classifier, ~1 solve | Task 1 (`solves?`) + Task 2 (`demand_of`) — **DEVIATION**: the design's per-rule cascade is replaced by a downward walk (Task 6 Step 4, item 3) |
| §6.3 walk direction, hard end, per-tier attempts | Task 3 |
| §6.4 the nil invariant, in one place | Task 3 (`generate`'s comment + contract, and `shallow_fallback`) and Task 5 (`fill_board`'s guard) — **PARTIAL**: the fallback fires only when `hard_end` found nothing, not on every dismissal (Task 6 Step 4, item 5) |
| §6.5 the progress hook | Task 3 (the block) + Task 4 (the bar) + Task 5 (throttle, cross-retry denominator) — **DEVIATION**: no `retry_cap` denominator, so the bar never fills (Task 6 Step 4, item 2) |
| §7 clue counts, symmetry kept, single greedy pass | no code change — the design's recommendation is "keep what we have"; recorded in Task 6's §4 append |
| §8 what breaks the table-edit claim | Task 2 (`% 3`, the rater test) and Task 3 (`ATTEMPTS`) |
| §9.2 what gets worse | Task 6, named in the design record |
| §9.3 the chain-rule recommendation | Task 6 Step 3, recorded as future work |
| §9.4 clue floor / achieved tier | left as owner decisions; the achieved-tier half is narrowed and documented in Task 5 |

Owner decisions 1–7 all land: five names that render (Task 2's glyph
assertion), the hybrid ladder (`DEMAND_EDGES` at the bottom), X-wing as
shipped (`DEMAND_SETS[3]`), retry for ever on a miss (Task 5), the two-step
prefill ladder accepted and recorded (Task 6), cost behind a bar (Tasks 3–5),
a real bar (Task 4).

**2. Placeholder scan.** Four deliberate gaps, called out rather than hidden.
All four are values that must be **measured** before the test around them means
anything, and all four have a script in the step that needs them:

- **The three demand fixtures (`LOCKED_81`, `PAIR_81`, `XWING_81`) are
  `'<81 chars>'` in Task 2 Step 10.** They cannot be written here: a board
  that genuinely *requires* an X-wing is 2 per 100 chains, and hand-writing
  one would put a confident wrong 81-character string into the plan. The step
  gives the script that mines them, the seeds to record, and — crucially — a
  test that pins each fixture's class **by definition** (`solves?` against the
  weaker and stronger sets) rather than by the classifier that found it.
- **`SOLVED_FLOOR_SEED` and `REJECT_FLOOR_SEED` are `<n>` in Task 3 Step 0.**
  Same reason and a sharper consequence: three assertions in Task 3 are
  unconditional *because* those seeds are chosen for what their chain floor is.
  An earlier draft used `13` for both and guarded the bodies with `unless
  out[0].nil?` and `if r.measure(floor)[:tier]`, which meant the floor-rescue
  path — the source of 7 of 10 measured `:master` boards — could ship with zero
  coverage and a green suite. Mining the seed is what converts a hope into a
  test.
- **Task 6's PLAN.md §7 edit is described, not written out.** It is prose in a
  document whose current wording the implementer must read; quoting a
  replacement here would fight whatever the last fix wave left behind. Step 4
  names the three specific claims in it that are now false, so "described" does
  not mean "left to taste".

**3. Type consistency.** Checked across tasks: `values` is an 81-element
Array of Integer everywhere; `rules` is an **Array of symbols** at
`Techniques.solves?` and `Rater::DEMAND_SETS`, and an **Integer mask** only
inside `Techniques.solve` and `mask_of`; `Rater.measure`'s six keys are the
same in Task 2's tests, Task 3's `hard_end`/`rescue_floor`/`walk_up`/
`shallow_fallback` and Task 5's `fill_board`; `[board, measurement]` is the
return shape of all six walk helpers; `Generator.generate`'s reply carries
`attempts:` in Task 3 and is read as `out[:tier]` in Task 5;
`Renderer.progress_fill(num, den)` and `draw_progress(num, den)` take the same
pair in the same order in Tasks 4 and 5; and **`Rater::TIERS` is the only tier
list in the tree** — `Renderer::DIFFICULTIES` was deleted in `75eb7cf`, so
there is no second copy to keep in step and no equality test to maintain.

**4. Known risks, recorded rather than resolved.**

- **Palm suppression is still unverified on hardware, and this plan does not
  change that.** It is the last item carried forward from M1 that remains open:
  the owner's device run discharged the button-feedback half of M1's caveat and
  said nothing about the palm half. Nothing here touches
  `note_pen_proximity`, `expire_pen_proximity`, `touch_suppressed?` or the
  `@touch_blocked` birth latch, so the risk is neither raised nor lowered —
  it is simply still there, and it needs a pen-and-finger device run to close.
  Recorded here as well as in `PLAN.md` §1 and §10 so that deleting the M2
  workspace cannot lose it, and Task 6 Step 4 says explicitly not to drop
  §10's sentence while rewriting the paragraph around it.
- **The `:master` progress bar stops around a third full and then vanishes.**
  `num / (num + total)` reaches 307 px of 614 after one full budget and 460
  after three; the board's arrival is the completion signal. An `:easy` press
  stops at 87 px (14%). Deliberate — never resetting across a retry was judged
  worth more than finishing — but it is the most likely thing for the owner to
  report as a bug on the first device run, so it is written down here before
  they do.

- **The unbounded retry is genuinely unbounded.** If a rung ever becomes
  unreachable — a table typo, a rule regression — the game searches for ever
  behind a moving bar. The mitigations are the bar (it keeps moving, so the
  device does not look dead), the log line (rounds and milliseconds, so the
  distribution becomes visible in play), and Task 3 Step 5's one-off
  reachability measurement. There is no timeout, by the owner's decision.
- **`:master` at 150 attempts is host p50 4.7 s and p90 16.0 s, and the device
  factor has never been measured for this project.** Every device figure in
  the design is a host figure times an assumption. The first device run of
  this change is the first real measurement, which is what the log line exists
  to capture.
- **`:master` rests on 10 events in 500 chains.** The 2% yield has a wide
  interval (roughly 1–3.6%), and every `:master` cost figure inherits it. The
  direction — X-wing an order of magnitude more common than triples — is safe
  at 10 versus 1 in the same corpus; the wall clock is not.
