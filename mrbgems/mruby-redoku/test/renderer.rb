assert('Renderer#draw_board paints a white board with grid lines') do
  d = TestDisplay.new
  Redoku::Renderer.new(d).draw_board
  # Cell interiors are white; boundaries are black.
  assert_equal 255, d.gray_at(142, 270)  # middle of cell (0,0)... interior
  assert_equal 0, d.gray_at(72 + 140, 300)     # boundary between col 0 and 1
  assert_equal 0, d.gray_at(72 + 3 * 140, 300) # block boundary
  assert_equal 255, d.gray_at(100, 250)        # inside cell (0,0)
end

assert('Renderer#draw_board draws block lines thicker than cell lines') do
  d = TestDisplay.new
  Redoku::Renderer.new(d).draw_board
  cell_x = Redoku::Layout::BOARD_X + Redoku::Layout::CELL       # thin line
  block_x = Redoku::Layout::BOARD_X + 3 * Redoku::Layout::CELL  # thick line
  assert_equal 0, d.gray_at(cell_x, 300)
  assert_equal 255, d.gray_at(cell_x + 1, 300) # 1 px wide: next px is white
  assert_equal 0, d.gray_at(block_x - 2, 300)  # 4 px wide, centred
  assert_equal 0, d.gray_at(block_x + 1, 300)
  assert_equal 255, d.gray_at(block_x + 2, 300)
end

assert('Renderer#draw_board frames every edge of the board') do
  d = TestDisplay.new
  Redoku::Renderer.new(d).draw_board
  x, y, w, h = Redoku::Layout.board_rect
  assert_equal 0, d.gray_at(x, y)                 # top-left corner
  assert_equal 0, d.gray_at(x + w - 1, y)         # top-right
  assert_equal 0, d.gray_at(x, y + h - 1)         # bottom-left
  assert_equal 0, d.gray_at(x + w - 1, y + h - 1) # bottom-right
end

assert('Renderer#draw_buttons frames each button and centres its label') do
  d = TestDisplay.new
  Redoku::Renderer.new(d).draw_buttons
  Redoku::Layout.buttons.each do |_name, x, y, w, h|
    assert_equal 0, d.gray_at(x, y)                 # border, top-left
    assert_equal 0, d.gray_at(x + w - 1, y + h - 1) # border, bottom-right
    assert_equal 255, d.gray_at(x + w / 2, y + 4)   # inside the border: white
  end
  # The NEW label's ink lands inside the New button, not outside it.
  bx, by, bw, bh = Redoku::Layout.button_rect(:new)
  label_w = Redoku::Font.width('NEW', Redoku::Layout::BUTTON_LABEL_SCALE)
  left = bx + (bw - label_w) / 2
  assert_equal 0, d.gray_at(left, by + (bh - Redoku::Font::HEIGHT *
    Redoku::Layout::BUTTON_LABEL_SCALE) / 2)
  assert_true label_w < bw
end

assert('Renderer#draw_header shows the title and the difficulty') do
  d = TestDisplay.new
  Redoku::Renderer.new(d).draw_header(:medium)
  # Title starts at the header origin.
  assert_equal 0, d.gray_at(Redoku::Layout::HEADER_X, Redoku::Layout::HEADER_Y)
  # The difficulty label is right-aligned to the board's right edge.
  right = Redoku::Layout::BOARD_X + Redoku::Layout::BOARD_W
  label_w = Redoku::Font.width('MEDIUM', Redoku::Layout::LABEL_SCALE)
  assert_equal 0, d.gray_at(right - label_w, Redoku::Layout::HEADER_Y)
  # Nothing is painted at or past the board's right edge: the label's last ink
  # is at x 1331 and the header band ends there too, so `right` itself is the
  # tightest untouched column.
  assert_nil d.gray_at(right, Redoku::Layout::HEADER_Y)
end

assert('Renderer#draw_all clears the whole panel first') do
  d = TestDisplay.new
  Redoku::Renderer.new(d).draw_all(:easy)
  first = d.rects[0]
  assert_equal [0, 0, Redoku::Layout::SCREEN_W, Redoku::Layout::SCREEN_H, 255],
               first
