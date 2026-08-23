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

def new_app(batches = [])
  d = TestDisplay.new
  input = FakeInput.new(batches)
  signals = FakeSignals.new
  app = Redoku::App.new(d, [input], Redoku::Renderer.new(d),
                        FakeWaiter.new([input]), signals)
  [app, d, input, signals]
end

# An App with a touchscreen as well as a pen, and a clock under the test's
# control.
def new_touch_app(pen_batches = [], touch_batches = [])
  d = TestDisplay.new
  pen = FakeInput.new(pen_batches)
  finger = FakeInput.new(touch_batches)
  clock = FakeClock.new
  waiter = FakeWaiter.new([pen, finger])
  app = Redoku::App.new(d, [pen], Redoku::Renderer.new(d), waiter,
                        FakeSignals.new, touch_sources: [finger],
                        clock: clock)
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
  assert_equal [[[], Redoku::App::QUIT_ACK_MS]], waiter.calls
  # ...and the flash had already reached the panel when the hold began,
  # which is the ordering that makes the pause worth anything.
  assert_equal [1], waiter.updates_at
  assert_equal [qx, qy, qw, qh, RM2::DU, RM2::FAST_DRAW], d.updates[0]
end

assert('New and Level do not hold: only Quit has to be seen before it goes') do
  d = TestDisplay.new
  input = FakeInput.new
  waiter = TimelineWaiter.new([input], d)
  app = Redoku::App.new(d, [input], Redoku::Renderer.new(d), waiter,
                        FakeSignals.new)
  [:new, :level].each do |name|
    bx, by, bw, bh = Redoku::Layout.button_rect(name)
    app.handle_sample(pen_sample(bx + bw / 2, by + bh / 2, true))
    app.handle_sample(pen_sample(bx + bw / 2, by + bh / 2, false))
  end
  assert_true app.running?
  # Both repaint as their action, so they already read as responsive; a hold
  # here would only make the game feel slower.
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
    expected = Redoku::Renderer::DIFFICULTIES[(i + 1) % 3]
    assert_equal expected, app.difficulty
    assert_equal 1, d.updates.size
    assert_equal RM2::GL16, d.updates[0][4]
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
  # This GL16 board update is the evidence that the ink was cleared. The
  # gray_at below only confirms draw_board's white fill covers that cell
  # pixel: gray_at replays fill_rect calls, and ink is a draw_line.
  assert_equal [bx, by, bw, bh, RM2::GL16, 0], d.updates[0]
  assert_equal 255, d.gray_at(300, 400)
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
  assert_equal 1, d.updates.size # only the opening full paint
end

assert('App#run repaints when the server resumes us') do
  app, d, _input, signals = new_app
  signals.resumed = true
  signals.terminated = true # one turn of the loop, then stop
  app.run
  assert_equal 2, d.updates.size
  assert_equal RM2::GC16, d.updates[0][4]
  assert_equal RM2::GC16, d.updates[1][4]
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
