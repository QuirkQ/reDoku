# Feeds canned samples to App as if they came from an RM2::Input.
class FakeInput
  attr_accessor :hung_up

  def initialize(batches = [])
    @batches = batches
    @hung_up = false
  end

  def pending_events
    @batches.shift || []
  end

  def hung_up?
    @hung_up
  end

  def empty?
    @batches.empty?
  end
end

# Stands in for RM2::Input.wait: says "ready" while batches remain, and
# records what it was asked to wait on, so tests can pin the arguments App
# passes rather than trusting them.
class FakeWaiter
  attr_reader :calls # one [sources, timeout_ms] per wait

  def initialize(sources)
    @sources = sources
    @calls = []
  end

  def wait(sources, timeout_ms)
    @calls << [sources, timeout_ms]
    @sources.any? { |s| !s.empty? }
  end
end

# Records how much had already reached the panel at each wait, so a test can
# assert what App had painted by the time it paused, rather than just that
# both things happened.
class TimelineWaiter < FakeWaiter
  attr_reader :updates_at

  def initialize(sources, display)
    super(sources)
    @d = display
    @updates_at = []
  end

  def wait(sources, timeout_ms)
    @updates_at << @d.updates.size
    super(sources, timeout_ms)
  end
end

# A display whose flush fails the way a wedged server's does: the display
# socket carries a 10 s receive timeout, so #update gives up and raises
# instead of answering. A RuntimeError stands in for the real
# SystemCallError, so that this gem's tests do not depend on which errno gem
# their mrbtest state happens to carry; App rescues StandardError, which both
# of them are.
class WedgedDisplay < TestDisplay
  def update(x, y, w, h, waveform: RM2::GL16, flags: 0)
    raise 'no ack from the display server'
  end
end

# A display that acks every flush except a button's. Contrived on purpose:
# it isolates the one guarantee N1 established for Quit and this task
# extends to all three buttons — the press flash is a courtesy and the
# action is the contract — from the pre-existing question of what an
# action's OWN failed flush should do.
class DeafButtonsDisplay < TestDisplay
  def update(x, y, w, h, waveform: RM2::GL16, flags: 0)
    raise 'no ack from the display server' if Redoku::Layout.button_at(x, y)
    super(x, y, w, h, waveform: waveform, flags: flags)
  end
end

# A monotonic clock a test can drive. The cooldown is half a second of real
# time; asserting against a real clock would mean sleeping through it once
# per assertion, so App takes the clock the same way it takes its waiter.
class FakeClock
  attr_accessor :ms

  def initialize(ms = 0)
    @ms = ms
  end

  def monotonic_ms
    @ms
  end
end

# Stands in for the RM2 module's signal flags, so one test's SIGTERM cannot
# leak into another's loop.
class FakeSignals
  attr_accessor :terminated, :resumed

  def initialize
    @terminated = false
    @resumed = false
  end

  def terminated?
    @terminated
  end

  def resumed?
    was = @resumed
    @resumed = false
    was
  end
end

# An Rng that records how much had already reached the panel the first time
# the generator drew from it.
#
# It exists because the splash's ORDERING cannot be seen from outside. A
# splash flushed BEFORE the dig and a splash flushed after it leave the
# identical update list behind — same rects, same waveforms, same count — so
# every assertion written after the fact holds either way, and the one thing
# PLAN.md §7 needs the splash for (covering a pause of a few hundred ms on the
# Cortex-A7) would be protected by nothing but code reading. Observing from
# INSIDE the dig is what makes the ordering testable: the generator's first
# draw is a moment during generation, and what has reached the panel by then
# is exactly the question.
#
# Both entry points are noted, not just shuffle: shuffle is all the generator
# and solver use today (Generator#dig_order, Solver#solve), but next_int is
# public and a future search could draw from it directly. shuffle calls
# next_int itself, and the nil guard is what keeps that from counting twice.
class SpyRng < Redoku::Rng
  attr_reader :updates_at_first_draw

  def initialize(display, seed)
    super(seed)
    @d = display
    @updates_at_first_draw = nil
  end

  def next_int(n)
    note_first_draw
    super(n)
  end

  def shuffle(list)
    note_first_draw
    super(list)
  end

  private

  def note_first_draw
    @updates_at_first_draw = @d.updates.size if @updates_at_first_draw.nil?
  end
end

# A pen sample — [raw_x, raw_y, pressure, tools] — built from the screen
# point it should land on. Both directions of the mapping round, so tests
# assert against screen_of(sample), never the point they started from.
def pen_sample(sx, sy, down)
  raw_x = (Redoku::Layout::SCREEN_H - 1 - sy) * Redoku::Pen::MAX_X /
          (Redoku::Layout::SCREEN_H - 1)
  raw_y = sx * Redoku::Pen::MAX_Y / (Redoku::Layout::SCREEN_W - 1)
  tools = RM2::Input::PEN | (down ? RM2::Input::TOUCH : 0)
  [raw_x, raw_y, down ? 1000 : 0, tools]
end

def screen_of(sample)
  Redoku::Pen.to_screen(sample[0], sample[1])
end

# The packet the digitizer sends when the tool leaves proximity: the last
# position, with every tool bit clear. Distinct from pen_sample(.., false),
# which is the pen hovering — still in proximity, and still suppressing
# touch.
def pen_away_sample(sx, sy)
  s = pen_sample(sx, sy, false)
  [s[0], s[1], 0, 0]
end

# --- press and tap helpers. Defined here, before the first assertion that
# uses them: top-level defs execute in file order in mruby, so a helper
# defined below its first caller is simply not there yet. Built on pen_sample
# rather than a parallel set, so a change to how a stroke is faked lands in
# one place.

def press_new(app)
  press_pen_button(app, :new)
end

def press_level(app)
  press_pen_button(app, :level)
end

# In a menu the play-mode :new rect means BACK (App#menu_target_at).
def press_back(app)
  x, y, w, h = Redoku::Layout.button_rect(:new)
  app.handle_sample(pen_sample(x + w / 2, y + h / 2, true))
  app.handle_sample(pen_sample(x + w / 2, y + h / 2, false))
end

# A tap: down and up on the centre of the named button.
def press_pen_button(app, name)
  x, y, w, h = Redoku::Layout.button_rect(name)
  app.handle_sample(pen_sample(x + w / 2, y + h / 2, true))
  app.handle_sample(pen_sample(x + w / 2, y + h / 2, false))
  app
end

def tap_pen_at(app, x, y)
  app.handle_sample(pen_sample(x, y, true))
  app.handle_sample(pen_sample(x, y, false))
  app
end

def tap_button(app, name)
  x, y, w, h = Redoku::Layout.button_rect(name)
  tap_pen_at(app, x + w / 2, y + h / 2)
end

# A GAMES-menu action taps the play-mode button whose rect it shares
# (geometry never moves between modes — see App#menu_target_at).
def tap_menu_action(app, name)
  chrome = { back: :new, del: :level, save: :games }
  tap_button(app, chrome[name])
end

def tap_menu_row(app, n)
  x, y, w, h = Redoku::Layout.menu_row_rect(n)
  tap_pen_at(app, x + w / 2, y + h / 2)
end

# The same packet with the pen's OTHER END in proximity: BTN_TOOL_RUBBER
# where pen_sample has BTN_TOOL_PEN. The digitizer latches one tool code or
# the other when the tool enters range and reports contact separately on
# BTN_TOUCH, so an eraser press differs from a tip press in exactly this one
# bit (mrbgems/mruby-rm2/src/input.c, and the device trace recorded in
# .superpowers/sdd/2026-08-23-m2-sudoku-engine/design-pen-eraser.md).
#
# Everything below this line is the only coverage eraser behaviour can ever
# have: PLAN.md §9's TCP injection rig writes BTN_TOOL_PEN and nothing else
# (rm2fb's sendPen), so the device path is manual-verify only.
def eraser_sample(sx, sy, down)
  s = pen_sample(sx, sy, down)
  [s[0], s[1], s[2], RM2::Input::RUBBER | (down ? RM2::Input::TOUCH : 0)]
end

# A TIP sample with the eraser bit stuck on as well. `tools` is a sticky mask
# whose bits are set and cleared per evdev code independently (input.c), so
# this is the state a LOST `BTN_TOOL_RUBBER 0` packet leaves behind — and the
# digitizer never mentions RUBBER again afterwards, so nothing clears it.
# A packet with both tools is corrupt: the hardware reports one or the other.
def stuck_rubber_sample(sx, sy, down)
  s = pen_sample(sx, sy, down)
  [s[0], s[1], s[2], s[3] | RM2::Input::RUBBER]
end

# The flat 0..80 cell index a sample lands in — derived from the point the
# transform actually produces, not the one the test asked for, because both
# directions of Pen.to_screen round.
def cell_index_of(sample)
  x, y = screen_of(sample)
  col, row = Redoku::Layout.cell_at(x, y)
  Redoku::Sudoku::Grid.index_of(col, row)
end

# The white fill a cell repaint starts with, as TestDisplay records it. Asking
# whether this rect is in d.rects is "that cell was repainted from the model",
# without depending on anything else the repaint drew.
def cell_fill(index)
  x, y, w, h = Redoku::Layout.cell_rect(Redoku::Sudoku::Grid.col_of(index),
                                        Redoku::Sudoku::Grid.row_of(index))
  [x, y, w, h, 255]
end

def count_fills(display, index)
  want = cell_fill(index)
  n = 0
  display.rects.each { |rect| n += 1 if rect == want }
  n
end

# A touchscreen sample, built the same way from the screen point it should
# land on. The pt_mt node reports no pressure and no BTN_TOOL/BTN_TOUCH:
# RM2::Input::FINGER, set from the multitouch tracking id, is the whole of
# what it says about contact — which is why a finger cannot be mistaken for
# a pen tip. This mapping is exact in both directions (the touchscreen
# reports one unit per panel pixel), so these tests may assert against the
# point they asked for; the first assertion below pins that.
def touch_sample(sx, sy, down)
  raw_x = sx * Redoku::Touch::MAX_X / (Redoku::Layout::SCREEN_W - 1)
  raw_y = Redoku::Touch::MAX_Y -
          sy * Redoku::Touch::MAX_Y / (Redoku::Layout::SCREEN_H - 1)
  [raw_x, raw_y, 0, down ? RM2::Input::FINGER : 0]
end

# The seed every App in this suite is built with. Arbitrary but FIXED, and
# both halves of that matter. Fixed is what lets a test say "New produced a
# DIFFERENT puzzle" at all — a clock-seeded App could deal two identical
# boards on some unlucky run — and it also pins the suite's generation cost
# instead of re-rolling it every time, because the dig is a search and a
# :medium request measured anywhere from 90 to 600 ms on this host depending on
# the seed. 11 was chosen by timing the sequences these tests drove at the
# time — medium+hard+easy for the two three-press Level tests, easy+easy for
# New — across a dozen candidate seeds and keeping one of the two fastest.
# Those two Level tests no longer dig for real (see below), so that
# measurement now stands behind the six tests that still do.
#
# The production default — App's own `rng:` keyword, which reads the clock —
# is covered by one test of its own rather than incidentally by all of these:
# see 'an App given no rng seeds itself from the clock'.
#
# Every App built through `new_app` now takes a FakeGenerator, so this seed no
# longer prices the suite's digging — only the six tests that construct an App
# directly generate for real, five of them at `:easy` and two of them (the
# New-and-Level acknowledgement sweep, and the refused Level flash) at
# `:medium`.
GEN_SEED = 11

# Stands in for Sudoku::Generator. Deals a real, uniquely-solvable board from
# the shared fixtures -- so every assertion about "the App holds a puzzle"
# still means something -- and lets a test say what should happen instead:
# a tier miss, nil, or a raise.
#
# It does NOT call the progress block unless asked to (progress: true), so the
# update-count assertions in this file keep counting what they counted before.
# Task 5's bar tests opt in.
class FakeGenerator
  attr_reader :calls, :tiers_asked

  def initialize(tier: nil, fail_with: nil, answer_nil: false,
                 progress: false, attempts: 4)
    @tier = tier            # nil means "answer the tier that was asked for"
    @fail_with = fail_with  # a String: raise RuntimeError with it, every call
    @answer_nil = answer_nil
    @progress = progress
    @attempts = attempts
    @calls = 0
    @tiers_asked = []
  end

  # Two fixtures alternating, so 'New deals a DIFFERENT puzzle' has something
  # to see. Both are uniquely solvable (test/sudoku_solver.rb pins that).
  BOARDS = [EASY_81, UNIQUE_81].freeze

  def generate(tier, _rng, attempts = nil)
    @calls += 1
    @tiers_asked << tier
    total = attempts || @attempts
    if block_given?
      i = 0
      while i < total && @progress
        i += 1
        yield(i, total)
      end
    end
    raise RuntimeError, @fail_with if @fail_with
    return nil if @answer_nil
    board = BOARDS[(@calls - 1) % BOARDS.size]
    {
      grid: Redoku::Sudoku::Grid.parse(board),
      solution: solved_values,
      tier: @tier.nil? ? tier : @tier,
      demand: :singles, score: 6, hardest: :naked_single,
      counts: { naked_single: 2 },
      clues: Redoku::Sudoku::Rater.clue_count(values_of(board)),
      attempts: 1
    }
  end
end

# `log: nil` by default, not `log: FakeLog.new`: a suite that logged by
# accident would print a generation report for every one of the sixty-odd App
# assertions below, and $stderr really is live under `make test` (both build
# targets call `conf.gembox 'default'`, which carries mruby-io). The tests that
# care about the report pass their own recorder.
def new_app(batches = [], rng: Redoku::Rng.new(GEN_SEED),
            generator: FakeGenerator.new, log: nil, store: nil)
  d = TestDisplay.new
  input = FakeInput.new(batches)
  signals = FakeSignals.new
  app = Redoku::App.new(d, [input], Redoku::Renderer.new(d),
                        FakeWaiter.new([input]), signals, rng: rng,
                        generator: generator, log: log, store: store)
  [app, d, input, signals]
end

# An App with a touchscreen as well as a pen, and a clock under the test's
# control.
def new_touch_app(pen_batches = [], touch_batches = [],
                  rng: Redoku::Rng.new(GEN_SEED),
                  generator: FakeGenerator.new, log: nil)
  d = TestDisplay.new
  pen = FakeInput.new(pen_batches)
  finger = FakeInput.new(touch_batches)
  clock = FakeClock.new
  waiter = FakeWaiter.new([pen, finger])
  app = Redoku::App.new(d, [pen], Redoku::Renderer.new(d), waiter,
                        FakeSignals.new, touch_sources: [finger],
                        clock: clock, rng: rng, generator: generator, log: log)
  [app, d, clock, waiter, pen, finger]
end

assert('App echoes ink along the pen path inside the board') do
  app, d, = new_app
  s1 = pen_sample(300, 400, true)  # pen down
  s2 = pen_sample(320, 420, true)  # drag
  s3 = pen_sample(340, 440, true)
  p1 = screen_of(s1)
  p2 = screen_of(s2)
  p3 = screen_of(s3)
  app.handle_sample(s1)
  app.handle_sample(s2)
  app.handle_sample(s3)
  assert_equal 2, d.lines.size # two segments for three points
  assert_equal [p1[0], p1[1], p2[0], p2[1], Redoku::App::INK_WIDTH,
                Redoku::App::INK_GRAY], d.lines[0]
  assert_equal [p2[0], p2[1], p3[0], p3[1], Redoku::App::INK_WIDTH,
                Redoku::App::INK_GRAY], d.lines[1]
end

assert('App flushes accumulated ink once, with the fast waveform') do
  app, d, = new_app
  s1 = pen_sample(300, 400, true)
  s2 = pen_sample(340, 440, true)
  p1 = screen_of(s1)
  p2 = screen_of(s2)
  app.handle_sample(s1)
  app.handle_sample(s2)
  assert_equal [], d.updates # nothing flushed while drawing
  app.flush_ink
  assert_equal 1, d.updates.size
  x, y, w, h, waveform, flags = d.updates[0]
  assert_equal RM2::DU, waveform
  assert_equal RM2::FAST_DRAW, flags
  # The damage rect covers both points plus the brush width.
  assert_true x <= p1[0] - Redoku::App::INK_WIDTH
  assert_true y <= p1[1] - Redoku::App::INK_WIDTH
  assert_true x + w >= p2[0] + Redoku::App::INK_WIDTH
  assert_true y + h >= p2[1] + Redoku::App::INK_WIDTH
  app.flush_ink
  assert_equal 1, d.updates.size # nothing left to flush
