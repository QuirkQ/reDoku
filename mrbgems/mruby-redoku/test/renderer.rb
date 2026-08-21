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
  assert_nil d.gray_at(right + 1, Redoku::Layout::HEADER_Y) # nothing past it
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
  r.flush_rect(10, 20, 30, 40, waveform: RM2::DU, flags: RM2::FAST_DRAW)
  assert_equal [10, 20, 30, 40, RM2::DU, RM2::FAST_DRAW], d.updates[0]
end

assert('Renderer draws nothing outside the panel') do
  d = TestDisplay.new
  Redoku::Renderer.new(d).draw_all(:hard)
  d.rects.each do |x, y, w, h, _gray|
    assert_true x >= 0 && y >= 0, "rect starts off-panel: #{[x, y, w, h]}"
    assert_true x + w <= Redoku::Layout::SCREEN_W, "rect too wide: #{[x, y, w, h]}"
    assert_true y + h <= Redoku::Layout::SCREEN_H, "rect too tall: #{[x, y, w, h]}"
  end
end
