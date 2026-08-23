assert('Generator.full_board makes a complete valid grid, seed-stable') do
  gen = Redoku::Sudoku::Generator
  g = Redoku::Sudoku::Grid
  board = gen.full_board(Redoku::Rng.new(11))
  assert_true g.complete?(board)
  assert_equal(board, gen.full_board(Redoku::Rng.new(11)))
  assert_false board == gen.full_board(Redoku::Rng.new(12))
end

assert('Generator.dig_order covers all 81 cells as symmetric pairs') do
  gen = Redoku::Sudoku::Generator
  order = gen.dig_order(Redoku::Rng.new(1))
  # 40 pairs plus the centre, which is its own partner: 40*2 + 1 = 81.
  assert_equal(41, order.size)
  seen = {}
  order.each do |pair|
    assert_equal(80, pair[0] + pair[1]) # 180-degree rotation
    seen.store(pair[0], true)
    seen.store(pair[1], true)
  end
  assert_equal(81, seen.keys.size)
  # The centre is the only self-paired group.
  selves = order.select { |p| p[0] == p[1] }
  assert_equal(1, selves.size)
  assert_equal(40, selves[0][0])
end

assert('Generator.dig_chain reports removals and the clue count after each') do
  gen = Redoku::Sudoku::Generator
  solution = gen.full_board(Redoku::Rng.new(5))
  chain = gen.dig_chain(solution, Redoku::Rng.new(5))
  removals = chain[0]
  clues_after = chain[1]

  # One clue count per point along the chain, including the untouched board.
  assert_equal(removals.size + 1, clues_after.size)
  assert_equal(81, clues_after[0])
  assert_true removals.size > 0

  k = 1
  while k < clues_after.size
    dropped = clues_after[k - 1] - clues_after[k]
    # A group is a symmetric pair (2 cells) or the centre (1).
    assert_true dropped == 1 || dropped == 2
    pair = removals[k - 1]
    assert_equal(80, pair[0] + pair[1])
    assert_equal(dropped, pair[0] == pair[1] ? 1 : 2)
    k += 1
  end

  # The floor is respected, and in practice never reached: uniqueness under
  # symmetry stops the dig well above it.
  assert_true clues_after[clues_after.size - 1] >= gen::MIN_CLUES
end

assert('every board along a dig chain is uniquely solvable') do
  gen = Redoku::Sudoku::Generator
  s = Redoku::Sudoku::Solver
  # The load-bearing invariant of the whole design: the chain is only a valid
  # thing to search because EVERY point on it is a real puzzle. dig_chain only
  # keeps a removal that left the board unique, so this must hold at every k --
  # if it fails anywhere, the generator can hand the player an ambiguous board.
  solution = gen.full_board(Redoku::Rng.new(13))
  chain = gen.dig_chain(solution, Redoku::Rng.new(13))
  removals = chain[0]

  k = 0
  while k <= removals.size
    board = gen.board_at(solution, removals, k)
    assert_true s.unique?(board)
    k += 1
  end
end

assert('Generator.board_at replays exactly k removals, symmetrically') do
  gen = Redoku::Sudoku::Generator
  solution = gen.full_board(Redoku::Rng.new(6))
  chain = gen.dig_chain(solution, Redoku::Rng.new(6))
  removals = chain[0]
  clues_after = chain[1]

  # Nothing removed yet is the solution itself.
  assert_equal(solution, gen.board_at(solution, removals, 0))

  # Any point along the chain has the clue count the chain recorded, counted
  # independently here rather than taken from clues_after.
  [1, removals.size / 2, removals.size].each do |k|
    board = gen.board_at(solution, removals, k)
    filled = 0
    board.each { |d| filled += 1 if d != 0 }
    assert_equal(clues_after[k], filled)
    # Rotational symmetry: a hole at i implies a hole at 80 - i. A pair
    # blocked by uniqueness was restored whole, which is what keeps this true.
    81.times do |i|
      assert_equal(0, board[80 - i]) if board[i] == 0
    end
    # Every surviving clue agrees with the solution it was cut from.
    81.times do |i|
      assert_equal(solution[i], board[i]) if board[i] != 0
    end
  end

  # And it does not disturb the solution it replays from.
  before = solution.dup
  gen.board_at(solution, removals, removals.size)
  assert_equal(before, solution)
end

