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

    # The exact status text shown while the generator digs. A constant
    # rather than a caller-supplied literal because Font.draw silently draws
    # NOTHING for a character it has no glyph for — a lowercase letter or a
    # real ellipsis character would render as blank space with no error —
    # so the string that ships is pinned here once and asserted
    # (test/renderer.rb), instead of trusted anew at every call site.
    SPLASH_TEXT = 'GENERATING...'

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
    def redraw_cell(index, grid)
      col = Sudoku::Grid.col_of(index)
      row = Sudoku::Grid.row_of(index)
      x, y, w, h = Layout.cell_rect(col, row)
      @d.fill_rect(x, y, w, h, WHITE)
      redraw_cell_lines(col, row, x, y, w, h)
      if grid && !grid.empty?(index)
        # WAVEFORM WARNING for whoever wires M3's recogniser through here.
        # ENTRY_GRAY is 96, a mid tone, and the caller that exists today
        # (App#erase_at) flushes this region as RM2::DU — a TWO-LEVEL
        # waveform, which thresholds 96 to black or white and destroys the
        # given-versus-entry distinction PLAN.md §8 asks for. Nothing in M2
        # can reach it (no entries exist yet), so the ONLY gray this method
        # ever actually prints today is GIVEN_GRAY. Repaint a cell holding an
        # entry and the flush for it has to be GL16; App#flush_ink says the
        # same thing at the point where the waveform is chosen.
        gray = grid.given?(index) ? GIVEN_GRAY : ENTRY_GRAY
        draw_digit(index, grid.value_at(index), gray)
      end
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
    # (cycle_difficulty flushes the header, new_puzzle the board), so an
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
    def flash_button(name, ink, paper)
      x, y, w, h = Layout.button_rect(name)
      draw_button(name, x, y, w, h, ink, paper)
      @d.update(x, y, w, h, waveform: RM2::DU, flags: RM2::FAST_DRAW)
    end

    # The weight draw_board gives boundary `i` (0..9): every third boundary is
    # a 3x3 block edge and gets the heavy line. One definition, two callers —
    # draw_board and the per-cell restoration below — because a second copy of
    # this rule could disagree with the board it is supposed to be restoring.
    #
    # `== 0`, not `.zero?`: Integer#zero? is mruby-numeric-ext, which this gem
    # does not depend on, so it is absent from its mrbtest state.
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

    # `ink` and `paper` swap for the pressed state (flash_button). They are
    # the only two grays a button uses, so one pair of arguments inverts the
    # whole thing — frame and label included — with no second code path.
    def draw_button(name, x, y, w, h, ink = BLACK, paper = WHITE)
      @d.fill_rect(x, y, w, h, paper)
      @d.fill_rect(x, y, w, BUTTON_BORDER, ink)              # top
      @d.fill_rect(x, y + h - BUTTON_BORDER, w, BUTTON_BORDER, ink) # bottom
      @d.fill_rect(x, y, BUTTON_BORDER, h, ink)              # left
      @d.fill_rect(x + w - BUTTON_BORDER, y, BUTTON_BORDER, h, ink) # right

      label = name.to_s.upcase
      scale = Layout::BUTTON_LABEL_SCALE
      lx, ly = centered_origin(label, scale, x, y, w, h)
      Font.draw(@d, label, lx, ly, scale, ink)
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
