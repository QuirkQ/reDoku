assert('Solver.solve completes a solvable board and leaves it valid') do
  s = Redoku::Sudoku::Solver
  g = Redoku::Sudoku::Grid

  # An already-solved board comes back unchanged.
  solved = solved_values
  assert_equal solved, s.solve(solved)

  # A board with two holes is filled to a complete, consistent grid, and
  # every given survives.
  easy = values_of(EASY_81)
  out = s.solve(easy)
  assert_true g.complete?(out)
  81.times { |i| assert_equal easy[i], out[i] if easy[i] != 0 }
  # EASY_81 came from SOLVED_81 and is unique, so the answer is that board.
  assert_equal solved, out

  # Six holes.
  assert_equal solved, s.solve(values_of(UNIQUE_81))

  # A wholly empty board is still solvable.
  assert_true g.complete?(s.solve(Array.new(81, 0)))
end

assert('Solver.solve does not mutate the board it was given') do
  easy = values_of(EASY_81)
  before = easy.dup
  Redoku::Sudoku::Solver.solve(easy)
  assert_equal before, easy

  empty = Array.new(81, 0)
  Redoku::Sudoku::Solver.solve(empty)
  assert_equal Array.new(81, 0), empty
end

assert('Solver.solve returns nil for an inconsistent board') do
  s = Redoku::Sudoku::Solver
  # Cell 0 is empty in EASY_81 and row 0 already holds 2..9, so only 1 fits.
  # Forcing a 2 there duplicates cell 1's digit: the board is illegal before
  # any search starts, and solve must say so rather than "solving" the one
  # remaining hole and declaring victory.
  bad = values_of(EASY_81)
  bad[0] = 2
  assert_nil s.solve(bad)
  assert_equal 0, s.count(bad)
  assert_false s.unique?(bad)
end

assert('Solver.solve returns nil for a consistent but unsolvable board') do
  s = Redoku::Sudoku::Solver
  g = Redoku::Sudoku::Grid
  # Row 0 holds 1..8 in its first eight cells and cell 17 (row 1, col 8)
  # holds 9. Nothing repeats anywhere, so the board is legal -- but cell 8
  # has no candidate left: its row bars 1..8 and its column bars 9. This is
  # the case a consistency check alone cannot catch.
  wedged = Array.new(81, 0)
  8.times { |c| wedged[c] = c + 1 }
  wedged[17] = 9
  assert_true g.consistent?(wedged)
  assert_equal 0, g.candidates(wedged, 8)
  assert_nil s.solve(wedged)
  assert_equal 0, s.count(wedged)
end

assert('Solver.count stops at its limit and recognises uniqueness') do
  s = Redoku::Sudoku::Solver

  # A solved board has exactly one solution: itself.
  assert_equal 1, s.count(solved_values)
  assert_true s.unique?(solved_values)

  # Proper puzzles with real gaps.
  assert_equal 1, s.count(values_of(EASY_81))
  assert_true s.unique?(values_of(EASY_81))
  assert_equal 1, s.count(values_of(UNIQUE_81))
  assert_true s.unique?(values_of(UNIQUE_81))

  # MULTI_81 has three givens on an empty board, so the true count runs into
  # the billions. count MUST say 2 and stop -- if the early exit is broken
  # this assertion does not fail, it never returns, which is why the limit
  # is the subject of the test rather than an optimisation detail.
  assert_equal 2, s.count(values_of(MULTI_81))
  assert_false s.unique?(values_of(MULTI_81))

  # A higher ceiling is honoured exactly, not overshot.
  assert_equal 5, s.count(values_of(MULTI_81), 5)
  assert_equal 1, s.count(values_of(MULTI_81), 1)
end

assert('Solver.count does not mutate its input') do
  multi = values_of(MULTI_81)
  before = multi.dup
  Redoku::Sudoku::Solver.count(multi)
  assert_equal before, multi
end

