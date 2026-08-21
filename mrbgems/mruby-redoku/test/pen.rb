assert('Pen.to_screen rotates the digitizer into panel coordinates') do
  # The pen's long axis is ABS_X (0..20966) and maps to screen y, inverted;
  # ABS_Y (0..15725) maps to screen x (PLAN.md §3). Every mapped point is a
  # valid panel pixel, so the extremes land on SCREEN_H - 1, not SCREEN_H.
  assert_equal [0, Redoku::Layout::SCREEN_H - 1], Redoku::Pen.to_screen(0, 0)
  assert_equal [0, 0], Redoku::Pen.to_screen(Redoku::Pen::MAX_X, 0)
  x, y = Redoku::Pen.to_screen(Redoku::Pen::MAX_X / 2, Redoku::Pen::MAX_Y / 2)
  assert_true (x - Redoku::Layout::SCREEN_W / 2).abs <= 2
  assert_true (y - Redoku::Layout::SCREEN_H / 2).abs <= 2
end

assert('Pen.to_screen keeps the far corner inside the panel') do
  x, y = Redoku::Pen.to_screen(Redoku::Pen::MAX_X, Redoku::Pen::MAX_Y)
  assert_true x >= 0 && x < Redoku::Layout::SCREEN_W, "x=#{x}"
  assert_true y >= 0 && y < Redoku::Layout::SCREEN_H, "y=#{y}"
end

assert('Pen.to_screen clamps out-of-range raw values') do
  assert_equal [0, Redoku::Layout::SCREEN_H - 1],
               Redoku::Pen.to_screen(-100, -100)
  x, y = Redoku::Pen.to_screen(Redoku::Pen::MAX_X * 2, Redoku::Pen::MAX_Y * 2)
  assert_equal Redoku::Layout::SCREEN_W - 1, x
  assert_equal 0, y
end
