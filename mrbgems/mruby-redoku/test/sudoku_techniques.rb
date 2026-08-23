assert('naked_pair strips a locked pair from the rest of its unit') do
  t = Redoku::Sudoku::Techniques
  # The elimination rules work purely on a candidate grid, so they can be
  # tested on one built by hand -- no board needed, and no arithmetic about
  # what some fixture's candidates happen to be.
  cand = Array.new(81, 0)
  p12 = (1 << 1) | (1 << 2)
  cand[0] = p12                 # row 0: locked pair {1,2}
  cand[1] = p12
  cand[2] = p12 | (1 << 3)      # so this cell can only be 3
  cand[3] = (1 << 1) | (1 << 4)

  assert_true t.naked_pair(cand)
  assert_equal((1 << 3), cand[2])
  assert_equal((1 << 4), cand[3])
  assert_equal(p12, cand[0])    # the pair itself is untouched
  assert_equal(p12, cand[1])

  # Nothing left to do the second time: a rule that keeps reporting progress
  # without changing anything is what makes the solver loop for ever.
  assert_false t.naked_pair(cand)
end

assert('naked_pair ignores a pair that shares no unit') do
  t = Redoku::Sudoku::Techniques
  cand = Array.new(81, 0)
  p12 = (1 << 1) | (1 << 2)
  cand[0] = p12
  cand[80] = p12                # opposite corners share no row, col or box
  cand[40] = p12 | (1 << 3)
  assert_false t.naked_pair(cand)
  assert_equal(p12 | (1 << 3), cand[40])
end

assert('hidden_pair confines two digits to the two cells that can hold them') do
  t = Redoku::Sudoku::Techniques
  cand = Array.new(81, 0)
  # In row 0, digits 1 and 2 can only live in cells 0 and 1. Those cells
  # therefore hold nothing else, so the 3 and the 4 go.
  cand[0] = (1 << 1) | (1 << 2) | (1 << 3)
  cand[1] = (1 << 1) | (1 << 2) | (1 << 4)
  cand[2] = (1 << 3) | (1 << 4)

  assert_true t.hidden_pair(cand)
  assert_equal((1 << 1) | (1 << 2), cand[0])
  assert_equal((1 << 1) | (1 << 2), cand[1])
  assert_equal((1 << 3) | (1 << 4), cand[2]) # untouched
  assert_false t.hidden_pair(cand)
end

assert('hidden_pair does not fire when the two cells hold nothing extra') do
  t = Redoku::Sudoku::Techniques
  cand = Array.new(81, 0)
  # Same shape, but the two cells already hold only the pair, so there is
  # nothing to eliminate and claiming progress would loop for ever.
  cand[0] = (1 << 1) | (1 << 2)
  cand[1] = (1 << 1) | (1 << 2)
  cand[2] = (1 << 3) | (1 << 4)
  assert_false t.hidden_pair(cand)
end

assert('pointing strips a box-locked digit from the rest of its line') do
  t = Redoku::Sudoku::Techniques
  cand = Array.new(81, 0)
  b5 = 1 << 5
  # Inside box 0, digit 5 can only be in cells 0 and 1 -- both in row 0. So
  # the 5 of row 0 lives inside box 0, and cannot be at cell 3 (row 0,
  # box 1).
  cand[0] = b5 | (1 << 1)
  cand[1] = b5 | (1 << 2)
  cand[3] = b5 | (1 << 6)
  cand[4] = (1 << 6) | (1 << 7)

  assert_true t.pointing(cand)
  assert_equal((1 << 6), cand[3])
  assert_equal(b5 | (1 << 1), cand[0]) # the box's own cells keep the 5
  assert_false t.pointing(cand)
end

