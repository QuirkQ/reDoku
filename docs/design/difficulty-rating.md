# How reDoku measures difficulty

**Status:** decided and implemented, 2026-08-23. Supersedes PLAN.md §7's
description of the `Rater`.

This records what we measure, why, what we tried first and abandoned, and what
it would take to go from three difficulty levels to five. It exists because
almost every decision below is counter-intuitive, several were arrived at by
being wrong first, and none of it is recoverable from reading the code.

---

## 1. What we measure

One integer per puzzle, the **score**, from two measurements composed in
series:

```
score = Σ over techniques (weight × uses, discounted for repeats)
      + 120 × (guesses still needed after the techniques give up)
```

1. Run the human technique solver (`Techniques`). Every rule it applies costs
   points, weighted by how hard that rule is to know and to spot.
2. Take whatever it could not finish and measure that **residual board** with
   the search solver (`Solver.cost`), counting decisions at cells with more
   than one candidate.

The tier is then the **harder** of two answers:

- the band the score falls in (`CEILING = [130, 230, nil]`), and
- the floor the hardest technique puts under it (`TECHNIQUE_FLOOR`).

### Why the composition is in series

Measuring cost on the *residual* board rather than on the puzzle as dealt is
the point. It makes the second number mean "guessing still required after
human technique is exhausted" instead of "guessing a machine needs from
scratch", so the two measurements describe **different work** rather than
overlapping. A board the techniques finish scores no guess points at all,
because there is nothing left to guess about.

---

## 2. Why not the obvious alternatives

### Not clue count

This is what sudoku.js does — `easy: 62, medium: 53, hard: 44` givens and no
other signal — and it is a poor predictor. Measured on our own generator,
boards at 26 clues ranged from needing no guesses at all to needing 99
decisions. Pelánek's correlation study against human solve times puts "number
of givens" at r = 0.25 / 0.27 across two datasets.

It also needs no separate term, because **it is already inside the sum**: a
board with more holes needs proportionally more singles to fill them, so it
scores higher on that alone. An earlier version of our rater had an explicit
`EASY_MIN_CLUES` rule alongside the score and was double-counting.

Cross-checked in the reference implementations: sudoku.js's own clue ladder
collapses in the middle — its "hard" (44 clues) and "very-hard" (35 clues)
measure 4.2 and 4.4 mean solver iterations, i.e. indistinguishable.
sudoku-generator's medium and hard are likewise 4 versus 4–7 despite a 2×
removal budget.

### Not pure search cost

This is what we shipped first, and it is the **worst-performing family of
metrics that has been measured.** From Pelánek (arXiv:1403.7373), Pearson r
against human solve times:

| metric | dataset 1 | dataset 2 |
| --- | --- | --- |
| backtracking cost | **0.16** | **0.25** |
| number of givens | 0.25 | 0.27 |
| technique max (Sudoku Explainer) | 0.70 | 0.86 |
| technique *counts* (linear model) | **0.78** | 0.86 |
| combined technique + propagation | **0.84** | **0.95** |

Raw search cost correlates *worse than simply counting the givens*. It is a
fine measure of what a computer finds hard and close to useless as a measure of
what a person finds hard — which is what a difficulty label on a puzzle claims
to be.

super-sudoku's own committed test data says the same thing independently: its
websudoku *medium* puzzles reach 258 solver iterations while its *evil* mean is
113, and *hard* reaches 403. The means separate cleanly (7 / 19 / 33 / 113 /
250); the per-puzzle distributions overlap almost completely.

### Not the technique solver alone

Which is what our rater did *before* the cost version: singles → easy, any
elimination → medium, stall → hard. Two things killed it.

- **It collapsed two tiers into one.** Benchmarked against the real generator,
  four attempts in five produced singles-only boards in the 28–35 clue band, so
  a `:medium` request returned `:easy` over and over, burned its whole
  twelve-attempt budget and took 1.9 s to fail. The needs-an-elimination band
  is *thin*, not wide — the opposite of what the plan assumed.
- **"Our solver stalled" is a fact about our solver.** It knows eight rules. A
  competent player knows XY-wing, swordfish and simple colouring, none of which
  we implement, so a board we stall on may well be one they finish without
  guessing. Calling every such board hard claims our blind spot as the puzzle's
  difficulty.

