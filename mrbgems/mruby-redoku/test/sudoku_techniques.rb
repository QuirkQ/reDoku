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

# --- The triples, the X-wing and the XY-wing get at least THREE assertions
# each, and the third is the one that earns its keep:
#
#   1. it fires, eliminates exactly the right bits, and leaves the pattern's
#      own cells alone;
#   2. it declines when there is nothing left to eliminate -- that is the
#      termination argument, and a rule reporting progress it did not make
#      makes `solve` loop until MAX_PASSES;
#   3. it declines on a NEAR MISS: a shape a plausibly-wrong version of the
#      rule fires on. Each near-miss below names the specific wrong rule it
#      rules out, because "returns false on something" is not evidence of
#      anything by itself.
#
# The XY-wing gets a fourth: it has two independent ways to be wrong (a pincer
# that does not see the pivot, and two pincers taking the same pivot digit),
# and one near-miss board cannot exhibit both.

assert('naked_triple strips a three-cell triple from the rest of its unit') do
  t = Redoku::Sudoku::Techniques
  cand = Array.new(81, 0)
  # Row 0. Cells 0, 1 and 2 hold {1,2} {2,3} {1,3}: two candidates each, three
  # between them, so the 1, the 2 and the 3 of row 0 all live in those cells.
  # Note that no PAIR inside this is locked -- naked_pair cannot see it, which
  # is the whole reason the rule exists.
  cand[0] = (1 << 1) | (1 << 2)
  cand[1] = (1 << 2) | (1 << 3)
  cand[2] = (1 << 1) | (1 << 3)
  cand[3] = (1 << 1) | (1 << 4)          # so this cell can only be 4
  cand[4] = (1 << 3) | (1 << 5) | (1 << 6)
  cand[5] = (1 << 7) | (1 << 8)          # nothing of the triple's, untouched

  assert_true t.naked_triple(cand)
  assert_equal((1 << 4), cand[3])
  assert_equal((1 << 5) | (1 << 6), cand[4])
  assert_equal((1 << 7) | (1 << 8), cand[5])
  assert_equal((1 << 1) | (1 << 2), cand[0]) # the triple itself is untouched
  assert_equal((1 << 2) | (1 << 3), cand[1])
  assert_equal((1 << 1) | (1 << 3), cand[2])

  assert_false t.naked_triple(cand)
end

assert('naked_triple does not fire when the rest of the unit is already clear') do
  t = Redoku::Sudoku::Techniques
  cand = Array.new(81, 0)
  # A real triple, but the only other cell in the unit offers none of its
  # three digits, so there is nothing to remove.
  cand[0] = (1 << 1) | (1 << 2)
  cand[1] = (1 << 2) | (1 << 3)
  cand[2] = (1 << 1) | (1 << 3)
  cand[3] = (1 << 4) | (1 << 5)
  before = cand.dup

  assert_false t.naked_triple(cand)
  assert_equal(before, cand)
end

assert('naked_triple needs the union to be three digits, not just three cells') do
  t = Redoku::Sudoku::Techniques
  cand = Array.new(81, 0)
  # Cells 0, 1 and 2 have two candidates each -- but {1,2} {3,4} {1,3} unions
  # to FOUR digits, so they own nothing and cell 3 keeps its 1. A version that
  # tests only the members' sizes, or ORs just the first two, strips cell 3
  # down to {5}.
  cand[0] = (1 << 1) | (1 << 2)
  cand[1] = (1 << 3) | (1 << 4)
  cand[2] = (1 << 1) | (1 << 3)
  cand[3] = (1 << 1) | (1 << 5)
  before = cand.dup

  assert_false t.naked_triple(cand)
  assert_equal(before, cand)
end

