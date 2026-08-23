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

  # RM2_MAX_SPAN in src/display.c, where it bounds each draw_line coordinate
  # as well as the span between them.
  MAX_SPAN = 65535

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

  # The checks in fill_rect, draw_line and update below mirror every
  # ArgumentError the C Display raises (src/display.c), with the same message
  # text, kept in sync by hand rather than by anything shared with the C —
  # so an argument this mock accepts is meant to be one the device accepts
  # too, not guaranteed to be. Two real
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
    # The coordinate bound comes before the span, as it does in C: there the
    # subtraction below can overflow on the 32-bit device ABI, so a span
    # computed from unbounded endpoints is not a number worth checking.
    [x1, y1, x2, y2].each do |v|
      if v < -MAX_SPAN || v > MAX_SPAN
        raise ArgumentError, "coordinate must be within -#{MAX_SPAN}..#{MAX_SPAN}"
      end
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

# --- sudoku fixtures, shared by the grid, solver, technique, rater and
# generator suites. 81 characters, '.' for an empty cell, read row-major.
# They live here rather than in one suite because four files assert against
# them, and a board that drifts between copies is a bug nobody would find.

# A complete, valid solution: rows 1-3 are 123456789 shifted by 3 each time,
# and the lower two bands repeat the trick on a permuted digit set. Its
# validity is not taken on trust -- test/sudoku_grid.rb asserts
# Grid.consistent?(solved_values), so a typo here fails there first.
SOLVED_81 =
  '123456789' \
  '456789123' \
  '789123456' \
  '214365897' \
  '365897214' \
  '897214365' \
  '531642978' \
  '642978531' \
  '978531642'

# SOLVED_81 with the two opposite corners blanked. Both holes are forced by
# their row alone, so singles finish it and the Rater must call it easy.
EASY_81 =
  '.23456789' \
  '456789123' \
  '789123456' \
  '214365897' \
  '365897214' \
  '897214365' \
  '531642978' \
  '642978531' \
  '97853164.'

# Six holes, still exactly one solution: each blank is pinned by its column.
# Used to check that Solver.count says 1 on a board with real gaps rather
# than only on a finished one.
UNIQUE_81 =
  '....56789' \
  '456789123' \
  '789123456' \
  '214365897' \
  '365897214' \
  '897214365' \
  '531642978' \
  '642978531' \
  '9785316..'

# Three givens on an otherwise empty board, so the solution count runs into
# the billions. Exists to prove the counting solver EARLY-EXITS: a count
# that tries to be exact here never returns.
MULTI_81 =
  '1........' \
  '.........' \
  '.........' \
  '.........' \
  '....5....' \
  '.........' \
  '.........' \
  '.........' \
  '........9'

# An 81-char board string as the engine's values array: 0 for empty.
def values_of(str)
  out = []
  str.each_char { |ch| out << (ch == '.' ? 0 : ch.to_i) }
  out
end

def solved_values
  values_of(SOLVED_81)
end

def grid_of(str)
  Redoku::Sudoku::Grid.parse(str)
end

def r_shuffle_with_seed(list, seed)
  Redoku::Rng.new(seed).shuffle(list)
end