assert('Solver.solve with an Rng varies its answer but stays correct') do
  s = Redoku::Sudoku::Solver
  g = Redoku::Sudoku::Grid
  empty = Array.new(81, 0)

  a = s.solve(empty, Redoku::Rng.new(1))
  b = s.solve(empty, Redoku::Rng.new(2))
  assert_true g.complete?(a)
  assert_true g.complete?(b)
  # Two seeds must not agree on a full board. If they do, the rng is not
  # reaching the digit ordering and every generated puzzle would be the
  # same one -- a bug that no other assertion here would catch.
  assert_false a == b

  # Same seed, same board: generation has to be reproducible from a seed.
  assert_equal a, s.solve(empty, Redoku::Rng.new(1))

  # Randomised order does not weaken correctness on a constrained board.
  assert_equal solved_values, s.solve(values_of(UNIQUE_81), Redoku::Rng.new(9))
end

assert('Solver.pick returns immediately on a forced cell') do
  s = Redoku::Sudoku::Solver
  g = Redoku::Sudoku::Grid
  # One hole in a solved board is forced by definition, and the early exit
  # means pick must hand it back without scanning on.
  values = solved_values
  values[40] = 0
  cand = s.build_cand(values)
  i = s.pick(values, cand)
  assert_equal 40, i
  assert_equal 1, g.count_bits(cand[i])

  # On a full board there is nothing to choose.
  full = solved_values
  assert_nil s.pick(full, s.build_cand(full))

  # A contradiction comes back as a cell with a ZERO mask rather than as nil,
  # so a caller can tell "nothing left to do" from "this branch is dead".
  wedged = Array.new(81, 0)
  8.times { |c| wedged[c] = c + 1 }
  wedged[17] = 9
  wcand = s.build_cand(wedged)
  dead = s.pick(wedged, wcand)
  assert_equal 8, dead
  assert_equal 0, wcand[dead]
end

assert('Solver.pick takes the global minimum, not the first empty cell') do
  s = Redoku::Sudoku::Solver
  g = Redoku::Sudoku::Grid

  # The heuristic is what keeps generation inside PLAN.md §7's budget, so it
  # is worth testing on a board where "first empty cell" and "fewest
  # candidates" are DIFFERENT cells. Emptying the whole top band plus two
  # cells of row 3 does that: the band's cells keep three or four candidates
  # each, while cell 27 is pinned to two.
  values = solved_values
  27.times { |i| values[i] = 0 }
  values[27] = 0
  values[28] = 0

  # Derive the expectation instead of hard-coding it, so this assertion does
  # not depend on arithmetic done by hand in a comment.
  counts = {}
  81.times do |i|
    counts.store(i, g.count_bits(g.candidates(values, i))) if values[i] == 0
  end
  min = nil
  counts.values.each { |n| min = n if min.nil? || n < min }

  # Premise check: with a forced cell anywhere, the early exit would be what
  # was under test instead of the minimum search.
  assert_true min > 1
  # Premise check: cell 0 is empty and must NOT be the answer, or "returns
  # the first empty cell" would pass this too.
  assert_equal 0, values[0]
  assert_true counts[0] > min

  cand = s.build_cand(values)
  i = s.pick(values, cand)
  assert_equal 0, values[i]
  assert_equal min, g.count_bits(cand[i])
  assert_true i > 0
end