assert('hidden_triple confines three digits to the three cells that can hold them') do
  t = Redoku::Sudoku::Techniques
  cand = Array.new(81, 0)
  # Row 0. Digit 1 can only be at cell 0 or 1, digit 2 at 0 or 2, digit 3 at
  # 1 or 2 -- three digits with three cells between them. Those cells are
  # therefore full, and the 7, 8 and 9 loitering in them go.
  cand[0] = (1 << 1) | (1 << 2) | (1 << 7)
  cand[1] = (1 << 1) | (1 << 3) | (1 << 8)
  cand[2] = (1 << 2) | (1 << 3) | (1 << 9)
  cand[3] = (1 << 7) | (1 << 8)
  cand[4] = (1 << 7) | (1 << 9)

  assert_true t.hidden_triple(cand)
  assert_equal((1 << 1) | (1 << 2), cand[0])
  assert_equal((1 << 1) | (1 << 3), cand[1])
  assert_equal((1 << 2) | (1 << 3), cand[2])
  assert_equal((1 << 7) | (1 << 8), cand[3]) # the other cells keep their 7s
  assert_equal((1 << 7) | (1 << 9), cand[4])

  assert_false t.hidden_triple(cand)
end

assert('hidden_triple does not fire when the three cells hold nothing extra') do
  t = Redoku::Sudoku::Techniques
  cand = Array.new(81, 0)
  # The same confinement, but the three cells already hold only the three
  # digits, so claiming progress here is what makes the solver spin.
  cand[0] = (1 << 1) | (1 << 2)
  cand[1] = (1 << 1) | (1 << 3)
  cand[2] = (1 << 2) | (1 << 3)
  cand[3] = (1 << 7) | (1 << 8)
  cand[4] = (1 << 7) | (1 << 9)
  before = cand.dup

  assert_false t.hidden_triple(cand)
  assert_equal(before, cand)
end

assert('hidden_triple needs the SAME three cells, not three homes each') do
  t = Redoku::Sudoku::Techniques
  cand = Array.new(81, 0)
  # This is hidden_pair's caught defect one size up, and the reason to spell
  # it out again: three homes each is not the rule, the UNION being three
  # cells is. In row 0 digit 1 lives at cells 0-2, digit 2 at 3-5, digit 3 at
  # 6-8. Each has exactly three homes; together they cover all nine cells and
  # confine nothing. The wrong rule fires and strips cell 0 to {1}.
  cand[0] = (1 << 1) | (1 << 7)
  cand[1] = (1 << 1) | (1 << 8)
  cand[2] = (1 << 1) | (1 << 9)
  cand[3] = (1 << 2) | (1 << 7)
  cand[4] = (1 << 2) | (1 << 8)
  cand[5] = (1 << 2) | (1 << 9)
  cand[6] = (1 << 3) | (1 << 7)
  cand[7] = (1 << 3) | (1 << 8)
  cand[8] = (1 << 3) | (1 << 9)
  before = cand.dup

  assert_false t.hidden_triple(cand)
  assert_equal(before, cand)
end

assert('x_wing clears the digit from both columns of a two-row lock') do
  t = Redoku::Sudoku::Techniques
  cand = Array.new(81, 0)
  b5 = 1 << 5
  # Digit 5 has exactly two homes in row 0 (cols 1 and 7) and exactly two in
  # row 4 (the same cols 1 and 7). One of each row's two must be a 5 and they
  # cannot share a column, so between them they use up both columns: no other
  # cell of column 1 or column 7 can be a 5.
  cand[1]  = b5 | (1 << 1)   # r0c1
  cand[7]  = b5 | (1 << 2)   # r0c7
  cand[37] = b5 | (1 << 3)   # r4c1
  cand[43] = b5 | (1 << 4)   # r4c7
  cand[19] = b5 | (1 << 6)   # r2c1 -- in a locked column, loses the 5
  cand[79] = b5 | (1 << 7)   # r8c7 -- likewise
  # A cell in row 4 but neither column. It must hold no 5, or row 4 would
  # have three homes and there would be no X-wing to find at all.
  cand[40] = (1 << 8) | (1 << 9)

  assert_true t.x_wing(cand)
  assert_equal((1 << 6), cand[19])
  assert_equal((1 << 7), cand[79])
  assert_equal(b5 | (1 << 1), cand[1])   # the four corners keep their 5s
  assert_equal(b5 | (1 << 2), cand[7])
  assert_equal(b5 | (1 << 3), cand[37])
  assert_equal(b5 | (1 << 4), cand[43])
  assert_equal((1 << 8) | (1 << 9), cand[40])

  assert_false t.x_wing(cand)