end

assert('Renderer flush methods pick the documented waveforms') do
  d = TestDisplay.new
  r = Redoku::Renderer.new(d)
  r.flush_all
  assert_equal [0, 0, Redoku::Layout::SCREEN_W, Redoku::Layout::SCREEN_H,
                RM2::GC16, RM2::SYNC], d.updates[0]
  d.clear_calls
  r.flush_board
  x, y, w, h = Redoku::Layout.board_rect
  assert_equal [x, y, w, h, RM2::GL16, 0], d.updates[0]
  d.clear_calls
  r.flush_header
  # 56 is a literal, not Font::HEIGHT * TITLE_SCALE: recomputing the same
  # expression here would let a bug shared by both copies cancel out.
  assert_equal [Redoku::Layout::HEADER_X, Redoku::Layout::HEADER_Y,
                Redoku::Layout::BOARD_W, 56,
                RM2::GL16, 0], d.updates[0]
  d.clear_calls
  r.flush_rect(10, 20, 30, 40, waveform: RM2::DU, flags: RM2::FAST_DRAW)
  assert_equal [10, 20, 30, 40, RM2::DU, RM2::FAST_DRAW], d.updates[0]
end

assert('Renderer inverts a pressed button and puts it back symmetrically') do
  d = TestDisplay.new
  r = Redoku::Renderer.new(d)
  x, y, w, h = Redoku::Layout.button_rect(:new)
  r.press_button(:new)
  # Inverted: black paper, white border, white label.
  assert_equal 0, d.gray_at(x + 10, y + h / 2)
  assert_equal 255, d.gray_at(x, y)
  # DU + FAST_DRAW, not the GL16 chrome convention: this has to land in a
  # tenth of the time, because for Quit it has to beat the teardown it
  # announces.
  assert_equal [x, y, w, h, RM2::DU, RM2::FAST_DRAW], d.updates[0]

  r.release_button(:new)
  # Back to normal, and in the SAME waveform: a press arriving in a tenth of
  # a second and a release fading back over a GL16's half second would not
  # read as one gesture.
  assert_equal 255, d.gray_at(x + 10, y + h / 2)
  assert_equal 0, d.gray_at(x, y)
  assert_equal d.updates[0], d.updates[1]
  assert_equal 2, d.updates.size
end

assert('Renderer draws nothing outside the panel') do
  d = TestDisplay.new
  Redoku::Renderer.new(d).draw_all(:hard)
  # Guard against a vacuous pass: the loop below proves nothing over an empty
  # list, and the :hard repaint really records 390 rects.
  assert_true d.rects.size > 100, "only #{d.rects.size} rects recorded"
  d.rects.each do |x, y, w, h, _gray|
    assert_true x >= 0 && y >= 0, "rect starts off-panel: #{[x, y, w, h]}"
    assert_true x + w <= Redoku::Layout::SCREEN_W, "rect too wide: #{[x, y, w, h]}"
    assert_true y + h <= Redoku::Layout::SCREEN_H, "rect too tall: #{[x, y, w, h]}"
  end
end

assert('Renderer draws a digit centred in its cell') do
  d = TestDisplay.new
  r = Redoku::Renderer.new(d)
  scale = Redoku::Renderer::DIGIT_SCALE
  r.draw_digit(0, 5, Redoku::Renderer::GIVEN_GRAY)

  x, y, w, h = Redoku::Layout.cell_rect(0, 0)
  gw = Redoku::Font.width('5', scale)
  gh = Redoku::Font::HEIGHT * scale
  # The glyph must fit inside the cell with a visible margin on both axes.
  assert_true gw < w
  assert_true gh < h
  # Every pixel it painted lies inside the centred glyph box.
  assert_true d.painted_within?(x + (w - gw) / 2, y + (h - gh) / 2, gw, gh)
end

