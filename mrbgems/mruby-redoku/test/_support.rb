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

  def fill_rect(x, y, w, h, gray)
    @rects << [x, y, w, h, gray]
    self
  end

  def draw_line(x1, y1, x2, y2, width, gray)
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
