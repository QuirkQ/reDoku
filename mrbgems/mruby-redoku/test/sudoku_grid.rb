assert('Grid geometry maps indices to rows, columns and boxes') do
  g = Redoku::Sudoku::Grid
  assert_equal 0, g.row_of(0)
  assert_equal 0, g.col_of(0)
  assert_equal 0, g.box_of(0)
  assert_equal 8, g.row_of(80)
  assert_equal 8, g.col_of(80)
  assert_equal 8, g.box_of(80)
  # Cell 30 is row 3, col 3 -> the centre box, which is box 4.
  assert_equal 3, g.row_of(30)
  assert_equal 3, g.col_of(30)
  assert_equal 4, g.box_of(30)
  # Boxes are numbered row-major over the 3x3 blocks: 0 1 2 / 3 4 5 / 6 7 8.
  assert_equal 2, g.box_of(8)   # row 0, col 8
  assert_equal 1, g.box_of(3)   # row 0, col 3
  assert_equal 3, g.box_of(27)  # row 3, col 0
  assert_equal 8, g.box_of(60)  # row 6, col 6
end

assert('Grid units are 27 nine-cell groups covering every cell three times') do
  g = Redoku::Sudoku::Grid
  assert_equal 9, g::ROWS.size
  assert_equal 9, g::COLS.size
  assert_equal 9, g::BOXES.size
  assert_equal 27, g::UNITS.size
  g::UNITS.each { |u| assert_equal 9, u.size }

  # Each cell appears in exactly three units: its row, its column, its box.
  seen = Array.new(g::CELLS, 0)
  g::UNITS.each { |u| u.each { |i| seen[i] += 1 } }
  assert_true seen.all? { |n| n == 3 }

  # Spot-check the three shapes so a transposed table cannot pass.
  assert_equal [0, 1, 2, 3, 4, 5, 6, 7, 8], g::ROWS[0]
  assert_equal [0, 9, 18, 27, 36, 45, 54, 63, 72], g::COLS[0]
  assert_equal [0, 1, 2, 9, 10, 11, 18, 19, 20], g::BOXES[0]
  assert_equal [30, 31, 32, 39, 40, 41, 48, 49, 50], g::BOXES[4]

  # Every unit really holds nine DISTINCT cells (a builder bug could repeat).
  g::UNITS.each do |u|
    marks = {}
    u.each { |i| marks.store(i, true) }
    assert_equal 9, marks.keys.size
  end
end

assert('Grid peers are the 20 cells a digit conflicts with') do
  g = Redoku::Sudoku::Grid
  assert_equal g::CELLS, g::PEERS.size
  g::PEERS.each { |p| assert_equal 20, p.size }

  # A cell is never its own peer, and peership is symmetric.
  g::CELLS.times { |i| assert_false g::PEERS[i].include?(i) }
  assert_true g::PEERS[0].include?(1)   # same row
  assert_true g::PEERS[0].include?(9)   # same column
  assert_true g::PEERS[0].include?(10)  # same box
  assert_false g::PEERS[0].include?(80) # shares nothing
  assert_true g::PEERS[10].include?(0)  # symmetric

  # Peers are distinct: 8 row + 8 col + 4 box, with no double-counting of
  # the cells its row and box share.
  g::CELLS.times do |i|
    marks = {}
    g::PEERS[i].each { |j| marks.store(j, true) }
    assert_equal 20, marks.keys.size
  end
end

assert('Grid.count_bits and Grid.bits read a candidate mask') do
  g = Redoku::Sudoku::Grid
  assert_equal 0, g.count_bits(0)
  assert_equal 9, g.count_bits(g::ALL)
  assert_equal [1, 2, 3, 4, 5, 6, 7, 8, 9], g.bits(g::ALL)
  assert_equal [], g.bits(0)
  assert_equal 1, g.count_bits(1 << 5)
  assert_equal [5], g.bits(1 << 5)
  assert_equal 2, g.count_bits((1 << 1) | (1 << 9))
  assert_equal [1, 9], g.bits((1 << 1) | (1 << 9))
  # Bit 0 is not a digit and must never be reported.
  assert_equal 0, g.count_bits(1)
  assert_equal [], g.bits(1)
  assert_equal 1022, g::ALL
end

assert('Grid.candidates excludes every peer digit') do
  g = Redoku::Sudoku::Grid
  values = Array.new(g::CELLS, 0)
  assert_equal g::ALL, g.candidates(values, 0)

  values[1] = 3   # same row as cell 0
  values[9] = 4   # same column
  values[10] = 5  # same box
  values[80] = 6  # shares nothing with cell 0
  assert_equal [1, 2, 6, 7, 8, 9], g.bits(g.candidates(values, 0))

  # A filled cell still reports what would be legal there -- the technique
  # solver asks about cells it has not yet skipped -- and cell 40 shares no
  # unit with any of the four cells set above.
  assert_equal g::ALL, g.candidates(values, 40)