assert('Generator.first_usable skips boards too full to be puzzles') do
  gen = Redoku::Sudoku::Generator
  solution = gen.full_board(Redoku::Rng.new(9))
  chain = gen.dig_chain(solution, Redoku::Rng.new(9))
  clues_after = chain[1]
  k = gen.first_usable(clues_after)

  # It really is usable...
  assert_true clues_after[k] <= gen::MAX_CLUES
  # ...and it is the FIRST such, so the one before it is not.
  assert_true clues_after[k - 1] > gen::MAX_CLUES if k > 0
end

assert('Generator.dig returns a board and its measurement') do
  gen = Redoku::Sudoku::Generator
  s = Redoku::Sudoku::Solver
  r = Redoku::Sudoku::Rater
  solution = gen.full_board(Redoku::Rng.new(5))
  out = gen.dig(solution, :easy, Redoku::Rng.new(5))
  puzzle = out[0]
  m = out[1]

  assert_false puzzle.nil?
  assert_false m.nil?
  assert_true s.unique?(puzzle)
  # The measurement really describes the board handed back, not some other
  # point on the chain.
  assert_equal(r.measure(puzzle)[:score], m[:score])
  assert_equal(r.measure(puzzle)[:tier], m[:tier])

  clues = 0
  puzzle.each { |d| clues += 1 if d != 0 }
  assert_true clues <= gen::MAX_CLUES
  assert_true clues >= gen::MIN_CLUES
end

assert('Generator.dig does not mutate the solution it digs from') do
  gen = Redoku::Sudoku::Generator
  solution = gen.full_board(Redoku::Rng.new(2))
  before = solution.dup
  gen.dig(solution, :hard, Redoku::Rng.new(2))
  assert_equal(before, solution)
end

assert('Generator.dig walks from the shallow end, so easy keeps its clues') do
  gen = Redoku::Sudoku::Generator
  # Two requests against the SAME chain: the easier one must not come back
  # with fewer clues than the harder one. That is the whole point of walking
  # shallow-to-deep and returning the first acceptable board -- both ends of
  # the chain would satisfy an easy request, and the one with more clues is
  # the one that looks like the puzzle it claims to be.
  solution = gen.full_board(Redoku::Rng.new(31))
  easy = gen.dig(solution, :easy, Redoku::Rng.new(31))
  hard = gen.dig(solution, :hard, Redoku::Rng.new(31))

  easy_clues = 0
  easy[0].each { |d| easy_clues += 1 if d != 0 }
  hard_clues = 0
  hard[0].each { |d| hard_clues += 1 if d != 0 }
  assert_true easy_clues >= hard_clues
  # And the easier request cannot have scored higher than the harder one.
  assert_true easy[1][:score] <= hard[1][:score]
end

assert('Generator.tier_distance measures along the tier order') do
  gen = Redoku::Sudoku::Generator
  assert_equal(0, gen.tier_distance(:easy, :easy))
  assert_equal(1, gen.tier_distance(:medium, :easy))
  assert_equal(1, gen.tier_distance(:easy, :medium))
  assert_equal(2, gen.tier_distance(:hard, :easy))
  # An unknown tier is further away than any real one, so it never wins.
  assert_true gen.tier_distance(:nonsense, :easy) > gen.tier_distance(:hard, :easy)
end

assert('Generator.score_distance is zero inside the band and grows outside') do
  gen = Redoku::Sudoku::Generator
  r = Redoku::Sudoku::Rater
  band = r.band(:medium)
  assert_equal(0, gen.score_distance(band[0], :medium))
  assert_equal(0, gen.score_distance(band[1], :medium))
  assert_equal(5, gen.score_distance(band[0] - 5, :medium))
  assert_equal(7, gen.score_distance(band[1] + 7, :medium))
  # The top band is open-ended, so nothing is above it.
  hardest = r::TIERS[r::TIERS.size - 1]
  assert_equal(0, gen.score_distance(1_000_000, hardest))
end

assert('Generator.closer? prefers the right tier, then the nearer score') do
  gen = Redoku::Sudoku::Generator
  r = Redoku::Sudoku::Rater
  band = r.band(:medium)
  right = { tier: :medium, score: band[0] }
  wrong = { tier: :easy, score: band[0] - 100 }
  # Tier distance dominates.
  assert_true gen.closer?(right, wrong, :medium)
  assert_false gen.closer?(wrong, right, :medium)
  # Within the same wrong tier, the nearer score wins.
  near = { tier: :easy, score: band[0] - 1 }
  far = { tier: :easy, score: band[0] - 100 }
  assert_true gen.closer?(near, far, :medium)
  assert_false gen.closer?(far, near, :medium)
  # Equal is not closer, so the earliest candidate kept wins ties.
  assert_false gen.closer?(near, near, :medium)
