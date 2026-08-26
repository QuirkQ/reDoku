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

assert('Grid.index_of inverts col_of and row_of for every cell') do
  g = Redoku::Sudoku::Grid
  # The inverse exists because the input path needs it: Layout.cell_at answers
  # a (col, row) and the renderer and the Grid both want a flat index, so
  # without this the conversion would be an open-coded `row * 9 + col` sitting
  # in app.rb — a second copy of Grid's indexing rule, in a file that has no
  # other business knowing it.
  assert_equal 0, g.index_of(0, 0)
  assert_equal 80, g.index_of(8, 8)
  # Off the diagonal, where a col/row swap would otherwise cancel out: cell 2
  # is col 2, row 0, and cell 18 is col 0, row 2.
  assert_equal 2, g.index_of(2, 0)
  assert_equal 18, g.index_of(0, 2)
  g::CELLS.times do |i|
    assert_equal i, g.index_of(g.col_of(i), g.row_of(i))
  end
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

assert('an unreadable cell reads as empty to the engine') do
  g = Redoku::Sudoku::Grid.parse('.' * 81)
  g.set_unreadable(0)
  assert_true g.unreadable?(0)
  assert_equal 0, g.value_at(0)      # not -1: the sentinel never escapes
  assert_true g.empty?(0)
  assert_equal 0, g.values[0]
  assert_equal '.', g.values_s[0]    # the engine's view is unchanged
end

assert('an unreadable cell persists as ? and nothing else does') do
  g = Redoku::Sudoku::Grid.parse('.' * 81)
  g.set_unreadable(3)
  g.set_entry(4, 7)
  assert_equal '?', g.entries_s[3]
  assert_equal '7', g.entries_s[4]
  assert_equal '.', g.entries_s[5]
  # givens_s and values_s can never carry the sentinel, because value_at
  # filters it and @givens never holds it.
  assert_false g.givens_s.include?('?')
  assert_false g.values_s.include?('?')
end

assert('an unreadable cell cannot produce a false win') do
  # THE property this state exists to protect, and the reason the sentinel
  # filter in value_at must not be "simplified" away. Fill a solved board,
  # then make one cell unreadable: complete? already returns false because
  # value_at reads 0 there, so solved? is false with no extra guard.
  solved = solved_values                        # test/_support.rb
  g = Redoku::Sudoku::Grid.new(Array.new(81, 0), solved.dup)
  assert_true g.solved?
  g.set_unreadable(40)
  assert_false g.solved?
end

assert('writing a digit over an unreadable cell clears the sentinel') do
  g = Redoku::Sudoku::Grid.parse('.' * 81)
  g.set_unreadable(9)
  g.set_entry(9, 5)
  assert_false g.unreadable?(9)
  assert_equal 5, g.value_at(9)
end

assert('clear_entry clears an unreadable cell too') do
  g = Redoku::Sudoku::Grid.parse('.' * 81)
  g.set_unreadable(9)
  g.clear_entry(9)
  assert_false g.unreadable?(9)
  assert_equal '.', g.entries_s[9]
end

assert('set_unreadable refuses a given, exactly as set_entry does') do
  g = Redoku::Sudoku::Grid.parse('5' + '.' * 80)
  begin
    g.set_unreadable(0)
    assert_true false, 'expected a raise'
  rescue RuntimeError => e
    assert_true e.message.include?('given')
  end
end

assert('a Grid round-trips an unreadable cell through its strings') do
  g = Redoku::Sudoku::Grid.parse('.' * 81)
  g.set_unreadable(11)
  back = Redoku::Sudoku::Grid.new(Array.new(81, 0),
                                  values_of_entries(g.entries_s))
  assert_true back.unreadable?(11)
end