assert('Solver.assign and unassign leave the candidate grid exactly as found') do
  s = Redoku::Sudoku::Solver
  # The undo list is what makes the incremental candidates safe: a peer whose
  # bit was already absent must NOT be handed the bit back on unassign, or
  # the grid would drift looser with every backtrack and the solver would
  # start accepting illegal boards.
  # An EMPTY board, so cell 0's peers genuinely still offer the digit and
  # there is something to remove. (UNIQUE_81 is no good here: every empty
  # peer of cell 0 is already pinned to a different single digit, so
  # assigning 1 there removes nothing and the grid correctly does not
  # change -- which says nothing about whether undo works.)
  values = Array.new(81, 0)
  cand = s.build_cand(values)
  before = cand.dup
  work = values.dup

  trail = s.assign(work, cand, 0, 5)
  assert_false trail.nil?
  assert_equal 5, work[0]
  assert_equal [0], trail[0]      # one cell assigned, no cascade on an empty board
  assert_equal 40, trail[1].size  # 20 peers x (index, bit)
  assert_false before == cand     # something really did change
  s.unassign(work, cand, trail)
  assert_equal 0, work[0]
  assert_equal before, cand

  # A peer that did NOT offer the digit must not be handed it back, or the
  # grid drifts looser on every backtrack and the solver starts accepting
  # illegal boards. Cell 1 is a peer of cell 0; take the 5 away from it
  # first, and assigning 5 at cell 0 must leave it out of the trail.
  cand[1] &= ~(1 << 5)
  narrowed = cand.dup
  trail2 = s.assign(work, cand, 0, 5)
  assert_equal 38, trail2[1].size # 19 peers now
  # The trail is flat pairs of [cell, bit], so read the cells out rather
  # than searching the whole thing for a value that might be a bit.
  cleared = []
  k = 0
  while k < trail2[1].size
    cleared << trail2[1][k]
    k += 2
  end
  assert_false cleared.include?(1)
  s.unassign(work, cand, trail2)
  assert_equal narrowed, cand
end

assert('Solver.assign cascades through singletons its own write CREATES') do
  s = Redoku::Sudoku::Solver
  # The cascade only follows cells whose mask it just narrowed to one. A cell
  # that was ALREADY a singleton before the write is never revisited, because
  # nothing about it changed -- `pick` catches those on the next turn
  # instead. That distinction is easy to get backwards, so it is pinned in
  # both directions here.
  work = Array.new(81, 0)
  cand = s.build_cand(work)
  # Cell 1 shares row 0 and box 0 with cell 0. Leave it two candidates, one
  # of which is the digit about to be placed, so removing that digit forces
  # it to the other.
  cand[1] = (1 << 5) | (1 << 6)
  # Cell 2 is already a singleton and does NOT contain the placed digit, so
  # the cascade must leave it alone.
  cand[2] = 1 << 7

  trail = s.assign(work, cand, 0, 5)
  assert_false trail.nil?
  assert_equal 5, work[0]
  assert_equal 6, work[1]         # forced by the write, so filled too
  assert_equal 0, work[2]         # already a singleton: not the cascade's job
  assert_equal 2, trail[0].size
  assert_equal [0, 1], trail[0]

  s.unassign(work, cand, trail)
  assert_equal Array.new(81, 0), work
  assert_equal((1 << 5) | (1 << 6), cand[1])
  assert_equal((1 << 7), cand[2])
end

assert('Solver.assign undoes its own partial cascade on a contradiction') do
  s = Redoku::Sudoku::Solver
  # Cell 1 holds {3,5} and cell 2 holds {5}; both share row 0 and box 0 with
  # each other and with cell 0. Writing a 3 at cell 0 is legal on its own,
  # but it forces cell 1 to the 5, and that leaves cell 2 with nothing at
  # all. assign must report the dead branch AND leave no trace -- a caller
  # that gets nil is told not to undo anything, so a half-written cascade
  # would quietly corrupt the search.
  work = Array.new(81, 0)
  cand = s.build_cand(work)
  cand[1] = (1 << 3) | (1 << 5)
  cand[2] = 1 << 5
  board_before = work.dup
  cand_before = cand.dup

  assert_nil s.assign(work, cand, 0, 3)
  assert_equal board_before, work
  assert_equal cand_before, cand

  # And the same across a whole exhaustive count, which is many assign and
  # unassign pairs deep: a leak shows up as a mismatch here. `tally` is the
  # right method to check it on, because it restores unconditionally -- it
  # has to, or a later branch would count against a corrupted grid.
  puzzle = values_of(UNIQUE_81)
  deep = s.build_cand(puzzle)
  snapshot = deep.dup
  board = puzzle.dup
  s.tally(board, deep, 2, nil)
  assert_equal snapshot, deep
  assert_equal puzzle, board # the board comes back untouched too

  # `search`, by contrast, deliberately does NOT unwind on success: `solve`
  # wants the solved board it just built, so the last winning assignment
  # stays put. Worth pinning so nobody "fixes" it into symmetry with tally.
  won = values_of(UNIQUE_81)
  wcand = s.build_cand(won)
  assert_true s.search(won, wcand, nil)
  assert_true Redoku::Sudoku::Grid.complete?(won)
  assert_equal solved_values, won
