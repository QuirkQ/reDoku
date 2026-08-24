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
  # Two rungs rather than three, for cost: the upper rungs are gated on what a
  # board DEMANDS now, so a :hard request pays its whole attempt cap on most
  # chains rather than settling early, and this test is about MAX_CLUES rather
  # than about reaching a tier.
  #
  # The explicit 6 is DEFAULT_ATTEMPTS today, so it changes nothing right now
  # -- it is not a reduced budget and must not be read as one. It pins the cost
  # of this test against a future rise in DEFAULT_ATTEMPTS, which Task 3 is
  # going to make: a test whose subject is a clue-count guard rail has no
  # reason to pay for a bigger search than it does today.
  [:easy, :medium].each do |tier|
    out = gen.generate(tier, Redoku::Rng.new(50), 6)
    assert_true out[:clues] <= gen::MAX_CLUES
    assert_true out[:clues] < 81
    assert_true out[:clues] >= gen::MIN_CLUES
  end
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
  # WHY MEDIUM IS SAFE TO ASSERT, and READ THE FIRST LINE OF THIS BEFORE
  # BELIEVING THE REST. The 89%-of-chains figure at EDGE 140 was measured under
  # the DEEP walk, which is Task 3's code and does not exist yet -- this task
  # still walks every rung from the shallow end. So the figure is NOT direct
  # evidence for what this assertion does here, and treating it as such is the
  # mistake this comment exists to stop.
  #
  # What carries it instead is an ARGUMENT, and it is worth checking rather than
  # trusting: reachability is a property of the CHAIN, not of the direction it
  # is walked. MEASURE_BUDGET (12 here, 16 after Task 3) exceeds the measured
  # 8-to-12-board window between MAX_CLUES and the uniqueness floor, so both
  # walks classify the whole window and find a MEDIUM board on exactly the same
  # chains -- they differ only in WHICH one they hand back. On top of that,
  # `generate` draws a FRESH solution per attempt, so DEFAULT_ATTEMPTS is six
  # independent chains and the miss probability is 0.11^6, about two in a
  # million per seed.
  #
  # The argument is why this assertion survives Task 3 unchanged. The
  # MEASUREMENT under the shipped code lands in Task 3 Step 5, whose script
  # prints a per-rung hit rate and whose output goes into that commit message.
  # Until then, this is reasoning, not data.
  [:easy, :medium].each do |tier|
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
