module Redoku
  # The event loop. One stroke at a time: what a stroke does is decided
  # where the pen went down and WITH WHICH END (ink on the board from the tip,
  # a cleared cell from the eraser, a tap on a button, nothing anywhere else),
  # so dragging out of a region — or flipping the pen mid-stroke — can never
  # surprise the user.
  #
  # The pen writes with one end and erases with the other, and presses
  # buttons with either; a finger can only press buttons.
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

    # How long a pressed button is held inverted on the panel — for Quit,
    # before the loop stops; for the other two, before the button is painted
    # back. Feedback nobody can see is not feedback: the DU flash lands and
    # then the next thing happens, and on the device an unheld flash was not
    # reliably perceptible. 200 ms is the duration the owner approved on
    # hardware for Quit, and every button now gets that one rather than a
    # second calibration of its own.
    PRESS_ACK_MS = 200

    # How many times a generation that FAILED OUTRIGHT -- raised, or answered
    # nil -- is tried before the board is left as it was. Deliberately small
    # and deliberately BOUNDED, unlike a tier miss: an exception or an empty
    # answer means the engine produced nothing, which is a fault rather than
    # bad luck, and retrying a fault for ever would hang the game on a device
    # whose only escape is the power button. Conflating the two paths is how an
    # engine bug becomes an infinite loop.
    GENERATE_TRIES = 3

    # How far the progress bar's filled edge must move before it is worth a
    # panel refresh. E-ink updates are not free -- DU + FAST_DRAW is the cheap
    # two-level waveform and still costs tens of milliseconds -- and :master's
    # budget fires the hook up to 150 times per round.
    #
    # 30 px of a 614 px interior is about 5%. Because the fraction is
    # num/(num+total) rather than num/total, one full :master round only ever
    # reaches 614*150/300 = 307 px, so a round costs about TEN paints, not
    # twenty; and because the bar is monotone and asymptotic to 614 px, the
    # whole press -- however many rounds it runs -- costs at most about twenty.
    # MEASURED, not estimated: a full 150-attempt round paints exactly ten
    # times (test/app.rb, 'the bar is painted at most once per visible step'),
    # at attempts 8, 17, 27, 38, 51, 65, 81, 100, 122 and 149. Roughly a second
    # of paint inside a search measured in seconds, and it does not grow with
    # the tail. Painting per attempt instead would add 150 refreshes per round
    # and could double a :hard dig.
    PROGRESS_STEP_PX = 30

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

    # ink_dirty is the pending pen damage — ink laid down, or a cell repainted
    # to take ink away — as INCLUSIVE corners [x1, y1, x2, y2]: the one rect
    # in this codebase that is not [x, y, w, h] with exclusive edges, because
    # it grows corner by corner as segments arrive and is converted only on
    # its way out, in flush_ink.
    #
    # `grid` is the puzzle on the board (nil until the first dig), `solution`
    # its answer and `achieved_tier` the tier the generator actually reached —
    # see fill_board for why the last of those is stored rather than shown.
    attr_reader :difficulty, :ink_dirty, :grid, :solution, :achieved_tier,
                :current_save_id, :screen, :ink_strokes

    # `rng:` IS the boundary between a varying device and deterministic tests.
    # Its default reads the wall clock, so each launch deals a different
    # puzzle; Ruby evaluates a keyword default only when the argument is
    # omitted, so a test that passes its own fixed-seed Rng never touches
    # Time.now and generates the same boards every run.
    #
    # `generator:` is the same kind of seam as `waiter`, `signals`, `clock` and
    # `rng`: the thing this loop cannot afford to run for real in a test. The
    # retry behaviour in fill_board is a control structure -- one path bounded,
    # one deliberately not -- and a control structure needs a collaborator that
    # can be told to fail. It also keeps the suite off the real search, which
    # for :expert is measured in seconds.
    #
    # `log:` is where the generation report goes: which rung, how many rounds,
    # how many attempts, how many milliseconds. That line is the ONLY way the
    # real cost distribution on the device ever becomes visible -- every timing
    # in the design document is a host figure times an assumption, because the
    # tablet was unreachable when it was written. The game runs from a shell,
    # so stderr is read.
    #
    # GUARDED AT EVERY USE (`@log.puts(...) if @log`), and the guard earns its
    # keep for the ordinary reason rather than an exotic one: the tests pass
    # `nil`, because a suite that logged by accident would print a generation
    # report for every one of the sixty-odd App assertions. It is cheap
    # insurance for a second reason too -- $stderr comes from mruby-io, which
    # this gem does not DECLARE (see Global Constraint 1), so it is present here
    # only by grace of `conf.gembox 'default'` in both build targets. It really
    # is present in both, device and mrbtest alike (main.rb has written to it
    # since M1), so this is not a workaround for a missing global; it is what
    # lets one line of logging be switched off by a caller.
    #
    # `store:` is the save database, injected like `generator:` for the same
    # reason: tests use tmp files and fakes, never /home/root. It may be nil —
    # main.rb passes nil when the DB could not be opened — and every use is
    # guarded, because persistence is a courtesy and the puzzle is the
    # contract: a broken store costs saves, never the game.
    def initialize(display, sources, renderer, waiter = RM2::Input,
                   signals = RM2, touch_sources: [], clock: RM2,
                   rng: Rng.from_clock, generator: Sudoku::Generator,
                   log: $stderr, store: nil)
      @d = display
      @sources = sources
      @touch = touch_sources
      @renderer = renderer
      @waiter = waiter
      @signals = signals
      @clock = clock
      @rng = rng
      @generator = generator
      @log = log
      @store = store
      @difficulty = Sudoku::Rater::TIERS[0]
      # No puzzle until something asks for one. Generation is a search of tens
      # of milliseconds here and PLAN.md §7 budgets a few hundred on the
      # device, so it does not belong in a constructor that every test — and
      # every future test — runs.
      @grid = nil
      @solution = nil
      @achieved_tier = nil
      # The row the board on the glass came from: the autosave id after a dig
      # or a resume, nil while nothing is saved. Manual saves are a Task 4
      # flow; until then this only ever names an autosave row.
      @current_save_id = nil
      @running = true
      # Which screen the presses belong to: :play is the board, :menu is the
      # GAMES list (M3a). NOT @mode — that name has meant "what this stroke
      # is doing" since M1 (:ink/:erase/:button/:none) and a second meaning
      # on the same ivar would make every stroke decision read both. The
      # plan document's "@mode (:play / :menu)" landed here as @screen for
      # exactly that reason.
      @screen = :play
      @page = 0          # GAMES menu page, when the list spans several
      @delete_mode = false # GAMES menu: next row tap deletes instead of loads
      @mode = nil       # :ink, :erase, :button, :none, or nil: no stroke open
      @last = nil       # previous point of this stroke
      @button = nil     # the button this stroke went down on, if any
      @travel = 0       # distance travelled so far, for tap detection
      @ink_dirty = nil  # pending ink damage, inclusive corners
      @erased = nil     # last cell this erase stroke cleared (see erase_at)
      # The stroke journal (M3a Task 6). @ink_strokes is every completed
      # stroke of the board on the glass, in draw order — the in-memory copy
      # of what the store holds under @current_save_id. While no autosave
      # exists yet (@current_save_id nil — no dig has succeeded this session)
      # it doubles as the BUFFER: strokes stay here and are discarded the
      # moment a dig lands, because a dig repaints the board and wipes the
      # glass first, so flushing them would resurrect ink nobody can see.
      # Once an autosave exists each completed stroke is journaled to the
      # store immediately (crash-safe, same philosophy as the autosave row).
      @ink_strokes = []
      # Capture state for the stroke OPEN right now: subpaths being built,
      # the subpath under construction, its last recorded endpoint, and a
      # running point count against Store::MAX_STROKE_POINTS. All nil/zero
      # whenever no ink stroke is open.
      @stroke_subs = nil
      @stroke_cur = nil
      @stroke_from = nil
      @stroke_count = 0

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

    # The opening paint carries the SPLASH, and that ordering is the point:
    # the first puzzle is dug before the loop starts, and that dig is the
    # longest pause of the session. draw_all lays down the chrome, draw_splash
    # replaces the board area with the status text, and one GC16 SYNC puts
    # both on the panel — so the player reads GENERATING... rather than
    # staring at an empty grid wondering whether the tap worked.
    #
    # One paint, not two: new_puzzle's own splash flush would be a second
    # board refresh over a board that has this instant been painted with the
    # splash already on it, so fill_board is called directly instead.
    #
    # UNLESS there is an autosave to resume (M3a Task 3). Then the saved game
    # comes back INSTEAD of the dig: chrome painted with the SAVED difficulty,
    # the puzzle drawn on top exactly as handle_resume does after a suspend,
    # the saved ink replayed over it (Task 6), one flush.
    # The splash and the progress bar are generation UI; resuming digs
    # nothing, so they do not belong on the panel.
    def run
      if restore_saved
        @renderer.draw_all(@difficulty)
        @renderer.draw_puzzle(@grid)
        @renderer.draw_ink(@ink_strokes)
        @renderer.flush_all
      else
        @renderer.draw_all(@difficulty)
        @renderer.draw_splash
        # The empty bar goes out on the SAME flush as the splash, so it costs no
        # refresh of its own -- the player sees a bar waiting to move rather than
        # one appearing from nowhere a second later.
        reset_progress
        @renderer.draw_progress(0, 1)
        @renderer.flush_all
        fill_board
      end
      while @running
        step
        handle_resume if @signals.resumed?
        @running = false if @signals.terminated?
      end
      shutdown_persistence
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

    # RM2::Input::TOUCH is the tool pressed against the glass and says nothing
    # about WHICH end is pressed; RUBBER is the tool identity, reported while
    # the eraser end is in proximity (PEN while the tip is — the digitizer
    # latches one tool on proximity entry and reports only that one). So the
    # two bits are read together here: contact from TOUCH, meaning from
    # RUBBER, and the meaning is handed to begin_stroke and latched there for
    # the whole stroke. Re-reading it per sample would let a stroke change
    # identity halfway, which no other stroke decision in this loop can do.
    def handle_sample(sample)
      raw_x, raw_y, _pressure, tools = sample
      note_pen_proximity(tools)
      x, y = Pen.to_screen(raw_x, raw_y)
      down = (tools & RM2::Input::TOUCH) != 0
      # RUBBER set AND PEN clear, not RUBBER alone. `tools` is a STICKY mask
      # whose bits are set and cleared per evdev code independently (the rm2
      # gem's input.c: `if (ev->value != 0) in->tools |= bit; else in->tools
      # &= ~bit;`), so PEN | RUBBER together is reachable — it is exactly what
      # a LOST `BTN_TOOL_RUBBER 0` packet leaves behind, and the two things
      # that eat such a packet are the same two PEN_SILENCE_MS exists for: the
      # display server draining a thawed client's evdev backlog, and
      # SYN_DROPPED. The digitizer then never mentions RUBBER again, because it
      # only ever reports the tool actually in range, so reading RUBBER alone
      # would make every later TIP stroke erase the cell the player meant to
      # write in — for the rest of the session, recoverable only by flipping
      # the pen over and back, which nobody would guess. That is the shape of
      # the bug the lost-packet fix took out of the touch path, pointed the
      # destructive way.
      #
      # A both-bits packet is corrupt by definition, and the safe reading of
      # corruption in a DESTRUCTIVE decision is "ink": it is the trade
      # fill_board already makes when a dig hands back nil, where an unchanged
      # board beats a wiped one. Guess wrong this way and the player gets a
      # stroke of ink in a cell they wanted cleared, which they can erase;
      # guess wrong the other way and they lose writing they cannot get back.
      #
      # note_pen_proximity keeps ORing the two bits, deliberately, and that is
      # not an inconsistency: proximity asks "is any end of the tool near the
      # glass", where either bit is evidence enough and a stuck one merely
      # over-suppresses touch until PEN_SILENCE_MS expires it. Only a
      # destructive decision needs the strict reading, so only this one gets
      # it.
      erasing = (tools & RM2::Input::RUBBER) != 0 &&
                (tools & RM2::Input::PEN) == 0

      if down && @mode.nil?
        begin_stroke(x, y, erasing)
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

    # Pushes pending pen damage to the panel with the fast waveform. Ink is
    # drawn into the shared buffer as it arrives but flushed at most once per
    # loop turn: fewer round trips, and the pen still keeps up.
    #
    # Erasing shares this channel rather than flushing per cell, and the
    # waveform is the reason. RM2::DU + FAST_DRAW is the cheap two-level
    # waveform the pen echo and the button flash already use — about a tenth of
    # a GL16 chrome refresh — and undrawing has to feel as immediate as
    # drawing, or the eraser reads as broken. Everything a cell repaint puts
    # back on an M2 board is black on white (grid lines, a given digit in
    # GIVEN_GRAY, white paper), which is all two levels can carry, so nothing
    # is lost by sending it this way.
    #
    # WHERE THAT STOPS BEING TRUE, for M3: DU is two-level, so an
    # ENTRY_GRAY (96) digit flushed through here would be thresholded to black
    # or white rather than printed in its own tone — the very distinction
    # PLAN.md §8 wants between a clue and a guess. Nothing in M2 can hit that
    # (there are no entries yet), but the first repaint that puts a player's
    # entry back on the glass needs GL16 for that region, not this.
    def flush_ink
      return self unless @ink_dirty
      x1, y1, x2, y2 = @ink_dirty
      @ink_dirty = nil
      @renderer.flush_rect(x1, y1, x2 - x1 + 1, y2 - y1 + 1,
                           waveform: RM2::DU, flags: RM2::FAST_DRAW)
      self
    end

    # New: a fresh puzzle, and the ink the player had written goes with it.
    #
    # Repainting and flushing board_rect alone is enough to clear that ink,
    # because ink cannot exist anywhere else: ink_to refuses any segment with
    # an endpoint off the board, so every stamped pixel is within
    # INK_WIDTH / 2 of a line inside board_rect — that is, inside it or on
    # the Layout::BLOCK_LINE / 2 frame overhang, which draw_board repaints
    # black over black (see Renderer#flush_board). That holds only while
    # INK_WIDTH <= Layout::BLOCK_LINE, which is 4 and 4 today: a fatter
    # brush reaches past the frame band onto white background, where stray
    # ink would survive New and no host test could see it, because the mock
    # records the update rather than rendering it. Raise INK_WIDTH and both
    # flushes here have to widen with it.
    #
    # The splash is drawn and FLUSHED BEFORE the dig, not after: it is the
    # only progress indication the player gets for a pause PLAN.md §7 budgets
    # at a few hundred ms on the Cortex-A7, and a progress indication that
    # reaches the panel once the work has finished is worse than none. It goes
    # out through flush_board because draw_splash paints exactly board_rect
    # (see Renderer#draw_splash), so the region is already the right one.
    #
    # No argument to draw_splash. Renderer::SPLASH_TEXT is pinned and
    # glyph-asserted in one place because Font.draw silently draws NOTHING for
    # a character it has no glyph for — the font holds only uppercase A-Z,
    # 0-9, space, '-', ':' and '.' — so a literal here could paint a blank
    # board under a fully green test suite.
    #
    # Public because it is what a New press does and what a test drives
    # directly; the dig itself is fill_board, which cycle_difficulty and run
    # also reach.
    # An EMPTY BAR goes up with the splash, on the splash's own flush, for the
    # same reason run does it: it costs no extra refresh, and a bar that
    # appears from nowhere partway through a search reads worse than one that
    # was always there waiting to move.
    def new_puzzle
      @ink_dirty = nil
      @renderer.draw_splash
      reset_progress
      @renderer.draw_progress(0, 1)
      @renderer.flush_board
      fill_board
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
      # Repaint whatever screen the player was on: a SIGCONT that lands in
      # the GAMES menu must bring the menu back, not the board underneath it.
      if @screen == :menu
        refresh_menu
        return self
      end
      @renderer.draw_all(@difficulty)
      # draw_all paints an EMPTY board, so the puzzle has to go back on top of
      # it: without this the first suspend and resume would silently wipe the
      # board the player was working on. Guarded because handle_resume is
      # reachable before anything has been dug — every resume test does
      # exactly that — and draw_puzzle wants a Grid. The ink comes back too
      # (Task 6), from the same journal the load and resume paths read.
      @renderer.draw_puzzle(@grid) if @grid
      @renderer.draw_ink(@ink_strokes)
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
    # packet is the first evidence either way.
    #
    # The pen's own stroke state is deliberately left alone, and the worst case
    # for that is no longer merely one wrong line: with :erase in the set, a
    # stroke still open across a resume can go on CLEARING CELLS. The decision
    # holds anyway, because of what handle_resume does immediately after this —
    # draw_all plus draw_puzzle repaint the whole board from the model, which
    # is exactly what a continued erase would do to one cell of it, so the
    # continuation is a no-op rather than a loss. What it is not is a dead
    # input device, which is what the latches above would otherwise become.
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
    #
    # That second half is best-effort, not a second rule, and the honest
    # reason is the kernel: it drops a frame in which nothing changed, so a
    # PERFECTLY still contact emits nothing after its down packet and there
    # is no later sample to re-latch on. In practice a resting palm jitters
    # and end_touch re-checks at the lift, so the hole is narrow — but it is
    # a hole, and the birth latch is what actually carries the guarantee.
    def begin_touch(x, y)
      @touch_last = [x, y]
      @touch_travel = 0
      @touch_blocked = touch_suppressed?
      @touch_button = target_at(x, y)
      # A finger on the board (or anywhere off a button) opens a stroke that
      # can only ever do nothing — the same :none the pen uses, and the
      # reason a finger cannot ink: nothing here consults Layout.cell_at.
      # In the GAMES menu the board area means rows instead, so a finger can
      # work the saves list exactly as the pen does.
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
        target_at(x, y) == @touch_button
    end

    # @last and @travel are kept for every stroke, not only an inking one:
    # the travel that tells a tap from a drag has to accumulate on a button
    # stroke too, or TAP_MAX_PATH would never bite and any drag ending on
    # Quit would quit. @button remembers what was pressed, so the release
    # can be checked against it without asking Layout twice.
    #
    # `erasing` is the eraser end of the pen, and it only means anything on the
    # board: off the board a stroke is a button press or nothing, whichever end
    # of the pen made it. That is a decision rather than an oversight — the
    # chrome is not a writing surface, so there is nothing there for an eraser
    # to mean, and it is the same pen in the same hand, where a tap is a tap.
    def begin_stroke(x, y, erasing = false)
      @last = [x, y]
      @travel = 0
      @erased = nil
      if Layout.cell_at(x, y) && @screen == :play
        @button = nil
        @mode = erasing ? :erase : :ink
        # An ink stroke opens its capture here — the journal needs the whole
        # polyline, and a stroke's meaning is latched at pen-down, so this is
        # also the only place capture can start.
        if @mode == :ink
          @stroke_subs = []
          @stroke_cur = nil
          @stroke_from = nil
          @stroke_count = 0
        end
        erase_at(x, y)
      else
        # Off the board — or ON it while the GAMES menu is up: the menu's
        # rows are the board area's other meaning, and a screen that lists
        # saves is no more a writing surface than the chrome is. The stroke
        # latches whatever the current screen says this point means.
        @button = target_at(x, y)
        @mode = @button ? :button : :none
      end
    end

    def continue_stroke(x, y)
      @travel += (x - @last[0]).abs + (y - @last[1]).abs
      ink_to(x, y)
      erase_at(x, y)
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
      erase_at(x, y)
      press(@button) if tap?(x, y)
      close_ink_capture
      @mode = nil
      @last = nil
      @button = nil
      @travel = 0
      @erased = nil
    end

    # A completed ink stroke leaves the capture and goes two places at once:
    # into @ink_strokes (the board's in-memory journal, what repaints draw
    # from) and — when an autosave row exists to hang it on — into the store,
    # immediately, one INSERT. Crash-safe per stroke: a power cut between two
    # strokes loses nothing but the stroke that had not ended yet.
    def close_ink_capture
      subs = @stroke_subs
      @stroke_subs = nil
      @stroke_cur = nil
      @stroke_from = nil
      @stroke_count = 0
      return if subs.nil? || subs.empty?
      stroke = { color: INK_GRAY, width: INK_WIDTH, subpaths: subs }
      @ink_strokes << stroke
      return unless @store && @current_save_id
      @store.journal_stroke(@current_save_id, stroke[:color],
                            stroke[:width], stroke[:subpaths])
    rescue StandardError => e
      log_line('stroke journal failed (' + e.message + ')')
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
      note_ink(@last, [x, y])
    end

    # Records one drawn segment into the open stroke's capture. Consecutive
    # samples append to the same subpath; an excursion off the board (which
    # ink_to refuses to draw across) leaves a gap that starts a NEW subpath,
    # so the replay connects exactly the segments that were drawn and never
    # bridges a gap. Recording stops at Store::MAX_STROKE_POINTS — the live
    # ink keeps flowing either way; what stops is only how much of this
    # stroke survives a reload.
    def note_ink(from_pt, to_pt)
      return if @stroke_subs.nil?
      return if @stroke_count >= Store::MAX_STROKE_POINTS
      if @stroke_cur.nil? || @stroke_from != from_pt
        @stroke_cur = [from_pt]
        @stroke_subs << @stroke_cur
      end
      @stroke_cur << to_pt
      @stroke_from = to_pt
      @stroke_count += 1
    end

    # The eraser's counterpart to ink_to, in the same shape: @mode is checked
    # first, so a tip stroke or a button stroke costs no geometry at all, and
    # a point off the board does nothing.
    #
    # There is nothing to UNdraw. Ink goes straight into the shared
    # framebuffer, one draw_line per segment, with no journal and no per-cell
    # backing store, so the only way back is to repaint the cell as the model
    # says it should look — which is Renderer#redraw_cell, and is also exactly
    # the primitive M3's recogniser needs when it replaces a cell's raw ink
    # with a printed digit.
    #
    # @grid may still be nil, on an App that has not dug a board yet;
    # redraw_cell reads that as "no digit to put back" and clears the cell all
    # the same, because the ink is on the glass either way.
    #
    # @erased is a ONE-cell latch, not a set of every cell this stroke has
    # cleared. A cell cannot acquire new ink while the eraser is down (ink_to
    # refuses for @mode == :erase), so repainting the cell under every sample
    # would be some 100 identical cell repaints a second on the Cortex-A7 for
    # no visible change. Dragging out of a cell and back into it erases it a
    # second time, which is idempotent and cheaper to allow than to remember.
    #
    # Damage goes into the pen's own pending rect as INCLUSIVE corners, so
    # flush_ink pushes it — one flush per loop turn however many cells a drag
    # crossed, in the same waveform as the ink it removes (see flush_ink).
    def erase_at(x, y)
      return unless @mode == :erase
      cell = Layout.cell_at(x, y)
      return unless cell
      index = Sudoku::Grid.index_of(cell[0], cell[1])
      return if index == @erased
      @erased = index
      @renderer.redraw_cell(index, @grid)
      cx, cy, cw, ch = Layout.cell_rect(cell[0], cell[1])
      mark_dirty(cx, cy, cx + cw - 1, cy + ch - 1)
    end

    # A tap starts and ends on the same button, having travelled little in
    # between. Sliding off the button before releasing cancels it — the
    # standard affordance, and one more thing that has to go right before
    # Quit fires.
    def tap?(x, y)
      @mode == :button && @travel <= TAP_MAX_PATH &&
        target_at(x, y) == @button
    end

    # What a press point means on the CURRENT screen: the chrome buttons in
    # play mode; in the GAMES menu those same rects mean BACK/DEL/SAVE/QUIT,
    # plus PREV/NEXT in the header band and one row per board band. Both
    # stroke paths (pen and finger) ask this at pen-down and again at lift,
    # so a stroke that slides to a different meaning cancels itself exactly
    # as sliding off a button always has.
    def target_at(x, y)
      return Layout.button_at(x, y) if @screen == :play
      menu_target_at(x, y)
    end

    def menu_target_at(x, y)
      case Layout.button_at(x, y)
      when :new   then return :back
      when :level then return :del
      when :games then return :save
      when :quit  then return :quit
      end
      b = Layout.menu_button_at(x, y)
      return b if b
      # A plain Integer row index (0..8), or nil for dead space.
      Layout.menu_row_at(x, y)
    end

    def press(target)
      if @screen == :menu
        press_in_menu(target)
        return self
      end
      case target
      when :quit then quit
      when :level then acknowledge(:level) { cycle_difficulty }
      when :new then acknowledge(:new) { new_puzzle }
      when :games then acknowledge(:games) { open_menu }
      end
    end

    # Menu presses. Every action repaints its own result (refresh_menu or a
    # full play-mode repaint), which is why the repainting ones run inside
    # acknowledge like every other press — and why the acknowledgement's
    # restore half is what decides whether the flash survives its own
    # action:
    #
    # - BACK/SAVE/PREV/NEXT come back up, because their actions repaint
    #   regions that include their buttons but no button pass repaints them;
    # - a ROW stays down (restore: false): loading a save repaints everything
    #   anyway, and deleting repaints the menu — either way the inverted row
    #   it flashed is gone under the repaint, and painting it "back" would
    #   flush stale pixels over whatever the action just put there.
    #
    # DEL acknowledges nothing: its feedback is PERSISTENT, not transient —
    # the armed state is the label sitting inverted (draw_menu_buttons), and
    # refresh_menu paints exactly that. A press-flash under it would be two
    # inversions racing to one panel, and a release would un-arm the mode on
    # the glass while it stayed armed in the model.
    #
    # An unknown target cannot reach here (both stroke paths latch nil for
    # dead space and nil never presses), so the case simply falls through.
    def press_in_menu(target)
      case target
      when :quit then quit
      when :back then acknowledge(:back) { close_menu }
      when :del then toggle_delete_mode
      when :save then acknowledge(:save, restore: false) { save_manual_copy }
      when :prev then acknowledge(:prev) { turn_page(-1) }
      when :next then acknowledge(:next) { turn_page(1) }
      else
        return unless target.is_a?(Integer)
        acknowledge(target, restore: false) { row_chosen(target) }
      end
    end

    # --- the GAMES menu (M3a). State: @screen, @page, @delete_mode. Every
    # transition repaints its own result, and every store touch goes through
    # the same guarded seam as the autosave paths: persistence is a
    # courtesy, so a store that raises or answers empty costs menu rows and
    # log lines, never the game.

    def open_menu
      @screen = :menu
      @page = 0
      @delete_mode = false
      refresh_menu
      self
    end

    def close_menu
      @screen = :play
      @page = 0
      @delete_mode = false
      @renderer.draw_all(@difficulty)
      @renderer.draw_puzzle(@grid) if @grid
      @renderer.draw_ink(@ink_strokes)
      @renderer.flush_all
      self
    end

    # The one way the menu reaches glass: read the list, paint everything,
    # one GC16. Re-reading Store#games per refresh rather than caching is
    # deliberate — the list only changes through this UI, but "only" is
    # doing real work there, and the query costs microseconds against an
    # e-ink refresh measured in tenths.
    def refresh_menu
      @renderer.draw_games_menu(games_list, @page, @delete_mode)
      @renderer.flush_all
      self
    rescue StandardError => e
      log_line('could not show saved games (' + e.message + ')')
      close_menu
      self
    end

    def games_list
      return [] unless @store
      @store.games
    end

    # Page turns clamp instead of wrapping: a list of two pages that walks
    # NEXT, NEXT would otherwise fling the player from the last row back to
    # the first past three dead screens' worth of flicker.
    def turn_page(step)
      pages = page_count(games_list.size)
      page = @page + step
      return self if page < 0 || page >= pages
      @page = page
      refresh_menu
      self
    end

    def toggle_delete_mode
      @delete_mode = !@delete_mode
      refresh_menu
      self
    end

    # The tapped row: delete it in delete mode (one tap spends the mode —
    # arm, tap, done — because a second deliberate gesture is what stands
    # between a stray finger and someone's save), otherwise load it.
    # `index` is PAGE-LOCAL (0..8, what Layout.menu_row_at answers); the list
    # is not, so it is resolved against the full games_list through the page
    # offset — tapping row 0 of the second page must reach list position 9,
    # not 0. Out of range (a page whose tail a deletion just shortened) is a
    # no-op, never a crash; the refresh below still runs for the delete path.
    def row_chosen(index)
      list = games_list
      pos = @page * Renderer::MENU_ROWS + index
      game = pos >= 0 && pos < list.size ? list[pos] : nil
      if @delete_mode
        @store.delete(game[:id]) if game && @store
        @delete_mode = false
        pages = page_count(games_list.size)
        @page = pages - 1 if @page >= pages
        refresh_menu
      elsif game
        load_game(game[:id])
      end
      self
    end

    # Loads a save and returns to the board. A record that fails validation
    # (Store#load already skipped-and-logged it) leaves the menu up rather
    # than dumping the player onto an unchanged board with no explanation:
    # the menu is where they can pick another save.
    def load_game(id)
      rec = @store ? @store.load(id) : nil
      return self unless rec
      return self unless adopt_record(rec)
      @screen = :play
      @page = 0
      @delete_mode = false
      @renderer.draw_all(@difficulty)
      @renderer.draw_puzzle(@grid)
      @renderer.draw_ink(@ink_strokes)
      @renderer.flush_all
      log_line('loaded saved game ' + id.to_s)
      self
    end

    # The SAVE action inside the menu: writes a manual copy of whatever is
    # on the board, then repaints the list — the new row IS the press's
    # visible result, and a menu that stays stale after a save reads (and
    # tested) as a button that did nothing. Refusals are the store's to
    # report (no board, invalid record, cap of MANUAL_CAP reached) and are
    # logged there; this side stays quiet about a nil answer because the
    # reason is already on stderr, but it still repaints: restore: false in
    # press_in_menu means this method owns putting the glass right on every
    # path out of here, refusal included. The autosave row keeps its own
    # life regardless — a manual copy is a bookmark, not a replacement for
    # the crash-safe singleton.
    def save_manual_copy
      return refresh_menu unless @store
      id = @store.save_manual(@grid ? current_game_record : nil)
      if id && @current_save_id
        # The bookmark takes the ink with it, so loading it later restores
        # the board AND the marks on it. No autosave id (nothing dug) means
        # no strokes either — save_manual was handed nil and refused.
        @store.copy_strokes(@current_save_id, id)
      end
      log_line('saved manual copy ' + id.to_s) if id
      refresh_menu
      self
    rescue StandardError => e
      log_line('manual save failed (' + e.message + ')')
      refresh_menu
    end

    def page_count(size)
      count = size / Renderer::MENU_ROWS
      count += 1 if size % Renderer::MENU_ROWS > 0
      count == 0 ? 1 : count
    end

    # Quit is the one press that is not put back up. Its action is to
    # disappear, and e-ink holds the last image it was given, so the board
    # stays on the panel right through teardown and a tap that worked looks
    # like a tap that did nothing (observed on the device: the game exits,
    # xochitl comes back a moment later, and in between the frozen board is
    # all there is to see). The inverted button is therefore the goodbye —
    # restoring it would erase the only feedback the tap gives.
    def quit
      acknowledge(:quit, restore: false) { @running = false }
    end

    # Every press is answered at the button it was pressed on: paint it
    # inverted, get that onto the panel, run the action, hold the pressed
    # state long enough to read, paint it back.
    #
    # This used to be Quit's alone, on the premise that "New and Level
    # repaint as their action and already read as responsive". Both halves
    # are false, and the device said so — the owner's report was that New and
    # Level "don't flash inverted and nothing visual occured", while both
    # actions were in fact firing correctly the whole time. New's repaint —
    # then a bare clear_ink, now new_puzzle — was PIXEL-IDENTICAL on a board
    # with no ink, and cycle_difficulty's only visible change was a header
    # label about 1480 px from the finger that caused it, on a 1872 px screen.
    # Neither is invisible any more, now that both draw a fresh puzzle, but the
    # acknowledgement is what makes the tap land AT ONCE rather than after a
    # dig the player has no other reason to expect.
    #
    # ORDER — the action runs INSIDE the press, not before or after it.
    # 200 ms is how long a press lasts, not a toll the game may charge for
    # every tap: New's board repaint starts the moment the tap is recognised
    # and the button stays down while it happens, which is also what a button
    # does. Holding first and acting afterwards would make every action
    # 200 ms later than the tap and buy nothing; acting first and flashing
    # afterwards would put the acknowledgement after the result it is
    # supposed to announce.
    #
    # FAILURE — the press is a courtesy and the action is the contract (N1),
    # and that now covers all three buttons rather than Quit's alone, because
    # this is where display I/O joined the New and Level paths. The display
    # socket carries a 10 s receive timeout, so any of these flushes can
    # raise. `yield` sits outside every rescue, so the action happens exactly
    # once whatever the panel does. A press that never reached the panel is
    # neither held nor restored: there is nothing out there to hold or to put
    # back, and a wedged server should be answered fast, not 200 ms slower.
    # That can leave the shared BUFFER inverted — draw_button only writes
    # memory and cannot fail on a wedged server — which is harmless, because
    # the only things that ever flush a button's rect are these two calls and
    # draw_all + flush_all, and every one of them paints the button
    # immediately before flushing it.
    #
    # What this deliberately does NOT cover, because it is the actions' own
    # pre-existing shape rather than the acknowledgement's: a flush raised by
    # cycle_difficulty or new_puzzle themselves still unwinds out of the loop,
    # past main.rb's explicit display.close, and leaves the button inverted
    # on the way out. Containing that means making main.rb close the display
    # come what may, which is a change to the entry point, not to this
    # method.
    def acknowledge(name, restore: true)
      pressed = show_press(name)
      yield
      finish_press(name, restore) if pressed
      self
    end

    def show_press(name)
      @renderer.press_button(name)
      true
    rescue StandardError
      false
    end

    # The hold is not a spin and not a new dependency: RM2::Input.wait with
    # nothing to watch polls no descriptors for the whole timeout, which is
    # exactly a bounded sleep (see the rm2 gem's input.c). An empty list is
    # passed on purpose — waiting on the real sources would return the moment
    # the next pen sample arrived and hold nothing.
    def finish_press(name, restore)
      @waiter.wait([], PRESS_ACK_MS)
      @renderer.release_button(name) if restore
      true
    rescue StandardError
      false
    end

    # Level advances the tier, repaints the label AND digs a new board at the
    # new tier, because a tier means nothing until a puzzle of that tier is on
    # the glass — a Level press that only changed a word would be a setting,
    # not a button.
    #
    # Header first, puzzle second. The label is the cheap half and answers the
    # tap at once; new_puzzle's splash then covers the dig, which is the
    # expensive half. Doing it the other way round would leave the old tier's
    # name over the new tier's board for the whole search.
    def cycle_difficulty
      list = Sudoku::Rater::TIERS
      @difficulty = list[(list.index(@difficulty) + 1) % list.size]
      @renderer.draw_header(@difficulty)
      @renderer.flush_header
      new_puzzle
    end

    # Digs a puzzle at the current difficulty and puts it on the board. The
    # caller owns the splash — new_puzzle flushes one first, and run's opening
    # GC16 already carries one — so this is the second half of both.
    #
    # WHAT THE HEADER SHOWS is settled here, and it shows the REQUESTED tier:
    # @difficulty is what cycle_difficulty advanced, what draw_header printed
    # and what the generator was asked for. The header is the Level button's
    # read-out, not a rating of the board — a label that followed the achieved
    # tier would make the button unpredictable: ask for medium, get easy, the
    # label reads EASY, so the next press reads EASY as the current tier and
    # offers medium again, three presses stop visiting three labels, and HARD
    # can become unreachable. Splitting the two apart into "the tier you asked
    # for" and "the tier you got" is also what keeps M1's one-step-per-tap
    # guarantee (test/app.rb, 'the acknowledgement runs each action exactly
    # once') meaningful.
    #
    # Under the retry-without-limit rule that gap has NARROWED to one case, and
    # it is worth naming: a successful search only ever returns the tier that
    # was asked for, so @achieved_tier now means "the tier of the board
    # actually on the glass" and normally equals @difficulty. It differs only
    # after a FAULT, when the previous puzzle is kept while the header has
    # already been repainted with the new tier — a visible inconsistency,
    # logged rather than papered over, and an M3 UI question (surface the
    # achieved tier, or re-request) rather than something to fix here.
    #
    # THE NIL GUARD is required, not defensive: Generator.generate's "cannot
    # return nil" was an undocumented invariant spread over four methods in two
    # files, and the difficulty rework breaks it deliberately and re-establishes
    # it in ONE place — generate's own comment, which names all three failures
    # an attempt has to suffer (rejected floor, rejected neighbourhood,
    # rejected shallow fallback) before it yields nothing.
    #
    # AND IT REPAINTS EITHER WAY, which reverses half of the guard that landed
    # in 75eb7cf. That guard returned before the repaint so the splash stayed
    # up, on the grounds that "nothing new was actually dug" and saying so is
    # honest. It is not: e-ink holds the last image it was given, so a first
    # generation that fails leaves GENERATING... on the panel for ever with
    # nothing coming, which reads as a dead device rather than as an honest
    # report. The half that stands is the other one — an unchanged board beats
    # a wiped one (the stuck-RUBBER fix in 2bebc4e cites it by name as
    # precedent for resolving corruption toward the non-destructive answer) —
    # so a fault after a successful dig repaints the puzzle the player already
    # had, and only a fault with nothing ever dug paints empty.
    def fill_board
      found = search_for_puzzle
      if found
        @grid = found[:grid]
        # Kept, not used. M3's Check needs the answer and the generator has
        # already paid for computing it, so throwing it away would mean digging
        # a second time or solving the board again. Nothing in M2 reads it:
        # there is no Check here, by scope.
        @solution = found[:solution]
        @achieved_tier = found[:tier]
        # The dig is durable before the board is even on the glass: a power
        # cut an instant later resumes THIS puzzle, not a fresh search.
        persist_autosave
      end
      # New / Level cleared the glass the moment the splash went up — on the
      # FAULT path too, where the old puzzle comes back without its ink. The
      # journal follows the glass, whatever the search did: memory emptied,
      # and the persisted strokes of the row this board belongs to deleted.
      # This is also what disposes of any pre-dig buffered strokes.
      clear_ink_journal
      @renderer.draw_board
      # @grid is nil only when nothing has EVER been dug and this search
      # produced nothing: paint the empty board anyway (see above).
      @renderer.draw_puzzle(@grid) if @grid
      @renderer.flush_board
      self
    end

    # Ask until the requested tier arrives, or until the engine has failed
    # GENERATE_TRIES times. Returns the candidate, or nil.
    #
    # TWO PATHS, AND THEY MUST STAY DISTINCT:
    #
    #   TIER MISS — unbounded. The rung is rare (:master is available on 2% of
    #   chains, measured 1.3% over 300) and every retry draws a FRESH solution,
    #   so retrying resets the odds: the expected cost is about 1.06 full
    #   budgets, not 1/0.06. There is no fallback to an easier tier and never a
    #   wrong label. The tail is real, and the progress bar is what makes it
    #   readable as work rather than as a hang.
    #
    #   FAULT (a raise, or a nil reply) — bounded. Both mean the engine
    #   produced nothing at all, and retrying that for ever would spin on a bug
    #   behind a splash screen, on a device whose only escape is the power
    #   button.
    #
    # `faults` counts across the whole press rather than consecutively, and
    # that is the deliberate reading: a fault is evidence of a bug, so three of
    # them scattered through one long search are as much reason to stop as
    # three in a row. Counting consecutively would let an engine that fails
    # every other call retry for ever.
    def search_for_puzzle
      reset_progress
      started = @clock.monotonic_ms
      faults = 0
      rounds = 0
      while true
        rounds += 1
        out = attempt_generation
        if out.nil?
          faults += 1
          if faults >= GENERATE_TRIES
            log_line('generation gave up after ' + rounds.to_s +
                     ' rounds; keeping the board')
            return nil
          end
          next
        end
        # THE UNBOUNDED EDGE, and it is one line: a candidate of the wrong tier
        # is dropped and the loop turns again, with no counter to stop it.
        next unless out[:tier] == @difficulty
        log_line('generated ' + out[:tier].to_s.upcase + ' in ' +
                 rounds.to_s + ' rounds, ' + @progress_done.to_s +
                 ' attempts, ' + (@clock.monotonic_ms - started).to_s + ' ms')
        return out
      end
    end

    # One call to the generator. nil for either kind of outright failure; the
    # candidate otherwise, tier honest.
    #
    # The rescue is around the ENGINE, not around the painting: show_progress
    # swallows its own display errors (see there), so a wedged panel cannot be
    # mistaken for a broken dig and burn a generation try.
    def attempt_generation
      @generator.generate(@difficulty, @rng) do |done, total|
        show_progress(done, total)
      end
    rescue StandardError => e
      log_line('generation failed (' + e.message + ')')
      nil
    end

    # The numerator and the throttle, zeroed once per PRESS rather than once
    # per round — which is the whole of "the bar does not reset between
    # retries". search_for_puzzle calls this before its loop, deliberately not
    # inside it.
    def reset_progress
      @progress_done = 0
      @progress_px = 0
    end

    # THE FRACTION, and why it is this shape.
    #
    # The design had App paint (retry_index * total + done) / (retry_cap *
    # total), which needs a retry CAP — and decision 4 removed it, so that
    # denominator does not exist. What survives of the requirement is the part
    # that matters: the bar must not RESET between retries, because a long wait
    # that starts over reads as a hang.
    #
    # So: numerator is every attempt completed since the press, across every
    # retry; denominator is that plus one more full budget. The bar is
    # monotone, never resets, decelerates as the search runs long, and never
    # fills — which is honest, because a search that has not finished cannot
    # promise it is about to. One full budget spent shows half; two shows two
    # thirds. The board's arrival is the completion signal, and it costs no
    # extra refresh.
    #
    # NEVER FILLS IS AN INVARIANT, NOT AN OBSERVATION: `num < num + total`
    # holds for every `total >= 1`, so Renderer.progress_fill can never take
    # its `num >= den` branch and return a full 614 px. Every attempt budget in
    # Generator::ATTEMPTS is 6 or more, and DEFAULT_ATTEMPTS covers a tier the
    # table has never heard of, so nothing reachable passes 0 here. A caller
    # that ever did would fill the bar at the moment of least justification.
    #
    # `done` is IGNORED on purpose: it restarts at 1 for every retry, and the
    # numerator must not. Counting the block's own calls is what makes
    # monotonicity a property of the code rather than of the generator's
    # bookkeeping.
    #
    # THE ONE ARITHMETIC BOUND, written down rather than clamped because it
    # cannot be reached: @progress_done is the only unbounded counter in the
    # game, and progress_fill computes 614 * num, which overflows the device's
    # 32-bit mrb_int past about 3.5 million attempts. At :master's measured
    # 8 ms an attempt that is roughly 97 hours of unbroken generation behind
    # one splash. A clamp would be dead code guarding an impossibility.
    #
    # Display errors are swallowed here, exactly as show_press swallows them:
    # the bar is a courtesy and the puzzle is the contract, and a raise from
    # inside the search would otherwise be counted as a failed generation.
    # @progress_px is advanced BEFORE the paint, so a panel that raises costs
    # the bar one step rather than a retry storm against a wedged server.
    def show_progress(_done, total)
      @progress_done += 1
      num = @progress_done
      px = Renderer.progress_fill(num, num + total)
      return self if px - @progress_px < PROGRESS_STEP_PX
      @progress_px = px
      @renderer.draw_progress(num, num + total)
      @renderer.flush_progress
      self
    rescue StandardError
      self
    end

    def log_line(text)
      @log.puts('redoku: ' + text) if @log
      self
    end

    # --- persistence (M3a). Every path here is guarded: a store that is nil,
    # closed or mid-failure costs saves and log lines, never the game.

    # Brings the autosave back as the live game. False when there is nothing
    # to resume or the record will not rebuild; the caller then digs a fresh
    # puzzle, which is the same "an unchanged board beats a wiped one" trade
    # in the destructive direction.
    #
    # Entries are replayed through set_entry rather than handed to the
    # constructor so a future recognizer's saved entries land the same way
    # live play does. A stored entry on a GIVEN cell is skipped, not raised:
    # the store validated only shape, and one inconsistent cell must not
    # forfeit the other eighty.
    def restore_saved
      return false unless @store
      rec = @store.autosave
      return false unless rec
      return false unless adopt_record(rec)
      log_line('resumed saved game ' + rec[:id].to_s)
      true
    end

    # Makes a validated Store record the live game — givens onto a fresh
    # Grid, entries replayed over it, tier and solution back as they were.
    # Shared by resume-on-launch (restore_saved) and by loading a save out
    # of the GAMES menu (load_game), which is the whole point: a record is
    # either good enough to play from or it is refused whole, never half-
    # adopted. False (with the board left as it was) on any failure.
    def adopt_record(rec)
      grid = Sudoku::Grid.parse(rec[:givens])
      i = 0
      while i < Sudoku::Grid::CELLS
        ch = rec[:entries][i]
        grid.set_entry(i, ch.to_i) if ch != '.' && ch != '0' && !grid.given?(i)
        i += 1
      end
      @grid = grid
      @solution = values_of_board(rec[:solution])
      @difficulty = rec[:difficulty]
      @achieved_tier = rec[:achieved_tier]
      @current_save_id = rec[:id]
      # The ink travels with the game: whatever is journaled under this row
      # becomes the board's in-memory journal, ready for the caller's
      # repaint to replay. Corrupt rows were already skipped-and-logged
      # inside the store.
      @ink_strokes = @store ? @store.strokes(rec[:id]) : []
      true
    rescue StandardError => e
      log_line('could not restore saved game (' + e.message + ')')
      @grid = nil
      @solution = nil
      @achieved_tier = nil
      @current_save_id = nil
      @ink_strokes = []
      false
    end

    # Empties every copy of the current board's ink: memory, the open
    # capture (a stroke cannot be open across a press, but this costs
    # nothing) and — when the board has a save row — its persisted strokes.
    # Called from fill_board, i.e. from New, Level and the first dig of a
    # launch; NOT from load_game/adopt_record, which swap in another game's
    # ink whole rather than discarding it.
    def clear_ink_journal
      @ink_strokes = []
      @stroke_subs = nil
      @stroke_cur = nil
      @stroke_from = nil
      @stroke_count = 0
      return unless @store && @current_save_id
      @store.clear_strokes(@current_save_id)
    rescue StandardError => e
      log_line('could not clear strokes (' + e.message + ')')
    end

    # Upserts the autosave row for the board on the glass. Called after every
    # successful dig and again at shutdown; the row is a singleton, so each
    # call replaces the last. A New or Level press therefore DISCARDS the old
    # game deliberately — it overwrites the autosave and writes no manual
    # copy — consistent with how New has always cleared the ink.
    def persist_autosave
      return self unless @store && @grid
      # Kept, not overwritten: a save that fails (store answers nil) leaves
      # the previous id standing, so strokes keep landing on the row they
      # belong to instead of being orphaned as journal-less.
      id = @store.save_autosave(current_game_record)
      @current_save_id = id if id
      self
    rescue StandardError => e
      log_line('autosave failed (' + e.message + ')')
      self
    end

    def current_game_record
      { difficulty: @difficulty,
        achieved_tier: @achieved_tier || @difficulty,
        givens: @grid.givens_s,
        entries: @grid.entries_s,
        solution: board_of_values(@solution || []) }
    end

    # Runs exactly once, after the loop ends — however it ended. That is the
    # whole of §11's SIGTERM requirement and the Quit button's alike, because
    # both paths only ever set @running false: one shutdown, not two. The row
    # is REFRESHED even though the last dig already wrote it, because the dig
    # and the quit are separate events and the second write is what makes
    # "crash between them" indistinguishable from "quit cleanly".
    def shutdown_persistence
      persist_autosave
      @store.close if @store
      self
    rescue StandardError => e
      log_line('save on exit failed (' + e.message + ')')
      self
    end

    # The engine's values array as an 81-char board string. Grid#str_of is
    # private and givens-shaped ('.' for empty), which is the right reading of
    # a solution too — a complete board never holds a 0, but a FAULTED dig can
    # leave @solution shorter than expected, and this renders '.'s there
    # rather than raising out of a save path.
    def board_of_values(values)
      s = ''
      values.each { |d| s = s + (d.nil? || d == 0 ? '.' : d.to_s) }
      while s.size < 81
        s = s + '.'
      end
      s[0, 81]
    end

    # The inverse, for a restored solution string.
    def values_of_board(str)
      out = []
      str.each_char { |ch| out << (ch == '.' ? 0 : ch.to_i) }
      out
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