end

assert('App draws no ink for a pen that never touched down') do
  app, d, = new_app
  app.handle_sample(pen_sample(300, 400, false)) # hovering
  app.handle_sample(pen_sample(320, 420, false))
  assert_equal [], d.lines
end

assert('App ignores ink outside the board') do
  app, d, = new_app
  app.handle_sample(pen_sample(700, 1750, true)) # down on the button row
  app.handle_sample(pen_sample(720, 1760, true))
  assert_equal [], d.lines
end

assert('App does not draw ink from a stroke that began off the board') do
  app, d, = new_app
  app.handle_sample(pen_sample(700, 1600, true)) # down on the Level button
  app.handle_sample(pen_sample(700, 800, true))  # dragged onto the board
  assert_equal [], d.lines
end

assert('App stops inking where the pen leaves the board') do
  app, d, = new_app
  s1 = pen_sample(300, 400, true)  # down inside a cell
  s2 = pen_sample(340, 440, true)  # still inside
  s3 = pen_sample(340, 1600, true) # dragged off the board, over the buttons
  p1 = screen_of(s1)
  p2 = screen_of(s2)
  app.handle_sample(s1)
  app.handle_sample(s2)
  app.handle_sample(s3)
  assert_equal 1, d.lines.size # only the segment with both ends on the board
  assert_equal [p1[0], p1[1], p2[0], p2[1], Redoku::App::INK_WIDTH,
                Redoku::App::INK_GRAY], d.lines[0]
  # ...and nothing outside the board was marked for a DU flush either.
  board_bottom = Redoku::Layout::BOARD_Y + Redoku::Layout::BOARD_W
  assert_true app.ink_dirty[3] < board_bottom
end

assert('App resumes inking where the pen returns to the board') do
  app, d, = new_app
  s1 = pen_sample(300, 400, true)  # down inside a cell
  s2 = pen_sample(300, 1600, true) # off the board
  s3 = pen_sample(340, 440, true)  # back on the board
  s4 = pen_sample(380, 480, true)  # and moving inside it
  p3 = screen_of(s3)
  p4 = screen_of(s4)
  app.handle_sample(s1)
  app.handle_sample(s2)
  app.handle_sample(s3)
  app.handle_sample(s4)
  # Both crossings are gaps; only the pair with two in-board ends is drawn.
  assert_equal 1, d.lines.size
  assert_equal [p3[0], p3[1], p4[0], p4[1], Redoku::App::INK_WIDTH,
                Redoku::App::INK_GRAY], d.lines[0]
end

assert('App inks the closing segment when the pen lifts in mid-motion') do
  app, d, = new_app
  s1 = pen_sample(300, 400, true)
  # A real pen reports the new position and BTN_TOUCH 0 in the same packet
  # when it is lifted while still moving, so this segment is the stroke's
  # tail: drop it and every such stroke ends short of where the pen was.
  s2 = pen_sample(340, 440, false)
  p1 = screen_of(s1)
  p2 = screen_of(s2)
  app.handle_sample(s1)
  app.handle_sample(s2)
  assert_equal 1, d.lines.size
  assert_equal [p1[0], p1[1], p2[0], p2[1], Redoku::App::INK_WIDTH,
                Redoku::App::INK_GRAY], d.lines[0]
end

# --- the eraser end. BTN_TOOL_RUBBER instead of BTN_TOOL_PEN, latched at
# pen-down like every other stroke decision, and clearing whole cells rather
# than pixels.

assert('the eraser end clears the cell it touched instead of inking') do
  app, d, = new_app
  s = eraser_sample(300, 400, true)
  index = cell_index_of(s)
  app.handle_sample(s)
  # A second sample inside the same cell, so that the no-ink claim below is
  # about ink_to refusing rather than about ink_to never being reached: a lone
  # down sample runs begin_stroke only, and nothing on that path draws a line
  # whatever the mode, which would make the assertion unable to fail.
  app.handle_sample(eraser_sample(320, 420, true))
  # No ink: ink_to only draws for @mode == :ink, and this stroke is :erase.
  assert_equal [], d.lines
  # ...and the cell was repainted from the model instead. The white fill is
  # the first thing redraw_cell does, so it is also the first rect recorded.
  #
  # A white fill over the cell rect is the strongest thing a host test can say
  # here, and the reason is the mock, not the assertion: ink is a draw_line
  # and gray_at replays fill_rect calls, so no host test can watch a pixel of
  # ink disappear (the same limit the 'tap on New clears the ink' test
  # records). What the fill establishes is that every pixel of the cell was
  # painted over; that the ink was under it is geometry, not observation.
  assert_equal cell_fill(index), d.rects[0]
end

assert('the eraser puts the cell back the way the model has it') do
  app, d, = new_app
  app.new_puzzle
  # The first given of the board App just dug, so the erased cell has a digit
  # to come back. Bounded, not `while !given?`: an unbounded walk would spin
  # off the end of a hypothetical zero-clue grid instead of failing.
  given = nil
  Redoku::Sudoku::Grid::CELLS.times do |i|
    given = i if given.nil? && app.grid.given?(i)
  end
  assert_false given.nil?
  col = Redoku::Sudoku::Grid.col_of(given)
  row = Redoku::Sudoku::Grid.row_of(given)
  x, y, w, h = Redoku::Layout.cell_rect(col, row)
  d.clear_calls
  app.handle_sample(eraser_sample(x + w / 2, y + h / 2, true))
  assert_equal cell_fill(given), d.rects[0]
  # The given is printed again, in given ink, inside its own cell — which the
  # white fill above proves was cleared first.
  assert_true d.glyph_in_cell?(given)
  assert_true d.inked_grays.include?(Redoku::Renderer::GIVEN_GRAY)
end

assert('the eraser flushes the cell it cleared in the ink waveform') do
  app, d, = new_app
  s = eraser_sample(300, 400, true)
  index = cell_index_of(s)
  app.handle_sample(s)
  assert_equal [], d.updates # nothing flushed while the stroke is open
  app.flush_ink
  x, y, w, h = Redoku::Layout.cell_rect(Redoku::Sudoku::Grid.col_of(index),
                                        Redoku::Sudoku::Grid.row_of(index))
  pad = Redoku::App::INK_WIDTH
  # DU + FAST_DRAW, the pen echo's own waveform: erasing has to feel as
  # immediate as drawing, and everything a repaint puts back on an M2 board is
  # black on white, which is all a two-level waveform can carry anyway. The
  # region is the cell, padded exactly as ink damage is (mark_dirty).
  assert_equal 1, d.updates.size
  assert_equal [x - pad, y - pad, w + 2 * pad, h + 2 * pad,
                RM2::DU, RM2::FAST_DRAW], d.updates[0]
end

assert('an eraser drag clears every cell it crosses') do
  app, d, = new_app
  s1 = eraser_sample(300, 400, true)
  s2 = eraser_sample(450, 400, true) # the next cell to the right
  i1 = cell_index_of(s1)
  i2 = cell_index_of(s2)
  assert_false i1 == i2
  app.handle_sample(s1)
  app.handle_sample(s2)
  assert_equal 1, count_fills(d, i1)
  assert_equal 1, count_fills(d, i2)
  # One flush for both, because erasing shares the pen's once-per-turn damage
  # rect: the union covers the two cells.
  app.flush_ink
  assert_equal 1, d.updates.size
end

assert('the eraser repaints a cell once however many samples land in it') do
  app, d, = new_app
  s1 = eraser_sample(300, 400, true)
  index = cell_index_of(s1)
  app.handle_sample(s1)
  app.handle_sample(eraser_sample(310, 410, true))
  app.handle_sample(eraser_sample(320, 420, true))
  app.handle_sample(eraser_sample(320, 420, false)) # lift, same cell
  # A cell that has just been cleared cannot acquire new ink while the eraser
  # is down, so repainting it again per sample would be ~100 pointless cell
  # repaints a second on the Cortex-A7.
  assert_equal 1, count_fills(d, index)
end

assert('a stroke that went down on the tip inks even if the eraser bit turns up') do
  app, d, = new_app
  s1 = pen_sample(300, 400, true)
  s2 = eraser_sample(340, 440, true)
  p1 = screen_of(s1)
  p2 = screen_of(s2)
  app.handle_sample(s1)
  app.handle_sample(s2)
  # The tool is latched at pen-down, the way every other stroke decision is,
  # so a stroke can never change what it means halfway through. It mirrors the
  # digitizer, which latches the tool code on proximity entry and cannot
  # switch it while the tool is in range.
  assert_equal 1, d.lines.size
  assert_equal [p1[0], p1[1], p2[0], p2[1], Redoku::App::INK_WIDTH,
                Redoku::App::INK_GRAY], d.lines[0]
  assert_equal 0, count_fills(d, cell_index_of(s2))
end

assert('a stuck RUBBER bit does not turn the pen tip into an eraser') do
  app, d, = new_app
  s1 = stuck_rubber_sample(300, 400, true)
  s2 = stuck_rubber_sample(340, 440, true)
  p1 = screen_of(s1)
  p2 = screen_of(s2)
  app.handle_sample(s1)
  app.handle_sample(s2)
  # PEN | RUBBER is not "the eraser", it is a mask that lost a packet: the two
  # documented packet-eaters are the display server draining a thawed
  # client's backlog and SYN_DROPPED, the same two PEN_SILENCE_MS exists for.
  # Reading RUBBER alone would make every tip stroke for the rest of the
  # session wipe the cell the player was writing in, with no way back but
  # flipping the pen over and returning. So a corrupt packet inks, which is
  # the same trade fill_board makes: an unchanged board beats a wiped one.
  assert_equal 1, d.lines.size
  assert_equal [p1[0], p1[1], p2[0], p2[1], Redoku::App::INK_WIDTH,
                Redoku::App::INK_GRAY], d.lines[0]
  assert_equal 0, count_fills(d, cell_index_of(s1))
  # The stroke is a plain ink stroke, so it also leaves ink damage to flush,
  # rather than a cell-sized repaint region.
  assert_false app.ink_dirty.nil?
end

assert('a stroke that went down on the eraser never inks, tip bit or not') do
  app, d, = new_app
  app.handle_sample(eraser_sample(300, 400, true))
  app.handle_sample(pen_sample(340, 440, true))
  app.handle_sample(pen_sample(340, 440, false))
  assert_equal [], d.lines
end

assert('an eraser stroke that began off the board clears nothing') do
  app, d, = new_app
  app.handle_sample(eraser_sample(700, 1600, true)) # down on the Level button
  d.clear_calls
  s = eraser_sample(300, 400, true)                 # dragged onto the board
  app.handle_sample(s)
  # Same rule as ink: what a stroke does is decided where it went down, so
  # dragging onto the board cannot start erasing.
  assert_equal 0, count_fills(d, cell_index_of(s))
end

assert('the eraser end presses a button, exactly as the tip does') do
  app, = new_app
  qx, qy, qw, qh = Redoku::Layout.button_rect(:quit)
  app.handle_sample(eraser_sample(qx + qw / 2, qy + qh / 2, true))
  app.handle_sample(eraser_sample(qx + qw / 2, qy + qh / 2, false))
  # A deliberate decision, not an oversight: the chrome is not a writing
  # surface, so there is nothing there for an eraser to mean, and it is still
  # the same pen in the same hand — a tap is a tap. tap? asks only about
  # @mode == :button, which a stroke that went down off the board gets
  # whichever end of the pen it was.
  assert_false app.running?
end

assert('the eraser end suppresses touch the way the tip does') do
  app, _d, clock = new_touch_app
  qx, qy, qw, qh = Redoku::Layout.button_rect(:quit)
  # RUBBER in proximity, not touching anything: note_pen_proximity reads
  # PEN | RUBBER, because either end near the glass means a hand is over it.
  app.handle_sample(eraser_sample(300, 400, false))
  app.handle_touch_sample(touch_sample(qx + qw / 2, qy + qh / 2, true))
  app.handle_touch_sample(touch_sample(qx + qw / 2, qy + qh / 2, false))
  assert_true app.running?
  # And it keeps suppressing for the cooldown after it leaves, like the tip.
  app.handle_sample(pen_away_sample(300, 400))
  clock.ms += Redoku::App::TOUCH_COOLDOWN_MS - 1
  app.handle_touch_sample(touch_sample(qx + qw / 2, qy + qh / 2, true))
  app.handle_touch_sample(touch_sample(qx + qw / 2, qy + qh / 2, false))
  assert_true app.running?
end

assert('the eraser clears a cell on a board that has not been dug yet') do
  # An App holds no Grid until run or a New press digs one, and every test
  # above erases on exactly such an App. The ink still has to go.
  app, d, = new_app
  assert_nil app.grid
  s = eraser_sample(300, 400, true)
  app.handle_sample(s)
  assert_equal cell_fill(cell_index_of(s)), d.rects[0]
end

assert('a tap on Quit stops the loop') do
  app, = new_app
  assert_true app.running?
  qx, qy, qw, qh = Redoku::Layout.button_rect(:quit)
  app.handle_sample(pen_sample(qx + qw / 2, qy + qh / 2, true))
  app.handle_sample(pen_sample(qx + qw / 2, qy + qh / 2, false)) # release
  assert_false app.running?
end

assert('a tap on Quit acknowledges itself before the game tears down') do
  app, d, = new_app
  qx, qy, qw, qh = Redoku::Layout.button_rect(:quit)
  d.clear_calls
  app.handle_sample(pen_sample(qx + qw / 2, qy + qh / 2, true))
  app.handle_sample(pen_sample(qx + qw / 2, qy + qh / 2, false))
  assert_false app.running?
  # Quit is the one button whose action is not a repaint, and e-ink holds
  # the last image it was given right through teardown — so the inverted
  # flash below is the only feedback the player gets that the tap landed.
  # It goes out with the ink waveform (DU + FAST_DRAW), not GL16: this has
  # to beat the teardown it announces.
  assert_equal 1, d.updates.size
  assert_equal [qx, qy, qw, qh, RM2::DU, RM2::FAST_DRAW], d.updates[0]
  # Inverted means the paper is black and the border is white — the label
  # is drawn in the same white, so the whole button reads as pressed.
  assert_equal [qx, qy, qw, qh, Redoku::Renderer::BLACK], d.rects[0]
  assert_equal [qx, qy, qw, Redoku::Renderer::BUTTON_BORDER,
                Redoku::Renderer::WHITE], d.rects[1]
  assert_equal 255, d.gray_at(qx, qy)          # border, top-left: white now
  assert_equal 0, d.gray_at(qx + 10, qy + qh / 2) # paper, left of the label
end

assert('the Quit acknowledgement is held on the panel before the loop stops') do
  d = TestDisplay.new
  input = FakeInput.new
  waiter = TimelineWaiter.new([input], d)
  app = Redoku::App.new(d, [input], Redoku::Renderer.new(d), waiter,
                        FakeSignals.new)
  qx, qy, qw, qh = Redoku::Layout.button_rect(:quit)
  d.clear_calls
  app.handle_sample(pen_sample(qx + qw / 2, qy + qh / 2, true))
  app.handle_sample(pen_sample(qx + qw / 2, qy + qh / 2, false))
  assert_false app.running?
  # One hold, for the configured duration, watching nothing: waiting on the
  # real sources would end the instant the next pen sample arrived, and the
  # flash it is there to show would be gone before anyone saw it.
  assert_equal [[[], Redoku::App::PRESS_ACK_MS]], waiter.calls
  # ...and the flash had already reached the panel when the hold began,
  # which is the ordering that makes the pause worth anything.
  assert_equal [1], waiter.updates_at
  assert_equal [qx, qy, qw, qh, RM2::DU, RM2::FAST_DRAW], d.updates[0]