### Not the maximum technique, but the count

Sudoku Explainer rates a puzzle by the *hardest* step on its solution path.
Counting *uses* measures better (0.78 versus 0.70 above), it matches an
intuition the max cannot express — one X-wing in an otherwise gentle board is a
puzzle you finish, twenty pointing pairs is an evening — and it is what HoDoKu
does in production, where the score is the plain sum over every step taken.

---

## 3. Where the numbers come from

### Technique weights: HoDoKu's table

| technique | weight | | technique | weight |
| --- | --- | --- | --- | --- |
| naked single | 4 | | naked triple | 80 |
| hidden single | 14 | | hidden triple | 100 |
| pointing / box-line | 50 | | X-wing | 140 |
| naked pair | 60 | | *unweighted rule* | 140 |
| hidden pair | 70 | | | |

Taken from HoDoKu's `Options.java` (verified identical across three
independent forks) because it is the only published table whose scores are
meant to be **summed**, which is what we do with them. Sudoku Explainer's
numbers are per-move ratings designed to be maximised over, so they cannot be
added up — though the two tables agree closely on relative order.

**The ordering correction worth recording:** locked candidates
(pointing/box-line) is the *easiest* of the eliminators, below both pairs.
HoDoKu scores it 50 against naked pair 60 and hidden pair 70; Sudoku Explainer
agrees (2.6 against 3.0 and 3.4). Our `Techniques::ORDER` had it last — ranked
as the *hardest* — against both. It is listed late in some tutorials, which is
presumably how it came to be treated that way. Since `ORDER` is both the order
rules are tried in and the scale `hardest` is measured on, this changed which
puzzles get called hard.

A rule that fires with no weight is charged `UNKNOWN_WEIGHT = 140`, the dearest
known rule — deliberately not zero, so a rule added to `ORDER` and forgotten in
`WEIGHT` cannot silently become free, and deliberately not an exception,
because this runs inside generation where the cost of a safety net firing
should be a puzzle rated too hard rather than a game that dies mid-tap.

### The repeat discount

A technique costs full price the first time and two-thirds per repeat.
Sudoku Of The Day is the one published table that prices first use separately
(swordfish 8000 then 6000, naked quad 5000 then 4000, naked pair 750 then 500),
and its stated reason is that the first use is the hard part: *"if you
understand the technique, then applying it again won't be quite such a hard
step."* Integer arithmetic, because `mrb_int` is 32-bit on the device and there
is no `Rational`.

### Guess weight: 120 per decision

HoDoKu prices its own last resort ("Brute Force") at 10000 against 140 for an
X-wing. Ours is far gentler on purpose: our repertoire is deliberately small,
so a board we cannot finish may be solvable by a technique a good player knows
and we simply have not implemented. 120 is enough that a genuinely
trial-and-error board climbs past the top band on its own, without declaring
every stall unplayable.

### Band edges: calibrated, never borrowed

`CEILING = [130, 230, nil]`.

HoDoKu's own thresholds (800 / 1000 / 1600 / 1800) cannot transfer, and the
reason generalises: **a cost metric and the propagation strength it is measured
against are one unit.** HoDoKu scores against roughly forty techniques and we
score against eight.

super-sudoku learned this the expensive way and left the evidence in its
source. Its AC3 loop is disabled at `solverAC3.ts:119-126` under the comment
*"I initially didn't count the ac3 iterations as proposed by the paper. But
using them now falsifies the tests"* — strengthening propagation moved every
iteration count off its committed reference numbers, so the fixpoint loop was
switched off rather than the bands recalibrated. Its `while (true)` runs exactly
once to this day.

The same trap is why our edges were set **after** the technique solver gained
its triples and X-wing, not before.

The paper this whole approach descends from is no exception. super-sudoku lists
Fatemi/Kazemi/Mehrasa's reference values (Easy 6.234, Medium 29.2093, Hard
98.2093, Evil 527.4318), then records its author's own remeasurement on the
same puzzle source: *"Easy 7, Medium 19, Hard 33, Expert 113"* — off by 1.5× to
5×. Its shipped goals table matches neither.

#### The measurements the edges came from

