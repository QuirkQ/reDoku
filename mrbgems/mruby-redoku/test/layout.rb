assert('Layout board geometry matches the design') do
  assert_equal [72, 200, 1260, 1260], Redoku::Layout.board_rect
  # The board is horizontally centred on the 1404 px panel.
  assert_equal 1404 - (72 + 1260), Redoku::Layout::BOARD_X
  assert_equal 1260, Redoku::Layout::BOARD_W
end

assert('Layout.cell_rect places each of the 81 cells') do
  assert_equal [72, 200, 140, 140], Redoku::Layout.cell_rect(0, 0)
  assert_equal [212, 200, 140, 140], Redoku::Layout.cell_rect(1, 0)
  assert_equal [72, 340, 140, 140], Redoku::Layout.cell_rect(0, 1)
  assert_equal [1192, 1320, 140, 140], Redoku::Layout.cell_rect(8, 8)
  assert_raise(ArgumentError) { Redoku::Layout.cell_rect(9, 0) }
  assert_raise(ArgumentError) { Redoku::Layout.cell_rect(0, -1) }
end

assert('Layout.cell_at maps screen points back to cells') do
  assert_equal [0, 0], Redoku::Layout.cell_at(72, 200)      # top-left corner
  assert_equal [0, 0], Redoku::Layout.cell_at(211, 339)     # last px of (0,0)
  assert_equal [1, 0], Redoku::Layout.cell_at(212, 200)     # first px of (1,0)
  assert_equal [8, 8], Redoku::Layout.cell_at(1331, 1459)   # last px of board
  assert_nil Redoku::Layout.cell_at(71, 200)                # left of the board
  assert_nil Redoku::Layout.cell_at(72, 199)                # above the board
  assert_nil Redoku::Layout.cell_at(1332, 200)              # right of the board
  assert_nil Redoku::Layout.cell_at(72, 1460)               # below the board
end

assert('Layout buttons put Quit at the far end of its row') do
  assert_equal [:new, :level, :games, :quit],
               Redoku::Layout.buttons.map { |b| b[0] }
  assert_equal [72, 1540, 400, 140], Redoku::Layout.button_rect(:new)
  assert_equal [502, 1540, 400, 140], Redoku::Layout.button_rect(:level)
  assert_equal [72, 1700, 400, 140], Redoku::Layout.button_rect(:games)
  assert_equal [932, 1700, 400, 140], Redoku::Layout.button_rect(:quit)
  # Everything stays on the panel and inside the board's columns.
  Redoku::Layout.buttons.each do |_name, x, y, w, h|
    assert_true x >= Redoku::Layout::BOARD_X
    assert_true x + w <= Redoku::Layout::BOARD_X + Redoku::Layout::BOARD_W
    assert_true y + h <= Redoku::Layout::SCREEN_H
    assert_true y >= Redoku::Layout::BOARD_Y + Redoku::Layout::BOARD_W
  end
  # The destructive button keeps two full widths of travel between it and
  # anything else on its row — Games sits left, a dead gap between them.
  assert_true Redoku::Layout.button_rect(:games)[0] +
              Redoku::Layout.button_rect(:games)[2] <
              Redoku::Layout.button_rect(:quit)[0]
  assert_nil Redoku::Layout.button_rect(:check) # not part of M1
end

assert('Layout.button_at hit-tests the button row') do
  assert_equal :new, Redoku::Layout.button_at(72, 1540)
  assert_equal :new, Redoku::Layout.button_at(471, 1679)
  assert_equal :level, Redoku::Layout.button_at(502, 1600)
  assert_equal :games, Redoku::Layout.button_at(72, 1700)
  assert_equal :quit, Redoku::Layout.button_at(1000, 1750)
  assert_nil Redoku::Layout.button_at(472, 1600)  # gap between New and Level
  assert_nil Redoku::Layout.button_at(500, 1750)  # gap between Games and Quit
  assert_nil Redoku::Layout.button_at(700, 800)   # middle of the board
end

assert('Layout menu buttons sit at the far end of the header band') do
  assert_equal [992, 60, 150, 56], Redoku::Layout.menu_button_rect(:prev)
  assert_equal [1162, 60, 150, 56], Redoku::Layout.menu_button_rect(:next)
  assert_equal :prev, Redoku::Layout.menu_button_at(992, 60)
  assert_equal :next, Redoku::Layout.menu_button_at(1162, 115)
  assert_nil Redoku::Layout.menu_button_at(991, 60)   # one px left of PREV
  assert_nil Redoku::Layout.menu_button_at(1162, 116) # one px below NEXT
  # Clear of the GAMES title (scale-8 'GAMES' is 232 px wide from HEADER_X)
  # and inside the board's columns like every chrome button.
  assert_true Redoku::Layout::MENU_PREV_X > Redoku::Layout::HEADER_X + 232
  assert_true Redoku::Layout::MENU_NEXT_X + Redoku::Layout::MENU_BTN_W <=
              Redoku::Layout::BOARD_X + Redoku::Layout::BOARD_W
end

assert('Layout menu rows tile the board into 9 full-width bands') do
  assert_equal 9, Redoku::Renderer::MENU_ROWS
  assert_equal [72, 200, 1260, 140], Redoku::Layout.menu_row_rect(0)
  assert_equal [72, 1320, 1260, 140], Redoku::Layout.menu_row_rect(8)
  assert_raise(ArgumentError) { Redoku::Layout.menu_row_rect(9) }
  assert_raise(ArgumentError) { Redoku::Layout.menu_row_rect(-1) }
  # Every point of the board answers exactly one row; the corners included.
  assert_equal 0, Redoku::Layout.menu_row_at(72, 200)
  assert_equal 8, Redoku::Layout.menu_row_at(1331, 1459)
  assert_equal 4, Redoku::Layout.menu_row_at(700, 830)
  assert_nil Redoku::Layout.menu_row_at(71, 200)    # left of the board
  assert_nil Redoku::Layout.menu_row_at(1332, 900)  # right of the board
  assert_nil Redoku::Layout.menu_row_at(700, 199)   # above the board
  assert_nil Redoku::Layout.menu_row_at(700, 1460)  # below the board
end
