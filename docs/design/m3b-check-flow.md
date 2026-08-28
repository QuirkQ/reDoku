# How reDoku turns ink into an answer

**Status:** designed 2026-08-26, not yet implemented. Owner decisions taken
this date are marked **[owner]**. Supersedes PLAN.md §6's pipeline detail and
§7's "Mistake checking" paragraph; §10's M3b bullet is the scope this refines.

This records what CHECK does, why the recognizer is not the one PLAN.md
specified, and one defect the design is built on top of. Read §2 before
touching `Grid`, and §5 before touching `Recognizer`'s thresholds — several
decisions below invert the obvious answer, and the reasoning is not
recoverable from the code.

Provenance markers, borrowed from `ENGINE-IMPROVEMENTS.md`:

- **[src]** — read in the source, citable.
- **[test]** — proven by an assertion that was actually run.
- **[reasoned]** — argument only, unmeasured.
- **[owner]** — a decision, not a finding.

---

## 1. The defect this is built on

**Erasing does not survive a reload.** Ink a cell, erase it with the pen's
other end, quit, relaunch: the erased stroke is back in `App@ink_strokes` and
still in the `strokes` table. **[test]**

Two probe assertions, run against a green baseline (2546 total, 2499 OK, 0
crash, 0 warning, the only 2 KO being the probes themselves):

```
PROBE A: erasing a cell removes its stroke from the journal
 - Assertion[3]  Expected: 0  Actual: 1   # rows left in `strokes`
 - Assertion[4]  Expected: 0  Actual: 1   # strokes left in @ink_strokes
PROBE B: an erased stroke is not replayed after a relaunch
 - Assertion[2]  Expected: 0  Actual: 1   # strokes replayed onto a fresh App
```

The cause is a one-line reasoning slip in the M3a plan
([`2026-08-25-m3-sqlite-saves.md`](../plans/2026-08-25-m3-sqlite-saves.md),
Task 6), which claims:

> The eraser is not journaled: it never draws ink, it repaints cells from the
> model, so a reload restores erased cells correctly by simply not having
> those strokes.

The stroke *was* journaled — at pen-lift, by `App#close_ink_capture`, before
the eraser ever came near it. `App#erase_at` calls only
`Renderer#redraw_cell`; it touches neither `@ink_strokes` nor the DB. **[src]**
So the glass is cleaned and the record is not.

**Why this is M3b's problem and not a footnote.** The entire gameplay model
the owner described on 2026-08-25 is *"you can erase your notes, press a check
button and then we can check"*. Erase is the load-bearing step **before**
CHECK. Today a player who erases their scratch notes, quits, and comes back
has those notes back on the board — and CHECK would read them as answers.
The check cannot be correct on top of an erase that lies.

Folded in as Task 2 of the implementation plan rather than landed separately
**[owner]**, because it and the retire-on-check mechanism (§4) touch the same
two things — `Store#strokes` and the schema bump — and splitting them across
two commits would mean designing that column twice.

---

## 2. What CHECK does

CHECK is the moment ink becomes an answer. The pass runs over every
**non-given** cell that holds live ink, and each such cell gets exactly one of
three verdicts:

| Verdict | Condition | Cell afterwards | Persisted? |
|---|---|---|---|
| **read** | a digit cleared both thresholds | printed digit, ink retired | yes, as the digit |
| **wrong** | read, but ≠ the stored solution | printed digit + corner ✕ | yes, as the digit |
| **unreadable** | cleared neither threshold | ink kept + corner `?` | yes, as `'?'` |

Two cases are deliberately *not* verdicts, and both are silent no-ops:

- **A given cell holding ink.** A clue cannot be answered, so the recognizer
  never runs on it and its ink is left exactly as drawn — a player who circles
  or annotates a clue keeps that annotation. `Grid#set_entry` already raises on
  a given, so skipping these is also what stops CHECK from crashing on one.
- **A cell with no live ink.** Never checked, or checked and read (its ink is
  retired), or edited since. Nothing to do either way.

An invariant worth stating, because two rules combine to guarantee it: at CHECK
time **no cell has both live ink and an entry.** Reading a cell retires its ink
(§4), and pen-down into a cell that holds an entry clears that entry before the
ink is echoed (below). So the pass never has to decide which of the two wins.

