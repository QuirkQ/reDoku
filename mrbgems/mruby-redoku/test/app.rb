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
# instead of re-rolling it every time, because the dig is a search and a hard
# request measured anywhere from 90 to 600 ms on this host depending on the
# seed. 11 was chosen by timing the sequences these tests actually drive
# (medium+hard+easy for the two three-press Level tests, easy+easy for New)
# across a dozen candidate seeds and keeping one of the two fastest.
#
# The production default — App's own `rng:` keyword, which reads the clock —
# is covered by one test of its own rather than incidentally by all of these:
# see 'an App given no rng seeds itself from the clock'.
GEN_SEED = 11

def new_app(batches = [], rng: Redoku::Rng.new(GEN_SEED))
  d = TestDisplay.new
  input = FakeInput.new(batches)
  signals = FakeSignals.new
  app = Redoku::App.new(d, [input], Redoku::Renderer.new(d),
                        FakeWaiter.new([input]), signals, rng: rng)
  [app, d, input, signals]
end

# An App with a touchscreen as well as a pen, and a clock under the test's
# control.
def new_touch_app(pen_batches = [], touch_batches = [],
                  rng: Redoku::Rng.new(GEN_SEED))
  d = TestDisplay.new
  pen = FakeInput.new(pen_batches)
  finger = FakeInput.new(touch_batches)
  clock = FakeClock.new
  waiter = FakeWaiter.new([pen, finger])
  app = Redoku::App.new(d, [pen], Redoku::Renderer.new(d), waiter,
                        FakeSignals.new, touch_sources: [finger],
                        clock: clock, rng: rng)
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
  [:new, :level, :quit].each do |name|
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
    # Neither action repaints the buttons — new_puzzle flushes the board,
    # cycle_difficulty the header — so without a release of its own the
    # button would stay inverted for the rest of the session.
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
                        FakeSignals.new, rng: Redoku::Rng.new(GEN_SEED))
  nx, ny, nw, nh = Redoku::Layout.button_rect(:new)
  d.clear_calls
  app.handle_sample(pen_sample(nx + nw / 2, ny + nh / 2, true))
  app.handle_sample(pen_sample(nx + nw / 2, ny + nh / 2, false))
  # THREE updates had reached the panel by the time the hold began: the press
  # flash, the splash, and the board repaint carrying the new puzzle. Was two
  # before M2, when New's whole action was one board repaint; the extra one is
  # the splash, and it counts here for the same reason the others do — 200 ms
  # is how long a press lasts, not a toll to charge before every action, so
  # the work starts the moment the tap is recognised and the button stays down
  # while it happens.
  assert_equal [3], waiter.updates_at
  bx, by, bw, bh = Redoku::Layout.board_rect
  # Both halves of the action go out over board_rect with the chrome
  # waveform: the splash first, then the finished puzzle. Same rect, because
  # draw_splash paints exactly board_rect (see Renderer#draw_splash), which is
  # what lets one flush_board cover either of them.
  assert_equal [bx, by, bw, bh, RM2::GL16, 0], d.updates[1]
  assert_equal [bx, by, bw, bh, RM2::GL16, 0], d.updates[2]
  # press, splash, puzzle, release — and the release is after the hold.
  assert_equal 4, d.updates.size
  assert_equal [nx, ny, nw, nh, RM2::DU, RM2::FAST_DRAW], d.updates[3]
end