assert('Renderer draws a digit into the right cell, not always the first') do
  d = TestDisplay.new
  r = Redoku::Renderer.new(d)
  scale = Redoku::Renderer::DIGIT_SCALE
  # Cell 80 is col 8, row 8 — the opposite corner from cell 0. A draw_digit
  # that ignored its index would paint at cell 0 and fail here.
  r.draw_digit(80, 7, Redoku::Renderer::GIVEN_GRAY)
  x, y, w, h = Redoku::Layout.cell_rect(8, 8)
  gw = Redoku::Font.width('7', scale)
  gh = Redoku::Font::HEIGHT * scale
  assert_true d.painted_within?(x + (w - gw) / 2, y + (h - gh) / 2, gw, gh)
end

assert('Renderer draws a digit using col, not row, off the diagonal') do
  d = TestDisplay.new
  r = Redoku::Renderer.new(d)
  scale = Redoku::Renderer::DIGIT_SCALE
  # Indices 0 and 80 are both on the diagonal, where cell_rect(col, row) and
  # cell_rect(row, col) agree, so a consistent col/row swap inside
  # draw_digit would still pass both cases above. Index 2 is col 2, row 0 —
  # off the diagonal — and this checks against a rect built directly from
  # that (col, row), not derived by converting 2 back through
  # Grid.col_of/row_of the way draw_digit itself does, so a swap in the
  # renderer has nothing matching to cancel against.
  r.draw_digit(2, 3, Redoku::Renderer::GIVEN_GRAY)
  x, y, w, h = Redoku::Layout.cell_rect(2, 0)
  gw = Redoku::Font.width('3', scale)
  gh = Redoku::Font::HEIGHT * scale
  assert_true d.painted_within?(x + (w - gw) / 2, y + (h - gh) / 2, gw, gh)
end

assert('Renderer draws givens darker than entries') do
  assert_equal 0, Redoku::Renderer::GIVEN_GRAY
  assert_true Redoku::Renderer::ENTRY_GRAY > Redoku::Renderer::GIVEN_GRAY
  assert_true Redoku::Renderer::ENTRY_GRAY < Redoku::Renderer::WHITE
end

assert('DIGIT_SCALE puts a spec-sized digit in the cell with clear margin') do
  scale = Redoku::Renderer::DIGIT_SCALE
  height = Redoku::Font::HEIGHT * scale
  # PLAN.md §8 asks for digits at "~96 px". 7 glyph rows at scale 14 is
  # 98 px — the whole scale that lands nearest that target.
  assert_true height >= 90
  assert_true height <= 105
  # It clears the block border on both sides rather than touching it.
  assert_true height + 2 * Redoku::Layout::BLOCK_LINE < Redoku::Layout::CELL
  # A larger scale would still FIT the cell (7*18 = 126 < 140) but would
  # overshoot the spec, so what pins this number is §8, not the geometry.
  assert_true Redoku::Font::HEIGHT * (scale + 2) > 105
end

assert('Renderer draws every filled cell of a puzzle and no empty one') do
  d = TestDisplay.new
  r = Redoku::Renderer.new(d)
  grid = grid_of(EASY_81)
  r.draw_board
  drawn = d.draw_count
  r.draw_puzzle(grid)
  assert_true d.draw_count > drawn
  # EASY_81 is '.23456789...' with blanks at cell 0 and cell 80 only.
  assert_false d.glyph_in_cell?(0)
  assert_true d.glyph_in_cell?(1)
  assert_false d.glyph_in_cell?(80)
  assert_true d.glyph_in_cell?(79)
end