### The cell prints what was read

The recognized digit is painted into the cell in `ENTRY_GRAY` and that cell's
ink stops being replayed. **[owner]**

PLAN.md §7 said the opposite — *"right cells keep their ink untouched"* — and
the reason it lost is diagnosability. Under the old rule a recognizer that
misreads a correct 4 as a 9 shows the player a ✕ over a cell they got right,
and nothing distinguishes that from their own logic error. Printing what was
read makes the machine's mistake visible and therefore fixable: you see a 9
where you wrote a 4, and you rewrite it. The cost is that a cell's ink stops
being the player's own hand, which is why the strokes are **retired, not
deleted** (§4) — the record keeps them.

### Unreadable is a real, persisted cell state

`Grid` gains a fourth state beside given / entry / empty. **[owner]**

This was the option flagged as having the largest blast radius, and measuring
it showed the flag was wrong: **nothing in `mrblib/redoku/sudoku/` takes a
`Grid` instance.** `Solver.solve/count/unique?/cost`, `Rater.measure/rate/
score/demand_of`, and `Techniques.solves?` all take a raw 81-element `values`
array. **[src]** So the state is containable inside `Grid` itself, and the
engine cannot see it:

```ruby
UNREADABLE = -1                       # @entries[i] is otherwise 0..9

def value_at(i)
  return @givens[i] if @givens[i] != 0
  @entries[i] > 0 ? @entries[i] : 0   # <- the whole containment, one line
end
```

Everything downstream of `value_at` then keeps working untouched, and two
properties fall out for free rather than being coded:

- `values` / `values_s` render an unreadable cell as empty, so the engine sees
  the board it has always seen.
- `solved?` is `Grid.complete?(values)`, which is already false while any cell
  reads 0 — so **an unreadable cell cannot produce a false win.** No separate
  guard exists, and none should be added; deleting the sentinel filter would
  break the win screen, which is the property worth pinning with a test.

The visible changes are small and local: `str_of` maps `-1` to `'?'` (safe for
`givens_s` and `values_s` too, since `value_at` filters the sentinel out of
both); new `set_unreadable(i)` and `unreadable?(i)`; and `Store` needs a
looser validator for the `entries` column only — `board?` is currently applied
to `givens`, `entries` *and* `solution` alike, and only `entries` may contain
`'?'`.