Scores along real dig chains, which is the distribution the generator actually
draws from:

| clues | 45 | 43 | 41 | 39 | 37 | 35 | 33 | 32 | 30 | 28 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| score | 97 | 102 | 108 | 113 | 176 | 188 | 213 | 223 | 188 | 274 |

Two things this table settles:

- **The score is not monotone.** 223 → 188 → 274 as clues come out, because a
  removal can turn a hidden single worth 14 points into a naked single worth 4.
  This is why the generator walks the chain linearly instead of halving it; a
  binary search assumes what that dip disproves.
- **The bulk of a chain is easy.** One measured solution in four produced no
  board harder than easy anywhere along its entire chain, which is why the
  generator needs retries at all.

An earlier attempt at `[140, 300]` made the middle band nearly unreachable,
because a chain tends to step from the 130s straight past 300 once a stall
starts costing guess points.

### Tolerance: 25 points or 15%, whichever is more generous

No published grader states a tolerance figure — that is a genuine gap in the
literature, not an omission in the research. What *is* published is
deliberately overlapping bands: Sudoku Of The Day says its overlap *"allows the
generator an extra bit of leeway as it works to create a puzzle that's still
within an acceptable range."*

The two-form shape is stolen wholesale from super-sudoku
(`generate.ts:211-288`), whose accept test is `relative < 20% || absolute < 3`.
Its comment explains why both are needed and the reasoning transfers exactly: a
percentage is meaningless at the easy end of a metric that spans two orders of
magnitude, and a fixed number of points is meaningless at the hard end. Our
scores run from about 97 to well over 10000.

**Strict drives, tolerant gates.** `in_band?` is exact and drives the
generator's search; `accepts?` forgives and only decides the outcome once the
search has run out of boards. Getting this backwards was a real bug: with the
tolerant test driving the walk, the slack at the low edge let through the tier
below, and twelve requests for `:medium` returned twelve `:easy` boards. The
tolerance exists to forgive a board for *overshooting* what was asked, not to
excuse the search from looking.

This is super-sudoku's two-tier accept — tight window drives the hill climb,
wide band gates shipping — and it is the one idea in that codebase that its own
bugs did not undermine.

---

## 4. What the tiers actually mean

| tier | score | typical clues | what it is |
| --- | --- | --- | --- |
| easy | 0–130 | 44–45 | singles only, generously clued |
| medium | 131–230 | 31–41 | more filling in, or one eliminator needed |
| hard | 231+ | 26–32 | a lot of filling in, or guessing beyond our eight rules |

Measured hit rate, 12 requests per tier: **12/12 for all three**, at 56 ms /
87 ms / 153 ms per puzzle on the build host.

### Which rules each tier actually needs

Measured over 20 generated boards per tier — the fraction of boards where each
rule was needed at least once:

| rule | easy | medium | hard |
| --- | --- | --- | --- |
| naked single | 20/20 | 20/20 | 19/20 |
| hidden single | – | 10/20 | 20/20 |
| pointing / box-line | – | – | 9/20 |
| naked pair | – | – | 5/20 |
| naked triple | – | – | 2/20 |
| hidden pair | – | – | 2/20 |
| X-wing | – | – | 1/20 |
| *needed guessing* | 0/20 | 0/20 | **7/20** |

This is a cleaner progression than the score alone suggests, and it lines up
with §7's original intent: easy is pure naked singles, medium adds hidden
singles, and the eliminators appear only in hard.

The 7-in-20 guessing figure is the other half of why the hard band works: the
guess points are what push a board decisively past 230 rather than leaving it
bunched near the medium boundary.

### What widening the repertoire did and did not buy

Honest accounting, because the answer is mostly "less than hoped".

**It did not reduce stalling at all.** Measured before and after on identical
corpora — same seeds, same solver — the numbers are unchanged to the board:

| clues | boards | finished before | finished after |
| --- | --- | --- | --- |
| 27 | 40 | 30 | 30 |
| 24 | 40 | 30 | 30 |
| 22 | 12 | 6 | 6 |