end

assert('every button acknowledges its press, at the button, for the same 200 ms') do
  [:new, :level, :games, :quit].each do |name|
    d = TestDisplay.new
    input = FakeInput.new
    waiter = TimelineWaiter.new([input], d)
    app = Redoku::App.new(d, [input], Redoku::Renderer.new(d), waiter,
                          FakeSignals.new, rng: Redoku::Rng.new(GEN_SEED))
    bx, by, bw, bh = Redoku::Layout.button_rect(name)
    d.clear_calls
    app.handle_sample(pen_sample(bx + bw / 2, by + bh / 2, true))
    app.handle_sample(pen_sample(bx + bw / 2, by + bh / 2, false))
    # The first thing out is the press, at the button, in the ink waveform.
    # This used to be Quit's alone, on the premise that New and Level
    # "repaint as their action and already read as responsive". Both halves
    # are false on hardware: New's repaint — a bare clear_ink when the device
    # said so, new_puzzle now — is pixel-identical on a board with no ink, and
    # cycle_difficulty's only visible change is a header label 1480 px from
    # the finger that caused it.
    assert_equal [bx, by, bw, bh, RM2::DU, RM2::FAST_DRAW], d.updates[0],
                 name.to_s
    # Inverted means black paper under a white border and label.
    assert_equal [bx, by, bw, bh, Redoku::Renderer::BLACK], d.rects[0], name.to_s
    assert_equal [bx, by, bw, Redoku::Renderer::BUTTON_BORDER,
                  Redoku::Renderer::WHITE], d.rects[1], name.to_s
    # Held exactly once, for exactly the duration the owner approved on the
    # device for Quit. One constant, not a second calibration.
    assert_equal [[[], Redoku::App::PRESS_ACK_MS]], waiter.calls, name.to_s
  end
end

assert('New and Level come back up; Quit stays down because it is leaving') do
  [:new, :level].each do |name|
    app, d, = new_app
    bx, by, bw, bh = Redoku::Layout.button_rect(name)
    d.clear_calls
    app.handle_sample(pen_sample(bx + bw / 2, by + bh / 2, true))
    app.handle_sample(pen_sample(bx + bw / 2, by + bh / 2, false))
    assert_true app.running?, name.to_s
    # Neither action leaves the button inverted: new_puzzle flushes the board,
    # open_levels the whole panel — either way every pixel of the pressed
    # button has just been repainted over, but only by paints that are
    # already ordered before the release, so the release of its own is what
    # guarantees the button comes back up.
    assert_equal [bx, by, bw, bh, RM2::DU, RM2::FAST_DRAW],
                 d.updates[d.updates.size - 1], name.to_s
    # Same waveform in both directions, so the flash is symmetric: a press
    # arriving in a tenth of a second and a release fading back over a
    # GL16's half second would not read as one gesture.
    assert_equal 0, d.gray_at(bx, by), name.to_s               # border black
    assert_equal 255, d.gray_at(bx + 10, by + bh / 2), name.to_s # paper white
  end

  # Quit is the exception, and the one that must NOT be put back: e-ink
  # holds the last image it was given, so the inverted button is the
  # goodbye. Restoring it would erase the only feedback the tap gives.
  app, d, = new_app
  qx, qy, qw, qh = Redoku::Layout.button_rect(:quit)
  d.clear_calls
  app.handle_sample(pen_sample(qx + qw / 2, qy + qh / 2, true))
  app.handle_sample(pen_sample(qx + qw / 2, qy + qh / 2, false))
  assert_equal 1, d.updates.size
  assert_equal 255, d.gray_at(qx, qy)
  assert_equal 0, d.gray_at(qx + 10, qy + qh / 2)
end

assert('the action runs while the button is held down, not after it comes up') do
  d = TestDisplay.new
  input = FakeInput.new
  waiter = TimelineWaiter.new([input], d)
  app = Redoku::App.new(d, [input], Redoku::Renderer.new(d), waiter,
                        FakeSignals.new, rng: Redoku::Rng.new(GEN_SEED),
                        log: nil)
  nx, ny, nw, nh = Redoku::Layout.button_rect(:new)
  d.clear_calls
  app.handle_sample(pen_sample(nx + nw / 2, ny + nh / 2, true))
  app.handle_sample(pen_sample(nx + nw / 2, ny + nh / 2, false))
  # THE EXACT COUNTS BELOW ASSUME EXACTLY ONE BAR PAINT, and this line is the
  # assumption rather than a comment about it. EASY hits on its first attempt
  # on 500 of 500 measured chains, so the hook fires once; one paint follows
  # iff that single step clears the throttle. Raise ATTEMPTS[:easy] to 60 and
  # it does not (614/61 = 10 px), the bar paints ZERO times, and every count
  # below is off by one for a reason nobody would find from the failure. So it
  # fails here, with a reason.
  assert_true Redoku::Renderer.progress_fill(
    1, 1 + Redoku::Sudoku::Generator::ATTEMPTS[:easy]
  ) >= Redoku::App::PROGRESS_STEP_PX

  # FOUR updates had reached the panel by the time the hold began: the press
  # flash, the splash, the progress bar moving DURING the dig, and the board
  # repaint carrying the new puzzle. Was two before M2, when New's whole action
  # was one board repaint, and three until the bar existed. The bar is the new
  # one, and it counts here for the same reason the others do — 200 ms is how
  # long a press lasts, not a toll to charge before every action, so the work
  # starts the moment the tap is recognised and the button stays down while it
  # happens.
  assert_equal [4], waiter.updates_at
  bx, by, bw, bh = Redoku::Layout.board_rect
  # The splash goes out over board_rect with the chrome waveform, because
  # draw_splash paints exactly board_rect (see Renderer#draw_splash), which is
  # what lets one flush_board cover it.
  assert_equal [bx, by, bw, bh, RM2::GL16, 0], d.updates[1]
  # Then the bar moved WHILE the generator dug — asserted rather than skipped
  # over, because it is the half of covering the pause a static splash cannot
  # do, and this test is already the one that reads the sequence.
  px, py, pw, ph = Redoku::Renderer.progress_rect
  assert_equal [px, py, pw, ph, RM2::DU, RM2::FAST_DRAW], d.updates[2]
  # ...then the finished puzzle, over board_rect again.
  assert_equal [bx, by, bw, bh, RM2::GL16, 0], d.updates[3]
  # press, splash, bar, puzzle, release — and the release is after the hold.
  assert_equal 5, d.updates.size
  assert_equal [nx, ny, nw, nh, RM2::DU, RM2::FAST_DRAW], d.updates[4]
end

assert('the acknowledgement runs each action exactly once') do
  app, d, = new_app
  lx, ly, lw, lh = Redoku::Layout.button_rect(:level)
  nx, ny, nw, nh = Redoku::Layout.button_rect(:new)
  2.times do
    d.clear_calls
    press_level(app)
    # One picker per tap: a press that ran open_levels twice would paint two
    # full screens, and one that dropped it would leave the board showing.
    assert_equal :levels, app.screen
    # Exactly three updates per tap: the press flash at the button (DU), ONE
    # whole-screen GC16 carrying the picker — a menu is a mode change and
    # arrives in one paint, exactly as the GAMES menu does — and the release
    # flash. Counted by region rather than trusting the total alone.
    assert_equal 3, d.updates.size
    assert_equal [lx, ly, lw, lh, RM2::DU, RM2::FAST_DRAW], d.updates[0]
    u = d.updates[1]
    assert_equal [0, 0], [u[0], u[1]]
    assert_equal [Redoku::Layout::SCREEN_W, Redoku::Layout::SCREEN_H],
                 [u[2], u[3]]
    assert_equal RM2::GC16, u[4]
    assert_equal [lx, ly, lw, lh, RM2::DU, RM2::FAST_DRAW], d.updates[2]
    # And BACK out again, so the next round presses Level on :play, where it
    # means the picker — on :menu and :levels that rect belongs to the menu.
    d.clear_calls
    app.handle_sample(pen_sample(nx + nw / 2, ny + nh / 2, true))
    app.handle_sample(pen_sample(nx + nw / 2, ny + nh / 2, false))
    assert_equal :play, app.screen
  end
end

assert('a finger tap is acknowledged exactly the way the pen tap is') do
  app, d, = new_touch_app
  nx, ny, nw, nh = Redoku::Layout.button_rect(:new)
  d.clear_calls
  app.handle_touch_sample(touch_sample(nx + nw / 2, ny + nh / 2, true))
  app.handle_touch_sample(touch_sample(nx + nw / 2, ny + nh / 2, false))
  # One mechanism, not two: both sources arrive at the same press(), so the
  # feedback falls out rather than being written twice.
  #
  # Four updates, not the three of M1: press flash, splash, puzzle, release.
  # New's action grew a splash flush when it started digging a puzzle, and
  # this test's subject is that a FINGER gets the identical sequence a pen
  # does — so the count follows the pen's, and the release is still the last
  # thing out.
  assert_equal 4, d.updates.size
  assert_equal [nx, ny, nw, nh, RM2::DU, RM2::FAST_DRAW], d.updates[0]
  assert_equal [nx, ny, nw, nh, RM2::DU, RM2::FAST_DRAW], d.updates[3]
  assert_equal 0, d.gray_at(nx, ny)
end

assert('a Level press whose flash is refused still opens the picker') do
  d = DeafButtonsDisplay.new
  input = FakeInput.new
  waiter = TimelineWaiter.new([input], d)
  app = Redoku::App.new(d, [input], Redoku::Renderer.new(d), waiter,
                        FakeSignals.new, rng: Redoku::Rng.new(GEN_SEED),
                        log: nil)
  lx, ly, lw, lh = Redoku::Layout.button_rect(:level)
  app.handle_sample(pen_sample(lx + lw / 2, ly + lh / 2, true))
  app.handle_sample(pen_sample(lx + lw / 2, ly + lh / 2, false))
  # N1 for all three buttons now, not Quit's alone: the display socket
  # carries a 10 s receive timeout, so a press flash really can raise on the
  # device — and the player must still get the thing they pressed.
  assert_equal :levels, app.screen
  assert_equal :easy, app.difficulty   # the picker, not a dig
  assert_true app.running?
  # Nothing reached the panel to hold or to put back, so neither happened.
  assert_equal [], waiter.calls
  # The action's own paint DID reach the panel: one whole-screen GC16. The
  # deaf display refuses only button rects, and no button lives at (0, 0).
  assert_equal 1, d.updates.size
  u = d.updates[0]
  assert_equal [0, 0, Redoku::Layout::SCREEN_W, Redoku::Layout::SCREEN_H,
                RM2::GC16, RM2::SYNC], u
end

assert('a New press whose flash is refused still clears the ink') do
  d = DeafButtonsDisplay.new
  input = FakeInput.new
  waiter = TimelineWaiter.new([input], d)
  app = Redoku::App.new(d, [input], Redoku::Renderer.new(d), waiter,
                        FakeSignals.new, rng: Redoku::Rng.new(GEN_SEED),
                        log: nil)
  app.handle_sample(pen_sample(300, 400, true))
  app.handle_sample(pen_sample(340, 440, true))
  app.handle_sample(pen_sample(340, 440, false))
  d.clear_calls
  nx, ny, nw, nh = Redoku::Layout.button_rect(:new)
  app.handle_sample(pen_sample(nx + nw / 2, ny + nh / 2, true))
  app.handle_sample(pen_sample(nx + nw / 2, ny + nh / 2, false))
  bx, by, bw, bh = Redoku::Layout.board_rect
  # Two board flushes with the bar moving between them, where M1 had one board
  # flush and nothing else: the splash, the bar during the dig, then the board
  # carrying the new puzzle. Both board flushes go over board_rect with the
  # chrome waveform, exactly as the single one did — the refused button flash
  # still costs the player nothing, which is what this test is for.
  #
  # COUNTED BY REGION rather than as one literal list, even though this test
  # digs :easy and the literal could simply have grown a middle entry. The
  # point is that the two refused-flash tests read alike and neither breaks the
  # next time an attempt budget moves.
  board = d.updates.reject { |u| u[0] != bx || u[1] != by }
  assert_equal 2, board.size
  board.each { |u| assert_equal [bx, by, bw, bh, RM2::GL16, 0], u }
  px, py, = Redoku::Renderer.progress_rect
  bar = d.updates.reject { |u| u[0] != px || u[1] != py }
  assert_true bar.size >= 1
  bar.each { |u| assert_equal RM2::DU, u[4] }
  # And nothing else at all reached the panel — in particular no button rect,
  # which is the whole subject of the test.
  assert_equal d.updates.size, board.size + bar.size
  assert_nil app.ink_dirty
  assert_false app.grid.nil?
  assert_true app.running?
  assert_equal [], waiter.calls
end

assert('Quit proceeds when the acknowledgement cannot be delivered') do
  d = WedgedDisplay.new
  input = FakeInput.new
  waiter = TimelineWaiter.new([input], d)
  app = Redoku::App.new(d, [input], Redoku::Renderer.new(d), waiter,
                        FakeSignals.new)
  qx, qy, qw, qh = Redoku::Layout.button_rect(:quit)
  app.handle_sample(pen_sample(qx + qw / 2, qy + qh / 2, true))
  app.handle_sample(pen_sample(qx + qw / 2, qy + qh / 2, false))
  # The press is a courtesy; the exit is the contract. A server that stops
  # acking must not turn a Quit tap into an exception that unwinds past
  # main.rb's explicit display.close and leaves the panel to a finalizer.
  assert_false app.running?
  # Nothing landed on the panel, so there is nothing to hold for either.
  assert_equal [], waiter.calls
end

assert('a long drag across Quit is not a tap') do
  app, = new_app
  qx, qy, qw, qh = Redoku::Layout.button_rect(:quit)
  app.handle_sample(pen_sample(qx + 10, qy + 10, true))
  app.handle_sample(pen_sample(qx + qw - 10, qy + qh - 10, true))
  app.handle_sample(pen_sample(qx + qw - 10, qy + qh - 10, false))
  assert_true app.running?
end

assert('sliding off Quit before releasing does not fire it') do
  app, = new_app
  qx, qy, = Redoku::Layout.button_rect(:quit)
  app.handle_sample(pen_sample(qx + 2, qy + 2, true))  # down on Quit
  app.handle_sample(pen_sample(qx - 3, qy + 2, false)) # released just outside
  # Travel is a handful of pixels, well under TAP_MAX_PATH, so only the
  # release landing off the button can save the game here.
  assert_true app.running?
end

assert('a tap on Level opens the picker instead of digging') do
  app, d, = new_app
  assert_equal :easy, app.difficulty
  lx, ly, lw, lh = Redoku::Layout.button_rect(:level)
  d.clear_calls
  app.handle_sample(pen_sample(lx + lw / 2, ly + lh / 2, true))
  app.handle_sample(pen_sample(lx + lw / 2, ly + lh / 2, false))
  assert_equal :levels, app.screen
  # The tier is untouched and nothing was dug — the dig belongs to a row tap,
  # not to opening the list.
  assert_equal :easy, app.difficulty
  assert_nil app.grid
  # press flash, whole-screen GC16 carrying the picker, release flash. Same
  # shape as the GAMES menu's arrival, because it is the same kind of event.
  assert_equal 3, d.updates.size
  assert_equal [lx, ly, lw, lh, RM2::DU, RM2::FAST_DRAW], d.updates[0]
  u = d.updates[1]
  assert_equal [0, 0], [u[0], u[1]]
  assert_equal [Redoku::Layout::SCREEN_W, Redoku::Layout::SCREEN_H], [u[2], u[3]]
  assert_equal RM2::GC16, u[4]
  assert_equal [lx, ly, lw, lh, RM2::DU, RM2::FAST_DRAW], d.updates[2]
end