assert('the acknowledgement runs each action exactly once') do
  app, d, = new_app
  lx, ly, lw, lh = Redoku::Layout.button_rect(:level)
  3.times do |i|
    d.clear_calls
    app.handle_sample(pen_sample(lx + lw / 2, ly + lh / 2, true))
    app.handle_sample(pen_sample(lx + lw / 2, ly + lh / 2, false))
    # One step per tap: a press that ran cycle_difficulty twice would skip a
    # difficulty, and one that dropped it would stay put.
    assert_equal Redoku::Sudoku::Rater::TIERS[(i + 1) % 3], app.difficulty
    # Exactly one header flush per tap, exactly as before. What changed is how
    # it is counted: Level now digs a puzzle as well as renaming the tier, and
    # new_puzzle's two board flushes are GL16 chrome too, so counting GL16
    # updates no longer isolates the header. Counted by REGION instead, which
    # asks a tighter question than the old waveform count did, not a looser
    # one — the old version would have accepted a header flush that landed on
    # the wrong rect.
    hx = Redoku::Layout::HEADER_X
    hy = Redoku::Layout::HEADER_Y
    header = d.updates.reject { |u| u[0] != hx || u[1] != hy }
    assert_equal 1, header.size
    # And exactly two board flushes, which is the same "exactly once" property
    # applied to the new half of the action: the splash and then the puzzle,
    # dug once per tap and not twice.
    bx, by, = Redoku::Layout.board_rect
    board = d.updates.reject { |u| u[0] != bx || u[1] != by }
    assert_equal 2, board.size
    # All three of those are chrome and none of them ink, which is the M1
    # waveform discipline the old count was written in.
    assert_equal 3, d.updates.reject { |u| u[4] != RM2::GL16 }.size
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

assert('a Level press whose flash is refused still cycles the difficulty') do
  d = DeafButtonsDisplay.new
  input = FakeInput.new
  waiter = TimelineWaiter.new([input], d)
  app = Redoku::App.new(d, [input], Redoku::Renderer.new(d), waiter,
                        FakeSignals.new, rng: Redoku::Rng.new(GEN_SEED))
  lx, ly, lw, lh = Redoku::Layout.button_rect(:level)
  app.handle_sample(pen_sample(lx + lw / 2, ly + lh / 2, true))
  app.handle_sample(pen_sample(lx + lw / 2, ly + lh / 2, false))
  # N1 for all three buttons now, not Quit's alone: the display socket
  # carries a 10 s receive timeout, so a press flash really can raise on the
  # device — and the player must still get the thing they pressed.
  assert_equal :medium, app.difficulty
  assert_true app.running?
  # ...and the puzzle that goes with the tier, which is the other half of what
  # Level now means.
  assert_false app.grid.nil?
  # Nothing reached the panel to hold or to put back, so neither happened.
  # The header, which is not a button, went out as usual.
  assert_equal [], waiter.calls
  # Three updates where M1 had one: the header, then new_puzzle's splash and
  # its finished board. The deaf display refuses only button rects, so all
  # three land. The header is still FIRST and still GL16 — that is the M1
  # decision this test exists for, and the two board flushes after it are the
  # dig Level gained, not a change to it.
  assert_equal 3, d.updates.size
  hx = Redoku::Layout::HEADER_X
  hy = Redoku::Layout::HEADER_Y
  assert_equal RM2::GL16, d.updates[0][4]
  assert_equal hx, d.updates[0][0]
  assert_equal hy, d.updates[0][1]
  bx, by, bw, bh = Redoku::Layout.board_rect
  assert_equal [bx, by, bw, bh, RM2::GL16, 0], d.updates[1]
  assert_equal [bx, by, bw, bh, RM2::GL16, 0], d.updates[2]
end

