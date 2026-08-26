module Redoku
  # Paints the board onto an RM2::Display. Drawing and flushing are kept
  # apart on purpose: pixels are cheap, panel refreshes are not, and each
  # region wants its own waveform (PLAN.md §3) — GC16 to clear ghosting on
  # a full repaint, GL16 for chrome, DU for pen ink.
  class Renderer
    WHITE = 255
    BLACK = 0
    BUTTON_BORDER = 3

    # Givens print darker than the player's own entries (PLAN.md §8), so a
    # glance tells clue from guess without reading digit shapes. GIVEN_GRAY
    # is full black rather than a lighter tone: it is the ink that must
    # survive the most e-ink refreshes over a session, and black is what GC16
    # holds cleanest.
    GIVEN_GRAY = 0
    ENTRY_GRAY = 96

    # 14 gives a 70 x 98 px glyph in a 140 px cell: PLAN.md §8 asks for
    # "~96 px" digits, and 98 is that target reached by a whole integer
    # scale (Font.draw only ever steps a glyph by whole pixels), leaving
    # 35 px of side margin and 21 px above and below — comfortably clear of
    # both the cell border and BLOCK_LINE's 2 px overhang into the cell.
    # This hits §8's SIZE, not its METHOD: §8 wants that size from a Spleen
    # BDF face via tools/fontpack.rb, and this is instead a 14x upscale of
    # Font's built-in 5x7 table (see font.rb) — the BDF pipeline is
    # deferred, and the visible trade-off is a blocky 14x14 pixel per glyph
    # pixel rather than a crisp face.
    DIGIT_SCALE = 14

    # A verdict mark, in the cell's top-right corner, small enough to leave
    # the digit or the player's ink legible under it.
    MARK_SCALE = 4
    MARK_INSET = 8

    # The splash ('GENERATING...') is the other full-board-width text the
    # renderer prints, so it takes the header's own scale rather than
    # inventing a third one: same visual weight as REDOKU, and verified
    # (test/renderer.rb) to fit inside the board. Referencing
    # Layout::TITLE_SCALE at load time, rather than copying its value, relies
    # on layout.rb sorting before renderer.rb in mrblib's alphabetical load
    # order — true today ('l' < 'r'), and worth knowing if that ever stops
    # being true.
    #
    # The direction that would actually bite is the other one: mrblib's
    # sudoku/ subdirectory sorts AFTER renderer.rb ('r' < 's'), so
    # Sudoku::Grid is NOT loaded yet while this file's class body is
    # executing. draw_digit and draw_puzzle reach Sudoku::Grid.col_of/row_of
    # and Sudoku::Grid::CELLS below safely only because those references sit
    # inside method bodies, which run on first call rather than at load —
    # by then every mrblib file has loaded. Hoist one of those into a
    # class-body constant the way SPLASH_SCALE hoists Layout::TITLE_SCALE
    # right here, and it raises `NameError: uninitialized constant
    # Redoku::Sudoku` at load, not at some later call.
    SPLASH_SCALE = Layout::TITLE_SCALE

    # --- the GAMES menu (M3a). MENU_ROWS is how many saves one page lists:
    # the board area tiles into exactly as many 140 px rows as it does cell
    # rows, because menu_row_rect shares the board's own arithmetic. Referenced
    # at load time like SPLASH_SCALE above — layout.rb sorts before
    # renderer.rb in mrblib's load order ('l' < 'r').
    MENU_ROWS = Layout::BOARD_W / Layout::CELL

    # Row labels print at the button label's scale: '10 MASTER 2026-08-25
    # 09:05' is 26 glyphs, 774 px at scale 6, inside a 1260 px row with room
    # to spare; scale 8 would need 1240 px and leave no margin.
    ROW_SCALE = Layout::BUTTON_LABEL_SCALE
    ROW_PAD = 40 # left inset of a row's text inside the board

    # Pinned strings for the same reason SPLASH_TEXT is: Font.draw silently
    # draws NOTHING for a character it has no glyph for, so each literal the
    # menu can print is pinned here once and glyph-asserted together
    # (test/renderer.rb) instead of trusted at every call site. The chrome
    # relabels (BACK / DEL / SAVE) are drawn over the play-mode buttons'
    # rects while the menu is up; PREV/NEXT name their own Layout buttons.
    MENU_TITLE_TEXT = 'GAMES'
    MENU_EMPTY_TEXT = 'NO SAVED GAMES'

    # What the play-mode buttons MEAN while the menu is up. Geometry never
    # moves — Layout.button_at still answers :new over the BACK rect — so
    # App routes presses through this same mapping, and flash_button needs
    # it to find the rect an action name flashes.
    MENU_CHROME_LABELS = {
      new: 'BACK', level: 'DEL', games: 'SAVE', quit: 'QUIT'
    }.freeze

    # The exact status text shown while the generator digs. A constant
    # rather than a caller-supplied literal because Font.draw silently draws
    # NOTHING for a character it has no glyph for — a lowercase letter or a
    # real ellipsis character would render as blank space with no error —
    # so the string that ships is pinned here once and asserted
    # (test/renderer.rb), instead of trusted anew at every call site.
    SPLASH_TEXT = 'GENERATING...'

    # Pinned as constants for the reason SPLASH_TEXT is pinned: Font.draw
    # silently draws NOTHING for a character it has no glyph for, so a
    # caller-supplied string could ship a blank win screen and no test would
    # see it. Pinned here, and asserted against the charset in test/app.rb.
    WIN_TEXT   = 'SOLVED'
    WIN_LABEL  = 'CHECKS: '
    WIN_HINT   = 'TAP FOR A NEW ONE'
    WIN_SCALE  = 10
    WIN_SUB    = 5

    # The --record capture prompt (M3b Task 10): the digit being asked for,
    # full-screen at the win headline's scale, and how many samples the walk
    # has banked so far under it. Same pinned-string rule as WIN_TEXT —
    # every character here must have a glyph, and test/renderer.rb asserts
    # that against Font::GLYPHS rather than trusting the literals. The
    # progress line reads 'SAVED N' rather than 'N OF M' because '/' has no
    # glyph; the recorder's total is derivable but the count alone is what
    # tells the player the pen stroke landed.
    RECORD_TITLE     = 'WRITE '
    RECORD_DONE_TEXT = 'DONE'
    RECORD_SUB       = 'SAVED '
    RECORD_SUB_SCALE = 5

    # THE PROGRESS BAR, and it is a real one: generation already loops over
    # attempts, so a callback on completed work gives honest progress at no
    # extra cost. What it means, stated plainly because a bar that means
    # nothing is worse than no bar: work COMPLETED against work completed plus
    # one more full attempt budget. It advances with every finished attempt,
    # decelerates as a search runs long, and can never fill -- because a search
    # that has not finished cannot promise it is about to. See App#show_progress
    # for why that is the shape and not a percentage of a fixed total.
    #
    # WHAT THAT LOOKS LIKE IN THE COMMON CASE, said plainly because it is the
    # case the player meets: an EASY press hits on its first attempt, so the bar
    # goes to 1/(1+6) -- 14%, 87 px of 614 -- and is then replaced by the board.
    # A short bar that vanishes, not a bar that fills. design 6.5 predicted "the
    # bar jumps to full"; that was true of a denominator of `total`, and it is
    # not true of this one. The trade was taken deliberately: never resetting
    # across a retry matters more than finishing, because the retry case is the
    # one where the player is actually waiting.
    #
    # Geometry is derived from the splash text's own box so the two stay
    # centred together, and lives wholly inside board_rect so that draw_board's
    # white fill erases it and flush_board covers it -- no second flush region,
    # and no bar surviving onto the finished puzzle.
    PROGRESS_W = 620
    PROGRESS_H = 24
    PROGRESS_GAP = 40
    PROGRESS_BORDER = 3

    def self.progress_rect
      x, y, w, h = Layout.board_rect
      th = Font::HEIGHT * SPLASH_SCALE
      top = y + (h - th) / 2 + th + PROGRESS_GAP
      [x + (w - PROGRESS_W) / 2, top, PROGRESS_W, PROGRESS_H]
    end

    # The filled width in pixels for a fraction given as two Integers. Integer
    # arithmetic throughout, and the reason is the bar and not the toolchain:
    # a bar is pixels, mrb_int is 32-bit on the device, and there is nothing a
    # Float would add here but a rounding rule to get wrong. (String#% and
    # `format` ARE available since 18cc2f5 declared mruby-sprintf; a percentage
    # STRING is simply not what this returns.) Clamped at both ends and safe on
    # a zero denominator, because this is called from inside a search where a
    # raise costs the player their puzzle.
    def self.progress_fill(num, den)
      inner = PROGRESS_W - 2 * PROGRESS_BORDER
      return 0 if den <= 0 || num <= 0
      return inner if num >= den
      (inner * num) / den
    end

    # An epoch as 'YYYY-MM-DD HH:MM', for the GAMES menu's rows. BY HAND,
    # and deliberately: strftime is not among our declared dependencies, and
    # the font holds the digits, '-' and ':' this needs and nothing more.
    # The calendar half is Howard Hinnant's civil-from-days (public domain),
    # which turns a day count straight into (y, m, d) with no leap-year case
    # of its own to get wrong — verified in test/renderer.rb against epochs
    # chosen to exercise the 400-year rule (2000-02-29), the non-rule
    # centuries, and both sides of a day boundary.
    #
    # UTC, not local time: epoch arithmetic knows no zone, and pulling in
    # mruby-time's localtime for a list label would buy a timezone the rM2
    # does not have set anyway. The stamp orders saves and dates them; it
    # does not promise wall-clock.
    def self.format_stamp(epoch)
      days = epoch / 86400
      secs = epoch % 86400
      hh = secs / 3600
      mm = (secs % 3600) / 60
      z = days + 719468
      era = (z >= 0 ? z : z - 146096) / 146097
      doe = z - era * 146097
      yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
      y = yoe + era * 400
      doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
      mp = (5 * doy + 2) / 153
      d = doy - (153 * mp + 2) / 5 + 1
      m = mp < 10 ? mp + 3 : mp - 9
      y += 1 if m <= 2
      pad(y, 4) + '-' + pad(m, 2) + '-' + pad(d, 2) + ' ' +
        pad(hh, 2) + ':' + pad(mm, 2)
    end

    def self.pad(v, width)
      s = v.to_s
      s = '0' + s while s.size < width
      s
    end

    def initialize(display)
      @d = display
    end

    def draw_all(difficulty)
      @d.fill_rect(0, 0, Layout::SCREEN_W, Layout::SCREEN_H, WHITE)
      draw_header(difficulty)
      draw_board
      draw_buttons
      self
    end

    def draw_header(difficulty)
      x, y, w, h = header_rect
      @d.fill_rect(x, y, w, h, WHITE)
      Font.draw(@d, 'REDOKU', Layout::HEADER_X, Layout::HEADER_Y,
                Layout::TITLE_SCALE, BLACK)
      label = difficulty.to_s.upcase
      label_w = Font.width(label, Layout::LABEL_SCALE)
      Font.draw(@d, label, Layout::BOARD_X + Layout::BOARD_W - label_w,
                Layout::HEADER_Y, Layout::LABEL_SCALE, BLACK)
      self
    end

    # White board plus the 10 vertical and 10 horizontal boundaries. Every
    # third boundary is a block edge and gets the heavy weight; each line is
    # centred on its boundary, so the outer frame straddles the board edge.
    def draw_board
      bx, by, bw, bh = Layout.board_rect
      @d.fill_rect(bx, by, bw, bh, WHITE)
      10.times do |i|
        weight = boundary_weight(i)
        offset = weight / 2
        pos = i * Layout::CELL
        @d.fill_rect(bx + pos - offset, by - offset, weight, bh + weight, BLACK)
        @d.fill_rect(bx - offset, by + pos - offset, bw + weight, weight, BLACK)
      end
      self
    end

    def draw_buttons
      Layout.buttons.each do |name, x, y, w, h|
        draw_button(name, x, y, w, h)
      end
      self
    end

    # `index` is a FLAT 0..80 cell index, matching Grid's own currency — the
    # caller (draw_puzzle) already has one per cell and Grid.row_of/col_of
    # are the tested way to turn it into Layout's (col, row), so re-deriving
    # i / 9 and i % 9 here would just be a second copy that could disagree.
    def draw_digit(index, digit, gray)
      col = Sudoku::Grid.col_of(index)
      row = Sudoku::Grid.row_of(index)
      x, y, w, h = Layout.cell_rect(col, row)
      text = digit.to_s
      tx, ty = centered_origin(text, DIGIT_SCALE, x, y, w, h)
      Font.draw(@d, text, tx, ty, DIGIT_SCALE, gray)
      self
    end

    # Every filled cell of `grid`, given or entered, in its own ink. Blank
    # cells are skipped rather than drawn as ' ' — Font.draw has no glyph for
    # it anyway, but skipping also means this can be called on a half-solved
    # board without painting anything for the holes.
    def draw_puzzle(grid)
      Sudoku::Grid::CELLS.times do |i|
        next if grid.empty?(i)
        gray = grid.given?(i) ? GIVEN_GRAY : ENTRY_GRAY
        draw_digit(i, grid.value_at(i), gray)
      end
      self
    end

    # Replays journaled pen ink onto the shared buffer: the same draw_line
    # calls live drawing made, in the same order, at the same width and
    # gray, from panel ("screen") coordinates stored per stroke (M3a Task 6).
    # This is the repaint half of stroke persistence — resume-on-launch,
    # load-from-menu, BACK out of the menu and SIGCONT all come through here,
    # always BETWEEN the model paints and the flush, so one GC16 carries
    # puzzle and ink to the glass together.
    #
    # `strokes` is App's in-memory journal ({color:, width:, subpaths:}),
    # already validated by the store; subpaths replay as connected polylines,
    # never bridging the gap where a stroke left the board.
    def draw_ink(strokes)
      strokes.each do |stroke|
        color = stroke[:color]
        width = stroke[:width]
        stroke[:subpaths].each do |sub|
          i = 1
          while i < sub.size
            @d.draw_line(sub[i - 1][0], sub[i - 1][1],
                         sub[i][0], sub[i][1], width, color)
            i += 1
          end
        end
      end
      self
    end

    # One cell, repainted from the model: white paper, the grid lines that
    # touch it, and its digit if `grid` has one. This is what ERASING means
    # here. Ink is drawn straight into the shared framebuffer (App#ink_to →
    # Display#draw_line), so there is no ink buffer to undo and nothing to
    # "unpaint" — the only way back is to paint the cell as it should look.
    #
    # `index` is a flat 0..80 cell index, Grid's own currency and draw_digit's
    # too. `grid` may be nil: that is the board that has not been dug yet (an
    # App holds no Grid until run or a New press asks for one, because
    # generation is a search), and a cell with no model behind it still has to
    # come clean — there is simply no digit to put back.
    #
    # Deliberately cell-at-a-time rather than pixel-accurate: a rub-out that
    # cleared only the pixels the eraser passed over would need an ink journal
    # or a per-cell backing store, and the game thinks in cells anyway. Touch
    # the eraser anywhere in a cell and the cell clears.
    #
    # THE LIMIT WORTH KNOWING, since it follows from this being cell-exact:
    # the brush is INK_WIDTH (4) px and stamped biased up-left (2 px up and
    # left, 1 px down and right — see rm2_stamp), so ink written hard against
    # a cell's LEFT or TOP edge lands up to 2 px outside it, where repainting
    # this cell cannot reach it. Three neighbours can hold that residue, not
    # one: the cell to the left, the cell above, and — for a stroke through
    # the corner, which reaches 2 px left AND 2 px up — the cell diagonally
    # up-left. At a block boundary the 4 px line swallows all of it; at a 1 px
    # cell boundary up to 2 px survives, and 2 px is its WIDTH, not its
    # extent: it can run the whole length the stroke travelled along that
    # boundary, up to a full 140 px cell edge. It goes when that neighbour is
    # erased in its turn, or when New repaints the board. The right and bottom
    # edges have no such hole — 1 px of overshoot always lands on the next
    # cell's own line. Widening the repaint into the neighbours would trade
    # that band for something worse: shaving pixels off ink the player wrote
    # in a cell they never touched.
    def redraw_cell(index, grid, mark: nil)
      col = Sudoku::Grid.col_of(index)
      row = Sudoku::Grid.row_of(index)
      x, y, w, h = Layout.cell_rect(col, row)
      @d.fill_rect(x, y, w, h, WHITE)
      redraw_cell_lines(col, row, x, y, w, h)
      if grid && !grid.empty?(index)
        # WAVEFORM WARNING, still true at the flush: ENTRY_GRAY is 96, a mid
        # tone, and a DU update thresholds it to black or white. Any caller
        # that puts an entry digit back on the glass — App#clear_verdict_at,
        # CHECK's read path — must flush this region as GL16 (constraint 4).
        gray = grid.given?(index) ? GIVEN_GRAY : ENTRY_GRAY
        draw_digit(index, grid.value_at(index), gray)
      end
      draw_mark(index, mark) if mark
      self
    end

    # Paints ONLY the mark, over whatever is already in the cell. This is
    # the path an :unreadable verdict must take: that cell is keeping its
    # ink, and redraw_cell above would repaint the cell from the model and
    # wipe the very strokes the verdict exists to preserve.
    def draw_mark(index, mark)
      text = mark == :wrong ? 'X' : '?'
      col = Sudoku::Grid.col_of(index)
      row = Sudoku::Grid.row_of(index)
      x, y, w, _h = Layout.cell_rect(col, row)
      gw = Font.width(text, MARK_SCALE)
      Font.draw(@d, text, x + w - gw - MARK_INSET, y + MARK_INSET,
                MARK_SCALE, GIVEN_GRAY)
      self
    end

    # Fills the board area white and centres `text` in it — a status message
    # (PLAN.md §8's "Generating…") shown while the generator is digging and
    # the board underneath it is not yet something worth looking at. Filling
    # white erases whatever grid or puzzle was there before on purpose: the
    # caller repaints with draw_board + draw_puzzle once generation finishes,
    # so nothing here needs to survive that. Painting only inside board_rect,
    # rather than a wider area, is also what lets the caller's existing
    # flush_board cover exactly the region this dirties — a second flush
    # region would be a second way to do the one thing flush_board does.
    # No parameter. An earlier version took `text = SPLASH_TEXT`, which
    # closed the default path but not the method: a caller could still write
    # `draw_splash('Generating...')` and paint a blank board under a fully
    # green suite, because Font.draw silently draws NOTHING for a character
    # it has no glyph for (lowercase, a real ellipsis). No caller ever passed
    # one, so the parameter was pure liability with no offsetting use — a
    # glyph-check inside the method would have closed the same hole but kept
    # the liability alive for the next caller to trip over. Removing it means
    # the only string this method can ever draw is SPLASH_TEXT, which is
    # already pinned and glyph-asserted once (test/renderer.rb) rather than
    # trusted anew at every call site.
    #
    # Note for anyone tempted to "fix" the result: board_rect's white fill
    # leaves the 2 px frame overhang (see flush_board) untouched, so a thin
    # dark hairline stays visible around the splash — that is the SAME
    # invariant flush_board already relies on (the overhang never receives
    # white), not a bug.
    def draw_splash
      x, y, w, h = Layout.board_rect
      @d.fill_rect(x, y, w, h, WHITE)
      tx, ty = centered_origin(SPLASH_TEXT, SPLASH_SCALE, x, y, w, h)
      Font.draw(@d, SPLASH_TEXT, tx, ty, SPLASH_SCALE, BLACK)
      self
    end

    # The whole win screen in one paint: white panel, the verdict centred
    # where a headline wants to be, the check count under it and the one
    # instruction the screen needs. Like draw_games_menu, this is a FULL-
    # screen paint rather than a region patch — it replaces the board and
    # the chrome at once, and every caller flushes with flush_all.
    def draw_win(checks)
      @d.fill_rect(0, 0, @d.width, @d.height, WHITE)
      centre_line(WIN_TEXT, WIN_SCALE, Layout::SCREEN_H / 2 - 160)
      centre_line(WIN_LABEL + checks.to_s, WIN_SUB, Layout::SCREEN_H / 2)
      centre_line(WIN_HINT, WIN_SUB, Layout::SCREEN_H / 2 + 120)
      self
    end

    # `text` horizontally centred in the panel at `scale`, its top at `y`.
    # The one formula draw_win's three lines share, so their rounding cannot
    # drift apart the way three hand-written centres would.
    def centre_line(text, scale, y)
      w = Font.width(text, scale)
      Font.draw(@d, text, (Layout::SCREEN_W - w) / 2, y, scale, BLACK)
    end

    # The whole capture screen in one paint: which digit to write now (or
    # DONE once the walk is over), and the running sample count. Like
    # draw_win this is a full-screen paint followed by the caller's
    # flush_all — a prompt is a mode change the player reads as one event,
    # and it fires once per completed stroke, so there is nothing to be
    # saved by region bookkeeping.
    def draw_record_prompt(recorder)
      @d.fill_rect(0, 0, Layout::SCREEN_W, Layout::SCREEN_H, WHITE)
      title = recorder.done? ? RECORD_DONE_TEXT
                             : RECORD_TITLE + recorder.wanted.to_s
      centre_line(title, WIN_SCALE, Layout::SCREEN_H / 2 - 160)
      centre_line(RECORD_SUB + recorder.samples.size.to_s,
                  RECORD_SUB_SCALE, Layout::SCREEN_H / 2 + 120)
      self
    end

    # The whole GAMES screen in one paint: header (title + pagination),
    # the board area tiled into save rows (or the empty state), and the
    # chrome relabelled BACK / DEL / SAVE / QUIT. `list` is Store#games'
    # metadata — id, kind, difficulty, achieved_tier, updated_at — ordered
    # by updated_at DESC; `page` indexes it in MENU_ROWS-sized pages;
    # `delete_mode` holds the DEL button inverted.
    #
    # A FULL-screen paint rather than a region patch, on purpose: a menu is
    # a mode change the player reads as one event, and one GC16 SYNC costs
    # what a single chrome refresh does. Every caller flushes with
    # flush_all, so nothing here has to agree with anything about which
    # regions changed — there are no stale-pixel corners to reason about,
    # unlike the board repaints where that reasoning is half the code.
    #
    # PREV/NEXT appear ONLY when the list actually spans more than one page:
    # controls for a second page that does not exist would be a lie about
    # the content, and e-ink holds an image for free so there is no cost to
    # their absence. Pressing either at a page boundary is a no-op (App's
    # turn_page), not a visibility change.
    def draw_games_menu(list, page, delete_mode)
      @d.fill_rect(0, 0, Layout::SCREEN_W, Layout::SCREEN_H, WHITE)
      draw_menu_header(list)
      draw_game_rows(list, page)
      draw_menu_buttons(delete_mode)
      self
    end

    # --- the LEVEL picker (M3b). Same full-screen shape as the GAMES menu:
    # title in the header band, one row per option tiled over the board area
    # with a hairline under each, chrome relabelled (BACK over New's rect is
    # the way out). The current tier carries LEVEL_MARK; the others two spaces,
    # so every label starts on the same column. Pinned strings for the reason
    # SPLASH_TEXT is pinned: Font.draw silently draws NOTHING for a character
    # it has no glyph for, so each literal the picker can print lives here and
    # is glyph-asserted against Rater::TIERS in test/app.rb.
    LEVEL_TITLE = 'LEVEL'
    LEVEL_MARK  = '- '        # against the current tier; inside the charset

    def draw_levels_menu(tiers, current)
      @d.fill_rect(0, 0, @d.width, @d.height, WHITE)
      Font.draw(@d, LEVEL_TITLE, Layout::HEADER_X, Layout::HEADER_Y,
                Layout::TITLE_SCALE, BLACK)
      tiers.each_with_index do |tier, i|
        x, y, w, h = Layout.menu_row_rect(i)
        label = (tier == current ? LEVEL_MARK : '  ') + tier.to_s.upcase
        Font.draw(@d, label, x + 20,
                  y + (h - Font::HEIGHT * Layout::LABEL_SCALE) / 2,
                  Layout::LABEL_SCALE, BLACK)
        @d.fill_rect(x, y + h - 1, w, 1, BLACK)
      end
      draw_menu_buttons(false)
      self
    end

    # The whole bar, frame and fill, repainted from scratch each time: 620x24
    # is nothing to fill and it removes any question of a stale fill edge
    # surviving a repaint.
    def draw_progress(num, den)
      x, y, w, h = Renderer.progress_rect
      b = PROGRESS_BORDER
      @d.fill_rect(x, y, w, h, WHITE)
      @d.fill_rect(x, y, w, b, BLACK)                # top
      @d.fill_rect(x, y + h - b, w, b, BLACK)        # bottom
      @d.fill_rect(x, y, b, h, BLACK)                # left
      @d.fill_rect(x + w - b, y, b, h, BLACK)        # right
      fill = Renderer.progress_fill(num, den)
      @d.fill_rect(x + b, y + b, fill, h - 2 * b, BLACK) if fill > 0
      self
    end

    # DU + FAST_DRAW, the same exception to the chrome convention that
    # press_button makes: this is two-level black on white, it happens about ten
    # times per attempt budget and about twenty times over a whole press
    # however long it runs (App::PROGRESS_STEP_PX explains why the total is
    # bounded), and a GL16 each time would cost more than the search it
    # reports on.
    def flush_progress
      x, y, w, h = Renderer.progress_rect
      @d.update(x, y, w, h, waveform: RM2::DU, flags: RM2::FAST_DRAW)
    end

    def flush_all
      @d.update(0, 0, Layout::SCREEN_W, Layout::SCREEN_H,
                waveform: RM2::GC16, flags: RM2::SYNC)
    end

    # board_rect is enough even though the frame straddles it: draw_board's
    # white fill is exactly board_rect, so the 2 px overhang only ever receives
    # black over black and a repaint cannot leave a stale pixel out there.
    # Widening that white fill would break this and need a wider flush.
    def flush_board
      x, y, w, h = Layout.board_rect
      @d.update(x, y, w, h, waveform: RM2::GL16, flags: 0)
    end

    def flush_header
      x, y, w, h = header_rect
      @d.update(x, y, w, h, waveform: RM2::GL16, flags: 0)
    end

    def flush_rect(x, y, w, h, waveform: RM2::GL16, flags: 0)
      @d.update(x, y, w, h, waveform: waveform, flags: flags)
    end

    # Paints one button inverted — black paper, white border and label — and
    # flushes it as ink rather than chrome. That is deliberate: DU is the
    # two-level waveform the pen echo uses, so this lands in about a tenth of
    # the time a GL16 chrome refresh would take, and it is the
    # acknowledgement for a press whose own action may be slow (New repaints
    # the whole board) or may be to tear the game down (App#quit).
    def press_button(name)
      flash_button(name, WHITE, BLACK)
    end

    # The other half, and the reason draw_button takes its colours as
    # arguments: a pressed button has to come back up, because neither of the
    # two actions that survive their own press repaints the buttons
    # (new_puzzle flushes the board, open_levels the whole panel), so an
    # inverted button would otherwise stay inverted for the session. Only
    # App knows which presses outlive themselves, so App decides — see
    # App#acknowledge.
    def release_button(name)
      flash_button(name, BLACK, WHITE)
    end

    private

    # One painter for both directions, so the two cannot drift apart: the
    # release uses the same DU + FAST_DRAW exception to the chrome
    # convention, over the same rect, and the flash is therefore symmetric.
    # A press arriving in a tenth of a second and a release fading back over
    # a GL16's half second would not read as one gesture.
    #
    # `name` is whatever App pressed — a chrome button (:new..:quit), a
    # menu action (:back/:del/:save) whose rect is the play-mode button it
    # shares, :prev/:next, or an Integer menu row (M3a). rect_of resolves
    # all of them; a name nothing answers for raises here rather than
    # drawing nowhere, because a press acknowledged at no particular place
    # is a bug worth seeing immediately.
    def flash_button(name, ink, paper)
      x, y, w, h = rect_of(name)
      draw_button(name, x, y, w, h, ink, paper, label_of(name))
      @d.update(x, y, w, h, waveform: RM2::DU, flags: RM2::FAST_DRAW)
    end

    # The rect a press target flashes. Menu actions sit on the play-mode
    # buttons they relabel (MENU_CHROME_LABELS), so BACK inverts the same
    # 400x140 rect NEW does — geometry never moves between modes, which is
    # what lets Layout.button_at stay static while meaning changes.
    def rect_of(target)
      case target
      when Integer then Layout.menu_row_rect(target)
      when :prev   then Layout.menu_button_rect(:prev)
      when :next   then Layout.menu_button_rect(:next)
      when :back   then Layout.button_rect(:new)
      when :del    then Layout.button_rect(:level)
      when :save   then Layout.button_rect(:games)
      else Layout.button_rect(target)
      end
    end

    # The text a flash paints: a row has none worth printing (its own load
    # or delete repaints the screen inside the acknowledgement), everything
    # else prints its name — or its menu label, when the target IS a
    # relabelled play-mode button.
    def label_of(target)
      MENU_CHROME_LABELS[target] || target.to_s.upcase
    end

    # The weight draw_board gives boundary `i` (0..9): every third boundary is
    # a 3x3 block edge and gets the heavy line. One definition, two callers —
    # draw_board and the per-cell restoration below — because a second copy of
    # this rule could disagree with the board it is supposed to be restoring.
    #
    # Every third boundary, counting from the board's own edge, which is why
    # this is `% 3` and not a lookup.
    def boundary_weight(i)
      i % 3 == 0 ? Layout::BLOCK_LINE : Layout::CELL_LINE
    end

    # The four grid boundaries this cell touches, put back over the white fill
    # — and CLIPPED to the cell, which is the whole subtlety here. draw_board
    # centres each line ON its boundary (`offset = weight / 2`), so a line's
    # band straddles two cells: the half of it inside this cell is what the
    # white fill just ate and what has to come back, while the half in the
    # neighbour was never touched. Painting the full weight instead would be
    # black over black everywhere except at the board's outer edge, where it
    # would put 2 px of new frame onto the white margin (see draw_splash's
    # note on that overhang).
    def redraw_cell_lines(col, row, x, y, w, h)
      left = leading_band(col)
      top = leading_band(row)
      right = trailing_band(col + 1)
      bottom = trailing_band(row + 1)
      @d.fill_rect(x, y, left, h, BLACK) if left > 0
      @d.fill_rect(x, y, w, top, BLACK) if top > 0
      @d.fill_rect(x + w - right, y, right, h, BLACK) if right > 0
      @d.fill_rect(x, y + h - bottom, w, bottom, BLACK) if bottom > 0
    end

    # How much of boundary `i`'s line falls inside the cell that STARTS there:
    # the line is drawn from `weight / 2` px before the boundary, so the cell
    # after it keeps the rest — 2 px of a block line, 1 px of a cell line.
    def leading_band(i)
      weight = boundary_weight(i)
      weight - weight / 2
    end

    # ...and how much falls inside the cell that ENDS there: exactly the
    # offset, so a block line contributes 2 px and a 1 px cell line
    # contributes nothing at all — it sits wholly in the next cell, which is
    # why that cell's last column and row are plain interior and come back
    # white.
    def trailing_band(i)
      boundary_weight(i) / 2
    end

    def header_rect
      [Layout::HEADER_X, Layout::HEADER_Y,
       Layout::BOARD_W, Font::HEIGHT * Layout::TITLE_SCALE]
    end

    # --- the GAMES menu's three regions, in draw_games_menu's order.

    # Title at the header origin (where REDOKU sits in play mode — the menu
    # replaces the whole screen, so the player is never reading both at
    # once), pagination at the far end only when more than one page exists.
    def draw_menu_header(list)
      x, y, w, h = header_rect
      @d.fill_rect(x, y, w, h, WHITE)
      Font.draw(@d, MENU_TITLE_TEXT, Layout::HEADER_X, Layout::HEADER_Y,
                Layout::TITLE_SCALE, BLACK)
      return unless list.size > MENU_ROWS
      draw_button(:prev, *Layout.menu_button_rect(:prev))
      draw_button(:next, *Layout.menu_button_rect(:next))
    end

    # The board area as a white field, then either the empty state centred
    # where the splash sits (a full-board-width message in the splash's own
    # scale) or up to MENU_ROWS rows from `page`'s slice of `list`.
    #
    # Each row reads `N TIER YYYY-MM-DD HH:MM` — position in the WHOLE list
    # (stable across pages), the tier the saved board actually reached,
    # and the hand-formatted last-write time. The tier is the achieved one
    # rather than the requested for the same reason fill_board keeps both:
    # it is what the board on that save's glass was.
    def draw_game_rows(list, page)
      bx, by, bw, bh = Layout.board_rect
      @d.fill_rect(bx, by, bw, bh, WHITE)
      if list.empty?
        tx, ty = centered_origin(MENU_EMPTY_TEXT, SPLASH_SCALE, bx, by, bw, bh)
        Font.draw(@d, MENU_EMPTY_TEXT, tx, ty, SPLASH_SCALE, BLACK)
        return
      end
      i = 0
      while i < MENU_ROWS
        index = page * MENU_ROWS + i
        break if index >= list.size
        draw_game_row(index, list[index])
        i += 1
      end
    end

    # One row: text left-aligned ROW_PAD px inside the board, vertically
    # centred in its 140 px band. Left-aligned rather than centred because
    # a column of ragged-centred stamps reads as noise; the leading number
    # gives the eye a fixed rail.
    def draw_game_row(index, game)
      _x, y, _w, h = Layout.menu_row_rect(index % MENU_ROWS)
      label = (index + 1).to_s + ' ' + game[:achieved_tier].to_s.upcase +
              ' ' + Renderer.format_stamp(game[:updated_at])
      ty = y + (h - Font::HEIGHT * ROW_SCALE) / 2
      Font.draw(@d, label, Layout::BOARD_X + ROW_PAD, ty, ROW_SCALE, BLACK)
    end

    # The chrome with its menu meanings painted on: BACK over New's rect,
    # DEL over Level's (inverted while delete mode is armed — the inversion
    # IS the armed state, and it persists until the next row tap spends it),
    # SAVE over Games', QUIT unchanged.
    def draw_menu_buttons(delete_mode)
      Layout.buttons.each do |name, x, y, w, h|
        label = MENU_CHROME_LABELS[name]
        if name == :level && delete_mode
          draw_button(name, x, y, w, h, WHITE, BLACK, label)
        else
          draw_button(name, x, y, w, h, BLACK, WHITE, label)
        end
      end
    end

    # `ink` and `paper` swap for the pressed state (flash_button). They are
    # the only two grays a button uses, so one pair of arguments inverts the
    # whole thing — frame and label included — with no second code path.
    # `label` overrides the name-derived text: the GAMES menu draws BACK /
    # DEL / SAVE over the play-mode buttons' rects (draw_menu_buttons), and
    # a flash of one of those actions has to paint what the button says,
    # not what it is called underneath.
    def draw_button(name, x, y, w, h, ink = BLACK, paper = WHITE,
                    label = nil)
      @d.fill_rect(x, y, w, h, paper)
      @d.fill_rect(x, y, w, BUTTON_BORDER, ink)              # top
      @d.fill_rect(x, y + h - BUTTON_BORDER, w, BUTTON_BORDER, ink) # bottom
      @d.fill_rect(x, y, BUTTON_BORDER, h, ink)              # left
      @d.fill_rect(x + w - BUTTON_BORDER, y, BUTTON_BORDER, h, ink) # right

      text = label || name.to_s.upcase
      scale = Layout::BUTTON_LABEL_SCALE
      lx, ly = centered_origin(text, scale, x, y, w, h)
      Font.draw(@d, text, lx, ly, scale, ink)
    end

    # Where to put `text` at `scale` so it lands centred inside the rect
    # (x, y, w, h). One formula, one place: draw_digit, draw_splash and
    # draw_button each used to recompute
    # `x + (w - Font.width(t, s)) / 2, y + (h - Font::HEIGHT * s) / 2` by
    # hand, which is three chances for the rounding to quietly drift apart
    # rather than one.
    def centered_origin(text, scale, x, y, w, h)
      tw = Font.width(text, scale)
      th = Font::HEIGHT * scale
      [x + (w - tw) / 2, y + (h - th) / 2]
    end
  end
end
