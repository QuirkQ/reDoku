module Redoku
  # Wacom I2C Digitizer -> panel coordinates (PLAN.md §3). The digitizer is
  # mounted rotated: its X axis runs along the panel's long side and counts
  # the opposite way, so raw x becomes screen y inverted and raw y becomes
  # screen x. Integer arithmetic throughout — this runs per pen sample.
  module Pen
    MAX_X = 20966 # ABS_X range, along the screen's height
    MAX_Y = 15725 # ABS_Y range, along the screen's width

    # The `- 1` in both denominators is deliberate: mapping onto SCREEN_W - 1
    # and SCREEN_H - 1 makes every result a valid panel pixel, so nothing
    # downstream has to clamp again.
    def self.to_screen(raw_x, raw_y)
      rx = raw_x < 0 ? 0 : (raw_x > MAX_X ? MAX_X : raw_x)
      ry = raw_y < 0 ? 0 : (raw_y > MAX_Y ? MAX_Y : raw_y)
      x = ry * (Layout::SCREEN_W - 1) / MAX_Y
      y = (MAX_X - rx) * (Layout::SCREEN_H - 1) / MAX_X
      [x, y]
    end
  end
end
