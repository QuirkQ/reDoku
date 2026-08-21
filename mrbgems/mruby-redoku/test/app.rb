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

def new_app(batches = [])
  d = TestDisplay.new
  input = FakeInput.new(batches)
  signals = FakeSignals.new
  app = Redoku::App.new(d, [input], Redoku::Renderer.new(d),
                        FakeWaiter.new([input]), signals)
  [app, d, input, signals]
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