end

assert('Solver.cost is exactly 0 when no guessing was needed') do
  s = Redoku::Sudoku::Solver
  # cost is a count of DECISIONS, so "0" is not "cheap", it is the statement
  # "this puzzle falls out by propagation alone". The Rater turns this number
  # into points -- so many per guess -- and the Generator steers by the score
  # that comes out, which makes 0 the difference between "no guessing was
  # needed" and a per-guess premium. Hence == 0 rather than < something: a
  # solver that charged one unit for a forced cell would still look small and
  # would still be wrong.
  assert_equal 0, s.cost(solved_values)     # nothing at all to do
  assert_equal 0, s.cost(values_of(EASY_81))   # two holes, both forced by row
  assert_equal 0, s.cost(values_of(UNIQUE_81)) # six holes, each pinned by column
end

assert('Solver.cost charges nothing for a long forced cascade') do
  s = Redoku::Sudoku::Solver
  g = Redoku::Sudoku::Grid
  # The distinction the code comment says was measured wrong once before:
  # counting raw NODES made cost FALL as clues were removed, because a
  # heavily-clued board resolves one forced cell per node while a sparse one
  # clears many in a single cascade. So a board that resolves a lot of cells
  # with no branching has to come out at 0, not at "one per cell".
  #
  # Blanking the first 15 cells of SOLVED_81 does that: fifteen holes, still
  # exactly one solution, and no cell ever offers a real choice by the time
  # `pick` reaches it.
  board = solved_values
  15.times { |i| board[i] = 0 }

  # Premise checks, because "0" would be unremarkable if every hole were a
  # singleton from the start -- then nothing would be cascading. Count the
  # holes that begin with MORE than one candidate: those are the ones that
  # only become free because an earlier assignment narrowed them.
  holes = 0
  multi = 0
  81.times do |i|
    next unless board[i] == 0
    holes += 1
    multi += 1 if g.count_bits(g.candidates(board, i)) > 1
  end
  assert_equal 15, holes
  assert_true multi > 0
  assert_equal 1, s.count(board) # still a proper puzzle, not a guessing game

  # (Measured 2026-08-23: 15 holes, 9 of them starting with two candidates,
  # and the first cascade alone fills six cells.) None of it is a decision.
  assert_equal 0, s.cost(board)
end

assert('Solver.cost rises as clues are removed, it does not fall') do
  s = Redoku::Sudoku::Solver
  # The direction is the point. The rejected node-counting metric was p50 12
  # at 45 clues against 5 at 34 -- backwards -- and no single-board assertion
  # would have caught that, because each number looked plausible on its own.
  # Three boards off the same solution, differing only in how much was
  # erased, pin the ordering itself.
  #
  # Properties rather than exact numbers here: how much guessing a given
  # blanking pattern forces is a legitimate thing to shift when `pick`'s
  # heuristic is tuned, but it must never shift direction. (Measured
  # 2026-08-23: 0, 9 and 30 for 12, 27 and 60 blanks.)
  few = solved_values
  12.times { |i| few[i] = 0 }
  some = solved_values
  27.times { |i| some[i] = 0 }
  many = solved_values
  60.times { |i| many[i] = 0 }

  c_few = s.cost(few)
  c_some = s.cost(some)
  c_many = s.cost(many)
  assert_equal 0, c_few          # a dozen forced holes is still free
  assert_true c_some > c_few
  assert_true c_many > c_some
end

