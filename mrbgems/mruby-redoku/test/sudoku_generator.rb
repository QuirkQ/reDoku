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

assert('Generator.dig leaves a uniquely solvable puzzle inside the band') do
  gen = Redoku::Sudoku::Generator
  s = Redoku::Sudoku::Solver
  solution = gen.full_board(Redoku::Rng.new(5))
  puzzle = gen.dig(solution, :easy, Redoku::Rng.new(5))

  assert_true s.unique?(puzzle)
  # Every remaining clue agrees with the solution it was cut from.
  81.times do |i|
    assert_equal(solution[i], puzzle[i]) if puzzle[i] != 0
  end
  # It removed something, and stopped at the tier's floor.
  clues = 0
  puzzle.each { |d| clues += 1 if d != 0 }
  assert_true clues < 81
  assert_true clues >= Redoku::Sudoku::Generator::CLUE_BAND[:easy][0]
end

assert('Generator.dig removes cells in rotationally symmetric pairs') do
  gen = Redoku::Sudoku::Generator
  solution = gen.full_board(Redoku::Rng.new(8))
  puzzle = gen.dig(solution, :medium, Redoku::Rng.new(8))
  # PLAN.md §7 digs cell PAIRS with rotational symmetry, so a hole at i
  # implies a hole at 80 - i. A rejected pair is restored whole, which is
  # what keeps this true even when uniqueness blocks a removal.
  81.times do |i|
    assert_equal(0, puzzle[80 - i]) if puzzle[i] == 0
  end
end

assert('Generator.dig does not mutate the solution it digs from') do
  gen = Redoku::Sudoku::Generator
  solution = gen.full_board(Redoku::Rng.new(2))
  before = solution.dup
  gen.dig(solution, :hard, Redoku::Rng.new(2))
  assert_equal(before, solution)
end

assert('Generator.generate returns a puzzle, its solution and its tier') do
  gen = Redoku::Sudoku::Generator
  g = Redoku::Sudoku::Grid
  s = Redoku::Sudoku::Solver

  out = gen.generate(:easy, Redoku::Rng.new(3))
  assert_false out.nil?
  assert_true g.complete?(out[:solution])
  assert_true Redoku::Sudoku::Rater::TIERS.include?(out[:tier])

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
  # clue_count agrees with the board it describes, counted independently.
  filled = 0
  puzzle.each { |d| filled += 1 if d != 0 }
  assert_equal(filled, out[:grid].clue_count)
  assert_equal(81, out[:grid].givens_s.size)
end

assert('Generator.generate honours the clue band of the tier it achieved') do
  gen = Redoku::Sudoku::Generator
  # The band belongs to the tier that was ACHIEVED, not the one asked for:
  # generate reports what it actually made, and digging was bounded by the
  # requested tier's floor, so the count is at or above that floor.
  [:easy, :medium, :hard].each_with_index do |tier, n|
    out = gen.generate(tier, Redoku::Rng.new(100 + n))
    assert_true out[:grid].clue_count >= gen::CLUE_BAND[tier][0]
    assert_true out[:grid].clue_count < 81
    assert_true Redoku::Sudoku::Solver.unique?(out[:grid].values)
  end
end

assert('Generator.generate is reproducible from its seed') do
  gen = Redoku::Sudoku::Generator
  a = gen.generate(:medium, Redoku::Rng.new(77))
  b = gen.generate(:medium, Redoku::Rng.new(77))
  assert_equal(a[:grid].givens_s, b[:grid].givens_s)
  assert_equal(a[:solution], b[:solution])
  assert_equal(a[:tier], b[:tier])
end

assert('Generator.generate always returns a playable puzzle, tier or not') do
  gen = Redoku::Sudoku::Generator
  s = Redoku::Sudoku::Solver
  # With a budget of one attempt the generator may fail to hit the requested
  # tier. It must still hand back a real puzzle rather than nil, because the
  # game has a board to draw either way -- reporting the tier it actually
  # achieved is how the caller stays honest instead of relabelling.
  out = gen.generate(:hard, Redoku::Rng.new(4), 1)
  assert_false out.nil?
  assert_true s.unique?(out[:grid].values)
  assert_true Redoku::Sudoku::Rater::TIERS.include?(out[:tier])
end

assert('Generator.target_clues stays inside its tier band') do
  gen = Redoku::Sudoku::Generator
  r = Redoku::Rng.new(21)
  [:easy, :medium, :hard].each do |tier|
    band = gen::CLUE_BAND[tier]
    30.times do
      n = gen.target_clues(tier, r)
      assert_true n >= band[0]
      assert_true n <= band[1]
    end
  end
  # The bands are PLAN.md §7's, and they must not overlap in a way that
  # makes a tier meaningless.
  assert_true gen::CLUE_BAND[:easy][0] > gen::CLUE_BAND[:medium][1]
  assert_true gen::CLUE_BAND[:medium][0] > gen::CLUE_BAND[:hard][0]
end

assert('Generator.closer_tier? measures distance along the tier order') do
  gen = Redoku::Sudoku::Generator
  # The fallback keeps the attempt nearest the requested tier, so a medium
  # result beats a hard one when easy was asked for.
  assert_true gen.closer_tier?(:medium, :easy, :hard)
  assert_false gen.closer_tier?(:hard, :easy, :medium)
  assert_true gen.closer_tier?(:easy, :easy, :hard)
  # Equal distance is not closer: the first attempt kept wins ties.
  assert_false gen.closer_tier?(:hard, :medium, :easy)
end