Rejected: keeping `?` transient (no schema or `Grid` work at all, but ✕ marks
survive a relaunch while `?` silently would not — an inconsistency the player
would have to learn) and a sidecar `unreadable` column on `games` (Grid stays
pure, but the board's state then lives in two places that must agree).

### Marks are derived, never stored

For a non-given cell `i` with entry `e`:

```
e == UNREADABLE          -> :unreadable   (paint '?')
e == 0                   -> no mark       (never checked, or edited since)
e == solution[i]         -> no mark
otherwise                -> :wrong        (paint '✕')
```

So the marks need no column, no dirty set and no invalidation: they are a pure
function of state that already persists. `Renderer#redraw_cell(index, grid)`
grows a `mark:` keyword rather than being handed the solution — the renderer
stays ignorant of what a correct answer is. **[reasoned]**

### Editing a checked cell clears its verdict

PLAN.md §7's *"they stay until edited"*, made exact: pen-down inside a cell
that holds an entry clears that entry (hence its mark) and repaints the cell
before the new ink is echoed.

The waveform here is the one trap M3b was warned about. `App#flush_ink` and
PLAN.md §10 both say it: a repaint that puts an `ENTRY_GRAY` digit — or
removes one — needs `GL16` for that region, because `DU` is two-level and 96
is a mid tone. So this first-stroke-into-a-checked-cell path costs one
cell-sized `GL16` before the stroke's own `DU` echo. That is the price of the
rule and it is worth it; a `DU` repaint would leave the old digit's ghost.

---

## 3. CHECK is not gated, and counts itself

CHECK runs on whatever is on the board, at any time. The App counts presses
and the win screen reports the total. **[owner]**

The concern this settles: unrestricted, CHECK is a correctness oracle — write
a digit, check, see ✕, try the next one, and the puzzle falls to brute force
with no logic at all. Two answers were available. Gating CHECK until every
non-given cell holds ink removes the oracle outright and matches the owner's
own phrasing (*"when you're done"*), at the cost of ever being able to sanity-
check partial progress. Counting instead leaves the choice with the player and
gives §7's otherwise undefined *"n mistakes checked"* a real referent.

The count is transient — an App ivar, not a column. A relaunch resets it,
which is a known and accepted limit: it is a scoreboard for one sitting, not a
record.

---

## 4. Retiring ink, and the free re-check

Schema **v3**, additive in the same style as v2's `CREATE TABLE IF NOT
EXISTS`: `ALTER TABLE strokes ADD COLUMN retired INTEGER NOT NULL DEFAULT 0`.
`Store#strokes` gains `WHERE retired = 0`; a new `Store#retire_strokes(ids)`
sets it. Existing v2 files upgrade in place with every stroke live, which is
correct — nothing has been checked yet.

Erase and check need *different* operations, and conflating them would be a
bug:

- **Erase deletes.** The player erased it; it is gone. This also keeps the
  journal inside `STROKES_CAP` instead of growing a permanent tail of
  tombstones.
- **CHECK retires.** The strokes stay in the record, they simply stop being
  replayed, because the cell now prints a digit instead.

Both need to answer "which strokes are in cell *i*", and neither should pay a
table scan to do it on a device. The answer is already in memory:
`@ink_strokes` holds every live stroke with its decoded points. Give each
entry its **row id** — `journal_stroke` returns the new id, `Store#strokes`
selects it — and both operations become an in-memory filter plus one indexed
statement over a small id list. **No `cell` column, and no back-fill
migration.** A stroke buffered before the first dig has no id, which is
harmless: those are discarded when the dig lands (M3a Task 6).

`Recognizer.cell_of(stroke)` — bounding-box centre to a cell index, or nil off
the board — is built once and serves erase, retire and the recognizer's own
grouping.

**§7's incremental re-check falls out for free.** PLAN.md promises that
re-checking *"re-recognizes only cells whose ink changed since the last
CHECK"*, which sounds like per-cell version tracking. It is not: a cell that
was read has no live strokes, so it is not in the grouped set at all, and a
cell the player has since edited has new live strokes and is. The retire
mechanism *is* the incremental-recheck mechanism. Nothing further to build.

### A contradiction in §6 to resolve

PLAN.md §6 states both that a stroke *"belongs to the cell containing its
bounding-box center"* (step 1) and, under **Pre-classification guards**, that
only *"strokes fully inside a cell's bounds"* are used. These disagree, and a
digit written slightly over a cell line — normal handwriting on a 140 px cell
— is exactly the case that separates them.

Bounding-box centre wins; the "fully inside" guard is dropped. It would
silently discard legitimate answers, and the failure mode is invisible to the
player. The dot guard from the same paragraph stays: total path under 8 px is
an accidental touch, not ink. **[reasoned]**

---

## 5. The recognizer

### $P as specified does not fit

PLAN.md §6 specifies the $P point-cloud recognizer at 48 resampled points
against templates for digits 1–9. Costed before writing it:

$P's greedy cloud match runs `n^(1-ε)` start positions (ε = 0.5), each a full
greedy pass of O(n²) point-to-point comparisons. At n = 48 that is ≈ 7 × 2304
≈ 16k point-distance evaluations *per template comparison*. Against 45
templates (9 digits × 5 samples) that is ≈ 725k per cell, and a finished board
holds ~50 inked cells: **≈ 36M point-distance evaluations per CHECK**, each
one several mruby VM instructions. Dropping to n = 32 only reaches ≈ 14M.
**[reasoned]**

That is seconds to minutes on a Cortex-A7, not the "one invocation instead of
hundreds" §6 assumes it bought. The relevant precedent is in
`ENGINE-IMPROVEMENTS.md`: in mruby, arithmetic and `[]` have inlined opcodes
while every bitwise operator is a method send, so interpreted inner loops cost
far more than the C intuition suggests, and the fix is lookup tables and fewer
passes rather than micro-optimising the pass.

### Two stages, with the second one provisional

**Stage 1 — features.** Normalise the cell's combined ink and reduce it to a
short integer vector: a 4×4 or 5×5 ink-density grid plus a handful of shape
features (stroke count, aspect ratio, total path length, direction reversals,
endpoint count). Nearest-neighbour by squared distance costs ≈ 25 multiply-adds
× 45 templates ≈ 1.1k operations per cell — four orders of magnitude under
$P, and ≈ 55k per board. **[reasoned]**

**Stage 2 — $P on the survivors.** Stage 1 prunes 9 digits to the best 2;
stage 2 runs the greedy cloud match at n = 32 against just those two digits'
templates (≈ 10 clouds), ≈ 60k point-distance evaluations per cell and ≈ 3M
per board. Aspect ratio is preserved through normalisation, because it is what
separates 1 from 7, and the degenerate near-vertical 1 needs a guard against
dividing by a tiny width.

Stage 2 exists because a coarse density grid is where 4/9, 3/5 and 1/7 would
be expected to blur, and $P's stroke-order and stroke-count invariance is
worth paying for precisely on that shortlist. But whether it is *needed* is an
empirical question, so:

> **Decision gate.** Task 1 of the plan is a measured spike. If stage 1 alone
> clears the accuracy bar on the corpus, ship stage 1 and delete stage 2.
> Record the measured numbers here either way.

The seam is fixed regardless, which is what lets the rest of M3b be built in
parallel against a stub:

```ruby
Recognizer.read(strokes) -> [digit_or_nil, confidence]
```

A ~1–3 s CHECK is acceptable and should be *shown*: `Renderer#draw_progress`
and `#flush_progress` already exist for the generator splash and can be driven
per cell. A press whose only visible result arrives a second later reads as a
button that did nothing — the same finding M1 recorded for button
acknowledgement, and the reason every press paints inverted.

> **Shipped without the bar, and the paragraph above is why it was tried**
> (removed 2026-08-28, after the owner played it: "the CHECK button actually
> has a progress bar that gets stuck and doesn't undraw after pressing it").
> Its premise went with stage 2. The 1–3 s is this section's own estimate for
> **stage 1 plus $P on a shortlist** (≈3M point-distance evaluations per
> board); the decision gate deleted stage 2, and what ships is stage 1 alone
> at ≈1.1k operations per cell — four orders of magnitude less. Driving a
> per-cell bar over that pass cost more than the pass: up to ~50 DU panel
> updates, unthrottled (unlike the generator's, which `PROGRESS_STEP_PX`
> bounds to about twenty however long a search runs).
>
> It could not be erased from where it was drawn, either. `progress_rect`
> sits inside `board_rect` on purpose — `draw_board`'s white fill is what
> erases it for generation — but the CHECK pass repaints only the cells it
> read, so the bar crossed ten cells nothing in that loop had reason to
> touch and survived to the closing `flush_board`; and the last cell makes
> `num == den`, so what stuck there was a *full* black bar. Its DU flush
> also thresholded the `ENTRY_GRAY` digits inside its own rect, which is the
> waveform rule the rest of the renderer obeys.
>
> **The paragraph's actual requirement is met without it.** `App#acknowledge`
> inverts the pressed button before the pass and releases it after, so CHECK
> is visibly held down for the whole duration — the M1 finding this section
> cites, applied where it belongs. If a device measurement ever shows a
> board's worth of cells taking a second, the honest answer is a bar drawn
> *outside* `board_rect` (or one whose region the pass repaints on the way
> out) and throttled like the generator's, not this one restored.

### Thresholds err toward refusing to guess

Accept a digit only on a high confidence score **and** a wide margin over the
runner-up; otherwise return nil and let the cell read unreadable. **[owner]**

The asymmetry that decides this is not the one it looks like. A false ✕ is
visible and recoverable — the printed digit shows you the misread. A false
`?` costs one rewrite. But a guess that happens to *match the solution* in a
cell where the player wrote something else is a **silent false pass**, and if
it is the last cell it declares a board solved that is not. That failure is
invisible and unrecoverable, so the thresholds are tuned against it, not
against total error rate. Tuning to minimise total wrong verdicts was
considered and rejected: it weights a false `?` and a false win equally, and
they are not equal.

### Templates: authored now, recorded later

The chicken-and-egg is real — `--record` needs a recognizer, and the
recognizer needs templates. Resolved by ordering **[owner]**:

1. Hand-author polyline templates as Ruby literals, resampled at load. The
   recognizer is host-testable from day one and nothing blocks on hardware.
2. Ship `--record`: prompts "WRITE 1 … WRITE 9" for a few rounds and writes
   `/home/root/redoku/templates.local` as one line per sample,
   `digit<TAB>x,y x,y|…` — the same text-points encoding as
   `Store.encode_pts`, for the same reason (the SQLite binding truncates TEXT
   at the first NUL, so nothing binary round-trips).
3. The owner records on-device. Those clouds are committed as **both** the
   shipped bootstrap set and §9's corpus, split train/holdout, and the
   thresholds are tuned against the holdout.

The game loads the compiled-in shipped set and overlays `templates.local` when
present, so the recognizer tunes itself to one hand cheaply.

Rejected: recording first against a stub matcher (best accuracy immediately,
but no host-testable recognizer until a device session clears) and
synthesising templates by tracing the built-in 5×7 font glyphs (fully
deterministic, but a bitmap glyph is not the shape a hand draws, so the corpus
test would measure the wrong thing).

---

## 6. Win screen

A new `@screen` state beside `:play` and the GAMES menu. Full `GC16` flash,
`SOLVED`, the check count, and a tap anywhere deals a new puzzle.

It fires when every non-given cell holds an entry equal to `solution[i]`.

`Grid#solved?` is *almost* the same test and is not the one to use.
`Grid.complete?` is "every cell filled **and** `consistent?`", so on a puzzle
with a unique solution a complete-and-consistent board must be that solution,
which makes `solved?` sufficient in theory. **[src]** Comparing against the
stored solution directly is preferred anyway: it is cheaper than a 27-unit
consistency sweep, it is the same comparison the ✕ marks already run per cell,
and it does not quietly depend on uniqueness holding — a property the
generator guarantees but the win screen should not have to know about.

Unreadable cells need no special handling in either form: the sentinel is
never equal to a digit, and `value_at` filters it to 0.

---

## 7. Difficulty menu

Kept in M3b rather than deferred **[owner]**. The `Level` button stops cycling
and opens a picker screen instead: five rows, one per `Rater::TIERS` entry,
the current one marked, tap to select and deal.

Cycling worked, but five tiers means up to five presses and a full dig on each
one that lands — the menu makes the choice one tap. The machinery to copy
already exists in the GAMES menu: `Layout.menu_row_at` / `menu_row_rect`, the
`menu_target_at` dispatch, the row-tap acknowledgement discipline and the
`restore: false` repaint rule. Cycling is *replaced*, not kept alongside; two
ways to do one thing is how the tier label and `Renderer::DIFFICULTIES` drifted
apart before (`rater.rb`'s note: "Do not reintroduce one").

---

## 8. Layout

`:check` takes row 1's free third slot, `[BOARD_X + 2 * (BTN_W + BTN_GAP),
BTN_ROW1_Y]` = x 932, which is where PLAN.md §8's sketch has always drawn it.
This is not an arbitrary free slot: it keeps `:quit` alone at the far end of
row 2 across a dead gap, which is the rule `Layout`'s own comment states —
a mis-aimed tap must not be able to end the game.

---

## 9. What this does not do

Recorded so it is not re-litigated:

- **The check count does not survive a relaunch** (§3). It is per-sitting.
- **A retired stroke is never un-retired.** Editing a checked cell clears the
  entry and starts fresh ink; the old hand stays in the record but never
  returns to the glass. There is no undo.
- **Erase remains manual-verify on hardware, permanently.** PLAN.md §9: the
  TCP injection rig drives rm2fb's `sendPen`, which writes only
  `BTN_TOOL_PEN`, so no injected sequence can produce an eraser event. Task
  2's fix is fully covered at the Ruby layer and not at all on the device.
- **No mid-play recognition, no pencil marks, no undo, no timer.** PLAN.md
  §10's v2 parking lot stands.