end

assert('x_wing works transposed: two columns locking two rows') do
  t = Redoku::Sudoku::Techniques
  cand = Array.new(81, 0)
  b4 = 1 << 4
  # The dual, which is a different pattern on the same board and not free:
  # digit 4 has two homes in column 2 (rows 1 and 5) and two in column 6 (the
  # same rows), so it is cleared from the rest of rows 1 and 5. Note the rows
  # themselves have THREE homes each here, so the row-wise scan finds nothing
  # -- only the column-wise scan sees this.
  cand[11] = b4 | (1 << 1)   # r1c2
  cand[15] = b4 | (1 << 3)   # r1c6
  cand[47] = b4 | (1 << 2)   # r5c2
  cand[51] = b4 | (1 << 5)   # r5c6
  cand[17] = b4 | (1 << 6)   # r1c8 -- in a locked row, loses the 4
  cand[45] = b4 | (1 << 7)   # r5c0 -- likewise

  assert_true t.x_wing(cand)
  assert_equal((1 << 6), cand[17])
  assert_equal((1 << 7), cand[45])
  assert_equal(b4 | (1 << 1), cand[11])
  assert_equal(b4 | (1 << 3), cand[15])
  assert_equal(b4 | (1 << 2), cand[47])
  assert_equal(b4 | (1 << 5), cand[51])

  assert_false t.x_wing(cand)
end

assert('x_wing does not fire when the locked columns are already clear') do
  t = Redoku::Sudoku::Techniques
  cand = Array.new(81, 0)
  b5 = 1 << 5
  # A genuine X-wing with no victims: no other cell of column 1 or 7 offers a
  # 5 in the first place.
  cand[1]  = b5 | (1 << 1)
  cand[7]  = b5 | (1 << 2)
  cand[37] = b5 | (1 << 3)
  cand[43] = b5 | (1 << 4)
  cand[19] = (1 << 6) | (1 << 8) # column 1, but holds no 5
  before = cand.dup

  assert_false t.x_wing(cand)
  assert_equal(before, cand)
end

assert('x_wing needs BOTH columns to match, not just one') do
  t = Redoku::Sudoku::Techniques
  cand = Array.new(81, 0)
  b5 = 1 << 5
  # Digit 5 has two homes in row 0 (cols 1 and 7) and two in row 4 (cols 1
  # and 8). They share column 1, and that is not enough: the row-4 five could
  # be at column 8, leaving the row-0 five free to be at column 7 and the
  # column-1 five somewhere else entirely. A version that compares only the
  # first home's column fires here and wrongly takes the 5 from cell 19.
  cand[1]  = b5 | (1 << 1)   # r0c1
  cand[7]  = b5 | (1 << 2)   # r0c7
  cand[37] = b5 | (1 << 3)   # r4c1
  cand[44] = b5 | (1 << 4)   # r4c8, NOT c7
  cand[19] = b5 | (1 << 6)   # r2c1, the cell a wrong rule would strip
  before = cand.dup

  assert_false t.x_wing(cand)
  assert_equal(before, cand)
end