assert('a tap on New clears the ink and repaints the board') do
  app, d, = new_app
  app.handle_sample(pen_sample(300, 400, true))
  app.handle_sample(pen_sample(340, 440, true))
  app.handle_sample(pen_sample(340, 440, false))
  d.clear_calls
  nx, ny, nw, nh = Redoku::Layout.button_rect(:new)
  app.handle_sample(pen_sample(nx + nw / 2, ny + nh / 2, true))
  app.handle_sample(pen_sample(nx + nw / 2, ny + nh / 2, false))
  bx, by, bw, bh = Redoku::Layout.board_rect
  # These GL16 board updates are the evidence that the ink was cleared: the
  # splash at updates[1] and the repainted board at updates[2], between the
  # press flash and the release flash. M1 had one of them; the splash is the
  # one M2 added, and the board repaint is still there and still last.
  assert_equal [bx, by, bw, bh, RM2::GL16, 0], d.updates[1]
  assert_equal [bx, by, bw, bh, RM2::GL16, 0], d.updates[2]
  # The gray_at only confirms draw_board's white fill covers a pixel of the
  # cell the ink was in: gray_at replays fill_rect calls, and ink is a
  # draw_line, so it never could see the ink itself.
  #
  # What it establishes, exactly: this pixel of the cell ends the press WHITE,
  # so nothing the New path draws leaves a mark on it. It does not attribute
  # that white to draw_board — draw_splash fills board_rect white first, so
  # either fill would satisfy it — and after M2 there is no probe that could,
  # because the two fills are the same colour over the same rect. The board
  # repaint's own evidence is the update at updates[2] above and the glyph
  # below.
  #
  # The probe moved INTO THAT CELL'S MARGIN for M2, and the reason is not
  # convenience: the board repaint now also draws the puzzle, and a digit's
  # 70x98 glyph is centred in the 140 px cell, so (300, 400) — 53 px into the
  # glyph box of cell (1, 1) — is a pixel draw_puzzle may legitimately
  # blacken, depending on which digit the generator dealt. The 35 px margin no
  # glyph can reach keeps this asking the question it always asked. 10 px in
  # from the cell's left edge, clear of the 1 px cell line on it.
  assert_equal 255, d.gray_at(Redoku::Layout::BOARD_X + Redoku::Layout::CELL +
                              10, 400)
  # ...and the puzzle did reach the board, so a New that quietly stopped
  # drawing it could not hide behind the white fill above. The first given of
  # the grid App now holds has a glyph inside its own cell, which draw_board's
  # grid lines cannot fake: they span the whole board, so no line rect lies
  # entirely inside one cell (see TestDisplay#glyph_in_cell?).
  # Bounded, not `while !given?`: an unbounded walk would spin off the end of
  # a hypothetical zero-clue grid instead of failing an assertion.
  first_given = nil
  Redoku::Sudoku::Grid::CELLS.times do |i|
    first_given = i if first_given.nil? && app.grid.given?(i)
  end
  assert_false first_given.nil?
  assert_true d.glyph_in_cell?(first_given)
end

assert('App#step drains every source and flushes once') do
  d = TestDisplay.new
  a = FakeInput.new([[pen_sample(300, 400, true)]])
  b = FakeInput.new([[pen_sample(320, 420, true)]])
  app = Redoku::App.new(d, [a, b], Redoku::Renderer.new(d),
                        FakeWaiter.new([a, b]), FakeSignals.new)
  app.step
  assert_equal 1, d.lines.size  # second source continued the first's stroke
  assert_equal 1, d.updates.size
end

assert('App#run paints once, then loops until Quit') do
  qx, qy, qw, qh = Redoku::Layout.button_rect(:quit)
  # The ink stroke ends with a release, as a real pen's does: without it the
  # tap on Quit would be read as that same stroke dragging on (a stroke's
  # meaning is fixed at pen-down), the loop would never be told to stop and
  # this test would spin forever.
  batches = [[pen_sample(300, 400, true), pen_sample(340, 440, true),
              pen_sample(340, 440, false)],
             [pen_sample(qx + qw / 2, qy + qh / 2, true)],
             [pen_sample(qx + qw / 2, qy + qh / 2, false)]]
  app, d, = new_app(batches)
  app.run
  assert_false app.running?
  # The stroke still inked on its way through: the drag, then the release's
  # zero-length closing stamp.
  assert_equal 2, d.lines.size
  # First update of the run is the full GC16 paint.
  assert_equal [0, 0, Redoku::Layout::SCREEN_W, Redoku::Layout::SCREEN_H,
                RM2::GC16, RM2::SYNC], d.updates[0]
end

assert('App repaints everything after a resume') do
  app, d, = new_app
  d.clear_calls
  app.handle_resume
  assert_equal [0, 0, Redoku::Layout::SCREEN_W, Redoku::Layout::SCREEN_H,
                RM2::GC16, RM2::SYNC], d.updates[0]
end

assert('App#step drops a hung-up source and stops when the last one dies') do
  app, _d, input = new_app
  input.hung_up = true
  app.step
  assert_false app.running?
end

assert('App#step keeps running while one live source remains') do
  d = TestDisplay.new
  dead = FakeInput.new
  live = FakeInput.new
  dead.hung_up = true
  waiter = FakeWaiter.new([dead, live])
  app = Redoku::App.new(d, [dead, live], Redoku::Renderer.new(d), waiter,
                        FakeSignals.new)
  app.step
  assert_true app.running?
  app.step
  assert_equal [live], waiter.calls[1][0] # and stops waiting on the dead one
end

assert('App#step waits on its current sources with the poll timeout') do
  d = TestDisplay.new
  input = FakeInput.new
  waiter = FakeWaiter.new([input])
  app = Redoku::App.new(d, [input], Redoku::Renderer.new(d), waiter,
                        FakeSignals.new)
  app.step
  assert_equal 1, waiter.calls.size
  assert_equal [[input], Redoku::App::POLL_MS], waiter.calls[0]
end

assert('App#step stops a loop that has no sources at all') do
  # Nothing to wait on means nothing will ever arrive, and wait answers
  # false immediately for an empty list, so a loop left running here would
  # spin at 100% CPU on a battery device with only SIGTERM to stop it.
  d = TestDisplay.new
  app = Redoku::App.new(d, [], Redoku::Renderer.new(d), FakeWaiter.new([]),
                        FakeSignals.new)
  app.step
  assert_false app.running?
end

assert('App#run stops when the process is asked to terminate') do
  app, d, _input, signals = new_app
  signals.terminated = true
  app.run
  assert_false app.running?
  # TWO updates, not M1's one, and both of them are startup: the opening full
  # paint, and the board flush carrying the first puzzle. The loop itself
  # still paints nothing on a turn with no input — its control flow is
  # untouched, it runs exactly one turn and stops — so the second update is
  # the first dig, which run now does BEFORE entering the loop rather than in
  # the constructor.
  assert_equal 2, d.updates.size
  assert_equal RM2::GC16, d.updates[0][4]
  bx, by, bw, bh = Redoku::Layout.board_rect
  assert_equal [bx, by, bw, bh, RM2::GL16, 0], d.updates[1]
  # And the opening paint carries the splash rather than an empty grid: the
  # first dig is the longest pause of the session, and the board is not worth
  # looking at until it is over.
  assert_false app.grid.nil?
end

assert('App#run repaints when the server resumes us') do
  app, d, _input, signals = new_app
  signals.resumed = true
  signals.terminated = true # one turn of the loop, then stop
  app.run
  # THREE updates where M1 had two. The startup pair comes first — full GC16
  # paint, then the first puzzle's GL16 board — and the resume's full repaint
  # is now the third rather than the second. The two GC16s this test is about
  # are still the first and the last thing out, with only the first puzzle
  # between them.
  assert_equal 3, d.updates.size
  assert_equal RM2::GC16, d.updates[0][4]
  assert_equal RM2::GL16, d.updates[1][4]
  assert_equal RM2::GC16, d.updates[2][4]
end

assert('a finger tap presses the button it landed on') do
  app, d, = new_touch_app
  qx, qy, qw, qh = Redoku::Layout.button_rect(:quit)
  cx = qx + qw / 2
  cy = qy + qh / 2
  s = touch_sample(cx, cy, true)
  # The helper's mapping is exact in both directions, which is what lets the
  # assertions below name the screen point they mean.
  assert_equal [cx, cy], Redoku::Touch.to_screen(s[0], s[1])
  d.clear_calls
  app.handle_touch_sample(s)
  app.handle_touch_sample(touch_sample(cx, cy, false))
  assert_false app.running?
  assert_equal [qx, qy, qw, qh, RM2::DU, RM2::FAST_DRAW], d.updates[0]
end

assert('a finger on the board inks nothing and selects nothing') do
  app, d, = new_touch_app
  d.clear_calls
  app.handle_touch_sample(touch_sample(300, 400, true))
  app.handle_touch_sample(touch_sample(340, 440, true))
  app.handle_touch_sample(touch_sample(340, 440, false))
  # Ink is the pen's alone, by the owner's instruction: a finger dragged
  # across the board draws no line, marks no damage and flushes nothing.
  assert_equal [], d.lines
  assert_nil app.ink_dirty
  app.flush_ink
  assert_equal [], d.updates
end

assert('a finger that starts off a button can never press one') do
  app, = new_touch_app
  qx, qy, qw, qh = Redoku::Layout.button_rect(:quit)
  # Same rule the pen follows: what a stroke does is decided where it went
  # down, so dragging onto Quit is not a press.
  app.handle_touch_sample(touch_sample(300, 400, true))
  app.handle_touch_sample(touch_sample(qx + qw / 2, qy + qh / 2, true))
  app.handle_touch_sample(touch_sample(qx + qw / 2, qy + qh / 2, false))
  assert_true app.running?
end

assert('a finger arriving while the pen is in proximity presses nothing') do
  app, d, = new_touch_app
  qx, qy, qw, qh = Redoku::Layout.button_rect(:quit)
  # Hovering, not writing: BTN_TOOL_PEN with no BTN_TOUCH. That is the state
  # the digitizer is in while a hand rests on the glass to write, which is
  # what makes proximity worth listening to — the palm is suppressed before
  # it has touched anything.
  app.handle_sample(pen_sample(300, 400, false))
  d.clear_calls
  app.handle_touch_sample(touch_sample(qx + qw / 2, qy + qh / 2, true))
  app.handle_touch_sample(touch_sample(qx + qw / 2, qy + qh / 2, false))
  assert_true app.running?
  assert_equal [], d.updates
end

assert('a contact born under the pen stays dead once the cooldown expires') do
  app, _d, clock = new_touch_app
  qx, qy, qw, qh = Redoku::Layout.button_rect(:quit)
  app.handle_sample(pen_sample(300, 400, false))                        # hover
  app.handle_touch_sample(touch_sample(qx + qw / 2, qy + qh / 2, true)) # palm
  app.handle_sample(pen_away_sample(300, 400))                          # set down
  clock.ms += Redoku::App::TOUCH_COOLDOWN_MS + 1
  app.handle_touch_sample(touch_sample(qx + qw / 2, qy + qh / 2, false))
  # The latch, not an instantaneous check: a palm already resting on Quit
  # when the pen was set aside is not a deliberate press, however long it
  # waits. It has to lift and press again.
  assert_true app.running?
end

assert('a finger tap inside the cooldown presses nothing') do
  app, _d, clock = new_touch_app
  qx, qy, qw, qh = Redoku::Layout.button_rect(:quit)
  app.handle_sample(pen_sample(300, 400, false))
  app.handle_sample(pen_away_sample(300, 400))
  clock.ms += Redoku::App::TOUCH_COOLDOWN_MS - 1
  app.handle_touch_sample(touch_sample(qx + qw / 2, qy + qh / 2, true))
  app.handle_touch_sample(touch_sample(qx + qw / 2, qy + qh / 2, false))
  # Proximity flickers out during ordinary writing; without the cooldown
  # each flicker is a window a palm can land in.
  assert_true app.running?
end

assert('a fresh finger tap once the cooldown has expired does press') do
  app, _d, clock = new_touch_app
  qx, qy, qw, qh = Redoku::Layout.button_rect(:quit)
  app.handle_sample(pen_sample(300, 400, false))
  app.handle_sample(pen_away_sample(300, 400))
  clock.ms += Redoku::App::TOUCH_COOLDOWN_MS
  app.handle_touch_sample(touch_sample(qx + qw / 2, qy + qh / 2, true))
  app.handle_touch_sample(touch_sample(qx + qw / 2, qy + qh / 2, false))
  # Suppression has to end, or setting the pen down and reaching for a
  # button would never work at all.
  assert_false app.running?
end

assert('a 30 px drag is a tap from a finger and not from the pen') do
  assert_true Redoku::App::TAP_MAX_PATH < 30
  assert_true Redoku::App::TOUCH_TAP_MAX_PATH >= 30
  qx, qy, qw, qh = Redoku::Layout.button_rect(:quit)
  x0 = qx + 50
  y0 = qy + qh / 2

  app, = new_touch_app
  app.handle_touch_sample(touch_sample(x0, y0, true))
  app.handle_touch_sample(touch_sample(x0 + 30, y0, true))
  app.handle_touch_sample(touch_sample(x0 + 30, y0, false))
  assert_false app.running? # a fingertip rolls; 30 px is still a tap

  # The identical drag from the pen is a drag, and the pen's own rounding
  # cannot close a 10 px gap on either side of either threshold.
  pen_app, = new_app
  pen_app.handle_sample(pen_sample(x0, y0, true))
  pen_app.handle_sample(pen_sample(x0 + 30, y0, true))
  pen_app.handle_sample(pen_sample(x0 + 30, y0, false))
  assert_true pen_app.running?
end

assert('App#step waits on pen and touch together and drains both in one turn') do
  qx, qy, qw, qh = Redoku::Layout.button_rect(:quit)
  down = touch_sample(qx + qw / 2, qy + qh / 2, true)
  up = touch_sample(qx + qw / 2, qy + qh / 2, false)
  app, d, clock, waiter, pen, finger = new_touch_app(
    [[pen_sample(300, 400, true), pen_sample(340, 440, true)],
     [pen_away_sample(340, 440)]],
    [[down, up], [], [down, up]]
  )
  app.step
  # One poll over both devices, on one timeout.
  assert_equal [[pen, finger], Redoku::App::POLL_MS], waiter.calls[0]
  assert_equal 1, d.lines.size # the pen's two samples inked one segment
  # ...and the finger's tap was drained in the same turn, suppressed by the
  # pen it shared that turn with. Had the pen list not been drained first,
  # this tap would have quit the game — which makes this the assertion that
  # both sources really were read on one turn.
  assert_true app.running?

  app.step # the pen leaves proximity, which starts the cooldown
  clock.ms += Redoku::App::TOUCH_COOLDOWN_MS
  app.step # a fresh contact, on a quiet digitizer: this one presses
  assert_false app.running?
end

assert('App#step drops a hung-up touchscreen and plays on with the pen') do
  app, _d, _clock, waiter, pen, finger = new_touch_app
  finger.hung_up = true
  app.step
  # A dead touchscreen is a game whose buttons went back to pen-only, not a
  # game that is over. A dead pen is the one that ends it.
  assert_true app.running?
  app.step
  assert_equal [pen], waiter.calls[1][0]
end

assert('a resume forgets that the pen was ever near') do
  app, _d, clock = new_touch_app
  qx, qy, qw, qh = Redoku::Layout.button_rect(:quit)
  app.handle_sample(pen_sample(300, 400, false)) # hovering: touch suppressed
  app.handle_resume
  # The display server drains the evdev backlog of a client it thaws
  # (PLAN.md §5), so the packet saying the pen left proximity is lost
  # precisely when the user switches away from the game and back. @pen_near
  # is a latch with nothing to clear it: without this reset every finger tap
  # is dead for the rest of the session, recoverable only by waving the pen
  # into range and out again, which nobody would guess.
  clock.ms += Redoku::App::TOUCH_COOLDOWN_MS
  app.handle_touch_sample(touch_sample(qx + qw / 2, qy + qh / 2, true))
  app.handle_touch_sample(touch_sample(qx + qw / 2, qy + qh / 2, false))
  assert_false app.running?
end

