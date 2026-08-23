module Redoku
  module Sudoku
    # An 81-cell sudoku board, plus the board geometry every other unit in the
    # engine asks it for.
    #
    # Two shapes live here and they are deliberately not the same thing:
    #
    #   `values` — a bare 81-element Array of 0..9, index row * 9 + col, 0
    #   meaning empty. This is the engine's working currency: Solver,
    #   Techniques, Rater and Generator all take one and return one. A plain
    #   Array on purpose — the counting solver touches it tens of thousands of
    #   times per generated puzzle, so it must not allocate an object per
    #   cell.
    #
    #   A `Grid` instance — the game's state, which is `values` split in two:
    #   the givens the puzzle arrived with, and the entries the player wrote.
    #   Keeping them apart is what lets the renderer print givens heavier
    #   (PLAN.md §8) and what stops the player editing a clue.
    #
    # Candidate sets are integer BITMASKS, bit d set meaning "digit d is still
    # possible". Bit 0 is deliberately unused so the bit for digit d is
    # exactly `1 << d`, with no offset arithmetic to get wrong. Masks rather
    # than Sets or Arrays for two reasons, and the first is not a preference:
    # this gem's mrbtest state has no Set, no Array#uniq and no
    # Array#combination (measured, see docs/plans/2026-08-23-m2-sudoku-engine.md),
    # so the array-shaped version of this code would pass on the device and
    # crash under `make test`. And bitwise ops are the cheapest thing on the
    # device's Cortex-A7, which matters because generation is the one pause
    # the player actually sees.
    class Grid
      CELLS = 81
      ALL = 0b1111111110 # digits 1..9; bit 0 unused

      # CELLS, not SIZE: Layout::SIZE already means "9 cells per side" in this
      # same codebase, so a Grid::SIZE of 81 would be a trap for anyone
      # reading the two together.

      # The lookup tables are built by these three methods rather than inline,
      # because `Object#tap` is mruby-object-ext and `Range#map` is unproven
      # here — and a constant that fails to build takes the whole gem down at
      # load, taking every other suite with it.
      def self.build_rows
        rows = []
        9.times do |r|
          row = []
          9.times { |c| row << r * 9 + c }
          rows << row
        end
        rows
      end

      def self.build_cols
        cols = []
        9.times do |c|
          col = []
          9.times { |r| col << r * 9 + c }
          cols << col
        end
        cols
      end

      # Box b covers rows 3*(b/3)..+2 and cols 3*(b%3)..+2, so boxes are
      # numbered row-major over the 3x3 blocks: 0 1 2 / 3 4 5 / 6 7 8.
      def self.build_boxes
        boxes = []
        9.times do |b|
          box = []
          base_r = (b / 3) * 3
          base_c = (b % 3) * 3
          3.times do |dr|
            3.times { |dc| box << (base_r + dr) * 9 + base_c + dc }
          end
          boxes << box
        end
        boxes
      end

      ROWS = build_rows
      COLS = build_cols
      BOXES = build_boxes
      UNITS = ROWS + COLS + BOXES

      # The 20 cells that may not repeat this cell's digit: 8 in its row, 8 in
      # its column, and the 4 remaining cells of its box. Built by union over
      # UNITS rather than by arithmetic, so it cannot disagree with UNITS —
      # and the `include?` guard is what keeps the row/box overlap from being
      # counted twice.
      def self.build_peers
        peers = []
        CELLS.times do |i|
          set = []
          UNITS.each do |unit|
            next unless unit.include?(i)
            unit.each { |j| set << j if j != i && !set.include?(j) }
          end
          peers << set
        end
        peers
      end

      PEERS = build_peers

      def self.row_of(i)
        i / 9
      end

      def self.col_of(i)
        i % 9
      end

      def self.box_of(i)
        (i / 27) * 3 + (i % 9) / 3
      end

      # Digits still legal at cell i: ALL minus every digit a peer already
      # holds. Deliberately ignores the cell's OWN value, so a caller may ask
      # about a filled cell — the technique solver does, when building its
      # candidate grid — and callers that care skip filled cells themselves.
      def self.candidates(values, i)
        mask = ALL
        PEERS[i].each do |j|
          d = values[j]
          mask &= ~(1 << d) if d != 0
        end
        mask
      end

      # Both of these start at 1, because bit 0 is not a digit. A nine-step
      # loop beats any popcount cleverness at this width, and the idioms that
      # would express it (Integer#digits, Array#count) are not available here.
      def self.count_bits(mask)
        n = 0
        d = 1
        while d <= 9
          n += 1 if (mask & (1 << d)) != 0
          d += 1
        end
        n
      end

      def self.bits(mask)
        out = []
        d = 1
        while d <= 9
          out << d if (mask & (1 << d)) != 0
          d += 1
        end
        out
      end

      # No unit repeats a digit. Empty cells are ignored, so a partly filled
      # board can be consistent without being complete — which is the normal
      # state of a puzzle being played.
      def self.consistent?(values)
        UNITS.each do |unit|
          seen = 0
          unit.each do |i|
            d = values[i]
            next if d == 0
            bit = 1 << d
            return false if (seen & bit) != 0
            seen |= bit
          end
        end
        true
      end

      # Full AND legal. Both halves matter: a board can be full of digits and
      # still be nonsense, and the win condition in M3 depends on this
      # answering no in that case.
      def self.complete?(values)
        values.each { |d| return false if d == 0 }
        consistent?(values)
      end

      # `givens` and `entries` are values-shaped arrays. Both are COPIED: a
      # Grid sharing its caller's array would let a solver's scratch buffer
      # rewrite the player's board, and the generator hands over exactly such
      # a buffer.
      def initialize(givens, entries = nil)
        @givens = givens.dup
        @entries = entries ? entries.dup : Array.new(CELLS, 0)
      end

      # '.' or '0' is an empty cell; every other character becomes a given.
      def self.parse(str)
        givens = []
        str.each_char do |ch|
          givens << (ch == '.' || ch == '0' ? 0 : ch.to_i)
        end
        if givens.size != CELLS
          raise "grid needs #{CELLS} cells, got #{givens.size}"
        end
        new(givens)
      end

      def given?(i)
        @givens[i] != 0
      end

      def value_at(i)
        @givens[i] != 0 ? @givens[i] : @entries[i]
      end

      # Writing over a given is refused rather than ignored: the caller has a
      # bug, and silently dropping the write would hide it until someone
      # noticed a clue had changed.
      def set_entry(i, digit)
        raise "cell #{i} is a given" if given?(i)
        @entries[i] = digit
        self
      end

      def clear_entry(i)
        @entries[i] = 0 unless given?(i)
        self
      end

      def empty?(i)
        value_at(i) == 0
      end

      # The board as the engine wants it: one flat 81-array with givens and
      # entries merged, which is what Solver and Techniques consume. A fresh
      # array each call, for the aliasing reason in the constructor.
      def values
        out = []
        CELLS.times { |i| out << value_at(i) }
        out
      end

      def givens
        @givens.dup
      end

      def entries
        @entries.dup
      end

      def clue_count
        n = 0
        @givens.each { |d| n += 1 if d != 0 }
        n
      end

      def givens_s
        str_of(@givens)
      end

      def values_s
        str_of(values)
      end

      def entries_s
        str_of(@entries)
      end

      def solved?
        Grid.complete?(values)
      end

      private

      def str_of(list)
        s = ''
        list.each { |d| s = s + (d == 0 ? '.' : d.to_s) }
        s
      end
    end
  end
end