assert('xy_wing clears the shared digit from every cell that sees both pincers') do
  t = Redoku::Sudoku::Techniques
  cand = Array.new(81, 0)
  # The pivot at r0c0 offers {1,2}. Its two pincers each share ONE of those
  # with it and both offer a 3: r0c4 is {1,3} (row peer), r4c0 is {2,3}
  # (column peer). Whichever way the pivot falls, one pincer is forced to the
  # 3 -- pivot 1 forces r0c4, pivot 2 forces r4c0 -- so no cell that sees BOTH
  # pincers can be a 3.
  #
  # Note the pincers do NOT see each other (r0c4 and r4c0 share no unit), and
  # that is not an oversight: the rule never needs them to.
  cand[0]  = (1 << 1) | (1 << 2)   # r0c0, the pivot
  cand[4]  = (1 << 1) | (1 << 3)   # r0c4, pincer taking the 1
  cand[36] = (1 << 2) | (1 << 3)   # r4c0, pincer taking the 2
  # The ONLY cell that sees both pincers: r4c4 is on r0c4's column and on
  # r4c0's row. It loses the 3.
  cand[40] = (1 << 3) | (1 << 5)
  # Two cells that see exactly ONE pincer each. They keep their 3s -- "sees
  # both" is the whole claim, and a rule that strips the peers of either
  # pincer alone takes these too.
  cand[13] = (1 << 3) | (1 << 6)   # r1c4, sees r0c4 only
  cand[45] = (1 << 3) | (1 << 7)   # r5c0, sees r4c0 only

  assert_true t.xy_wing(cand)
  assert_equal((1 << 5), cand[40])
  assert_equal((1 << 3) | (1 << 6), cand[13])
  assert_equal((1 << 3) | (1 << 7), cand[45])
  # The pattern's own three cells are untouched. The pivot cannot hold the 3
  # in the first place -- C differs from both of the pivot's digits by
  # construction -- and neither pincer sees itself.
  assert_equal((1 << 1) | (1 << 2), cand[0])
  assert_equal((1 << 1) | (1 << 3), cand[4])
  assert_equal((1 << 2) | (1 << 3), cand[36])

  # Nothing left to do the second time. Same termination argument as every
  # other eliminator: claiming progress it did not make is what makes `solve`
  # spin to MAX_PASSES.
  assert_false t.xy_wing(cand)
end

assert('xy_wing does not fire when nothing seeing both pincers holds the digit') do
  t = Redoku::Sudoku::Techniques
  cand = Array.new(81, 0)
  # A genuine XY-wing with no victim: r4c4 is still the only cell seeing both
  # pincers, and it offers no 3.
  cand[0]  = (1 << 1) | (1 << 2)
  cand[4]  = (1 << 1) | (1 << 3)
  cand[36] = (1 << 2) | (1 << 3)
  cand[40] = (1 << 5) | (1 << 6)
  cand[13] = (1 << 3) | (1 << 6)
  cand[45] = (1 << 3) | (1 << 7)
  before = cand.dup

  assert_false t.xy_wing(cand)
  assert_equal(before, cand)
end

assert('xy_wing needs the pincers to take DIFFERENT digits from the pivot') do
  t = Redoku::Sudoku::Techniques
  cand = Array.new(81, 0)
  # Both pincers are {1,3}, so both share the SAME pivot digit. Then pivot 2
  # forces neither of them and the 3 is not pinned anywhere: nothing may be
  # eliminated. A version that only checks "two bi-value peers of the pivot
  # sharing one candidate with it and one with each other" fires here and
  # strips the 3 from r4c4.
  cand[0]  = (1 << 1) | (1 << 2)   # pivot {1,2}
  cand[4]  = (1 << 1) | (1 << 3)   # shares the 1
  cand[36] = (1 << 1) | (1 << 3)   # shares the 1 as well -- not a wing
  cand[40] = (1 << 3) | (1 << 5)   # what the wrong rule would strip
  before = cand.dup

  assert_false t.xy_wing(cand)
  assert_equal(before, cand)
end