assert('a resume starts a fresh cooldown rather than a clean slate') do
  app, _d, clock = new_touch_app
  qx, qy, qw, qh = Redoku::Layout.button_rect(:quit)
  app.handle_sample(pen_sample(300, 400, false))
  app.handle_resume
  clock.ms += Redoku::App::TOUCH_COOLDOWN_MS - 1
  app.handle_touch_sample(touch_sample(qx + qw / 2, qy + qh / 2, true))
  app.handle_touch_sample(touch_sample(qx + qw / 2, qy + qh / 2, false))
  # A hand is quite likely to be on the glass at the moment the game comes
  # back, and the pen's next sample is the first evidence either way — so
  # the reset above must not be a licence to fire Quit immediately.
  assert_true app.running?
end

assert('a resume closes a contact whose lift packet may have been dropped') do
  app, _d, clock = new_touch_app
  qx, qy, qw, qh = Redoku::Layout.button_rect(:quit)
  # A contact opens, then the game is frozen and thawed with its lift packet
  # still in the backlog the server drains. Left open, @touch_mode routes
  # every later contact to continue_touch and no tap ever completes again.
  app.handle_touch_sample(touch_sample(300, 400, true))
  app.handle_resume
  clock.ms += Redoku::App::TOUCH_COOLDOWN_MS
  app.handle_touch_sample(touch_sample(qx + qw / 2, qy + qh / 2, true))
  app.handle_touch_sample(touch_sample(qx + qw / 2, qy + qh / 2, false))
  assert_false app.running?
end

assert('pen proximity expires when the digitizer goes silent') do
  qx, qy, qw, qh = Redoku::Layout.button_rect(:quit)
  app, _d, clock = new_touch_app(
    [], [[touch_sample(qx + qw / 2, qy + qh / 2, true),
          touch_sample(qx + qw / 2, qy + qh / 2, false)]]
  )
  app.handle_sample(pen_sample(300, 400, false)) # hovering, then silence
  clock.ms += Redoku::App::PEN_SILENCE_MS
  app.step
  # SYN_DROPPED discards a torn packet (input.c), and the packet it discards
  # can be the one that says the pen left proximity. No resume hook can see
  # that, so proximity has to be able to expire on its own too.
  assert_false app.running?
end

assert('a pen in proximity suppresses touch right up to the silence timeout') do
  qx, qy, qw, qh = Redoku::Layout.button_rect(:quit)
  app, _d, clock = new_touch_app(
    [], [[touch_sample(qx + qw / 2, qy + qh / 2, true),
          touch_sample(qx + qw / 2, qy + qh / 2, false)]]
  )
  app.handle_sample(pen_sample(300, 400, false))
  clock.ms += Redoku::App::PEN_SILENCE_MS - 1
  app.step
  # The expiry is a recovery from a LOST packet, not a licence to allow taps
  # while the pen is demonstrably about. Palm suppression is verified on
  # hardware and must not get looser by a millisecond.
  assert_true app.running?
end

assert('every pen packet restarts the silence timeout') do
  qx, qy, qw, qh = Redoku::Layout.button_rect(:quit)
  app, _d, clock = new_touch_app(
    [], [[touch_sample(qx + qw / 2, qy + qh / 2, true),
          touch_sample(qx + qw / 2, qy + qh / 2, false)]]
  )
  app.handle_sample(pen_sample(300, 400, false))
  clock.ms += Redoku::App::PEN_SILENCE_MS - 1
  app.handle_sample(pen_sample(301, 401, false)) # still hovering
  clock.ms += Redoku::App::PEN_SILENCE_MS - 1
  app.step
  # A hovering pen reports at about 100 Hz and a held hand always jitters,
  # so the deadline is measured from the LAST packet, not the first. Stamp
  # it once and a long hover would expire while the pen was still there.
  assert_true app.running?
end

assert('a finger already down when the pen arrives is latched dead') do
  app, = new_touch_app
  qx, qy, qw, qh = Redoku::Layout.button_rect(:quit)
  app.handle_touch_sample(touch_sample(qx + qw / 2, qy + qh / 2, true)) # palm
  app.handle_sample(pen_sample(300, 400, false)) # the pen reaches the glass
  app.handle_touch_sample(touch_sample(qx + qw / 2, qy + qh / 2, false))
  # Decision 2 as literally written latches at BIRTH, which leaves the palm
  # that lands a moment BEFORE the pen is detected — the same hazard. The
  # latch is re-armed on any sample taken while the pen is about, so this
  # contact is dead by the time it lifts.
  assert_true app.running?
end

assert('a contact that met the pen mid-drag stays dead after the pen leaves') do
  app, _d, clock = new_touch_app
  qx, qy, qw, qh = Redoku::Layout.button_rect(:quit)
  x0 = qx + qw / 2
  y0 = qy + qh / 2
  app.handle_touch_sample(touch_sample(x0, y0, true))     # born, pen away
  app.handle_sample(pen_sample(300, 400, false))           # pen arrives
  app.handle_touch_sample(touch_sample(x0 + 1, y0, true))  # the contact jitters
  app.handle_sample(pen_away_sample(300, 400))             # pen leaves again
  clock.ms += Redoku::App::TOUCH_COOLDOWN_MS + 1
  app.handle_touch_sample(touch_sample(x0 + 1, y0, false))
  # Only continue_touch's re-latch can keep this dead: the contact was born
  # while the pen was away, and by the lift the pen is long gone and the
  # cooldown has expired.
  #
  # Best-effort by nature, and the honest limit worth knowing: the kernel
  # drops a frame in which nothing changed, so a PERFECTLY still contact
  # emits nothing after its down packet and there is no later sample to
  # re-latch on. A resting palm jitters, and end_touch re-checks at the
  # lift, so the hole is narrow — but it is a hole, not a second rule.
  assert_true app.running?
end

# --- puzzle helpers. An App that holds a puzzle, and the two presses that
# make it hold a different one. Built on new_app and pen_sample rather than a
# parallel set, so a change to how an App is constructed lands in one place.

def test_app
  app, = new_app
  app
end

def test_app_with_display
  app, d, = new_app
  [app, d]
end

assert('App holds a generated puzzle once it has one') do
  app = test_app
  app.new_puzzle
  assert_false app.grid.nil?
  assert_true Redoku::Sudoku::Solver.unique?(app.grid.values)
  assert_true app.grid.clue_count > 0
end

assert('App does not generate a puzzle in its constructor') do
  # Generation is a search costing tens of milliseconds. Every existing App
  # test constructs one, so a generating constructor would tax the whole
  # suite and every future test.
  app = test_app
  assert_nil app.grid
end

assert('a tap on New generates a different puzzle') do
  app = test_app
  app.new_puzzle
  before = app.grid.givens_s
  press_new(app)
  assert_false app.grid.givens_s == before
  assert_true Redoku::Sudoku::Solver.unique?(app.grid.values)
end

assert('LEVEL opens the picker instead of cycling') do
  app, = new_app(generator: FakeGenerator.new)
  app.new_puzzle
  before = app.difficulty
  press_level(app)
  assert_equal :levels, app.screen
  assert_equal before, app.difficulty      # it no longer changes on press
end

assert('the picker offers exactly the five tiers, in Rater order') do
  assert_equal Redoku::Sudoku::Rater::TIERS.size, Redoku::Layout.level_rows
  # Derived and not duplicated: adding a sixth tier must not need a Layout
  # edit. Rater::TIERS is the only tier list in the tree.
  assert_equal 5, Redoku::Layout.level_rows
  assert_true Redoku::Layout.level_rows <= 9   # rows the menu band can hold
end

assert('tapping a row sets that tier and deals at it') do
  app, = new_app(generator: FakeGenerator.new)
  app.new_puzzle
  press_level(app)
  tap_menu_row(app, 3)                     # :expert, TIERS[3]
  assert_equal :expert, app.difficulty
  assert_equal :play, app.screen
end

assert('BACK leaves the picker without changing the tier or the board') do
  app, = new_app(generator: FakeGenerator.new)
  app.new_puzzle
  before_tier = app.difficulty
  before_board = app.grid.givens_s
  press_level(app)
  press_back(app)
  assert_equal :play, app.screen
  assert_equal before_tier, app.difficulty
  assert_equal before_board, app.grid.givens_s
end

assert('every tier label has a glyph for every character') do
  allowed = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -:.?'
  Redoku::Sudoku::Rater::TIERS.each do |t|
    t.to_s.upcase.each_char do |ch|
      assert_true allowed.include?(ch), "no glyph for #{ch.inspect} in #{t}"
    end
  end
end

assert('the splash reaches the panel before generation starts') do
  # The splash is the only progress indication the player gets for a pause
  # that PLAN.md §7 budgets at a few hundred ms on the Cortex-A7. If it is
  # flushed after the puzzle has been computed it is worthless.
  #
  # Counting updates afterwards CANNOT catch that, which is why this test is
  # shaped the way it is: `draw_splash; fill_board; flush_board` leaves the
  # same two board updates behind as `draw_splash; flush_board; fill_board`,
  # so every after-the-fact assertion passes either way. So the question is
  # asked from inside the dig instead — see SpyRng.
  d = TestDisplay.new
  input = FakeInput.new
  spy = SpyRng.new(d, GEN_SEED)
  app = Redoku::App.new(d, [input], Redoku::Renderer.new(d),
                        FakeWaiter.new([input]), FakeSignals.new, rng: spy,
                        log: nil)
  app.new_puzzle
  # THE EXACT COUNTS BELOW ASSUME EXACTLY ONE BAR PAINT, and this line is the
  # assumption rather than a comment about it. EASY hits on its first attempt
  # on 500 of 500 measured chains, so the hook fires once; one paint follows
  # iff that single step clears the throttle. Raise ATTEMPTS[:easy] to 60 and
  # it does not (614/61 = 10 px), the bar paints ZERO times, and every count
  # below is off by one for a reason nobody would find from the failure. So it
  # fails here, with a reason.
  assert_true Redoku::Renderer.progress_fill(
    1, 1 + Redoku::Sudoku::Generator::ATTEMPTS[:easy]
  ) >= Redoku::App::PROGRESS_STEP_PX

  # Exactly one update had reached the panel when the generator took its first
  # draw, and that update is the splash. Nought would mean the splash flush
  # had moved after the dig; more would mean something else is flushing in
  # between and this test should be told about it.
  assert_equal 1, spy.updates_at_first_draw
  bx, by, bw, bh = Redoku::Layout.board_rect
  assert_equal [bx, by, bw, bh, RM2::GL16, 0], d.updates[0]
  # Then the progress bar moved DURING the dig -- which is the other half of
  # covering the pause, and the half a splash alone cannot do.
  px, py, pw, ph = Redoku::Renderer.progress_rect
  assert_equal [px, py, pw, ph, RM2::DU, RM2::FAST_DRAW], d.updates[1]
  # ...and the board carrying the finished puzzle came last, so the splash is
  # a cover for the pause rather than the last word on it.
  assert_equal 3, d.updates.size
  assert_equal [bx, by, bw, bh, RM2::GL16, 0], d.updates[2]
  assert_false app.grid.nil?
end

assert('a new puzzle clears the ink the player had written') do
  app = test_app
  app.new_puzzle
  assert_nil app.ink_dirty
end

assert('a resume puts the puzzle back on the board it repaints') do
  app, d = test_app_with_display
  app.new_puzzle
  d.clear_calls
  app.handle_resume
  # The full repaint is still the full repaint...
  assert_equal [0, 0, Redoku::Layout::SCREEN_W, Redoku::Layout::SCREEN_H,
                RM2::GC16, RM2::SYNC], d.updates[0]
  # ...but draw_all paints an EMPTY board, so the puzzle has to go back on top
  # of it. Without that, the first suspend and resume of a session would wipe
  # the board the player was working on, and the GC16 would make the blank
  # result look deliberate.
  # Bounded, not `while !given?`: an unbounded walk would spin off the end of
  # a hypothetical zero-clue grid instead of failing an assertion.
  first_given = nil
  Redoku::Sudoku::Grid::CELLS.times do |i|
    first_given = i if first_given.nil? && app.grid.given?(i)
  end
  assert_false first_given.nil?
  assert_true d.glyph_in_cell?(first_given)
end

assert('an App given no rng seeds itself from the clock') do
  # The `rng:` keyword's DEFAULT is the production path: main.rb omits it, so
  # Rng.from_clock -- and with it Time, and with it the mruby-time dependency
  # this gem now declares -- is exercised only by an App built without one.
  # Every other App in this suite is handed a fixed seed so the suite stays
  # deterministic, which is exactly why the default needs a test of its own
  # rather than incidental coverage.
  d = TestDisplay.new
  input = FakeInput.new
  app = Redoku::App.new(d, [input], Redoku::Renderer.new(d),
                        FakeWaiter.new([input]), FakeSignals.new)
  app.new_puzzle
  assert_false app.grid.nil?
  assert_true Redoku::Sudoku::Solver.unique?(app.grid.values)
end

# --- generation: the two failure paths, and the bar that covers the tail.
#
# THE DISTINCTION THESE TESTS EXIST FOR: a tier MISS is bad luck and retries
# without limit, while a FAULT -- a raise, or a nil reply -- is the engine
# producing nothing at all and retries a bounded few times. Conflating them
# turns an engine bug into an infinite loop behind a splash on a device whose
# only escape is the power button.

# Records the lines App writes about generation, so the attempt count can be
# asserted rather than assumed. Stands in for $stderr.
class FakeLog
  attr_reader :lines

  def initialize
    @lines = []
  end

  def puts(line)
    @lines << line
    nil
  end
end

# A generator that misses the requested tier a fixed number of times and then
# hits it. The only way to drive App's unbounded retry without an unbounded
# test: a real generator either succeeds by luck or hangs.
class MissingGenerator < FakeGenerator
  # `progress:` is threaded through rather than poked in from outside
  # afterwards. An earlier draft did `gen.instance_variable_set(:@progress,
  # true)`, which works (mruby-metaprog is declared) but is a test reaching
  # around a collaborator's own constructor because that constructor forgot an
  # argument. Fixing the interface is the cheaper repair.
  def initialize(misses, progress: false)
    super(progress: progress)
    @misses = misses
  end

  def generate(tier, rng, attempts = nil, &block)
    out = super(tier, rng, attempts, &block)
    return out if @calls > @misses
    # An honest reply naming a tier it ACTUALLY reached, which is what a missed
    # request looks like: never a wrong label. NEVER the requested tier, which
    # is why this is conditional -- an earlier draft always answered :easy, so a
    # "miss" at the default difficulty of :easy was a HIT and every retry test
    # built on it passed while turning the loop exactly once.
    out.store(:tier, tier == :easy ? :medium : :easy)
    out
  end
end

# Puts App at `tier` directly, which is how a test gets there -- @difficulty
# has no setter because the player reaches tiers through the LEVEL picker, and
# walking there would mean dealing a puzzle per stop (the picker's whole
# point).
#
# instance_variable_set rather than a public seam on App: this is a test
# reaching into a test's own subject for one line, not an API anyone ships.
def difficulty_to(app, tier)
  unless Redoku::Sudoku::Rater::TIERS.include?(tier)
    raise "no such difficulty: #{tier}"
  end
  app.instance_variable_set(:@difficulty, tier)
  app
end

assert('a missed tier is asked for again, without limit') do
  # Get to :master on a generator that HITS, so the four cycling digs do not
  # land in the counts below, then swap in the misser and a fresh recorder.
  # instance_variable_set rather than a public seam on App: this is a test
  # reaching into a test's own subject for one line, not an API anyone ships.
  app, = new_app(generator: FakeGenerator.new, log: FakeLog.new)
  difficulty_to(app, :master)

  gen = MissingGenerator.new(4)
  log = FakeLog.new
  app.instance_variable_set(:@generator, gen)
  app.instance_variable_set(:@log, log)
  app.new_puzzle

  # Five rounds: four misses and the hit. No fallback to an easier tier and no
  # wrong label -- the board on the glass is a MASTER board or the search is
  # still running.
  assert_equal(5, gen.calls)
  assert_equal(:master, app.achieved_tier)
  assert_false app.grid.nil?
  # The rounds are logged, so the real distribution becomes visible in play
  # instead of staying a bootstrap estimate.
  assert_equal(1, log.lines.size)
  assert_true log.lines[0].include?('MASTER')
  assert_true log.lines[0].include?('5 rounds')