The three new rules are not dead code — naked triple and X-wing do fire — but
the eliminators turn out to be **confluent** on these boards: they all narrow
toward the same candidate fixed point, so where a triple or an X-wing found
something, a cheaper rule reached the same endpoint anyway. **`hidden_triple`
never fired once** across any corpus measured, ours or the 20-board sample
above.

So if the goal is "stall less", these rules are not the lever. A chain-based
rule — XY-wing, simple colouring — would be, because those infer across cells
that no subset rule relates. What the new rules *do* buy is attribution at the
top end: naked triple and X-wing each turn up as the *hardest* rule needed on
some hard board, which gives `TECHNIQUE_FLOOR` something to grip.

**The reorder changed attribution substantially, and that is a calibration
hazard.** Putting pointing ahead of the pairs, per §3, moved firings on the same
40 boards: pointing 14 → 36, naked pair 17 → 7, hidden pair 5 → 2. Pointing now
absorbs work the pairs used to be credited for, and `hardest` shifts with it.
Any weighting or band calibrated against the old histogram is stale. Ours was
measured after the reorder — deliberately, per §3's one-unit warning — but the
next person to touch `ORDER` must recalibrate, not interpolate.

**Cost:** `Techniques.solve` went from ~8.6 ms to ~9.8 ms per 27-clue board
(+15%), almost entirely `hidden_triple` and `x_wing` *declining* — 1041 µs and
632 µs per negative sweep. `naked_triple` is as cheap as `naked_pair` (122 µs)
only because it pre-collects each unit's 2-to-3-candidate cells instead of
nesting three loops over the unit, which would be 19,683 combinations per call.

### An honest characterisation: our hard tier means "long", not "clever"

A representative generated `:hard` board needed **zero** hard techniques — 39
naked singles and 15 hidden singles, score 249, no guessing. It is hard by
*volume*, not by demanding any clever step.

This is defensible: technique counts are what correlate 0.78 with human solve
time, so "lots of steps" genuinely predicts a longer solve. And it is not
fixable by trying harder — tdoku reports that *"45% of 17-clue puzzles"* are
solvable with singles alone, and that 17-clue puzzles are *"among the easiest
Sudoku for solvers that incorporate additional reasoning techniques."* Most
sudoku, even very sparse ones, simply do not require anything clever. Boards
that genuinely need an X-wing are a rare subset, and requiring one would mean
rejecting the large majority of candidates.

If "hard" should instead mean "requires a named technique", that is a product
decision, not a bug, and the lever is a minimum on `hardest` rather than on
score. It would cost hit rate and generation time.

### Why hard puzzles still have 26–32 clues

Because **180° rotational symmetry costs clues**, and that is an aesthetic
choice from PLAN.md §8 rather than a difficulty decision. Every removal must
take a *pair* of cells, so a cut fails whenever *either* cell breaks
uniqueness. Measured: our dig bottoms out at 28–30 clues, and a second and
fourth pass over the blocked pairs removed **nothing further** — the greedy
single pass is not what limits us, uniqueness under symmetry is.

For reference, the absolute minimum for a uniquely-solvable sudoku is 17, and
18 with rotational symmetry. Our `MIN_CLUES = 22` floor therefore never binds;
it exists to bound the loop, not to shape difficulty. Getting below the high
20s would mean dropping symmetry or searching many candidate solutions per
puzzle instead of digging one.

---

## 5. Going from three levels to five

Everything is derived from two ordered lists, so this is a table edit plus a
recalibration, not a logic change:

1. Extend `Rater::TIERS` with the new names, easiest first.
2. Extend `Rater::CEILING` to the same length, last entry `nil`.
3. Recalibrate the edges against a fresh measurement — **do not interpolate**,
   and do not touch `Techniques` in the same change, per §3's one-unit warning.
4. Revisit `TECHNIQUE_FLOOR`: with five levels, X-wing and hidden triple should
   probably floor at level 4 rather than at the top.

`STALL_FLOOR = :medium` is already the right shape for this. Flooring every
stall at the *hardest* tier would collapse the top two levels into one, which
is exactly why it is not `:hard`.

Nothing may assume `TIERS.size == 3`. The tests pin the derivation rather than
the three current values: that every band starts one point above the previous
band's ceiling, that the first starts at zero, and that the last is open-ended.

