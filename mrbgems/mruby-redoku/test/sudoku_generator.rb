# Two dig-chain seeds chosen for what their FLOOR is, because three assertions
# below are unconditional and would be meaningless otherwise. Mined by a
# throwaway script over seeds 1-60 (see the plan's Task 3 Step 0); rerun it if
# the rater or the dig ever changes, because these are properties of the
# CLASSIFIER, not of the seed. Measured over those 60 seeds: 43 floors solvable,
# 17 rejects, and every one of the 17 rejects had a rescuable neighbourhood.
SOLVED_FLOOR_SEED = 1  # floor_tier: :medium  -- our rules finish this floor
REJECT_FLOOR_SEED = 6  # floor_tier: nil, rescue: :expert -- floor is a reject

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
  # The explicit 6 was DEFAULT_ATTEMPTS when this was written and is now a
  # REAL reduction for :medium, whose shipped cap is 12 (ATTEMPTS). That is
  # deliberate and it is why the number stayed behind after the caps went per
  # tier: a test whose subject is a clue-count guard rail has no reason to pay
  # for a bigger search than it needs, and the guard rail it checks binds on
  # attempt 1 or not at all. Measured after the deep walk landed, both rungs
  # hit on their first attempt anyway (10 draws each, p50 61 ms and 65 ms), so
  # the 6 is slack rather than a constraint.
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
  # WHY MEDIUM IS SAFE TO ASSERT, and it is now MEASURED rather than argued.
  # This comment used to carry an argument in place of data, because the
  # 89%-of-chains figure at EDGE 140 had been measured under the DEEP walk,
  # which did not exist yet. It exists now, MEDIUM walks it, and the deep end
  # of a chain is where MEDIUM lives: measured over 300 fresh chains the hard
  # end is MEDIUM or harder on 292 of them (97%), and over 10 draws at the
  # shipped cap of 12, a MEDIUM request hit on its FIRST attempt every time
  # (p50 65 ms, max 180 ms). The argument still holds and is still worth
  # knowing -- reachability is a property of the CHAIN, not of the direction it
  # is walked, because MEASURE_BUDGET (16) exceeds the measured 8-to-12-board
  # window, so both walks find a MEDIUM board on exactly the same chains and
  # differ only in WHICH one they hand back -- but it is no longer the only
  # thing holding this assertion up.
  #
  # `generate` also draws a FRESH solution per attempt, so a cap of 12 is
  # twelve independent chains and a miss needs all twelve to fail.
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
  # 44-45 clues over 500 measured chains, and never more than MAX_CLUES. 44 or
  # 45 on all 34 chains re-measured for this task; 45 on this seed.
  assert_true easy_clues <= gen::MAX_CLUES
  assert_true easy_clues >= 40

  # The hard end of the same chain is the FLOOR, which is strictly deeper.
  # Measured on this seed: 26 clues against the shallow end's 45.
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
  # (measured floor_tier: :medium).
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
  # (0 class decreases in 527 measured adjacent chain steps agree with it, as
  # do the 11 boards of this seed's own window.) An earlier draft wrote
  # `unless shallower[:tier].nil?` here, which would have let the whole loop
  # skip in silence.
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
  # Mined by Step 0 (measured floor_tier: nil, rescue: :expert -- this one seed
  # is the claim above in miniature: a rejected floor whose neighbourhood holds
  # a rung the chain itself could not reach).
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
