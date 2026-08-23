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

assert('Solver.best_cell returns immediately on a forced cell') do
  s = Redoku::Sudoku::Solver
  g = Redoku::Sudoku::Grid
  # One hole in a solved board is forced by definition, and the early exit
  # means best_cell must hand it back without scanning on.
  values = solved_values
  values[40] = 0
  cell = s.best_cell(values)
  assert_equal 40, cell[0]
  assert_equal 1, g.count_bits(cell[1])

  # On a full board there is nothing to choose.
  assert_nil s.best_cell(solved_values)

  # A contradiction is reported as a ZERO mask rather than as nil, so a
  # caller can tell "nothing left to do" from "this branch is dead".
  wedged = Array.new(81, 0)
  8.times { |c| wedged[c] = c + 1 }
  wedged[17] = 9
  dead = s.best_cell(wedged)
  assert_equal 8, dead[0]
  assert_equal 0, dead[1]
end

assert('Solver.best_cell picks the global minimum, not the first empty cell') do
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

  cell = s.best_cell(values)
  assert_equal 0, values[cell[0]]
  assert_equal min, g.count_bits(cell[1])
  assert_true cell[0] > 0
end