assert('pointing does not fire when the box homes straddle two lines') do
  t = Redoku::Sudoku::Techniques
  cand = Array.new(81, 0)
  b5 = 1 << 5
  # Cells 0 (row 0, col 0) and 10 (row 1, col 1) are both in box 0 but share
  # neither a row nor a column, so the digit is pinned to no line at all.
  cand[0] = b5 | (1 << 1)
  cand[10] = b5 | (1 << 2)
  cand[3] = b5 | (1 << 6)
  assert_false t.pointing(cand)
  assert_equal(b5 | (1 << 6), cand[3])
end

assert('Techniques.solve finishes a singles-only board and says so') do
  t = Redoku::Sudoku::Techniques
  g = Redoku::Sudoku::Grid
  result = t.solve(values_of(EASY_81))
  assert_true result[:solved]
  assert_true g.complete?(result[:values])
  assert_equal(solved_values, result[:values])
  # Both holes are forced by their own row, so singles are all it took.
  assert_true [:naked_single, :hidden_single].include?(result[:hardest])
end

assert('Techniques.solve reports nil hardest for an already-solved board') do
  result = Redoku::Sudoku::Techniques.solve(solved_values)
  assert_true result[:solved]
  assert_nil result[:hardest]
end

assert('Techniques.solve handles a six-hole board') do
  result = Redoku::Sudoku::Techniques.solve(values_of(UNIQUE_81))
  assert_true result[:solved]
  assert_equal(solved_values, result[:values])
end

assert('Techniques.solve stalls rather than guessing') do
  t = Redoku::Sudoku::Techniques
  g = Redoku::Sudoku::Grid
  # MULTI_81 has three givens on an empty board: it has many solutions, so
  # NO technique can force any cell. The solver must stop and say so, not
  # search. If this hangs rather than fails, a rule is reporting progress
  # without changing anything.
  result = t.solve(values_of(MULTI_81))
  assert_false result[:solved]
  # And it must not have invented anything on the way out.
  assert_true g.consistent?(result[:values])
  assert_equal(1, result[:values][0])
  assert_equal(5, result[:values][40])
  assert_equal(9, result[:values][80])
end

assert('Techniques.solve does not mutate its input') do
  before = values_of(EASY_81)
  copy = before.dup
  Redoku::Sudoku::Techniques.solve(before)
  assert_equal(copy, before)
end

assert('Techniques.solve never writes a digit that contradicts the solution') do
  t = Redoku::Sudoku::Techniques
  g = Redoku::Sudoku::Grid
  # A scattering of holes, so the techniques may or may not finish. Whatever
  # they do write must agree with the one true solution -- a solver that
  # guessed would report "solved" and fail this.
  values = solved_values
  [0, 4, 8, 30, 40, 50, 72, 76, 80].each { |i| values[i] = 0 }
  result = t.solve(values)
  assert_true g.consistent?(result[:values])
  solution = solved_values
  81.times do |i|
    v = result[:values][i]
    assert_equal(solution[i], v) if v != 0
  end
end

assert('Techniques rank orders the rules cheapest first') do
  t = Redoku::Sudoku::Techniques
  assert_equal([:naked_single, :hidden_single, :naked_pair, :hidden_pair,
                :pointing], t::ORDER)
  # nil is cheaper than every real technique, so "nothing needed yet" never
  # beats a rule that was actually used.
  assert_true t.rank(:naked_single) > t.rank(nil)
  assert_true t.rank(:pointing) > t.rank(:naked_pair)
  assert_true t.rank(:naked_pair) > t.rank(:hidden_single)
  # harder picks the more expensive of two, in either argument order.
  assert_equal(:pointing, t.harder(:naked_single, :pointing))
  assert_equal(:pointing, t.harder(:pointing, :naked_single))
  assert_equal(:naked_single, t.harder(nil, :naked_single))
  assert_nil t.harder(nil, nil)
end