assert('xy_wing needs both pincers to SEE the pivot') do
  t = Redoku::Sudoku::Techniques
  cand = Array.new(81, 0)
  # r0c4 is {1,3} and r8c8 is {2,3}: between them they look exactly like a
  # wing around the {1,2} at r0c0 -- except r8c8 shares no unit with it, so
  # the pivot cannot force it and the deduction does not exist. A version
  # that scans every bi-value cell instead of walking the pivot's PEERS fires
  # here and strips the 3 from r0c8, which sees both.
  cand[0]  = (1 << 1) | (1 << 2)
  cand[4]  = (1 << 1) | (1 << 3)
  cand[80] = (1 << 2) | (1 << 3)   # r8c8: no row, column or box with r0c0
  cand[8]  = (1 << 3) | (1 << 6)   # r0c8, what the wrong rule would strip
  before = cand.dup

  assert_false t.xy_wing(cand)
  assert_equal(before, cand)
end

assert('a real board that needs the XY-wing is finished only with it') do
  t = Redoku::Sudoku::Techniques
  # The candidate-grid tests above prove the RULE. This proves it is REACHABLE
  # through `solve` on a board a player could be handed, and that the board
  # genuinely turns on it: hand `solve` every rule except this one and it
  # stalls. Without that second assertion the first proves only that the
  # repertoire finishes the board, which pointing might have done.
  board = values_of(XY_WING_81)
  without = []
  t::ORDER.each { |name| without << name unless name == :xy_wing }
  assert_false t.solves?(board, without)
  assert_true t.solves?(board, t::ORDER)

  # And the rule really is what fired -- once, on top of singles alone. This
  # board needs no pointing, no pair and no X-wing, so nothing else can be
  # credited with the work.
  result = t.solve(board)
  assert_true result[:solved]
  assert_equal(:xy_wing, result[:hardest])
  assert_equal(1, result[:counts][:xy_wing])
  assert_false result[:counts].has_key?(:pointing)
  assert_false result[:counts].has_key?(:naked_pair)
  assert_false result[:counts].has_key?(:x_wing)
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

assert('Techniques.solve counts how often each rule was needed') do
  t = Redoku::Sudoku::Techniques
  # `hardest` says which rule was the worst; `counts` says how much work the
  # board took. Rating needs both: one pointing pair and nine of them are not
  # the same puzzle, and `hardest` calls them both :pointing.

  # A singles-only board writes one digit per hole and eliminates nothing, so
  # the counts must add up to exactly the number of holes. The hole count is
  # derived from the board rather than written in by hand, so this does not
  # depend on a fixture's arithmetic being restated correctly in a comment.
  values = values_of(EASY_81)
  holes = 0
  values.each { |d| holes += 1 if d == 0 }
  assert_true holes > 0 # premise: a board with no holes would pass trivially

  result = t.solve(values)
  assert_true result[:solved]
  total = 0
  result[:counts].each_value { |n| total += n }
  assert_equal(holes, total)

  # A rule that never fired is ABSENT, not zero. Callers weight the keys they
  # find, so "never looked for" must not read as "used 0 times" -- that is the
  # difference between a rule being unnecessary and a rule being unimplemented.
  assert_false result[:counts].has_key?(:pointing)
  assert_false result[:counts].has_key?(:naked_pair)
  assert_false result[:counts].has_key?(:naked_triple)
  assert_false result[:counts].has_key?(:hidden_pair)
  assert_false result[:counts].has_key?(:hidden_triple)
  assert_false result[:counts].has_key?(:x_wing)
  assert_false result[:counts].has_key?(:xy_wing)

  # Six holes, same accounting.
  six = t.solve(values_of(UNIQUE_81))
  filled = 0
  six[:counts].each_value { |n| filled += n }
  assert_equal(6, filled)

  # A board that needed nothing gets an empty log, not a nil one, so a caller
  # can sum it without checking.
  done = t.solve(solved_values)
  assert_equal({}, done[:counts])
  assert_nil done[:hardest]

  # A stalled board logs the work it DID manage before giving up, which is
  # what lets a rater tell "stalled immediately" from "stalled at the end".
  stalled = t.solve(values_of(MULTI_81))
  assert_false stalled[:solved]
  assert_false stalled[:counts].nil?
end

