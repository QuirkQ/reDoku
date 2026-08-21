module Redoku
  # Screen geometry, in panel pixels (PLAN.md §8). Portrait 1404x1872: a
  # 9x9 board of 140 px cells centred horizontally, with the button row
  # below it. Every rect is [x, y, w, h] with an exclusive right/bottom
  # edge, matching Display#fill_rect.
  module Layout
    SCREEN_W = 1404
    SCREEN_H = 1872

    CELL     = 140
    BOARD_W  = 9 * CELL           # 1260
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

    # Quit sits alone on the second row so a mis-aimed tap cannot end the
    # game while reaching for New or Level.
    BUTTONS = [
      [:new,   BOARD_X,                          BTN_ROW1_Y, BTN_W, BTN_H],
      [:level, BOARD_X + BTN_W + BTN_GAP,        BTN_ROW1_Y, BTN_W, BTN_H],
      [:quit,  BOARD_X + 2 * (BTN_W + BTN_GAP),  BTN_ROW2_Y, BTN_W, BTN_H]
    ].freeze

    HEADER_X = BOARD_X
    HEADER_Y = 60
    TITLE_SCALE = 8
    LABEL_SCALE = 5
    BUTTON_LABEL_SCALE = 6

    def self.board_rect
      [BOARD_X, BOARD_Y, BOARD_W, BOARD_W]
    end

    def self.cell_rect(col, row)
      unless col >= 0 && col < 9 && row >= 0 && row < 9
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
  end
end