end

assert('a generation that raises is retried a few times, then the board is kept') do
  # THE DISTINCTION THAT MATTERS. A tier miss is bad luck and retries for ever;
  # an exception is a fault and must not, or an engine bug becomes a hang on a
  # device whose only escape is the power button.
  broken = FakeGenerator.new(fail_with: 'dig exploded')
  log = FakeLog.new
  app, = new_app(generator: broken, log: log)
  app.new_puzzle          # nothing dug yet, so there is nothing to keep

  assert_equal(Redoku::App::GENERATE_TRIES, broken.calls)
  assert_nil app.grid
  # THE LAST LINE IS THE GIVE-UP, NOT THE FAULT. attempt_generation logs one
  # 'generation failed (...)' per fault and search_for_puzzle logs 'gave up'
  # after the last of them, so 'dig exploded' is second from the end.
  assert_equal(Redoku::App::GENERATE_TRIES + 1, log.lines.size)
  assert_true log.lines[log.lines.size - 1].include?('gave up')
  assert_true log.lines[log.lines.size - 2].include?('dig exploded')
  log.lines.each_with_index do |line, i|
    assert_true line.include?('dig exploded') if i < Redoku::App::GENERATE_TRIES
  end

  # And with a puzzle already on the board, THAT puzzle survives the fault --
  # which is the half of the behaviour a fresh App cannot show.
  app2, = new_app(generator: FakeGenerator.new, log: FakeLog.new)
  app2.new_puzzle
  before = app2.grid.givens_s
  app2.instance_variable_set(:@generator, broken)
  app2.send(:fill_board)
  assert_equal(before, app2.grid.givens_s)
end

assert('a generator that finds nothing at all is treated as a fault, not as luck') do
  # generate answers nil only when no attempt produced a single logically
  # solvable board. That is the same kind of event as a raise -- the engine
  # produced nothing -- so it takes the BOUNDED path. Retrying it for ever
  # would leave a player staring at a splash.
  empty = FakeGenerator.new(answer_nil: true)
  log = FakeLog.new
  app, d, = new_app(generator: empty, log: log)
  app.new_puzzle
  assert_equal(Redoku::App::GENERATE_TRIES, empty.calls)
  # Nothing was ever dug, so there is no puzzle to keep -- and the board is
  # painted empty rather than left showing the splash, which is where this
  # differs from the guard that landed in 75eb7cf. See App#fill_board.
  assert_nil app.grid
  bx, by, bw, bh = Redoku::Layout.board_rect
  assert_equal [bx, by, bw, bh, RM2::GL16, 0], d.updates[d.updates.size - 1]
  # A nil reply is not an exception, so nothing logs a 'failed' line -- only the
  # give-up. Worth pinning: it is what distinguishes the two bounded paths in
  # the log a device run will actually produce.
  assert_equal(1, log.lines.size)
  assert_true log.lines[0].include?('gave up')
end

assert('the progress bar does not reset between retries') do
  gen = MissingGenerator.new(2, progress: true)
  d = TestDisplay.new
  app = Redoku::App.new(d, [FakeInput.new], Redoku::Renderer.new(d),
                        FakeWaiter.new([]), FakeSignals.new,
                        rng: Redoku::Rng.new(GEN_SEED), generator: gen,
                        log: nil)
  app.new_puzzle

  # Every bar repaint, in order, as the x-extent of its filled rect. A long
  # wait that started over would read as a hang, and the top rung's tail is an
  # expected path rather than an exception.
  bx, by, = Redoku::Renderer.progress_rect
  fills = []
  d.rects.each do |x, y, w, _h, gray|
    fills << w if gray == 0 && x == bx + Redoku::Renderer::PROGRESS_BORDER &&
                  y == by + Redoku::Renderer::PROGRESS_BORDER
  end
  assert_true fills.size >= 2
  i = 1
  while i < fills.size
    assert_true fills[i] >= fills[i - 1]
    i += 1
  end
  # And it never claims to be finished, because it never is until the board
  # replaces it.
  assert_true fills[fills.size - 1] <
              Redoku::Renderer::PROGRESS_W - 2 * Redoku::Renderer::PROGRESS_BORDER
end

assert('the bar is painted at most once per visible step') do
  gen = FakeGenerator.new(progress: true, attempts: 150)
  d = TestDisplay.new
  app = Redoku::App.new(d, [FakeInput.new], Redoku::Renderer.new(d),
                        FakeWaiter.new([]), FakeSignals.new,
                        rng: Redoku::Rng.new(GEN_SEED), generator: gen,
                        log: nil)
  app.new_puzzle
  # E-ink updates are not free: DU + FAST_DRAW is the cheap two-level
  # waveform and still costs tens of milliseconds, and MASTER's budget fires
  # the hook up to 150 times per round. Painting per attempt would add 150
  # refreshes and could double a HARD dig.
  bx, by, = Redoku::Renderer.progress_rect
  bar = d.updates.reject { |u| u[0] != bx || u[1] != by }
  assert_true bar.size <= 25
  assert_true bar.size >= 2
  bar.each { |u| assert_equal(RM2::DU, u[4]) }
end

# --- persistence (M3a Tasks 2 and 3). A real Store over real SQLite, in tmp
# files; the dig stays a FakeGenerator deal. App takes `store:` exactly like
# `generator:`, so these tests drive the same seam the device binary does.

def app_store_db(name)
  '/tmp/redoku_mrbtest_app_' + name + '.db'
end

def remove_app_db(path)
  [path, path + '-journal'].each { |f| File.delete(f) if File.exist?(f) }
end

# Answers every call with a fault, so a test can prove that a broken store
# costs saves and never the game.
class ExplodingStore
  def save_autosave(_game)
    raise 'disk gone'
  end

  def autosave
    nil
  end

  def closed?
    false
  end

  def close
    nil
  end
end

assert('a successful dig writes an autosave row') do
  path = app_store_db('dig')
  remove_app_db(path)
  store = Redoku::Store.open(path, log: nil)
  app, = new_app(store: store)
  app.new_puzzle
  rec = store.autosave
  assert_false rec.nil?
  assert_equal(app.grid.givens_s, rec[:givens])
  assert_equal('.' * 81, rec[:entries])
  assert_equal(:easy, rec[:difficulty])
  assert_equal(app.achieved_tier, rec[:achieved_tier])
  assert_equal(rec[:id], app.current_save_id)
  store.close
  remove_app_db(path)
end

assert('a failing store costs saves, not the game') do
  app, = new_app(store: ExplodingStore.new)
  app.new_puzzle
  assert_false app.grid.nil?
  assert_nil app.current_save_id
end

assert('an App without a store still digs') do
  app, = new_app(store: nil)
  app.new_puzzle
  assert_false app.grid.nil?
  assert_nil app.current_save_id
end

assert('quitting by button persists the autosave and closes the store') do
  path = app_store_db('quit')
  remove_app_db(path)
  store = Redoku::Store.open(path, log: nil)
  qx, qy, qw, qh = Redoku::Layout.button_rect(:quit)
  batches = [[pen_sample(qx + qw / 2, qy + qh / 2, true),
              pen_sample(qx + qw / 2, qy + qh / 2, false)]]
  app, = new_app(batches, store: store)
  app.run
  assert_false app.running?
  # Shutdown ran inside run, after the loop — the same code a SIGTERM walks.
  assert_true store.closed?

  reopened = Redoku::Store.open(path, log: nil)
  rec = reopened.autosave
  assert_false rec.nil?
  assert_equal(app.grid.givens_s, rec[:givens])
  reopened.close
  remove_app_db(path)
end

assert('SIGTERM persists the game and closes the store too') do
  path = app_store_db('term')
  remove_app_db(path)
  store = Redoku::Store.open(path, log: nil)
  app, _d, _input, signals = new_app(store: store)
  signals.terminated = true # one turn of the loop, then stop
  app.run
  assert_false app.running?
  assert_true store.closed?

  reopened = Redoku::Store.open(path, log: nil)
  assert_false reopened.autosave.nil?
  reopened.close
  remove_app_db(path)
end

assert('New overwrites the autosave and writes no manual copy') do
  path = app_store_db('new')
  remove_app_db(path)
  store = Redoku::Store.open(path, log: nil)
  app, = new_app(generator: FakeGenerator.new, store: store)
  app.new_puzzle
  press_new(app)
  list = store.games
  assert_equal(1, list.size)
  assert_equal(:autosave, list[0][:kind])
  assert_equal(app.grid.givens_s, store.autosave[:givens])
  store.close
  remove_app_db(path)
end

assert('a fresh App resumes the saved game instead of digging') do
  path = app_store_db('resume')
  remove_app_db(path)

  store1 = Redoku::Store.open(path, log: nil)
  gen1 = FakeGenerator.new
  app1, _d1, _in1, signals1 = new_app(generator: gen1, store: store1)
  app1.new_puzzle
  signals1.terminated = true
  app1.run
  assert_true store1.closed?

  store2 = Redoku::Store.open(path, log: nil)
  gen2 = FakeGenerator.new
  app2, d2, _in2, signals2 = new_app(generator: gen2, store: store2)
  signals2.terminated = true
  app2.run

  # The SAME puzzle, tier for tier, dug ZERO times.
  assert_equal(app1.grid.givens_s, app2.grid.givens_s)
  assert_equal(app1.difficulty, app2.difficulty)
  assert_equal(app1.achieved_tier, app2.achieved_tier)
  assert_equal(0, gen2.calls)
  assert_equal(app1.grid.givens_s[0], app2.grid.givens_s[0])
  assert_equal(1, d2.updates.size)
  assert_equal([0, 0, Redoku::Layout::SCREEN_W, Redoku::Layout::SCREEN_H,
                RM2::GC16, RM2::SYNC], d2.updates[0])
  first_given = nil
  Redoku::Sudoku::Grid::CELLS.times do |i|
    first_given = i if first_given.nil? && app2.grid.given?(i)
  end
  assert_false first_given.nil?
  assert_true d2.glyph_in_cell?(first_given)
  assert_true store2.closed?
  remove_app_db(path)
end

# --- the GAMES menu (M3a Task 4). Driven through real taps on real rects,
# exactly like every button test above, against a real Store over a tmp DB
# where one is needed. The renderer's own suite covers what the menu looks
# like; these cover what it DOES.

def game_record(givens, tier, entries = '.' * 81)
  { difficulty: tier, achieved_tier: tier,
    givens: givens, entries: entries, solution: SOLVED_81 }
end

def games_store_db(name)
  '/tmp/redoku_mrbtest_menu_' + name + '.db'
end

assert('pressing GAMES opens the saves menu') do
  app, d, = new_app
  gx, gy, gw, gh = Redoku::Layout.button_rect(:games)
  d.clear_calls
  tap_button(app, :games)
  assert_equal :menu, app.screen
  # Press flash at the button, then the whole-screen GC16 the menu arrives
  # in — the same full paint a mode change deserves.
  assert_equal [gx, gy, gw, gh, RM2::DU, RM2::FAST_DRAW], d.updates[0]
  assert_equal [0, 0, Redoku::Layout::SCREEN_W, Redoku::Layout::SCREEN_H,
                RM2::GC16, RM2::SYNC], d.updates[1]
end

assert('BACK leaves the menu and repaints the board') do
  app, d, = new_app
  tap_button(app, :games)
  assert_equal :menu, app.screen
  d.clear_calls
  tap_menu_action(app, :back)
  assert_equal :play, app.screen
  # BACK's action is close_menu: press flash first, then a full play-mode
  # repaint, and the release flash lands on a button that is NEW again by
  # the time it flushes.
  assert_equal [0, 0, Redoku::Layout::SCREEN_W, Redoku::Layout::SCREEN_H,
                RM2::GC16, RM2::SYNC], d.updates[1]
  nx, ny, nw, nh = Redoku::Layout.button_rect(:new)
  assert_equal [nx, ny, nw, nh, RM2::DU, RM2::FAST_DRAW],
               d.updates[d.updates.size - 1]
end

assert('the GAMES menu is not a writing surface') do
  app, d, = new_app
  tap_button(app, :games)
  d.clear_calls
  app.handle_sample(pen_sample(300, 400, true))
  app.handle_sample(pen_sample(340, 440, true))
  app.handle_sample(pen_sample(380, 480, false))
  # The board area means rows while the menu is up, so pen strokes there
  # are taps-or-drags on the list, never ink — and never erasure either.
  assert_equal [], d.lines
  assert_nil app.ink_dirty
  assert_equal :menu, app.screen
end

assert('tapping a row loads that game and returns to the board') do
  path = games_store_db('load')
  remove_app_db(path)
  store = Redoku::Store.open(path, log: nil)
  # cell 0 is blank in EASY_81, so its entry is one this load can replay
  entries = '1' + '.' * 80
  id = store.save_manual(game_record(EASY_81, :easy, entries))
  app, d, = new_app(store: store)
  assert_nil app.grid

  tap_button(app, :games)
  tap_menu_row(app, 0)

  assert_equal :play, app.screen
  assert_false app.grid.nil?
  assert_equal EASY_81, app.grid.givens_s
  assert_equal id, app.current_save_id
  assert_equal :easy, app.difficulty
  assert_equal 1, app.grid.value_at(0)      # the entry came back too
  assert_false app.grid.given?(0)
  # The load announces itself with a full repaint, like every other return
  # to the board.
  assert_equal [0, 0, Redoku::Layout::SCREEN_W, Redoku::Layout::SCREEN_H,
                RM2::GC16, RM2::SYNC], d.updates[d.updates.size - 1]
  store.close
  remove_app_db(path)
end

assert('DEL arms, and the next row tap deletes instead of loading') do
  path = games_store_db('del')
  remove_app_db(path)
  store = Redoku::Store.open(path, log: nil)
  id1 = store.save_manual(game_record(EASY_81, :easy))
  store.save_manual(game_record(UNIQUE_81, :easy))
  app, d, = new_app(store: store)

  tap_button(app, :games)
  lx, ly, lw, lh = Redoku::Layout.button_rect(:level)
  d.clear_calls
  tap_menu_action(app, :del)
  assert_equal :menu, app.screen
  # The armed state IS the label sitting inverted, painted by refresh_menu
  # itself — persistent feedback, not a transient flash.
  assert_equal 0, d.gray_at(lx + 10, ly + lh / 2)

  tap_menu_row(app, 0)
  list = store.games
  # One save is gone. WHICH one is not pinned: both rows were written in
  # the same second, so their updated_at tie leaves the order Store#games
  # answers legitimately free — the subject here is the deletion, not the
  # sort.
  assert_equal 1, list.size
  survivor = store.load(list[0][:id])
  assert_true list[0][:id] == id1 || survivor[:givens] == UNIQUE_81
  # One tap spent the mode: the label came back up...
  assert_equal 255, d.gray_at(lx + 10, ly + lh / 2)
  # ...and the player is still in the menu, looking at what is left.
  assert_equal :menu, app.screen
  store.close
  remove_app_db(path)
end

assert('SAVE writes a manual copy of the current game') do
  path = games_store_db('save')
  remove_app_db(path)
  store = Redoku::Store.open(path, log: nil)
  app, = new_app(store: store)
  app.new_puzzle
  givens_before = app.grid.givens_s

  tap_button(app, :games)
  tap_menu_action(app, :save)

  manual = store.games.select { |g| g[:kind] == :manual }
  assert_equal 1, manual.size
  rec = store.load(manual[0][:id])
  assert_equal givens_before, rec[:givens]
  assert_equal app.difficulty, rec[:difficulty]
  # The autosave singleton keeps its own life beside the bookmark.
  assert_false store.autosave.nil?
  assert_equal :menu, app.screen
  store.close
  remove_app_db(path)
end