assert('a New press whose flash is refused still clears the ink') do
  d = DeafButtonsDisplay.new
  input = FakeInput.new
  waiter = TimelineWaiter.new([input], d)
  app = Redoku::App.new(d, [input], Redoku::Renderer.new(d), waiter,
                        FakeSignals.new, rng: Redoku::Rng.new(GEN_SEED))
  app.handle_sample(pen_sample(300, 400, true))
  app.handle_sample(pen_sample(340, 440, true))
  app.handle_sample(pen_sample(340, 440, false))
  d.clear_calls
  nx, ny, nw, nh = Redoku::Layout.button_rect(:new)
  app.handle_sample(pen_sample(nx + nw / 2, ny + nh / 2, true))
  app.handle_sample(pen_sample(nx + nw / 2, ny + nh / 2, false))
  bx, by, bw, bh = Redoku::Layout.board_rect
  # Two board flushes where M1 had one: the splash, then the board carrying
  # the new puzzle. Both over board_rect with the chrome waveform, exactly as
  # the single one was — the refused button flash still costs the player
  # nothing, which is what this test is for.
  assert_equal [[bx, by, bw, bh, RM2::GL16, 0],
                [bx, by, bw, bh, RM2::GL16, 0]], d.updates
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

assert('a tap on Level cycles the difficulty and repaints the header') do
  app, d, = new_app
  assert_equal :easy, app.difficulty
  lx, ly, lw, lh = Redoku::Layout.button_rect(:level)
  3.times do |i|
    d.clear_calls
    app.handle_sample(pen_sample(lx + lw / 2, ly + lh / 2, true))
    app.handle_sample(pen_sample(lx + lw / 2, ly + lh / 2, false))
    expected = Redoku::Sudoku::Rater::TIERS[(i + 1) % 3]
    assert_equal expected, app.difficulty
    # press flash, header, splash, puzzle, release flash. Was three before
    # M2, when Level only renamed the tier; the two extra are the board the
    # tier now comes with. The header is still the FIRST thing after the press
    # and still GL16 — the M1 decision this test is named for — and it is no
    # longer the only GL16, because the splash and the puzzle are chrome too.
    assert_equal 5, d.updates.size
    assert_equal RM2::GL16, d.updates[1][4]
    assert_equal Redoku::Layout::HEADER_X, d.updates[1][0]
    assert_equal Redoku::Layout::HEADER_Y, d.updates[1][1]
    bx, by, bw, bh = Redoku::Layout.board_rect
    assert_equal [bx, by, bw, bh, RM2::GL16, 0], d.updates[2]
    assert_equal [bx, by, bw, bh, RM2::GL16, 0], d.updates[3]
    assert_equal [lx, ly, lw, lh, RM2::DU, RM2::FAST_DRAW], d.updates[4]
    # ...and a board of the new tier really is on the glass, which is what
    # makes the label mean anything.
    assert_false app.grid.nil?
  end
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

def press_new(app)
  press_pen_button(app, :new)
end

def press_level(app)
  press_pen_button(app, :level)
end

# A tap: down and up on the centre of the named button, which is what every
# existing press assertion above does by hand.
def press_pen_button(app, name)
  x, y, w, h = Redoku::Layout.button_rect(name)
  app.handle_sample(pen_sample(x + w / 2, y + h / 2, true))
  app.handle_sample(pen_sample(x + w / 2, y + h / 2, false))
  app
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

assert('a tap on Level changes the difficulty and the puzzle with it') do
  app = test_app
  app.new_puzzle
  before_tier = app.difficulty
  before_puzzle = app.grid.givens_s
  press_level(app)
  assert_false app.difficulty == before_tier
  assert_false app.grid.givens_s == before_puzzle
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
                        FakeWaiter.new([input]), FakeSignals.new, rng: spy)
  app.new_puzzle
  # Exactly one update had reached the panel when the generator took its first
  # draw, and that update is the splash. Nought would mean the splash flush
  # had moved after the dig; more would mean something else is flushing in
  # between and this test should be told about it.
  assert_equal 1, spy.updates_at_first_draw
  bx, by, bw, bh = Redoku::Layout.board_rect
  assert_equal [bx, by, bw, bh, RM2::GL16, 0], d.updates[0]
  # ...and the board carrying the finished puzzle came after it, so the splash
  # is a cover for the pause rather than the last word on it.
  assert_equal 2, d.updates.size
  assert_equal [bx, by, bw, bh, RM2::GL16, 0], d.updates[1]
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
