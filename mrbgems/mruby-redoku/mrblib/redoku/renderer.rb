module Redoku
  # Paints the board onto an RM2::Display. Drawing and flushing are kept
  # apart on purpose: pixels are cheap, panel refreshes are not, and each
  # region wants its own waveform (PLAN.md §3) — GC16 to clear ghosting on
  # a full repaint, GL16 for chrome, DU for pen ink.
  class Renderer
    WHITE = 255
    BLACK = 0
    DIFFICULTIES = [:easy, :medium, :hard].freeze

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
      x, y, w, _h = header_rect
      @d.fill_rect(x, y, w, Font::HEIGHT * Layout::TITLE_SCALE, WHITE)
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
        # `== 0`, not `.zero?`: Integer#zero? is mruby-numeric-ext, which this
        # gem does not depend on, so it is absent from its mrbtest state.
        weight = i % 3 == 0 ? Layout::BLOCK_LINE : Layout::CELL_LINE
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

    def flush_all
      @d.update(0, 0, Layout::SCREEN_W, Layout::SCREEN_H,
                waveform: RM2::GC16, flags: RM2::SYNC)
    end

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

    private

    BUTTON_BORDER = 3

    def header_rect
      [Layout::HEADER_X, Layout::HEADER_Y,
       Layout::BOARD_W, Font::HEIGHT * Layout::TITLE_SCALE]
    end

    def draw_button(name, x, y, w, h)
      @d.fill_rect(x, y, w, h, WHITE)
      @d.fill_rect(x, y, w, BUTTON_BORDER, BLACK)              # top
      @d.fill_rect(x, y + h - BUTTON_BORDER, w, BUTTON_BORDER, BLACK) # bottom
      @d.fill_rect(x, y, BUTTON_BORDER, h, BLACK)              # left
      @d.fill_rect(x + w - BUTTON_BORDER, y, BUTTON_BORDER, h, BLACK) # right

      label = name.to_s.upcase
      scale = Layout::BUTTON_LABEL_SCALE
      Font.draw(@d, label,
                x + (w - Font.width(label, scale)) / 2,
                y + (h - Font::HEIGHT * scale) / 2,
                scale, BLACK)
    end
  end
end