# True when any dark pixel sits inside a menu row's rect: the row is showing
# text, not the blank white the empty list leaves behind.
def menu_row_inked?(d, rect)
  x, y, w, h = rect
  py = y
  while py < y + h
    px = x
    while px < x + w
      g = d.gray_at(px, py)
      return true if g && g < 128
      px += 6
    end
    py += 3
  end
  false
end

assert('SAVE repaints the list so the new copy appears on the glass') do
  path = games_store_db('save-refresh')
  remove_app_db(path)
  store = Redoku::Store.open(path, log: nil)
  app, d, = new_app(store: store)
  app.new_puzzle

  tap_button(app, :games)
  second_row = Redoku::Layout.menu_row_rect(1)  # only the autosave exists yet
  assert_equal false, menu_row_inked?(d, second_row)

  tap_menu_action(app, :save)   # writes the manual copy AND must repaint

  assert_equal :menu, app.screen
  assert_equal true, menu_row_inked?(d, second_row)
  store.close
  remove_app_db(path)
end

# Plants `n` manual rows with DISTINCT pinned timestamps, so Store#games'
# updated_at DESC order — and therefore which record sits at each list
# position — is deterministic. Written raw rather than through save_manual,
# whose rows would all land inside one second and leave the sort free.
def plant_manual_rows(path, n)
  seeder = Redoku::Store.open(path, log: nil)
  seeder.close
  raw = SQLite3::Database.open(path)
  boards = [EASY_81, UNIQUE_81]
  dots = '.' * 81
  n.times do |i|
    ts = 1000 + i
    raw.execute(
      'INSERT INTO games (kind, difficulty, achieved_tier, givens, entries, ' \
      "solution, created_at, updated_at) VALUES ('manual', 'easy', 'easy', " \
      "'#{boards[i % 2]}', '#{dots}', '#{SOLVED_81}', #{ts}, #{ts})")
  end
  raw.close
end

assert('PREV/NEXT appear for a long list and page two loads EXACTLY its rows') do
  path = games_store_db('page')
  remove_app_db(path)
  plant_manual_rows(path, 11)          # page one: 9 rows, page two: 2
  store = Redoku::Store.open(path, log: nil)
  ordered = store.games                # position p holds the 10-p th plant
  assert_equal(11, ordered.size)
  app, d, = new_app(store: store)

  tap_button(app, :games)
  nx, ny, nw, nh = Redoku::Layout.menu_button_rect(:next)
  assert_equal 0, d.gray_at(nx, ny)             # NEXT framed: 11 > 9 per page

  tap_pen_at(app, nx + nw / 2, ny + nh / 2)     # onto page two
  assert_equal(1, app.instance_variable_get(:@page))

  # The row shows list position 9 (page offset 1 * 9 rows + row 0), and the
  # load must reach exactly that record — not position 0 of the full list,
  # which is what a page-local index into games_list would fetch.
  tap_menu_row(app, 0)
  assert_equal :play, app.screen
  assert_equal(ordered[9][:id], app.current_save_id)
  assert_equal(store.load(ordered[9][:id])[:givens], app.grid.givens_s)

  # Row 1 of the same page is position 10, not 9 again.
  tap_button(app, :games)                       # reopens at @page = 0
  tap_pen_at(app, nx + nw / 2, ny + nh / 2)
  tap_menu_row(app, 1)
  assert_equal :play, app.screen
  assert_equal(ordered[10][:id], app.current_save_id)
  assert_equal(store.load(ordered[10][:id])[:givens], app.grid.givens_s)
  assert_true store.load(ordered[10][:id])[:givens] !=
              store.load(ordered[9][:id])[:givens]      # pinned, not luck
  store.close
  remove_app_db(path)
end

assert("DEL on page two deletes EXACTLY the row it shows, not page one's") do
  path = games_store_db('del_page')
  remove_app_db(path)
  plant_manual_rows(path, 11)
  store = Redoku::Store.open(path, log: nil)
  ordered = store.games
  app, = new_app(store: store)

  tap_button(app, :games)
  nx, ny, nw, nh = Redoku::Layout.menu_button_rect(:next)
  tap_pen_at(app, nx + nw / 2, ny + nh / 2)     # onto page two

  # An out-of-range tap (this page shows only two of MENU_ROWS rows) is a
  # no-op: still in the menu, nothing deleted.
  tap_menu_row(app, 5)
  assert_equal :menu, app.screen
  assert_equal(11, store.games.size)

  tap_menu_action(app, :del)                    # arm DEL
  tap_menu_row(app, 0)                          # displays list position 9
  left = store.games
  assert_equal(10, left.size)
  # Position 9 went — not position 0, which a page-local index would have
  # hit, and not its neighbour either.
  assert_true(left.none? { |g| g[:id] == ordered[9][:id] })
  assert_true(left.any? { |g| g[:id] == ordered[0][:id] })
  assert_true(left.any? { |g| g[:id] == ordered[8][:id] })
  store.close
  remove_app_db(path)
end

assert('an empty list ignores row taps and stays in the menu') do
  path = games_store_db('empty')
  remove_app_db(path)
  store = Redoku::Store.open(path, log: nil)
  app, = new_app(store: store)
  tap_button(app, :games)
  tap_menu_row(app, 4)
  assert_equal :menu, app.screen
  assert_true app.running?
  store.close
  remove_app_db(path)
end

# --- stroke persistence (M3a Task 6). Ink is journaled per completed
# stroke, replayed on every repaint, and dies with its game row. Driven the
# same way as every test above: real samples through handle_sample, a real
# Store over a tmp DB.

def stroke_app_db(name)
  '/tmp/redoku_mrbtest_strokes_' + name + '.db'
end

# Draws one three-sample ink stroke and returns the screen points it produced.
def draw_ink_stroke(app, d)
  s1 = pen_sample(300, 400, true)
  s2 = pen_sample(340, 440, true)
  s3 = pen_sample(340, 440, false) # lift: repeats the position
  app.handle_sample(s1)
  app.handle_sample(s2)
  app.handle_sample(s3)
  [screen_of(s1), screen_of(s2), screen_of(s3)]
end

assert('a completed ink stroke is journaled to the store immediately') do
  path = stroke_app_db('journal')
  remove_app_db(path)
  store = Redoku::Store.open(path, log: nil)
  app, d, = new_app(store: store)
  app.new_puzzle
  sid = app.current_save_id
  assert_false sid.nil?

  pts = draw_ink_stroke(app, d)

  got = store.strokes(sid)
  assert_equal 1, got.size
  assert_equal Redoku::App::INK_GRAY, got[0][:color]
  assert_equal Redoku::App::INK_WIDTH, got[0][:width]
  # Replay data identical to what was drawn: same points, same order — the
  # closing zero-length segment records its (repeated) endpoint like any
  # other sample, which replays as a line of no length.
  assert_equal [[pts[0], pts[1], pts[2]]], got[0][:subpaths]

  # A stroke drawn BEFORE any dig exists buffers in memory only...
  app2, d2, = new_app(store: store)
  draw_ink_stroke(app2, d2)
  assert_equal 1, app2.ink_strokes.size
  assert_equal [], store.strokes(nil)

  # ...and dies with the unsaved board at the first dig, exactly as its ink
  # died on the glass under the splash.
  app2.new_puzzle
  assert_equal [], app2.ink_strokes
  assert_false app2.current_save_id.nil?
  assert_equal [], store.strokes(app2.current_save_id)
  store.close
  remove_app_db(path)
end

assert('a stroke that left the board journals two subpaths') do
  path = stroke_app_db('gap')
  remove_app_db(path)
  store = Redoku::Store.open(path, log: nil)
  app, d, = new_app(store: store)
  app.new_puzzle
  s1 = pen_sample(300, 400, true)
  s2 = pen_sample(340, 440, true)
  s3 = pen_sample(340, 1600, true)  # dragged off the board
  s4 = pen_sample(380, 480, true)   # back on
  s5 = pen_sample(400, 500, false)  # lifted on the board
  [s1, s2, s3, s4].each { |s| app.handle_sample(s) }
  app.handle_sample(s5)
  p1 = screen_of(s1)
  p2 = screen_of(s2)
  p4 = screen_of(s4)
  p5 = screen_of(s5)
  got = store.strokes(app.current_save_id)
  assert_equal 1, got.size
  # The off-board excursion is a GAP: two subpaths, and replay must never
  # bridge it.
  subs = got[0][:subpaths]
  assert_equal 2, subs.size
  assert_equal [p1, p2], subs[0]
  assert_equal p4, subs[1][0]
  assert_equal p5, subs[1][1]
  store.close
  remove_app_db(path)
end

assert('New clears the persisted strokes along with the ink') do
  path = stroke_app_db('new_clears')
  remove_app_db(path)
  store = Redoku::Store.open(path, log: nil)
  app, d, = new_app(store: store)
  app.new_puzzle
  sid = app.current_save_id
  draw_ink_stroke(app, d)
  assert_equal 1, store.strokes(sid).size

  press_new(app)
  assert_equal sid, app.current_save_id   # stable id, fresh board
  assert_equal [], app.ink_strokes
  assert_equal [], store.strokes(sid)

  # And dealing from the LEVEL picker is a New underneath, so it clears too:
  # open the picker, tap row 0 (:easy), and the dig wipes the journal.
  draw_ink_stroke(app, d)
  press_level(app)
  assert_equal :levels, app.screen
  tap_menu_row(app, 0)
  assert_equal :play, app.screen
  assert_equal [], store.strokes(app.current_save_id)
  store.close
  remove_app_db(path)
end

assert('SAVE copies the strokes into the manual copy') do
  path = stroke_app_db('save_copies')
  remove_app_db(path)
  store = Redoku::Store.open(path, log: nil)
  app, d, = new_app(store: store)
  app.new_puzzle
  pts = draw_ink_stroke(app, d)

  tap_button(app, :games)
  tap_menu_action(app, :save)

  manual = store.games.select { |g| g[:kind] == :manual }
  assert_equal 1, manual.size
  got = store.strokes(manual[0][:id])
  assert_equal 1, got.size
  assert_equal [[pts[0], pts[1], pts[2]]], got[0][:subpaths]
  # The autosave keeps its own copy too.
  assert_equal 1, store.strokes(app.current_save_id).size
  store.close
  remove_app_db(path)
end

assert('loading a save replays its ink onto the board') do
  path = stroke_app_db('load_replay')
  remove_app_db(path)
  store = Redoku::Store.open(path, log: nil)
  id = store.save_manual(game_record(EASY_81, :easy))
  store.journal_stroke(id, Redoku::App::INK_GRAY, Redoku::App::INK_WIDTH,
                       [[[200, 300], [220, 320]], [[240, 340], [260, 360]]])
  app, d, = new_app(store: store)

  tap_button(app, :games)
  d.clear_calls
  tap_menu_row(app, 0)

  assert_equal :play, app.screen
  assert_equal id, app.current_save_id
  assert_equal 1, app.ink_strokes.size
  # The replay went through the SAME painter live drawing uses: one polyline
  # per subpath, at the journal's width and gray — and never a segment
  # bridging the gap between the two subpaths.
  assert_equal [[200, 300, 220, 320, Redoku::App::INK_WIDTH,
                 Redoku::App::INK_GRAY],
                [240, 340, 260, 360, Redoku::App::INK_WIDTH,
                 Redoku::App::INK_GRAY]], d.lines
  store.close
  remove_app_db(path)
end

assert('resume-on-launch brings the ink back with the board') do
  path = stroke_app_db('resume_ink')
  remove_app_db(path)

  store1 = Redoku::Store.open(path, log: nil)
  app1, d1, _in1, signals1 = new_app(store: store1)
  app1.new_puzzle
  pts = draw_ink_stroke(app1, d1)
  signals1.terminated = true
  app1.run   # SIGTERM path: refreshes the autosave row, keeps the strokes
  assert_true store1.closed?

  store2 = Redoku::Store.open(path, log: nil)
  app2, d2, _in2, signals2 = new_app(store: store2)
  signals2.terminated = true
  d2.clear_calls
  app2.run

  # Same puzzle AND the same marks on it, replayed before the single GC16.
  assert_equal app1.grid.givens_s, app2.grid.givens_s
  assert_equal 1, app2.ink_strokes.size
  assert_equal [[pts[0], pts[1], pts[2]]],
               app2.ink_strokes[0][:subpaths]
  # The replayed polyline: the real segment and the closing zero-length one,
  # exactly as live drawing drew them.
  assert_equal [[pts[0][0], pts[0][1], pts[1][0], pts[1][1],
                 Redoku::App::INK_WIDTH, Redoku::App::INK_GRAY],
                [pts[1][0], pts[1][1], pts[2][0], pts[2][1],
                 Redoku::App::INK_WIDTH, Redoku::App::INK_GRAY]], d2.lines
   assert_equal [0, 0, Redoku::Layout::SCREEN_W, Redoku::Layout::SCREEN_H,
                 RM2::GC16, RM2::SYNC], d2.updates[0]
  store2.close
  remove_app_db(path)
end

# --- erase persistence (M3b Task 3). The M3a plan claimed the eraser needed
# no journal entry because it "repaints cells from the model, so a reload
# restores erased cells correctly by simply not having those strokes"
# (docs/plans/2026-08-25-m3-sqlite-saves.md, Task 6). The stroke was already
# journaled at pen-lift, before the eraser came, so it did have one. These
# two assertions are the proof and the guard.

assert('erasing a cell removes its stroke from the journal') do
  path = stroke_app_db('erase_journal')
  remove_app_db(path)
  store = Redoku::Store.open(path, log: nil)
  app, d, = new_app(store: store)
  app.new_puzzle
  sid = app.current_save_id
  assert_false sid.nil?

  draw_ink_stroke(app, d)              # cell (1,1), screen (300,400)..(340,440)
  assert_equal 1, store.strokes(sid).size

  app.handle_sample(eraser_sample(300, 400, true))
  app.handle_sample(eraser_sample(300, 400, false))

  assert_equal 0, store.strokes(sid).size
  assert_equal 0, app.ink_strokes.size
  store.close
  remove_app_db(path)
end

assert('an erased stroke is not replayed after a relaunch') do
  path = stroke_app_db('erase_reload')
  remove_app_db(path)

  store1 = Redoku::Store.open(path, log: nil)
  app1, d1, _in1, signals1 = new_app(store: store1)
  app1.new_puzzle
  draw_ink_stroke(app1, d1)
  app1.handle_sample(eraser_sample(300, 400, true))
  app1.handle_sample(eraser_sample(300, 400, false))
  signals1.terminated = true
  app1.run
  assert_true store1.closed?

  store2 = Redoku::Store.open(path, log: nil)
  app2, _d2, _in2, signals2 = new_app(store: store2)
  signals2.terminated = true
  app2.run                             # resume-on-launch happens inside run
  assert_equal 0, app2.ink_strokes.size
  remove_app_db(path)
end

assert('erasing one cell leaves a neighbour cell ink alone') do
  # The fix must be cell-scoped, not "clear the journal". Two strokes in
  # two cells, erase one, the other survives in memory AND on disk.
  path = stroke_app_db('erase_neighbour')
  remove_app_db(path)
  store = Redoku::Store.open(path, log: nil)
  app, = new_app(store: store)
  app.new_puzzle
  sid = app.current_save_id

  app.handle_sample(pen_sample(300, 400, true))   # cell (1,1)
  app.handle_sample(pen_sample(320, 420, true))
  app.handle_sample(pen_sample(320, 420, false))
  app.handle_sample(pen_sample(300, 540, true))   # cell (1,2), one row down
  app.handle_sample(pen_sample(320, 560, true))
  app.handle_sample(pen_sample(320, 560, false))
  assert_equal 2, store.strokes(sid).size

  app.handle_sample(eraser_sample(300, 400, true))
  app.handle_sample(eraser_sample(300, 400, false))

  assert_equal 1, store.strokes(sid).size
  assert_equal 1, app.ink_strokes.size
  survivor = Redoku::Sudoku::Grid.index_of(1, 2)
  assert_equal survivor, Redoku::Ink.cell_of(app.ink_strokes[0])
  store.close
  remove_app_db(path)
end

