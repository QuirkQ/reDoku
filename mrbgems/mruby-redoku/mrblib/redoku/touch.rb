module Redoku
  # pt_mt touchscreen -> panel coordinates (PLAN.md §3). Unlike the pen's
  # digitizer this panel is mounted the same way round as the display, so
  # there is no axis swap: only Y counts the other way.
  #
  # A module of its own rather than an argument to Pen: the two share the
  # word "transform" and nothing else — different ranges, different axes,
  # different callers — and one function with a mode flag would have to be
  # read twice to see which device a call site meant.
  module Touch
    MAX_X = 1403 # ABS_MT_POSITION_X range, along the screen's width
    MAX_Y = 1871 # ABS_MT_POSITION_Y range, along the screen's height

    # The scale factors are 1:1 today (the touchscreen reports one unit per
    # panel pixel), and the arithmetic is written out anyway so that a
    # firmware reporting a different range stays correct instead of drawing
    # in the wrong place. PLAN.md §3 gives the flip as `1872 - Y`, which is
    # off by one at Y = 0: SCREEN_H - 1 is the last real row, and mapping
    # onto it is what keeps every result a valid panel pixel, exactly as in
    # Pen.to_screen.
    def self.to_screen(raw_x, raw_y)
      rx = raw_x < 0 ? 0 : (raw_x > MAX_X ? MAX_X : raw_x)
      ry = raw_y < 0 ? 0 : (raw_y > MAX_Y ? MAX_Y : raw_y)
      x = rx * (Layout::SCREEN_W - 1) / MAX_X
      y = (MAX_Y - ry) * (Layout::SCREEN_H - 1) / MAX_Y
      [x, y]
    end
  end
end