HoDoKu's five levels (Easy ≤ 800, Medium ≤ 1000, Hard ≤ 1600, Unfair ≤ 1800,
Extreme ∞) are the obvious naming precedent if one is wanted.

---

## 6. Deliberate omissions

- **No symmetry-orbit averaging of the cost.** tdoku averages guess counts over
  ten random isomorphs of each puzzle (`generate.cc:86-112`), on the sound
  reasoning that a single run's guess count is partly an artifact of the
  solver's arbitrary tie-breaking rather than a property of the puzzle. It is
  the sharpest idea in the reference corpus and we do not do it, because it
  multiplies rating cost by ten on a device where generation already runs
  behind a splash screen. Our cost term is also usually zero — it only fires on
  the minority of boards the techniques cannot finish — so the contamination
  has less to bite on. Worth revisiting if the hard tier is ever recalibrated.
- **No clue-count debiasing when sampling for calibration.** tdoku corrects the
  `k!(81−k)!` oversampling of low-clue puzzles (`grid_tools.cc:113-140`). Our
  calibration walks dig chains rather than sampling minimal puzzles, so the
  bias does not arise in the same form, but any future calibration that samples
  differently needs to account for it.
- **No committed reference distribution.** super-sudoku pins min/avg/max solver
  iterations for 500 human-labelled puzzles as a test, and that test is what
  caught its AC3 change. We have no human-labelled corpus, so we cannot. It is
  the single biggest gap in our confidence that these tiers mean anything to a
  player rather than merely being self-consistent.

---

## 7. Traps found in the reference implementations

Recorded because we are structurally immune to some of these and should stay
that way.

| trap | where | our position |
| --- | --- | --- |
| Uncapped retry loops | all four generators; sudoku.js `:178` recurses forever *and* silently drops its `unique` flag; sudoku-core has three separate uncapped loops | `DEFAULT_ATTEMPTS` is a real cap with a defined give-up value — the closest board found |
| Sparse array + `filter(Boolean)` destroying index alignment, so pointing was paid the naked-pair rate | sudoku-core `utils.ts:168` — its published example score is the buggy value | our counts are a hash keyed by symbol; immune by construction |
| "Too expensive" conflated with "unsolvable" | super-sudoku returns `Infinity` for both, then rates the puzzle with a *different* solver on a different scale | `COST_CAP` is returned for both, and the rater treats it as a score rather than as a verdict — worth watching |
| Hill climb whose candidate neighbourhood collapses, so goals are never reached | super-sudoku `generate.ts:222` discards a whole row *and* column per rejected sample; its own test asserts 32 against a goal of 500 | we walk a fixed chain rather than climbing, so there is no neighbourhood to collapse |
| Rating by count of *distinct* techniques used | sudoku-core `utils.ts:176-181` | not used; the weighted sum subsumes it |

---

## 8. Sources

- Pelánek, *Difficulty Rating of Sudoku Puzzles: An Overview and Evaluation*,
  [arXiv:1403.7373](https://www.fi.muni.cz/~xpelanek/publications/sudoku-arxiv.pdf)
  — the correlation table in §2
- Fatemi, Kazemi & Mehrasa, *Rating and Generating Sudoku Puzzles Based On
  Constraint Satisfaction Problems* — the original CSP-cost approach
- [HoDoKu `Options.java`](https://github.com/tyllmoritz/Hodoku/blob/master/src/sudoku/Options.java)
  — the weight table and five-level thresholds
- [Sudoku Explainer difficulty ratings](https://github.com/SudokuMonster/SukakuExplainer/wiki/Difficulty-ratings-in-Sudoku-Explainer-v1.2.1)
  — per-move ratings, cross-check on ordering
- [Sudoku Of The Day](https://www.sudokuoftheday.com/difficulty) — first-use vs
  repeat pricing, and the overlapping-bands rationale
- [Stuart, *Sudoku Creation and Grading*](https://www.sudokuwiki.org/Sudoku_Creation_and_Grading.pdf)
  — frequency-weighted grading; weights deliberately unpublished
- Local clones under `../sudoku/`: `sudoku.js`, `sudoku-core`, `super-sudoku`,
  `sudoku-generator`, `tdoku` (see `tdoku/docs/sudoku.md`)