assert('Renderer prints givens in given ink and entries in entry ink') do
  d = TestDisplay.new
  r = Redoku::Renderer.new(d)
  grid = grid_of(EASY_81)
  # Cell 0 is blank in EASY_81, so it can hold a player entry.
  grid.set_entry(0, 1)
  r.draw_puzzle(grid)
  # A given and an entry are both on the board, in two different grays.
  # inked_grays alone only proves both grays appear SOMEWHERE, so it would
  # still pass with the given/entry ternary inverted — the two gray_at
  # checks below pin an exact pixel of each digit to its expected ink.
  assert_true d.inked_grays.include?(Redoku::Renderer::GIVEN_GRAY)
  assert_true d.inked_grays.include?(Redoku::Renderer::ENTRY_GRAY)
  # Cell 0's entry is '1': glyph row 0 is '..#..', so column 2 of its 5-wide,
  # 14x-scaled glyph is lit. The glyph starts at x 107, y 221 (cell_rect(0,0)
  # centred), so (140, 225) sits inside that one lit block.
  assert_equal Redoku::Renderer::ENTRY_GRAY, d.gray_at(140, 225)
  # Cell 1's given is '2': glyph row 0 is '.###.', lit at columns 1-3. The
  # glyph starts at x 247, y 221 (cell_rect(1,0) centred), so (265, 225)
  # sits inside the lit column-1 block.
  assert_equal Redoku::Renderer::GIVEN_GRAY, d.gray_at(265, 225)
end

assert('Renderer draws a splash the font can actually print') do
  d = TestDisplay.new
  r = Redoku::Renderer.new(d)
  text = Redoku::Renderer::SPLASH_TEXT
  # Every character must have a glyph. Font.draw silently draws NOTHING for
  # an unknown character and just advances the cursor, so a lowercase or
  # ellipsis character would render as blank space with no error at all.
  # Checking Renderer::SPLASH_TEXT itself, not a literal copied into this
  # test, is what makes this a real guard: draw_splash has no parameter any
  # more (it draws SPLASH_TEXT and nothing else), but a literal here would
  # still only ever cover itself, not the constant draw_splash actually
  # ships, if the two were ever allowed to drift apart.
  text.each_char { |ch| assert_true !Redoku::Font::GLYPHS[ch].nil? }

  r.draw_splash
  bx, by, bw, bh = Redoku::Layout.board_rect
  sw = Redoku::Font.width(text, Redoku::Renderer::SPLASH_SCALE)
  assert_true sw < bw
  # The splash lands inside the board area, so flush_board covers it.
  assert_true d.painted_within?(bx, by, bw, bh)
end

# draw_header prints `difficulty.to_s.upcase` (renderer.rb) with no glyph
# check of its own — the same Font.draw-silently-draws-nothing hazard
# SPLASH_TEXT is guarded against above, applied here to the tier list
# instead. It costs nothing to check while the font only ever needs to print
# :easy/:medium/:hard, but it stops mattering the moment it is skipped: the
# owner has already decided to go to five tiers, and a name like
# :very_hard would print as "VERY", a silent gap for the underscore, then
# "HARD", with no error anywhere to catch it.
assert('every Rater tier name has a glyph for each of its characters') do
  Redoku::Sudoku::Rater::TIERS.each do |tier|
    label = tier.to_s.upcase
    label.each_char do |ch|
      assert_true !Redoku::Font::GLYPHS[ch].nil?,
                  "no glyph for #{ch.inspect} in tier label #{label.inspect}"
    end
  end
end

# SPLASH_SCALE is not handed to us the way DIGIT_SCALE is — Task 5a chose it,
# so its arithmetic gets its own assertion rather than trust. Picked to match
# Layout::TITLE_SCALE (the header's scale) for visual consistency between the
# two full-board-width texts the renderer prints.
# --- redraw_cell: one cell repainted from the model, which is what erasing
# with the pen's eraser end means (there is no ink buffer to undo; ink goes
# straight into the shared framebuffer, so "erase" is "paint the cell as it
# should look").
#
# An empty Grid, not nil, in the identity tests: the reference board carries
# no digits either, so a grid with any given in the cell under test would make
# the comparison fail for the right reason at the wrong time. nil gets its own
# test below.
def blank_grid
  grid_of('.' * Redoku::Sudoku::Grid::CELLS)
end

