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

assert('Layout buttons are laid out with Quit on its own row') do
  assert_equal [:new, :level, :quit], Redoku::Layout.buttons.map { |b| b[0] }
  assert_equal [72, 1540, 400, 140], Redoku::Layout.button_rect(:new)
  assert_equal [502, 1540, 400, 140], Redoku::Layout.button_rect(:level)
  assert_equal [932, 1700, 400, 140], Redoku::Layout.button_rect(:quit)
  # Everything stays on the panel and inside the board's columns.
  Redoku::Layout.buttons.each do |_name, x, y, w, h|
    assert_true x >= Redoku::Layout::BOARD_X
    assert_true x + w <= Redoku::Layout::BOARD_X + Redoku::Layout::BOARD_W
    assert_true y + h <= Redoku::Layout::SCREEN_H
    assert_true y >= Redoku::Layout::BOARD_Y + Redoku::Layout::BOARD_W
  end
  assert_nil Redoku::Layout.button_rect(:check) # not part of M1
end

assert('Layout.button_at hit-tests the button row') do
  assert_equal :new, Redoku::Layout.button_at(72, 1540)
  assert_equal :new, Redoku::Layout.button_at(471, 1679)
  assert_equal :level, Redoku::Layout.button_at(502, 1600)
  assert_equal :quit, Redoku::Layout.button_at(1000, 1750)
  assert_nil Redoku::Layout.button_at(472, 1600)  # gap between New and Level
  assert_nil Redoku::Layout.button_at(72, 1700)   # empty spot on the Quit row
  assert_nil Redoku::Layout.button_at(700, 800)   # middle of the board
end
