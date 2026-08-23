module Redoku
  # The event loop. One stroke at a time: what a stroke does is decided
  # where the pen went down (ink on the board, a tap on a button, nothing
  # anywhere else), so dragging out of a region can never surprise the user.
  #
  # The pen writes and presses buttons; a finger can only press buttons.
  # That split is the owner's: the board is a writing surface, so ink is
  # pen-exclusive, and the two devices are handled by separate code paths
  # here because they are separate devices — different transforms, different
  # tap tolerances, and a finger the pen can veto (see touch_suppressed?).
  #
  # `sources` are the pen's RM2::Input objects and `touch_sources` the
  # touchscreen's; `waiter` is anything answering `wait(sources, timeout_ms)`,
  # `signals` anything answering `terminated?`/`resumed?`, and `clock`
  # anything answering `monotonic_ms` — RM2::Input and RM2 in production,
  # fakes in tests, which is what keeps this loop host-testable.
  class App
    INK_GRAY = 0
    INK_WIDTH = 4
    TAP_MAX_PATH = 20 # px of travel still counted as a tap, not a drag
    POLL_MS = 100     # idle wake-up; returns immediately when ink is pending

    # A fingertip is fatter than a pen tip and rolls as it lands, so its
    # reported point drifts further on a tap that felt perfectly still. The
    # buttons are 400x140, so the looser threshold costs no precision. Its
    # own constant rather than a bigger TAP_MAX_PATH: the pen's tolerance is
    # tight on purpose, and the choice is made per source at the call site.
    TOUCH_TAP_MAX_PATH = 40

    # How long the Quit acknowledgement is held on the panel before the loop
    # stops. Feedback nobody can see is not feedback: the DU flash lands and
    # then the process tears down, and on the device the gap before xochitl
    # repaints was too short to perceive.
    QUIT_ACK_MS = 200

    # How long the pen may say nothing at all before its proximity latch is
    # treated as stale. @pen_near only ever becomes false because a packet
    # said so, and two documented things eat that packet: the display server
    # drains the evdev backlog of a client it had SIGSTOPped (PLAN.md §5),
    # and SYN_DROPPED, which input.c discards a torn packet for. With no
    # expiry, one lost packet suppresses every finger tap for the rest of the
    # session, recoverable only by waving the pen into range and out again —
    # which nobody would guess.
    #
    # Twice the cooldown and ten loop turns: long enough that a pen genuinely
    # hovering over the glass keeps its own latch alive (the digitizer
    # reports at about 100 Hz while a tool is in range, and a held hand
    # always jitters), short enough that a lost packet costs a second instead
    # of a session. It is a recovery, not a relaxation — see
    # expire_pen_proximity.
    PEN_SILENCE_MS = 1000

    # How long touch stays suppressed after the pen leaves proximity.
    # BTN_TOOL_PEN flickers out during normal writing, and without a
    # cooldown one such dropout is a window for a resting palm to press
    # something. Long enough to absorb the flicker, short enough that
    # putting the pen down and reaching for a button does not feel laggy.
    TOUCH_COOLDOWN_MS = 500

    # ink_dirty is the pending ink damage as INCLUSIVE corners
    # [x1, y1, x2, y2] — the one rect in this codebase that is not
    # [x, y, w, h] with exclusive edges, because it grows corner by corner as
    # segments arrive and is converted only on its way out, in flush_ink.
    attr_reader :difficulty, :ink_dirty

    def initialize(display, sources, renderer, waiter = RM2::Input,
                   signals = RM2, touch_sources: [], clock: RM2)
      @d = display
      @sources = sources
      @touch = touch_sources
      @renderer = renderer
      @waiter = waiter
      @signals = signals
      @clock = clock
      @difficulty = Renderer::DIFFICULTIES[0]
      @running = true
      @mode = nil       # :ink, :button, :none, or nil for no stroke open
      @last = nil       # previous point of this stroke
      @button = nil     # the button this stroke went down on, if any
      @travel = 0       # distance travelled so far, for tap detection
      @ink_dirty = nil  # pending ink damage, inclusive corners

      # The touch stroke is tracked separately from the pen's, so that a
      # finger landing on the glass can never cut a stroke short or steal
      # the pen's @mode. Two contacts open at once is normal on this device.
      @touch_mode = nil    # :button, :none, or nil for no contact
      @touch_last = nil
      @touch_button = nil
      @touch_travel = 0
      @touch_blocked = false # this contact met the pen; it can never press
      @pen_near = false      # pen (or rubber) in proximity, hovering counts
      @pen_left_at = nil     # monotonic ms when proximity last ended
      @pen_seen_at = nil     # monotonic ms of the last pen packet of any kind
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
    # readable again, so it is dropped; losing every pen means there is
    # nothing left to play with, so the loop ends (see
    # drop_hung_up_sources). Pen and touch are waited on together — one
    # poll, one timeout — but drained apart, because a touch sample means
    # something different from a pen sample and is not even in the same
    # coordinate space.
    def step
      ready = @waiter.wait(@sources + @touch, POLL_MS)
      if ready
        @sources.each do |source|
          source.pending_events.each { |sample| handle_sample(sample) }
        end
        # Between the two drains, not before both: a turn that took a second
        # inside a GC16 SYNC repaint leaves the pen's packets queued, and
        # decoding them first is what stops a slow repaint from looking like
        # a silent digitizer. After that the touch samples of this same turn
        # are judged against proximity we have just re-checked, so the first
        # tap after a lost packet is the one that works.
        expire_pen_proximity
        @touch.each do |source|
          source.pending_events.each { |sample| handle_touch_sample(sample) }
        end
      end
      drop_hung_up_sources
      flush_ink
      self
    end

    def handle_sample(sample)
      raw_x, raw_y, _pressure, tools = sample
      note_pen_proximity(tools)
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

    # A touchscreen contact. It can press a button and do nothing else: no
    # ink, no cell selection, nothing on the board at all — begin_touch asks
    # Layout for a button and treats every other point as dead.
    #
    # RM2::Input::FINGER, not TOUCH: TOUCH is evdev's BTN_TOUCH, which on
    # this hardware means the PEN TIP is against the glass. FINGER is the
    # touchscreen's own bit, set while the one contact the decoder follows
    # exists (see the MT decode in the rm2 gem's input.c).
    def handle_touch_sample(sample)
      raw_x, raw_y, _pressure, tools = sample
      x, y = Touch.to_screen(raw_x, raw_y)
      down = (tools & RM2::Input::FINGER) != 0

      if down && @touch_mode.nil?
        begin_touch(x, y)
      elsif down
        continue_touch(x, y)
      elsif @touch_mode
        end_touch(x, y)
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
    #
    # It is also where the input-derived latches are thrown away, and that
    # half matters more than the repaint. We were SIGSTOPped, and the display
    # server drains the evdev backlog of a client it thaws (PLAN.md §5), so
    # every packet the user generated while we were frozen is gone. If the
    # pen left proximity in that window, @pen_near would stay true for ever
    # and every finger tap would be dead for the rest of the session; if a
    # contact lifted, @touch_mode would stay open and no later tap would
    # complete. Both are latches with nothing else to clear them, so both are
    # cleared here rather than waited on.
    def handle_resume
      forget_input_state
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
      @touch = @touch.reject { |source| source.hung_up? }
      # The pen list is what decides: reDoku is a pen game, and a session
      # that can only press buttons has nothing left to do but quit. A dead
      # touchscreen is merely a game whose buttons went back to pen-only.
      @running = false if @sources.empty?
    end

    # The digitizer reports BTN_TOOL_PEN (or BTN_TOOL_RUBBER) as soon as the
    # tool is NEAR the glass, not only when it touches — which is what makes
    # ordinary writing posture suppress a resting palm for free, before any
    # contact is made. RM2::Input::TOUCH is the tip actually pressed down and
    # is deliberately not consulted here.
    #
    # This is the pen path's only new work, and it decides nothing about the
    # pen: it records, for the touch path, where the pen is.
    def note_pen_proximity(tools)
      near = (tools & (RM2::Input::PEN | RM2::Input::RUBBER)) != 0
      # Stamped for EVERY pen packet, near or not, because what
      # expire_pen_proximity needs to know is when the digitizer last said
      # anything at all. One vDSO clock_gettime per sample, against a sample
      # that already costs a transform and a brush stamp.
      @pen_seen_at = @clock.monotonic_ms
      @pen_left_at = @pen_seen_at if @pen_near && !near
      @pen_near = near
    end

    # Treats a digitizer that has gone completely quiet as a pen that is no
    # longer there. This is the recovery half of PEN_SILENCE_MS: without it a
    # single lost proximity-off packet disables the touchscreen for the whole
    # session, silently, with no diagnostic and no discoverable way back.
    #
    # It expires the latch and nothing more — no cooldown is started here,
    # unlike an observed proximity-off. The cooldown absorbs BTN_TOOL_PEN
    # flicker, and flicker is packets; silence is the absence of packets, so
    # there is nothing to absorb and no reason to make the recovery a second
    # and a half instead of a second.
    #
    # It does not loosen suppression while the pen is genuinely about: a pen
    # in range reports continuously, so its own packets keep resetting the
    # deadline. And a contact that was open while the pen was still being
    # seen stays latched dead regardless — @touch_blocked is per contact, and
    # only a lift (or a resume) clears it.
    def expire_pen_proximity
      return self unless @pen_near && @pen_seen_at
      elapsed = @clock.monotonic_ms - @pen_seen_at
      # A negative elapsed is the 32-bit wrap touch_suppressed? documents,
      # and reads the same way here: expired. Recovering a second early once
      # every 24.8 days beats a dead touchscreen for the same window.
      @pen_near = false if elapsed < 0 || elapsed >= PEN_SILENCE_MS
      self
    end

    # Everything the loop believes about the glass, unlearned. Called on
    # resume, where none of it can be trusted any more (see handle_resume).
    #
    # A fresh cooldown rather than a clean slate: a hand is quite likely to
    # be on the glass at the moment the game comes back, and the pen's next
    # packet is the first evidence either way. The pen's own stroke state is
    # deliberately left alone — an interrupted stroke is one wrong line, not
    # a dead input device, and the pen path is verified on hardware.
    def forget_input_state
      @pen_near = false
      @pen_seen_at = nil
      @pen_left_at = @clock.monotonic_ms
      close_touch_contact
    end

    # True while a touch contact must not be allowed to press anything: the
    # pen is in proximity, or it left less than TOUCH_COOLDOWN_MS ago.
    #
    # A negative elapsed can only mean the clock wrapped — monotonic_ms is
    # an mrb_int, 32-bit on the device, so it wraps after 24.8 days of
    # process life — and is read as "long expired". The alternative would be
    # suppressing touch for another 24 days.
    def touch_suppressed?
      return true if @pen_near
      return false unless @pen_left_at
      elapsed = @clock.monotonic_ms - @pen_left_at
      elapsed >= 0 && elapsed < TOUCH_COOLDOWN_MS
    end

    # @touch_blocked is a latch, not a check: a contact born while the pen
    # was about must lift and press again before it can ever count, so that
    # a palm resting on Quit can never fire it merely because the pen was
    # set aside. It also latches on any later sample taken while the pen is
    # about, which covers the palm that lands a moment BEFORE the pen is
    # detected — same hazard, same answer, and re-tapping a button is a
    # cheap price for never quitting someone's game by accident.
    def begin_touch(x, y)
      @touch_last = [x, y]
      @touch_travel = 0
      @touch_blocked = touch_suppressed?
      @touch_button = Layout.button_at(x, y)
      # A finger on the board (or anywhere off a button) opens a stroke that
      # can only ever do nothing — the same :none the pen uses, and the
      # reason a finger cannot ink: nothing here consults Layout.cell_at.
      @touch_mode = @touch_button ? :button : :none
    end

    def continue_touch(x, y)
      @touch_travel += (x - @touch_last[0]).abs + (y - @touch_last[1]).abs
      @touch_blocked = true if touch_suppressed?
      @touch_last = [x, y]
    end

    # Same tap discipline as the pen — start and end on one button, having
    # travelled little in between — with the finger's own travel budget, and
    # one extra condition the pen does not have: the pen must have stayed
    # away for the whole contact.
    def end_touch(x, y)
      @touch_travel += (x - @touch_last[0]).abs + (y - @touch_last[1]).abs
      @touch_blocked = true if touch_suppressed?
      press(@touch_button) if touch_tap?(x, y)
      close_touch_contact
    end

    # The touch contact's state, as if no finger had ever been on the glass.
    # Shared with forget_input_state, because a resume has to do exactly this
    # to a contact whose lift packet it may never see.
    def close_touch_contact
      @touch_mode = nil
      @touch_last = nil
      @touch_button = nil
      @touch_travel = 0
      @touch_blocked = false
    end

    def touch_tap?(x, y)
      @touch_mode == :button && !@touch_blocked &&
        @touch_travel <= TOUCH_TAP_MAX_PATH &&
        Layout.button_at(x, y) == @touch_button
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
      when :quit then quit
      when :level then cycle_difficulty
      when :new then clear_ink
      end
    end

    # New and Level repaint as their action, so they read as responsive for
    # free. Quit is the one press whose action is to disappear — and e-ink
    # holds the last image it was given, so the board stays on the panel
    # through teardown and a tap that worked looks like a tap that did
    # nothing (observed on the device: the game exits, xochitl comes back a
    # moment later, and in between the frozen board is all there is to see).
    # So acknowledge first, in the one waveform fast enough to arrive before
    # the exit it announces — and then hold it. An earlier version of this
    # comment argued the opposite, that sending the update was enough and
    # quitting should not wait on the panel; on the device the flash was not
    # reliably perceptible, and feedback nobody can see is not feedback.
    def quit
      acknowledge_quit
      @running = false
    end

    # The press is a courtesy; the exit is the contract. The display socket
    # carries a 10 s receive timeout, so a server that stops acking makes
    # press_button raise SystemCallError — and an exception here would
    # unwind past main.rb's explicit display.close, leaving the user's
    # screen to come back whenever a finalizer got round to it. So the
    # acknowledgement may fail, and quitting still proceeds.
    #
    # A failed press also skips the hold: there is nothing on the panel to
    # look at, and a wedged server should be quit fast, not 200 ms slower.
    def acknowledge_quit
      @renderer.press_button(:quit)
      # Not a spin and not a new dependency: RM2::Input.wait with nothing to
      # watch polls no descriptors for the whole timeout, which is exactly a
      # bounded sleep (see the rm2 gem's input.c). An empty list is passed on
      # purpose — waiting on the real sources would return the moment the
      # next pen sample arrived and hold nothing.
      @waiter.wait([], QUIT_ACK_MS)
      true
    rescue StandardError
      false
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