assert('Renderer#redraw_cell restores a cell to exactly what draw_board drew') do
  # The tightest statement of correctness available: after a redraw, every
  # pixel of the cell AND of a 4 px margin around it is the colour a freshly
  # drawn board has there. That is what catches the hazard a naive white fill
  # of cell_rect walks into — draw_board centres each line ON its boundary,
  # so a line's band straddles two cells and a full-cell white fill eats the
  # half of it that lies inside this cell, leaving a 140 px gap in a grid line
  # that no assertion about the cell's interior would ever notice.
  #
  # It also catches the opposite mistake: painting the restored line at full
  # weight would put 2 px of new black on the white margin outside the board
  # at cell 0, which the margin in this comparison covers.
  #
  # Cells 0 and 20 between them exercise both kinds of boundary on all four
  # sides: cell 0 has block lines (4 px, offset 2) on its left and top and
  # thin ones (1 px, offset 0) on its right and bottom, and cell 20 (col 2,
  # row 2) has exactly the reverse.
  [0, 20].each do |index|
    ref = TestDisplay.new
    Redoku::Renderer.new(ref).draw_board
    d = TestDisplay.new
    r = Redoku::Renderer.new(d)
    r.draw_board
    r.redraw_cell(index, blank_grid)

    x, y, w, h = Redoku::Layout.cell_rect(Redoku::Sudoku::Grid.col_of(index),
                                          Redoku::Sudoku::Grid.row_of(index))
    pad = Redoku::Layout::BLOCK_LINE
    bad = nil
    py = y - pad
    while bad.nil? && py < y + h + pad
      px = x - pad
      while bad.nil? && px < x + w + pad
        got = d.gray_at(px, py)
        want = ref.gray_at(px, py)
        bad = [px, py, got, want] if got != want
        px += 1
      end
      py += 1
    end
    assert_nil bad, "cell #{index}: [x, y, got, want] = #{bad.inspect}"
  end
end

assert('Renderer#redraw_cell repaints the grid lines it painted over itself') do
  # The identity test above compares against a board draw_board painted, so a
  # redraw_cell that painted NOTHING at all would pass it. These pixels are
  # therefore checked with draw_board's own rects discarded first: black here
  # can only have come from redraw_cell.
  #
  # Bands, per side, from draw_board's `offset = weight / 2`: the cell that
  # STARTS at a boundary keeps `weight - weight / 2` px of it (2 for a block
  # line, 1 for a cell line) and the cell that ENDS there keeps `weight / 2`
  # (2 for a block line, and none at all for a cell line, which sits wholly
  # in the next cell).
  d = TestDisplay.new
  r = Redoku::Renderer.new(d)
  r.draw_board
  d.clear_calls
  r.redraw_cell(0, blank_grid) # block left and top, thin right and bottom
  x, y, w, h = Redoku::Layout.cell_rect(0, 0)
  assert_equal 0, d.gray_at(x, y + h / 2)         # left block band, 2 px...
  assert_equal 0, d.gray_at(x + 1, y + h / 2)
  assert_equal 255, d.gray_at(x + 2, y + h / 2)   # ...and no wider
  assert_equal 0, d.gray_at(x + w / 2, y)         # top block band, 2 px
  assert_equal 0, d.gray_at(x + w / 2, y + 1)
  assert_equal 255, d.gray_at(x + w / 2, y + 2)
  # The thin lines on the far sides live in the NEXT cell, so this cell's own
  # last row and column are interior and must come back white.
  assert_equal 255, d.gray_at(x + w - 1, y + h / 2)
  assert_equal 255, d.gray_at(x + w / 2, y + h - 1)

  d.clear_calls
  r.redraw_cell(20, blank_grid) # thin left and top, block right and bottom
  x, y, w, h = Redoku::Layout.cell_rect(2, 2)
  assert_equal 0, d.gray_at(x, y + h / 2)         # thin left band, 1 px...
  assert_equal 255, d.gray_at(x + 1, y + h / 2)   # ...and no wider
  assert_equal 0, d.gray_at(x + w / 2, y)         # thin top band, 1 px
  assert_equal 255, d.gray_at(x + w / 2, y + 1)
  assert_equal 0, d.gray_at(x + w - 1, y + h / 2) # right block band, 2 px...
  assert_equal 0, d.gray_at(x + w - 2, y + h / 2)
  assert_equal 255, d.gray_at(x + w - 3, y + h / 2) # ...and no wider
  assert_equal 0, d.gray_at(x + w / 2, y + h - 1)   # bottom block band, 2 px
  assert_equal 0, d.gray_at(x + w / 2, y + h - 2)
  assert_equal 255, d.gray_at(x + w / 2, y + h - 3)
