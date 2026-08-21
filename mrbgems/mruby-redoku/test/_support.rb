# The leading underscore is load order, not decoration: mrbtest loads a gem's
# test files in sorted order and runs each assert block as its file loads, so
# a shared helper has to sort first or the tests using it die with
# `uninitialized constant TestDisplay`. Rename this to support.rb and four
# assertions crash. Keep sibling test filenames lowercase too: '_' is 0x5F,
# so an uppercase or digit-leading name would sort ahead of this one.
#
# Stand-in for RM2::Display: records draw calls so tests can assert on
# geometry, and answers gray_at by replaying them in order.
class TestDisplay
  attr_reader :rects, :lines, :updates

  MAX_SPAN = 65535 # RM2_MAX_SPAN in src/display.c

  def initialize(w = Redoku::Layout::SCREEN_W, h = Redoku::Layout::SCREEN_H)
    @w = w
    @h = h
    @rects = []
    @lines = []
    @updates = []
  end

  def width
    @w
  end

  def height
    @h
  end

  # The checks in fill_rect, draw_line and update below are every ArgumentError
  # the C Display raises (src/display.c), with the same message text, so an
  # argument this mock accepts is one the device accepts too. Two real
  # behaviours are deliberately NOT reproduced, so do not read these as a full
  # emulation: the C clips out-of-panel geometry instead of raising, which the
  # mock must not do because gray_at replays @rects verbatim and clipping would
  # hide the very mistakes the renderer tests look for; and the C raises
  # RuntimeError on a closed display, which cannot arise here as the mock has
  # no close. Add a check here whenever display.c grows one.
  def fill_rect(x, y, w, h, gray)
    raise ArgumentError, 'gray must be 0..255' if gray < 0 || gray > 255
    raise ArgumentError, 'width and height must be >= 0' if w < 0 || h < 0
    @rects << [x, y, w, h, gray]
    self
  end

  def draw_line(x1, y1, x2, y2, width, gray)
    raise ArgumentError, 'gray must be 0..255' if gray < 0 || gray > 255
    if width < 1 || width > MAX_SPAN
      raise ArgumentError, 'width must be >= 1 and <= 65535'
    end
    dx = x2 > x1 ? x2 - x1 : x1 - x2
    dy = y2 > y1 ? y2 - y1 : y1 - y2
    if dx > MAX_SPAN || dy > MAX_SPAN
      raise ArgumentError, 'line span too large'
    end
    @lines << [x1, y1, x2, y2, width, gray]
    self
  end

  def update(x, y, w, h, waveform: RM2::GL16, flags: 0)
    raise ArgumentError, 'width and height must be >= 0' if w < 0 || h < 0
    @updates << [x, y, w, h, waveform, flags]
    true
  end

  # Gray last written at (px, py) by fill_rect, or nil if never touched.
  def gray_at(px, py)
    found = nil
    @rects.each do |x, y, w, h, gray|
      found = gray if px >= x && px < x + w && py >= y && py < y + h
    end
    found
  end

  def clear_calls
    @rects = []
    @lines = []
    @updates = []
  end
end