end

assert('Generator.generate returns a puzzle, its solution and its measurement') do
  gen = Redoku::Sudoku::Generator
  g = Redoku::Sudoku::Grid
  s = Redoku::Sudoku::Solver

  out = gen.generate(:easy, Redoku::Rng.new(3))
  assert_false out.nil?
  assert_true g.complete?(out[:solution])
  assert_true Redoku::Sudoku::Rater::TIERS.include?(out[:tier])
  assert_false out[:score].nil?
  assert_false out[:counts].nil?
  assert_false out[:clues].nil?

  puzzle = out[:grid].values
  assert_true s.unique?(puzzle)
  # The stored solution really does solve the stored puzzle.
  81.times do |i|
    assert_equal(out[:solution][i], puzzle[i]) if puzzle[i] != 0
  end
  # Every filled cell of a fresh puzzle is a GIVEN: no player entries yet.
  81.times do |i|
    assert_equal((puzzle[i] != 0), out[:grid].given?(i))
  end
  # The reported clue count agrees with the board, counted independently.
  filled = 0
  puzzle.each { |d| filled += 1 if d != 0 }
  assert_equal(filled, out[:clues])
  assert_equal(filled, out[:grid].clue_count)
  assert_equal(81, out[:grid].givens_s.size)
end

assert('Generator.generate never hands back a board that is barely dug') do
  gen = Redoku::Sudoku::Generator
  # A real bug this catches rather than a hypothetical one. The search accepts
  # the shallowest board that scores inside the requested band -- and the
  # shallowest board on any chain is the COMPLETE SOLUTION, which scores zero
  # and sits comfortably inside the easy band. Without MAX_CLUES, an easy
  # request was answered with a finished sudoku.
  [:easy, :medium, :hard].each do |tier|
    out = gen.generate(tier, Redoku::Rng.new(50))
    assert_true out[:clues] <= gen::MAX_CLUES
    assert_true out[:clues] < 81
    assert_true out[:clues] >= gen::MIN_CLUES
  end
end

assert('Generator.generate hits every tier it is asked for') do
  gen = Redoku::Sudoku::Generator
  s = Redoku::Sudoku::Solver
  # All three must be reachable, which is not a given: an earlier design made
  # :medium nearly unreachable, and the one before that collapsed two tiers
  # into one. A few seeds each, since the point is that the tier comes out
  # right rather than that one particular board does.
  [:easy, :medium, :hard].each do |tier|
    3.times do |n|
      out = gen.generate(tier, Redoku::Rng.new(200 + (n * 7)))
      assert_equal(tier, out[:tier])
      assert_true s.unique?(out[:grid].values)
    end
  end
end

assert('Generator.generate is reproducible from its seed') do
  gen = Redoku::Sudoku::Generator
  a = gen.generate(:medium, Redoku::Rng.new(77))
  b = gen.generate(:medium, Redoku::Rng.new(77))
  assert_equal(a[:grid].givens_s, b[:grid].givens_s)
  assert_equal(a[:solution], b[:solution])
  assert_equal(a[:tier], b[:tier])
  assert_equal(a[:score], b[:score])
end

assert('Generator.generate always returns a playable puzzle, tier or not') do
  gen = Redoku::Sudoku::Generator
  s = Redoku::Sudoku::Solver
  # With a budget of one attempt the generator may fail to hit the requested
  # tier -- one solution in four produces no hard board anywhere along its
  # chain. It must still hand back a real puzzle rather than nil, because the
  # game has a board to draw either way, and report the tier it actually
  # achieved rather than the one that was asked for.
  out = gen.generate(:hard, Redoku::Rng.new(4), 1)
  assert_false out.nil?
  assert_true s.unique?(out[:grid].values)
  assert_true Redoku::Sudoku::Rater::TIERS.include?(out[:tier])
  assert_true out[:clues] <= gen::MAX_CLUES
end

assert('Generator.generate reports the measurement of the board it returns') do
  gen = Redoku::Sudoku::Generator
  r = Redoku::Sudoku::Rater
  # The reply must describe the board in it. A generator that reported the
  # tier it was ASKED for rather than the one it achieved would be lying, and
  # the header on screen would be lying with it.
  out = gen.generate(:hard, Redoku::Rng.new(61), 1)
  m = r.measure(out[:grid].values)
  assert_equal(m[:tier], out[:tier])
  assert_equal(m[:score], out[:score])
  assert_equal(m[:guesses], out[:guesses])
  assert_equal(m[:hardest], out[:hardest])
end