end

assert('Grid.consistent? and Grid.complete? judge a values array') do
  g = Redoku::Sudoku::Grid
  solved = solved_values
  # This assertion is load-bearing for Tasks 2-4: it proves SOLVED_81 really
  # is a valid solution. If it fails, the fixture is wrong, not the code.
  assert_true g.consistent?(solved)
  assert_true g.complete?(solved)

  empty = Array.new(g::CELLS, 0)
  assert_true g.consistent?(empty)  # nothing repeats
  assert_false g.complete?(empty)   # but it is not finished

  # A repeat inside a row is caught.
  clash = solved.dup
  clash[0] = clash[1]
  assert_false g.consistent?(clash)
  assert_false g.complete?(clash)

  # So is a repeat inside a column only.
  col_clash = solved.dup
  col_clash[0] = col_clash[9]
  assert_false g.consistent?(col_clash)

  # And one inside a box only. Cells 0 and 10 share box 0 but neither a row
  # nor a column, so this fixture fails only if BOXES is right.
  box_clash = solved.dup
  box_clash[0] = box_clash[10]
  assert_false g.consistent?(box_clash)

  # A board with one hole is consistent but incomplete.
  hole = solved.dup
  hole[40] = 0
  assert_true g.consistent?(hole)
  assert_false g.complete?(hole)
end

assert('Grid keeps givens and entries apart') do
  grid = grid_of(EASY_81)
  assert_false grid.given?(0)  # EASY_81 starts with '.'
  assert_true grid.given?(1)
  assert_equal 0, grid.value_at(0)
  assert_equal 2, grid.value_at(1)
  assert_equal 79, grid.clue_count # 81 cells less the two blanks
  assert_true grid.empty?(0)
  assert_false grid.empty?(1)

  grid.set_entry(0, 7)
  assert_equal 7, grid.value_at(0)
  assert_false grid.given?(0)         # an entry never becomes a given
  assert_false grid.empty?(0)
  assert_equal EASY_81, grid.givens_s # and never touches the givens

  grid.clear_entry(0)
  assert_equal 0, grid.value_at(0)

  # A given is the puzzle, not the player's to edit. Refused loudly, because
  # a silent no-op would hide the caller's bug.
  assert_raise(RuntimeError) { grid.set_entry(1, 5) }
  assert_equal 2, grid.value_at(1)
end

assert('Grid serialises to 81 characters and back') do
  grid = grid_of(EASY_81)
  assert_equal 81, grid.givens_s.size
  assert_equal EASY_81, grid.givens_s
  # values_s is the merged board, so with no entries it equals the givens.
  assert_equal EASY_81, grid.values_s

  grid.set_entry(0, 1)
  assert_equal '1' + EASY_81.slice(1, 80), grid.values_s
  assert_equal EASY_81, grid.givens_s

  # A round trip through parse preserves the givens exactly.
  assert_equal EASY_81, grid_of(grid.givens_s).givens_s

  # '0' is accepted as a blank alongside '.', because a serialised board may
  # come from either convention.
  assert_equal 79, grid_of(EASY_81.gsub('.', '0')).clue_count

  # Solved detection reads the merged board, entries included.
  assert_true grid_of(SOLVED_81).solved?
  assert_false grid_of(EASY_81).solved?

  # A wrong length is refused rather than silently padded.
  assert_raise(RuntimeError) { Redoku::Sudoku::Grid.parse('123') }
end

assert('Grid copies its inputs so a solver buffer cannot alias the board') do
  givens = values_of(EASY_81)
  grid = Redoku::Sudoku::Grid.new(givens)
  givens[0] = 9
  assert_equal 0, grid.value_at(0)

  # And the arrays it hands out are copies too.
  out = grid.values
  out[5] = 0
  assert_equal 6, grid.value_at(5)
  g2 = grid.givens
  g2[5] = 0
  assert_equal 6, grid.value_at(5)
end

assert('Grid entries survive alongside givens when both are supplied') do
  # The restore path (M3 will read this back off disk): givens and entries
  # come from two separate strings and must not be merged into givens.
  givens = values_of(EASY_81)
  entries = Array.new(81, 0)
  entries[0] = 1
  grid = Redoku::Sudoku::Grid.new(givens, entries)
  assert_equal 1, grid.value_at(0)
  assert_false grid.given?(0)
  assert_equal 79, grid.clue_count
  # One hole left (cell 80), so not solved yet -- entries do not flatter it.
  assert_false grid.solved?

  # Fill the last hole with the digit SOLVED_81 has there and it is solved,
  # which is how M3's Check button will know the player finished.
  entries[80] = 2
  full = Redoku::Sudoku::Grid.new(givens, entries)
  assert_true full.solved?
  assert_equal SOLVED_81, full.values_s
end
