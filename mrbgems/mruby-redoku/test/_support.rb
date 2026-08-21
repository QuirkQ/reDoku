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

  # The two argument checks below mirror what the C Display enforces, so a
  # call that passes here cannot fail on the device. Out-of-panel rects are
  # deliberately NOT clipped: gray_at replays @rects verbatim, and clipping
  # would hide the very mistakes the renderer tests look for.
  def fill_rect(x, y, w, h, gray)
    raise ArgumentError, 'gray must be 0..255' if gray < 0 || gray > 255
    raise ArgumentError, 'width and height must be >= 0' if w < 0 || h < 0
    @rects << [x, y, w, h, gray]
    self
  end

  def draw_line(x1, y1, x2, y2, width, gray)
    raise ArgumentError, 'gray must be 0..255' if gray < 0 || gray > 255
    @lines << [x1, y1, x2, y2, width, gray]
    self
  end

  def update(x, y, w, h, waveform: RM2::GL16, flags: 0)
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