assert('Solver.cost is above 0 once the board forces a guess') do
  s = Redoku::Sudoku::Solver
  # The other half of the 0 semantic: a board that cannot be propagated to a
  # finish must charge for the guesses. If this ever came back 0 the Rater
  # would file the emptiest board there is as the easiest puzzle there is.
  #
  # The exact figures are recorded but not asserted. They are stable per
  # build -- the repeat assertions below prove that -- but they are a
  # function of `pick`'s tie-breaking and of trying digits in 1..9 order,
  # both of which are implementation choices someone may legitimately retune.
  # What must not drift is that they are above 0 and below the cap.
  multi = s.cost(values_of(MULTI_81)) # measured 41 (3 givens)
  empty = s.cost(Array.new(81, 0))    # measured 47
  assert_true multi > 0
  assert_true empty > 0
  # A real measurement must stay clear of the cap, or "capped" and "measured"
  # would be indistinguishable to every caller.
  assert_true multi < s::COST_CAP
  assert_true empty < s::COST_CAP

  # And the smallest non-zero case in this family: blanking one more cell than
  # the forced-cascade board above is enough to introduce a genuine choice.
  # (Measured 1 -- that board has two solutions, so whichever digit is tried
  # first at the branching cell completes it and nothing is backtracked. Not
  # asserted as 1: a different tie-break could pick a cell whose first digit
  # is wrong and pay 2, which is still the same statement.)
  edge = solved_values
  16.times { |i| edge[i] = 0 }
  assert_true s.cost(edge) > 0
end

assert('Solver.cost answers the same number every time, and takes no rng') do
  s = Redoku::Sudoku::Solver
  # The Generator steers by this number through the Rater's score: it digs,
  # rates, and keeps or reverts. If cost varied between calls it would be
  # steering by noise and puzzles would land in whichever difficulty band the
  # last coin flip chose, so equality across repeated calls is the assertion,
  # not "roughly the same".
  a = s.cost(values_of(MULTI_81))
  assert_equal a, s.cost(values_of(MULTI_81))
  assert_equal a, s.cost(values_of(MULTI_81))
  b = s.cost(Array.new(81, 0))
  assert_equal b, s.cost(Array.new(81, 0))

  # `cost` deliberately accepts no rng. Pinned by arity, because the whole
  # guarantee is that no caller CAN inject an ordering -- an optional rng
  # parameter added "for symmetry with solve" would silently reopen it.
  raised = false
  begin
    s.cost(values_of(MULTI_81), Redoku::Rng.new(1))
  rescue ArgumentError
    raised = true
  end
  assert_true raised

  # And the reason that matters: digit order really does move the number. The
  # same search WITH a shuffle counts a different number of decisions on the
  # same board, so a cost that accepted an rng would be reporting the seed as
  # much as the puzzle. Scan a handful of seeds rather than naming two, so
  # this asserts "some seed disagrees" and not a particular Rng output.
  varied = false
  seed = 1
  while seed <= 8
    work = Array.new(81, 0)
    counter = [0]
    s.search(work, s.build_cand(work), Redoku::Rng.new(seed), counter)
    varied = true if counter[0] != b
    seed += 1
  end
  assert_true varied
end

assert('Solver.cost answers COST_CAP for boards that are not measurements') do
  s = Redoku::Sudoku::Solver
  g = Redoku::Sudoku::Grid
  # Callers get one number back and no error channel, so a board that cannot
  # be rated has to answer something no real puzzle answers. COST_CAP is that
  # something. The failure this guards against is not a crash, it is a
  # plausible SMALL number: an inconsistent board whose search "succeeds"
  # against its own empty cells would come back as an easy puzzle, and the
  # Generator would happily ship it.
  assert_true s::COST_CAP > 0

  # Inconsistent: cell 0 is empty in EASY_81 and row 0 already holds 2..9, so
  # only 1 fits. A 2 there duplicates cell 1's digit -- illegal before any
  # search starts, exactly as in the solve test above.
  bad = values_of(EASY_81)
  bad[0] = 2
  assert_false g.consistent?(bad)
  assert_equal s::COST_CAP, s.cost(bad)

  # Consistent but unsolvable: row 0 holds 1..8 and cell 17 holds 9, so
  # nothing repeats but cell 8 has no candidate at all. This is the case the
  # door's consistency check cannot catch, so it has to be the search's
  # failure that produces the cap.
  wedged = Array.new(81, 0)
  8.times { |c| wedged[c] = c + 1 }
  wedged[17] = 9
  assert_true g.consistent?(wedged)
  assert_equal 0, g.candidates(wedged, 8)
  assert_nil s.solve(wedged)
  assert_equal s::COST_CAP, s.cost(wedged)
