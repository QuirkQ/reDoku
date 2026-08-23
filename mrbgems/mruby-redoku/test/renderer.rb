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
  assert_true d.inked_grays.include?(Redoku::Renderer::GIVEN_GRAY)
  assert_true d.inked_grays.include?(Redoku::Renderer::ENTRY_GRAY)
end

assert('Renderer draws a splash the font can actually print') do
  d = TestDisplay.new
  r = Redoku::Renderer.new(d)
  text = 'GENERATING...'
  # Every character must have a glyph. Font.draw silently draws NOTHING for
  # an unknown character and just advances the cursor, so a lowercase or
  # ellipsis character would render as blank space with no error at all.
  text.each_char { |ch| assert_true !Redoku::Font::GLYPHS[ch].nil? }

  r.draw_splash(text)
  bx, by, bw, bh = Redoku::Layout.board_rect
  sw = Redoku::Font.width(text, Redoku::Renderer::SPLASH_SCALE)
  assert_true sw < bw
  # The splash lands inside the board area, so flush_board covers it.
  assert_true d.painted_within?(bx, by, bw, bh)
end

# SPLASH_SCALE is not handed to us the way DIGIT_SCALE is — Task 5a chose it,
# so its arithmetic gets its own assertion rather than trust. Picked to match
# Layout::TITLE_SCALE (the header's scale) for visual consistency between the
# two full-board-width texts the renderer prints, and verified here rather
# than assumed: 'GENERATING...' is 13 characters, and this proves it clears
# the board with more than half its width still empty on both sides
# combined, not just barely inside it.
assert('SPLASH_SCALE matches the header scale and leaves a wide margin') do
  scale = Redoku::Renderer::SPLASH_SCALE
  assert_equal Redoku::Layout::TITLE_SCALE, scale
  text = 'GENERATING...'
  sw = Redoku::Font.width(text, scale)
  bw = Redoku::Layout::BOARD_W
  assert_true sw < bw
  assert_true sw < bw / 2
end