assert('Techniques.place keeps hard-won eliminations across a write') do
  t = Redoku::Sudoku::Techniques
  # This is the whole reason the candidate grid is maintained incrementally
  # rather than rebuilt: an elimination a rule paid for must survive the next
  # digit being written. Rebuilding from the board would hand the 8 back to
  # cell 60 here, and the pointing pair that removed it would have to be
  # found all over again.
  work = Array.new(81, 0)
  cand = t.candidate_grid(work)
  cand[60] &= ~(1 << 8) # as if an eliminator had ruled the 8 out
  t.place(work, cand, 0, 3)

  assert_equal(3, work[0])
  assert_equal(0, cand[0])                # the written cell holds nothing more
  assert_equal(0, cand[1] & (1 << 3))     # a peer loses the digit
  assert_equal(0, cand[9] & (1 << 3))     # column peer too
  assert_equal(0, cand[10] & (1 << 3))    # box peer too
  assert_equal(0, cand[60] & (1 << 8))    # AND the earlier elimination stands
  # A cell sharing no unit with cell 0 keeps the digit.
  assert_true (cand[80] & (1 << 3)) != 0
end

assert('Techniques.place is sound on a peer that is already filled') do
  t = Redoku::Sudoku::Techniques
  # A filled peer has a zero mask, so stripping a bit from it must be a
  # no-op rather than something that needs guarding against.
  work = Array.new(81, 0)
  cand = t.candidate_grid(work)
  t.place(work, cand, 1, 3)
  assert_equal(0, cand[1])
  t.place(work, cand, 0, 5) # cell 1 is a peer of cell 0 and already filled
  assert_equal(0, cand[1])
  assert_equal(3, work[1])  # and its digit is untouched
end

assert('Techniques.tally accumulates rather than overwrites') do
  t = Redoku::Sudoku::Techniques
  counts = {}
  t.tally(counts, :pointing)
  assert_equal(1, counts[:pointing])
  t.tally(counts, :pointing)
  t.tally(counts, :pointing)
  assert_equal(3, counts[:pointing])
  # A second rule does not disturb the first.
  t.tally(counts, :naked_pair)
  assert_equal(3, counts[:pointing])
  assert_equal(1, counts[:naked_pair])
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
  assert_equal([:naked_single, :hidden_single, :pointing, :naked_pair,
                :naked_triple, :hidden_pair, :hidden_triple, :x_wing,
                :xy_wing],
               t::ORDER)
  # nil is cheaper than every real technique, so "nothing needed yet" never
  # beats a rule that was actually used.
  assert_true t.rank(:naked_single) > t.rank(nil)
  # The singles are cheaper than anything that only eliminates.
  assert_true t.rank(:pointing) > t.rank(:hidden_single)
  # Locked candidates is the CHEAPEST eliminator, not the dearest: Sudoku
  # Explainer scores pointing 2.6 against naked pair 3.0, and HoDoKu 50
  # against 60. This assertion is the one that fails if someone puts
  # :pointing back at the end of ORDER, where it used to be.
  assert_true t.rank(:naked_pair) > t.rank(:pointing)
  # Each rule is dearer than the smaller version of itself, and the X-wing --
  # the only rule that reasons across two units -- is dearest of all.
  assert_true t.rank(:naked_triple) > t.rank(:naked_pair)
  assert_true t.rank(:hidden_triple) > t.rank(:hidden_pair)
  assert_true t.rank(:x_wing) > t.rank(:hidden_triple)
  # And the XY-wing is dearer still: it is the only rule here that chains two
  # deductions through a third cell, and both published graders rank it above
  # the X-wing (HoDoKu 160 against 140, Sudoku Explainer 4.2 against 3.2).
  assert_true t.rank(:xy_wing) > t.rank(:x_wing)
  # harder picks the more expensive of two, in either argument order.
  assert_equal(:x_wing, t.harder(:naked_single, :x_wing))
  assert_equal(:x_wing, t.harder(:x_wing, :naked_single))
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
  # MULTI_81 has three givens: nothing our nine rules know can force a cell.
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
