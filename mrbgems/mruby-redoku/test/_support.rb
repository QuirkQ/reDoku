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

  # How many fill_rect calls have been recorded. Used only to prove drawing
  # happened at all, not where.
  def draw_count
    @rects.size
  end

  # Distinct gray values among recorded rects that are not white (255) — i.e.
  # actual ink, not background fill. Proves givens and entries render in two
  # different grays without caring how many rects each one took.
  def inked_grays
    grays = []
    @rects.each do |_x, _y, _w, _h, gray|
      grays << gray if gray != 255 && !grays.include?(gray)
    end
    grays
  end

  # True when at least one ink rect (a fill_rect in a gray other than white)
  # was recorded, AND every ink rect recorded lies entirely inside the given
  # rectangle. The "every", not "any", is what makes this a real containment
  # check: an `any?` version would still pass with a glyph half outside its
  # cell, as long as one stray pixel happened to land inside.
  def painted_within?(x, y, w, h)
    ink = @rects.select { |_rx, _ry, _rw, _rh, gray| gray != 255 }
    return false if ink.size == 0
    ink.all? do |rx, ry, rw, rh, _gray|
      rx >= x && ry >= y && rx + rw <= x + w && ry + rh <= y + h
    end
  end

  # True when some ink rect lies entirely inside cell `index`'s rect, inset on
  # every side by Layout::BLOCK_LINE. NOT a fix for draw_board today: its
  # grid lines are painted as rects spanning the whole board, so a line rect
  # is never entirely inside a single cell rect regardless of this inset —
  # remove the inset and every existing assertion using this still passes.
  # It is defence against a FUTURE per-cell line painter that would put a
  # short line rect right at a cell's edge, which the whole-board painter
  # never does. A digit at DIGIT_SCALE leaves 21 px of vertical margin, far
  # clear of a 4 px inset, so the inset costs the real case nothing either way.
  def glyph_in_cell?(index)
    col = Redoku::Sudoku::Grid.col_of(index)
    row = Redoku::Sudoku::Grid.row_of(index)
    x, y, w, h = Redoku::Layout.cell_rect(col, row)
    inset = Redoku::Layout::BLOCK_LINE
    ix = x + inset
    iy = y + inset
    iw = w - 2 * inset
    ih = h - 2 * inset
    @rects.any? do |rx, ry, rw, rh, gray|
      next false if gray == 255
      rx >= ix && ry >= iy && rx + rw <= ix + iw && ry + rh <= iy + ih
    end
  end
end

# Stands in for a Time, for Rng.from_clock. It answers one fixed reading and
# counts how often each half of it was asked for, so "reads the clock exactly
# once" is something a test can check rather than assume.
#
# A SECOND read of either half answers a DRIFTED value — a second later, a
# fresh microsecond — instead of raising. That is the hazard from_clock exists
# to avoid, reproduced: two separate Time.now calls can straddle a second
# boundary and mix a fresh microsecond into a stale second. Raising would also
# make `reads` unable to ever exceed 1, which would turn the assertion that
# reads it into one that cannot fail.
class OneShotClock
  def initialize(secs, usec)
    @secs = secs
    @usec = usec
    @sec_reads = 0
    @usec_reads = 0
    @last_secs = secs
    @last_usec = usec
  end

  def to_i
    @sec_reads += 1
    @last_secs = @sec_reads == 1 ? @secs : @secs + 1
  end

  def usec
    @usec_reads += 1
    @last_usec = @usec_reads == 1 ? @usec : @usec + 1
  end

  # One reading is one to_i AND one usec, so the two counters have to agree.
  # When they do not the answer is nil rather than an average or a maximum: a
  # caller that read the seconds twice and the microseconds never has not read
  # the clock once, and `assert_equal 1, probe.reads` must not be talked into
  # saying it did.
  def reads
    @sec_reads == @usec_reads ? @sec_reads : nil
  end

  # The seed the values this clock actually handed out imply. Pins the VALUE
  # as well as the count: a from_clock that read the seconds twice would take
  # the drifted one, and this would no longer match the seed the test asked
  # for even though `reads` alone might.
  def seed_seen
    Redoku::Rng.clock_seed(@last_secs, @last_usec)
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
