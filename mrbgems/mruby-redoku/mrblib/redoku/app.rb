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
      @mode = nil       # :ink, :button or nil — fixed at pen-down
      @last = nil       # previous point of this stroke
      @start = nil      # where this stroke began
      @path = 0         # travel so far, for tap detection
      @ink_dirty = nil  # [x1, y1, x2, y2] pending ink damage
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
    # gone and there is nothing left to play with.
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

    def drop_hung_up_sources
      live = @sources.reject { |source| source.hung_up? }
      return if live.size == @sources.size
      @sources = live
      @running = false if @sources.empty?
    end

    # @last is kept for every stroke, not only an inking one: the travel that
    # tells a tap from a drag has to accumulate on a button stroke too, or
    # TAP_MAX_PATH would never bite and any drag ending on Quit would quit.
    def begin_stroke(x, y)
      @start = [x, y]
      @last = [x, y]
      @path = 0
      @mode = if Layout.cell_at(x, y)
                :ink
              elsif Layout.button_at(x, y)
                :button
              else
                :none
              end
    end

    def continue_stroke(x, y)
      @path += (x - @last[0]).abs + (y - @last[1]).abs
      if @mode == :ink
        @d.draw_line(@last[0], @last[1], x, y, INK_WIDTH, INK_GRAY)
        mark_dirty(@last[0], @last[1], x, y)
      end
      @last = [x, y]
    end

    def end_stroke(x, y)
      @path += (x - @last[0]).abs + (y - @last[1]).abs
      press(Layout.button_at(@start[0], @start[1])) if tap?
      @mode = nil
      @last = nil
      @start = nil
      @path = 0
    end

    def tap?
      @mode == :button && @path <= TAP_MAX_PATH
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