assert('Techniques.solve terminates on every board it is given') do
  t = Redoku::Sudoku::Techniques
  # The termination argument is that every rule either writes a digit (at
  # most 81 times) or shrinks a candidate mask (at most 729 bits), so the
  # loop is bounded. Exercise it over a spread of boards, including ones
  # built to stall, and rely on `make test` completing at all.
  [SOLVED_81, EASY_81, UNIQUE_81, MULTI_81].each do |board|
    result = t.solve(values_of(board))
    assert_false result.nil?
    assert_equal(81, result[:values].size)
  end
  # A wholly empty board is the worst case for stalling.
  empty = t.solve(Array.new(81, 0))
  assert_false empty[:solved]
  # An inconsistent board must not hang either.
  bad = values_of(EASY_81)
  bad[0] = 2
  assert_false t.solve(bad).nil?
end

# --- The three assertions below exist because MUTATION TESTING found the
# tests above could not tell correct code from broken code here. Two
# deliberate defects survived the whole suite: dropping the `!many` guard in
# find_hidden_single, and matching hidden_pair on "both digits have two
# homes" instead of "both digits have the SAME two homes". Both are caught
# now, and each of these tests fails against its own specific defect.
#
# The reason they escaped is worth keeping: every board fixture in this file
# has holes that are forced, so naked_single always fires first and
# find_hidden_single is never reached at all. Testing the rules directly on a
# hand-built candidate grid is the only way to reach them.

assert('find_hidden_single ignores a digit with more than one home') do
  t = Redoku::Sudoku::Techniques
  cand = Array.new(81, 0)
  # Row 0. Digit 1 can go in two places, so it is NOT a hidden single;
  # digit 7 can only go in cell 5, so it is. A version that forgets to check
  # for a second home returns the digit-1 cell instead.
  cand[0] = (1 << 1) | (1 << 2)
  cand[1] = (1 << 1) | (1 << 2)
  cand[5] = (1 << 7) | (1 << 2)

  spot = t.find_hidden_single(cand)
  assert_false spot.nil?
  assert_equal(5, spot[0])
  assert_equal(7, spot[1])
end

assert('find_hidden_single answers nil when no digit is pinned anywhere') do
  t = Redoku::Sudoku::Techniques
  # EVERY cell offers the same two digits, so in every one of the 27 units
  # each of those digits has nine homes and the other seven have none:
  # nothing is forced anywhere and the rule must decline. Returning a cell
  # here is how a solver starts guessing.
  #
  # The grid is uniform on purpose. A sparse hand-built grid does not work
  # for a "nil everywhere" assertion, and getting that wrong is instructive:
  # a mask of 0 means FILLED, so setting only cells 0 and 1 leaves cell 0 as
  # the single unfilled cell of column 0 -- which makes its digits genuine
  # hidden singles in that column, exactly as the code said.
  cand = Array.new(81, (1 << 1) | (1 << 2))
  assert_nil t.find_hidden_single(cand)
end

assert('hidden_pair needs the SAME two homes, not merely two homes each') do
  t = Redoku::Sudoku::Techniques
  cand = Array.new(81, 0)
  # In row 0: digit 1 lives in cells 0 or 1, digit 2 in cells 2 or 3. Each
  # digit has exactly two homes, but they are different homes, so this is no
  # hidden pair and nothing may be eliminated. The wrong rule fires here and
  # would wrongly strip cell 0 down to {1}.
  cand[0] = (1 << 1) | (1 << 3)
  cand[1] = (1 << 1) | (1 << 4)
  cand[2] = (1 << 2) | (1 << 3)
  cand[3] = (1 << 2) | (1 << 4)
  before = cand.dup

  assert_false t.hidden_pair(cand)
  assert_equal(before, cand) # and it changed nothing on its way to saying no
end

assert('find_naked_single finds a one-candidate cell and nothing less') do
  t = Redoku::Sudoku::Techniques
  cand = Array.new(81, 0)
  cand[0] = (1 << 1) | (1 << 2)
  cand[7] = (1 << 4)          # the only forced cell
  assert_equal(7, t.find_naked_single(cand))

  # A zero mask is a contradiction, not a single: count_bits is 0, and
  # writing "the one candidate" of an impossible cell would raise.
  none = Array.new(81, 0)
  none[3] = 0
  assert_nil t.find_naked_single(none)
end