end

assert('Renderer#redraw_cell paints nothing outside the cell it was given') do
  # Erasing is a one-cell operation: the flush region App picks is the cell's,
  # so a rect painted outside it would be a pixel changed in the buffer that
  # the panel is never told about — invisible on the device until some later
  # full refresh, and invisible to a host test that only counts updates.
  d = TestDisplay.new
  r = Redoku::Renderer.new(d)
  r.draw_board
  d.clear_calls
  r.redraw_cell(20, blank_grid)
  x, y, w, h = Redoku::Layout.cell_rect(2, 2)
  assert_nil d.gray_at(x - 1, y + h / 2)
  assert_nil d.gray_at(x + w, y + h / 2)
  assert_nil d.gray_at(x + w / 2, y - 1)
  assert_nil d.gray_at(x + w / 2, y + h)
  # ...and every black rect it did paint is inside the cell (painted_within?
  # is an every-ink-rect check, not an any-ink-rect one).
  assert_true d.painted_within?(x, y, w, h)
end

assert('Renderer#redraw_cell puts the model digit back in its own ink') do
  d = TestDisplay.new
  r = Redoku::Renderer.new(d)
  grid = grid_of(EASY_81)
  grid.set_entry(0, 1) # cell 0 is blank in EASY_81, so it can hold an entry
  r.draw_board
  d.clear_calls
  r.redraw_cell(0, grid)
  # The same two pixels the draw_puzzle test pins, for the same reason: cell
  # 0's '1' has glyph row 0 '..#..', so column 2 of its 5-wide, 14x-scaled
  # glyph is lit, and the glyph starts at x 107, y 221.
  assert_equal Redoku::Renderer::ENTRY_GRAY, d.gray_at(140, 225)
  assert_true d.glyph_in_cell?(0)

  d.clear_calls
  r.redraw_cell(1, grid) # cell 1's given is '2'
  assert_equal Redoku::Renderer::GIVEN_GRAY, d.gray_at(265, 225)
  assert_true d.glyph_in_cell?(1)
end

assert('Renderer#redraw_cell draws no digit for an empty cell or no board') do
  d = TestDisplay.new
  r = Redoku::Renderer.new(d)
  grid = grid_of(EASY_81) # cell 80 is blank in EASY_81
  r.draw_board
  d.clear_calls
  r.redraw_cell(80, grid)
  assert_false d.glyph_in_cell?(80)

  # nil is the board that has not been dug yet. An App is constructed without
  # one (generation is a search, so it waits for run or a New press), and the
  # cell still has to come clean — there is simply no digit to put back.
  d.clear_calls
  r.redraw_cell(80, nil)
  assert_false d.glyph_in_cell?(80)
  x, y, w, h = Redoku::Layout.cell_rect(8, 8)
  assert_equal 255, d.gray_at(x + w / 2, y + h / 2)
end

assert('SPLASH_SCALE matches the header scale and fits the board') do
  scale = Redoku::Renderer::SPLASH_SCALE
  assert_equal Redoku::Layout::TITLE_SCALE, scale
  sw = Redoku::Font.width(Redoku::Renderer::SPLASH_TEXT, scale)
  bw = Redoku::Layout::BOARD_W
  # The actual requirement is that the splash fits the board — not a margin
  # fraction of BOARD_W, which is really a fact about TITLE_SCALE (the
  # header's own scale) wearing a splash-shaped disguise: retuning the
  # header to scale 9 would fail a `sw < bw / 2` version of this assertion
  # over a splash-sizing question it has nothing to do with.
  assert_true sw < bw
end
