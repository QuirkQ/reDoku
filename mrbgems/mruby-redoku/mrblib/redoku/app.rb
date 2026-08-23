module Redoku
  # The event loop. One stroke at a time: what a stroke does is decided
  # where the pen went down (ink on the board, a tap on a button, nothing
  # anywhere else), so dragging out of a region can never surprise the user.
  #
  # `sources` are RM2::Input objects; `waiter` is anything answering
  # `wait(sources, timeout_ms)` and `signals` anything answering
  # `terminated?`/`resumed?` — RM2::Input and RM2 in production, fakes in
  # tests, which is what keeps this loop host-testable.
  class App
    INK_GRAY = 0
    INK_WIDTH = 4
    TAP_MAX_PATH = 20 # px of travel still counted as a tap, not a drag
    POLL_MS = 100     # idle wake-up; returns immediately when ink is pending

    # ink_dirty is the pending ink damage as INCLUSIVE corners
    # [x1, y1, x2, y2] — the one rect in this codebase that is not
    # [x, y, w, h] with exclusive edges, because it grows corner by corner as
    # segments arrive and is converted only on its way out, in flush_ink.
    attr_reader :difficulty, :ink_dirty

    def initialize(display, sources, renderer, waiter = RM2::Input,
                   signals = RM2)
      @d = display
      @sources = sources
      @renderer = renderer
      @waiter = waiter
      @signals = signals
      @difficulty = Renderer::DIFFICULTIES[0]
      @running = true
      @mode = nil       # :ink, :button, :none, or nil for no stroke open
      @last = nil       # previous point of this stroke
      @button = nil     # the button this stroke went down on, if any
      @travel = 0       # distance travelled so far, for tap detection
      @ink_dirty = nil  # pending ink damage, inclusive corners
    end

    def running?
      @running
    end

    def run
      @renderer.draw_all(@difficulty)
      @renderer.flush_all
      while @running
        step
        handle_resume if @signals.resumed?
        @running = false if @signals.terminated?
      end
      self
    end

    # One turn of the loop: wait, drain every source, then flush the ink in
    # a single update rather than one per segment. A hung-up source (the
    # server tearing down a uinput clone, a device unbound) never becomes
    # readable again, so it is dropped; losing every source means the pen is
    # gone and there is nothing left to play with, so the loop ends (see
    # drop_hung_up_sources).
    def step
      ready = @waiter.wait(@sources, POLL_MS)
      if ready
        @sources.each do |source|
          source.pending_events.each { |sample| handle_sample(sample) }
        end
      end
      drop_hung_up_sources
      flush_ink
      self
    end

    def handle_sample(sample)
      raw_x, raw_y, _pressure, tools = sample
      x, y = Pen.to_screen(raw_x, raw_y)
      down = (tools & RM2::Input::TOUCH) != 0

      if down && @mode.nil?
        begin_stroke(x, y)
      elsif down
        continue_stroke(x, y)
      elsif @mode
        end_stroke(x, y)
      end
      self
    end

    # Pushes pending ink to the panel with the fast waveform. Ink is drawn
    # into the shared buffer as it arrives but flushed at most once per loop
    # turn: fewer round trips, and the pen still keeps up.
    def flush_ink
      return self unless @ink_dirty
      x1, y1, x2, y2 = @ink_dirty
      @ink_dirty = nil
      @renderer.flush_rect(x1, y1, x2 - x1 + 1, y2 - y1 + 1,
                           waveform: RM2::DU, flags: RM2::FAST_DRAW)
      self
    end

    # After a SIGCONT the server has already re-flashed our buffer, but a
    # full repaint is the cheap way to be certain the panel matches us.
    def handle_resume
      @renderer.draw_all(@difficulty)
      @renderer.flush_all
      self
    end

    private

    # The empty check runs on every turn, not only when the list just shrank:
    # an App handed no sources at all would otherwise loop forever on a wait
    # that can never report anything ready, and nothing else in the loop
    # would ever stop it. RM2::Input.wait paces such a wait rather than
    # returning at once, so what this prevents is a game nobody can quit —
    # it stopped being a hot spin when wait learned to sleep on an empty
    # poll set.
    def drop_hung_up_sources
      @sources = @sources.reject { |source| source.hung_up? }
      @running = false if @sources.empty?
    end

    # @last and @travel are kept for every stroke, not only an inking one:
    # the travel that tells a tap from a drag has to accumulate on a button
    # stroke too, or TAP_MAX_PATH would never bite and any drag ending on
    # Quit would quit. @button remembers what was pressed, so the release
    # can be checked against it without asking Layout twice.
    def begin_stroke(x, y)
      @last = [x, y]
      @travel = 0
      if Layout.cell_at(x, y)
        @button = nil
        @mode = :ink
      else
        @button = Layout.button_at(x, y)
        @mode = @button ? :button : :none
      end
    end

    def continue_stroke(x, y)
      @travel += (x - @last[0]).abs + (y - @last[1]).abs
      ink_to(x, y)
      @last = [x, y]
    end

    # The closing segment inks like any other: when the pen lifts in
    # mid-motion the new position and BTN_TOUCH 0 arrive in the same packet,
    # so skipping it would drop the tail of every such stroke. Usually it is
    # zero length — a release packet repeats the last position, and the
    # decoder drops unchanged EV_ABS values — which stamps the brush once
    # more over pixels it already painted.
    def end_stroke(x, y)
      @travel += (x - @last[0]).abs + (y - @last[1]).abs
      ink_to(x, y)
      press(@button) if tap?(x, y)
      @mode = nil
      @last = nil
      @button = nil
      @travel = 0
    end

    # The board is the writing surface and the chrome is not, so a segment is
    # drawn only when both of its endpoints are on the board: an :ink stroke
    # that wanders off leaves a gap and picks up again where it returns.
    # Clamping the stray endpoint to the border instead would drag it along
    # the edge and smear a line down the side of the board for as long as the
    # pen stayed outside, which is worse than the gap. cell_at is the board
    # test — it answers nil off the board. @mode is checked first, so a
    # button or dead stroke costs no geometry at all.
    def ink_to(x, y)
      return unless @mode == :ink
      return unless Layout.cell_at(@last[0], @last[1]) && Layout.cell_at(x, y)
      @d.draw_line(@last[0], @last[1], x, y, INK_WIDTH, INK_GRAY)
      mark_dirty(@last[0], @last[1], x, y)
    end

    # A tap starts and ends on the same button, having travelled little in
    # between. Sliding off the button before releasing cancels it — the
    # standard affordance, and one more thing that has to go right before
    # Quit fires.
    def tap?(x, y)
      @mode == :button && @travel <= TAP_MAX_PATH &&
        Layout.button_at(x, y) == @button
    end

    def press(button)
      case button
      when :quit then @running = false
      when :level then cycle_difficulty
      when :new then clear_ink
      end
    end

    def cycle_difficulty
      list = Renderer::DIFFICULTIES
      @difficulty = list[(list.index(@difficulty) + 1) % list.size]
      @renderer.draw_header(@difficulty)
      @renderer.flush_header
    end

    # New wipes the ink. Repainting and flushing board_rect alone is enough
    # because ink cannot exist anywhere else: ink_to refuses any segment with
    # an endpoint off the board, so every stamped pixel is within
    # INK_WIDTH / 2 of a line inside board_rect — that is, inside it or on
    # the Layout::BLOCK_LINE / 2 frame overhang, which draw_board repaints
    # black over black (see Renderer#flush_board). That holds only while
    # INK_WIDTH <= Layout::BLOCK_LINE, which is 4 and 4 today: a fatter
    # brush reaches past the frame band onto white background, where stray
    # ink would survive New and no host test could see it, because the mock
    # records the update rather than rendering it. Raise INK_WIDTH and this
    # flush has to widen with it.
    def clear_ink
      @ink_dirty = nil
      @renderer.draw_board
      @renderer.flush_board
    end

    # Grows the pending damage rect by the brush extent so every pixel the
    # brush stamped is inside what we flush — a rect even one pixel short
    # leaves ink invisible until some later full refresh, and no host test
    # can see that, because the mock records the update instead of rendering
    # it. draw_line stamps a width-sided square per point, reaching
    # width / 2 up and left and width - width / 2 - 1 down and right
    # (src/display.c rm2_stamp), so a pad of INK_WIDTH covers both sides for
    # any width. Then clamp: the panel is all we may flush.
    def mark_dirty(x1, y1, x2, y2)
      pad = INK_WIDTH
      lo_x = (x1 < x2 ? x1 : x2) - pad
      lo_y = (y1 < y2 ? y1 : y2) - pad
      hi_x = (x1 > x2 ? x1 : x2) + pad
      hi_y = (y1 > y2 ? y1 : y2) + pad
      lo_x = 0 if lo_x < 0
      lo_y = 0 if lo_y < 0
      hi_x = Layout::SCREEN_W - 1 if hi_x >= Layout::SCREEN_W
      hi_y = Layout::SCREEN_H - 1 if hi_y >= Layout::SCREEN_H
      if @ink_dirty
        @ink_dirty[0] = lo_x if lo_x < @ink_dirty[0]
        @ink_dirty[1] = lo_y if lo_y < @ink_dirty[1]
        @ink_dirty[2] = hi_x if hi_x > @ink_dirty[2]
        @ink_dirty[3] = hi_y if hi_y > @ink_dirty[3]
      else
        @ink_dirty = [lo_x, lo_y, hi_x, hi_y]
      end
    end
  end
end
