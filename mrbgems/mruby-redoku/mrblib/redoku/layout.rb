module Redoku
  # Screen geometry, in panel pixels (PLAN.md §8). Portrait 1404x1872: a
  # 9x9 board of 140 px cells centred horizontally, with the button row
  # below it. Every rect is [x, y, w, h] with an exclusive right/bottom
  # edge, matching Display#fill_rect.
  module Layout
    SCREEN_W = 1404
    SCREEN_H = 1872

    # The board is square, so BOARD_W doubles as its vertical extent —
    # board_rect and cell_at both lean on that.
    SIZE     = 9                  # cells per side
    CELL     = 140
    BOARD_W  = SIZE * CELL        # 1260
    BOARD_X  = (SCREEN_W - BOARD_W) / 2 # 72
    BOARD_Y  = 200                # leaves a header band above the board

    # Line weights: thin between cells, heavy between 3x3 blocks. Both are
    # centred on the boundary they mark.
    CELL_LINE  = 1
    BLOCK_LINE = 4

    BTN_W = 400
    BTN_H = 140
    BTN_GAP = 30
    BTN_ROW1_Y = BOARD_Y + BOARD_W + 80  # 1540
    BTN_ROW2_Y = BTN_ROW1_Y + BTN_H + 20 # 1700

    # GAMES opens the saves menu (M3a), and shares row 2 with QUIT. The
    # original rule stands with one more button in play: the destructive
    # button stays at the FAR end of its row — two full widths away from New
    # and Level, and across a dead gap from Games — so a mis-aimed tap still
    # cannot end the game while reaching for anything else.
    # Each row is frozen too, not just the outer array: `buttons` hands the
    # shared array out, so a mutable row would be editable process-wide.
    BUTTONS = [
      [:new,   BOARD_X,                          BTN_ROW1_Y, BTN_W, BTN_H].freeze,
      [:level, BOARD_X + BTN_W + BTN_GAP,        BTN_ROW1_Y, BTN_W, BTN_H].freeze,
      [:games, BOARD_X,                          BTN_ROW2_Y, BTN_W, BTN_H].freeze,
      [:quit,  BOARD_X + 2 * (BTN_W + BTN_GAP),  BTN_ROW2_Y, BTN_W, BTN_H].freeze
    ].freeze

    # PREV / NEXT page the saves list (M3a) from the header band's right
    # end, clear of the GAMES title at HEADER_X (scale-8 'GAMES' ends at
    # x 304; PREV starts at 992). Sized to their LABEL_SCALE labels: 'PREV'
    # is 115 px wide at scale 5, leaving 17 px of margin inside each rect.
    MENU_BTN_W = 150
    MENU_BTN_H = 56 # exactly the header band, HEADER_Y..HEADER_Y + 56
    MENU_PREV_X = BOARD_X + BOARD_W - 2 * MENU_BTN_W - 40 # 992
    MENU_NEXT_X = BOARD_X + BOARD_W - MENU_BTN_W - 20     # 1162

    HEADER_X = BOARD_X
    HEADER_Y = 60

    MENU_BUTTONS = [
      [:prev, MENU_PREV_X, HEADER_Y, MENU_BTN_W, MENU_BTN_H].freeze,
      [:next, MENU_NEXT_X, HEADER_Y, MENU_BTN_W, MENU_BTN_H].freeze
    ].freeze

    TITLE_SCALE = 8
    LABEL_SCALE = 5
    BUTTON_LABEL_SCALE = 6

    def self.board_rect
      [BOARD_X, BOARD_Y, BOARD_W, BOARD_W]
    end

    def self.cell_rect(col, row)
      unless col >= 0 && col < SIZE && row >= 0 && row < SIZE
        raise ArgumentError, "cell out of range: #{col},#{row}"
      end
      [BOARD_X + col * CELL, BOARD_Y + row * CELL, CELL, CELL]
    end

    # The cell containing a screen point, or nil when the point is off the
    # board.
    def self.cell_at(px, py)
      return nil if px < BOARD_X || px >= BOARD_X + BOARD_W
      return nil if py < BOARD_Y || py >= BOARD_Y + BOARD_W
      [(px - BOARD_X) / CELL, (py - BOARD_Y) / CELL]
    end

    def self.buttons
      BUTTONS
    end

    def self.button_rect(name)
      found = BUTTONS.find { |b| b[0] == name }
      found && found[1, 4]
    end

    def self.button_at(px, py)
      hit = BUTTONS.find do |_name, x, y, w, h|
        px >= x && px < x + w && py >= y && py < y + h
      end
      hit && hit[0]
    end

    # --- the GAMES menu (M3a). Rows tile the board area exactly as cells
    # do — BOARD_W / CELL = 9 of them — and PREV/NEXT live in the header
    # band. Hit-tests mirror button_at / button_rect one for one.

    def self.menu_button_rect(name)
      found = MENU_BUTTONS.find { |b| b[0] == name }
      found && found[1, 4]
    end

    def self.menu_button_at(px, py)
      hit = MENU_BUTTONS.find do |_name, x, y, w, h|
        px >= x && px < x + w && py >= y && py < y + h
      end
      hit && hit[0]
    end

    # The menu row (0..8) containing a screen point, or nil off the board.
    # Whole-board rows: a tap anywhere in the row's 140 px band hits it,
    # which is the tolerance a list wants.
    def self.menu_row_at(px, py)
      return nil if px < BOARD_X || px >= BOARD_X + BOARD_W
      return nil if py < BOARD_Y || py >= BOARD_Y + BOARD_W
      (py - BOARD_Y) / CELL
    end

    def self.menu_row_rect(n)
      unless n >= 0 && n < SIZE
        raise ArgumentError, "menu row out of range: #{n}"
      end
      [BOARD_X, BOARD_Y + n * CELL, BOARD_W, CELL]
    end
  end
end