end

assert('Solver.cost does not mutate the board it was given') do
  s = Redoku::Sudoku::Solver
  # The Rater and Generator rate boards they are still holding -- the
  # Generator rates the very array it is digging -- so a cost call that left
  # a solved board behind would turn the puzzle under construction into its
  # own answer.
  multi = values_of(MULTI_81)
  before = multi.dup
  s.cost(multi)
  assert_equal before, multi

  empty = Array.new(81, 0)
  s.cost(empty)
  assert_equal Array.new(81, 0), empty

  easy = values_of(EASY_81)
  before_easy = easy.dup
  s.cost(easy)
  assert_equal before_easy, easy

  # The two capped paths too: they leave by a different exit, and the wedged
  # one goes through the search before failing.
  bad = values_of(EASY_81)
  bad[0] = 2
  before_bad = bad.dup
  s.cost(bad)
  assert_equal before_bad, bad

  wedged = Array.new(81, 0)
  8.times { |c| wedged[c] = c + 1 }
  wedged[17] = 9
  before_wedged = wedged.dup
  s.cost(wedged)
  assert_equal before_wedged, wedged
end

assert('Solver.search counts decisions and caps only when given a counter') do
  s = Redoku::Sudoku::Solver
  g = Redoku::Sudoku::Grid
  # `cost` is a thin wrapper, so the counting and the bail-out are really
  # properties of `search`. Two things are pinned here that cost alone cannot
  # show.
  #
  # First: the counter `search` fills is the number `cost` reports -- nothing
  # is added or lost in the wrapper.
  work = values_of(MULTI_81)
  counter = [0]
  assert_true s.search(work, s.build_cand(work), nil, counter)
  assert_equal s.cost(values_of(MULTI_81)), counter[0]

  # Second: passing a counter is what ARMS the cap, and the cap trips on a
  # decision. Starting the counter at the cap means the first real choice
  # takes it over, so an empty board -- nine candidates at every cell --
  # must abandon immediately and leave the board untouched, having written
  # nothing at all.
  empty = Array.new(81, 0)
  work = empty.dup
  counter = [s::COST_CAP]
  assert_false s.search(work, s.build_cand(work), nil, counter)
  assert_equal empty, work
  assert_true counter[0] > s::COST_CAP

  # ...whereas a board that needs no decisions is not stopped by an exhausted
  # budget at all, because it never spends any. This is the same "forced is
  # free" rule as in cost, observed from the other side: with the counter
  # already AT the cap, EASY_81 still solves and the counter never moves.
  easy = values_of(EASY_81)
  work = easy.dup
  counter = [s::COST_CAP]
  assert_true s.search(work, s.build_cand(work), nil, counter)
  assert_equal s::COST_CAP, counter[0]
  assert_true g.complete?(work)

  # `solve` passes no counter, so the cap cannot reach it. Note what the pair
  # below does and does not show: the empty board spends decisions (so the
  # bail-out is live for `cost` on it) and `solve` still finishes -- but its
  # cost is far under the cap, so this is not a demonstration that `solve`
  # survives a board that WOULD exceed it. No cheap fixture for that exists;
  # the guarantee is structural, in `solve` passing no counter at all, and
  # the pre-loaded counter above is what stands in for the expensive case.
  assert_true s.cost(empty) > 0
  assert_true g.complete?(s.solve(empty))
end
