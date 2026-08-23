assert('Touch.to_screen maps the touchscreen onto the panel, flipping Y') do
  # ABS_MT_POSITION_X (0..1403) is already the screen's x and needs no swap;
  # only Y counts the other way (PLAN.md §3). Every mapped point is a valid
  # panel pixel, so the extremes land on SCREEN_H - 1, not SCREEN_H — which
  # is where PLAN's `1872 - Y` is one out.
  assert_equal [0, Redoku::Layout::SCREEN_H - 1], Redoku::Touch.to_screen(0, 0)
  assert_equal [Redoku::Layout::SCREEN_W - 1, 0],
               Redoku::Touch.to_screen(Redoku::Touch::MAX_X,
                                       Redoku::Touch::MAX_Y)
  assert_equal [Redoku::Layout::SCREEN_W - 1, Redoku::Layout::SCREEN_H - 1],
               Redoku::Touch.to_screen(Redoku::Touch::MAX_X, 0)
  x, y = Redoku::Touch.to_screen(Redoku::Touch::MAX_X / 2,
                                 Redoku::Touch::MAX_Y / 2)
  assert_true (x - Redoku::Layout::SCREEN_W / 2).abs <= 2, "x=#{x}"
  assert_true (y - Redoku::Layout::SCREEN_H / 2).abs <= 2, "y=#{y}"
end

assert('Touch.to_screen is not the pen transform') do
  # The two devices are mounted differently, and mixing the transforms up
  # would put every finger press somewhere else entirely: the pen swaps its
  # axes, the touchscreen does not.
  x, y = Redoku::Touch.to_screen(100, 200)
  assert_equal 100, x
  assert_equal Redoku::Touch::MAX_Y - 200, y
end

assert('Touch.to_screen clamps a raw point to the panel') do
  assert_equal [0, Redoku::Layout::SCREEN_H - 1],
               Redoku::Touch.to_screen(-5000, -5000)
  assert_equal [Redoku::Layout::SCREEN_W - 1, 0],
               Redoku::Touch.to_screen(99_999, 99_999)
  # Clamping happens before the multiply, so no reported value — however
  # wrong — can overflow the 32-bit mrb_int of the device build.
  [[0, 0], [1403, 1871], [700, 900], [-1, 99_999]].each do |rx, ry|
    x, y = Redoku::Touch.to_screen(rx, ry)
    assert_true x >= 0 && x < Redoku::Layout::SCREEN_W, "x=#{x}"
    assert_true y >= 0 && y < Redoku::Layout::SCREEN_H, "y=#{y}"
  end
end