# A store whose autosave upsert fails ONCE on command — answering nil, the
# way the real Store does for an invalid record or a database error — then
# behaves. Everything else delegates to the real store it wraps, so strokes
# and reads stay real.
class FailOnceAutosaveStore
  attr_accessor :fail_next

  def initialize(real)
    @real = real
    @fail_next = false
  end

  def save_autosave(game)
    return nil if @fail_next
    @real.save_autosave(game)
  end

  def autosave
    @real.autosave
  end

  def journal_stroke(id, color, width, subpaths)
    @real.journal_stroke(id, color, width, subpaths)
  end

  def strokes(id)
    @real.strokes(id)
  end

  def clear_strokes(id)
    @real.clear_strokes(id)
  end

  def closed?
    @real.closed?
  end

  def close
    @real.close
  end
end

assert('a failed autosave keeps the current save id and the stroke journal on it') do
  path = app_store_db('flaky')
  remove_app_db(path)
  real = Redoku::Store.open(path, log: nil)
  flaky = FailOnceAutosaveStore.new(real)
  app, d, = new_app(store: flaky)
  app.new_puzzle
  sid = app.current_save_id
  assert_false sid.nil?

  flaky.fail_next = true
  press_new(app)                 # the dig's autosave comes back nil
  # The old id stands rather than being overwritten with nil: a nil here
  # would orphan every later stroke onto no row at all.
  assert_equal(sid, app.current_save_id)

  flaky.fail_next = false
  draw_ink_stroke(app, d)        # journals against the RETAINED row...
  assert_equal(1, real.strokes(sid).size)

  press_new(app)                 # ...and a subsequent save succeeds onto it
  assert_equal(sid, real.autosave[:id])
  assert_equal(sid, app.current_save_id)
  draw_ink_stroke(app, d)        # this one lands too (the dig cleared before)
  assert_equal(1, real.strokes(sid).size)
  real.close
  remove_app_db(path)
end

assert('a stroke drawn on a loaded manual save lands on that row and survives reopen') do
  path = stroke_app_db('manual_current')
  remove_app_db(path)
  store = Redoku::Store.open(path, log: nil)
  id = store.save_manual(game_record(EASY_81, :easy))
  app, d, = new_app(store: store)

  tap_button(app, :games)
  tap_menu_row(app, 0)
  assert_equal(id, app.current_save_id)   # the MANUAL row is current now

  pts = draw_ink_stroke(app, d)
  got = store.strokes(id)
  assert_equal(1, got.size)
  assert_equal([[pts[0], pts[1], pts[2]]], got[0][:subpaths])

  # And it is really in the file, not just this session's memory.
  store.close
  reopened = Redoku::Store.open(path, log: nil)
  got = reopened.strokes(id)
  assert_equal(1, got.size)
  assert_equal([[pts[0], pts[1], pts[2]]], got[0][:subpaths])
  reopened.close
  remove_app_db(path)
end

assert('an entry stored on a given cell is skipped; every other entry restores') do
  path = games_store_db('given_entry')
  remove_app_db(path)
  store = Redoku::Store.open(path, log: nil)
  pristine = Redoku::Sudoku::Grid.parse(EASY_81)
  given = nil
  Redoku::Sudoku::Grid::CELLS.times do |i|
    given = i if given.nil? && pristine.given?(i)
  end
  entries = '.' * 81
  entries[0] = '1'       # cell 0 is blank in EASY_81: a legal stored entry
  entries[given] = '9'   # impossible on a given: skipped, never fatal
  store.save_manual(game_record(EASY_81, :easy, entries))

  app, = new_app(store: store)
  tap_button(app, :games)
  tap_menu_row(app, 0)

  assert_equal :play, app.screen
  assert_equal(1, app.grid.value_at(0))                    # restored
  assert_true(app.grid.given?(given))
  assert_equal(pristine.value_at(given), app.grid.value_at(given)) # untouched
  store.close
  remove_app_db(path)
end

assert('SAVE at the manual cap refuses through the menu with a logged warning') do
  path = games_store_db('save_cap')
  remove_app_db(path)
  store_log = FakeLog.new
  store = Redoku::Store.open(path, log: store_log)
  50.times { |i|
    store.save_manual(game_record(i.even? ? EASY_81 : UNIQUE_81, :easy))
  }
  app, = new_app(log: FakeLog.new, store: store)
  app.new_puzzle

  tap_button(app, :games)
  tap_menu_action(app, :save)

  manuals = store.games.select { |g| g[:kind] == :manual }
  assert_equal(Redoku::Store::MANUAL_CAP, manuals.size)
  assert_equal :menu, app.screen
  assert_true app.running?
  warned = store_log.lines.select { |l|
    l.include?('cap of ' + Redoku::Store::MANUAL_CAP.to_s)
  }
  assert_equal(1, warned.size)
  store.close
  remove_app_db(path)
end

assert('BACK out and reopening the menu clears the armed DEL state') do
  lx, ly, lw, lh = Redoku::Layout.button_rect(:level)  # DEL shares its rect
  app, d, = new_app
  tap_button(app, :games)
  tap_menu_action(app, :del)
  assert_equal(0, d.gray_at(lx + 10, ly + lh / 2))     # armed: label inverted
  assert_true(app.instance_variable_get(:@delete_mode))

  tap_menu_action(app, :back)
  assert_equal :play, app.screen
  tap_button(app, :games)
  assert_equal :menu, app.screen
  # The armed state did not survive the round trip: one gesture must never
  # arm deletion across a menu the player left and came back to.
  assert_false(app.instance_variable_get(:@delete_mode))
  assert_equal(255, d.gray_at(lx + 10, ly + lh / 2))   # label back up
end

# --- CHECK (M3b Task 7). The button, the pass, the verdicts. Helpers first,
# then the assertions; every stroke still goes through handle_sample as real
# pen packets, and the recognizer sees the same panel coordinates the game
# gives it.

def cell_rect_of(index)
  Redoku::Layout.cell_rect(Redoku::Sudoku::Grid.col_of(index),
                           Redoku::Sudoku::Grid.row_of(index))
end

def first_empty_cell(grid)
  i = 0
  i += 1 while i < 81 && grid.given?(i)
  i
end

def next_empty_cell(grid, after)
  i = after + 1
  i += 1 while i < 81 && grid.given?(i)
  i
end

def first_given_cell(grid)
  i = 0
  i += 1 while i < 81 && !grid.given?(i)
  i
end

# Draws the authored template for `digit` inside `index`, as pen samples, so
# the recognizer sees the same panel coordinates the game gives it.
def write_digit_in_cell(app, index, digit)
  entry = Redoku::Templates::AUTHORED.find { |d, _s| d == digit }
  x, y, w, h = cell_rect_of(index)
  entry[1].each do |sub|
    pts = sub.map { |px, py| [x + px * w / 100, y + py * h / 100] }
    pts.each { |px, py| app.handle_sample(pen_sample(px, py, true)) }
    app.handle_sample(pen_sample(pts[-1][0], pts[-1][1], false))
  end
end

def scribble_in_cell(app, index)
  x, y, w, h = cell_rect_of(index)
  [[10, 10], [90, 90], [10, 90], [90, 10], [50, 10], [50, 90],
   [10, 50], [90, 50]].each do |px, py|
    app.handle_sample(pen_sample(x + px * w / 100, y + py * h / 100, true))
  end
  app.handle_sample(pen_sample(x + w / 2, y + h / 2, false))
end

def press_check(app)
  x, y, w, h = Redoku::Layout.button_rect(:check)
  app.handle_sample(pen_sample(x + w / 2, y + h / 2, true))
  app.handle_sample(pen_sample(x + w / 2, y + h / 2, false))
end

assert('CHECK reads a written digit into the grid and retires its ink') do
  path = stroke_app_db('check_read')
  remove_app_db(path)
  store = Redoku::Store.open(path, log: nil)
  app, = new_app(store: store, generator: FakeGenerator.new)
  app.new_puzzle
  sid = app.current_save_id
  index = first_empty_cell(app.grid)
  want = app.solution[index]
  write_digit_in_cell(app, index, want)   # helper below

  assert_equal 1, app.run_check
  assert_equal want, app.grid.value_at(index)
  assert_nil app.mark_of(index)
  # The ink is retired: still in the table, no longer read back.
  assert_equal 0, store.strokes(sid).size
  assert_equal 0, app.ink_strokes.size
  rows = store.instance_variable_get(:@db)
              .execute('SELECT COUNT(*) FROM strokes WHERE game_id = ?', [sid])
  assert_true rows[0][0] > 0
  store.close
  remove_app_db(path)
end

assert('a wrong digit is written, printed and marked') do
  app, = new_app(generator: FakeGenerator.new)
  app.new_puzzle
  index = first_empty_cell(app.grid)
  wrong = app.solution[index] == 9 ? 8 : 9
  write_digit_in_cell(app, index, wrong)
  app.run_check
  assert_equal wrong, app.grid.value_at(index)
  assert_equal :wrong, app.mark_of(index)
end

assert('unreadable ink is KEPT on the glass and marked, not repainted away') do
  # The trap: redraw_cell repaints a cell from the model, which would wipe
  # the very ink an unreadable verdict is preserving. Unreadable cells get
  # draw_mark only.
  app, d = new_app(generator: FakeGenerator.new)
  app.new_puzzle
  index = first_empty_cell(app.grid)
  scribble_in_cell(app, index)
  d.clear_calls
  app.run_check
  assert_true app.grid.unreadable?(index)
  assert_equal :unreadable, app.mark_of(index)
  assert_equal 1, app.ink_strokes.size          # ink survived
  x, y, w, h = cell_rect_of(index)
  # No full-cell white fill over this cell: that is what erasing looks like.
  assert_false d.rects.any? { |rx, ry, rw, rh, g|
    g == Redoku::Renderer::WHITE && rx == x && ry == y && rw == w && rh == h
  }
end

assert('CHECK never touches a given, even one with ink on it') do
  app, = new_app(generator: FakeGenerator.new)
  app.new_puzzle
  given = first_given_cell(app.grid)
  before = app.grid.value_at(given)
  scribble_in_cell(app, given)
  assert_equal 0, app.run_check          # nothing was read
  assert_equal before, app.grid.value_at(given)
  assert_equal 1, app.ink_strokes.size   # the annotation survives
end

assert('CHECK counts its presses and reports them') do
  app, = new_app(generator: FakeGenerator.new)
  app.new_puzzle
  assert_equal 0, app.checks
  press_check(app)
  press_check(app)
  assert_equal 2, app.checks
end

assert('re-checking skips a cell already read, without any dirty tracking') do
  # Spec §4: a read cell has no live strokes, so it is not in the grouped
  # set at all. This is the whole of the "re-recognize only what changed"
  # promise in PLAN.md §7.
  app, = new_app(generator: FakeGenerator.new)
  app.new_puzzle
  index = first_empty_cell(app.grid)
  write_digit_in_cell(app, index, app.solution[index])
  assert_equal 1, app.run_check
  assert_equal 0, app.run_check
end

assert('writing into a checked cell clears its entry and its mark') do
  app, = new_app(generator: FakeGenerator.new)
  app.new_puzzle
  index = first_empty_cell(app.grid)
  wrong = app.solution[index] == 9 ? 8 : 9
  write_digit_in_cell(app, index, wrong)
  app.run_check
  assert_equal :wrong, app.mark_of(index)
  write_digit_in_cell(app, index, app.solution[index])
  assert_true app.grid.empty?(index)      # cleared at pen-down
  assert_nil app.mark_of(index)
  app.run_check
  assert_nil app.mark_of(index)
end

assert('a cell repaint that removes an entry digit flushes GL16, not DU') do
  # Constraint 4, and App#flush_ink's warning at the point of choice:
  # ENTRY_GRAY is 96, a mid tone, and DU is two-level.
  app, d = new_app(generator: FakeGenerator.new)
  app.new_puzzle
  index = first_empty_cell(app.grid)
  write_digit_in_cell(app, index, app.solution[index])
  app.run_check
  d.clear_calls
  write_digit_in_cell(app, index, 5)
  x, y, w, h = cell_rect_of(index)
  hit = d.updates.find { |ux, uy, uw, uh, _wf, _fl|
    ux <= x && uy <= y && ux + uw >= x + w && uy + uh >= y + h
  }
  assert_false hit.nil?
  assert_equal RM2::GL16, hit[4]
end

# --- THE WIN SCREEN (M3b Task 8). Helpers first, then the assertions; the
# board is solved by real pen samples, so the win is earned through the
# recognizer exactly as it is on the device.

def fill_board_correctly(app)
  i = 0
  while i < Redoku::Sudoku::Grid::CELLS
    write_digit_in_cell(app, i, app.solution[i]) unless app.grid.given?(i)
    i += 1
  end
end

def last_empty_cell(grid)
  i = Redoku::Sudoku::Grid::CELLS - 1
  i -= 1 while i >= 0 && grid.given?(i)
  i
end

assert('a full and correct board wins, and reports the check count') do
  app, d = new_app(generator: FakeGenerator.new)
  app.new_puzzle
  fill_board_correctly(app)      # helper: writes every non-given answer
  app.run_check
  assert_true app.won?
  assert_equal :win, app.screen
  # GC16 + SYNC: the one full-screen flash a transition is allowed.
  last = d.updates[-1]
  assert_equal [0, 0, Redoku::Layout::SCREEN_W, Redoku::Layout::SCREEN_H],
               [last[0], last[1], last[2], last[3]]
  assert_equal RM2::GC16, last[4]
end

assert('one unreadable cell is enough to withhold the win') do
  # The property Grid::UNREADABLE exists for (spec §2): a cell that could
  # not be read is not a solved cell, so no false win.
  app, = new_app(generator: FakeGenerator.new)
  app.new_puzzle
  fill_board_correctly(app)
  last = last_empty_cell(app.grid)
  app.grid.clear_entry(last)
  scribble_in_cell(app, last)
  app.run_check
  assert_true app.grid.unreadable?(last)
  assert_false app.won?
end

assert('one wrong digit is enough to withhold the win') do
  app, = new_app(generator: FakeGenerator.new)
  app.new_puzzle
  fill_board_correctly(app)
  i = first_empty_cell(app.grid)
  app.grid.set_entry(i, app.solution[i] == 9 ? 8 : 9)
  assert_false app.solved_correctly?
end

assert('a tap on the win screen deals a new puzzle') do
  app, = new_app(generator: FakeGenerator.new)
  app.new_puzzle
  fill_board_correctly(app)
  app.run_check
  before = app.grid.givens_s
  app.handle_sample(pen_sample(700, 900, true))
  app.handle_sample(pen_sample(700, 900, false))
  assert_equal :play, app.screen
  assert_false before == app.grid.givens_s
  assert_equal 0, app.checks         # a new puzzle is a new sitting
end

assert('the win screen text stays inside the font charset') do
  # Constraint 3: Font.draw silently draws NOTHING for a missing glyph, so
  # a stray lowercase letter would ship a blank screen.
  allowed = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -:.?'
  Redoku::Renderer::WIN_TEXT.each_char do |ch|
    assert_true allowed.include?(ch), "no glyph for #{ch.inspect}"
  end
end

assert('CHECK persists its verdicts, including the unreadable one') do
  path = stroke_app_db('check_persist')
  remove_app_db(path)
  store = Redoku::Store.open(path, log: nil)
  app, = new_app(store: store, generator: FakeGenerator.new)
  app.new_puzzle
  read_cell = first_empty_cell(app.grid)
  write_digit_in_cell(app, read_cell, app.solution[read_cell])
  bad_cell = next_empty_cell(app.grid, read_cell)
  scribble_in_cell(app, bad_cell)
  app.run_check

  rec = store.autosave
  assert_equal app.solution[read_cell].to_s, rec[:entries][read_cell]
  assert_equal '?', rec[:entries][bad_cell]

  store2 = Redoku::Store.open(path, log: nil)
  app2, _d2, _in2, sig2 = new_app(store: store2)
  sig2.terminated = true
  app2.run
  assert_equal app.solution[read_cell], app2.grid.value_at(read_cell)
  assert_true app2.grid.unreadable?(bad_cell)
  remove_app_db(path)
end
